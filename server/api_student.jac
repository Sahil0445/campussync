"""Employee endpoints. An employee sees ALL of their own jobs and hours -- it's their data."""

import from pathlib { Path }
import from datetime { date, timedelta }
import from server.clock { utcnow, now_s, today_local, monday, slot_datetime, to_utc_naive, seconds_since, parse_iso }
import from server.timeutil { DAY_LONG, hm, slot_label }
import from server.rules { Ledger }
import from server.notify { log_event, to_employer }
import from server.models {
    Employee,
    Employer,
    Employment,
    BusyBlock,
    Shift,
    SwapRequest,
    SwapLoop,
    SwapOffer,
    TimeEntry,
    put,
    set_holder,
    employer_of,
    employee_of,
    employment_of,
    position_of,
    shift_of,
    request_of,
    loop_of,
    offer_of
}
import from server.membership { can_join }
import from server.api_common { UNSET, opt, ApiError, guarded, me_student, week_arg }
import server.availability as availability;
import server.calendar as calendar;
import server.recruiting as recruiting;
import server.swaps as swaps;
import server.timesheets as timesheets;

glob PREFS: list[str] = ["Mornings", "Afternoons", "Evenings", "Weekends"],
     SAMPLE_ICS: Path = Path(__file__).resolve().parent / "sample_calendar.ics";

def calendar_info(st: Employee) -> dict[str, any] {
    labels = {"google": "Google Calendar", "ics_url": "Calendar link", "demo": "Demo calendar", "upload": "Uploaded .ics"};
    return {
        "source": st.calendar_source,
        "connected": st.calendar_source in ("google", "ics_url", "demo"),
        "label": labels.get(st.calendar_source, ""),
        "account": st.google_email if st.calendar_source == "google" else "",
        "writes_shifts": st.calendar_source == "google" and bool(st.google_calendar_id),
        # The demo feed is re-read every autopilot cycle (it only rewrites the graph when it changed).
        "synced_seconds_ago": (0 if st.calendar_source == "demo" else seconds_since(st.calendar_synced_at))
            if st.calendar_synced_at else None,
        "error": st.calendar_error,
        "google_available": calendar.google_enabled()
    };
}

def blocks_view(st: Employee) -> list[dict[str, any]] {
    rows = sorted(list([st --> [?:BusyBlock]]), key=lambda (b: BusyBlock) -> tuple[int, int] { return (b.day, b.start); });
    return [
        {"id": jid(b), "day": b.day, "start": b.start, "end": b.end, "title": b.title, "source": b.source}
        for b in rows
    ];
}

@guarded
def:protect get_availability() -> dict[str, any] {
    st = me_student();
    blocks = blocks_view(st);
    return {
        "blocks": blocks,
        "note": st.note,
        "rules": [
            {"day": b["day"], "start": b["start"], "end": b["end"], "label": b["title"]}
            for b in blocks if b["source"] == "note"
        ],
        "classes": len({b["title"] for b in blocks if b["source"] == "calendar"}),
        "calendar": calendar_info(st),
        "profile": {
            "limit": st.cap(), "kind": st.kind, "international": st.is_international(), "status": st.status,
            "open_swap_days": st.open_swap_days or [], "autopilot": st.autopilot
        }
    };
}

@guarded
def:protect import_calendar(ics: str = "", sample: bool = False) -> dict[str, any] {
    st = me_student();
    text = SAMPLE_ICS.read_text(encoding="utf-8") if sample else str(ics or "");
    if not text.strip() {
        raise ApiError("That file looks empty. Try exporting your calendar as .ics again.");
    }
    if "BEGIN:VCALENDAR" not in text[:2000].upper() {
        raise ApiError("That doesn't look like a calendar file (.ics).");
    }
    blocks = calendar.blocks_from_ics_text(text);
    calendar.replace_calendar_blocks(st, blocks);
    st.calendar_source = "upload";
    st.calendar_synced_at = now_s();
    log_event("Availability Agent", f"Imported your calendar · {len(blocks)} events", student=st);
    calendar.detect_disruptions(st);
    titles = {b["title"] for b in blocks};
    return {"count": len(titles), "blocks": blocks_view(st)};
}

