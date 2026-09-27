"""Swap Agent + swap workflow + Commit Service.

Search is deterministic (depth <= 4): direct 1:1 swap, then 3-person loops, then 4-person loops.
Every candidate is validated against the full cross-employer Ledger for every participant. The AI's
job is the explanation; it never decides what is allowed. Only employer-local data (first names,
this employer's shifts) is ever sent to the model.

Request -> Swap Agent plans -> manager approves -> every participant accepts -> commit (atomic).
Anyone declines or an offer expires -> nothing changes, the decliner is excluded, the agent re-plans.
No half-swaps, ever: all moves are applied in one transaction, after re-validation.
"""

import from datetime { timedelta }
import from server.clock { utcnow, now_s, iso, parse_iso }
import from server.config { OFFER_TTL_HOURS }
import from server.timeutil { DAY_LONG, DAY_SHORT, hm, slot_label }
import from server.trace { Trace }
import from server.rules { Held, Ledger }
import from server.notify { log_event, to_student, to_employer }
import from server.scheduling { period_of, team_of }
import from server.models {
    Employer,
    Employee,
    Shift,
    SwapRequest,
    SwapLoop,
    SwapOffer,
    put,
    also,
    set_holder,
    employee_of,
    employer_of,
    shift_of,
    request_of,
    loop_of
}
import server.ai as ai;

glob MAX_LOOP: int = 4,
     ACTIVE_REQUEST_STATES: list[str] = ["searching", "awaiting_manager", "offered"];

class SwapError(Exception) {}

obj Candidate {
    has kind: str,
        moves: list[dict[str, any]],
        participants: list[str],
        score: list[any] = [];

    def size -> int {
        return len(self.participants);
    }
}

obj SearchResult {
    has found: dict[int, int] = {2: 0, 3: 0, 4: 0},
        rejected_conflict: int = 0,
        rejected_hours: int = 0,
        candidates: list[Candidate] = [];
}

def _name(sid: str) -> str {
    st = employee_of(sid);
    return st.first_name() if st is not None else "";
}

def _slot(sh: Shift) -> str {
    return f"{DAY_SHORT[sh.day]} {hm(sh.start)}–{hm(sh.end)}";
}

# ------------------------------------------------------------------ search
def _holdings(req: SwapRequest, week: str) -> dict[str, list[Shift]] {
    e = employer_of(req.employer);
    out: dict[str, list[Shift]] = {};
    if e is None {
        return out;
    }
    wk = week;
    rows = sorted(
        [s for s in [_q for _q in [e --> [?:Shift, week == wk]] if _q.status == "published"] if s.student],
        key=lambda (s: Shift) -> str { return s.created; }
    );
    for s in rows {
        if s.state == "assigned" or jid(s) == req.shift {
            out.setdefault(s.student, []).append(s);
        }
    }
    return out;
}

def _requester_wants(req: SwapRequest, s0: Shift, sh: Shift) -> bool {
    if jid(sh) == jid(s0) {
        return False;
    }
    if req.want_kind == "days" {
        return sh.day in (req.want_days or []);
    }
    if req.want_kind == "any" {
        return (sh.day, sh.start, sh.end) != (s0.day, s0.start, s0.end);
    }
    return False;
}

def _moves_from_path(path: list[tuple[str, Shift]]) -> list[dict[str, any]] {
    moves: list[dict[str, any]] = [];
    for (i, step) in enumerate(path) {
        (sid, gives) = step;
        gets = path[i - 1][1] if i > 0 else path[-1][1];
        moves.append({"student_id": sid, "gives_shift_id": jid(gives), "gets_shift_id": jid(gets)});
    }
    return moves;
}

