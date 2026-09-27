"""Student walkers. A student sees ALL of their own jobs and hours — it's their data."""
from __future__ import annotations

from datetime import date, datetime
from pathlib import Path

from sqlalchemy import select

from .. import clock
from ..agents import availability, recruiting
from ..agents.rules import Ledger
from ..events import log
from ..services import calendar
from .. import clock
from ..models import (BusyBlock, Department, Employment, Position, Shift, Student, SwapLoop, SwapOffer, SwapRequest, TimeEntry)
from ..services import timesheets
from ..notify import to_department
from ..services import swaps
from ..timeutil import DAY_LONG, hm, slot_label
from .base import Ctx, WalkerError, walker

def calendar_info(st) -> dict:
    return {"source": st.calendar_source, "connected": st.calendar_source in ("google", "ics_url", "demo"),
            "label": {"google": "Google Calendar", "ics_url": "Calendar link", "demo": "Demo calendar", "upload": "Uploaded .ics"}.get(st.calendar_source, ""),
            "account": st.google_email if st.calendar_source == "google" else "",
            "writes_shifts": st.calendar_source == "google" and bool(st.google_calendar_id),
            "synced_seconds_ago": int((clock.utcnow() - st.calendar_synced_at).total_seconds()) if st.calendar_synced_at else None,
            "error": st.calendar_error, "google_available": calendar.google_enabled()}


SAMPLE_ICS = Path(__file__).resolve().parent.parent / "sample_calendar.ics"
PREFS = {"Mornings", "Afternoons", "Evenings", "Weekends"}


def _blocks(ctx: Ctx, sid: int) -> list[dict]:
    rows = ctx.db.scalars(select(BusyBlock).where(BusyBlock.student_id == sid).order_by(BusyBlock.day, BusyBlock.start))
    return [{"id": b.id, "day": b.day, "start": b.start, "end": b.end, "title": b.title, "source": b.source} for b in rows]


@walker("student")
def get_availability(ctx: Ctx):
    st = ctx.student
    blocks = _blocks(ctx, st.id)
    return {
        "blocks": blocks,
        "note": st.note,
        "rules": [{"day": b["day"], "start": b["start"], "end": b["end"], "label": b["title"]} for b in blocks if b["source"] == "note"],
        "classes": len({b["title"] for b in blocks if b["source"] == "calendar"}),
        "calendar": calendar_info(st),
        "profile": {"limit": st.cap, "kind": st.kind, "international": st.is_international,
                    "status": st.status, "open_swap_days": st.open_swap_days or [], "autopilot": st.autopilot},
    }


@walker("student")
def import_calendar(ctx: Ctx):
    st = ctx.student
    text = SAMPLE_ICS.read_text(encoding="utf-8") if ctx.get("sample") else str(ctx.get("ics") or "")
    if not text.strip():
        raise WalkerError("That file looks empty. Try exporting your calendar as .ics again.")
    if "BEGIN:VCALENDAR" not in text[:2000].upper():
        raise WalkerError("That doesn't look like a calendar file (.ics).")
    blocks = calendar.blocks_from_ics_text(text)
    calendar.replace_calendar_blocks(ctx.db, st, blocks)
    st.calendar_source = "upload" if not ctx.get("sample") else "upload"
    st.calendar_synced_at = clock.utcnow()
    log(ctx.db, "Availability Agent", f"Imported your calendar · {len(blocks)} events", student_id=st.id)
    ctx.db.commit()
    calendar.detect_disruptions(ctx.db, st)
    titles = {b["title"] for b in blocks}
    return {"count": len(titles), "blocks": _blocks(ctx, st.id)}


@walker("student")
def parse_availability_note(ctx: Ctx):
    """Availability Agent (AI): free text -> structured rules, stored as unavailable time."""
    st = ctx.student
    note = str(ctx.get("note") or "")[:500]
    rules, used_ai = availability.parse_note(note)
    st.note = note
    for b in ctx.db.scalars(select(BusyBlock).where(BusyBlock.student_id == st.id, BusyBlock.source == "note")):
        ctx.db.delete(b)
    for r in rules:
        ctx.db.add(BusyBlock(student_id=st.id, day=r["day"], start=r["start"], end=r["end"], title=r["label"], source="note"))
    if rules:
        log(ctx.db, "Availability Agent", f"Understood your note · {len(rules)} rule{'s' if len(rules) != 1 else ''}", student_id=st.id)
    ctx.db.commit()
    calendar.detect_disruptions(ctx.db, st)
    return {"rules": rules, "ai": used_ai, "blocks": _blocks(ctx, st.id)}


