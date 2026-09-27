"""Employer endpoints: coverage, the blind availability check, drafts, swaps, open shifts.

An employer NEVER receives another employer's name, shifts or hours -- not in data, not in errors.
Hidden information is reduced to: available / unavailable, and "hours you can still assign".
"""

import from datetime { date, timedelta }
import from server.clock { utcnow, now_s, iso, seconds_since }
import from server.config { PROBE_LIMIT_PER_HOUR }
import from server.timeutil { DAY_LONG, DAY_SHORT, hm, slot_label }
import from server.trace { Trace }
import from server.rules { Ledger, CONFLICT, HOUR_LIMIT }
import from server.notify { to_student, log_event }
import from server.models {
    Employer,
    Employee,
    Employment,
    Position,
    Probe,
    Requirement,
    Draft,
    Shift,
    SwapRequest,
    SwapLoop,
    SwapOffer,
    put,
    also,
    add_shift,
    employees,
    employee_of,
    position_of,
    draft_of,
    request_of,
    loop_of,
    shift_of,
    employment_between
}
import from server.scheduling { team_of, period_of }
import from server.api_common { UNSET, opt, ApiError, guarded, me_employer, week_arg }
import server.scheduling as scheduling;
import server.swaps as swaps;

# ------------------------------------------------------------------ helpers
"""'Mon Sep 28 11:00-15:00' -- notifications need the date, not just the weekday."""
def dated(week: str, day: int, start: int, end: int) -> str {
    d = date.fromisoformat(week) + timedelta(days=day);
    return f"{DAY_SHORT[day]} {d.strftime('%b')} {d.day} {hm(start)}–{hm(end)}";
}

def team_member(d: Employer, sid: str, allow_invited: bool = False) -> Employee {
    st = employee_of(sid);
    emp = employment_between(st, d) if st is not None else None;
    if st is None or emp is None or (emp.state != "active" and not (allow_invited and emp.state == "invited")) {
        raise ApiError("This person isn't on your team yet.");
    }
    return st;
}

def position_arg(d: Employer, pid: any) -> str {
    if pid is None or pid == "" or pid == 0 or pid == "0" {
        return "";
    }
    p = position_of(str(pid));
    if p is None or p.employer != jid(d) {
        raise ApiError("That role doesn't exist.");
    }
    return jid(p);
}

def slot_args(day: any, start: any, end: any) -> tuple[int, int, int] {
    if day is None or start is None or end is None or day == "" or start == "" or end == "" {
        raise ApiError("Missing " + ("day" if day is None or day == "" else ("start" if start is None or start == "" else "end")) + ".");
    }
    try {
        (d, s, e) = (int(day), int(start), int(end));
        if not (0 <= d and d <= 6 and 0 <= s and s < e and e <= 24 * 60) {
            raise ApiError("That time slot isn't valid.");
        }
        return (d, s, e);
    } except ApiError as ae {
        raise ae;
    } except Exception {
        raise ApiError("That time slot isn't valid.");
    }
}

"""Minimum disclosure: rate-limit availability probes so an employer can't map an employee's week."""
def probe(d: Employer, sid: str) {
    since = iso(utcnow() - timedelta(hours=1));
    n = len([p for p in [d --> [?:Probe, student == sid]] if p.created >= since]);
    if n >= PROBE_LIMIT_PER_HOUR {
        raise ApiError(
            "You've checked this student many times in the last hour. Try again later — this protects their privacy."
        );
    }
    put(d, Probe(employer=jid(d), student=sid, created=now_s()));
}

def suggestions(
    ledger: Ledger, sid: str, did: str, reqs: list[Requirement], day: int, start: int, end: int
) -> list[str] {
    dur = end - start;
    options: list[tuple[int, int, int]] = [];
    for step in range(60, 8 * 60, 60) {
        options.append((day, start + step, end + step));  # later the same day
    }
    ordered = sorted(
        reqs, key=lambda (r: Requirement) -> tuple[int, int] { return ((r.day - day) % 7, r.start); }
    );
    for r in ordered {
        if r.end - r.start >= dur {
            options.append((r.day, r.start, r.start + dur));
        }
    }
    options.append(((day + 1) % 7, start, end));
    out: list[str] = [];
    for (dd, s, e) in options {
        if e > 22 * 60 or (dd == day and s == start) {
            continue;
        }
        label = f"{DAY_SHORT[dd]} {hm(s)}-{hm(e)}";
        if label not in out and ledger.check(sid, did, dd, s, e).ok {
            out.append(label);
        }
        if len(out) == 2 {
            break;
        }
    }
    return out;
}

