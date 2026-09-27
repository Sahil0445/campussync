"""Employers, employees and join codes.

* An EMPLOYER registers its organization and gets a unique join code (e.g. DINE-7K2Q).
  A campus employer belongs to a university; a business stands alone.
* An EMPLOYEE signs up with that code and lands on the right team.
    - kind "student": a campus student employee. Can join several employers, all at the same
      university (the 20 h international cap then spans all of them).
    - kind "worker": a regular employee (e.g. a security guard). One employer at a time.
"""
from __future__ import annotations

import re
import secrets
from datetime import date, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .. import clock, config
from ..auth import hash_password
from ..events import log
from ..models import Department, Employment, Shift, Student, University, User
from ..notify import to_department, to_student
from .base import Ctx, WalkerError, walker
from .common import check_account, session_payload

CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O/1/I/L


# ------------------------------------------------------------------ codes
def normalize_code(code: str) -> str:
    c = re.sub(r"[^A-Za-z0-9]", "", code or "").upper()
    if len(c) > 4:
        c = f"{c[:-4]}-{c[-4:]}"
    return c


def new_join_code(db: Session, name: str) -> str:
    words = re.findall(r"[A-Z0-9]+", name.upper())
    prefix = "".join(w[0] for w in words)[:4] if len(words) > 1 else (words[0][:4] if words else "")
    if len(prefix) < 2:
        prefix = "TEAM"
    for _ in range(50):
        code = f"{prefix}-{''.join(secrets.choice(CODE_ALPHABET) for _ in range(4))}"
        if not db.scalar(select(Department.id).where(Department.join_code == code)):
            return code
    raise WalkerError("Couldn't make a join code — try again.", 500)


def department_by_code(db: Session, code: str) -> Department | None:
    norm = normalize_code(code)
    if not norm:
        return None
    return db.scalar(select(Department).where(Department.join_code == norm))


def university_named(db: Session, name: str, create: bool = True) -> University | None:
    clean = re.sub(r"\s+", " ", (name or "").strip())[:160]
    if not clean:
        return None
    uni = db.scalar(select(University).where(func.lower(University.name) == clean.lower()))
    if uni or not create:
        return uni
    uni = University(name=clean)
    db.add(uni)
    db.flush()
    return uni


def org_card(db: Session, d: Department) -> dict:
    uni = db.get(University, d.university_id) if d.university_id else None
    return {"id": d.id, "name": d.name, "kind": d.kind, "university": uni.name if uni else None}


# ------------------------------------------------------------------ rules
def can_join(db: Session, st: Student, dept: Department, ignore_invite: int | None = None) -> str | None:
    """None if the employee may join this employer, otherwise the reason (shown to the user)."""
    here = db.scalar(select(Employment).where(Employment.student_id == st.id, Employment.department_id == dept.id))
    if here and here.state == "active":
        return f"You're already on the {dept.name} team."
    if st.kind == "student":
        if dept.kind != "campus":
            return (f"{dept.name} is a business, not a campus employer. Student accounts join employers at their university — "
                    "sign up as a regular employee for other jobs.")
        if st.school_id and dept.university_id and dept.university_id != st.school_id:
            other = db.get(University, dept.university_id)
            mine = db.get(University, st.school_id)
            return f"{dept.name} is at {other.name if other else 'another university'}. You can only join employers at {mine.name if mine else 'your university'}."
        return None
    active = db.scalars(select(Employment).where(Employment.student_id == st.id, Employment.state == "active",
                                                 Employment.department_id != dept.id)).all()
    active = [e for e in active if e.id != ignore_invite]
    if active:
        current = db.get(Department, active[0].department_id)
        return (f"You already work for {current.name}. Regular employees can belong to one employer at a time — "
                f"leave {current.name} first.")
    return None


