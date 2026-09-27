"""Conflict Agent + Compliance Checker. Deterministic code, never a model.

The Ledger is an in-memory view of one week across ALL employers. It knows everything; the
endpoints decide what leaves. Every schedule draft, manual check and swap loop is validated here
before a human sees it.
"""

import from server.config { MIN_REST_MINUTES }
import from server.timeutil { overlaps }
import from server.models {
    Employee,
    BusyBlock,
    Employment,
    Shift,
    employee_of
}

# Internal reasons. Only two ever leave the system to an employer: schedule_conflict and hour_limit.
glob CONFLICT: str = "schedule_conflict",
     HOUR_LIMIT: str = "hour_limit",
     NOT_ON_TEAM: str = "not_on_team",
     NOT_QUALIFIED: str = "not_qualified",
     _TIMING: list[str] = ["overlap", "rest", "daily_max"],
     _HOURS: list[str] = ["weekly_cap", "dept_hours"];

obj Held {
    has shift_id: str,
        department_id: str,
        day: int,
        start: int,
        end: int;

    def hours -> float {
        return (self.end - self.start) / 60;
    }
}

obj Block {
    has day: int,
        start: int,
        end: int,
        title: str = "Busy";
}

obj Verdict {
    has ok: bool,
        code: str = "",
        hours_left: float = 0.0,
        cross_department: bool = False;

    def public_reason -> str {
        if self.ok {
            return "";
        }
        if self.code in _TIMING {
            return CONFLICT;
        }
        if self.code in _HOURS {
            return HOUR_LIMIT;
        }
        return self.code;
    }

    def is_timing -> bool {
        return self.code in _TIMING;
    }

    def is_hours -> bool {
        return self.code in _HOURS;
    }
}