"""Apply all moves to a copy of the week and check every participant against every hard rule."""
def validate_moves(ledger: Ledger, moves: list[dict[str, any]], shifts: dict[str, Shift]) -> list[str] {
    problems: list[str] = [];
    for m in moves {
        if m.get("gets_shift_id") {
            sh = shifts[m["gets_shift_id"]];
            if not ledger.qualified(m["student_id"], sh.employer, sh.position) {
                problems.append("not_qualified");
            }
        }
    }
    if problems {
        return problems;
    }
    trial = ledger.clone();
    for m in moves {
        if m.get("gives_shift_id") {
            trial.remove(m["student_id"], m["gives_shift_id"]);
        }
    }
    for m in moves {
        if m.get("gets_shift_id") {
            sh = shifts[m["gets_shift_id"]];
            trial.add(
                m["student_id"],
                Held(shift_id=jid(sh), department_id=sh.employer, day=sh.day, start=sh.start, end=sh.end)
            );
        }
    }
    for m in moves {
        problems = problems + trial.violations(m["student_id"]);
    }
    return problems;
}

def _consider(
    result: SearchResult, ledger: Ledger, shifts: dict[str, Shift], kind: str,
    moves: list[dict[str, any]], participants: list[str]
) {
    problems = validate_moves(ledger, moves, shifts);
    if problems {
        if any([p in ("overlap", "rest", "daily_max") for p in problems]) {
            result.rejected_conflict += 1;
        } else {
            result.rejected_hours += 1;
        }
        return;
    }
    n = len(participants);
    result.found[n] = result.found.get(n, 0) + 1;
    result.candidates.append(Candidate(kind=kind, moves=moves, participants=participants));
}

def _dfs(
    req: SwapRequest, s0: Shift, path: list[tuple[str, Shift]], holdings: dict[str, list[Shift]],
    students: dict[str, Employee], excluded: list[str], result: SearchResult, ledger: Ledger,
    shifts: dict[str, Shift]
) {
    current = path[-1][1];
    in_path = [p[0] for p in path];
    for (sid, owned) in holdings.items() {
        if sid in in_path or sid in excluded or sid == req.requester {
            continue;
        }
        if current.day not in (students[sid].open_swap_days or []) {
            continue;
        }
        for sh in owned {
            if sh.state != "assigned" {
                continue;
            }
            new_path = path + [(sid, sh)];
            if _requester_wants(req, s0, sh) {
                kind = "direct" if len(new_path) == 2 else "loop";
                _consider(result, ledger, shifts, kind, _moves_from_path(new_path), [p[0] for p in new_path]);
            }
            if len(new_path) < MAX_LOOP {
                _dfs(req, s0, new_path, holdings, students, excluded, result, ledger, shifts);
            }
        }
    }
}

def search(req: SwapRequest) -> SearchResult {
    result = SearchResult();
    s0 = shift_of(req.shift);
    if s0 is None {
        return result;
    }
    week = s0.week;
    ledger = Ledger(week=week);
    holdings = _holdings(req, week);
    shifts: dict[str, Shift] = {};
    for lst in holdings.values() {
        for s in lst {
            shifts[jid(s)] = s;
        }
    }
    students: dict[str, Employee] = {};
    for sid in holdings {
        st = employee_of(sid);
        if st is not None {
            students[sid] = st;
        }
    }
    excluded = list(req.excluded or []);
    if req.want_kind == "give_up" {
        e = employer_of(req.employer);
        team = team_of(e) if e is not None else [];
        shifts[jid(s0)] = s0;
        for st in team {
            sid = jid(st);
            if sid == req.requester or sid in excluded {
                continue;
            }
            moves = [
                {"student_id": req.requester, "gives_shift_id": jid(s0), "gets_shift_id": None},
                {"student_id": sid, "gives_shift_id": None, "gets_shift_id": jid(s0)}
            ];
            _consider(result, ledger, shifts, "handoff", moves, [req.requester, sid]);
        }
    } else {
        _dfs(req, s0, [(req.requester, s0)], holdings, students, excluded, result, ledger, shifts);
    }
    for c in result.candidates {
        c.score = _rank_key(c, students, shifts);
    }
    result.candidates = sorted(
        result.candidates, key=lambda (c: Candidate) -> list[any] { return c.score; }
    );
    return result;
}

