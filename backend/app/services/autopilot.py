"""Autopilot — the loop that runs the operation so people don't have to.

Every cycle (default 15 s):
  1. expire stale swap offers                       (Commit Service)
  2. sync connected calendars, catch new clashes    (Availability Agent -> Swap Agent)
  3. draft the upcoming week when slots are open    (Scheduling Agent)       -> manager approves
  4. recruit from campus for slots the team can't   (Recruiting Agent)       -> manager approves
  5. accept invites that fit an employee's limits   (employee autopilot)
  6. hand open shifts to eligible employees         (employee autopilot)
  7. report hours for shifts that just ended        (Time Agent)             -> employee approves Friday
  8. shift reminders + Friday timesheet alerts      (Notifier)               -> phone push
Humans only approve. Every hard rule is still checked in code at every step.
"""
from __future__ import annotations

import logging
import threading
from datetime import date, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import clock
from .. import config
from ..agents import recruiting, scheduling
from ..agents.rules import Ledger
from ..events import log
from ..models import Department, Employment, ScheduleDraft, Shift, StaffingRequirement, Student
from ..notify import to_department, to_student
from ..timeutil import monday_of, slot_label
from . import alerts, calendar, push, swaps, timesheets

log_ = logging.getLogger("campussync.autopilot")
_lock = threading.Lock()
_last_run: datetime | None = None


def last_run_iso() -> str | None:
    return _last_run.isoformat() + "Z" if _last_run else None


def planning_week() -> str:
    upcoming = monday_of(clock.today_local()) + timedelta(days=7)
    return max(upcoming, config.DEFAULT_WEEK).isoformat()


def tick(db: Session) -> dict:
    with _lock:
        stats = {"synced": 0, "drafts": 0, "recruits": 0, "invites": 0, "open_filled": 0, "reported": 0, "alerts": 0, "pushed": 0}
        swaps.sweep_expired(db)
        stats["synced"] = _safe(lambda: calendar.sync_due(db), db, "calendar sync") or 0
        week = planning_week()
        for dept in db.scalars(select(Department)).all():
            if not db.scalar(select(StaffingRequirement.id).where(StaffingRequirement.department_id == dept.id).limit(1)):
                continue
            if dept.auto_generate and _maybe_draft(db, dept, week):
                stats["drafts"] += 1
            if dept.auto_recruit:
                stats["recruits"] += len(recruiting.recruit(db, dept, week))
        stats["invites"] = _accept_invites(db)
        stats["open_filled"] = _fill_open_shifts(db)
        db.commit()
        stats["reported"] = _safe(lambda: timesheets.generate_due(db), db, "time reporting") or 0
        stats["alerts"] = _safe(lambda: alerts.run(db), db, "alerts") or 0
        stats["pushed"] = _safe(lambda: push.deliver_pending(db), db, "push") or 0
        return stats


def _safe(fn, db: Session, what: str):
    """One failing stage (e.g. Google is down) must never stop the rest of the cycle."""
    try:
        return fn()
    except Exception:
        db.rollback()
        log_.exception("autopilot stage failed: %s", what)
        return None


def _maybe_draft(db: Session, dept: Department, week: str) -> bool:
    pending = db.scalar(select(ScheduleDraft).where(ScheduleDraft.department_id == dept.id, ScheduleDraft.week == week,
                                                    ScheduleDraft.state == "draft"))
    if pending:
        return False
    recent = db.scalar(select(ScheduleDraft).where(ScheduleDraft.department_id == dept.id, ScheduleDraft.week == week,
                                                   ScheduleDraft.state == "discarded",
                                                   ScheduleDraft.created_at > clock.utcnow() - timedelta(minutes=30)))
    if recent:
        return False  # the manager just said no — don't nag
    _open, fillable = scheduling.fillable_seats(db, dept, week)
    if not fillable:
        return False
    scheduling.generate(db, dept, week, origin="autopilot")
    to_department(db, dept.id, "Autopilot drafted next week's schedule. Review and approve.", "/d/approvals")
    return True


def _accept_invites(db: Session) -> int:
    from ..walkers.membership import can_join  # local import: walkers import this module

    n = 0
    for emp in db.scalars(select(Employment).where(Employment.state == "invited")).all():
        st = db.get(Student, emp.student_id)
        if not st.autopilot:
            continue
        dept = db.get(Department, emp.department_id)
        if can_join(db, st, dept, ignore_invite=emp.id):
            continue  # returns a reason when the rules say no (e.g. a regular employee already has an employer)
        assigned = sum(e.hours for e in db.scalars(select(Employment).where(Employment.student_id == st.id, Employment.state == "active")))
        if assigned + emp.hours > st.cap:
            continue
        emp.state = "active"
        log(db, "Autopilot", f"Accepted {dept.name}'s invite for you · {emp.hours} hrs/week fits your limits",
            student_id=st.id, level="done")
        log(db, "Autopilot", f"{st.first_name} accepted your invite ({emp.hours} hrs/week)", department_id=dept.id, level="done")
        recruiting.on_invite_answer(db, st, dept, True)
        n += 1
    return n


def _fill_open_shifts(db: Session) -> int:
    n = 0
    for sh in db.scalars(select(Shift).where(Shift.student_id.is_(None), Shift.state == "open", Shift.status == "published")).all():
        ledger = Ledger(db, sh.week)
        best = None
        for st in scheduling.team_of(db, sh.department_id):
            if not st.autopilot or not ledger.check(st.id, sh.department_id, sh.day, sh.start, sh.end, pid=sh.position_id).ok:
                continue
            spare = ledger.hours_left(st.id, sh.department_id)
            if best is None or spare > best[0]:
                best = (spare, st)
        if best:
            st = best[1]
            sh.student_id, sh.state = st.id, "assigned"
            label = slot_label(sh.day, sh.start, sh.end)
            log(db, "Autopilot", f"Picked up the open shift {label} for you — it fits your hours", student_id=st.id, level="done")
            log(db, "Autopilot", f"{st.first_name} picked up the open shift {label}", department_id=sh.department_id, level="done")
            to_student(db, st.id, f"Autopilot picked up {label} for you.", "/s")
            n += 1
    return n


def run_once() -> dict:
    from ..db import SessionLocal

    global _last_run
    with SessionLocal() as db:
        try:
            out = tick(db)
            _last_run = clock.utcnow()
            return out
        except Exception:
            db.rollback()
            log_.exception("autopilot tick failed")
            return {}