@walker("student")
def remove_availability_rule(ctx: Ctx):
    st = ctx.student
    day, start, end = ctx.need("day", int), ctx.need("start", int), ctx.need("end", int)
    for b in ctx.db.scalars(select(BusyBlock).where(BusyBlock.student_id == st.id, BusyBlock.source == "note",
                                                    BusyBlock.day == day, BusyBlock.start == start, BusyBlock.end == end)):
        ctx.db.delete(b)
    ctx.db.commit()
    return {"blocks": _blocks(ctx, st.id)}


@walker("student")
def update_profile(ctx: Ctx):
    st = ctx.student
    if ctx.get("desired_hours") is not None:
        st.desired_hours = max(0, min(st.cap, int(ctx.get("desired_hours"))))
    if ctx.get("preferences") is not None:
        st.preferences = [p for p in ctx.get("preferences") if p in PREFS]
    if ctx.get("open_swap_days") is not None:
        st.open_swap_days = sorted({int(d) for d in ctx.get("open_swap_days") if 0 <= int(d) <= 6})
    if ctx.get("autopilot") is not None:
        st.autopilot = bool(ctx.get("autopilot"))
    if ctx.get("weekly_limit") is not None and not st.is_international:
        st.weekly_limit = max(1, min(40 if st.kind == "student" else 80, int(ctx.get("weekly_limit"))))
    ctx.db.commit()
    return {"ok": True}


def _role_names(ctx: Ctx, ids) -> dict[int, str]:
    ids = {i for i in ids if i}
    if not ids:
        return {}
    return {p.id: p.name for p in ctx.db.scalars(select(Position).where(Position.id.in_(ids)))}


def _shift_date(sh: Shift):
    from datetime import date, timedelta

    return date.fromisoformat(sh.week) + timedelta(days=sh.day)


@walker("student")
def get_student_home(ctx: Ctx):
    st = ctx.student
    swaps.sweep_expired(ctx.db)
    week = ctx.week
    ledger = Ledger(ctx.db, week)
    emps = ctx.db.scalars(select(Employment).where(Employment.student_id == st.id)).all()
    depts = {d.id: d for d in ctx.db.scalars(select(Department))}
    active = [e for e in emps if e.state == "active"]
    total = ledger.total_hours(st.id)
    by_job = sorted(
        [{"department": depts[e.department_id].name, "hours": ledger.dept_hours(st.id, e.department_id)} for e in active],
        key=lambda j: -j["hours"],
    )
    shifts = ctx.db.scalars(select(Shift).where(Shift.student_id == st.id, Shift.week == week, Shift.status == "published")
                            .order_by(Shift.day, Shift.start)).all()
    roles = _role_names(ctx, [s.position_id for s in shifts] + [p for e in active for p in (e.positions or [])])
    rate = {e.department_id: e.pay_rate for e in active}
    offers = ctx.db.scalars(select(SwapOffer).where(SwapOffer.student_id == st.id, SwapOffer.state == "waiting")).all()
    now = clock.utcnow()
    reqs = ctx.db.scalars(select(SwapRequest).where(SwapRequest.requester_id == st.id, SwapRequest.state.in_(swaps.ACTIVE_REQUEST_STATES))).all()
    assigned_total = sum(e.hours for e in active)
    worked = set(ctx.db.scalars(select(TimeEntry.shift_id).where(TimeEntry.student_id == st.id, TimeEntry.shift_id.in_([s.id for s in shifts]))))

    # Next shift from now on, across weeks
    upcoming = None
    this_week = clock.monday(clock.today_local())
    for sh in ctx.db.scalars(select(Shift).where(Shift.student_id == st.id, Shift.status == "published",
                                                 Shift.week >= this_week.isoformat()).order_by(Shift.week, Shift.day, Shift.start)).all():
        d = depts[sh.department_id]
        start = clock.slot_datetime(sh.week, sh.day, sh.start, d.timezone)
        end = clock.slot_datetime(sh.week, sh.day, sh.end, d.timezone)
        if clock.to_utc_naive(end) <= now:
            continue
        upcoming = {"id": sh.id, "date": _shift_date(sh).isoformat(), "day": sh.day, "start": sh.start, "end": sh.end,
                    "department": d.name, "role": _role_names(ctx, [sh.position_id]).get(sh.position_id, "") if sh.position_id else "",
                    "starts_in_seconds": int((clock.to_utc_naive(start) - now).total_seconds()),
                    "in_progress": clock.to_utc_naive(start) <= now}
        break
    ts = timesheets.employee_timesheet(ctx.db, st)
    return {
        "student": {"name": st.name, "first_name": st.first_name, "status": st.status, "autopilot": st.autopilot,
                    "kind": st.kind, "international": st.is_international},
        "calendar": calendar_info(st),
        "week": week,
        "hours": {"scheduled": total, "limit": st.cap, "left": max(0, st.cap - total), "by_job": by_job},
        "pay": {"projected_gross": round(sum(s.hours * rate.get(s.department_id, 0) for s in shifts), 2)},
        "jobs": [{"department_id": e.department_id, "department": depts[e.department_id].name, "hours": e.hours, "state": e.state,
                  "pay_rate": e.pay_rate, "roles": [roles[p] for p in (e.positions or []) if p in roles]} for e in active],
        "invites": [{"employment_id": e.id, "department": depts[e.department_id].name, "hours": e.hours,
                     "total_assigned": assigned_total + e.hours, "limit": st.cap} for e in emps if e.state == "invited"],
        "offers": [{"offer_id": o.id, "expires_in_seconds": max(0, int((o.expires_at - now).total_seconds()))} for o in offers],
        "requests": [{"request_id": r.id, "state": r.state} for r in reqs],
        "shifts": [{"id": s.id, "day": s.day, "date": _shift_date(s).isoformat(), "start": s.start, "end": s.end,
                    "department": depts[s.department_id].name, "role": roles.get(s.position_id, "") if s.position_id else "",
                    "state": s.state, "hours": s.hours, "worked": s.id in worked} for s in shifts],
        "next_shift": upcoming,
        "timesheet": {"pending_count": ts["pending_count"], "pending_hours": ts["pending_hours"], "next_review": ts["next_review"],
                      "review_today": ts["review_today"], "disputed_count": ts["disputed_count"]},
    }


