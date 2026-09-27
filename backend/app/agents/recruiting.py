"""Recruiting Agent — when a slot can't be filled from the team, look across campus.

Campus employers only: the pool is student employees at the same university who aren't on the team.
Businesses never see anyone outside their own team.

Proposes students who are free (per their own calendar) and under their limits, with the hours
to offer. The manager approves once; the student's autopilot (or the student) accepts; the
covered slots are then filled automatically — no scheduling by hand.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..events import log
from ..models import Department, Employment, RecruitProposal, Shift, StaffingRequirement, Student
from ..notify import to_department, to_student
from ..timeutil import slot_label
from .rules import Held, Ledger
from .scheduling import period_of


def gaps(db: Session, dept: Department, week: str) -> list[dict]:
    """Seats still missing after published shifts AND any pending draft."""
    reqs = db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == dept.id)).all()
    shifts = db.scalars(select(Shift).where(Shift.department_id == dept.id, Shift.week == week, Shift.student_id.is_not(None),
                                            Shift.status.in_(("published", "draft")))).all()
    need: dict[tuple, int] = {}
    for r in reqs:
        k = (r.day, r.start, r.end, r.position_id or 0)
        need[k] = need.get(k, 0) + r.headcount
    out = []
    for (day, start, end, pid), n in sorted(need.items()):
        have = sum(1 for s in shifts if (s.day, s.start, s.end, s.position_id or 0) == (day, start, end, pid))
        if have < n:
            out.append({"day": day, "start": start, "end": end, "position_id": pid or None, "missing": n - have})
    return out


def _same(c: dict, g: dict) -> bool:
    return (c["day"], c["start"], c["end"], c.get("position_id") or 0) == (g["day"], g["start"], g["end"], g.get("position_id") or 0)


def _pool(db: Session, dept: Department) -> list[Student]:
    """Student employees at the same university who aren't on this team. Businesses have no pool."""
    if dept.kind != "campus" or not dept.university_id:
        return []
    linked = {e.student_id for e in db.scalars(select(Employment).where(Employment.department_id == dept.id, Employment.state.in_(("active", "invited"))))}
    rows = db.scalars(select(Student).where(Student.kind == "student", Student.school_id == dept.university_id).order_by(Student.name))
    return [s for s in rows if s.id not in linked]


def _can_cover(ledger: Ledger, sid: int, did: int, day: int, start: int, end: int, hours: int, pid: int | None = None) -> bool:
    key = (sid, did)
    ledger.allotment(sid, did)
    saved, saved_roles = ledger._allot.get(key), ledger._roles.get(key, set())
    ledger._allot[key] = hours  # hypothetical job with this employer, in the role the slot needs
    ledger._roles[key] = saved_roles | ({pid} if pid else set())
    try:
        return ledger.check(sid, did, day, start, end, pid=pid).ok
    finally:
        ledger._allot[key], ledger._roles[key] = saved, saved_roles


def recruit(db: Session, dept: Department, week: str) -> list[RecruitProposal]:
    open_gaps = gaps(db, dept, week)
    if not open_gaps:
        return []
    pending = db.scalars(select(RecruitProposal).where(RecruitProposal.department_id == dept.id, RecruitProposal.week == week,
                                                       RecruitProposal.state.in_(("proposed", "invited")))).all()
    covered: dict[tuple, int] = {}
    for p in pending:
        for c in p.covers:
            k = (c["day"], c["start"], c["end"], c.get("position_id") or 0)
            covered[k] = covered.get(k, 0) + 1
    rejected = {p.student_id for p in db.scalars(select(RecruitProposal).where(
        RecruitProposal.department_id == dept.id, RecruitProposal.state.in_(("rejected", "declined"))))}
    ledger = Ledger(db, week)
    pool = [s for s in _pool(db, dept) if s.id not in rejected and s.id not in {p.student_id for p in pending}]
    made: list[RecruitProposal] = []
    plans: dict[int, dict] = {}
    for g in open_gaps:
        todo = g["missing"] - covered.get((g["day"], g["start"], g["end"], g.get("position_id") or 0), 0)
        for _ in range(max(0, todo)):
            slot_h = (g["end"] - g["start"]) / 60
            best = None
            for st in pool:
                plan = plans.get(st.id, {"covers": [], "hours": 0})
                hours = int(max(8, plan["hours"] + slot_h))
                if any(c["day"] == g["day"] and c["start"] == g["start"] and c["end"] == g["end"] for c in plan["covers"]):
                    continue
                if not _can_cover(ledger, st.id, dept.id, g["day"], g["start"], g["end"], hours, g.get("position_id")):
                    continue
                pref = 0 if set(st.preferences or []) & period_of(g["day"], g["start"], g["end"]) else 1
                spare = ledger.cap_left(st.id)
                score = (pref, -spare, st.id)
                if best is None or score < best[0]:
                    best = (score, st, hours)
            if not best:
                break
            _, st, hours = best
            plan = plans.setdefault(st.id, {"covers": [], "hours": 0, "student": st})
            plan["covers"].append({"day": g["day"], "start": g["start"], "end": g["end"], "position_id": g.get("position_id")})
            plan["hours"] += slot_h
            ledger._allot[(st.id, dept.id)] = hours
            ledger._roles[(st.id, dept.id)] = ledger._roles.get((st.id, dept.id), set()) | ({g["position_id"]} if g.get("position_id") else set())
            ledger.add(st.id, Held(-900 - len(plan["covers"]) - st.id * 10, dept.id, g["day"], g["start"], g["end"]))
    for sid, plan in plans.items():
        st = plan["student"]
        more = ledger.cap_left(sid) + plan["hours"]
        hours = int(min(max(plan["hours"], 8), max(plan["hours"], more)))
        labels = ", ".join(slot_label(c["day"], c["start"], c["end"]) for c in plan["covers"])
        reason = f"Free {labels} per their calendar · can take up to {int(more)} more hrs this week"
        p = RecruitProposal(department_id=dept.id, student_id=sid, week=week, hours=hours, covers=plan["covers"], reason=reason)
        db.add(p)
        made.append(p)
    if made:
        db.flush()
        names = ", ".join(db.get(Student, p.student_id).first_name for p in made)
        slots = sorted({slot_label(c["day"], c["start"], c["end"]) for p in made for c in p.covers})
        log(db, "Recruiting Agent", f"No one on your team can take {', '.join(slots)} — found {names} on campus · awaiting your approval",
            department_id=dept.id, level="action", link="/d/approvals")
        db.commit()
    return made