"""Availability Agent (AI): free text -> structured rules, stored as unavailable time."""
@guarded
def:protect parse_availability_note(note: str = "") -> dict[str, any] {
    st = me_student();
    text = str(note or "")[:500];
    (rules, used_ai) = availability.parse_note(text);
    st.note = text;
    for b in [st --> [?:BusyBlock, source == "note"]] {
        del b;
    }
    for r in rules {
        put(st, BusyBlock(day=r["day"], start=r["start"], end=r["end"], title=r["label"], source="note"));
    }
    if rules {
        log_event(
            "Availability Agent",
            f"Understood your note · {len(rules)} rule{'s' if len(rules) != 1 else ''}",
            student=st
        );
    }
    calendar.detect_disruptions(st);
    return {"rules": rules, "ai": used_ai, "blocks": blocks_view(st)};
}

@guarded
def:protect remove_availability_rule(day: int = -1, start: int = -1, end: int = -1) -> dict[str, any] {
    st = me_student();
    (dy, s, e) = (day, start, end);
    for b in [st --> [?:BusyBlock, source == "note", day == dy, start == s, end == e]] {
        del b;
    }
    return {"blocks": blocks_view(st)};
}

@guarded
def:protect update_profile(
    desired_hours: any = UNSET,
    preferences: any = UNSET,
    open_swap_days: any = UNSET,
    autopilot: any = UNSET,
    weekly_limit: any = UNSET
) -> dict[str, any] {
    desired_hours = opt(desired_hours);
    preferences = opt(preferences);
    open_swap_days = opt(open_swap_days);
    autopilot = opt(autopilot);
    weekly_limit = opt(weekly_limit);
    st = me_student();
    if desired_hours is not None {
        st.desired_hours = max(0, min(st.cap(), int(desired_hours)));
    }
    if preferences is not None {
        st.preferences = [p for p in preferences if p in PREFS];
    }
    if open_swap_days is not None {
        st.open_swap_days = sorted({int(d) for d in open_swap_days if 0 <= int(d) and int(d) <= 6});
    }
    if autopilot is not None {
        st.autopilot = bool(autopilot);
    }
    if weekly_limit is not None and not st.is_international() {
        st.weekly_limit = max(1, min(40 if st.kind == "student" else 80, int(weekly_limit)));
    }
    return {"ok": True};
}

def _role(pid: str) -> str {
    p = position_of(pid);
    return p.name if p is not None else "";
}

def _shift_date(sh: Shift) -> date {
    return date.fromisoformat(sh.week) + timedelta(days=sh.day);
}

