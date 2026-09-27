"""Demo seed (section 16). Deterministic: both swap loops and the Saturday gap are guaranteed.

Week: Mon Sep 28 – Sun Oct 4, 2026. Every shift is 4 hours, so swaps never change anyone's totals.

Employers
  * Northfield University (fictional) — two campus employers: Campus Dining (join code DINE-2026) and
    CSE Research (CSE-2026, exists to hide Priya's other job). Student employees can hold several jobs here.
  * Shieldpoint Security (SHLD-2026) — a business with regular employees (one employer each), roles
    (Site guard, Night patrol) and 12-hour shifts.
History: 12 weeks of worked shifts with time entries (approved), the week before the demo week
"reported" (waiting for Friday approval), plus one flagged line for the employer to resolve.
"""
from __future__ import annotations

import random
from datetime import date, datetime, timedelta

from sqlalchemy import select, text
from sqlalchemy.orm import Session

from . import clock
from .agents.availability import parse_note_fallback
from .auth import hash_password
from .config import DEFAULT_WEEK, SCHEMA_VERSION
from .events import log
from .db import Base, SessionLocal, engine
from .models import (BusyBlock, Department, Employment, Meta, Position, Shift, StaffingRequirement, Student, TimeEntry, University,
                     User)

PASSWORD = "demo1234"
H = 60

# name, email, status, uid, desired, prefs, open_swap_days, autopilot, classes[(days, start, end, title)], note
# Autopilot: on for everyone except Marcus — he's the one who gets asked (and declines) on stage.
STUDENTS = [
    ("Priya Nair", "priya@demo.edu", "international", "U1001", 20, ["Afternoons"], [2], True,
     [([1, 3], 9 * H, 10 * H + 15, "CSE 5243"), ([0], 16 * H, 17 * H + 15, "STAT 5301")], ""),
    ("Marcus Lee", "marcus@demo.edu", "domestic", "U1002", 12, ["Afternoons"], [3], False,
     [([0, 2, 4], 9 * H, 10 * H + 15, "ECON 2001")], ""),
    ("Sam Ortiz", "sam@demo.edu", "domestic", "U1003", 12, ["Evenings", "Weekends"], [5], True,
     [([1, 3], 8 * H, 9 * H + 15, "PHYS 1250")], ""),
    ("Dana Kim", "dana@demo.edu", "domestic", "U1004", 12, ["Evenings"], [4], True,
     [([0, 2], 10 * H, 11 * H + 15, "BIO 2100")], ""),
    ("Leo Chen", "leo@demo.edu", "international", "U1005", 12, ["Afternoons"], [3], True,
     [([2, 4], 9 * H, 10 * H + 15, "MATH 2568")], ""),
    ("Ana Silva", "ana@demo.edu", "domestic", "U1006", 12, ["Afternoons"], [], True,
     [([0, 2], 9 * H, 10 * H + 15, "HIST 1010")], "No weekends — I go home."),
    ("Ben Carter", "ben@demo.edu", "domestic", "U1007", 12, ["Evenings"], [], True,
     [([1, 3], 13 * H, 14 * H + 15, "ENG 1110")], "Saturdays I go home."),
    ("Chloe Martin", "chloe@demo.edu", "domestic", "U1008", 8, ["Mornings", "Weekends"], [], True,
     [([2], 11 * H, 12 * H + 15, "ART 2200")], "Can't work Saturdays after 3 PM."),
    ("Omar Haddad", "omar@demo.edu", "international", "U1009", 12, ["Afternoons"], [], True,
     [([4], 9 * H, 11 * H + 30, "CHEM 1210")], "No weekends."),
    ("Zoe Wright", "zoe@demo.edu", "international", "U1010", 12, [], [], True,
     [([1, 3], 16 * H, 17 * H + 15, "PSYC 1100")], "No weekends."),
    # Not on any team yet — shows up in "Add student" search.
    ("Ravi Patel", "ravi@demo.edu", "international", "U1011", 10, ["Mornings"], [], True,
     [([0, 2, 4], 13 * H, 14 * H + 15, "CSE 2221")], ""),
    ("Mia Johnson", "mia@demo.edu", "domestic", "U1012", 15, ["Evenings"], [], True,
     [([1, 3], 10 * H, 11 * H + 15, "SOC 1100")], ""),
]

