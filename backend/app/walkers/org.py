"""Employer walkers: organization settings, join code, positions (roles), team pay/hours, timesheets."""
from __future__ import annotations

from sqlalchemy import select

from .. import clock
from ..agents.rules import Ledger
from ..events import log
from ..models import Department, Employment, Position, Shift, StaffingRequirement, Student, TimeEntry, University
from ..notify import to_student
from ..services import timesheets
from ..services.autopilot import planning_week
from ..timeutil import week_key
from .base import Ctx, WalkerError, walker
from .membership import leave, new_join_code

ROLE_COLORS = ["#a18bff", "#3dd8f5", "#6c8cff", "#f5a3c7", "#7ee0b5", "#ffc46b", "#ff8f7a", "#9fb4ff"]


def _positions(ctx: Ctx, did: int) -> list[Position]:
    return list(ctx.db.scalars(select(Position).where(Position.department_id == did).order_by(Position.id)))


def _org(ctx: Ctx) -> dict:
    d = ctx.department
    uni = ctx.db.get(University, d.university_id) if d.university_id else None
    emps = ctx.db.scalars(select(Employment).where(Employment.department_id == d.id, Employment.state == "active")).all()
    roles = []
    for p in _positions(ctx, d.id):
        roles.append({"id": p.id, "name": p.name, "color": p.color, "members": sum(1 for e in emps if p.id in (e.positions or []))})
    return {
        "id": d.id, "name": d.name, "kind": d.kind, "university": uni.name if uni else None, "join_code": d.join_code,
        "timezone": d.timezone, "default_pay_rate": d.default_pay_rate, "default_weekly_hours": d.default_weekly_hours,
        "state_tax_pct": d.state_tax_pct, "description": d.description, "positions": roles, "team_size": len(emps),
        "policy": {"auto_generate": d.auto_generate, "auto_recruit": d.auto_recruit, "auto_approve_swaps": d.auto_approve_swaps},
    }


@walker("department")
def get_org(ctx: Ctx):
    return _org(ctx)


def _num(ctx: Ctx, key: str, lo: float, hi: float, label: str) -> float | None:
    v = ctx.get(key)
    if v is None or v == "":
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise WalkerError(f"{label} isn't a number.")
    if not lo <= f <= hi:
        raise WalkerError(f"{label} must be between {lo:g} and {hi:g}.")
    return f


@walker("department")
def update_org(ctx: Ctx):
    d = ctx.department
    if ctx.get("name") is not None:
        name = str(ctx.get("name")).strip()[:120]
        if len(name) < 2:
            raise WalkerError("The organization name is too short.")
        d.name = name
    if ctx.get("timezone"):
        from .membership import _tz

        d.timezone = _tz(ctx.get("timezone"))
    if ctx.get("description") is not None:
        d.description = str(ctx.get("description")).strip()[:500]
    rate = _num(ctx, "default_pay_rate", 0, 500, "Pay rate")
    if rate is not None:
        d.default_pay_rate = round(rate, 2)
        if ctx.get("apply_to_team"):
            for e in ctx.db.scalars(select(Employment).where(Employment.department_id == d.id, Employment.state.in_(("active", "invited")))):
                e.pay_rate = d.default_pay_rate
    hours = _num(ctx, "default_weekly_hours", 1, 80, "Weekly hours")
    if hours is not None:
        d.default_weekly_hours = int(hours)
    tax = _num(ctx, "state_tax_pct", 0, 15, "State tax")
    if tax is not None:
        d.state_tax_pct = round(tax, 2)
    log(ctx.db, "Coordinator", "Organization settings updated", kind="human", department_id=d.id)
    ctx.db.commit()
    return _org(ctx)


@walker("department")
def regenerate_join_code(ctx: Ctx):
    d = ctx.department
    d.join_code = new_join_code(ctx.db, d.name)
    log(ctx.db, "Coordinator", f"New join code {d.join_code} · the old one stopped working", kind="human", department_id=d.id)
    ctx.db.commit()
    return _org(ctx)


@walker("department")
def save_position(ctx: Ctx):
    d = ctx.department
    name = str(ctx.need("name")).strip()[:80]
    if len(name) < 2:
        raise WalkerError("Give the role a name.")
    existing = _positions(ctx, d.id)
    pid = ctx.get("id")
    if any(p.name.lower() == name.lower() and p.id != (int(pid) if pid else None) for p in existing):
        raise WalkerError("You already have a role with that name.")
    if pid:
        p = ctx.db.get(Position, int(pid))
        if not p or p.department_id != d.id:
            raise WalkerError("Role not found.", 404)
        p.name = name
        if ctx.get("color"):
            p.color = str(ctx.get("color"))[:9]
    else:
        if len(existing) >= 30:
            raise WalkerError("That's a lot of roles — 30 is the limit.")
        p = Position(department_id=d.id, name=name, color=str(ctx.get("color") or ROLE_COLORS[len(existing) % len(ROLE_COLORS)])[:9])
        ctx.db.add(p)
        log(ctx.db, "Coordinator", f"Added the {name} role", kind="human", department_id=d.id)
    ctx.db.commit()
    return _org(ctx)