@guarded
def:protect get_student_home(week: str = "") -> dict[str, any] {
    st = me_student();
    swaps.sweep_employee(st);
    wk = week_arg(week);
    sid = jid(st);
    ledger = Ledger(week=wk);
    emps = sorted(list([st --> [?:Employment]]), key=lambda (e: Employment) -> str { return e.created; });
    depts: dict[str, Employer] = {};
    for e in emps {
        d = employer_of(e.employer);
        if d is not None {
            depts[e.employer] = d;
        }
    }
    active = [e for e in emps if e.state == "active" and e.employer in depts];
    total = ledger.total_hours(sid);
    by_job = sorted(
        [{"department": depts[e.employer].name, "hours": ledger.dept_hours(sid, e.employer)} for e in active],
        key=lambda (j: dict[str, any]) -> float { return -j["hours"]; }
    );
    shifts = sorted(
        [s for s in [_q for _q in [st --> [?:Shift, week == wk]] if _q.status == "published"] if s.student == sid],
        key=lambda (s: Shift) -> tuple[int, int] { return (s.day, s.start); }
    );
    rate = {e.employer: e.pay_rate for e in active};
    now = utcnow();
    offers = [o for o in [st --> [?:SwapOffer]] if o.state == "waiting"];
    reqs = [r for r in [st --> [?:SwapRequest]] if r.requester == sid and r.state in swaps.ACTIVE_REQUEST_STATES];
    assigned_total = sum([e.hours for e in active]);
    worked = {te.shift for te in [st --> [?:TimeEntry]] if te.shift};
    # Next shift from now on, across weeks
    upcoming: dict[str, any] | None = None;
    this_week = monday(today_local()).isoformat();
    future = sorted(
        [s for s in [_q for _q in [st --> [?:Shift]] if _q.status == "published"] if s.student == sid and s.week >= this_week],
        key=lambda (s: Shift) -> tuple[str, int, int] { return (s.week, s.day, s.start); }
    );
    for sh in future {
        d = depts.get(sh.employer) or employer_of(sh.employer);
        if d is None {
            continue;
        }
        start = to_utc_naive(slot_datetime(sh.week, sh.day, sh.start, d.timezone));
        end = to_utc_naive(slot_datetime(sh.week, sh.day, sh.end, d.timezone));
        if end <= now {
            continue;
        }
        upcoming = {
            "id": jid(sh), "date": _shift_date(sh).isoformat(), "day": sh.day, "start": sh.start, "end": sh.end,
            "department": d.name, "role": _role(sh.position) if sh.position else "",
            "starts_in_seconds": int((start - now).total_seconds()), "in_progress": start <= now
        };
        break;
    }
    ts = timesheets.employee_timesheet(st);
    return {
        "student": {
            "name": st.name, "first_name": st.first_name(), "status": st.status, "autopilot": st.autopilot,
            "kind": st.kind, "international": st.is_international()
        },
        "calendar": calendar_info(st),
        "week": wk,
        "hours": {"scheduled": total, "limit": st.cap(), "left": max(0.0, st.cap() - total), "by_job": by_job},
        "pay": {"projected_gross": round(sum([s.hours() * rate.get(s.employer, 0) for s in shifts]), 2)},
        "jobs": [
            {
                "department_id": e.employer, "department": depts[e.employer].name, "hours": e.hours,
                "state": e.state, "pay_rate": e.pay_rate,
                "roles": [_role(p) for p in (e.positions or []) if _role(p)]
            }
            for e in active
        ],
        "invites": [
            {
                "employment_id": jid(e), "department": depts[e.employer].name, "hours": e.hours,
                "total_assigned": assigned_total + e.hours, "limit": st.cap()
            }
            for e in emps if e.state == "invited" and e.employer in depts
        ],
        "offers": [
            {"offer_id": jid(o), "expires_in_seconds": max(0, -seconds_since(o.expires_at))} for o in offers
        ],
        "requests": [{"request_id": jid(r), "state": r.state} for r in reqs],
        "shifts": [
            {
                "id": jid(s), "day": s.day, "date": _shift_date(s).isoformat(), "start": s.start, "end": s.end,
                "department": depts[s.employer].name if s.employer in depts else "",
                "role": _role(s.position) if s.position else "", "state": s.state, "hours": s.hours(),
                "worked": jid(s) in worked
            }
            for s in shifts
        ],
        "next_shift": upcoming,
        "timesheet": {
            "pending_count": ts["pending_count"], "pending_hours": ts["pending_hours"],
            "next_review": ts["next_review"], "review_today": ts["review_today"],
            "disputed_count": ts["disputed_count"]
        }
    };
}

@guarded
def:protect respond_invite(employment_id: str = "", accept: bool = False) -> dict[str, any] {
    st = me_student();
    emp = employment_of(str(employment_id or ""));
    if emp is None or emp.student != jid(st) or emp.state != "invited" {
        raise ApiError("This invite is no longer open.");
    }
    dept = employer_of(emp.employer);
    if dept is None {
        raise ApiError("This invite is no longer open.");
    }
    if accept {
        reason = can_join(st, dept, ignore_invite=jid(emp));
        if reason {
            raise ApiError(reason);
        }
        emp.state = "active";
        log_event("Recruiting Agent", f"{st.first_name()} accepted your invite", kind="human", employer=dept, level="done");
        recruiting.on_invite_answer(st, dept, True);
    } else {
        emp.state = "declined";
        to_employer(dept, f"{st.first_name()} declined your invite.", "/d/team");
        recruiting.on_invite_answer(st, dept, False);
    }
    return {"ok": True, "department": dept.name};
}