def approve(db: Session, p: RecruitProposal) -> None:
    dept = db.get(Department, p.department_id)
    st = db.get(Student, p.student_id)
    emp = db.scalar(select(Employment).where(Employment.student_id == st.id, Employment.department_id == dept.id))
    roles = sorted({int(c["position_id"]) for c in p.covers if c.get("position_id")})
    if emp and emp.state == "active":
        emp.hours = max(emp.hours, p.hours)
        emp.positions = sorted(set(emp.positions or []) | set(roles))
    elif emp:
        emp.state, emp.hours = "invited", p.hours
        emp.positions = sorted(set(emp.positions or []) | set(roles))
    else:
        db.add(Employment(student_id=st.id, department_id=dept.id, hours=p.hours, state="invited", positions=roles,
                          pay_rate=dept.default_pay_rate))
    p.state = "invited"
    covers = ", ".join(slot_label(c["day"], c["start"], c["end"]) for c in p.covers)
    to_student(db, st.id, f"{dept.name} invited you · {p.hours} hrs/week (starting with {covers})", "/s")
    log(db, "Recruiting Agent", f"Invited {st.first_name} · {p.hours} hrs/week to cover {covers}", kind="human",
        department_id=dept.id, level="info")
    log(db, "Recruiting Agent", f"{dept.name} wants you for {p.hours} hrs/week, starting {covers}", student_id=st.id, level="action")
    db.flush()
    if emp and emp.state == "active":
        fulfil(db, st, dept)


def fulfil(db: Session, st: Student, dept: Department) -> int:
    """Student joined: fill the slots they were recruited for (already approved by the manager)."""
    db.flush()
    n = 0
    for p in db.scalars(select(RecruitProposal).where(RecruitProposal.department_id == dept.id, RecruitProposal.student_id == st.id,
                                                      RecruitProposal.state == "invited")).all():
        ledger = Ledger(db, p.week)
        for c in p.covers:
            pid = c.get("position_id")
            open_seat = any(_same(c, g) for g in gaps(db, dept, p.week))
            if open_seat and ledger.check(st.id, dept.id, c["day"], c["start"], c["end"], pid=pid).ok:
                sh = Shift(department_id=dept.id, week=p.week, day=c["day"], start=c["start"], end=c["end"], student_id=st.id,
                           state="assigned", status="published", source="recruit", position_id=pid)
                db.add(sh)
                db.flush()
                ledger.add(st.id, Held(sh.id, dept.id, c["day"], c["start"], c["end"]))
                label = slot_label(c["day"], c["start"], c["end"])
                to_student(db, st.id, f"{dept.name} added {label} to your week.", "/s")
                log(db, "Scheduling Agent", f"{st.first_name} joined · filled {label} automatically", department_id=dept.id, level="done")
                log(db, "Scheduling Agent", f"Added {label} at {dept.name} to your week", student_id=st.id, level="done")
                n += 1
        p.state = "filled"
    return n


def reject(db: Session, p: RecruitProposal) -> None:
    p.state = "rejected"
    log(db, "Recruiting Agent", f"Skipped {db.get(Student, p.student_id).first_name} — won't suggest them again", kind="human",
        department_id=p.department_id, level="info")


def on_invite_answer(db: Session, st: Student, dept: Department, accepted: bool) -> None:
    if accepted:
        to_department(db, dept.id, f"{st.first_name} joined your team.", "/d/team")
        fulfil(db, st, dept)
    else:
        for p in db.scalars(select(RecruitProposal).where(RecruitProposal.department_id == dept.id, RecruitProposal.student_id == st.id,
                                                          RecruitProposal.state == "invited")):
            p.state = "declined"
        log(db, "Recruiting Agent", f"{st.first_name} declined — looking for someone else", department_id=dept.id, level="alert")