"""Smaller loops first; then most likely to be accepted; then least sacrifice."""
def _rank_key(c: Candidate, students: dict[str, Employee], shifts: dict[str, Shift]) -> list[any] {
    likely = 0;
    sacrifice = 0.0;
    for m in c.moves {
        st = students.get(m["student_id"]) or employee_of(m["student_id"]);
        if st is None {
            continue;
        }
        gets: Shift | None = shifts.get(m["gets_shift_id"]) if m.get("gets_shift_id") else None;
        if gets is not None and st.autopilot and gets.day in (st.open_swap_days or []) {
            likely += 1;
        }
        prefs = set(st.preferences or []);
        if gets is not None and prefs and not (prefs & period_of(gets.day, gets.start, gets.end)) {
            sacrifice += 1;
        }
        if gets is not None and m.get("gives_shift_id") {
            gives = shifts.get(m["gives_shift_id"]);
            if gives is not None {
                sacrifice += abs(gives.start - gets.start) / 600;
            }
        }
    }
    if c.kind == "handoff" {
        receiver = students.get(c.participants[1]) or employee_of(c.participants[1]);
        s0 = shifts.get(c.moves[0]["gives_shift_id"]) or shift_of(c.moves[0]["gives_shift_id"]);
        if receiver is not None and s0 is not None and s0.day in (receiver.open_swap_days or []) {
            likely += 1;
        }
    }
    order: list[str] = [];
    for p in c.participants {
        pe = students.get(p) or employee_of(p);
        order.append(pe.created if pe is not None else p);
    }
    return [c.size(), -likely, round(sacrifice, 2), order];
}

# ------------------------------------------------------------------ Explainer (swap cards)
def headline(kind: str, size: int, receiver_name: str = "") -> str {
    if kind == "handoff" {
        return f"Hand-off · {receiver_name} takes the shift";
    }
    if kind == "direct" {
        return "Direct swap · everyone stays within limits";
    }
    return f"{size}-person swap · everyone stays within limits";
}

"""Employer-local description of each move: first names, this employer's shifts only."""
def describe(moves: list[dict[str, any]]) -> list[dict[str, any]] {
    out: list[dict[str, any]] = [];
    for m in moves {
        st = employee_of(m["student_id"]);
        gives = shift_of(m.get("gives_shift_id") or "");
        gets = shift_of(m.get("gets_shift_id") or "");
        out.append(
            {
                "student_id": m["student_id"],
                "name": st.first_name() if st is not None else "",
                "gives": slot_label(gives.day, gives.start, gives.end) if gives is not None else None,
                "gets": slot_label(gets.day, gets.start, gets.end) if gets is not None else None,
                "gives_day": gives.day if gives is not None else None,
                "gets_day": gets.day if gets is not None else None,
                "gives_shift_id": jid(gives) if gives is not None else None,
                "gets_shift_id": jid(gets) if gets is not None else None
            }
        );
    }
    return out;
}

def summarize(cand: Candidate) -> str {
    names = [_name(sid) for sid in cand.participants[1:]];
    if cand.kind == "handoff" {
        return f"Hand-off to {names[0]}";
    }
    joined = ", ".join(names[:-1]) + (" and " if len(names) > 1 else "") + names[-1];
    return f"{cand.size()}-person loop via {joined}" if cand.kind == "loop" else f"Direct swap with {joined}";
}

def _want_text(req: SwapRequest, give_up: str) -> str {
    if req.want_kind == "days" {
        return ", ".join([DAY_LONG[d] for d in req.want_days]);
    }
    return "any other time" if req.want_kind == "any" else give_up;
}

def rationale(req: SwapRequest, cand: Candidate) -> tuple[str, bool] {
    moves = describe(cand.moves);
    requester = _name(req.requester);
    want = _want_text(req, "to give the shift up");
    feedback = req.feedback or [];
    if ai.ready() {
        try {
            why = ai.explain_swap(
                requester,
                want,
                [
                    ai.MoveInfo(name=m["name"], gives=str(m["gives"] or "nothing"), gets=str(m["gets"] or "nothing"))
                    for m in moves
                ],
                "none" if cand.kind != "handoff" else "requester down, receiver up",
                [f"{f.get('name', '')}: {f.get('reason', '')}" for f in feedback]
            );
            ai.succeeded();
            if why and why.strip() {
                return (why.strip()[:600], True);
            }
        } except Exception as ex {
            ai.failed(ex);
        }
    }
    return (_fallback_rationale(requester, want, moves, cand, feedback), False);
}

