"""Password hashing and signed tokens using only the standard library."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time

from fastapi import Depends, HTTPException, Request
from sqlalchemy.orm import Session

from .config import SECRET, TOKEN_TTL_SECONDS
from .db import get_db
from .models import User

_ITER = 120_000


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _ITER)
    return f"pbkdf2${_ITER}${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        _, iters, salt_hex, digest_hex = stored.split("$")
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_hex), int(iters))
        return hmac.compare_digest(digest.hex(), digest_hex)
    except Exception:
        return False


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def make_token(user: User) -> str:
    payload = _b64(json.dumps({"uid": user.id, "exp": int(time.time()) + TOKEN_TTL_SECONDS}).encode())
    sig = _b64(hmac.new(SECRET.encode(), payload.encode(), hashlib.sha256).digest())
    return f"{payload}.{sig}"


def read_token(token: str) -> int | None:
    try:
        payload, sig = token.split(".")
        expected = _b64(hmac.new(SECRET.encode(), payload.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, expected):
            return None
        data = json.loads(_unb64(payload))
        if data["exp"] < time.time():
            return None
        return int(data["uid"])
    except Exception:
        return None


def current_user(request: Request, db: Session = Depends(get_db)) -> User:
    header = request.headers.get("authorization", "")
    token = header[7:] if header.lower().startswith("bearer ") else ""
    uid = read_token(token) if token else None
    user = db.get(User, uid) if uid else None
    if not user:
        raise HTTPException(status_code=401, detail="Please sign in again.")
    return user
