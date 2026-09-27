"""Coordinator workflow for 'Generate schedule' + the Scheduling Agent.

Flow: Coordinator -> Availability -> Conflict (rules) -> Scheduling (AI proposes) ->
Compliance (rules validate every proposal) -> greedy backfill -> Explainer.
The AI makes the judgment calls (who takes Saturday, fairness); the rules decide what is allowed.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import date

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..events import log
from ..models import Department, Employment, Position, ScheduleDraft, Shift, StaffingRequirement, Student
from ..timeutil import DAY_SHORT, fmt_hours, hm, slot_label
from .llm import llm
from .rules import Held, Ledger
from .trace import Trace


@dataclass
class Seat:
    key: str  # slot key "day-start-end-position"
    day: int
    start: int
    end: int
    pid: int | None = None  # position this seat needs (None = anyone on the team)
    role: str = ""

    @property
    def hours(self) -> float:
        return (self.end - self.start) / 60

    @property
    def label(self) -> str:
        return slot_label(self.day, self.start, self.end) + (f" · {self.role}" if self.role else "")


def slot_key(day: int, start: int, end: int, pid: int | None) -> str:
    return f"{day}-{start}-{end}-{pid or 0}"


def position_names(db: Session, department_id: int) -> dict[int, str]:
    return {p.id: p.name for p in db.scalars(select(Position).where(Position.department_id == department_id))}


def period_of(day: int, start: int, end: int) -> set[str]:
    mid = (start + end) / 2
    out = {"Mornings" if mid < 12 * 60 else "Afternoons" if mid < 17 * 60 else "Evenings"}
    if day >= 5:
        out.add("Weekends")
    return out


def team_of(db: Session, department_id: int) -> list[Student]:
    rows = db.scalars(
        select(Student)
        .join(Employment, Employment.student_id == Student.id)
        .where(Employment.department_id == department_id, Employment.state == "active")
        .order_by(Student.name)
    )
    return list(rows)


def seats_for_week(db: Session, dept: Department, week: str) -> tuple[list[Seat], dict[str, dict]]:
    """Open seats (one per missing headcount) and per-slot bookkeeping."""
    reqs = db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == dept.id)).all()
    published = db.scalars(
        select(Shift).where(Shift.department_id == dept.id, Shift.week == week, Shift.status == "published", Shift.student_id.is_not(None))
    ).all()
    roles = position_names(db, dept.id)
    slots: dict[str, dict] = {}
    seats: list[Seat] = []
    for r in sorted(reqs, key=lambda r: (r.day, r.start, r.position_id or 0)):
        pid = r.position_id if r.position_id in roles else None
        key = slot_key(r.day, r.start, r.end, pid)
        have = sum(1 for s in published if (s.day, s.start, s.end, s.position_id) == (r.day, r.start, r.end, pid))
        slot = slots.setdefault(key, {"day": r.day, "start": r.start, "end": r.end, "pid": pid, "role": roles.get(pid, "") if pid else "",
                                      "needed": 0, "have": have})
        slot["needed"] += r.headcount
    for key, slot in slots.items():
        for _ in range(max(0, slot["needed"] - slot["have"])):
            seats.append(Seat(key, slot["day"], slot["start"], slot["end"], slot["pid"], slot["role"]))
    return seats, slots


_SCHED_SYSTEM = (
    "You are the Scheduling Agent for an employer. Fill open shift slots with employees. "
    "Hard rules are enforced by separate code, so focus on judgment: spread unpopular slots "
    "(weekends, early mornings, nights) fairly, give hours to people furthest below the hours their employer "
    "assigned them, and avoid giving one person every weekend. Only pick people listed "
    "as eligible for a slot, never exceed a slot's need, and never give anyone more hours than "
    "their can_take_more. Respond with JSON only: "
    '{"assignments": {"<slot id>": [<student id>, ...]}, "notes": {"<student id>": "<one short reason, max 12 words>"}}'
)


def _ai_propose(seats: list[Seat], cands: dict[str, list[int]], team: list[Student], ledger: Ledger, dept_id: int):
    by_key: dict[str, dict] = {}
    for s in seats:
        entry = by_key.setdefault(s.key, {"slot": s.key, "label": s.label, "hours": s.hours, "need": 0, "eligible": cands[s.key]})
        entry["need"] += 1
    students = [
        {
            "id": st.id,
            "name": st.first_name,
            "hours_with_you": ledger.dept_hours(st.id, dept_id),
            "can_take_more": ledger.hours_left(st.id, dept_id),
            "assigned_hours": ledger.allotment(st.id, dept_id) or 0,
            "weekend_shifts": sum(1 for h in ledger.held(st.id) if h.day >= 5 and h.department_id == dept_id),
        }
        for st in team
    ]
    prompt = json.dumps({"open_slots": list(by_key.values()), "students": students})
    data = llm.json(_SCHED_SYSTEM, prompt)
    if not isinstance(data, dict):
        return None
    assignments = data.get("assignments") or {}
    notes = data.get("notes") or {}
    if not isinstance(assignments, dict):
        return None
    clean = {k: [int(x) for x in v if str(x).isdigit()] for k, v in assignments.items() if isinstance(v, list)}
    clean_notes = {int(k): str(v)[:120] for k, v in notes.items() if str(k).isdigit()} if isinstance(notes, dict) else {}
    return clean, clean_notes


def _score(st: Student, seat: Seat, ledger: Ledger, dept_id: int, allot: int) -> tuple:
    """Fallback judgment. Lower is better."""
    fill = ledger.dept_hours(st.id, dept_id) / max(1, allot)
    prefs = set(st.preferences or [])
    pref_hit = 0 if (not prefs or prefs & period_of(seat.day, seat.start, seat.end)) else 1
    weekend = sum(1 for h in ledger.held(st.id) if h.day >= 5) if seat.day >= 5 else 0
    return (pref_hit + weekend, round(fill, 3), st.id)


def generate(db: Session, dept: Department, week: str, origin: str = "manual") -> ScheduleDraft:
    for old in db.scalars(select(ScheduleDraft).where(ScheduleDraft.department_id == dept.id, ScheduleDraft.week == week, ScheduleDraft.state == "draft")):
        discard(db, old)

    tr = Trace()
    wk = date.fromisoformat(week)
    tr.step("Coordinator", "agent", f"started workflow for week of {wk:%b} {wk.day}")
    team = team_of(db, dept.id)
    ledger = Ledger(db, week)
    for st in team:
        ledger.busy(st.id)
    tr.step("Availability Agent", "agent", f"read {len(team)} team calendars")

    seats, slots = seats_for_week(db, dept, week)
    allot = {st.id: ledger.allotment(st.id, dept.id) or 0 for st in team}
    before_hours = {st.id: ledger.dept_hours(st.id, dept.id) for st in team}

    # Conflict Agent: blind cross-department pass
    cands: dict[str, list[int]] = {}
    cross_pairs: set[tuple[int, str]] = set()
    for seat in seats:
        if seat.key in cands:
            continue
        ok_ids = []
        for st in team:
            v = ledger.check(st.id, dept.id, seat.day, seat.start, seat.end, pid=seat.pid)
            if v.ok:
                ok_ids.append(st.id)
            elif v.is_timing and v.cross_department:
                cross_pairs.add((st.id, seat.key))
        cands[seat.key] = ok_ids
    n_cross = len(cross_pairs)
    tr.step("Conflict Agent", "rules", f"found {n_cross} overlap{'s' if n_cross != 1 else ''} with other jobs",
            status="blocked" if n_cross else "done")

    # Scheduling Agent: AI proposal, then rules validate each pick
    order = sorted(seats, key=lambda s: (len(cands[s.key]), s.day, s.start))
    assigned: list[tuple[Seat, int]] = []
    removed = 0
    ai_notes: dict[int, str] = {}
    proposal = _ai_propose(seats, cands, team, ledger, dept.id) if seats and team else None
    used_ai = proposal is not None
    remaining = list(order)
    temp_id = -1
    if proposal:
        picks, ai_notes = proposal
        still: list[Seat] = []
        for seat in order:
            queue = picks.get(seat.key, [])
            placed = False
            while queue and not placed:
                sid = queue.pop(0)
                if sid not in allot:
                    continue
                v = ledger.check(sid, dept.id, seat.day, seat.start, seat.end, pid=seat.pid)
                if v.ok:
                    ledger.add(sid, Held(temp_id, dept.id, seat.day, seat.start, seat.end))
                    temp_id -= 1
                    assigned.append((seat, sid))
                    placed = True
                else:
                    removed += 1
            if not placed:
                still.append(seat)
        remaining = still

    # Greedy backfill (also the whole algorithm when the model is unavailable)
    while remaining:
        best = None
        for seat in remaining:
            ok = [st for st in team if ledger.check(st.id, dept.id, seat.day, seat.start, seat.end, pid=seat.pid).ok]
            if best is None or len(ok) < len(best[1]):
                best = (seat, ok)
        seat, ok = best
        remaining.remove(seat)
        if not ok:
            continue
        pick = min(ok, key=lambda st: _score(st, seat, ledger, dept.id, allot[st.id]))
        ledger.add(pick.id, Held(temp_id, dept.id, seat.day, seat.start, seat.end))
        temp_id -= 1
        assigned.append((seat, pick.id))

    if removed:
        tr.step("Compliance Checker", "rules", f"removed {removed} assignment{'s' if removed != 1 else ''} over hour cap or conflicting", status="blocked")
    else:
        tr.step("Compliance Checker", "rules", "every assignment within hour limits")

    total_needed = sum(s["needed"] for s in slots.values())
    total_have = sum(min(s["have"], s["needed"]) for s in slots.values())
    filled = total_have + len(assigned)
    tr.step("Scheduling Agent", "agent", f"filled {filled} of {total_needed} slots", ai=used_ai)

    # Gaps: flagged, never hidden
    filled_per_slot: dict[str, int] = {}
    for seat, _ in assigned:
        filled_per_slot[seat.key] = filled_per_slot.get(seat.key, 0) + 1
    gaps = []
    for key, slot in slots.items():
        found = slot["have"] + filled_per_slot.get(key, 0)
        if found < slot["needed"]:
            gaps.append({
                "day": slot["day"], "start": slot["start"], "end": slot["end"], "position_id": slot["pid"], "role": slot["role"],
                "label": slot_label(slot["day"], slot["start"], slot["end"]) + (f" · {slot['role']}" if slot["role"] else ""),
                "needed": slot["needed"], "found": found,
                "reason": _gap_reason(team, ledger, dept.id, slot),
            })
    gaps.sort(key=lambda g: (g["day"], g["start"]))
    open_seats = sum(g["needed"] - g["found"] for g in gaps)

    # Draft rows
    draft = ScheduleDraft(department_id=dept.id, week=week, state="draft", origin=origin)
    db.add(draft)
    db.flush()
    new_by_student: dict[int, list[Seat]] = {}
    new_ids = []
    for seat, sid in assigned:
        sh = Shift(department_id=dept.id, week=week, day=seat.day, start=seat.start, end=seat.end, position_id=seat.pid,
                   student_id=sid, state="assigned", status="draft", draft_id=draft.id, source="generated")
        db.add(sh)
        db.flush()
        new_ids.append(sh.id)
        new_by_student.setdefault(sid, []).append(seat)

    students_summary = []
    lowest = min(before_hours.values()) if before_hours else 0
    for st in team:
        mine = new_by_student.get(st.id, [])
        hrs = ledger.dept_hours(st.id, dept.id)
        why = ai_notes.get(st.id) or _fallback_note(st, mine, before_hours[st.id], lowest, hrs, allot[st.id])
        students_summary.append({
            "student_id": st.id, "name": st.first_name, "full_name": st.name,
            "hours": hrs, "allotment": allot[st.id], "new_shifts": len(mine),
            "line": f"{st.first_name} · {fmt_hours(hrs)} of {allot[st.id]} hrs · all within availability",
            "why": why,
        })

    if gaps:
        tr.step("Explainer", "agent", f"{open_seats} slot{'s' if open_seats != 1 else ''} still open — flagged for you", status="blocked", ai=used_ai)
    else:
        tr.step("Explainer", "agent", "every slot is covered", ai=used_ai)
    tr.final("Schedule ready for review")

    draft.trace = tr.rows
    draft.summary = {
        "filled": filled, "needed": total_needed, "open_seats": open_seats, "gaps": gaps,
        "students": students_summary, "new_shift_ids": new_ids, "ai": used_ai,
        "fallback": tr.fallback_used,
    }
    wk = date.fromisoformat(week)
    gap_note = f" · {open_seats} gap{'s' if open_seats != 1 else ''} flagged" if open_seats else ""
    log(db, "Scheduling Agent", f"Drafted week of {wk:%b} {wk.day} · {filled}/{total_needed} slots filled{gap_note} · awaiting your approval",
        department_id=dept.id, level="action", link=f"/d/drafts/{draft.id}")
    db.commit()
    return draft


def fillable_seats(db: Session, dept: Department, week: str) -> tuple[int, int]:
    """(open seats, seats at least one team member could take right now)."""
    seats, _ = seats_for_week(db, dept, week)
    team = team_of(db, dept.id)
    ledger = Ledger(db, week)
    fillable = sum(1 for s in seats if any(ledger.check(st.id, dept.id, s.day, s.start, s.end, pid=s.pid).ok for st in team))
    return len(seats), fillable


def _gap_reason(team: list[Student], ledger: Ledger, dept_id: int, slot: dict) -> str:
    if not team:
        return "No one on your team yet — share your join code."
    pid = slot.get("pid")
    if pid and not any(ledger.qualified(st.id, dept_id, pid) for st in team):
        return f"No one on your team has the {slot.get('role') or 'required'} role yet."
    free_but_hours = 0
    for st in team:
        v = ledger.check(st.id, dept_id, slot["day"], slot["start"], slot["end"], pid=pid)
        if v.ok:
            return "Someone is available — try generating again."
        if v.is_hours:
            free_but_hours += 1
    if free_but_hours:
        return "Everyone available is at their weekly limit."
    return "No one on your team is free at this time."


def _fallback_note(st: Student, mine: list[Seat], before: float, lowest: float, after: float, allot: int) -> str:
    if not mine:
        if after >= allot:
            return "Already at their hours with you."
        return "No open slot fits their availability and limits."
    prefs = set(st.preferences or [])
    parts = []
    hits = [p for p in prefs if any(p in period_of(s.day, s.start, s.end) for s in mine)]
    if hits:
        parts.append(f"Prefers {sorted(hits)[0].lower()}")
    if before == 0:
        parts.append("had no shifts yet")
    elif before <= lowest:
        parts.append("fewest hours so far")
    if any(s.day >= 5 for s in mine) and "Weekends" not in hits:
        parts.append("free on the weekend")
    if not parts:
        days = ", ".join(sorted({DAY_SHORT[s.day] for s in mine}, key=DAY_SHORT.index))
        parts.append(f"Free {days} and under their hours")
    text = "; ".join(parts)
    return text[0].upper() + text[1:]


def discard(db: Session, draft: ScheduleDraft) -> None:
    for sh in db.scalars(select(Shift).where(Shift.draft_id == draft.id, Shift.status == "draft")):
        db.delete(sh)
    draft.state = "discarded"


def publish(db: Session, draft: ScheduleDraft) -> dict:
    """Re-validate at publish time: another department may have published since the draft was made."""
    ledger = Ledger(db, draft.week)
    counts: dict[int, int] = {}
    dropped = 0
    for sh in db.scalars(select(Shift).where(Shift.draft_id == draft.id, Shift.status == "draft")).all():
        v = ledger.check(sh.student_id, sh.department_id, sh.day, sh.start, sh.end, pid=sh.position_id)
        if v.ok:
            sh.status = "published"
            ledger.add(sh.student_id, Held(sh.id, sh.department_id, sh.day, sh.start, sh.end))
            counts[sh.student_id] = counts.get(sh.student_id, 0) + 1
        else:
            db.delete(sh)
            dropped += 1
    draft.state = "published"
    log(db, "Coordinator", f"Schedule published · {len(counts)} {'person' if len(counts) == 1 else 'people'} notified" + (f" · {dropped} changed since draft and were dropped" if dropped else ""),
        kind="human", department_id=draft.department_id, level="done")
    for sid, n in counts.items():
        log(db, "Scheduling Agent", f"{n} new shift{'s' if n != 1 else ''} added to your week", student_id=sid, level="done")
    return {"notified": counts, "dropped": dropped}


def describe_slot(day: int, start: int, end: int) -> str:
    return f"{DAY_SHORT[day]} {hm(start)}–{hm(end)}"
