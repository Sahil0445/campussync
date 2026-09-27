"""Notifier: in-app notifications, also delivered as phone/desktop push (see services/push.py).

`dedupe_key` makes an alert idempotent — the alert scheduler can run every few seconds and each
reminder still goes out exactly once.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Notification


def _add(db: Session, *, student_id: int | None = None, department_id: int | None = None, text: str, link: str = "",
         title: str = "", kind: str = "general", dedupe_key: str | None = None, push: bool = True) -> Notification | None:
    if dedupe_key:
        if db.scalar(select(Notification.id).where(Notification.dedupe_key == dedupe_key)):
            return None
        for pending in db.new:  # not flushed yet in this session
            if isinstance(pending, Notification) and pending.dedupe_key == dedupe_key:
                return None
    n = Notification(student_id=student_id, department_id=department_id, text=text[:1000], link=link[:200], title=title[:120],
                     kind=kind, dedupe_key=dedupe_key, push=push)
    db.add(n)
    return n


def to_student(db: Session, student_id: int, text: str, link: str = "", *, title: str = "", kind: str = "general",
               dedupe_key: str | None = None, push: bool = True) -> Notification | None:
    return _add(db, student_id=student_id, text=text, link=link, title=title, kind=kind, dedupe_key=dedupe_key, push=push)


def to_department(db: Session, department_id: int, text: str, link: str = "", *, title: str = "", kind: str = "general",
                  dedupe_key: str | None = None, push: bool = True) -> Notification | None:
    return _add(db, department_id=department_id, text=text, link=link, title=title, kind=kind, dedupe_key=dedupe_key, push=push)
