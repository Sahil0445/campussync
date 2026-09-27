"""Coordinator workflow for 'Generate schedule' + the Scheduling Agent.

Flow: Coordinator -> Availability -> Conflict (rules) -> Scheduling (AI proposes) ->
Compliance (rules validate every proposal) -> greedy backfill -> Explainer.
The AI makes the judgment calls (who takes Saturday, fairness); the rules decide what is allowed.
"""

import from datetime { date }
import from server.clock { now_s }
import from server.timeutil { DAY_SHORT, fmt_hours, hm, slot_label }
import from server.trace { Trace }
import from server.rules { Held, Ledger }
import from server.notify { log_event }
import from server.models {
    Employer,
    Employee,
    Employment,
    Position,
    Requirement,
    Draft,
    Shift,
    put,
    add_shift,
    employee_of,
    position_of
}
import server.ai as ai;

obj Seat {
    has key: str,
        day: int,
        start: int,
        end: int,
        pid: str = "",
        role: str = "";

    def hours -> float {
        return (self.end - self.start) / 60;
    }

    def label -> str {
        return slot_label(self.day, self.start, self.end) + (f" · {self.role}" if self.role else "");
    }
}

obj SlotInfo {
    has day: int,
        start: int,
        end: int,
        pid: str,
        role: str,
        needed: int = 0,
        have: int = 0;
}

def slot_key(day: int, start: int, end: int, pid: str) -> str {
    return f"{day}-{start}-{end}-{pid or 0}";
}

def position_names(e: Employer) -> dict[str, str] {
    return {jid(p): p.name for p in [e --> [?:Position]]};
}

def period_of(day: int, start: int, end: int) -> set[str] {
    mid = (start + end) / 2;
    out: set[str] = set();
    out.add("Mornings" if mid < 12 * 60 else ("Afternoons" if mid < 17 * 60 else "Evenings"));
    if day >= 5 {
        out.add("Weekends");
    }
    return out;
}

"""Active team members, by name."""
def team_of(e: Employer) -> list[Employee] {
    out: list[Employee] = [];
    for emp in [_q for _q in [e --> [?:Employment]] if _q.state == "active"] {
        st = employee_of(emp.student);
        if st is not None {
            out.append(st);
        }
    }
    return sorted(out, key=lambda (s: Employee) -> tuple[str, str] { return (s.name, s.created); });
}

"""Open seats (one per missing headcount) and per-slot bookkeeping."""
def seats_for_week(e: Employer, week: str) -> tuple[list[Seat], dict[str, SlotInfo]] {
    reqs = [e --> [?:Requirement]];
    wk = week;
    published = [
        s for s in [_q for _q in [e --> [?:Shift, week == wk]] if _q.status == "published"] if s.student
    ];
    roles = position_names(e);
    slots: dict[str, SlotInfo] = {};
    seats: list[Seat] = [];
    ordered = sorted(
        reqs,
        key=lambda (r: Requirement) -> tuple[int, int, str] { return (r.day, r.start, r.position or ""); }
    );
    for r in ordered {
        pid = r.position if r.position in roles else "";
        key = slot_key(r.day, r.start, r.end, pid);
        if key not in slots {
            have = len(
                [
                    s
                    for s in published
                    if s.day == r.day and s.start == r.start and s.end == r.end and s.position == pid
                ]
            );
            slots[key] = SlotInfo(
                day=r.day,
                start=r.start,
                end=r.end,
                pid=pid,
                role=roles.get(pid, "") if pid else "",
                needed=0,
                have=have
            );
        }
        slots[key].needed += r.headcount;
    }
    for (key, slot) in slots.items() {
        for _i in range(max(0, slot.needed - slot.have)) {
            seats.append(
                Seat(key=key, day=slot.day, start=slot.start, end=slot.end, pid=slot.pid, role=slot.role)
            );
        }
    }
    return (seats, slots);
}

obj Proposal {
    has picks: dict[str, list[str]] = {},
        notes: dict[str, str] = {};
}