@walker("student")
def respond_invite(ctx: Ctx):
    st = ctx.student
    emp = ctx.db.get(Employment, ctx.need("employment_id", int))
    if not emp or emp.student_id != st.id or emp.state != "invited":
        raise WalkerError("This invite is no longer open.")
    dept = ctx.db.get(Department, emp.department_id)
    if ctx.get("accept"):
        from .membership import can_join

        reason = can_join(ctx.db, st, dept, ignore_invite=emp.id)
        if reason:
            raise WalkerError(reason)
        emp.state = "active"
        log(ctx.db, "Recruiting Agent", f"{st.first_name} accepted your invite", kind="human", department_id=dept.id, level="done")
        recruiting.on_invite_answer(ctx.db, st, dept, True)
    else:
        emp.state = "declined"
        to_department(ctx.db, dept.id, f"{st.first_name} declined your invite.", "/d/team")
        recruiting.on_invite_answer(ctx.db, st, dept, False)
    ctx.db.commit()
    return {"ok": True, "department": dept.name}


@walker("student")
def request_swap(ctx: Ctx):
    st = ctx.student
    try:
        req = swaps.create_request(ctx.db, st, ctx.need("shift_id", int), str(ctx.get("want_kind") or "days"),
                                   list(ctx.get("want_days") or []), str(ctx.get("reason") or ""))
    except swaps.SwapError as e:
        raise WalkerError(str(e))
    return _request_status(ctx, req)


@walker("student")
def get_my_request(ctx: Ctx):
    st = ctx.student
    req = ctx.db.get(SwapRequest, ctx.need("request_id", int))
    if not req or req.requester_id != st.id:
        raise WalkerError("Request not found.", 404)
    swaps.sweep_expired(ctx.db)
    return _request_status(ctx, req)


@walker("student")
def cancel_request(ctx: Ctx):
    st = ctx.student
    req = ctx.db.get(SwapRequest, ctx.need("request_id", int))
    if not req or req.requester_id != st.id or req.state not in ("searching", "awaiting_manager"):
        raise WalkerError("This request can't be cancelled now.")
    for lp in ctx.db.scalars(select(SwapLoop).where(SwapLoop.request_id == req.id, SwapLoop.state == "proposed")):
        lp.state = "rejected"
    req.state = "cancelled"
    ctx.db.get(Shift, req.shift_id).state = "assigned"
    ctx.db.commit()
    return {"ok": True}