"""The privacy-safe answer. Exactly these shapes, no extra fields."""
def check_view(d: Employer, ledger: Ledger, st: Employee, day: int, start: int, end: int, pid: str = "") -> dict[str, any] {
    did = jid(d);
    sid = jid(st);
    if not ledger.qualified(sid, did, pid) {
        role = position_of(pid);
        raise ApiError(
            f"{st.first_name()} doesn't have the {role.name if role is not None else 'required'} role. Add it on the Team page first."
        );
    }
    v = ledger.check(sid, did, day, start, end, pid=pid);
    if v.ok {
        return {"available": True, "hours_left": ledger.hours_left(sid, did)};
    }
    if v.public_reason() == CONFLICT {
        return {
            "available": False,
            "reason": "schedule_conflict",
            "suggestions": suggestions(ledger, sid, did, [d --> [?:Requirement]], day, start, end)
        };
    }
    if v.public_reason() == HOUR_LIMIT {
        return {"available": False, "reason": "hour_limit", "hours_left": ledger.hours_left(sid, did)};
    }
    raise ApiError("This person isn't on your team yet.");
}

# ------------------------------------------------------------------ coverage
def coverage(d: Employer, week: str, draft: Draft | None = None) -> dict[str, any] {
    reqs = [d --> [?:Requirement]];
    wk = week;
    dj = jid(draft) if draft is not None else "";
    shifts = sorted(
        [
            s for s in [d --> [?:Shift, week == wk]]
            if s.student and (s.status == "published" or (draft is not None and s.draft == dj))
        ],
        key=lambda (s: Shift) -> str { return s.created; }
    );
    names: dict[str, str] = {};
    for sh in shifts {
        if sh.student not in names {
            st = employee_of(sh.student);
            names[sh.student] = st.first_name() if st is not None else "";
        }
    }
    roles = {jid(p): p for p in [d --> [?:Position]]};
    slots: dict[str, dict[str, any]] = {};
    def cell(day: int, start: int, end: int, pid_in: str) -> dict[str, any] {
        pid = pid_in if pid_in in roles else "";
        key = f"{day}|{start}|{end}|{pid}";
        if key not in slots {
            p = roles.get(pid) if pid else None;
            slots[key] = {
                "day": day, "start": start, "end": end, "position_id": pid or None,
                "role": p.name if p is not None else "", "color": p.color if p is not None else "",
                "needed": 0, "people": []
            };
        }
        return slots[key];
    }
    for r in reqs {
        c = cell(r.day, r.start, r.end, r.position);
        c["needed"] = c["needed"] + r.headcount;
    }
    for sh in shifts {
        # shifts outside the staffing plan (manual, open-shift pickups) still show up
        c = cell(sh.day, sh.start, sh.end, sh.position);
        c["people"].append(
            {"student_id": sh.student, "name": names.get(sh.student, ""), "new": sh.status == "draft", "pending": sh.state == "pending_swap"}
        );
    }
    cells: list[dict[str, any]] = [];
    for c in slots.values() {
        c["planned"] = c["needed"] > 0;
        if not c["planned"] {
            c["needed"] = len(c["people"]);  # an extra shift outside the staffing plan counts as covered
        }
        c["assigned"] = len(c["people"]);
        c["people"] = sorted(c["people"], key=lambda (p: dict[str, any]) -> str { return p["name"]; });
        cells.append(c);
    }
    cells.sort(key=lambda (c: dict[str, any]) -> tuple[int, int] { return (c["day"], c["start"]); });
    rows = sorted({(c["start"], c["end"]) for c in cells});
    needed = sum([c["needed"] for c in cells]);
    filled = sum([min(c["assigned"], c["needed"]) for c in cells]);
    team = len([e for e in [d --> [?:Employment]] if e.state == "active"]);
    pending = pending_requests(d);
    return {
        "department": {"id": jid(d), "name": d.name, "type": d.type, "kind": d.kind},
        "week": week,
        "rows": [{"start": s, "end": e} for (s, e) in rows],
        "cells": cells,
        "stats": {
            "filled": filled,
            "needed": needed,
            "understaffed": len([c for c in cells if c["assigned"] < c["needed"]]),
            "requests": len(pending),
            "students": team
        },
        "requests": pending,
        "has_needs": bool(cells),
        "has_schedule": any([s.status == "published" for s in shifts])
    };
}