@walker("department")
def delete_position(ctx: Ctx):
    d = ctx.department
    p = ctx.db.get(Position, ctx.need("id", int))
    if not p or p.department_id != d.id:
        raise WalkerError("Role not found.", 404)
    for e in ctx.db.scalars(select(Employment).where(Employment.department_id == d.id)):
        if p.id in (e.positions or []):
            e.positions = [x for x in e.positions if x != p.id]
    for r in ctx.db.scalars(select(StaffingRequirement).where(StaffingRequirement.position_id == p.id)):
        r.position_id = None
    for sh in ctx.db.scalars(select(Shift).where(Shift.position_id == p.id)):
        sh.position_id = None
    log(ctx.db, "Coordinator", f"Removed the {p.name} role", kind="human", department_id=d.id)
    ctx.db.delete(p)
    ctx.db.commit()
    return _org(ctx)


# ------------------------------------------------------------------ team
def _member(ctx: Ctx, sid: int) -> tuple[Student, Employment]:
    emp = ctx.db.scalar(select(Employment).where(Employment.student_id == sid, Employment.department_id == ctx.department.id,
                                                 Employment.state.in_(("active", "invited"))))
    if not emp:
        raise WalkerError("This person isn't on your team.", 404)
    return ctx.db.get(Student, sid), emp


@walker("department")
def get_team(ctx: Ctx):
    d = ctx.department
    week = ctx.week if ctx.get("week") else planning_week()
    ledger = Ledger(ctx.db, week)
    roles = {p.id: p for p in _positions(ctx, d.id)}
    rows = []
    since = clock.utcnow()
    for e in ctx.db.scalars(select(Employment).where(Employment.department_id == d.id, Employment.state.in_(("active", "invited")))):
        st = ctx.db.get(Student, e.student_id)
        active = e.state == "active"
        rows.append({
            "student_id": st.id, "name": st.name, "email": st.email, "kind": st.kind, "status": st.status,
            "international": st.is_international, "state": e.state, "hours": e.hours, "pay_rate": e.pay_rate,
            "positions": [pid for pid in (e.positions or []) if pid in roles],
            "scheduled_with_you": ledger.dept_hours(st.id, d.id) if active else 0,
            "can_still_schedule": ledger.hours_left(st.id, d.id) if active else None,
            "calendar": st.calendar_source in ("google", "ics_url", "demo"), "autopilot": st.autopilot,
            "new": active and not (e.positions or []) and bool(roles) and (since - e.created_at).days < 7,
        })
    rows.sort(key=lambda r: (r["state"] != "active", not r["new"], r["name"]))
    return {"week": week, "people": rows, "positions": [{"id": p.id, "name": p.name, "color": p.color} for p in roles.values()],
            "join_code": d.join_code, "kind": d.kind}


@walker("department")
def update_member(ctx: Ctx):
    d = ctx.department
    st, emp = _member(ctx, ctx.need("student_id", int))
    changed = []
    if ctx.get("hours") is not None:
        h = _num(ctx, "hours", 0, 80, "Weekly hours")
        emp.hours = int(h)
        changed.append(f"{emp.hours} hrs/week")
    rate = _num(ctx, "pay_rate", 0, 500, "Pay rate")
    if rate is not None:
        emp.pay_rate = round(rate, 2)
        changed.append(f"${emp.pay_rate:.2f}/hr")
    if ctx.get("positions") is not None:
        valid = {p.id for p in _positions(ctx, d.id)}
        try:
            wanted = sorted({int(x) for x in ctx.get("positions")})
        except (TypeError, ValueError):
            raise WalkerError("Roles aren't valid.")
        if any(x not in valid for x in wanted):
            raise WalkerError("One of those roles doesn't exist.")
        emp.positions = wanted
        names = [p.name for p in _positions(ctx, d.id) if p.id in wanted]
        changed.append("roles: " + (", ".join(names) if names else "none"))
    if changed:
        to_student(ctx.db, st.id, f"{d.name} updated your job: {'; '.join(changed)}.", "/s/profile", title="Job updated")
        log(ctx.db, "Coordinator", f"Updated {st.first_name}: {'; '.join(changed)}", kind="human", department_id=d.id)
    ctx.db.commit()
    return {"ok": True}


@walker("department")
def remove_member(ctx: Ctx):
    st, _ = _member(ctx, ctx.need("student_id", int))
    released = leave(ctx.db, st, ctx.department, by_employer=True)
    ctx.db.commit()
    return {"ok": True, "released": released}


# ------------------------------------------------------------------ timesheets
def _week(ctx: Ctx) -> str:
    if ctx.get("week"):
        try:
            return week_key(str(ctx.get("week")), clock.monday(clock.today_local()))
        except ValueError:
            raise WalkerError("That week isn't a valid date.")
    return clock.current_week(ctx.department.timezone)


@walker("department")
def get_timesheets(ctx: Ctx):
    d = ctx.department
    data = timesheets.employer_week(ctx.db, d, _week(ctx))
    data["current_week"] = clock.current_week(d.timezone)
    return data


@walker("department")
def resolve_time_entry(ctx: Ctx):
    e = ctx.db.get(TimeEntry, ctx.need("entry_id", int))
    if not e:
        raise WalkerError("Entry not found.", 404)
    try:
        timesheets.resolve(ctx.db, ctx.department, e, bool(ctx.get("accept")), str(ctx.get("note") or ""))
    except timesheets.TimesheetError as err:
        raise WalkerError(str(err))
    return {"ok": True, "entry": timesheets.entry_dict(ctx.db, e)}


@walker("department")
def export_timesheets(ctx: Ctx):
    d = ctx.department
    week = _week(ctx)
    safe = "".join(ch if ch.isalnum() else "-" for ch in d.name).strip("-").lower() or "timesheet"
    return {"filename": f"{safe}-timesheet-{week}.csv", "csv": timesheets.employer_csv(ctx.db, d, week)}