def want_label(req: SwapRequest) -> str {
    if req.want_kind == "days" {
        return ", ".join([DAY_LONG[x] for x in req.want_days]);
    }
    return "Any other time" if req.want_kind == "any" else "Give it up";
}

def request_status(req: SwapRequest) -> dict[str, any] {
    sh = shift_of(req.shift);
    dept = employer_of(req.employer);
    my_offer: dict[str, any] | None = None;
    if req.state == "offered" {
        lps = [_q for _q in [req --> [?:SwapLoop]] if _q.state == "approved"];
        if lps {
            rq = req.requester;
            os = [o for o in [lps[0] --> [?:SwapOffer]] if o.student == rq];
            if os {
                my_offer = {"offer_id": jid(os[0]), "state": os[0].state};
            }
        }
    }
    messages: dict[str, tuple[str, str]] = {
        "awaiting_manager": ("Found a swap. Waiting for your manager to approve.", "waiting"),
        "offered": ("Your manager approved. Waiting for everyone to say yes.", "waiting"),
        "searching": ("No swap available yet. We'll keep looking and notify you.", "searching"),
        "no_option": ("No swap available yet. We'll keep looking and notify you.", "searching"),
        "completed": ("Swap complete. Your schedule is updated.", "confirmed"),
        "rejected": ("Your manager didn't approve this swap. Your shift stays as it was.", "blocked"),
        "cancelled": ("You cancelled this request.", "neutral")
    };
    (msg, chip) = messages.get(req.state, ("", "neutral"));
    return {
        "request_id": jid(req), "state": req.state, "message": msg, "chip": chip, "trace": req.trace or [],
        "shift": slot_label(sh.day, sh.start, sh.end) if sh is not None else "",
        "department": dept.name if dept is not None else "", "want": want_label(req), "offer": my_offer
    };
}

@guarded
def:protect request_swap(
    shift_id: str = "", want_kind: str = "days", want_days: any = UNSET, reason: str = ""
) -> dict[str, any] {
    want_days = opt(want_days);
    st = me_student();
    if not shift_id {
        raise ApiError("Missing shift id.");
    }
    try {
        req = swaps.create_request(st, str(shift_id), str(want_kind or "days"), list(want_days or []), str(reason or ""));
        return request_status(req);
    } except swaps.SwapError as se {
        raise ApiError(str(se));
    }
}

@guarded
def:protect get_my_request(request_id: str = "") -> dict[str, any] {
    st = me_student();
    req = request_of(str(request_id or ""));
    if req is None or req.requester != jid(st) {
        raise ApiError("Request not found.");
    }
    swaps.sweep_employee(st);
    return request_status(req);
}

@guarded
def:protect cancel_request(request_id: str = "") -> dict[str, any] {
    st = me_student();
    req = request_of(str(request_id or ""));
    if req is None or req.requester != jid(st) or req.state not in ("searching", "awaiting_manager") {
        raise ApiError("This request can't be cancelled now.");
    }
    for lp in [_q for _q in [req --> [?:SwapLoop]] if _q.state == "proposed"] {
        lp.state = "rejected";
    }
    req.state = "cancelled";
    sh = shift_of(req.shift);
    if sh is not None {
        sh.state = "assigned";
    }
    return {"ok": True};
}