def pending_requests(d: Employer) -> list[dict[str, any]] {
    out: list[dict[str, any]] = [];
    reqs = sorted(
        list([_q for _q in [d --> [?:SwapRequest]] if _q.state == "awaiting_manager"]),
        key=lambda (r: SwapRequest) -> str { return r.created; },
        reverse=True
    );
    for r in reqs {
        lps = [_q for _q in [r --> [?:SwapLoop]] if _q.state == "proposed"];
        if not lps {
            continue;
        }
        lp = lps[0];
        st = employee_of(r.requester);
        who = st.first_name() if st is not None else "";
        sh = shift_of(r.shift);
        found = "";
        if lp.kind == "loop" {
            found = f"The AI found a {lp.size}-person swap.";
        } elif lp.kind == "direct" {
            found = "The AI found a direct swap.";
        } else {
            found = "The AI found someone to take it.";
        }
        out.append(
            {"request_id": jid(r), "text": f"{who} wants out of {DAY_LONG[sh.day] if sh is not None else ''}. {found}"}
        );
    }
    return out;
}

@guarded
def:protect get_coverage(week: str = "", draft_id: str = "") -> dict[str, any] {
    d = me_employer();
    draft: Draft | None = None;
    if draft_id {
        draft = draft_of(str(draft_id));
        if draft is None or draft.employer != jid(d) {
            raise ApiError("Draft not found.");
        }
    }
    return coverage(d, week_arg(week), draft);
}

@guarded
def:protect get_slot(
    day: any = UNSET, start: any = UNSET, end: any = UNSET, position_id: any = UNSET, week: str = ""
) -> dict[str, any] {
    day = opt(day);
    start = opt(start);
    end = opt(end);
    position_id = opt(position_id);
    d = me_employer();
    (dy, s, e) = slot_args(day, start, end);
    pid = position_arg(d, position_id);
    wk = week_arg(week);
    did = jid(d);
    ledger = Ledger(week=wk);
    needed = sum(
        [
            r.headcount for r in [d --> [?:Requirement, day == dy, start == s, end == e]]
            if (r.position or "") == pid
        ]
    );
    shifts = sorted(
        [
            sh for sh in [_q for _q in [d --> [?:Shift, week == wk, day == dy, start == s, end == e]] if _q.status == "published"]
            if sh.student and (sh.position or "") == pid
        ],
        key=lambda (x: Shift) -> str { return x.created; }
    );
    people: list[dict[str, any]] = [];
    for sh in shifts {
        st = employee_of(sh.student);
        if st is None {
            continue;
        }
        people.append(
            {
                "student_id": jid(st), "name": st.name, "hours_with_you": ledger.dept_hours(jid(st), did),
                "pending": sh.state == "pending_swap"
            }
        );
    }
    role = position_of(pid);
    return {
        "label": slot_label(dy, s, e) + (f" · {role.name}" if role is not None else ""),
        "day": dy, "start": s, "end": e, "position_id": pid or None,
        "role": role.name if role is not None else "",
        "needed": max(needed, len(people)),
        "people": people
    };
}

# ------------------------------------------------------------------ needs
@guarded
def:protect get_staffing_needs() -> dict[str, any] {
    d = me_employer();
    reqs = sorted(
        list([d --> [?:Requirement]]), key=lambda (r: Requirement) -> tuple[int, int] { return (r.day, r.start); }
    );
    return {
        "needs": [
            {"day": r.day, "start": r.start, "end": r.end, "headcount": r.headcount, "position_id": r.position or None}
            for r in reqs
        ]
    };
}

def replace_needs(d: Employer, clean: list[tuple[int, int, int, int, str]]) {
    for r in [d --> [?:Requirement]] {
        del r;
    }
    for (day, start, end, head, pid) in clean {
        put(d, Requirement(employer=jid(d), day=day, start=start, end=end, headcount=head, position=pid));
    }
}