def _fallback_rationale(
    requester: str, want: str, moves: list[dict[str, any]], cand: Candidate, feedback: list[dict[str, any]]
) -> str {
    if cand.kind == "handoff" {
        r = moves[1];
        return (
            f"{requester} wants to give up {moves[0]['gives']}. {r['name']} is free then and still under "
            + f"their hours with you, so they can take it. {requester}'s hours go down; coverage is unchanged."
        );
    }
    first = moves[0];
    others = moves[1:];
    opens: list[str] = [];
    for (i, m) in enumerate(others) {
        if i == 0 {
            opens.append(f"{m['name']} is open to {DAY_LONG[m['gets_day']]}s");
        } else {
            opens.append(f"{m['name']} to {DAY_LONG[m['gets_day']]}s");
        }
    }
    wants = opens[0] if len(opens) == 1 else ", ".join(opens[:-1]) + " and " + opens[-1];
    lead = "";
    if cand.kind == "loop" {
        lead = f"{requester} wants {want}, but nobody holding a {want} shift wants {DAY_LONG[first['gives_day']]} directly. ";
    } else {
        lead = f"{requester} wants {want} and {others[0]['name']} wants {requester}'s shift. ";
    }
    body = (
        f"{wants}, so passing the shifts around the circle gives everyone a day they asked for. "
        + "Every shift is the same length, so nobody's hours change and coverage stays exactly the same."
    );
    if feedback {
        last = feedback[-1];
        body += f" {last['name']} declined the previous option, so this one leaves them out.";
    }
    return lead + body;
}

# ------------------------------------------------------------------ request + plan
def create_request(
    student: Employee, shift_id: str, want_kind: str, want_days: list[int], reason: str,
    origin: str = "student"
) -> SwapRequest {
    sh = shift_of(shift_id);
    if sh is None or sh.student != jid(student) or sh.status != "published" {
        raise SwapError("That shift isn't yours to swap.");
    }
    e = employer_of(sh.employer);
    if e is None {
        raise SwapError("That shift isn't yours to swap.");
    }
    sj = jid(sh);
    for r in [e --> [?:SwapRequest, shift == sj]] {
        if r.state in ACTIVE_REQUEST_STATES {
            raise SwapError("You already have a request open for this shift.");
        }
    }
    if sh.state == "pending_swap" {
        raise SwapError("This shift is already part of a pending swap.");
    }
    if want_kind not in ("days", "any", "give_up") {
        raise SwapError("Choose what you'd like instead.");
    }
    days = sorted({int(d) for d in (want_days or []) if 0 <= int(d) and int(d) <= 6});
    if want_kind == "days" and not days {
        raise SwapError("Pick at least one day.");
    }
    req = SwapRequest(
        employer=sh.employer,
        requester=jid(student),
        shift=sj,
        want_kind=want_kind,
        want_days=days,
        reason=(reason or "")[:300],
        state="searching",
        origin=origin,
        created=now_s()
    );
    put(e, req);
    also(student, req);
    sh.state = "pending_swap";
    plan(req, Trace());
    return req;
}

def _step_found(tr: Trace, label: str, n: int) {
    tr.step(
        "Swap Agent",
        "agent",
        f"{label} · {'found ' + str(n) if n else 'none found'}",
        status="done" if n else "blocked"
    );
}

