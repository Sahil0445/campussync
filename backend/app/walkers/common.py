"""Identity and notifications (both roles). Sign-up lives in membership.py."""
from __future__ import annotations

import re
from datetime import datetime

from sqlalchemy import func, or_, select

from .. import clock
from ..auth import hash_password, make_token
from ..models import Employment, Notification, User
from .base import Ctx, WalkerError, walker

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def check_account(ctx: Ctx, email: str, password: str) -> str:
    email = email.strip().lower()
    if not EMAIL_RE.match(email) or len(email) > 200:
        raise WalkerError("Enter a valid email address.")
    if len(password) < 8:
        raise WalkerError("Use at least 8 characters for your password.")
    if len(password) > 200:
        raise WalkerError("That password is too long.")
    if ctx.db.scalar(select(User).where(User.email == email)):
        raise WalkerError("An account with this email already exists. Try signing in.")
    return email


def session_payload(user: User) -> dict:
    return {"token": make_token(user), "role": user.role, "name": user.name}


@walker("any")
def whoami(ctx: Ctx):
    from ..models import University

    u = ctx.user
    out = {"role": u.role, "name": u.name, "email": u.email}
    if u.role == "department":
        d = ctx.department
        uni = ctx.db.get(University, d.university_id) if d.university_id else None
        out["department"] = {"id": d.id, "name": d.name, "type": d.type, "kind": d.kind, "join_code": d.join_code,
                             "university": uni.name if uni else None, "timezone": d.timezone}
    else:
        s = ctx.student
        uni = ctx.db.get(University, s.school_id) if s.school_id else None
        jobs = ctx.db.scalar(select(func.count(Employment.id)).where(Employment.student_id == s.id, Employment.state == "active"))
        out["student"] = {"id": s.id, "name": s.name, "first_name": s.first_name, "status": s.status, "kind": s.kind,
                          "international": s.is_international, "cap": s.cap, "university": uni.name if uni else None, "jobs": jobs}
    return out


def _scope(ctx: Ctx):
    u = ctx.user
    if u.role == "department":
        return Notification.department_id == u.department_id
    return Notification.student_id == u.student_id


@walker("any")
def get_notifications(ctx: Ctx):
    rows = ctx.db.scalars(select(Notification).where(_scope(ctx)).order_by(Notification.created_at.desc(), Notification.id.desc()).limit(30)).all()
    now = clock.utcnow()
    return {
        "unread": sum(1 for n in rows if not n.read),
        "items": [{"id": n.id, "title": n.title, "text": n.text, "link": n.link, "read": n.read, "kind": n.kind,
                   "seconds_ago": int((now - n.created_at).total_seconds())} for n in rows],
    }


@walker("any")
def mark_notifications_read(ctx: Ctx):
    for n in ctx.db.scalars(select(Notification).where(_scope(ctx), or_(Notification.read.is_(False), Notification.read.is_(None)))):
        n.read = True
    ctx.db.commit()
    return {"ok": True}