def add_member(db: Session, st: Student, dept: Department, *, via: str = "code") -> Employment:
    emp = db.scalar(select(Employment).where(Employment.student_id == st.id, Employment.department_id == dept.id))
    hours = min(dept.default_weekly_hours or 20, st.cap)
    if emp:
        emp.state = "active"
        emp.hours = emp.hours or hours
        emp.pay_rate = emp.pay_rate or dept.default_pay_rate
    else:
        emp = Employment(student_id=st.id, department_id=dept.id, hours=hours, state="active", positions=[],
                         pay_rate=dept.default_pay_rate)
        db.add(emp)
    db.flush()
    to_department(db, dept.id, f"{st.name} joined {dept.name} with your join code. Give them a role.", "/d/team",
                  title="New team member")
    log(db, "Coordinator", f"{st.first_name} joined the team" + (" with your join code" if via == "code" else ""),
        department_id=dept.id, level="done", link="/d/team")
    log(db, "Coordinator", f"You joined {dept.name}", student_id=st.id, level="done")
    return emp


def release_future_shifts(db: Session, st: Student, dept: Department) -> int:
    """When someone leaves: their upcoming shifts become open shifts (drafts are dropped)."""
    today = clock.today_local(dept.timezone)
    n = 0
    for sh in db.scalars(select(Shift).where(Shift.student_id == st.id, Shift.department_id == dept.id)).all():
        d = date.fromisoformat(sh.week) + timedelta(days=sh.day)
        if d < today:
            continue
        if sh.status == "draft":
            db.delete(sh)
            continue
        sh.student_id, sh.state = None, "open"
        n += 1
    return n


def leave(db: Session, st: Student, dept: Department, *, by_employer: bool = False) -> int:
    emp = db.scalar(select(Employment).where(Employment.student_id == st.id, Employment.department_id == dept.id,
                                             Employment.state.in_(("active", "invited"))))
    if not emp:
        raise WalkerError("Not on this team.")
    emp.state = "left"
    released = release_future_shifts(db, st, dept)
    if by_employer:
        to_student(db, st.id, f"{dept.name} removed you from the team." + (" Your upcoming shifts were released." if released else ""), "/s")
        log(db, "Coordinator", f"Removed {st.first_name} from the team" + (f" · {released} upcoming shift{'s' if released != 1 else ''} now open" if released else ""),
            department_id=dept.id, kind="human", level="info")
    else:
        to_department(db, dept.id, f"{st.name} left {dept.name}." + (f" {released} upcoming shift{'s are' if released != 1 else ' is'} open again." if released else ""),
                      "/d/schedule")
        log(db, "Coordinator", f"{st.first_name} left the team" + (f" · {released} upcoming shift{'s' if released != 1 else ''} now open" if released else ""),
            department_id=dept.id, level="alert")
    return released


# ------------------------------------------------------------------ public walkers
@walker("public")
def lookup_join_code(ctx: Ctx):
    d = department_by_code(ctx.db, str(ctx.get("code") or ""))
    if not d:
        raise WalkerError("No employer uses that code. Check it with your manager.", 404)
    return org_card(ctx.db, d)


@walker("public")
def list_universities(ctx: Ctx):
    q = str(ctx.get("query") or "").strip().lower()
    stmt = select(University).order_by(University.name).limit(20)
    if q:
        stmt = select(University).where(func.lower(University.name).like(f"%{q}%")).order_by(University.name).limit(20)
    return {"universities": [{"id": u.id, "name": u.name} for u in ctx.db.scalars(stmt)]}


def _tz(value) -> str:
    name = str(value or "").strip()
    try:
        from zoneinfo import ZoneInfo

        ZoneInfo(name)
        return name
    except Exception:
        return config.TIMEZONE


@walker("public")
def register_employer(ctx: Ctx):
    org = re.sub(r"\s+", " ", str(ctx.need("organization")).strip())[:120]
    name = str(ctx.need("name")).strip()[:120]
    if len(org) < 2:
        raise WalkerError("Enter your organization's name.")
    email = check_account(ctx, str(ctx.need("email")), str(ctx.need("password")))
    kind = "campus" if ctx.get("kind") == "campus" else "business"
    uni = None
    if kind == "campus":
        uni = university_named(ctx.db, str(ctx.get("university") or ""))
        if not uni:
            raise WalkerError("Enter your university's name.")
    dept = Department(name=org, kind=kind, type="department" if kind == "campus" else "vendor", university_id=uni.id if uni else None,
                      join_code=new_join_code(ctx.db, org), timezone=_tz(ctx.get("timezone")),
                      default_pay_rate=config.DEFAULT_PAY_RATE, default_weekly_hours=20 if kind == "campus" else 40,
                      description=str(ctx.get("description") or "").strip()[:500],
                      auto_recruit=kind == "campus")
    ctx.db.add(dept)
    ctx.db.flush()
    user = User(email=email, password_hash=hash_password(str(ctx.need("password"))), role="department", name=name, department_id=dept.id)
    ctx.db.add(user)
    log(ctx.db, "Coordinator", f"Welcome to CampusSync · share join code {dept.join_code} with your team", department_id=dept.id, level="done")
    ctx.db.commit()
    return {**session_payload(user), "department_id": dept.id, "join_code": dept.join_code}