def plan(req: SwapRequest, tr: Trace) -> SwapLoop | None {
    result = search(req);
    if not result.candidates and req.origin == "calendar" and req.want_kind != "give_up" {
        # Nobody can trade -- fall back to finding someone who can simply take the shift.
        tr.step("Swap Agent", "agent", "no trade possible · looking for someone to take the shift", status="blocked");
        kind = req.want_kind;
        req.want_kind = "give_up";
        result = search(req);
        if not result.candidates {
            req.want_kind = kind;
        }
    }
    if req.want_kind == "give_up" {
        n = result.found.get(2, 0);
        tr.step("Swap Agent", "agent", "looking for someone to take the shift");
        tr.step(
            "Swap Agent",
            "agent",
            (f"found {n} option{'s' if n != 1 else ''}" if n else "no one can take it yet"),
            status="done" if n else "blocked"
        );
    } else {
        tr.step("Swap Agent", "agent", "looking for a direct swap");
        _step_found(tr, "direct swap", result.found[2]);
        if not result.found[2] {
            _step_found(tr, "searching 3-person loops", result.found[3]);
            if not result.found[3] {
                _step_found(tr, "searching 4-person loops", result.found[4]);
            }
        }
    }
    rejected = result.rejected_conflict;
    tr.step(
        "Conflict Agent",
        "rules",
        (f"checking hidden conflicts · removed {rejected} option{'s' if rejected != 1 else ''}" if rejected else "checking hidden conflicts · clear"),
        status="blocked" if rejected else "done"
    );
    tr.step(
        "Compliance Checker",
        "rules",
        (f"checking hour limits · removed {result.rejected_hours}" if result.rejected_hours else "checking hour limits · all within limits"),
        status="blocked" if result.rejected_hours else "done"
    );
    e = employer_of(req.employer);
    if not result.candidates {
        tr.final("No option found", ok=False);
        req.state = "searching";
        req.trace = tr.rows;
        log_event(
            "Swap Agent",
            f"No swap for {_name(req.requester)} yet — will retry when the week changes",
            employer=e,
            level="alert",
            link=f"/d/requests/{jid(req)}"
        );
        return None;
    }
    best = result.candidates[0];
    (why, used_ai) = rationale(req, best);
    tr.step("Explainer", "agent", "wrote the approval card", ai=used_ai);
    tr.final("Ready for review");
    alternatives = [
        {"summary": summarize(c), "why_lower": _why_lower(best, c)} for c in result.candidates[1:4]
    ];
    loop = SwapLoop(
        request=jid(req),
        moves=best.moves,
        size=best.size(),
        kind=best.kind,
        score=0.0,
        rationale=why,
        alternatives=alternatives,
        trace=tr.rows,
        state="proposed",
        created=now_s()
    );
    put(req, loop);
    req.state = "awaiting_manager";
    req.trace = tr.rows;
    s0 = shift_of(req.shift);
    day_name = DAY_LONG[s0.day] if s0 is not None else "";
    word = "swap" if best.kind != "handoff" else "hand-off";
    size_word = "";
    if best.kind == "loop" {
        size_word = f"a {best.size()}-person {word}";
    } elif best.kind == "handoff" {
        size_word = f"a {word}";
    } else {
        size_word = "a direct swap";
    }
    if e is not None {
        to_employer(
            e,
            f"{_name(req.requester)} wants out of {day_name}. The AI found {size_word}.",
            f"/d/requests/{jid(req)}"
        );
    }
    log_event(
        "Swap Agent",
        f"Found {size_word} for {_name(req.requester)}'s {day_name} shift · awaiting your approval",
        employer=e,
        level="action",
        link=f"/d/requests/{jid(req)}"
    );
    log_event(
        "Swap Agent",
        f"Found {size_word} for your {day_name} shift · waiting for your manager",
        student=employee_of(req.requester),
        level="info"
    );
    if e is not None and e.auto_approve_swaps and best.kind != "handoff" {
        log_event(
            "Coordinator",
            "Low-risk swap (hours and coverage unchanged) — auto-approved by your policy",
            employer=e,
            level="info",
            link=f"/d/requests/{jid(req)}"
        );
        approve(loop);
    }
    return loop;
}

def _why_lower(best: Candidate, other: Candidate) -> str {
    if other.size() > best.size() {
        extra = other.size() - best.size();
        words = {1: "one", 2: "two", 3: "three"};
        return f"Changes {words.get(extra, str(extra))} more {'person' if extra == 1 else 'people'}'s week.";
    }
    if other.score and best.score and other.score[1] > best.score[1] {
        return "Fewer people have said they're open to these days.";
    }
    return "Asks more people to change the time of day they work.";
}

# ------------------------------------------------------------------ manager decisions
def _loop_shifts(loop: SwapLoop) -> dict[str, Shift] {
    out: dict[str, Shift] = {};
    for m in loop.moves {
        for key in ["gives_shift_id", "gets_shift_id"] {
            sid = m.get(key);
            if sid {
                sh = shift_of(sid);
                if sh is not None {
                    out[sid] = sh;
                }
            }
        }
    }
    return out;
}