def _request_status(ctx: Ctx, req: SwapRequest) -> dict:
    sh = ctx.db.get(Shift, req.shift_id)
    dept = ctx.db.get(Department, req.department_id)
    my_offer = None
    if req.state == "offered":
        lp = ctx.db.scalar(select(SwapLoop).where(SwapLoop.request_id == req.id, SwapLoop.state == "approved"))
        if lp:
            o = ctx.db.scalar(select(SwapOffer).where(SwapOffer.loop_id == lp.id, SwapOffer.student_id == req.requester_id))
            my_offer = {"offer_id": o.id, "state": o.state} if o else None
    messages = {
        "awaiting_manager": ("Found a swap. Waiting for your manager to approve.", "waiting"),
        "offered": ("Your manager approved. Waiting for everyone to say yes.", "waiting"),
        "searching": ("No swap available yet. We'll keep looking and notify you.", "searching"),
        "no_option": ("No swap available yet. We'll keep looking and notify you.", "searching"),
        "completed": ("Swap complete. Your schedule is updated.", "confirmed"),
        "rejected": ("Your manager didn't approve this swap. Your shift stays as it was.", "blocked"),
        "cancelled": ("You cancelled this request.", "neutral"),
    }
    msg, chip = messages.get(req.state, ("", "neutral"))
    want = (", ".join(DAY_LONG[d] for d in req.want_days) if req.want_kind == "days"
            else "Any other time" if req.want_kind == "any" else "Give it up")
    return {"request_id": req.id, "state": req.state, "message": msg, "chip": chip, "trace": req.trace or [],
            "shift": f"{slot_label(sh.day, sh.start, sh.end)}", "department": dept.name, "want": want, "offer": my_offer}


@walker("student")
def get_offer(ctx: Ctx):
    st = ctx.student
    swaps.sweep_expired(ctx.db)
    offer = ctx.db.get(SwapOffer, ctx.need("offer_id", int))
    if not offer or offer.student_id != st.id:
        raise WalkerError("Offer not found.", 404)
    loop = ctx.db.get(SwapLoop, offer.loop_id)
    req = ctx.db.get(SwapRequest, loop.request_id)
    dept = ctx.db.get(Department, req.department_id)
    move = next(m for m in loop.moves if m["student_id"] == st.id)
    gives = ctx.db.get(Shift, move["gives_shift_id"]) if move.get("gives_shift_id") else None
    gets = ctx.db.get(Shift, move["gets_shift_id"]) if move.get("gets_shift_id") else None
    anchor = gets or gives
    ledger = Ledger(ctx.db, anchor.week)
    now_total = ledger.total_hours(st.id)
    if loop.state == "committed":
        after, before = now_total, now_total - (gets.hours if gets else 0) + (gives.hours if gives else 0)
    else:
        before, after = now_total, now_total - (gives.hours if gives else 0) + (gets.hours if gets else 0)
    offers = {o.student_id: o for o in ctx.db.scalars(select(SwapOffer).where(SwapOffer.loop_id == loop.id))}
    circle = []
    for m in loop.moves:
        o = offers.get(m["student_id"])
        s = ctx.db.get(Student, m["student_id"])
        gs = ctx.db.get(Shift, m["gets_shift_id"]) if m.get("gets_shift_id") else None
        circle.append({"name": s.first_name, "me": s.id == st.id, "state": o.state if o else "waiting",
                       "gets": slot_label(gs.day, gs.start, gs.end) if gs else None})
    others = [c for c in circle if not c["me"]]
    status = "confirmed" if loop.state == "committed" else ("closed" if loop.state in ("declined", "invalidated", "rejected") else offer.state)
    return {
        "offer_id": offer.id, "state": offer.state, "status": status, "kind": loop.kind,
        "department": dept.name,
        "gets": slot_label(gets.day, gets.start, gets.end) if gets else None,
        "gets_day": DAY_LONG[gets.day] if gets else None,
        "gives": slot_label(gives.day, gives.start, gives.end) if gives else None,
        "hours_before": before, "hours_after": after,
        "circle": circle, "others": len(others), "others_accepted": sum(1 for c in others if c["state"] == "accepted"),
        "expires_in_seconds": max(0, int((offer.expires_at - clock.utcnow()).total_seconds())),
        "rationale": loop.rationale,
    }


@walker("student")
def respond_offer(ctx: Ctx):
    st = ctx.student
    offer = ctx.db.get(SwapOffer, ctx.need("offer_id", int))
    if not offer or offer.student_id != st.id:
        raise WalkerError("Offer not found.", 404)
    try:
        swaps.respond(ctx.db, offer, bool(ctx.get("accept")), str(ctx.get("reason_chip") or ""), str(ctx.get("reason_text") or ""))
    except swaps.SwapError as e:
        raise WalkerError(str(e))
    ctx.db.commit()
    return get_offer(ctx)