@guarded
def:protect set_staffing_needs(needs: any = UNSET) -> dict[str, any] {
    needs = opt(needs);
    d = me_employer();
    if not isinstance(needs, list) {
        raise ApiError("Needs must be a list.");
    }
    valid = [jid(p) for p in [d --> [?:Position]]];
    if len(needs) > 300 {
        raise ApiError("That's too many blocks for one week.");
    }
    clean: list[tuple[int, int, int, int, str]] = [];
    for n in needs {
        day = 0;
        start = 0;
        end = 0;
        head = 0;
        pid = "";
        try {
            day = int(n["day"]);
            start = int(n["start"]);
            end = int(n["end"]);
            head = int(n["headcount"]);
            raw = n.get("position_id");
            pid = str(raw) if raw not in (None, "", 0, "0") else "";
        } except Exception {
            raise ApiError("One of the blocks is incomplete.");
        }
        if pid and pid not in valid {
            raise ApiError("One of the blocks uses a role that doesn't exist.");
        }
        if not (0 <= day and day <= 6 and 0 <= start and start < end and end <= 24 * 60) {
            raise ApiError(f"{DAY_SHORT[day] if 0 <= day and day <= 6 else 'A'} block ends before it starts.");
        }
        if not (1 <= head and head <= 50) {
            raise ApiError("Headcount must be between 1 and 50.");
        }
        clean.append((day, start, end, head, pid));
    }
    replace_needs(d, clean);
    return {"ok": True, "count": len(clean)};
}

# ------------------------------------------------------------------ people
@guarded
def:protect get_people(week: str = "") -> dict[str, any] {
    d = me_employer();
    did = jid(d);
    ledger = Ledger(week=week_arg(week));
    rows: list[dict[str, any]] = [];
    for e in [d --> [?:Employment]] {
        if e.state not in ("active", "invited") {
            continue;
        }
        st = employee_of(e.student);
        if st is None {
            continue;
        }
        sid = jid(st);
        rows.append(
            {
                "student_id": sid, "name": st.name, "email": st.email, "status": st.status, "state": e.state,
                "assigned": e.hours,
                "scheduled_with_you": ledger.dept_hours(sid, did) if e.state == "active" else 0,
                "can_still_schedule": ledger.hours_left(sid, did) if e.state == "active" else None,
                "calendar": st.calendar_source in ("google", "ics_url", "demo"),
                "autopilot": st.autopilot
            }
        );
    }
    rows.sort(key=lambda (r: dict[str, any]) -> tuple[bool, str] { return (r["state"] != "active", r["name"]); });
    return {"people": rows};
}

"""Campus employers can look up students at their own university. Businesses add people with their join code."""
@guarded
def:protect search_students(query: str = "", week: str = "") -> dict[str, any] {
    d = me_employer();
    q = str(query or "").strip().lower();
    did = jid(d);
    if d.kind != "campus" or not d.university {
        return {"results": [], "join_code_only": True};
    }
    uni = d.university;
    rows = [
        s for s in employees()
        if s.kind == "student" and s.school == uni
            and (not q or q in s.name.lower() or q in s.email.lower() or q in (s.student_number or "").lower())
    ];
    rows = sorted(rows, key=lambda (s: Employee) -> str { return s.name; })[:8];
    ledger = Ledger(week=week_arg(week));
    out: list[dict[str, any]] = [];
    for st in rows {
        sid = jid(st);
        emp = employment_between(st, d);
        state = emp.state if emp is not None and emp.state in ("active", "invited") else None;
        more = ledger.hours_left(sid, did) if state == "active" else ledger.cap_left(sid);
        out.append(
            {
                "student_id": sid, "name": st.name, "email": st.email, "status": st.status,
                "can_take_more_hrs": more, "team_state": state
            }
        );
    }
    return {"results": out};
}