def _offers(loop: SwapLoop) -> list[SwapOffer] {
    return sorted(list([loop --> [?:SwapOffer]]), key=lambda (o: SwapOffer) -> str { return o.created; });
}

def approve(loop: SwapLoop) -> SwapLoop {
    if loop.state != "proposed" {
        raise SwapError("This option is no longer waiting for approval.");
    }
    req = request_of(loop.request);
    if req is None {
        raise SwapError("This option is no longer waiting for approval.");
    }
    shifts = _loop_shifts(loop);
    s0 = shift_of(req.shift);
    stale = False;
    for m in loop.moves {
        g = m.get("gives_shift_id");
        if g and (g not in shifts or shifts[g].student != m["student_id"]) {
            stale = True;
        }
    }
    for (sid, sh) in shifts.items() {
        if sh.state == "pending_swap" and sid != req.shift {
            stale = True;
        }
    }
    if not stale and s0 is not None and validate_moves(Ledger(week=s0.week), loop.moves, shifts) {
        stale = True;
    }
    if stale {
        loop.state = "invalidated";
        tr = Trace();
        tr.step("Coordinator", "agent", "the week changed since this option was found — re-planning");
        plan(req, tr);
        raise SwapError(
            "The schedule changed since this option was found. The Swap Agent found a fresh option."
        );
    }
    loop.state = "approved";
    req.state = "offered";
    e = employer_of(req.employer);
    log_event(
        "Coordinator",
        "Approved · sending offers (autopilot answers where it can)",
        kind="human",
        employer=e,
        level="info",
        link=f"/d/requests/{jid(req)}"
    );
    previous = _previous_accepted_moves(req, jid(loop));
    expires = iso(utcnow() + timedelta(hours=OFFER_TTL_HOURS));
    for m in loop.moves {
        st = employee_of(m["student_id"]);
        if st is None {
            continue;
        }
        gets: Shift | None = shifts.get(m.get("gets_shift_id") or "");
        gives: Shift | None = shifts.get(m.get("gives_shift_id") or "");
        signature = _move_signature(gives, gets);
        offer = SwapOffer(loop=jid(loop), student=jid(st), state="waiting", expires_at=expires, created=now_s());
        if signature in previous.get(jid(st), []) {
            offer.state = "accepted";
            offer.auto = "carried";
            offer.responded_at = now_s();
        } elif gets is not None and st.autopilot and gets.day in (st.open_swap_days or []) {
            offer.state = "accepted";
            offer.auto = "auto_accept";
            offer.responded_at = now_s();
        } elif gets is not None and st.autopilot and jid(st) == req.requester
            and (req.want_kind == "any" or gets.day in (req.want_days or [])) {
            offer.state = "accepted";
            offer.auto = "auto_accept";
            offer.responded_at = now_s();
        } elif gets is None and st.autopilot and req.origin == "calendar" and jid(st) == req.requester {
            offer.state = "accepted";
            offer.auto = "auto_accept";
            offer.responded_at = now_s();
        }
        if offer.auto {
            what = f"take {_slot(gets)}" if gets is not None else (f"hand off {_slot(gives)}" if gives is not None else "");
            extra = f", give up {_slot(gives)}" if gets is not None and gives is not None else "";
            log_event("Autopilot", f"Accepted for you: {what}{extra}", student=st, level="done");
        }
        put(loop, offer);
        also(st, offer);
        for sh in [gives, gets] {
            if sh is not None {
                sh.state = "pending_swap";
            }
        }
        if offer.state == "waiting" {
            text = "";
            if gets is not None and gives is not None {
                text = f"You've been offered a swap: take {_slot(gets)}, give up {_slot(gives)}.";
            } elif gets is not None {
                text = f"You've been offered an extra shift: {_slot(gets)}.";
            } elif gives is not None {
                text = f"Your hand-off of {_slot(gives)} was approved. Please confirm.";
            }
            to_student(st, text, f"/s/offer/{jid(offer)}");
        }
    }
    maybe_commit(loop);
    return loop;
}