def fmt_slot(day: int, start: int, end: int) -> str:
    return f"{DAY_LONG[day]} {hm(start)}–{hm(end)}"


@walker("student")
def list_my_requests(ctx: Ctx):
    st = ctx.student
    swaps.sweep_expired(ctx.db)
    reqs = ctx.db.scalars(select(SwapRequest).where(SwapRequest.requester_id == st.id)
                          .order_by(SwapRequest.created_at.desc()).limit(20)).all()
    return {"requests": [_request_status(ctx, r) for r in reqs]}


def _open_shifts(ctx: Ctx, st, week: str, ledger: Ledger) -> list[dict]:
    dept_ids = [e.department_id for e in ctx.db.scalars(select(Employment).where(Employment.student_id == st.id, Employment.state == "active"))]
    if not dept_ids:
        return []
    rows = ctx.db.scalars(select(Shift).where(Shift.department_id.in_(dept_ids), Shift.week == week, Shift.status == "published",
                                              Shift.student_id.is_(None), Shift.state == "open").order_by(Shift.day, Shift.start)).all()
    out = []
    for s in rows:
        if ledger.check(st.id, s.department_id, s.day, s.start, s.end).ok:
            out.append({"id": s.id, "day": s.day, "start": s.start, "end": s.end, "department": ctx.db.get(Department, s.department_id).name})
    return out


@walker("student")
def get_open_shifts(ctx: Ctx):
    st = ctx.student
    return {"shifts": _open_shifts(ctx, st, ctx.week, Ledger(ctx.db, ctx.week))}


@walker("student")
def claim_open_shift(ctx: Ctx):
    st = ctx.student
    sh = ctx.db.get(Shift, ctx.need("shift_id", int))
    if not sh or sh.student_id is not None or sh.state != "open":
        raise WalkerError("Someone already took this shift.")
    v = Ledger(ctx.db, sh.week).check(st.id, sh.department_id, sh.day, sh.start, sh.end)
    if not v.ok:
        raise WalkerError("This shift would put you over a limit or clash with your schedule.")
    sh.student_id, sh.state = st.id, "assigned"
    to_department(ctx.db, sh.department_id, f"{st.first_name} picked up the open shift {slot_label(sh.day, sh.start, sh.end)}.", "/d")
    ctx.db.commit()
    return {"ok": True}


@walker("student")
def get_student_inbox(ctx: Ctx):
    """Requests screen: everything that asks something of the student, plus what they asked for."""
    st = ctx.student
    swaps.sweep_expired(ctx.db)
    now = clock.utcnow()
    offers = []
    for o in ctx.db.scalars(select(SwapOffer).where(SwapOffer.student_id == st.id).order_by(SwapOffer.id.desc()).limit(30)):
        loop = ctx.db.get(SwapLoop, o.loop_id)
        move = next((m for m in loop.moves if m["student_id"] == st.id), None)
        if not move:
            continue
        gives = ctx.db.get(Shift, move["gives_shift_id"]) if move.get("gives_shift_id") else None
        gets = ctx.db.get(Shift, move["gets_shift_id"]) if move.get("gets_shift_id") else None
        dept = ctx.db.get(Department, (gets or gives).department_id)
        offers.append({
            "offer_id": o.id, "state": o.state, "auto": o.auto,
            "loop_state": loop.state, "size": loop.size, "kind": loop.kind, "department": dept.name,
            "gets": slot_label(gets.day, gets.start, gets.end) if gets else None,
            "gives": slot_label(gives.day, gives.start, gives.end) if gives else None,
            "seconds_ago": int((now - o.created_at).total_seconds()),
            "expires_in_seconds": max(0, int((o.expires_at - now).total_seconds())),
        })
    depts = {d.id: d.name for d in ctx.db.scalars(select(Department))}
    invites = [{"employment_id": e.id, "department": depts[e.department_id], "hours": e.hours}
               for e in ctx.db.scalars(select(Employment).where(Employment.student_id == st.id, Employment.state == "invited"))]
    reqs = ctx.db.scalars(select(SwapRequest).where(SwapRequest.requester_id == st.id).order_by(SwapRequest.created_at.desc()).limit(20)).all()
    return {"offers": offers, "invites": invites, "requests": [{**_request_status(ctx, r), "origin": r.origin} for r in reqs]}