@walker("public")
def register_employee(ctx: Ctx):
    name = re.sub(r"\s+", " ", str(ctx.need("name")).strip())[:120]
    if len(name) < 2:
        raise WalkerError("Enter your full name.")
    dept = department_by_code(ctx.db, str(ctx.need("code")))
    if not dept:
        raise WalkerError("No employer uses that join code. Check it with your manager.")
    email = check_account(ctx, str(ctx.need("email")), str(ctx.need("password")))
    if ctx.db.scalar(select(Student).where(Student.email == email)):
        raise WalkerError("An account with this email already exists. Try signing in.")
    kind = "worker" if ctx.get("kind") == "worker" else "student"
    if kind == "student":
        status = "international" if ctx.get("status") == "international" else "domestic"
        limit = config.INTERNATIONAL_WEEKLY_CAP if status == "international" else 20
        st = Student(name=name, email=email, kind="student", school_id=dept.university_id, status=status, weekly_limit=limit,
                     university_id=str(ctx.get("student_number") or "").strip()[:40], desired_hours=0, preferences=[], open_swap_days=[])
    else:
        st = Student(name=name, email=email, kind="worker", status="domestic", weekly_limit=config.WORKER_WEEKLY_LIMIT,
                     desired_hours=0, preferences=[], open_swap_days=[])
    reason = can_join(ctx.db, st, dept)
    if reason:
        raise WalkerError(reason)
    ctx.db.add(st)
    ctx.db.flush()
    user = User(email=email, password_hash=hash_password(str(ctx.need("password"))), role="student", name=name, student_id=st.id)
    ctx.db.add(user)
    add_member(ctx.db, st, dept)
    ctx.db.commit()
    return {**session_payload(user), "student_id": st.id, "employer": org_card(ctx.db, dept)}


# ------------------------------------------------------------------ employee walkers
@walker("student")
def join_employer(ctx: Ctx):
    st = ctx.student
    dept = department_by_code(ctx.db, str(ctx.need("code")))
    if not dept:
        raise WalkerError("No employer uses that join code. Check it with your manager.")
    reason = can_join(ctx.db, st, dept)
    if reason:
        raise WalkerError(reason)
    if st.kind == "student" and not st.school_id:
        st.school_id = dept.university_id
    add_member(ctx.db, st, dept)
    ctx.db.commit()
    return {"ok": True, "employer": org_card(ctx.db, dept)}


@walker("student")
def leave_employer(ctx: Ctx):
    st = ctx.student
    dept = ctx.db.get(Department, ctx.need("department_id", int))
    if not dept:
        raise WalkerError("Employer not found.", 404)
    released = leave(ctx.db, st, dept)
    ctx.db.commit()
    return {"ok": True, "released": released}


@walker("student")
def get_my_employers(ctx: Ctx):
    st = ctx.student
    rows = ctx.db.scalars(select(Employment).where(Employment.student_id == st.id, Employment.state.in_(("active", "invited")))).all()
    from ..models import Position

    out = []
    for e in rows:
        d = ctx.db.get(Department, e.department_id)
        roles = [p.name for p in ctx.db.scalars(select(Position).where(Position.id.in_(e.positions or [])))] if e.positions else []
        out.append({**org_card(ctx.db, d), "state": e.state, "hours": e.hours, "pay_rate": e.pay_rate, "roles": roles})
    uni = ctx.db.get(University, st.school_id) if st.school_id else None
    return {"employers": out, "kind": st.kind, "university": uni.name if uni else None,
            "can_join_more": st.kind == "student" or not any(e.state == "active" for e in rows)}
