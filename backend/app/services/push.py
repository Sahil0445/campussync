"""Web Push (the phone/desktop notifications), implemented on `cryptography` only.

* VAPID (RFC 8292): an ES256-signed JWT proves the push comes from this server.
* Payload encryption (RFC 8291, aes128gcm): only the subscribed browser can read the message.
Works with Chrome/Android (FCM), Firefox (Mozilla autopush), Edge and Safari/iOS 16.4+ (Apple) —
on iPhone the app has to be added to the Home Screen first; that's an Apple rule.

Keys: VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY from the environment, otherwise generated once and kept
in the database so subscriptions survive restarts.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import struct
import time
from urllib.parse import urlparse

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hmac import HMAC
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import clock, config
from ..models import Meta, Notification, PushSubscription, User

log = logging.getLogger("campussync.push")

_keys: tuple[ec.EllipticCurvePrivateKey, str] | None = None


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text: str) -> bytes:
    text = text.strip().replace("+", "-").replace("/", "_")
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _raw_public(key: ec.EllipticCurvePublicKey) -> bytes:
    return key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def _private_from_raw(raw_b64: str) -> ec.EllipticCurvePrivateKey:
    """Accepts a raw 32-byte private scalar (base64url, the usual VAPID format) or a PEM."""
    if "BEGIN" in raw_b64:
        return serialization.load_pem_private_key(raw_b64.encode(), password=None)
    return ec.derive_private_key(int.from_bytes(unb64u(raw_b64), "big"), ec.SECP256R1())


def keys(db: Session | None = None) -> tuple[ec.EllipticCurvePrivateKey, str]:
    """(private key, public key as base64url) — env first, then database, else generate and store."""
    global _keys
    if _keys:
        return _keys
    if config.VAPID_PRIVATE_KEY:
        priv = _private_from_raw(config.VAPID_PRIVATE_KEY)
        _keys = (priv, b64u(_raw_public(priv.public_key())))
        return _keys
    from ..db import SessionLocal

    own = db is None
    db = db or SessionLocal()
    try:
        row = db.get(Meta, "vapid_private")
        if row and row.value:
            priv = _private_from_raw(row.value)
        else:
            priv = ec.generate_private_key(ec.SECP256R1())
            raw = priv.private_numbers().private_value.to_bytes(32, "big")
            db.merge(Meta(key="vapid_private", value=b64u(raw)))
            db.commit()
        _keys = (priv, b64u(_raw_public(priv.public_key())))
        return _keys
    finally:
        if own:
            db.close()


def reset_keys_cache() -> None:
    global _keys
    _keys = None


# ------------------------------------------------------------------ RFC 8291 (aes128gcm)
def _hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    h = HMAC(salt, hashes.SHA256())
    h.update(ikm)
    return h.finalize()


def _hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    h = HMAC(prk, hashes.SHA256())
    h.update(info + b"\x01")
    return h.finalize()[:length]


def encrypt(payload: bytes, p256dh_b64: str, auth_b64: str, *, salt: bytes | None = None,
            server_key: ec.EllipticCurvePrivateKey | None = None, record_size: int = 4096) -> bytes:
    ua_public = unb64u(p256dh_b64)
    auth_secret = unb64u(auth_b64)
    if len(ua_public) != 65 or len(auth_secret) < 16:
        raise ValueError("Bad subscription keys")
    ua_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_public)
    as_private = server_key or ec.generate_private_key(ec.SECP256R1())
    as_public = _raw_public(as_private.public_key())
    shared = as_private.exchange(ec.ECDH(), ua_key)
    prk_key = _hkdf_extract(auth_secret, shared)
    ikm = _hkdf_expand(prk_key, b"WebPush: info\x00" + ua_public + as_public, 32)
    salt = salt or os.urandom(16)
    prk = _hkdf_extract(salt, ikm)
    cek = _hkdf_expand(prk, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = _hkdf_expand(prk, b"Content-Encoding: nonce\x00", 12)
    if len(payload) + 17 > record_size:
        raise ValueError("Payload too large for one record")
    ciphertext = AESGCM(cek).encrypt(nonce, payload + b"\x02", None)
    header = salt + struct.pack("!L", record_size) + bytes([len(as_public)]) + as_public
    return header + ciphertext


def vapid_headers(endpoint: str, db: Session | None = None) -> dict[str, str]:
    priv, pub = keys(db)
    u = urlparse(endpoint)
    claims = {"aud": f"{u.scheme}://{u.netloc}", "exp": int(time.time()) + 3600, "sub": config.VAPID_SUBJECT}
    header = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode())
    body = b64u(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = f"{header}.{body}".encode()
    r, s = decode_dss_signature(priv.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    jwt = f"{header}.{body}.{b64u(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"
    return {"Authorization": f"vapid t={jwt}, k={pub}"}


# ------------------------------------------------------------------ sending
def endpoint_hash(endpoint: str) -> str:
    return hashlib.sha256(endpoint.encode()).hexdigest()


def send(sub: PushSubscription, message: dict, *, urgency: str = "normal", ttl: int = 6 * 3600,
         client: httpx.Client | None = None, db: Session | None = None) -> int:
    """Returns the push service's HTTP status (201 = accepted). 404/410 mean the subscription is gone."""
    body = encrypt(json.dumps(message, separators=(",", ":")).encode(), sub.p256dh, sub.auth)
    headers = {**vapid_headers(sub.endpoint, db), "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
               "TTL": str(ttl), "Urgency": urgency}
    c = client or httpx.Client(timeout=10)
    try:
        r = c.post(sub.endpoint, content=body, headers=headers)
        if r.status_code >= 400:
            log.warning("push %s -> %s %s", urlparse(sub.endpoint).netloc, r.status_code, r.text[:200])
        return r.status_code
    except httpx.HTTPError as e:
        log.warning("push to %s failed: %s", urlparse(sub.endpoint).netloc, e)
        return 0
    finally:
        if client is None:
            c.close()


def subscriptions_for(db: Session, n: Notification) -> list[PushSubscription]:
    if n.student_id:
        users = db.scalars(select(User.id).where(User.student_id == n.student_id)).all()
    elif n.department_id:
        users = db.scalars(select(User.id).where(User.department_id == n.department_id)).all()
    else:
        return []
    if not users:
        return []
    return list(db.scalars(select(PushSubscription).where(PushSubscription.user_id.in_(users))))


def deliver_pending(db: Session, client: httpx.Client | None = None) -> int:
    """Push every notification marked for push that hasn't gone out yet (skip anything > 2 h old)."""
    cutoff = clock.utcnow().replace(microsecond=0)
    rows = db.scalars(select(Notification).where(Notification.push.is_(True), Notification.pushed_at.is_(None))
                      .order_by(Notification.id).limit(200)).all()
    sent = 0
    for n in rows:
        n.pushed_at = cutoff
        if (cutoff - n.created_at).total_seconds() > 2 * 3600:
            continue
        subs = subscriptions_for(db, n)
        message = {"title": n.title or "CampusSync", "body": n.text, "url": n.link or "/", "tag": n.kind if n.kind != "general" else f"n{n.id}",
                   "id": n.id}
        urgency = "high" if n.kind in ("shift_1h", "timesheet_pm") else "normal"
        for sub in subs:
            status = send(sub, message, urgency=urgency, client=client, db=db)
            if status in (404, 410):
                db.delete(sub)
            elif 200 <= status < 300:
                sub.last_ok_at, sub.failures = clock.utcnow(), 0
                sent += 1
            else:
                sub.failures = (sub.failures or 0) + 1
                if sub.failures >= 20:
                    db.delete(sub)
    db.commit()
    return sent