@guarded
def:protect invite_student(student_id: str = "", hours: any = UNSET) -> dict[str, any] {
    hours = opt(hours);
    d = me_employer();
    did = jid(d);
    st = employee_of(str(student_id or ""));
    if st is None {
        raise ApiError("Student not found.");
    }
    if d.kind != "campus" or st.kind != "student" or st.school != d.university {
        raise ApiError("You can only invite students from your university. Share your join code with anyone else.");
    }
    if hours is None or hours == "" {
        raise ApiError("Missing hours.");
    }
    h = 0;
    try {
        h = int(hours);
    } except Exception {
        raise ApiError("Hours isn't valid.");
    }
    h = max(1, min(40, h));
    emp = employment_between(st, d);
    if emp is not None and emp.state == "active" {
        emp.hours = h;
        return {"ok": True, "name": st.name, "updated": True};
    }
    if emp is not None {
        emp.hours = h;
        emp.state = "invited";
    } else {
        new_emp = Employment(
            student=jid(st), employer=did, hours=h, state="invited", pay_rate=d.default_pay_rate, created=now_s()
        );
        put(d, new_emp);
        also(st, new_emp);
    }
    to_student(st, f"{d.name} invited you · {h} hrs/week", "/s");
    return {"ok": True, "name": st.name};
}

# ------------------------------------------------------------------ the blind check
@guarded
def:protect check_assignment(
    student_id: str = "", day: any = UNSET, start: any = UNSET, end: any = UNSET, position_id: any = UNSET,
    week: str = ""
) -> dict[str, any] {
    day = opt(day);
    start = opt(start);
    end = opt(end);
    position_id = opt(position_id);
    d = me_employer();
    st = team_member(d, str(student_id or ""));
    (dy, s, e) = slot_args(day, start, end);
    pid = position_arg(d, position_id);
    probe(d, jid(st));
    ledger = Ledger(week=week_arg(week));
    return check_view(d, ledger, st, dy, s, e, pid);
}

@guarded
def:protect assign_shift(
    student_id: str = "", day: any = UNSET, start: any = UNSET, end: any = UNSET, position_id: any = UNSET,
    week: str = ""
) -> dict[str, any] {
    day = opt(day);
    start = opt(start);
    end = opt(end);
    position_id = opt(position_id);
    d = me_employer();
    st = team_member(d, str(student_id or ""));
    (dy, s, e) = slot_args(day, start, end);
    pid = position_arg(d, position_id);
    wk = week_arg(week);
    ledger = Ledger(week=wk);
    result = check_view(d, ledger, st, dy, s, e, pid);
    if not result["available"] {
        return result;
    }
    add_shift(
        d,
        Shift(
            week=wk, day=dy, start=s, end=e, position=pid, student=jid(st), state="assigned", status="published",
            source="manual"
        )
    );
    to_student(st, f"{d.name} added a shift: {dated(wk, dy, s, e)}.", "/s", title="New shift");
    return {"available": True, "assigned": True};
}

@guarded
def:protect find_someone_else(
    day: any = UNSET, start: any = UNSET, end: any = UNSET, position_id: any = UNSET, exclude: any = UNSET,
    week: str = ""
) -> dict[str, any] {
    day = opt(day);
    start = opt(start);
    end = opt(end);
    position_id = opt(position_id);
    exclude = opt(exclude);
    d = me_employer();
    (dy, s, e) = slot_args(day, start, end);
    pid = position_arg(d, position_id);
    did = jid(d);
    ledger = Ledger(week=week_arg(week));
    skip_ids = [str(x) for x in (exclude or [])];
    ranked: list[tuple[int, float, Employee]] = [];
    for st in team_of(d) {
        sid = jid(st);
        if sid in skip_ids {
            continue;
        }
        if ledger.check(sid, did, dy, s, e, pid=pid).ok {
            pref = 0 if set(st.preferences or []) & period_of(dy, s, e) else 1;
            ranked.append((pref, -ledger.hours_left(sid, did), st));
        }
    }
    ranked.sort(key=lambda (t: tuple[int, float, Employee]) -> tuple[int, float, str] { return (t[0], t[1], t[2].name); });
    return {"people": [{"student_id": jid(st), "name": st.name, "hours_left": -h} for (_p, h, st) in ranked[:3]]};
}

# ------------------------------------------------------------------ generate / publish
def draft_payload(d: Employer, draft: Draft) -> dict[str, any] {
    return {
        "draft_id": jid(draft), "state": draft.state, "week": draft.week, "trace": draft.trace, "summary": draft.summary,
        "coverage": coverage(d, draft.week, draft)
    };
}

