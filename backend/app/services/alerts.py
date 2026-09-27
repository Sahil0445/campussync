"""Alert scheduler. Runs inside every autopilot cycle; every alert is sent exactly once (dedupe keys).

Employees get:
  * 24 hours before a shift   "Tomorrow 11 AM–3 PM · Campus Dining"
  * 1 hour before a shift     "Starts in 1 hour"
  * Friday morning (09:00)    "Check and approve this week's reported hours"
  * Friday evening (18:00)    reminder, only if they still haven't approved
A shift created less than 24 h ahead gets the 24 h alert right away (if it's more than an hour off).
"""
from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import clock, config
from ..models import Department, Employment, Position, Shift, Student, TimeEntry
from ..notify import to_student
from ..timeutil import fmt_hours
from . import timesheets


def _t12(minutes: int) -> str:
    h, m = divmod(minutes, 60)
    suffix = "AM" if h < 12 or h == 24 else "PM"
    hh = h % 12 or 12
    return f"{hh}:{m:02d} {suffix}" if m else f"{hh} {suffix}"


def shift_alerts(db: Session) -> int:
    now = clock.utcnow()
    this_week = clock.monday(clock.today_local())
    weeks = [(this_week + timedelta(days=7 * i)).isoformat() for i in (-1, 0, 1)]
    shifts = db.scalars(select(Shift).where(Shift.status == "published", Shift.student_id.is_not(None), Shift.week.in_(weeks),
                                            Shift.state.in_(("assigned", "pending_swap")))).all()
    depts: dict[int, Department] = {}
    roles: dict[int, str] = {}
    sent = 0
    for sh in shifts:
        dept = depts.setdefault(sh.department_id, db.get(Department, sh.department_id))
        start_local = clock.slot_datetime(sh.week, sh.day, sh.start, dept.timezone)
        until = clock.to_utc_naive(start_local) - now
        if until <= timedelta(0) or until > timedelta(hours=24):
            continue
        if sh.position_id and sh.position_id not in roles:
            p = db.get(Position, sh.position_id)
            roles[sh.position_id] = p.name if p else ""
        what = dept.name + (f" · {roles.get(sh.position_id)}" if sh.position_id and roles.get(sh.position_id) else "")
        when = f"{_t12(sh.start)}–{_t12(sh.end)}"
        slot = f"{sh.week}:{sh.day}:{sh.start}:{sh.end}"
        if until <= timedelta(hours=1):
            mins = max(1, round(until.total_seconds() / 60))
            n = to_student(db, sh.student_id, f"{what} · {when}. Starts in {mins} min.", "/s",
                           title="Your shift starts soon", kind="shift_1h", dedupe_key=f"s1h:{sh.id}:{sh.student_id}:{slot}")
        elif until > timedelta(hours=1):
            local_now = clock.now_local(dept.timezone)
            day_word = "Today" if start_local.date() == local_now.date() else "Tomorrow" if start_local.date() == local_now.date() + timedelta(days=1) else start_local.strftime("%A")
            n = to_student(db, sh.student_id, f"{day_word} {when} · {what}.", "/s",
                           title="Shift reminder", kind="shift_24h", dedupe_key=f"s24h:{sh.id}:{sh.student_id}:{slot}")
        else:
            n = None
        if n is not None:
            sent += 1
    return sent


def timesheet_alerts(db: Session) -> int:
    pending = db.scalars(select(TimeEntry).where(TimeEntry.status == "reported")).all()
    by_student: dict[int, list[TimeEntry]] = {}
    for e in pending:
        by_student.setdefault(e.student_id, []).append(e)
    sent = 0
    for sid, entries in by_student.items():
        st = db.get(Student, sid)
        if not st:
            continue
        tzname = timesheets.primary_tz(db, st)
        local = clock.now_local(tzname)
        if local.weekday() != config.TIMESHEET_DAY:
            continue
        minutes = local.hour * 60 + local.minute
        day = local.date().isoformat()
        hrs = fmt_hours(round(sum(e.hours for e in entries), 2))
        n = None
        if config.TIMESHEET_MORNING <= minutes < config.TIMESHEET_EVENING:
            n = to_student(db, sid, f"CampusSync reported {hrs} hrs for you. Check the days you worked and approve.", "/s/time",
                           title="Approve your timesheet", kind="timesheet_am", dedupe_key=f"tsam:{sid}:{day}")
        elif minutes >= config.TIMESHEET_EVENING:
            n = to_student(db, sid, f"You still have {hrs} hrs waiting for your approval. It takes one tap.", "/s/time",
                           title="Reminder: timesheet not approved", kind="timesheet_pm", dedupe_key=f"tspm:{sid}:{day}")
        if n is not None:
            sent += 1
    return sent


def run(db: Session) -> int:
    n = shift_alerts(db) + timesheet_alerts(db)
    if n:
        db.commit()
    return n