def _ai_propose(
    seats: list[Seat], cands: dict[str, list[str]], team: list[Employee], ledger: Ledger, did: str
) -> Proposal | None {
    if not ai.ready() {
        return None;
    }
    alias: dict[str, str] = {};
    back: dict[str, str] = {};
    for (i, st) in enumerate(team) {
        alias[jid(st)] = f"p{i + 1}";
        back[f"p{i + 1}"] = jid(st);
    }
    by_key: dict[str, ai.SlotAsk] = {};
    for s in seats {
        if s.key not in by_key {
            by_key[s.key] = ai.SlotAsk(
                slot=s.key,
                label=s.label(),
                hours=s.hours(),
                need=0,
                eligible=[alias[x] for x in cands[s.key] if x in alias]
            );
        }
        by_key[s.key].need += 1;
    }
    people: list[ai.PersonAsk] = [];
    for st in team {
        sid = jid(st);
        people.append(
            ai.PersonAsk(
                id=alias[sid],
                name=st.first_name(),
                hours_with_you=ledger.dept_hours(sid, did),
                can_take_more=ledger.hours_left(sid, did),
                assigned_hours=ledger.allotment(sid, did) or 0,
                weekend_shifts=len(
                    [h for h in ledger.held(sid) if h.day >= 5 and h.department_id == did]
                )
            )
        );
    }
    try {
        plan = ai.plan_week(list(by_key.values()), people);
        picks: dict[str, list[str]] = {};
        for a in plan.assignments {
            picks[str(a.slot)] = [back[str(x)] for x in a.people if str(x) in back];
        }
        notes: dict[str, str] = {};
        for n in plan.notes {
            if str(n.id) in back {
                notes[back[str(n.id)]] = str(n.note)[:120];
            }
        }
        ai.succeeded();
        return Proposal(picks=picks, notes=notes);
    } except Exception as ex {
        ai.failed(ex);
        return None;
    }
}

"""Fallback judgment. Lower is better."""
def _score(
    st: Employee, seat: Seat, ledger: Ledger, did: str, allot: int
) -> tuple[int, float, str] {
    sid = jid(st);
    fill = ledger.dept_hours(sid, did) / max(1, allot);
    prefs = set(st.preferences or []);
    pref_hit = 0 if (not prefs or (prefs & period_of(seat.day, seat.start, seat.end))) else 1;
    weekend = len([h for h in ledger.held(sid) if h.day >= 5]) if seat.day >= 5 else 0;
    return (pref_hit + weekend, round(fill, 3), st.created);
}

glob _temp: int = 0;

def _temp_id() -> str {
    _temp = _temp + 1;
    return f"tmp-{_temp}";
}