def offer_view(st: Employee, offer: SwapOffer) -> dict[str, any] {
    loop = loop_of(offer.loop);
    if loop is None {
        raise ApiError("Offer not found.");
    }
    req = request_of(loop.request);
    dept = employer_of(req.employer) if req is not None else None;
    sid = jid(st);
    move: dict[str, any] = {};
    for m in loop.moves {
        if m["student_id"] == sid {
            move = m;
            break;
        }
    }
    gives = shift_of(move.get("gives_shift_id") or "");
    gets = shift_of(move.get("gets_shift_id") or "");
    anchor = gets if gets is not None else gives;
    ledger = Ledger(week=anchor.week if anchor is not None else "");
    now_total = ledger.total_hours(sid);
    gets_h = gets.hours() if gets is not None else 0.0;
    gives_h = gives.hours() if gives is not None else 0.0;
    before = now_total;
    after = now_total;
    if loop.state == "committed" {
        after = now_total;
        before = now_total - gets_h + gives_h;
    } else {
        before = now_total;
        after = now_total - gives_h + gets_h;
    }
    offers: dict[str, SwapOffer] = {o.student: o for o in [loop --> [?:SwapOffer]]};
    circle: list[dict[str, any]] = [];
    for m in loop.moves {
        o = offers.get(m["student_id"]);
        s = employee_of(m["student_id"]);
        gs = shift_of(m.get("gets_shift_id") or "");
        circle.append(
            {
                "name": s.first_name() if s is not None else "", "me": m["student_id"] == sid,
                "state": o.state if o is not None else "waiting",
                "gets": slot_label(gs.day, gs.start, gs.end) if gs is not None else None
            }
        );
    }
    others = [c for c in circle if not c["me"]];
    status = offer.state;
    if loop.state == "committed" {
        status = "confirmed";
    } elif loop.state in ("declined", "invalidated", "rejected") {
        status = "closed";
    }
    return {
        "offer_id": jid(offer), "state": offer.state, "status": status, "kind": loop.kind,
        "department": dept.name if dept is not None else "",
        "gets": slot_label(gets.day, gets.start, gets.end) if gets is not None else None,
        "gets_day": DAY_LONG[gets.day] if gets is not None else None,
        "gives": slot_label(gives.day, gives.start, gives.end) if gives is not None else None,
        "hours_before": before, "hours_after": after,
        "circle": circle, "others": len(others),
        "others_accepted": len([c for c in others if c["state"] == "accepted"]),
        "expires_in_seconds": max(0, -seconds_since(offer.expires_at)),
        "rationale": loop.rationale
    };
}

@guarded
def:protect get_offer(offer_id: str = "") -> dict[str, any] {
    st = me_student();
    swaps.sweep_employee(st);
    offer = offer_of(str(offer_id or ""));
    if offer is None or offer.student != jid(st) {
        raise ApiError("Offer not found.");
    }
    return offer_view(st, offer);
}

@guarded
def:protect respond_offer(
    offer_id: str = "", accept: bool = False, reason_chip: str = "", reason_text: str = ""
) -> dict[str, any] {
    st = me_student();
    offer = offer_of(str(offer_id or ""));
    if offer is None or offer.student != jid(st) {
        raise ApiError("Offer not found.");
    }
    try {
        swaps.respond(offer, bool(accept), str(reason_chip or ""), str(reason_text or ""));
    } except swaps.SwapError as se {
        raise ApiError(str(se));
    }
    return offer_view(st, offer);
}

@guarded
def:protect list_my_requests() -> dict[str, any] {
    st = me_student();
    swaps.sweep_employee(st);
    sid = jid(st);
    reqs = sorted(
        [r for r in [st --> [?:SwapRequest]] if r.requester == sid],
        key=lambda (r: SwapRequest) -> str { return r.created; },
        reverse=True
    )[:20];
    return {"requests": [request_status(r) for r in reqs]};
}