@guarded
def:protect generate_schedule(week: str = "") -> dict[str, any] {
    d = me_employer();
    draft = scheduling.generate(d, week_arg(week));
    return draft_payload(d, draft);
}

@guarded
def:protect get_draft(draft_id: str = "") -> dict[str, any] {
    d = me_employer();
    draft = draft_of(str(draft_id or ""));
    if draft is None or draft.employer != jid(d) {
        raise ApiError("Draft not found.");
    }
    return draft_payload(d, draft);
}

def publish_draft(d: Employer, draft_id: str) -> dict[str, any] {
    draft = draft_of(draft_id);
    if draft is None or draft.employer != jid(d) or draft.state != "draft" {
        raise ApiError("This draft can't be published.");
    }
    res = scheduling.publish(d, draft);
    for (sid, n) in res["notified"].items() {
        st = employee_of(sid);
        if st is not None {
            to_student(st, f"{d.name} published this week's schedule: {n} new shift{'s' if n != 1 else ''} for you.", "/s");
        }
    }
    # Anything still waiting for a swap gets another look now that the week changed.
    for req in sorted(
        list([_q for _q in [d --> [?:SwapRequest]] if _q.state == "searching"]), key=lambda (r: SwapRequest) -> str { return r.created; }
    ) {
        tr = Trace();
        tr.step("Coordinator", "agent", "new schedule published — looking again");
        swaps.plan(req, tr);
    }
    return {"ok": True, "notified": len(res["notified"]), "dropped": res["dropped"]};
}

@guarded
def:protect publish_schedule(draft_id: str = "") -> dict[str, any] {
    return publish_draft(me_employer(), str(draft_id or ""));
}

@guarded
def:protect discard_draft(draft_id: str = "") -> dict[str, any] {
    d = me_employer();
    draft = draft_of(str(draft_id or ""));
    if draft is None or draft.employer != jid(d) {
        raise ApiError("Draft not found.");
    }
    if draft.state == "draft" {
        scheduling.discard(d, draft);
    }
    return {"ok": True};
}

# ------------------------------------------------------------------ swaps
@guarded
def:protect get_requests() -> dict[str, any] {
    d = me_employer();
    reqs = sorted(
        list([d --> [?:SwapRequest]]), key=lambda (r: SwapRequest) -> str { return r.created; }, reverse=True
    )[:30];
    out: list[dict[str, any]] = [];
    for r in reqs {
        sh = shift_of(r.shift);
        st = employee_of(r.requester);
        out.append(
            {
                "request_id": jid(r), "requester": st.first_name() if st is not None else "", "state": r.state,
                "shift": slot_label(sh.day, sh.start, sh.end) if sh is not None else ""
            }
        );
    }
    return {"requests": out};
}

def loop_card(d: Employer, loop: SwapLoop, req: SwapRequest) -> dict[str, any] {
    did = jid(d);
    s0 = shift_of(req.shift);
    ledger = Ledger(week=s0.week if s0 is not None else "");
    moves = swaps.describe(loop.moves);
    for m in moves {
        now_h = ledger.dept_hours(m["student_id"], did);
        gs = shift_of(m["gives_shift_id"] or "");
        gt = shift_of(m["gets_shift_id"] or "");
        gives_h = gs.hours() if gs is not None else 0.0;
        gets_h = gt.hours() if gt is not None else 0.0;
        if loop.state == "committed" {
            m["hrs_before"] = now_h - gets_h + gives_h;
            m["hrs_after"] = now_h;
        } else {
            m["hrs_before"] = now_h;
            m["hrs_after"] = now_h - gives_h + gets_h;
        }
    }
    offers: dict[str, SwapOffer] = {o.student: o for o in [loop --> [?:SwapOffer]]};
    participants: list[dict[str, any]] = [];
    for m in moves {
        o = offers.get(m["student_id"]);
        participants.append(
            {
                "name": m["name"],
                "state": o.state if o is not None else None,
                "auto": o.auto if o is not None else "",
                "seconds_ago": seconds_since(o.responded_at or o.created) if o is not None else None
            }
        );
    }
    receiver = moves[1]["name"] if loop.kind == "handoff" and len(moves) > 1 else "";
    rq = employee_of(req.requester);
    declined = employee_of(loop.declined_by);
    return {
        "loop_id": jid(loop),
        "state": loop.state,
        "kind": loop.kind,
        "size": loop.size,
        "headline": swaps.headline(loop.kind, loop.size, receiver),
        "subline": f"Requested by {rq.first_name() if rq is not None else ''} · Coverage unchanged",
        "moves": moves,
        "rationale": loop.rationale,
        "alternatives": loop.alternatives or [],
        "trace": loop.trace or [],
        "checks": [
            {"label": "Availability", "kind": "agent"}, {"label": "Hidden conflicts", "kind": "rules"},
            {"label": "Hour limits", "kind": "rules"}, {"label": "Coverage", "kind": "rules"}
        ],
        "participants": participants,
        "declined_by": declined.first_name() if declined is not None else None,
        "decline_reason": loop.decline_reason
    };
}