obj Ledger {
    has week: str,
        _students: dict[str, Employee] = {},
        _busy: dict[str, list[Block]] = {},
        _held: dict[str, list[Held]] = {},
        _allot: dict[str, int] = {},
        _has_allot: dict[str, bool] = {},
        _roles: dict[str, list[str]] = {};

    # ---------- loading ----------
    def student(sid: str) -> Employee {
        if sid not in self._students {
            st = employee_of(sid);
            if st is None {
                raise ValueError(f"Unknown employee {sid}");
            }
            self._students[sid] = st;
        }
        return self._students[sid];
    }

    def busy(sid: str) -> list[Block] {
        if sid not in self._busy {
            st = self.student(sid);
            wk = self.week;
            rows = [st --> [?:BusyBlock]];
            self._busy[sid] = [
                Block(day=b.day, start=b.start, end=b.end, title=b.title)
                for b in rows
                if b.week == "" or b.week == wk
            ];
        }
        return self._busy[sid];
    }

    def held(sid: str) -> list[Held] {
        if sid not in self._held {
            st = self.student(sid);
            wk = self.week;
            rows = [_q for _q in [st --> [?:Shift, week == wk]] if _q.status == "published"];
            self._held[sid] = [
                Held(
                    shift_id=jid(s),
                    department_id=s.employer,
                    day=s.day,
                    start=s.start,
                    end=s.end
                )
                for s in rows
                if s.student == sid
            ];
        }
        return self._held[sid];
    }

    def _key(sid: str, did: str) -> str {
        return sid + "|" + did;
    }

    def allotment(sid: str, did: str) -> int | None {
        key = self._key(sid, did);
        if key not in self._has_allot {
            st = self.student(sid);
            rows = [_q for _q in [st --> [?:Employment, employer == did]] if _q.state == "active"];
            if rows {
                self._allot[key] = rows[0].hours;
                self._roles[key] = [str(x) for x in (rows[0].positions or [])];
                self._has_allot[key] = True;
            } else {
                self._roles[key] = [];
                self._has_allot[key] = False;
            }
        }
        if self._has_allot[key] {
            return self._allot[key];
        }
        return None;
    }

    """Pretend (in memory) that the employee has a job with this employer: used by recruiting."""
    def set_allotment(sid: str, did: str, hours: int | None, roles: list[str]) {
        key = self._key(sid, did);
        if hours is None {
            self._has_allot[key] = False;
            self._allot.pop(key, None);
        } else {
            self._has_allot[key] = True;
            self._allot[key] = hours;
        }
        self._roles[key] = list(roles);
    }

    def roles(sid: str, did: str) -> list[str] {
        self.allotment(sid, did);
        return self._roles.get(self._key(sid, did), []);
    }

    """Shifts tied to a position can only go to employees who hold it."""
    def qualified(sid: str, did: str, pid: str) -> bool {
        return not pid or pid in self.roles(sid, did);
    }

    def clone -> Ledger {
        other = Ledger(week=self.week);
        other._students = self._students;
        other._busy = self._busy;
        other._allot = dict(self._allot);
        other._has_allot = dict(self._has_allot);
        other._roles = dict(self._roles);
        copy: dict[str, list[Held]] = {};
        for (k, v) in self._held.items() {
            copy[k] = [
                Held(
                    shift_id=h.shift_id,
                    department_id=h.department_id,
                    day=h.day,
                    start=h.start,
                    end=h.end
                )
                for h in v
            ];
        }
        other._held = copy;
        return other;
    }

    # ---------- mutation (in memory only) ----------
    def add(sid: str, h: Held) {
        self.held(sid).append(h);
    }

    def remove(sid: str, shift_id: str) {
        self._held[sid] = [h for h in self.held(sid) if h.shift_id != shift_id];
    }

    # ---------- measures ----------
    def total_hours(sid: str) -> float {
        return sum([h.hours() for h in self.held(sid)]);
    }

    def dept_hours(sid: str, did: str) -> float {
        return sum([h.hours() for h in self.held(sid) if h.department_id == did]);
    }

    def day_hours(sid: str, day: int) -> float {
        return sum([h.hours() for h in self.held(sid) if h.day == day]);
    }

    def cap(sid: str) -> int {
        return self.student(sid).cap();
    }

    def cap_left(sid: str) -> float {
        return max(0.0, self.cap(sid) - self.total_hours(sid));
    }

    """Hours this employer may still schedule. The only hour number an employer ever sees."""
    def hours_left(sid: str, did: str) -> float {
        allot = self.allotment(sid, did);
        if allot is None {
            return 0.0;
        }
        return max(
            0.0,
            min(self.cap(sid) - self.total_hours(sid), allot - self.dept_hours(sid, did))
        );
    }

    # ---------- Conflict Agent ----------
    def conflict(
        sid: str, day: int, start: int, end: int, ignore: list[str], did: str
    ) -> Verdict {
        for b in self.busy(sid) {
            if b.day == day and overlaps(start, end, b.start, b.end) {
                return Verdict(ok=False, code="overlap", cross_department=False);
            }
        }
        for h in self.held(sid) {
            if h.shift_id in ignore {
                continue;
            }
            if h.day == day and overlaps(start, end, h.start, h.end) {
                return Verdict(ok=False, code="overlap", cross_department=h.department_id != did);
            }
        }
        return Verdict(ok=True);
    }

    # ---------- Compliance Checker ----------
    def compliance(
        sid: str, did: str, day: int, start: int, end: int, ignore: list[str]
    ) -> Verdict {
        add = (end - start) / 60;
        held = [h for h in self.held(sid) if h.shift_id not in ignore];
        allot = self.allotment(sid, did);
        if allot is None {
            return Verdict(ok=False, code="not_on_team");
        }
        total = sum([h.hours() for h in held]);
        dept = sum([h.hours() for h in held if h.department_id == did]);
        left = max(0.0, min(self.cap(sid) - total, allot - dept));
        if total + add > self.cap(sid) + 1e-9 {
            return Verdict(
                ok=False, code="weekly_cap", hours_left=left, cross_department=total - dept > 0
            );
        }
        if dept + add > allot + 1e-9 {
            return Verdict(ok=False, code="dept_hours", hours_left=left);
        }
        same_day = [h for h in held if h.day == day];
        if sum([h.hours() for h in same_day]) + add > self.student(sid).daily_max() + 1e-9 {
            return Verdict(
                ok=False,
                code="daily_max",
                hours_left=left,
                cross_department=any([h.department_id != did for h in same_day])
            );
        }
        for h in same_day {
            gap = start - h.end if start >= h.end else h.start - end;
            if 0 <= gap and gap < MIN_REST_MINUTES {
                return Verdict(
                    ok=False, code="rest", hours_left=left, cross_department=h.department_id != did
                );
            }
        }
        return Verdict(ok=True, hours_left=left);
    }

    """Conflict first, then compliance (if both apply, report schedule_conflict)."""
    def check(
        sid: str,
        did: str,
        day: int,
        start: int,
        end: int,
        ignore: list[str] | None = None,
        pid: str = ""
    ) -> Verdict {
        ign: list[str] = ignore if ignore is not None else [];
        if self.allotment(sid, did) is None {
            return Verdict(ok=False, code="not_on_team");
        }
        if not self.qualified(sid, did, pid) {
            return Verdict(ok=False, code=NOT_QUALIFIED);
        }
        v = self.conflict(sid, day, start, end, ign, did);
        if not v.ok {
            v.hours_left = self.hours_left(sid, did);
            return v;
        }
        return self.compliance(sid, did, day, start, end, ign);
    }

    # ---------- whole-week validation (used for swaps) ----------
    """Every hard rule against the employee's full week as it currently stands in this ledger."""
    def violations(sid: str) -> list[str] {
        out: list[str] = [];
        held = self.held(sid);
        for (i, a) in enumerate(held) {
            for b in self.busy(sid) {
                if a.day == b.day and overlaps(a.start, a.end, b.start, b.end) {
                    out.append("overlap");
                }
            }
            for c in held[i + 1:] {
                if a.day == c.day {
                    if overlaps(a.start, a.end, c.start, c.end) {
                        out.append("overlap");
                    } else {
                        gap = c.start - a.end if c.start >= a.end else a.start - c.end;
                        if gap < MIN_REST_MINUTES {
                            out.append("rest");
                        }
                    }
                }
            }
        }
        if self.total_hours(sid) > self.cap(sid) + 1e-9 {
            out.append("weekly_cap");
        }
        for did in sorted({h.department_id for h in held}) {
            allot = self.allotment(sid, did);
            if allot is None or self.dept_hours(sid, did) > allot + 1e-9 {
                out.append("dept_hours");
            }
        }
        for day in sorted({h.day for h in held}) {
            if self.day_hours(sid, day) > self.student(sid).daily_max() + 1e-9 {
                out.append("daily_max");
            }
        }
        return out;
    }
}