def open_shifts_for(st: Employee, week: str, ledger: Ledger) -> list[dict[str, any]] {
    sid = jid(st);
    out: list[dict[str, any]] = [];
    wk = week;
    for emp in [_q for _q in [st --> [?:Employment]] if _q.state == "active"] {
        d = employer_of(emp.employer);
        if d is None {
            continue;
        }
        rows = sorted(
            [s for s in [_q for _q in [d --> [?:Shift, week == wk]] if _q.status == "published" and _q.state == "open"] if not s.student],
            key=lambda (s: Shift) -> tuple[int, int] { return (s.day, s.start); }
        );
        for s in rows {
            if ledger.check(sid, jid(d), s.day, s.start, s.end).ok {
                out.append({"id": jid(s), "day": s.day, "start": s.start, "end": s.end, "department": d.name});
            }
        }
    }
    return sorted(out, key=lambda (x: dict[str, any]) -> tuple[int, int] { return (x["day"], x["start"]); });
}

@guarded
def:protect get_open_shifts(week: str = "") -> dict[str, any] {
    st = me_student();
    wk = week_arg(week);
    return {"shifts": open_shifts_for(st, wk, Ledger(week=wk))};
}

@guarded
def:protect claim_open_shift(shift_id: str = "") -> dict[str, any] {
    st = me_student();
    sh = shift_of(str(shift_id or ""));
    if sh is None or sh.student or sh.state != "open" {
        raise ApiError("Someone already took this shift.");
    }
    v = Ledger(week=sh.week).check(jid(st), sh.employer, sh.day, sh.start, sh.end);
    if not v.ok {
        raise ApiError("This shift would put you over a limit or clash with your schedule.");
    }
    set_holder(sh, jid(st));
    sh.state = "assigned";
    d = employer_of(sh.employer);
    if d is not None {
        to_employer(d, f"{st.first_name()} picked up the open shift {slot_label(sh.day, sh.start, sh.end)}.", "/d");
    }
    return {"ok": True};
}

"""Requests screen: everything that asks something of the employee, plus what they asked for."""
@guarded
def:protect get_student_inbox() -> dict[str, any] {
    st = me_student();
    swaps.sweep_employee(st);
    sid = jid(st);
    offers: list[dict[str, any]] = [];
    for o in sorted(list([st --> [?:SwapOffer]]), key=lambda (x: SwapOffer) -> str { return x.created; }, reverse=True)[:30] {
        loop = loop_of(o.loop);
        if loop is None {
            continue;
        }
        move: dict[str, any] | None = None;
        for m in loop.moves {
            if m["student_id"] == sid {
                move = m;
                break;
            }
        }
        if move is None {
            continue;
        }
        gives = shift_of(move.get("gives_shift_id") or "");
        gets = shift_of(move.get("gets_shift_id") or "");
        ref = gets if gets is not None else gives;
        dept = employer_of(ref.employer) if ref is not None else None;
        offers.append(
            {
                "offer_id": jid(o), "state": o.state, "auto": o.auto,
                "loop_state": loop.state, "size": loop.size, "kind": loop.kind,
                "department": dept.name if dept is not None else "",
                "gets": slot_label(gets.day, gets.start, gets.end) if gets is not None else None,
                "gives": slot_label(gives.day, gives.start, gives.end) if gives is not None else None,
                "seconds_ago": seconds_since(o.created),
                "expires_in_seconds": max(0, -seconds_since(o.expires_at))
            }
        );
    }
    invites: list[dict[str, any]] = [];
    for e in sorted(list([_q for _q in [st --> [?:Employment]] if _q.state == "invited"]), key=lambda (x: Employment) -> str { return x.created; }) {
        d = employer_of(e.employer);
        invites.append({"employment_id": jid(e), "department": d.name if d is not None else "", "hours": e.hours});
    }
    reqs = sorted(
        [r for r in [st --> [?:SwapRequest]] if r.requester == sid],
        key=lambda (r: SwapRequest) -> str { return r.created; },
        reverse=True
    )[:20];
    rows: list[dict[str, any]] = [];
    for r in reqs {
        item = request_status(r);
        item["origin"] = r.origin;
        rows.append(item);
    }
    return {"offers": offers, "invites": invites, "requests": rows};
}