def reject(loop: SwapLoop) {
    if loop.state != "proposed" {
        raise SwapError("This option is no longer waiting for approval.");
    }
    req = request_of(loop.request);
    if req is None {
        return;
    }
    loop.state = "rejected";
    req.state = "rejected";
    s0 = shift_of(req.shift);
    st = employee_of(req.requester);
    if s0 is not None {
        s0.state = "assigned";
        if st is not None {
            to_student(
                st, f"Your manager didn't approve the swap for {_slot(s0)}. Your shift stays as it was.", "/s"
            );
        }
    }
}

# ------------------------------------------------------------------ employee decisions
def respond(offer: SwapOffer, accept: bool, chip: str = "", text: str = "") {
    if offer.state != "waiting" {
        raise SwapError("This offer is no longer open.");
    }
    loop = loop_of(offer.loop);
    if loop is None or loop.state != "approved" {
        raise SwapError("This swap is no longer active.");
    }
    offer.responded_at = now_s();
    if accept {
        offer.state = "accepted";
        maybe_commit(loop);
        return;
    }
    offer.state = "declined";
    offer.reason_chip = (chip or "")[:60];
    offer.reason_text = (text or "")[:300];
    decline_loop(loop, offer.student, offer.reason_text or offer.reason_chip);
}

def decline_loop(loop: SwapLoop, student_id: str, reason: str, expired: bool = False) -> SwapLoop | None {
    req = request_of(loop.request);
    if req is None {
        return None;
    }
    loop.state = "declined";
    loop.declined_by = student_id;
    loop.decline_reason = reason or "";
    for o in _offers(loop) {
        # the reference app also closes the offer that ended the loop (declined/expired) as "cancelled"
        if o.state == "waiting" or (o.student == student_id and o.state in ("declined", "expired")) {
            o.state = "cancelled";
        }
    }
    _release_shifts(loop, req.shift);
    name = _name(student_id);
    req.excluded = sorted(set(req.excluded or []) | {student_id});
    req.feedback = (req.feedback or []) + [{"name": name, "reason": reason or ("offer expired" if expired else "")}];
    what = "didn't respond in time" if expired else "declined";
    quoted = f' — "{reason}"' if reason and not expired else "";
    e = employer_of(req.employer);
    if e is not None {
        to_employer(
            e, f"{name} {what}{quoted}. The Swap Agent is looking for another option.", f"/d/requests/{jid(req)}"
        );
    }
    log_event(
        "Coordinator",
        f"{name} {what} — Swap Agent re-planning without them",
        employer=e,
        level="alert",
        link=f"/d/requests/{jid(req)}"
    );
    tr = Trace();
    tr.step("Coordinator", "agent", f"{name} {what} — re-planning without them");
    new_loop = plan(req, tr);
    if new_loop is None {
        st = employee_of(req.requester);
        if st is not None {
            to_student(st, "Your swap fell through. We'll keep looking and notify you.", "/s");
        }
    }
    return new_loop;
}

"""Expire waiting offers past their deadline (scoped to a set of offers)."""
def sweep_offers(offers: list[SwapOffer]) {
    now = utcnow();
    for o in offers {
        if o.state != "waiting" {
            continue;
        }
        exp = parse_iso(o.expires_at);
        if exp is None or exp >= now {
            continue;
        }
        loop = loop_of(o.loop);
        o.state = "expired";
        if loop is not None and loop.state == "approved" {
            decline_loop(loop, o.student, "", expired=True);
        }
    }
}

def sweep_employee(st: Employee) {
    sweep_offers([o for o in [st --> [?:SwapOffer]] if o.state == "waiting"]);
}

def sweep_employer(e: Employer) {
    offers: list[SwapOffer] = [];
    for r in [_q for _q in [e --> [?:SwapRequest]] if _q.state == "offered"] {
        for lp in [_q for _q in [r --> [?:SwapLoop]] if _q.state == "approved"] {
            offers = offers + [o for o in [lp --> [?:SwapOffer]] if o.state == "waiting"];
        }
    }
    sweep_offers(offers);
}