def generate(e: Employer, week: str, origin: str = "manual") -> Draft {
    did = jid(e);
    wk = week;
    for old in [_q for _q in [e --> [?:Draft, week == wk]] if _q.state == "draft"] {
        discard(e, old);
    }
    tr = Trace();
    wkd = date.fromisoformat(week);
    tr.step("Coordinator", "agent", f"started workflow for week of {wkd.strftime('%b')} {wkd.day}");
    team = team_of(e);
    ledger = Ledger(week=week);
    for st in team {
        ledger.busy(jid(st));
    }
    tr.step("Availability Agent", "agent", f"read {len(team)} team calendars");

    (seats, slots) = seats_for_week(e, week);
    allot: dict[str, int] = {jid(st): (ledger.allotment(jid(st), did) or 0) for st in team};
    before_hours: dict[str, float] = {jid(st): ledger.dept_hours(jid(st), did) for st in team};

    # Conflict Agent: blind cross-employer pass
    cands: dict[str, list[str]] = {};
    cross_pairs: set[str] = set();
    for seat in seats {
        if seat.key in cands {
            continue;
        }
        ok_ids: list[str] = [];
        for st in team {
            v = ledger.check(jid(st), did, seat.day, seat.start, seat.end, pid=seat.pid);
            if v.ok {
                ok_ids.append(jid(st));
            } elif v.is_timing() and v.cross_department {
                cross_pairs.add(jid(st) + "|" + seat.key);
            }
        }
        cands[seat.key] = ok_ids;
    }
    n_cross = len(cross_pairs);
    tr.step(
        "Conflict Agent",
        "rules",
        f"found {n_cross} overlap{'s' if n_cross != 1 else ''} with other jobs",
        status="blocked" if n_cross else "done"
    );

    # Scheduling Agent: AI proposal, then rules validate each pick
    order = sorted(
        seats,
        key=lambda (s: Seat) -> tuple[int, int, int] { return (len(cands[s.key]), s.day, s.start); }
    );
    assigned: list[tuple[Seat, str]] = [];
    removed = 0;
    ai_notes: dict[str, str] = {};
    proposal: Proposal | None = _ai_propose(seats, cands, team, ledger, did) if seats and team else None;
    used_ai = proposal is not None;
    remaining = list(order);
    if proposal is not None {
        ai_notes = proposal.notes;
        still: list[Seat] = [];
        for seat in order {
            queue = proposal.picks.get(seat.key, []);
            placed = False;
            while queue and not placed {
                sid = queue.pop(0);
                if sid not in allot {
                    continue;
                }
                v = ledger.check(sid, did, seat.day, seat.start, seat.end, pid=seat.pid);
                if v.ok {
                    ledger.add(
                        sid,
                        Held(shift_id=_temp_id(), department_id=did, day=seat.day, start=seat.start, end=seat.end)
                    );
                    assigned.append((seat, sid));
                    placed = True;
                } else {
                    removed += 1;
                }
            }
            if not placed {
                still.append(seat);
            }
        }
        remaining = still;
    }

    # Greedy backfill (also the whole algorithm when the model is unavailable)
    while remaining {
        best_seat: Seat | None = None;
        best_ok: list[Employee] = [];
        for seat in remaining {
            ok = [
                st
                for st in team
                if ledger.check(jid(st), did, seat.day, seat.start, seat.end, pid=seat.pid).ok
            ];
            if best_seat is None or len(ok) < len(best_ok) {
                best_seat = seat;
                best_ok = ok;
            }
        }
        if best_seat is None {
            break;
        }
        pick_seat: Seat = best_seat;
        remaining.remove(pick_seat);
        if not best_ok {
            continue;
        }
        pick = min(
            best_ok,
            key=lambda (st: Employee) -> tuple[int, float, str] {
                return _score(st, pick_seat, ledger, did, allot[jid(st)]);
            }
        );
        ledger.add(
            jid(pick),
            Held(
                shift_id=_temp_id(),
                department_id=did,
                day=pick_seat.day,
                start=pick_seat.start,
                end=pick_seat.end
            )
        );
        assigned.append((pick_seat, jid(pick)));
    }

    if removed {
        tr.step(
            "Compliance Checker",
            "rules",
            f"removed {removed} assignment{'s' if removed != 1 else ''} over hour cap or conflicting",
            status="blocked"
        );
    } else {
        tr.step("Compliance Checker", "rules", "every assignment within hour limits");
    }

    total_needed = sum([s.needed for s in slots.values()]);
    total_have = sum([min(s.have, s.needed) for s in slots.values()]);
    filled = total_have + len(assigned);
    tr.step("Scheduling Agent", "agent", f"filled {filled} of {total_needed} slots", ai=used_ai);

    # Gaps: flagged, never hidden
    filled_per_slot: dict[str, int] = {};
    for (seat, _sid) in assigned {
        filled_per_slot[seat.key] = filled_per_slot.get(seat.key, 0) + 1;
    }
    gaps: list[dict[str, any]] = [];
    for (key, slot) in slots.items() {
        found = slot.have + filled_per_slot.get(key, 0);
        if found < slot.needed {
            gaps.append(
                {
                    "day": slot.day,
                    "start": slot.start,
                    "end": slot.end,
                    "position_id": slot.pid or None,
                    "role": slot.role,
                    "label": slot_label(slot.day, slot.start, slot.end) + (f" · {slot.role}" if slot.role else ""),
                    "needed": slot.needed,
                    "found": found,
                    "reason": _gap_reason(team, ledger, did, slot)
                }
            );
        }
    }
    gaps.sort(key=lambda (g: dict[str, any]) -> tuple[int, int] { return (g["day"], g["start"]); });
    open_seats = sum([g["needed"] - g["found"] for g in gaps]);

    # Draft rows
    draft = Draft(employer=did, week=week, state="draft", origin=origin, created=now_s());
    put(e, draft);
    new_by_student: dict[str, list[Seat]] = {};
    new_ids: list[str] = [];
    for (seat, sid) in assigned {
        sh = add_shift(
            e,
            Shift(
                week=week,
                day=seat.day,
                start=seat.start,
                end=seat.end,
                position=seat.pid,
                student=sid,
                state="assigned",
                status="draft",
                draft=jid(draft),
                source="generated"
            )
        );
        new_ids.append(jid(sh));
        new_by_student.setdefault(sid, []).append(seat);
    }

    students_summary: list[dict[str, any]] = [];
    lowest = min(list(before_hours.values())) if before_hours else 0.0;
    for st in team {
        sid = jid(st);
        mine = new_by_student.get(sid, []);
        hrs = ledger.dept_hours(sid, did);
        why = ai_notes.get(sid) or _fallback_note(st, mine, before_hours[sid], lowest, hrs, allot[sid]);
        students_summary.append(
            {
                "student_id": sid,
                "name": st.first_name(),
                "full_name": st.name,
                "hours": hrs,
                "allotment": allot[sid],
                "new_shifts": len(mine),
                "line": f"{st.first_name()} · {fmt_hours(hrs)} of {allot[sid]} hrs · all within availability",
                "why": why
            }
        );
    }

    if gaps {
        tr.step(
            "Explainer",
            "agent",
            f"{open_seats} slot{'s' if open_seats != 1 else ''} still open — flagged for you",
            status="blocked",
            ai=used_ai
        );
    } else {
        tr.step("Explainer", "agent", "every slot is covered", ai=used_ai);
    }
    tr.final("Schedule ready for review");

    draft.trace = tr.rows;
    draft.summary = {
        "filled": filled,
        "needed": total_needed,
        "open_seats": open_seats,
        "gaps": gaps,
        "students": students_summary,
        "new_shift_ids": new_ids,
        "ai": used_ai,
        "fallback": tr.fallback_used
    };
    gap_note = f" · {open_seats} gap{'s' if open_seats != 1 else ''} flagged" if open_seats else "";
    log_event(
        "Scheduling Agent",
        f"Drafted week of {wkd.strftime('%b')} {wkd.day} · {filled}/{total_needed} slots filled{gap_note} · awaiting your approval",
        employer=e,
        level="action",
        link=f"/d/drafts/{jid(draft)}"
    );
    return draft;
}