DINING_HOURS = {"Priya": 8, "Marcus": 12, "Sam": 12, "Dana": 12, "Leo": 12,
                "Ana": 12, "Ben": 12, "Chloe": 8, "Omar": 12, "Zoe": 8}

MID, EVE = (11 * H, 15 * H), (15 * H, 19 * H)
# Pre-published Dining shifts: (first name, day, (start, end))
DINING_SHIFTS = [
    ("Priya", 1, EVE), ("Priya", 5, MID),
    ("Marcus", 0, MID), ("Marcus", 1, MID), ("Marcus", 2, EVE),
    ("Sam", 0, EVE), ("Sam", 1, EVE), ("Sam", 3, MID),
    ("Dana", 0, EVE), ("Dana", 2, EVE), ("Dana", 3, EVE),
    ("Leo", 0, MID), ("Leo", 1, MID), ("Leo", 4, EVE),
]
# Priya's hidden CSE Research schedule — Campus Dining must never see this.
CSE_SHIFTS = [("Priya", 0, (10 * H, 14 * H)), ("Priya", 2, (10 * H, 14 * H)), ("Priya", 4, (10 * H, 14 * H))]


def seed(db: Session) -> None:
    if db.query(Department).count():
        return
    week = DEFAULT_WEEK.isoformat()
    pw = hash_password(PASSWORD)

    uni = University(name="Northfield University")
    db.add(uni)
    db.flush()
    dining = Department(name="Campus Dining", type="vendor", kind="campus", university_id=uni.id, join_code="DINE-2026",
                        description="Campus dining hall. Two shifts a day, Monday to Saturday, busiest at lunch.")
    cse = Department(name="CSE Research", type="department", kind="campus", university_id=uni.id, join_code="CSE-2026",
                     description="Research lab assistants.")
    db.add_all([dining, cse])
    db.flush()
    cashier = Position(department_id=dining.id, name="Cashier", color="#a18bff")
    cook = Position(department_id=dining.id, name="Line cook", color="#3dd8f5")
    lab = Position(department_id=cse.id, name="Lab assistant", color="#6c8cff")
    db.add_all([cashier, cook, lab])
    db.flush()
    db.add_all([
        User(email="dining@demo.edu", password_hash=pw, role="department", name="Jordan Avery", department_id=dining.id),
        User(email="cse@demo.edu", password_hash=pw, role="department", name="Helen Park", department_id=cse.id),
    ])

    by_first: dict[str, Student] = {}
    for name, email, status, uid, desired, prefs, open_days, auto, classes, note in STUDENTS:
        events = [{"day": d, "start": start, "end": end, "title": title, "week": None} for days, start, end, title in classes for d in days]
        st = Student(name=name, email=email, status=status, university_id=uid, weekly_limit=20, kind="student", school_id=uni.id,
                     desired_hours=desired, preferences=prefs, open_swap_days=open_days,
                     autopilot=auto, note=note, calendar_source="demo", demo_events=events,
                     calendar_synced_at=clock.utcnow())
        db.add(st)
        db.flush()
        by_first[name.split()[0]] = st
        db.add(User(email=email, password_hash=pw, role="student", name=name, student_id=st.id))
        for e in events:
            db.add(BusyBlock(student_id=st.id, day=e["day"], start=e["start"], end=e["end"], title=e["title"], source="calendar"))
        for rule in parse_note_fallback(note):
            db.add(BusyBlock(student_id=st.id, day=rule["day"], start=rule["start"], end=rule["end"],
                             title=rule["label"], source="note"))

    for i, (first, hours) in enumerate(DINING_HOURS.items()):
        role = [cashier.id] if i % 2 == 0 else [cook.id]
        if first in ("Marcus", "Sam"):
            role = [cashier.id, cook.id]
        db.add(Employment(student_id=by_first[first].id, department_id=dining.id, hours=hours, state="active", positions=role, pay_rate=15.0))
    db.add(Employment(student_id=by_first["Priya"].id, department_id=cse.id, hours=12, state="active", positions=[lab.id], pay_rate=15.0))

    for day in range(6):  # Mon–Sat
        for start, end in (MID, EVE):
            db.add(StaffingRequirement(department_id=dining.id, day=day, start=start, end=end, headcount=2))
    for day in (0, 2, 4):
        db.add(StaffingRequirement(department_id=cse.id, day=day, start=10 * H, end=14 * H, headcount=1, position_id=lab.id))

    for first, day, (start, end) in DINING_SHIFTS:
        db.add(Shift(department_id=dining.id, week=week, day=day, start=start, end=end,
                     student_id=by_first[first].id, state="assigned", status="published"))
    for first, day, (start, end) in CSE_SHIFTS:
        db.add(Shift(department_id=cse.id, week=week, day=day, start=start, end=end, position_id=lab.id,
                     student_id=by_first[first].id, state="assigned", status="published"))
    shield = _seed_business(db, pw)
    _seed_history(db, [dining, cse, shield])
    log(db, "Availability Agent", "Synced 10 team calendars · autopilot is on", department_id=dining.id, level="info")
    for st in by_first.values():
        log(db, "Availability Agent", "Synced your demo calendar", student_id=st.id)
    db.add(Meta(key="schema", value=SCHEMA_VERSION))
    db.commit()


