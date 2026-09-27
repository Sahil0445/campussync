"""Conflict Agent + Compliance Checker. Deterministic code, never a model.

The Ledger is an in-memory view of one week across ALL departments. It knows everything;
the walkers decide what leaves. Every schedule draft, manual check and swap loop is validated
here before a human sees it.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass, field

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from ..config import MIN_REST_MINUTES
from ..models import BusyBlock, Employment, Shift, Student
from ..timeutil import overlaps

# Internal reasons. Only two ever leave the system to a department: schedule_conflict and hour_limit.
CONFLICT = "schedule_conflict"
HOUR_LIMIT = "hour_limit"
NOT_ON_TEAM = "not_on_team"
NOT_QUALIFIED = "not_qualified"  # the employee doesn't hold the position this shift needs
_TIMING = {"overlap", "rest", "daily_max"}  # all surface as schedule_conflict
_HOURS = {"weekly_cap", "dept_hours"}  # all surface as hour_limit


@dataclass
class Held:
    shift_id: int
    department_id: int
    day: int
    start: int
    end: int

    @property
    def hours(self) -> float:
        return (self.end - self.start) / 60


@dataclass
class Verdict:
    ok: bool
    code: str | None = None  # overlap | rest | daily_max | weekly_cap | dept_hours | not_on_team | not_qualified
    hours_left: float = 0
    cross_department: bool = False  # the blocker belongs to another department (internal only)

    @property
    def public_reason(self) -> str | None:
        if self.ok:
            return None
        if self.code in _TIMING:
            return CONFLICT
        if self.code in _HOURS:
            return HOUR_LIMIT
        return self.code

    @property
    def is_timing(self) -> bool:
        return self.code in _TIMING

    @property
    def is_hours(self) -> bool:
        return self.code in _HOURS


@dataclass
class Ledger:
    db: Session
    week: str
    _students: dict = field(default_factory=dict)
    _busy: dict = field(default_factory=dict)
    _held: dict = field(default_factory=dict)
    _allot: dict = field(default_factory=dict)
    _roles: dict = field(default_factory=dict)

    # ---------- loading ----------
    def student(self, sid: int) -> Student:
        if sid not in self._students:
            self._students[sid] = self.db.get(Student, sid)
        return self._students[sid]

    def busy(self, sid: int) -> list[BusyBlock]:
        if sid not in self._busy:
            self._busy[sid] = list(self.db.scalars(select(BusyBlock).where(
                BusyBlock.student_id == sid, or_(BusyBlock.week.is_(None), BusyBlock.week == self.week))))
        return self._busy[sid]

    def held(self, sid: int) -> list[Held]:
        if sid not in self._held:
            rows = self.db.scalars(
                select(Shift).where(
                    Shift.student_id == sid,
                    Shift.week == self.week,
                    Shift.status == "published",
                )
            )
            self._held[sid] = [Held(s.id, s.department_id, s.day, s.start, s.end) for s in rows]
        return self._held[sid]

    def allotment(self, sid: int, did: int) -> int | None:
        key = (sid, did)
        if key not in self._allot:
            emp = self.db.scalar(
                select(Employment).where(
                    Employment.student_id == sid,
                    Employment.department_id == did,
                    Employment.state == "active",
                )
            )
            self._allot[key] = emp.hours if emp else None
            self._roles[key] = set(int(x) for x in (emp.positions or [])) if emp else set()
        return self._allot[key]

    def roles(self, sid: int, did: int) -> set[int]:
        self.allotment(sid, did)
        return self._roles.get((sid, did), set())

    def qualified(self, sid: int, did: int, pid: int | None) -> bool:
        """Shifts tied to a position can only go to employees who hold it."""
        return pid is None or pid in self.roles(sid, did)

    def clone(self) -> "Ledger":
        other = Ledger(self.db, self.week)
        other._students = self._students
        other._busy = self._busy
        other._allot = self._allot
        other._roles = self._roles
        other._held = copy.deepcopy(self._held)
        return other

    # ---------- mutation (in memory only) ----------
    def add(self, sid: int, h: Held) -> None:
        self.held(sid).append(h)

    def remove(self, sid: int, shift_id: int) -> None:
        self._held[sid] = [h for h in self.held(sid) if h.shift_id != shift_id]

    # ---------- measures ----------
    def total_hours(self, sid: int) -> float:
        return sum(h.hours for h in self.held(sid))

    def dept_hours(self, sid: int, did: int) -> float:
        return sum(h.hours for h in self.held(sid) if h.department_id == did)

    def day_hours(self, sid: int, day: int) -> float:
        return sum(h.hours for h in self.held(sid) if h.day == day)

    def cap(self, sid: int) -> int:
        return self.student(sid).cap

    def cap_left(self, sid: int) -> float:
        return max(0.0, self.cap(sid) - self.total_hours(sid))

    def hours_left(self, sid: int, did: int) -> float:
        """Hours this department may still schedule. The only hour number a department ever sees."""
        allot = self.allotment(sid, did)
        if allot is None:
            return 0.0
        return max(0.0, min(self.cap(sid) - self.total_hours(sid), allot - self.dept_hours(sid, did)))

    # ---------- Conflict Agent ----------
    def conflict(self, sid: int, day: int, start: int, end: int, ignore: set[int] | None = None, did: int | None = None) -> Verdict:
        ignore = ignore or set()
        for b in self.busy(sid):
            if b.day == day and overlaps(start, end, b.start, b.end):
                return Verdict(False, "overlap", cross_department=False)
        for h in self.held(sid):
            if h.shift_id in ignore:
                continue
            if h.day == day and overlaps(start, end, h.start, h.end):
                return Verdict(False, "overlap", cross_department=h.department_id != did)
        return Verdict(True)

    # ---------- Compliance Checker ----------
    def compliance(self, sid: int, did: int, day: int, start: int, end: int, ignore: set[int] | None = None) -> Verdict:
        ignore = ignore or set()
        add = (end - start) / 60
        held = [h for h in self.held(sid) if h.shift_id not in ignore]
        allot = self.allotment(sid, did)
        if allot is None:
            return Verdict(False, "not_on_team")
        total = sum(h.hours for h in held)
        dept = sum(h.hours for h in held if h.department_id == did)
        left = max(0.0, min(self.cap(sid) - total, allot - dept))
        if total + add > self.cap(sid) + 1e-9:
            return Verdict(False, "weekly_cap", hours_left=left, cross_department=total - dept > 0)
        if dept + add > allot + 1e-9:
            return Verdict(False, "dept_hours", hours_left=left)
        same_day = [h for h in held if h.day == day]
        if sum(h.hours for h in same_day) + add > self.student(sid).daily_max + 1e-9:
            return Verdict(False, "daily_max", hours_left=left, cross_department=any(h.department_id != did for h in same_day))
        for h in same_day:
            gap = start - h.end if start >= h.end else h.start - end
            if 0 <= gap < MIN_REST_MINUTES:
                return Verdict(False, "rest", hours_left=left, cross_department=h.department_id != did)
        return Verdict(True, hours_left=left)

    def check(self, sid: int, did: int, day: int, start: int, end: int, ignore: set[int] | None = None,
              pid: int | None = None) -> Verdict:
        """Conflict first, then compliance (spec: if both apply, report schedule_conflict)."""
        if self.allotment(sid, did) is None:
            return Verdict(False, "not_on_team")
        if not self.qualified(sid, did, pid):
            return Verdict(False, NOT_QUALIFIED)
        v = self.conflict(sid, day, start, end, ignore, did)
        if not v.ok:
            v.hours_left = self.hours_left(sid, did)
            return v
        return self.compliance(sid, did, day, start, end, ignore)

    # ---------- whole-week validation (used for swaps) ----------
    def violations(self, sid: int) -> list[str]:
        """Every hard rule against the student's full week as it currently stands in this ledger."""
        out: list[str] = []
        held = self.held(sid)
        for i, a in enumerate(held):
            for b in self.busy(sid):
                if a.day == b.day and overlaps(a.start, a.end, b.start, b.end):
                    out.append("overlap")
            for c in held[i + 1:]:
                if a.day == c.day:
                    if overlaps(a.start, a.end, c.start, c.end):
                        out.append("overlap")
                    else:
                        gap = c.start - a.end if c.start >= a.end else a.start - c.end
                        if gap < MIN_REST_MINUTES:
                            out.append("rest")
        if self.total_hours(sid) > self.cap(sid) + 1e-9:
            out.append("weekly_cap")
        for did in {h.department_id for h in held}:
            allot = self.allotment(sid, did)
            if allot is None or self.dept_hours(sid, did) > allot + 1e-9:
                out.append("dept_hours")
        for day in {h.day for h in held}:
            if self.day_hours(sid, day) > self.student(sid).daily_max + 1e-9:
                out.append("daily_max")
        return out
