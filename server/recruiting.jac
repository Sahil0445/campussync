"""Recruiting Agent -- when a slot can't be filled from the team, look across campus.

Campus employers only: the pool is student employees at the same university who aren't on the team.
Businesses never see anyone outside their own team. Proposes students who are free (per their own
calendar) and under their limits; the manager approves once; the student's autopilot (or the
student) accepts; the covered slots are then filled automatically.
"""

import from server.clock { now_s }
import from server.timeutil { slot_label }
import from server.rules { Held, Ledger }
import from server.notify { log_event, to_student, to_employer }
import from server.scheduling { period_of }
import from server.models {
    Employer,
    Employee,
    Employment,
    Requirement,
    Shift,
    RecruitProposal,
    put,
    also,
    add_shift,
    employees,
    employee_of,
    employer_of,
    employment_between
}

def _k(day: int, start: int, end: int, pid: str) -> str {
    return f"{day}|{start}|{end}|{pid or 0}";
}

"""Seats still missing after published shifts AND any pending draft."""
def gaps(e: Employer, week: str) -> list[dict[str, any]] {
    reqs = [e --> [?:Requirement]];
    wk = week;
    shifts = [
        s for s in [e --> [?:Shift, week == wk]] if s.student and s.status in ("published", "draft")
    ];
    need: dict[str, int] = {};
    info: dict[str, tuple[int, int, int, str]] = {};
    for r in reqs {
        k = _k(r.day, r.start, r.end, r.position);
        need[k] = need.get(k, 0) + r.headcount;
        info[k] = (r.day, r.start, r.end, r.position or "");
    }
    out: list[dict[str, any]] = [];
    keys = sorted(
        need.keys(),
        key=lambda (k: str) -> tuple[int, int, int, str] { return info[k]; }
    );
    for k in keys {
        (day, start, end, pid) = info[k];
        n = need[k];
        have = len(
            [
                s for s in shifts
                if s.day == day and s.start == start and s.end == end and (s.position or "") == pid
            ]
        );
        if have < n {
            out.append(
                {"day": day, "start": start, "end": end, "position_id": pid or None, "missing": n - have}
            );
        }
    }
    return out;
}

def _same(c: dict[str, any], g: dict[str, any]) -> bool {
    return _k(c["day"], c["start"], c["end"], c.get("position_id") or "")
        == _k(g["day"], g["start"], g["end"], g.get("position_id") or "");
}

"""Student employees at the same university who aren't on this team. Businesses have no pool."""
def _pool(e: Employer) -> list[Employee] {
    if e.kind != "campus" or not e.university {
        return [];
    }
    linked = {
        emp.student for emp in [e --> [?:Employment]] if emp.state in ("active", "invited")
    };
    uni = e.university;
    rows = [s for s in employees() if s.kind == "student" and s.school == uni];
    rows = sorted(rows, key=lambda (s: Employee) -> tuple[str, str] { return (s.name, s.created); });
    return [s for s in rows if jid(s) not in linked];
}

def _can_cover(
    ledger: Ledger, sid: str, did: str, day: int, start: int, end: int, hours: int, pid: str
) -> bool {
    saved = ledger.allotment(sid, did);
    saved_roles = list(ledger.roles(sid, did));
    ledger.set_allotment(sid, did, hours, saved_roles + ([pid] if pid else []));
    ok = ledger.check(sid, did, day, start, end, pid=pid).ok;
    ledger.set_allotment(sid, did, saved, saved_roles);
    return ok;
}

obj RecruitPlan {
    has student: Employee,
        covers: list[dict[str, any]] = [],
        hours: float = 0.0;
}

def recruit(e: Employer, week: str) -> list[RecruitProposal] {
    open_gaps = gaps(e, week);
    if not open_gaps {
        return [];
    }
    did = jid(e);
    wk = week;
    pending = [p for p in [e --> [?:RecruitProposal, week == wk]] if p.state in ("proposed", "invited")];
    covered: dict[str, int] = {};
    for p in pending {
        for c in p.covers {
            k = _k(c["day"], c["start"], c["end"], c.get("position_id") or "");
            covered[k] = covered.get(k, 0) + 1;
        }
    }
    rejected = {p.student for p in [e --> [?:RecruitProposal]] if p.state in ("rejected", "declined")};
    pending_ids = {p.student for p in pending};
    ledger = Ledger(week=week);
    pool = [s for s in _pool(e) if jid(s) not in rejected and jid(s) not in pending_ids];
    made: list[RecruitProposal] = [];
    plans: dict[str, RecruitPlan] = {};
    order: list[str] = [];
    for g in open_gaps {
        gpid = g.get("position_id") or "";
        todo = g["missing"] - covered.get(_k(g["day"], g["start"], g["end"], gpid), 0);
        for _i in range(max(0, todo)) {
            slot_h = (g["end"] - g["start"]) / 60;
            best_score: tuple[int, float, str] | None = None;
            best_st: Employee | None = None;
            best_hours = 0;
            for st in pool {
                sid = jid(st);
                plan_hours = plans[sid].hours if sid in plans else 0.0;
                plan_covers = plans[sid].covers if sid in plans else [];
                hours = int(max(8, plan_hours + slot_h));
                if any(
                    [c["day"] == g["day"] and c["start"] == g["start"] and c["end"] == g["end"] for c in plan_covers]
                ) {
                    continue;
                }
                if not _can_cover(ledger, sid, did, g["day"], g["start"], g["end"], hours, gpid) {
                    continue;
                }
                pref = 0 if set(st.preferences or []) & period_of(g["day"], g["start"], g["end"]) else 1;
                spare = ledger.cap_left(sid);
                score = (pref, -spare, st.created);
                if best_score is None or score < best_score {
                    best_score = score;
                    best_st = st;
                    best_hours = hours;
                }
            }
            if best_st is None {
                break;
            }
            chosen: Employee = best_st;
            cid = jid(chosen);
            if cid not in plans {
                plans[cid] = RecruitPlan(student=chosen);
                order.append(cid);
            }
            pl = plans[cid];
            pl.covers.append(
                {"day": g["day"], "start": g["start"], "end": g["end"], "position_id": g.get("position_id")}
            );
            pl.hours += slot_h;
            ledger.set_allotment(cid, did, best_hours, ledger.roles(cid, did) + ([gpid] if gpid else []));
            ledger.add(
                cid,
                Held(
                    shift_id=f"recruit-{cid}-{len(pl.covers)}",
                    department_id=did,
                    day=g["day"],
                    start=g["start"],
                    end=g["end"]
                )
            );
        }
    }
    for sid in order {
        pl = plans[sid];
        more = ledger.cap_left(sid) + pl.hours;
        hours = int(min(max(pl.hours, 8), max(pl.hours, more)));
        labels = ", ".join([slot_label(c["day"], c["start"], c["end"]) for c in pl.covers]);
        reason = f"Free {labels} per their calendar · can take up to {int(more)} more hrs this week";
        p = RecruitProposal(
            employer=did, student=sid, week=week, hours=hours, covers=pl.covers, reason=reason,
            created=now_s()
        );
        put(e, p);
        made.append(p);
    }
    if made {
        names = ", ".join([plans[p.student].student.first_name() for p in made]);
        slots = sorted({slot_label(c["day"], c["start"], c["end"]) for p in made for c in p.covers});
        log_event(
            "Recruiting Agent",
            f"No one on your team can take {', '.join(slots)} — found {names} on campus · awaiting your approval",
            employer=e,
            level="action",
            link="/d/approvals"
        );
    }
    return made;
}

