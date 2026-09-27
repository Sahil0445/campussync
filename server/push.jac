"""Web Push (the phone/desktop notifications), implemented on `cryptography` only.

* VAPID (RFC 8292): an ES256-signed JWT proves the push comes from this server.
* Payload encryption (RFC 8291, aes128gcm): only the subscribed browser can read the message.
Works with Chrome/Android (FCM), Firefox (Mozilla autopush), Edge and Safari/iOS 16.4+ (Apple) --
on iPhone the app has to be added to the Home Screen first; that's an Apple rule.

Keys: VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY from the environment, otherwise generated once and kept
in the graph so subscriptions survive restarts.
"""

import base64;
import hashlib;
import json;
import logging;
import os;
import struct;
import time;
import httpx;
import from urllib.parse { urlparse }
import from cryptography.hazmat.primitives { hashes, serialization }
import from cryptography.hazmat.primitives.asymmetric { ec }
import from cryptography.hazmat.primitives.asymmetric.utils { decode_dss_signature }
import from cryptography.hazmat.primitives.ciphers.aead { AESGCM }
import from cryptography.hazmat.primitives.hmac { HMAC }
import from server.clock { utcnow, now_s, parse_iso }
import from server.config { VAPID_PRIVATE_KEY, VAPID_SUBJECT }
import from server.models {
    Account,
    Employee,
    Employer,
    Notification,
    PushSub,
    hub,
    meta_get,
    meta_set,
    employees,
    employers
}

glob log = logging.getLogger("campussync.push"),
     _priv: any = None,
     _pub: str = "",
     _results: list[tuple[str, int]] = [];

def b64u(data: bytes) -> str {
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode();
}

def unb64u(text: str) -> bytes {
    t = text.strip().replace("+", "-").replace("/", "_");
    return base64.urlsafe_b64decode(t + "=" * (-len(t) % 4));
}

def _raw_public(key: any) -> bytes {
    return key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint);
}

"""Accepts a raw 32-byte private scalar (base64url, the usual VAPID format) or a PEM."""
def _private_from_raw(raw_b64: str) -> any {
    if "BEGIN" in raw_b64 {
        return serialization.load_pem_private_key(raw_b64.encode(), password=None);
    }
    return ec.derive_private_key(int.from_bytes(unb64u(raw_b64), "big"), ec.SECP256R1());
}

"""(private key, public key as base64url) -- env first, then the graph, else generate and store."""
def keys() -> tuple[any, str] {
    if _priv is not None {
        return (_priv, _pub);
    }
    pk: any = None;
    if VAPID_PRIVATE_KEY {
        pk = _private_from_raw(VAPID_PRIVATE_KEY);
    } else {
        stored = meta_get("vapid_private");
        if stored {
            pk = _private_from_raw(stored);
        } else {
            pk = ec.generate_private_key(ec.SECP256R1());
            raw = pk.private_numbers().private_value.to_bytes(32, "big");
            meta_set("vapid_private", b64u(raw));
        }
    }
    _priv = pk;
    _pub = b64u(_raw_public(pk.public_key()));
    return (_priv, _pub);
}

def reset_keys_cache {
    _priv = None;
    _pub = "";
}

# ------------------------------------------------------------------ RFC 8291 (aes128gcm)
def _hkdf_extract(salt: bytes, ikm: bytes) -> bytes {
    h = HMAC(salt, hashes.SHA256());
    h.update(ikm);
    return h.finalize();
}

def _hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes {
    h = HMAC(prk, hashes.SHA256());
    h.update(info + b"\x01");
    return h.finalize()[:length];
}

def encrypt(
    payload: bytes, p256dh_b64: str, auth_b64: str, salt: bytes | None = None,
    server_key: any = None, record_size: int = 4096
) -> bytes {
    ua_public = unb64u(p256dh_b64);
    auth_secret = unb64u(auth_b64);
    if len(ua_public) != 65 or len(auth_secret) < 16 {
        raise ValueError("Bad subscription keys");
    }
    ua_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_public);
    as_private = server_key if server_key is not None else ec.generate_private_key(ec.SECP256R1());
    as_public = _raw_public(as_private.public_key());
    shared = as_private.exchange(ec.ECDH(), ua_key);
    prk_key = _hkdf_extract(auth_secret, shared);
    ikm = _hkdf_expand(prk_key, b"WebPush: info\x00" + ua_public + as_public, 32);
    s: bytes = salt if salt is not None else os.urandom(16);
    prk = _hkdf_extract(s, ikm);
    cek = _hkdf_expand(prk, b"Content-Encoding: aes128gcm\x00", 16);
    nonce = _hkdf_expand(prk, b"Content-Encoding: nonce\x00", 12);
    if len(payload) + 17 > record_size {
        raise ValueError("Payload too large for one record");
    }
    ciphertext = AESGCM(cek).encrypt(nonce, payload + b"\x02", None);
    header = s + struct.pack("!L", record_size) + bytes([len(as_public)]) + as_public;
    return header + ciphertext;
}