# ------------------------------------------------------------------ a business: Shieldpoint Security
GUARDS = [  # name, email, roles, weekly hours, days off
    ("Tom Alvarez", "tom@demo.com", ["guard"], 48, [5, 6]),
    ("Aisha Khan", "aisha@demo.com", ["guard", "patrol"], 40, [0, 1]),
    ("Diego Santos", "diego@demo.com", ["patrol"], 36, [3]),
    ("Grace Liu", "grace@demo.com", ["guard", "patrol"], 40, [2]),
]


def _seed_business(db: Session, pw: str) -> Department:
    shield = Department(name="Shieldpoint Security", type="vendor", kind="business", join_code="SHLD-2026",
                        default_weekly_hours=40, auto_recruit=False,
                        description="Security guards for two office sites. Day posts 7 AM–7 PM, a night patrol 6 PM–midnight.")
    db.add(shield)
    db.flush()
    guard = Position(department_id=shield.id, name="Site guard", color="#7ee0b5")
    patrol = Position(department_id=shield.id, name="Night patrol", color="#ffc46b")
    db.add_all([guard, patrol])
    db.flush()
    ids = {"guard": guard.id, "patrol": patrol.id}
    db.add(User(email="shield@demo.com", password_hash=pw, role="department", name="Rosa Mendes", department_id=shield.id))
    for name, email, roles, hours, off in GUARDS:
        st = Student(name=name, email=email, kind="worker", status="domestic", weekly_limit=60, desired_hours=0,
                     preferences=[], open_swap_days=[d for d in range(7) if d not in off][:2], autopilot=True,
                     calendar_source="demo", calendar_synced_at=clock.utcnow(),
                     demo_events=[{"day": d, "start": 0, "end": 24 * H, "title": "Day off", "week": None} for d in off])
        db.add(st)
        db.flush()
        db.add(User(email=email, password_hash=pw, role="student", name=name, student_id=st.id))
        for d in off:
            db.add(BusyBlock(student_id=st.id, day=d, start=0, end=24 * H, title="Day off", source="calendar"))
        db.add(Employment(student_id=st.id, department_id=shield.id, hours=hours, state="active",
                          positions=[ids[r] for r in roles], pay_rate=15.0))
    for day in range(7):
        db.add(StaffingRequirement(department_id=shield.id, day=day, start=7 * H, end=19 * H, headcount=1, position_id=guard.id))
        db.add(StaffingRequirement(department_id=shield.id, day=day, start=18 * H, end=24 * H, headcount=1, position_id=patrol.id))
    db.flush()
    log(db, "Coordinator", "Team of 4 guards · autopilot drafts every week for your approval", department_id=shield.id, level="info")
    return shield