# ------------------------------------------------------------------ Commit Service
def maybe_commit(loop: SwapLoop) -> bool {
    offers = _offers(loop);
    if offers and all([o.state == "accepted" for o in offers]) {
        commit(loop);
        return True;
    }
    return False;
}

"""Apply every move at once -- or none. Re-validates against the live week first."""
def commit(loop: SwapLoop) {
    req = request_of(loop.request);
    if req is None {
        return;
    }
    shifts = _loop_shifts(loop);
    s0 = shift_of(req.shift);
    holders_ok = True;
    for m in loop.moves {
        g = m.get("gives_shift_id");
        if g and (g not in shifts or shifts[g].student != m["student_id"]) {
            holders_ok = False;
        }
    }
    problems: list[str] = ["stale"];
    if holders_ok and s0 is not None {
        problems = validate_moves(Ledger(week=s0.week), loop.moves, shifts);
    }
    e = employer_of(req.employer);
    if problems {
        loop.state = "invalidated";
        for o in _offers(loop) {
            if o.state in ("waiting", "accepted") {
                o.state = "cancelled";
            }
        }
        _release_shifts(loop, req.shift);
        tr = Trace();
        tr.step("Compliance Checker", "rules", "week changed before commit — nothing applied", status="blocked");
        plan(req, tr);
        return;
    }
    for m in loop.moves {
        g = m.get("gets_shift_id");
        if g {
            set_holder(shifts[g], m["student_id"]);
        }
    }
    for sh in shifts.values() {
        sh.state = "assigned";
    }
    loop.state = "committed";
    req.state = "completed";
    for m in loop.moves {
        st = employee_of(m["student_id"]);
        if st is None {
            continue;
        }
        g = m.get("gets_shift_id");
        if g {
            to_student(st, f"Your swap is confirmed. {DAY_LONG[shifts[g].day]} is yours.", "/s");
        } else {
            to_student(st, "Your hand-off is confirmed. The shift is off your schedule.", "/s");
        }
    }
    n = len(loop.moves);
    if e is not None {
        to_employer(e, f"Swap complete. All {n} schedules updated.", f"/d/requests/{jid(req)}");
    }
    log_event(
        "Commit Service",
        f"Applied all {n} moves at once · every schedule updated",
        kind="rules",
        employer=e,
        level="done",
        link=f"/d/requests/{jid(req)}"
    );
    for m in loop.moves {
        log_event(
            "Commit Service",
            "Your swap is confirmed — your week is updated",
            kind="rules",
            student=employee_of(m["student_id"]),
            level="done"
        );
    }
}

# ------------------------------------------------------------------ helpers
def _release_shifts(loop: SwapLoop, keep: str) {
    for m in loop.moves {
        for key in ["gives_shift_id", "gets_shift_id"] {
            sid = m.get(key);
            if sid and sid != keep {
                sh = shift_of(sid);
                if sh is not None and sh.state == "pending_swap" {
                    sh.state = "assigned";
                }
            }
        }
    }
}

def _move_signature(gives: Shift | None, gets: Shift | None) -> str {
    g = f"{gives.employer},{gives.day},{gives.start},{gives.end}" if gives is not None else "-";
    r = f"{gets.employer},{gets.day},{gets.start},{gets.end}" if gets is not None else "-";
    return g + "|" + r;
}

"""If someone already said yes to an identical move for this request, don't ask them twice."""
def _previous_accepted_moves(req: SwapRequest, exclude_loop: str) -> dict[str, list[str]] {
    out: dict[str, list[str]] = {};
    for lp in [req --> [?:SwapLoop]] {
        if jid(lp) == exclude_loop {
            continue;
        }
        for o in _offers(lp) {
            if o.state not in ("accepted", "cancelled") {
                continue;
            }
            if o.state == "cancelled" and not o.responded_at {
                continue;
            }
            mv: dict[str, any] | None = None;
            for m in lp.moves {
                if m["student_id"] == o.student {
                    mv = m;
                    break;
                }
            }
            if mv is None {
                continue;
            }
            gives = shift_of(mv.get("gives_shift_id") or "");
            gets = shift_of(mv.get("gets_shift_id") or "");
            out.setdefault(o.student, []).append(_move_signature(gives, gets));
        }
    }
    return out;
}