def vapid_headers(endpoint: str) -> dict[str, str] {
    (pk, pubk) = keys();
    u = urlparse(endpoint);
    claims = {"aud": f"{u.scheme}://{u.netloc}", "exp": int(time.time()) + 3600, "sub": VAPID_SUBJECT};
    header = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode());
    body = b64u(json.dumps(claims, separators=(",", ":")).encode());
    signing_input = f"{header}.{body}".encode();
    (r, s) = decode_dss_signature(pk.sign(signing_input, ec.ECDSA(hashes.SHA256())));
    jwt = f"{header}.{body}.{b64u(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}";
    return {"Authorization": f"vapid t={jwt}, k={pubk}"};
}

# ------------------------------------------------------------------ sending
def endpoint_hash(endpoint: str) -> str {
    return hashlib.sha256(endpoint.encode()).hexdigest();
}

obj Outgoing {
    has sub_id: str,
        endpoint: str,
        p256dh: str,
        auth: str,
        message: dict[str, any],
        urgency: str = "normal";
}

"""Returns the push service's HTTP status (201 = accepted). 404/410 mean the subscription is gone."""
def send(o: Outgoing, ttl: int = 6 * 3600) -> int {
    try {
        body = encrypt(json.dumps(o.message, separators=(",", ":")).encode(), o.p256dh, o.auth);
        headers = vapid_headers(o.endpoint);
        headers["Content-Encoding"] = "aes128gcm";
        headers["Content-Type"] = "application/octet-stream";
        headers["TTL"] = str(ttl);
        headers["Urgency"] = o.urgency;
        r = httpx.post(o.endpoint, content=body, headers=headers, timeout=10);
        if r.status_code >= 400 {
            log.warning("push %s -> %s %s", urlparse(o.endpoint).netloc, r.status_code, r.text[:200]);
        }
        return r.status_code;
    } except Exception as ex {
        log.warning("push to %s failed: %s", urlparse(o.endpoint).netloc, str(ex));
        return 0;
    }
}

def accounts_for(n: Notification) -> list[Account] {
    who = n.student or n.employer;
    if not who {
        return [];
    }
    return [hub() --> [?:Account, ref == who]];
}

def subscriptions_for(n: Notification) -> list[PushSub] {
    out: list[PushSub] = [];
    for a in accounts_for(n) {
        out = out + [a --> [?:PushSub]];
    }
    return out;
}

"""Apply what the push services answered last time (dead subscriptions are dropped)."""
def apply_results {
    if not _results {
        return;
    }
    done = list(_results);
    _results = [];
    for (sid, status) in done {
        sub = jobj(sid);
        if not isinstance(sub, PushSub) {
            continue;
        }
        if status == 404 or status == 410 {
            del sub;
        } elif 200 <= status and status < 300 {
            sub.last_ok_at = now_s();
            sub.failures = 0;
        } else {
            sub.failures = (sub.failures or 0) + 1;
            if sub.failures >= 20 {
                del sub;
            }
        }
    }
}

def _send_all(batch: list[Outgoing]) -> int {
    sent = 0;
    for o in batch {
        status = send(o);
        _results.append((o.sub_id, status));
        if 200 <= status and status < 300 {
            sent += 1;
        }
    }
    return sent;
}

def _pending(owner: any) -> list[Notification] {
    return [n for n in [owner --> [?:Notification, push == True]] if not n.pushed_at];
}

"""Push every notification marked for push that hasn't gone out yet (skip anything > 2 h old).
now=True sends inside this request (tests, "send a test"); otherwise sending waits for the
transaction to commit, so a replayed unit of work can never push twice."""
def deliver_pending(owners: list[any] | None = None, now: bool = False) -> int {
    batch: list[Outgoing] = [];
    cutoff = utcnow().replace(microsecond=0);
    pool: list[any] = owners if owners is not None else (list(employees()) + list(employers()));
    rows: list[Notification] = [];
    for owner in pool {
        rows = rows + _pending(owner);
    }
    rows = sorted(rows, key=lambda (n: Notification) -> str { return n.created; })[:200];
    stamp = now_s();
    for n in rows {
        n.pushed_at = stamp;
        created = parse_iso(n.created);
        if created is not None and (cutoff - created).total_seconds() > 2 * 3600 {
            continue;
        }
        message = {
            "title": n.title or "CampusSync",
            "body": n.text,
            "url": n.link or "/",
            "tag": n.kind if n.kind != "general" else f"n{jid(n)[:12]}",
            "id": jid(n)
        };
        urgency = "high" if n.kind in ("shift_1h", "timesheet_pm") else "normal";
        for sub in subscriptions_for(n) {
            batch.append(
                Outgoing(
                    sub_id=jid(sub), endpoint=sub.endpoint, p256dh=sub.p256dh, auth=sub.auth,
                    message=message, urgency=urgency
                )
            );
        }
    }
    if not batch {
        return 0;
    }
    if now {
        return _send_all(batch);
    }
    on_commit(lambda { _send_all(batch); });
    return len(batch);
}