# ------------------------------------------------------------------ history (worked weeks)
def _seed_history(db: Session, depts: list[Department], weeks: int = 12) -> None:
    """Replay each employee's usual week for the past `weeks` weeks as worked shifts + time entries."""
    rng = random.Random(2026)
    demo_week = DEFAULT_WEEK
    templates: dict[int, list[tuple[int, int, int, int, int | None]]] = {}
    for sh in db.scalars(select(Shift).where(Shift.week == demo_week.isoformat(), Shift.student_id.is_not(None))):
        templates.setdefault(sh.student_id, []).append((sh.department_id, sh.day, sh.start, sh.end, sh.position_id))
    shield = next(d for d in depts if d.kind == "business")
    roles = {p.name: p.id for p in db.scalars(select(Position).where(Position.department_id == shield.id))}
    guards = {st.email: st for st in db.scalars(select(Student).where(Student.kind == "worker"))}
    # Shieldpoint's usual rota (the demo week itself is left for the autopilot to draft)
    rota = {
        "tom@demo.com": [(d, 7 * H, 19 * H, roles["Site guard"]) for d in (0, 1, 2, 3)],
        "aisha@demo.com": [(d, 7 * H, 19 * H, roles["Site guard"]) for d in (4, 5, 6)] + [(2, 18 * H, 24 * H, roles["Night patrol"])],
        "diego@demo.com": [(d, 18 * H, 24 * H, roles["Night patrol"]) for d in (0, 1, 4, 5, 6)],
        "grace@demo.com": [(3, 18 * H, 24 * H, roles["Night patrol"])],
    }
    for email, rows in rota.items():
        st = guards[email]
        templates[st.id] = [(shield.id, d, s, e, pid) for d, s, e, pid in rows]
    rates = {(e.student_id, e.department_id): e.pay_rate for e in db.scalars(select(Employment))}
    tzs = {d.id: d.timezone for d in depts}
    now = clock.utcnow()
    for back in range(weeks, 0, -1):
        wk = demo_week - timedelta(days=7 * back)
        last = back == 1
        for sid, rows in templates.items():
            for did, day, start, end, pid in rows:
                if not last and rng.random() < 0.08:
                    continue  # the odd week off
                sh = Shift(department_id=did, week=wk.isoformat(), day=day, start=start, end=end, student_id=sid,
                           state="assigned", status="published", position_id=pid, source="generated")
                db.add(sh)
                db.flush()
                dept_tz = tzs[did]
                if clock.to_utc_naive(clock.slot_datetime(wk.isoformat(), day, end, dept_tz)) > now:
                    continue  # hasn't happened yet — the Time Agent reports it when it ends
                s2, e2 = start, end
                if not last and rng.random() < 0.12:
                    e2 = min(24 * H, end + rng.choice([15, 30]))  # stayed a little late — corrected and approved
                db.add(TimeEntry(student_id=sid, department_id=did, shift_id=sh.id, position_id=pid,
                                 work_date=wk + timedelta(days=day), week=wk.isoformat(), start=s2, end=e2,
                                 pay_rate=rates.get((sid, did), 15.0), status="reported" if last else "approved",
                                 source="auto", approved_at=None if last else now, created_at=now))
    db.flush()
    # One flagged line for Campus Dining to resolve: Sam stayed 30 minutes late last Tuesday.
    sam = db.scalar(select(Student).where(Student.email == "sam@demo.edu"))
    last_wk = (demo_week - timedelta(days=7)).isoformat()
    e = db.scalar(select(TimeEntry).where(TimeEntry.student_id == sam.id, TimeEntry.week == last_wk, TimeEntry.work_date == demo_week - timedelta(days=6)))
    if e:
        e.status, e.proposed_start, e.proposed_end = "disputed", e.start, e.end + 30
        e.note = "Stayed 30 min to close the register."
    


def sample_demo_events() -> list[dict]:
    """A plausible class schedule for a new student who picks the demo calendar."""
    return [{"day": d, "start": s, "end": e, "title": t, "week": None} for days, s, e, t in (
        ([0, 2, 4], 9 * H + 10, 10 * H + 30, "CSE 3241"), ([1, 3], 12 * H + 45, 14 * H + 5, "MATH 2568"),
        ([3], 15 * H + 30, 17 * H + 20, "PHYS 1250 Lab")) for d in days]


def add_demo_event(db: Session, st: Student, day: int, start: int, end: int, title: str, week: str | None) -> None:
    """Stands in for the student adding an event in Google Calendar."""
    st.demo_events = (st.demo_events or []) + [{"day": day, "start": start, "end": end, "title": title, "week": week}]


def _schema_ok() -> bool:
    try:
        with engine.connect() as c:
            row = c.execute(text("SELECT value FROM meta WHERE key='schema'")).fetchone()
            return bool(row) and row[0] == SCHEMA_VERSION
    except Exception:
        return False


def init_db(reset: bool = False) -> None:
    if reset or (_has_tables() and not _schema_ok()):
        Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as db:
        seed(db)


def _has_tables() -> bool:
    try:
        from sqlalchemy import inspect

        return bool(inspect(engine).get_table_names())
    except Exception:
        return True


if __name__ == "__main__":  # python -m app.seed [--reset]
    import sys

    init_db(reset="--reset" in sys.argv)
    print("Database ready." + (" (reset)" if "--reset" in sys.argv else ""))