def swap_request_view(d: Employer, request_id: str) -> dict[str, any] {
    swaps.sweep_employer(d);
    req = request_of(request_id);
    if req is None or req.employer != jid(d) {
        raise ApiError("Request not found.");
    }
    sh = shift_of(req.shift);
    loops = sorted(list([req --> [?:SwapLoop]]), key=lambda (l: SwapLoop) -> str { return l.created; });
    want = "";
    if req.want_kind == "days" {
        want = ", ".join([DAY_LONG[x] for x in req.want_days]);
    } elif req.want_kind == "any" {
        want = "any other time";
    } else {
        want = "to give it up";
    }
    rq = employee_of(req.requester);
    return {
        "request_id": jid(req),
        "state": req.state,
        "requester": rq.first_name() if rq is not None else "",
        "shift": slot_label(sh.day, sh.start, sh.end) if sh is not None else "",
        "want": want,
        "reason": req.reason,
        "trace": req.trace or [],
        "loops": [loop_card(d, lp, req) for lp in loops if lp.state != "invalidated"]
    };
}

@guarded
def:protect get_swap_request(request_id: str = "") -> dict[str, any] {
    return swap_request_view(me_employer(), str(request_id or ""));
}

def loop_for(d: Employer, loop_id: str) -> SwapLoop {
    loop = loop_of(loop_id);
    if loop is None {
        raise ApiError("Swap not found.");
    }
    req = request_of(loop.request);
    if req is None or req.employer != jid(d) {
        raise ApiError("Swap not found.");
    }
    return loop;
}

def approve_loop(d: Employer, loop_id: str) -> dict[str, any] {
    loop = loop_for(d, loop_id);
    try {
        swaps.approve(loop);
    } except swaps.SwapError as se {
        raise ApiError(str(se));
    }
    return swap_request_view(d, loop.request);
}

def reject_loop(d: Employer, loop_id: str) -> dict[str, any] {
    loop = loop_for(d, loop_id);
    try {
        swaps.reject(loop);
    } except swaps.SwapError as se {
        raise ApiError(str(se));
    }
    return swap_request_view(d, loop.request);
}

@guarded
def:protect approve_swap(loop_id: str = "") -> dict[str, any] {
    return approve_loop(me_employer(), str(loop_id or ""));
}

@guarded
def:protect reject_swap(loop_id: str = "") -> dict[str, any] {
    return reject_loop(me_employer(), str(loop_id or ""));
}

"""Post an unfilled slot as an open shift. Only employees who pass every rule are told about it."""
@guarded
def:protect post_open_shift(
    day: any = UNSET, start: any = UNSET, end: any = UNSET, position_id: any = UNSET, week: str = ""
) -> dict[str, any] {
    day = opt(day);
    start = opt(start);
    end = opt(end);
    position_id = opt(position_id);
    d = me_employer();
    (dy, s, e) = slot_args(day, start, end);
    pid = position_arg(d, position_id);
    wk = week_arg(week);
    did = jid(d);
    add_shift(
        d,
        Shift(week=wk, day=dy, start=s, end=e, student="", state="open", status="published", position=pid, source="open")
    );
    ledger = Ledger(week=wk);
    notified = 0;
    for st in team_of(d) {
        if ledger.check(jid(st), did, dy, s, e, pid=pid).ok {
            to_student(st, f"{d.name} posted an open shift you can take: {dated(wk, dy, s, e)}.", "/s", title="Open shift");
            notified += 1;
        }
    }
    return {"ok": True, "notified": notified};
}