def approve(p: RecruitProposal) {
    e = employer_of(p.employer);
    st = employee_of(p.student);
    if e is None or st is None {
        return;
    }
    emp = employment_between(st, e);
    roles = sorted({str(c["position_id"]) for c in p.covers if c.get("position_id")});
    active_before = emp is not None and emp.state == "active";
    if emp is not None and emp.state == "active" {
        emp.hours = max(emp.hours, p.hours);
        emp.positions = sorted(set(emp.positions or []) | set(roles));
    } elif emp is not None {
        emp.state = "invited";
        emp.hours = p.hours;
        emp.positions = sorted(set(emp.positions or []) | set(roles));
    } else {
        new_emp = Employment(
            student=jid(st), employer=jid(e), hours=p.hours, state="invited", positions=roles,
            pay_rate=e.default_pay_rate, created=now_s()
        );
        put(e, new_emp);
        also(st, new_emp);
    }
    p.state = "invited";
    covers = ", ".join([slot_label(c["day"], c["start"], c["end"]) for c in p.covers]);
    to_student(st, f"{e.name} invited you · {p.hours} hrs/week (starting with {covers})", "/s");
    log_event(
        "Recruiting Agent", f"Invited {st.first_name()} · {p.hours} hrs/week to cover {covers}",
        kind="human", employer=e, level="info"
    );
    log_event(
        "Recruiting Agent", f"{e.name} wants you for {p.hours} hrs/week, starting {covers}",
        student=st, level="action"
    );
    if active_before {
        fulfil(st, e);
    }
}

"""Employee joined: fill the slots they were recruited for (already approved by the manager)."""
def fulfil(st: Employee, e: Employer) -> int {
    n = 0;
    sid = jid(st);
    did = jid(e);
    for p in [_q for _q in [e --> [?:RecruitProposal, student == sid]] if _q.state == "invited"] {
        ledger = Ledger(week=p.week);
        for c in p.covers {
            pid = c.get("position_id") or "";
            open_seat = any([_same(c, g) for g in gaps(e, p.week)]);
            if open_seat and ledger.check(sid, did, c["day"], c["start"], c["end"], pid=pid).ok {
                sh = add_shift(
                    e,
                    Shift(
                        week=p.week, day=c["day"], start=c["start"], end=c["end"], student=sid,
                        state="assigned", status="published", source="recruit", position=pid
                    )
                );
                ledger.add(
                    sid, Held(shift_id=jid(sh), department_id=did, day=c["day"], start=c["start"], end=c["end"])
                );
                label = slot_label(c["day"], c["start"], c["end"]);
                to_student(st, f"{e.name} added {label} to your week.", "/s");
                log_event(
                    "Scheduling Agent", f"{st.first_name()} joined · filled {label} automatically",
                    employer=e, level="done"
                );
                log_event("Scheduling Agent", f"Added {label} at {e.name} to your week", student=st, level="done");
                n += 1;
            }
        }
        p.state = "filled";
    }
    return n;
}

def reject(p: RecruitProposal) {
    p.state = "rejected";
    st = employee_of(p.student);
    log_event(
        "Recruiting Agent",
        f"Skipped {st.first_name() if st is not None else 'them'} — won't suggest them again",
        kind="human",
        employer=employer_of(p.employer),
        level="info"
    );
}

def on_invite_answer(st: Employee, e: Employer, accepted: bool) {
    if accepted {
        to_employer(e, f"{st.first_name()} joined your team.", "/d/team");
        fulfil(st, e);
    } else {
        sid = jid(st);
        for p in [_q for _q in [e --> [?:RecruitProposal, student == sid]] if _q.state == "invited"] {
            p.state = "declined";
        }
        log_event(
            "Recruiting Agent", f"{st.first_name()} declined — looking for someone else", employer=e, level="alert"
        );
    }
}
