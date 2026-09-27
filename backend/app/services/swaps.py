"""Swap workflow + Commit Service.

Request -> Swap Agent plans -> manager approves -> every participant accepts -> commit (atomic).
Anyone declines or an offer expires -> nothing changes, the decliner is excluded, the Swap Agent re-plans.
No half-swaps, ever: all moves are applied in a single transaction, after re-validation.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import clock
from ..agents import swap as swap_agent
from ..agents.rules import Ledger
from ..agents.trace import Trace
from ..config import OFFER_TTL_HOURS
from ..events import log
from ..models import Department, Shift, Student, SwapLoop, SwapOffer, SwapRequest
from ..notify import to_department, to_student
from ..timeutil import DAY_LONG, DAY_SHORT

ACTIVE_REQUEST_STATES = ("searching", "awaiting_manager", "offered")


class SwapError(Exception):
    pass


def _name(db: Session, sid: int) -> str:
    return db.get(Student, sid).first_name


# ------------------------------------------------------------------ request + plan
def create_request(db: Session, student: Student, shift_id: int, want_kind: str, want_days: list[int], reason: str,
                   origin: str = "student") -> SwapRequest:
    sh = db.get(Shift, shift_id)
    if not sh or sh.student_id != student.id or sh.status != "published":
        raise SwapError("That shift isn't yours to swap.")
    active = db.scalar(select(SwapRequest).where(SwapRequest.shift_id == sh.id, SwapRequest.state.in_(ACTIVE_REQUEST_STATES)))
    if active:
        raise SwapError("You already have a request open for this shift.")
    if sh.state == "pending_swap":
        raise SwapError("This shift is already part of a pending swap.")
    if want_kind not in ("days", "any", "give_up"):
        raise SwapError("Choose what you'd like instead.")
    days = sorted({int(d) for d in (want_days or []) if 0 <= int(d) <= 6})
    if want_kind == "days" and not days:
        raise SwapError("Pick at least one day.")
    req = SwapRequest(department_id=sh.department_id, requester_id=student.id, shift_id=sh.id,
                      want_kind=want_kind, want_days=days, reason=(reason or "")[:300], state="searching", origin=origin)
    db.add(req)
    sh.state = "pending_swap"
    db.flush()
    plan(db, req, Trace())
    db.commit()
    return req


def plan(db: Session, req: SwapRequest, tr: Trace) -> SwapLoop | None:
    result = swap_agent.search(db, req)
    if not result.candidates and req.origin == "calendar" and req.want_kind != "give_up":
        # Nobody can trade — fall back to finding someone who can simply take the shift.
        tr.step("Swap Agent", "agent", "no trade possible · looking for someone to take the shift", status="blocked")
        kind, req.want_kind = req.want_kind, "give_up"
        result = swap_agent.search(db, req)
        if not result.candidates:
            req.want_kind = kind
    if req.want_kind == "give_up":
        n = result.found.get(2, 0)
        tr.step("Swap Agent", "agent", "looking for someone to take the shift")
        tr.step("Swap Agent", "agent", f"found {n} option{'s' if n != 1 else ''}" if n else "no one can take it yet",
                status="done" if n else "blocked")
    else:
        tr.step("Swap Agent", "agent", "looking for a direct swap")
        tr.step("Swap Agent", "agent", f"direct swap · {'found ' + str(result.found[2]) if result.found[2] else 'none found'}",
                status="done" if result.found[2] else "blocked")
        if not result.found[2]:
            tr.step("Swap Agent", "agent", f"searching 3-person loops · {'found ' + str(result.found[3]) if result.found[3] else 'none found'}",
                    status="done" if result.found[3] else "blocked")
            if not result.found[3]:
                tr.step("Swap Agent", "agent", f"searching 4-person loops · {'found ' + str(result.found[4]) if result.found[4] else 'none found'}",
                        status="done" if result.found[4] else "blocked")
    rejected = result.rejected_conflict
    tr.step("Conflict Agent", "rules",
            f"checking hidden conflicts · removed {rejected} option{'s' if rejected != 1 else ''}" if rejected else "checking hidden conflicts · clear",
            status="blocked" if rejected else "done")
    tr.step("Compliance Checker", "rules",
            f"checking hour limits · removed {result.rejected_hours}" if result.rejected_hours else "checking hour limits · all within limits",
            status="blocked" if result.rejected_hours else "done")

    if not result.candidates:
        tr.final("No option found", ok=False)
        req.state = "searching"
        req.trace = tr.rows
        log(db, "Swap Agent", f"No swap for {_name(db, req.requester_id)} yet — will retry when the week changes",
            department_id=req.department_id, level="alert", link=f"/d/requests/{req.id}")
        return None

    best = result.candidates[0]
    why, used_ai = swap_agent.rationale(db, req, best)
    tr.step("Explainer", "agent", "wrote the approval card", ai=used_ai)
    tr.final("Ready for review")
    alternatives = [
        {"summary": swap_agent.summarize(db, c), "why_lower": _why_lower(best, c)} for c in result.candidates[1:4]
    ]
    loop = SwapLoop(request_id=req.id, moves=best.moves, size=best.size, kind=best.kind, score=0,
                    rationale=why, alternatives=alternatives, trace=tr.rows, state="proposed")
    db.add(loop)
    req.state = "awaiting_manager"
    req.trace = tr.rows
    db.flush()
    s0 = db.get(Shift, req.shift_id)
    word = "swap" if best.kind != "handoff" else "hand-off"
    size_word = f"a {best.size}-person {word}" if best.kind == "loop" else f"a {word}" if best.kind == "handoff" else "a direct swap"
    to_department(db, req.department_id,
                  f"{_name(db, req.requester_id)} wants out of {DAY_LONG[s0.day]}. The AI found {size_word}.",
                  f"/d/requests/{req.id}")
    log(db, "Swap Agent", f"Found {size_word} for {_name(db, req.requester_id)}'s {DAY_LONG[s0.day]} shift · awaiting your approval",
        department_id=req.department_id, level="action", link=f"/d/requests/{req.id}")
    log(db, "Swap Agent", f"Found {size_word} for your {DAY_LONG[s0.day]} shift · waiting for your manager",
        student_id=req.requester_id, level="info")
    dept = db.get(Department, req.department_id)
    if dept and dept.auto_approve_swaps and best.kind != "handoff":
        log(db, "Coordinator", "Low-risk swap (hours and coverage unchanged) — auto-approved by your policy",
            department_id=req.department_id, level="info", link=f"/d/requests/{req.id}")
        db.flush()
        approve(db, loop)
    return loop


def _why_lower(best, other) -> str:
    if other.size > best.size:
        extra = other.size - best.size
        words = {1: "one", 2: "two", 3: "three"}
        return f"Changes {words.get(extra, extra)} more {'person' if extra == 1 else 'people'}'s week."
    if other.score and best.score and other.score[1] > best.score[1]:
        return "Fewer people have said they're open to these days."
    return "Asks more people to change the time of day they work."


# ------------------------------------------------------------------ manager decisions
def approve(db: Session, loop: SwapLoop) -> SwapLoop:
    if loop.state != "proposed":
        raise SwapError("This option is no longer waiting for approval.")
    req = db.get(SwapRequest, loop.request_id)
    # Re-validate: the week may have changed since the loop was proposed.
    shifts = {sid: db.get(Shift, sid) for m in loop.moves for sid in (m.get("gives_shift_id"), m.get("gets_shift_id")) if sid}
    s0 = db.get(Shift, req.shift_id)
    stale = (
        any(m.get("gives_shift_id") and shifts[m["gives_shift_id"]].student_id != m["student_id"] for m in loop.moves)
        or any(sh.state == "pending_swap" and sid != req.shift_id for sid, sh in shifts.items())
        or swap_agent.validate_moves(Ledger(db, s0.week), loop.moves, shifts)
    )
    if stale:
        loop.state = "invalidated"
        tr = Trace()
        tr.step("Coordinator", "agent", "the week changed since this option was found — re-planning")
        plan(db, req, tr)
        db.commit()
        raise SwapError("The schedule changed since this option was found. The Swap Agent found a fresh option.")

    loop.state = "approved"
    req.state = "offered"
    log(db, "Coordinator", "Approved · sending offers (autopilot answers where it can)", kind="human",
        department_id=req.department_id, level="info", link=f"/d/requests/{req.id}")
    previous_accepts = _previous_accepted_moves(db, req, exclude_loop=loop.id)
    expires = clock.utcnow() + timedelta(hours=OFFER_TTL_HOURS)
    for m in loop.moves:
        st = db.get(Student, m["student_id"])
        gets = shifts.get(m.get("gets_shift_id")) if m.get("gets_shift_id") else None
        gives = shifts.get(m.get("gives_shift_id")) if m.get("gives_shift_id") else None
        signature = _move_signature(gives, gets)
        offer = SwapOffer(loop_id=loop.id, student_id=st.id, state="waiting", expires_at=expires)
        if signature in previous_accepts.get(st.id, set()):
            offer.state, offer.auto, offer.responded_at = "accepted", "carried", clock.utcnow()
        elif gets and st.autopilot and gets.day in (st.open_swap_days or []):
            offer.state, offer.auto, offer.responded_at = "accepted", "auto_accept", clock.utcnow()
        elif (gets and st.autopilot and st.id == req.requester_id
              and (req.want_kind == "any" or gets.day in (req.want_days or []))):
            offer.state, offer.auto, offer.responded_at = "accepted", "auto_accept", clock.utcnow()
        elif not gets and st.autopilot and req.origin == "calendar" and st.id == req.requester_id:
            offer.state, offer.auto, offer.responded_at = "accepted", "auto_accept", clock.utcnow()
        if offer.auto:
            log(db, "Autopilot", f"Accepted for you: {'take ' + _slot(gets) if gets else 'hand off ' + _slot(gives)}"
                + (f", give up {_slot(gives)}" if gets and gives else ""), student_id=st.id, level="done")
        db.add(offer)
        db.flush()
        for sh in (gives, gets):
            if sh:
                sh.state = "pending_swap"
        if offer.state == "waiting":
            if gets and gives:
                text = f"You've been offered a swap: take {_slot(gets)}, give up {_slot(gives)}."
            elif gets:
                text = f"You've been offered an extra shift: {_slot(gets)}."
            else:
                text = f"Your hand-off of {_slot(gives)} was approved. Please confirm."
            to_student(db, st.id, text, f"/s/offer/{offer.id}")
    db.flush()
    maybe_commit(db, loop)
    return loop


def reject(db: Session, loop: SwapLoop) -> None:
    if loop.state != "proposed":
        raise SwapError("This option is no longer waiting for approval.")
    req = db.get(SwapRequest, loop.request_id)
    loop.state = "rejected"
    req.state = "rejected"
    s0 = db.get(Shift, req.shift_id)
    s0.state = "assigned"
    to_student(db, req.requester_id, f"Your manager didn't approve the swap for {_slot(s0)}. Your shift stays as it was.", "/s")


# ------------------------------------------------------------------ student decisions
def respond(db: Session, offer: SwapOffer, accept: bool, chip: str = "", text: str = "") -> None:
    if offer.state != "waiting":
        raise SwapError("This offer is no longer open.")
    loop = db.get(SwapLoop, offer.loop_id)
    if loop.state != "approved":
        raise SwapError("This swap is no longer active.")
    offer.responded_at = clock.utcnow()
    if accept:
        offer.state = "accepted"
        db.flush()
        maybe_commit(db, loop)
        return
    offer.state = "declined"
    offer.reason_chip = (chip or "")[:60]
    offer.reason_text = (text or "")[:300]
    decline_loop(db, loop, offer.student_id, offer.reason_text or offer.reason_chip)


def decline_loop(db: Session, loop: SwapLoop, student_id: int, reason: str, expired: bool = False) -> SwapLoop | None:
    req = db.get(SwapRequest, loop.request_id)
    loop.state = "declined"
    loop.declined_by = student_id
    loop.decline_reason = reason or ""
    for o in db.scalars(select(SwapOffer).where(SwapOffer.loop_id == loop.id, SwapOffer.state == "waiting")):
        o.state = "cancelled"
    _release_shifts(db, loop, keep=req.shift_id)
    name = _name(db, student_id)
    req.excluded_student_ids = sorted(set(req.excluded_student_ids or []) | {student_id})
    req.feedback = (req.feedback or []) + [{"name": name, "reason": reason or ("offer expired" if expired else "")}]
    what = "didn't respond in time" if expired else "declined"
    quoted = f' — "{reason}"' if reason and not expired else ""
    to_department(db, req.department_id, f"{name} {what}{quoted}. The Swap Agent is looking for another option.", f"/d/requests/{req.id}")
    log(db, "Coordinator", f"{name} {what} — Swap Agent re-planning without them", department_id=req.department_id,
        level="alert", link=f"/d/requests/{req.id}")
    tr = Trace()
    tr.step("Coordinator", "agent", f"{name} {what} — re-planning without them")
    new_loop = plan(db, req, tr)
    if new_loop is None:
        to_student(db, req.requester_id, "Your swap fell through. We'll keep looking and notify you.", "/s")
    return new_loop


def sweep_expired(db: Session) -> None:
    now = clock.utcnow()
    for o in db.scalars(select(SwapOffer).where(SwapOffer.state == "waiting", SwapOffer.expires_at < now)).all():
        loop = db.get(SwapLoop, o.loop_id)
        o.state = "expired"
        if loop.state == "approved":
            decline_loop(db, loop, o.student_id, "", expired=True)
    db.commit()


# ------------------------------------------------------------------ Commit Service
def maybe_commit(db: Session, loop: SwapLoop) -> bool:
    offers = db.scalars(select(SwapOffer).where(SwapOffer.loop_id == loop.id)).all()
    if offers and all(o.state == "accepted" for o in offers):
        commit(db, loop)
        return True
    return False


def commit(db: Session, loop: SwapLoop) -> None:
    """Apply every move at once — or none. Re-validates against the live week first."""
    req = db.get(SwapRequest, loop.request_id)
    shifts = {sid: db.get(Shift, sid) for m in loop.moves for sid in (m.get("gives_shift_id"), m.get("gets_shift_id")) if sid}
    s0 = db.get(Shift, req.shift_id)
    holders_ok = all(
        shifts[m["gives_shift_id"]].student_id == m["student_id"] for m in loop.moves if m.get("gives_shift_id")
    )
    problems = swap_agent.validate_moves(Ledger(db, s0.week), loop.moves, shifts) if holders_ok else ["stale"]
    if problems:
        loop.state = "invalidated"
        for o in db.scalars(select(SwapOffer).where(SwapOffer.loop_id == loop.id)):
            if o.state in ("waiting", "accepted"):
                o.state = "cancelled"
        _release_shifts(db, loop, keep=req.shift_id)
        tr = Trace()
        tr.step("Compliance Checker", "rules", "week changed before commit — nothing applied", status="blocked")
        plan(db, req, tr)
        return
    for m in loop.moves:
        if m.get("gets_shift_id"):
            shifts[m["gets_shift_id"]].student_id = m["student_id"]
    for sh in shifts.values():
        sh.state = "assigned"
    loop.state = "committed"
    req.state = "completed"
    for m in loop.moves:
        gets = shifts.get(m.get("gets_shift_id")) if m.get("gets_shift_id") else None
        if gets:
            to_student(db, m["student_id"], f"Your swap is confirmed. {DAY_LONG[gets.day]} is yours.", "/s")
        else:
            to_student(db, m["student_id"], "Your hand-off is confirmed. The shift is off your schedule.", "/s")
    n = len(loop.moves)
    to_department(db, req.department_id, f"Swap complete. All {n} schedules updated.", f"/d/requests/{req.id}")
    log(db, "Commit Service", f"Applied all {n} moves at once · every schedule updated", kind="rules",
        department_id=req.department_id, level="done", link=f"/d/requests/{req.id}")
    for m in loop.moves:
        log(db, "Commit Service", "Your swap is confirmed — your week is updated", kind="rules", student_id=m["student_id"], level="done")


# ------------------------------------------------------------------ helpers
def _release_shifts(db: Session, loop: SwapLoop, keep: int | None) -> None:
    for m in loop.moves:
        for sid in (m.get("gives_shift_id"), m.get("gets_shift_id")):
            if sid and sid != keep:
                sh = db.get(Shift, sid)
                if sh and sh.state == "pending_swap":
                    sh.state = "assigned"


def _slot(sh: Shift) -> str:
    from ..timeutil import hm

    return f"{DAY_SHORT[sh.day]} {hm(sh.start)}–{hm(sh.end)}"


def _move_signature(gives: Shift | None, gets: Shift | None) -> tuple:
    g = (gives.department_id, gives.day, gives.start, gives.end) if gives else None
    r = (gets.department_id, gets.day, gets.start, gets.end) if gets else None
    return (g, r)


def _previous_accepted_moves(db: Session, req: SwapRequest, exclude_loop: int) -> dict[int, set]:
    """If someone already said yes to an identical move for this request, don't ask them twice."""
    out: dict[int, set] = {}
    for lp in db.scalars(select(SwapLoop).where(SwapLoop.request_id == req.id, SwapLoop.id != exclude_loop)):
        for o in db.scalars(select(SwapOffer).where(SwapOffer.loop_id == lp.id, SwapOffer.state.in_(("accepted", "cancelled")))):
            if o.state == "cancelled" and o.responded_at is None:
                continue
            m = next((m for m in lp.moves if m["student_id"] == o.student_id), None)
            if not m:
                continue
            gives = db.get(Shift, m["gives_shift_id"]) if m.get("gives_shift_id") else None
            gets = db.get(Shift, m["gets_shift_id"]) if m.get("gets_shift_id") else None
            out.setdefault(o.student_id, set()).add(_move_signature(gives, gets))
    return out
