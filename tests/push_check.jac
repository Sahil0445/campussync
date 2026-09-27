"""Web Push crypto check: encrypt with server/push.jac, decrypt like a browser would (RFC 8291),
and verify the VAPID JWT signature."""

import os;
import json;
import struct;
import base64;
import from cryptography.hazmat.primitives { hashes, serialization }
import from cryptography.hazmat.primitives.asymmetric { ec }
import from cryptography.hazmat.primitives.asymmetric.utils { encode_dss_signature }
import from cryptography.hazmat.primitives.ciphers.aead { AESGCM }
import from cryptography.hazmat.primitives.hmac { HMAC }
import server.push as push;

def _hmac(key: bytes, data: bytes) -> bytes {
    h = HMAC(key, hashes.SHA256());
    h.update(data);
    return h.finalize();
}

with entry:__main__ {
    key = ec.generate_private_key(ec.SECP256R1());
    upub = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint);
    auth = os.urandom(16);
    msg = {"title": "Shift reminder", "body": "Tomorrow 11 AM–3 PM · Campus Dining.", "url": "/s"};
    body = push.encrypt(json.dumps(msg).encode(), push.b64u(upub), push.b64u(auth));
    salt = body[:16];
    rs = struct.unpack("!L", body[16:20])[0];
    idlen = body[20];
    as_pub = body[21:21 + idlen];
    ct = body[21 + idlen:];
    shared = key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_pub));
    ikm = _hmac(_hmac(auth, shared), b"WebPush: info\x00" + upub + as_pub + b"\x01")[:32];
    prk = _hmac(salt, ikm);
    cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16];
    nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12];
    plain = AESGCM(cek).decrypt(nonce, ct, None);
    assert plain.endswith(b"\x02") and rs == 4096;
    assert json.loads(plain[:-1]) == msg;
    print("encrypt/decrypt ok");
    # VAPID
    push._priv = ec.generate_private_key(ec.SECP256R1());
    push._pub = push.b64u(push._raw_public(push._priv.public_key()));
    hdr = push.vapid_headers("https://fcm.googleapis.com/fcm/send/abc")["Authorization"];
    jwt = hdr.split("t=")[1].split(",")[0];
    kpart = hdr.split("k=")[1];
    (h64, c64, s64) = jwt.split(".");
    claims = json.loads(push.unb64u(c64));
    assert claims["aud"] == "https://fcm.googleapis.com" and claims["sub"].startswith("mailto:");
    sig = push.unb64u(s64);
    r = int.from_bytes(sig[:32], "big");
    s = int.from_bytes(sig[32:], "big");
    pubkey = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), push.unb64u(kpart));
    pubkey.verify(encode_dss_signature(r, s), f"{h64}.{c64}".encode(), ec.ECDSA(hashes.SHA256()));
    print("vapid ok");
}
