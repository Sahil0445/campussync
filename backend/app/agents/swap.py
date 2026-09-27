"""Swap Agent.

Search is deterministic (depth <= 4): direct 1:1 swap, then 3-person loops, then 4-person loops.
Every candidate is validated against the full cross-department Ledger for every participant.
The AI's job is ranking judgment and the explanation; it never decides what is allowed.
Only department-local data (first names, this department's shifts) is ever sent to the model.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import Shift, Student, SwapRequest
from ..timeutil import DAY_LONG, DAY_SHORT, slot_label
from .llm import llm
from .rules import Held, Ledger
from .scheduling import period_of, team_of

MAX_LOOP = 4


@dataclass
class Candidate:
    kind: str  # direct | loop | handoff
    moves: list[dict]
    participants: list[int]
    score: tuple = field(default_factory=tuple)

    @property
    def size(self) -> int:
        return len(self.participants)


@dataclass
class SearchResult:
    found: dict[int, int] = field(default_factory=lambda: {2: 0, 3: 0, 4: 0})
    rejected_conflict: int = 0
    rejected_hours: int = 0
    candidates: list[Candidate] = field(default_factory=list)


def _holdings(db: Session, req: SwapRequest, week: str) -> dict[int, list[Shift]]:
    rows = db.scalars(
        select(Shift).where(
            Shift.department_id == req.department_id,
            Shift.week == week,
            Shift.status == "published",
            Shift.student_id.is_not(None),
        )
    ).all()
    out: dict[int, list[Shift]] = {}
    for s in rows:
        if s.state == "assigned" or s.id == req.shift_id:
            out.setdefault(s.student_id, []).append(s)
    return out


def _requester_wants(req: SwapRequest, s0: Shift, sh: Shift) -> bool:
    if sh.id == s0.id:
        return False
    if req.want_kind == "days":
        return sh.day in (req.want_days or [])
    if req.want_kind == "any":
        return (sh.day, sh.start, sh.end) != (s0.day, s0.start, s0.end)
    return False


def _moves_from_path(path: list[tuple[int, Shift]]) -> list[dict]:
    moves = []
    for i, (sid, gives) in enumerate(path):
        gets = path[i - 1][1] if i > 0 else path[-1][1]
        moves.append({"student_id": sid, "gives_shift_id": gives.id, "gets_shift_id": gets.id})
    return moves


def validate_moves(ledger: Ledger, moves: list[dict], shifts: dict[int, Shift]) -> list[str]:
    """Apply all moves to a copy of the week and check every participant against every hard rule."""
    problems: list[str] = []
    for m in moves:  # a shift tied to a position can only move to someone who holds that position
        if m.get("gets_shift_id"):
            sh = shifts[m["gets_shift_id"]]
            if not ledger.qualified(m["student_id"], sh.department_id, sh.position_id):
                problems.append("not_qualified")
    if problems:
        return problems
    trial = ledger.clone()
    for m in moves:
        if m.get("gives_shift_id"):
            trial.remove(m["student_id"], m["gives_shift_id"])
    for m in moves:
        if m.get("gets_shift_id"):
            sh = shifts[m["gets_shift_id"]]
            trial.add(m["student_id"], Held(sh.id, sh.department_id, sh.day, sh.start, sh.end))
    for m in moves:
        problems += trial.violations(m["student_id"])
    return problems


def search(db: Session, req: SwapRequest) -> SearchResult:
    s0 = db.get(Shift, req.shift_id)
    week = s0.week
    ledger = Ledger(db, week)
    holdings = _holdings(db, req, week)
    shifts = {s.id: s for lst in holdings.values() for s in lst}
    students = {sid: db.get(Student, sid) for sid in holdings}
    excluded = set(req.excluded_student_ids or [])
    result = SearchResult()

    def consider(kind: str, moves: list[dict], participants: list[int]):
        problems = validate_moves(ledger, moves, shifts)
        if problems:
            if any(p in ("overlap", "rest", "daily_max") for p in problems):
                result.rejected_conflict += 1
            else:
                result.rejected_hours += 1
            return
        result.found[len(participants)] = result.found.get(len(participants), 0) + 1
        result.candidates.append(Candidate(kind, moves, participants))

    if req.want_kind == "give_up":
        team = team_of(db, req.department_id)
        for st in team:
            if st.id == req.requester_id or st.id in excluded:
                continue
            moves = [
                {"student_id": req.requester_id, "gives_shift_id": s0.id, "gets_shift_id": None},
                {"student_id": st.id, "gives_shift_id": None, "gets_shift_id": s0.id},
            ]
            consider("handoff", moves, [req.requester_id, st.id])
    else:
        def dfs(path: list[tuple[int, Shift]]):
            current = path[-1][1]
            in_path = {p[0] for p in path}
            for sid, owned in holdings.items():
                if sid in in_path or sid in excluded or sid == req.requester_id:
                    continue
                if current.day not in (students[sid].open_swap_days or []):
                    continue
                for sh in owned:
                    if sh.state != "assigned":
                        continue
                    new_path = path + [(sid, sh)]
                    if _requester_wants(req, s0, sh):
                        kind = "direct" if len(new_path) == 2 else "loop"
                        consider(kind, _moves_from_path(new_path), [p[0] for p in new_path])
                    if len(new_path) < MAX_LOOP:
                        dfs(new_path)

        dfs([(req.requester_id, s0)])

    for c in result.candidates:
        c.score = _rank_key(c, students if students else {}, shifts, db)
    result.candidates.sort(key=lambda c: c.score)
    return result


def _rank_key(c: Candidate, students: dict, shifts: dict, db: Session) -> tuple:
    """Smaller loops first; then most likely to be accepted; then least sacrifice."""
    likely = 0
    sacrifice = 0
    for m in c.moves:
        st = students.get(m["student_id"]) or db.get(Student, m["student_id"])
        gets = shifts.get(m["gets_shift_id"]) if m.get("gets_shift_id") else None
        if gets and st.autopilot and gets.day in (st.open_swap_days or []):
            likely += 1
        prefs = set(st.preferences or [])
        if gets and prefs and not (prefs & period_of(gets.day, gets.start, gets.end)):
            sacrifice += 1
        if gets and m.get("gives_shift_id"):
            gives = shifts.get(m["gives_shift_id"])
            if gives:
                sacrifice += abs(gives.start - gets.start) / 600
    if c.kind == "handoff":
        receiver = students.get(c.participants[1]) or db.get(Student, c.participants[1])
        s0 = shifts.get(c.moves[0]["gives_shift_id"]) or db.get(Shift, c.moves[0]["gives_shift_id"])
        likely += 1 if s0.day in (receiver.open_swap_days or []) else 0
    return (c.size, -likely, round(sacrifice, 2), tuple(c.participants))


# ------------------------------------------------------------------ Explainer (swap cards)
def headline(kind: str, size: int, receiver_name: str | None = None) -> str:
    if kind == "handoff":
        return f"Hand-off · {receiver_name} takes the shift"
    if kind == "direct":
        return "Direct swap · everyone stays within limits"
    return f"{size}-person swap · everyone stays within limits"


def describe(db: Session, moves: list[dict]) -> list[dict]:
    """Department-local description of each move: first names, this department's shifts only."""
    out = []
    for m in moves:
        st = db.get(Student, m["student_id"])
        gives = db.get(Shift, m["gives_shift_id"]) if m.get("gives_shift_id") else None
        gets = db.get(Shift, m["gets_shift_id"]) if m.get("gets_shift_id") else None
        out.append({
            "student_id": st.id,
            "name": st.first_name,
            "gives": slot_label(gives.day, gives.start, gives.end) if gives else None,
            "gets": slot_label(gets.day, gets.start, gets.end) if gets else None,
            "gives_day": gives.day if gives else None,
            "gets_day": gets.day if gets else None,
            "gives_shift_id": gives.id if gives else None,
            "gets_shift_id": gets.id if gets else None,
        })
    return out