"""(open seats, seats at least one team member could take right now)."""
def fillable_seats(e: Employer, week: str) -> tuple[int, int] {
    (seats, _slots) = seats_for_week(e, week);
    team = team_of(e);
    ledger = Ledger(week=week);
    did = jid(e);
    fillable = 0;
    for s in seats {
        if any([ledger.check(jid(st), did, s.day, s.start, s.end, pid=s.pid).ok for st in team]) {
            fillable += 1;
        }
    }
    return (len(seats), fillable);
}

def _gap_reason(team: list[Employee], ledger: Ledger, did: str, slot: SlotInfo) -> str {
    if not team {
        return "No one on your team yet — share your join code.";
    }
    pid = slot.pid;
    if pid and not any([ledger.qualified(jid(st), did, pid) for st in team]) {
        return f"No one on your team has the {slot.role or 'required'} role yet.";
    }
    free_but_hours = 0;
    for st in team {
        v = ledger.check(jid(st), did, slot.day, slot.start, slot.end, pid=pid);
        if v.ok {
            return "Someone is available — try generating again.";
        }
        if v.is_hours() {
            free_but_hours += 1;
        }
    }
    if free_but_hours {
        return "Everyone available is at their weekly limit.";
    }
    return "No one on your team is free at this time.";
}

def _fallback_note(
    st: Employee, mine: list[Seat], before: float, lowest: float, after: float, allot: int
) -> str {
    if not mine {
        if after >= allot {
            return "Already at their hours with you.";
        }
        return "No open slot fits their availability and limits.";
    }
    prefs = set(st.preferences or []);
    parts: list[str] = [];
    hits = [p for p in prefs if any([p in period_of(s.day, s.start, s.end) for s in mine])];
    if hits {
        parts.append(f"Prefers {sorted(hits)[0].lower()}");
    }
    if before == 0 {
        parts.append("had no shifts yet");
    } elif before <= lowest {
        parts.append("fewest hours so far");
    }
    if any([s.day >= 5 for s in mine]) and "Weekends" not in hits {
        parts.append("free on the weekend");
    }
    if not parts {
        dset = sorted({s.day for s in mine});
        days = ", ".join([DAY_SHORT[d] for d in dset]);
        parts.append(f"Free {days} and under their hours");
    }
    text = "; ".join(parts);
    return text[0].upper() + text[1:];
}

def discard(e: Employer, draft: Draft) {
    dj = jid(draft);
    for sh in [_q for _q in [e --> [?:Shift, draft == dj]] if _q.status == "draft"] {
        del sh;
    }
    draft.state = "discarded";
}

"""Re-validate at publish time: another employer may have published since the draft was made."""
def publish(e: Employer, draft: Draft) -> dict[str, any] {
    ledger = Ledger(week=draft.week);
    counts: dict[str, int] = {};
    dropped = 0;
    dj = jid(draft);
    rows = sorted(
        list([_q for _q in [e --> [?:Shift, draft == dj]] if _q.status == "draft"]),
        key=lambda (s: Shift) -> str { return s.created; }
    );
    for sh in rows {
        v = ledger.check(sh.student, sh.employer, sh.day, sh.start, sh.end, pid=sh.position);
        if v.ok {
            sh.status = "published";
            ledger.add(
                sh.student,
                Held(shift_id=jid(sh), department_id=sh.employer, day=sh.day, start=sh.start, end=sh.end)
            );
            counts[sh.student] = counts.get(sh.student, 0) + 1;
        } else {
            del sh;
            dropped += 1;
        }
    }
    draft.state = "published";
    n = len(counts);
    log_event(
        "Coordinator",
        f"Schedule published · {n} {'person' if n == 1 else 'people'} notified"
            + (f" · {dropped} changed since draft and were dropped" if dropped else ""),
        kind="human",
        employer=e,
        level="done"
    );
    for (sid, cnt) in counts.items() {
        st = employee_of(sid);
        if st is not None {
            log_event(
                "Scheduling Agent",
                f"{cnt} new shift{'s' if cnt != 1 else ''} added to your week",
                student=st,
                level="done"
            );
        }
    }
    return {"notified": counts, "dropped": dropped};
}

def describe_slot(day: int, start: int, end: int) -> str {
    return f"{DAY_SHORT[day]} {hm(start)}–{hm(end)}";
}
