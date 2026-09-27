"""Department walkers.

A department NEVER receives another department's name, shifts or hours — not in data, not in
errors. Hidden information is reduced to: available / unavailable, and "hours you can still assign".
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import func, or_, select

from .. import clock
from ..agents import scheduling
from ..agents import swap as swap_agent
from ..agents.rules import CONFLICT, HOUR_LIMIT, Ledger
from ..agents.trace import Trace
from ..config import PROBE_LIMIT_PER_HOUR
from ..models import (Employment, Position, ProbeLog, ScheduleDraft, Shift, StaffingRequirement, Student, SwapLoop, SwapOffer, SwapRequest)
from ..notify import to_student
from ..services import swaps
from ..timeutil import DAY_LONG, DAY_SHORT, hm, slot_label
from .base import Ctx, WalkerError, walker


# ------------------------------------------------------------------ helpers
def _dated(week: str, day: int, start: int, end: int) -> str:
    """'Mon Sep 28 11:00–15:00' — notifications need the date, not just the weekday."""
    from datetime import date as _d, timedelta as _td

    d = _d.fromisoformat(week) + _td(days=day)
    return f"{DAY_SHORT[day]} {d:%b} {d.day} {hm(start)}–{hm(end)}"


def _team_member(ctx: Ctx, student_id: int, allow_invited: bool = False) -> Student:
    emp = ctx.db.scalar(select(Employment).where(Employment.student_id == student_id, Employment.department_id == ctx.department.id))
    if not emp or (emp.state != "active" and not (allow_invited and emp.state == "invited")):
        raise WalkerError("This person isn't on your team yet.")
    return ctx.db.get(Student, student_id)


def _position_arg(ctx: Ctx) -> int | None:
    pid = ctx.get("position_id")
    if pid in (None, "", 0, "0"):
        return None
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        raise WalkerError("That role isn't valid.")
    p = ctx.db.get(Position, pid)
    if not p or p.department_id != ctx.department.id:
        raise WalkerError("That role doesn't exist.")
    return pid


def _slot_args(ctx: Ctx) -> tuple[int, int, int]:
    day, start, end = ctx.need("day", int), ctx.need("start", int), ctx.need("end", int)
    if not (0 <= day <= 6 and 0 <= start < end <= 24 * 60):
        raise WalkerError("That time slot isn't valid.")
    return day, start, end


def _probe(ctx: Ctx, student_id: int) -> None:
    """Minimum disclosure: rate-limit availability probes so a department can't map a student's week."""
    since = clock.utcnow() - timedelta(hours=1)
    n = ctx.db.scalar(select(func.count(ProbeLog.id)).where(ProbeLog.department_id == ctx.department.id,
                                                            ProbeLog.student_id == student_id, ProbeLog.created_at >= since))
    if n >= PROBE_LIMIT_PER_HOUR:
        raise WalkerError("You've checked this student many times in the last hour. Try again later — this protects their privacy.", 429)
    ctx.db.add(ProbeLog(department_id=ctx.department.id, student_id=student_id))


def _suggestions(ledger: Ledger, sid: int, did: int, reqs, day: int, start: int, end: int) -> list[str]:
    dur = end - start
    options: list[tuple[int, int, int]] = []
    for step in range(60, 8 * 60, 60):  # later the same day
        options.append((day, start + step, end + step))
    for r in sorted(reqs, key=lambda r: ((r.day - day) % 7, r.start)):
        if r.end - r.start >= dur:
            options.append((r.day, r.start, r.start + dur))
    options.append(((day + 1) % 7, start, end))
    out: list[str] = []
    for d, s, e in options:
        if e > 22 * 60 or (d, s) == (day, start):
            continue
        label = f"{DAY_SHORT[d]} {hm(s)}-{hm(e)}"
        if label not in out and ledger.check(sid, did, d, s, e).ok:
            out.append(label)
        if len(out) == 2:
            break
    return out


def _check(ctx: Ctx, ledger: Ledger, student: Student, day: int, start: int, end: int, pid: int | None = None) -> dict:
    """The privacy-safe answer. Exactly these shapes, no extra fields."""
    did = ctx.department.id
    if not ledger.qualified(student.id, did, pid):
        role = ctx.db.get(Position, pid)
        raise WalkerError(f"{student.first_name} doesn't have the {role.name if role else 'required'} role. Add it on the Team page first.")
    v = ledger.check(student.id, did, day, start, end, pid=pid)
    if v.ok:
        return {"available": True, "hours_left": ledger.hours_left(student.id, did)}
    if v.public_reason == CONFLICT:
        reqs = ctx.db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == did)).all()
        return {"available": False, "reason": "schedule_conflict", "suggestions": _suggestions(ledger, student.id, did, reqs, day, start, end)}
    if v.public_reason == HOUR_LIMIT:
        return {"available": False, "reason": "hour_limit", "hours_left": ledger.hours_left(student.id, did)}
    raise WalkerError("This person isn't on your team yet.")


# ------------------------------------------------------------------ coverage
def coverage(ctx: Ctx, week: str, draft: ScheduleDraft | None = None) -> dict:
    dept = ctx.department
    reqs = ctx.db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == dept.id)).all()
    cond = [Shift.department_id == dept.id, Shift.week == week, Shift.student_id.is_not(None)]
    if draft:
        cond.append(or_(Shift.status == "published", Shift.draft_id == draft.id))
    else:
        cond.append(Shift.status == "published")
    shifts = ctx.db.scalars(select(Shift).where(*cond)).all()
    names = {s.id: s.first_name for s in ctx.db.scalars(select(Student).where(Student.id.in_({sh.student_id for sh in shifts})))}
    roles = {p.id: p for p in ctx.db.scalars(select(Position).where(Position.department_id == dept.id))}
    slots: dict[tuple, dict] = {}

    def cell(day: int, start: int, end: int, pid: int | None) -> dict:
        pid = pid if pid in roles else None
        key = (day, start, end, pid or 0)
        if key not in slots:
            p = roles.get(pid) if pid else None
            slots[key] = {"day": day, "start": start, "end": end, "position_id": pid, "role": p.name if p else "",
                          "color": p.color if p else "", "needed": 0, "people": []}
        return slots[key]

    for r in reqs:
        cell(r.day, r.start, r.end, r.position_id)["needed"] += r.headcount
    for sh in shifts:  # shifts outside the staffing plan (manual, open-shift pickups) still show up
        c = cell(sh.day, sh.start, sh.end, sh.position_id)
        c["people"].append({"student_id": sh.student_id, "name": names.get(sh.student_id, ""), "new": sh.status == "draft",
                                "pending": sh.state == "pending_swap"})
    cells = []
    for c in slots.values():
        c["planned"] = c["needed"] > 0
        if not c["planned"]:
            c["needed"] = len(c["people"])  # an extra shift outside the staffing plan counts as covered
        c["assigned"] = len(c["people"])
        c["people"].sort(key=lambda p: p["name"])
        cells.append(c)
    cells.sort(key=lambda c: (c["day"], c["start"]))
    rows = sorted({(c["start"], c["end"]) for c in cells})
    needed = sum(c["needed"] for c in cells)
    filled = sum(min(c["assigned"], c["needed"]) for c in cells)
    team = ctx.db.scalar(select(func.count(Employment.id)).where(Employment.department_id == dept.id, Employment.state == "active"))
    pending = _pending_requests(ctx)
    return {
        "department": {"id": dept.id, "name": dept.name, "type": dept.type, "kind": dept.kind},
        "week": week,
        "rows": [{"start": s, "end": e} for s, e in rows],
        "cells": cells,
        "stats": {"filled": filled, "needed": needed, "understaffed": sum(1 for c in cells if c["assigned"] < c["needed"]),
                  "requests": len(pending), "students": team},
        "requests": pending,
        "has_needs": bool(cells),
        "has_schedule": any(s.status == "published" for s in shifts),
    }


def _pending_requests(ctx: Ctx) -> list[dict]:
    out = []
    reqs = ctx.db.scalars(select(SwapRequest).where(SwapRequest.department_id == ctx.department.id,
                                                    SwapRequest.state.in_(("awaiting_manager",))).order_by(SwapRequest.created_at.desc())).all()
    for r in reqs:
        lp = ctx.db.scalar(select(SwapLoop).where(SwapLoop.request_id == r.id, SwapLoop.state == "proposed"))
        if not lp:
            continue
        who = ctx.db.get(Student, r.requester_id).first_name
        sh = ctx.db.get(Shift, r.shift_id)
        if lp.kind == "loop":
            found = f"The AI found a {lp.size}-person swap."
        elif lp.kind == "direct":
            found = "The AI found a direct swap."
        else:
            found = "The AI found someone to take it."
        out.append({"request_id": r.id, "text": f"{who} wants out of {DAY_LONG[sh.day]}. {found}"})
    return out


@walker("department")
def get_coverage(ctx: Ctx):
    draft = None
    if ctx.get("draft_id"):
        draft = ctx.db.get(ScheduleDraft, int(ctx.get("draft_id")))
        if not draft or draft.department_id != ctx.department.id:
            raise WalkerError("Draft not found.", 404)
    return coverage(ctx, ctx.week, draft)


@walker("department")
def get_slot(ctx: Ctx):
    day, start, end = _slot_args(ctx)
    pid = _position_arg(ctx)
    did = ctx.department.id
    ledger = Ledger(ctx.db, ctx.week)
    needed = sum(r.headcount for r in ctx.db.scalars(select(StaffingRequirement).where(
        StaffingRequirement.department_id == did, StaffingRequirement.day == day,
        StaffingRequirement.start == start, StaffingRequirement.end == end)) if (r.position_id or None) == pid)
    shifts = [sh for sh in ctx.db.scalars(select(Shift).where(Shift.department_id == did, Shift.week == ctx.week, Shift.status == "published",
                                                              Shift.day == day, Shift.start == start, Shift.end == end,
                                                              Shift.student_id.is_not(None))).all() if (sh.position_id or None) == pid]
    people = []
    for sh in shifts:
        st = ctx.db.get(Student, sh.student_id)
        people.append({"student_id": st.id, "name": st.name, "hours_with_you": ledger.dept_hours(st.id, did),
                       "pending": sh.state == "pending_swap"})
    role = ctx.db.get(Position, pid) if pid else None
    return {"label": slot_label(day, start, end) + (f" · {role.name}" if role else ""), "day": day, "start": start, "end": end,
            "position_id": pid, "role": role.name if role else "", "needed": max(needed, len(people)), "people": people}


# ------------------------------------------------------------------ needs
@walker("department")
def get_staffing_needs(ctx: Ctx):
    reqs = ctx.db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == ctx.department.id)
                          .order_by(StaffingRequirement.day, StaffingRequirement.start)).all()
    return {"needs": [{"day": r.day, "start": r.start, "end": r.end, "headcount": r.headcount, "position_id": r.position_id} for r in reqs]}


@walker("department")
def set_staffing_needs(ctx: Ctx):
    needs = ctx.get("needs")
    if not isinstance(needs, list):
        raise WalkerError("Needs must be a list.")
    clean = []
    valid_roles = {p.id for p in ctx.db.scalars(select(Position).where(Position.department_id == ctx.department.id))}
    if len(needs) > 300:
        raise WalkerError("That's too many blocks for one week.")
    for n in needs:
        try:
            day, start, end, head = int(n["day"]), int(n["start"]), int(n["end"]), int(n["headcount"])
            pid = int(n["position_id"]) if n.get("position_id") not in (None, "", 0, "0") else None
        except (KeyError, TypeError, ValueError, AttributeError):
            raise WalkerError("One of the blocks is incomplete.")
        if pid is not None and pid not in valid_roles:
            raise WalkerError("One of the blocks uses a role that doesn't exist.")
        if not (0 <= day <= 6 and 0 <= start < end <= 24 * 60):
            raise WalkerError(f"{DAY_SHORT[day] if 0 <= day <= 6 else 'A'} block ends before it starts.")
        if not 1 <= head <= 50:
            raise WalkerError("Headcount must be between 1 and 50.")
        clean.append((day, start, end, head, pid))
    for r in ctx.db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == ctx.department.id)):
        ctx.db.delete(r)
    for day, start, end, head, pid in clean:
        ctx.db.add(StaffingRequirement(department_id=ctx.department.id, day=day, start=start, end=end, headcount=head, position_id=pid))
    ctx.db.commit()
    return {"ok": True, "count": len(clean)}


# ------------------------------------------------------------------ people
@walker("department")
def get_people(ctx: Ctx):
    did = ctx.department.id
    ledger = Ledger(ctx.db, ctx.week)
    emps = ctx.db.scalars(select(Employment).where(Employment.department_id == did, Employment.state.in_(("active", "invited")))).all()
    rows = []
    for e in emps:
        st = ctx.db.get(Student, e.student_id)
        rows.append({
            "student_id": st.id, "name": st.name, "email": st.email, "status": st.status, "state": e.state,
            "assigned": e.hours,
            "scheduled_with_you": ledger.dept_hours(st.id, did) if e.state == "active" else 0,
            "can_still_schedule": ledger.hours_left(st.id, did) if e.state == "active" else None,
            "calendar": st.calendar_source in ("google", "ics_url", "demo"), "autopilot": st.autopilot,
        })
    rows.sort(key=lambda r: (r["state"] != "active", r["name"]))
    return {"people": rows}


@walker("department")
def search_students(ctx: Ctx):
    """Campus employers can look up students at their own university. Businesses add people with their join code."""
    q = str(ctx.get("query") or "").strip()
    dept = ctx.department
    did = dept.id
    if dept.kind != "campus" or not dept.university_id:
        return {"results": [], "join_code_only": True}
    stmt = select(Student).where(Student.kind == "student", Student.school_id == dept.university_id)
    if q:
        like = f"%{q.lower()}%"
        stmt = stmt.where(or_(func.lower(Student.name).like(like), func.lower(Student.email).like(like), func.lower(Student.university_id).like(like)))
    ledger = Ledger(ctx.db, ctx.week)
    out = []
    for st in ctx.db.scalars(stmt.order_by(Student.name).limit(8)):
        emp = ctx.db.scalar(select(Employment).where(Employment.student_id == st.id, Employment.department_id == did))
        state = emp.state if emp and emp.state in ("active", "invited") else None
        more = ledger.hours_left(st.id, did) if state == "active" else ledger.cap_left(st.id)
        out.append({"student_id": st.id, "name": st.name, "email": st.email, "status": st.status,
                    "can_take_more_hrs": more, "team_state": state})
    return {"results": out}


@walker("department")
def invite_student(ctx: Ctx):
    dept = ctx.department
    did = dept.id
    st = ctx.db.get(Student, ctx.need("student_id", int))
    if not st:
        raise WalkerError("Student not found.", 404)
    if dept.kind != "campus" or st.kind != "student" or st.school_id != dept.university_id:
        raise WalkerError("You can only invite students from your university. Share your join code with anyone else.")
    hours = max(1, min(40, ctx.need("hours", int)))
    emp = ctx.db.scalar(select(Employment).where(Employment.student_id == st.id, Employment.department_id == did))
    if emp and emp.state == "active":
        emp.hours = hours
        ctx.db.commit()
        return {"ok": True, "name": st.name, "updated": True}
    if emp:
        emp.hours, emp.state = hours, "invited"
    else:
        ctx.db.add(Employment(student_id=st.id, department_id=did, hours=hours, state="invited", pay_rate=dept.default_pay_rate))
    to_student(ctx.db, st.id, f"{ctx.department.name} invited you · {hours} hrs/week", "/s")
    ctx.db.commit()
    return {"ok": True, "name": st.name}


# ------------------------------------------------------------------ the blind check (Act 1)
@walker("department")
def check_assignment(ctx: Ctx):
    st = _team_member(ctx, ctx.need("student_id", int))
    day, start, end = _slot_args(ctx)
    pid = _position_arg(ctx)
    _probe(ctx, st.id)
    ledger = Ledger(ctx.db, ctx.week)
    result = _check(ctx, ledger, st, day, start, end, pid)
    ctx.db.commit()
    return result


@walker("department")
def assign_shift(ctx: Ctx):
    st = _team_member(ctx, ctx.need("student_id", int))
    day, start, end = _slot_args(ctx)
    pid = _position_arg(ctx)
    ledger = Ledger(ctx.db, ctx.week)
    result = _check(ctx, ledger, st, day, start, end, pid)
    if not result["available"]:
        return result
    ctx.db.add(Shift(department_id=ctx.department.id, week=ctx.week, day=day, start=start, end=end, position_id=pid,
                     student_id=st.id, state="assigned", status="published", source="manual"))
    to_student(ctx.db, st.id, f"{ctx.department.name} added a shift: {_dated(ctx.week, day, start, end)}.", "/s", title="New shift")
    ctx.db.commit()
    return {"available": True, "assigned": True}


@walker("department")
def find_someone_else(ctx: Ctx):
    day, start, end = _slot_args(ctx)
    pid = _position_arg(ctx)
    did = ctx.department.id
    ledger = Ledger(ctx.db, ctx.week)
    exclude = {int(x) for x in (ctx.get("exclude") or [])}
    ranked = []
    for st in scheduling.team_of(ctx.db, did):
        if st.id in exclude:
            continue
        if ledger.check(st.id, did, day, start, end, pid=pid).ok:
            pref = 0 if set(st.preferences or []) & scheduling.period_of(day, start, end) else 1
            ranked.append((pref, -ledger.hours_left(st.id, did), st))
    ranked.sort(key=lambda t: (t[0], t[1], t[2].name))
    return {"people": [{"student_id": st.id, "name": st.name, "hours_left": -h} for _, h, st in ranked[:3]]}


# ------------------------------------------------------------------ generate / publish
def _draft_payload(ctx: Ctx, draft: ScheduleDraft) -> dict:
    return {"draft_id": draft.id, "state": draft.state, "week": draft.week, "trace": draft.trace, "summary": draft.summary,
            "coverage": coverage(ctx, draft.week, draft)}


@walker("department")
def generate_schedule(ctx: Ctx):
    draft = scheduling.generate(ctx.db, ctx.department, ctx.week)
    return _draft_payload(ctx, draft)


@walker("department")
def get_draft(ctx: Ctx):
    draft = ctx.db.get(ScheduleDraft, ctx.need("draft_id", int))
    if not draft or draft.department_id != ctx.department.id:
        raise WalkerError("Draft not found.", 404)
    return _draft_payload(ctx, draft)


@walker("department")
def publish_schedule(ctx: Ctx):
    draft = ctx.db.get(ScheduleDraft, ctx.need("draft_id", int))
    if not draft or draft.department_id != ctx.department.id or draft.state != "draft":
        raise WalkerError("This draft can't be published.")
    res = scheduling.publish(ctx.db, draft)
    for sid, n in res["notified"].items():
        to_student(ctx.db, sid, f"{ctx.department.name} published this week's schedule: {n} new shift{'s' if n != 1 else ''} for you.", "/s")
    ctx.db.flush()
    # Anything still waiting for a swap gets another look now that the week changed.
    for req in ctx.db.scalars(select(SwapRequest).where(SwapRequest.department_id == ctx.department.id, SwapRequest.state == "searching")).all():
        tr = Trace()
        tr.step("Coordinator", "agent", "new schedule published — looking again")
        swaps.plan(ctx.db, req, tr)
    ctx.db.commit()
    return {"ok": True, "notified": len(res["notified"]), "dropped": res["dropped"]}


@walker("department")
def discard_draft(ctx: Ctx):
    draft = ctx.db.get(ScheduleDraft, ctx.need("draft_id", int))
    if not draft or draft.department_id != ctx.department.id:
        raise WalkerError("Draft not found.", 404)
    if draft.state == "draft":
        scheduling.discard(ctx.db, draft)
        ctx.db.commit()
    return {"ok": True}


# ------------------------------------------------------------------ swaps
@walker("department")
def get_requests(ctx: Ctx):
    reqs = ctx.db.scalars(select(SwapRequest).where(SwapRequest.department_id == ctx.department.id)
                          .order_by(SwapRequest.created_at.desc()).limit(30)).all()
    out = []
    for r in reqs:
        sh = ctx.db.get(Shift, r.shift_id)
        out.append({"request_id": r.id, "requester": ctx.db.get(Student, r.requester_id).first_name, "state": r.state,
                    "shift": slot_label(sh.day, sh.start, sh.end)})
    return {"requests": out}


def _loop_card(ctx: Ctx, loop: SwapLoop, req: SwapRequest) -> dict:
    did = ctx.department.id
    s0 = ctx.db.get(Shift, req.shift_id)
    ledger = Ledger(ctx.db, s0.week)
    moves = swap_agent.describe(ctx.db, loop.moves)
    for m in moves:
        now = ledger.dept_hours(m["student_id"], did)
        gives_h = (ctx.db.get(Shift, m["gives_shift_id"]).hours if m["gives_shift_id"] else 0)
        gets_h = (ctx.db.get(Shift, m["gets_shift_id"]).hours if m["gets_shift_id"] else 0)
        if loop.state == "committed":
            m["hrs_before"], m["hrs_after"] = now - gets_h + gives_h, now
        else:
            m["hrs_before"], m["hrs_after"] = now, now - gives_h + gets_h
    offers = {o.student_id: o for o in ctx.db.scalars(select(SwapOffer).where(SwapOffer.loop_id == loop.id))}
    now = clock.utcnow()
    participants = []
    for m in moves:
        o = offers.get(m["student_id"])
        participants.append({"name": m["name"], "state": o.state if o else None, "auto": o.auto if o else "",
                             "seconds_ago": int((now - (o.responded_at or o.created_at)).total_seconds()) if o else None})
    receiver = moves[1]["name"] if loop.kind == "handoff" else None
    requester = ctx.db.get(Student, req.requester_id).first_name
    return {
        "loop_id": loop.id, "state": loop.state, "kind": loop.kind, "size": loop.size,
        "headline": swap_agent.headline(loop.kind, loop.size, receiver),
        "subline": f"Requested by {requester} · Coverage unchanged",
        "moves": moves, "rationale": loop.rationale, "alternatives": loop.alternatives or [],
        "trace": loop.trace or [],
        "checks": [{"label": "Availability", "kind": "agent"}, {"label": "Hidden conflicts", "kind": "rules"},
                   {"label": "Hour limits", "kind": "rules"}, {"label": "Coverage", "kind": "rules"}],
        "participants": participants,
        "declined_by": ctx.db.get(Student, loop.declined_by).first_name if loop.declined_by else None,
        "decline_reason": loop.decline_reason,
    }


@walker("department")
def get_swap_request(ctx: Ctx):
    swaps.sweep_expired(ctx.db)
    req = ctx.db.get(SwapRequest, ctx.need("request_id", int))
    if not req or req.department_id != ctx.department.id:
        raise WalkerError("Request not found.", 404)
    sh = ctx.db.get(Shift, req.shift_id)
    loops = ctx.db.scalars(select(SwapLoop).where(SwapLoop.request_id == req.id).order_by(SwapLoop.id)).all()
    want = (", ".join(DAY_LONG[d] for d in req.want_days) if req.want_kind == "days"
            else "any other time" if req.want_kind == "any" else "to give it up")
    return {
        "request_id": req.id, "state": req.state,
        "requester": ctx.db.get(Student, req.requester_id).first_name,
        "shift": slot_label(sh.day, sh.start, sh.end), "want": want, "reason": req.reason,
        "trace": req.trace or [],
        "loops": [_loop_card(ctx, lp, req) for lp in loops if lp.state != "invalidated"],
    }


def _loop_for(ctx: Ctx) -> SwapLoop:
    loop = ctx.db.get(SwapLoop, ctx.need("loop_id", int))
    if not loop:
        raise WalkerError("Swap not found.", 404)
    req = ctx.db.get(SwapRequest, loop.request_id)
    if req.department_id != ctx.department.id:
        raise WalkerError("Swap not found.", 404)
    return loop


@walker("department")
def approve_swap(ctx: Ctx):
    loop = _loop_for(ctx)
    try:
        swaps.approve(ctx.db, loop)
    except swaps.SwapError as e:
        raise WalkerError(str(e), 409)
    ctx.db.commit()
    ctx.body["request_id"] = loop.request_id
    return get_swap_request(ctx)


@walker("department")
def reject_swap(ctx: Ctx):
    loop = _loop_for(ctx)
    try:
        swaps.reject(ctx.db, loop)
    except swaps.SwapError as e:
        raise WalkerError(str(e), 409)
    ctx.db.commit()
    ctx.body["request_id"] = loop.request_id
    return get_swap_request(ctx)



@walker("department")
def post_open_shift(ctx: Ctx):
    """Post an unfilled slot as an open shift. Only students who pass every rule are told about it."""
    day, start, end = _slot_args(ctx)
    pid = _position_arg(ctx)
    did = ctx.department.id
    ctx.db.add(Shift(department_id=did, week=ctx.week, day=day, start=start, end=end, student_id=None, state="open", status="published",
                     position_id=pid, source="open"))
    ledger = Ledger(ctx.db, ctx.week)
    notified = 0
    for st in scheduling.team_of(ctx.db, did):
        if ledger.check(st.id, did, day, start, end, pid=pid).ok:
            to_student(ctx.db, st.id, f"{ctx.department.name} posted an open shift you can take: {_dated(ctx.week, day, start, end)}.", "/s",
                       title="Open shift")
            notified += 1
    ctx.db.commit()
    return {"ok": True, "notified": notified}