def summarize(db: Session, cand: Candidate) -> str:
    names = [db.get(Student, sid).first_name for sid in cand.participants[1:]]
    if cand.kind == "handoff":
        return f"Hand-off to {names[0]}"
    joined = ", ".join(names[:-1]) + (" and " if len(names) > 1 else "") + names[-1]
    return f"{cand.size}-person loop via {joined}" if cand.kind == "loop" else f"Direct swap with {joined}"


_WHY_SYSTEM = (
    "You are the Explainer for a campus shift-swap agent. Write 2-3 plain sentences a busy manager can "
    "read in five seconds: why this circle of trades works and what each person gives up. Use first names "
    "only. Mention that nobody's hours change if that is true, and that coverage is unchanged. "
    "If a previous option was declined, say briefly how this one avoids that. No bullet points. "
    'Respond with JSON only: {"why": "..."}'
)


def rationale(db: Session, req: SwapRequest, cand: Candidate) -> tuple[str, bool]:
    moves = describe(db, cand.moves)
    requester = db.get(Student, req.requester_id).first_name
    want = (
        ", ".join(DAY_LONG[d] for d in req.want_days) if req.want_kind == "days"
        else "any other time" if req.want_kind == "any" else "to give the shift up"
    )
    feedback = req.feedback or []
    payload = {"requester": requester, "requester_wants": want, "moves": moves, "hours_change": "none" if cand.kind != "handoff" else "requester down, receiver up", "previous_declines": feedback}
    data = llm.json(_WHY_SYSTEM, json.dumps(payload))
    if isinstance(data, dict) and isinstance(data.get("why"), str) and data["why"].strip():
        return data["why"].strip()[:600], True
    return _fallback_rationale(requester, want, moves, cand, feedback), False


def _fallback_rationale(requester: str, want: str, moves: list[dict], cand: Candidate, feedback: list) -> str:
    if cand.kind == "handoff":
        r = moves[1]
        return (f"{requester} wants to give up {moves[0]['gives']}. {r['name']} is free then and still under "
                f"their hours with you, so they can take it. {requester}'s hours go down; coverage is unchanged.")
    first = moves[0]
    others = moves[1:]
    opens = [f"{m['name']} is open to {DAY_LONG[m['gets_day']]}s" if i == 0 else f"{m['name']} to {DAY_LONG[m['gets_day']]}s"
             for i, m in enumerate(others)]
    wants = opens[0] if len(opens) == 1 else ", ".join(opens[:-1]) + " and " + opens[-1]
    lead = (f"{requester} wants {want}, but nobody holding a {want} shift wants {DAY_LONG[first['gives_day']]} directly. "
            if cand.kind == "loop" else f"{requester} wants {want} and {others[0]['name']} wants {requester}'s shift. ")
    body = (f"{wants}, so passing the shifts around the circle gives everyone a day they asked for. "
            "Every shift is the same length, so nobody's hours change and coverage stays exactly the same.")
    if feedback:
        last = feedback[-1]
        body += f" {last['name']} declined the previous option, so this one leaves them out."
    return lead + body
