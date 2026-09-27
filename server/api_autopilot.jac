"""Autopilot endpoints: Mission Control, approvals inbox, copilot, calendar connect, policy."""

import from datetime { date }
import from server.clock { now_s }
import from server.timeutil { DAY_LONG, fmt_hours, hm, slot_label }
import from server.trace { Trace }
import from server.rules { Ledger }
import from server.notify { log_event, to_student }
import from server.models {
    Employer,
    Employee,
    Employment,
    AgentEvent,
    BusyBlock,
    Draft,
    Position,
    RecruitProposal,
    Requirement,
    Shift,
    SwapLoop,
    SwapRequest,
    put,
    also,
    add_shift,
    employees,
    employee_of,
    shift_of,
    draft_of,
    proposal_of,
    employment_between
}
import from server.scheduling { team_of }
import from server.api_common { UNSET, opt, ApiError, guarded, me_employer, me_student, week_arg, events_for }
import from server.api_department {
    check_view,
    probe,
    coverage,
    publish_draft,
    approve_loop,
    reject_loop,
    replace_needs
}
import from server.api_student { calendar_info }
import server.scheduling as scheduling;
import server.recruiting as recruiting;
import server.copilot as copilot;
import server.needs as needs;
import server.calendar as calendar;
import server.swaps as swaps;
import server.autopilot as autopilot;

glob AGENTS: list[dict[str, str]] = [
    {"name": "Coordinator", "kind": "agent", "role": "Orchestrates every workflow and decides which agent runs next."},
    {"name": "Availability Agent", "kind": "agent", "role": "Syncs calendars and turns notes into rules. Spots new clashes."},
    {"name": "Conflict Agent", "kind": "rules", "role": "Checks every employer's schedule. Says only yes or no."},
    {"name": "Compliance Checker", "kind": "rules", "role": "20 h international cap, assigned hours, 8 h/day, rest. Code, never AI."},
    {"name": "Scheduling Agent", "kind": "agent", "role": "Drafts the week: fairness, preferences, who takes Saturday."},
    {"name": "Swap Agent", "kind": "agent", "role": "Finds 1:1 swaps and 3–4 person loops. Re-plans on decline."},
    {"name": "Recruiting Agent", "kind": "agent", "role": "Finds students across campus for slots the team can't fill."},
    {"name": "Explainer", "kind": "agent", "role": "Writes every approval card and offer in one sentence."}
];

# ------------------------------------------------------------------ approvals inbox
def approvals(d: Employer) -> list[dict[str, any]] {
    items: list[dict[str, any]] = [];
    drafts = sorted(
        list([_q for _q in [d --> [?:Draft]] if _q.state == "draft"]), key=lambda (x: Draft) -> str { return x.created; }, reverse=True
    );
    for dr in drafts {
        s = dr.summary or {};
        wk = date.fromisoformat(dr.week);
        gaps = s.get("open_seats", 0);
        detail = (f"{gaps} slot{'s' if gaps != 1 else ''} flagged · the Recruiting Agent is on it" if gaps else "Every slot is covered")
            + " · every rule checked";
        items.append(
            {
                "type": "draft", "id": jid(dr), "agent": "Scheduling Agent", "link": f"/d/drafts/{jid(dr)}",
                "title": f"Week of {wk.strftime('%b')} {wk.day} is drafted · {s.get('filled')} of {s.get('needed')} slots filled",
                "detail": detail, "risk": "low" if not gaps else "medium"
            }
        );
    }
    for req in sorted(
        list([_q for _q in [d --> [?:SwapRequest]] if _q.state == "awaiting_manager"]), key=lambda (x: SwapRequest) -> str { return x.created; }
    ) {
        lps = [_q for _q in [req --> [?:SwapLoop]] if _q.state == "proposed"];
        if not lps {
            continue;
        }
        lp = lps[0];
        sh = shift_of(req.shift);
        st = employee_of(req.requester);
        who = st.first_name() if st is not None else "";
        why = "calendar changed" if req.origin == "calendar" else "asked for a change";
        kind = {"loop": f"{lp.size}-person swap", "direct": "direct swap", "handoff": "hand-off"}.get(lp.kind, "swap");
        items.append(
            {
                "type": "swap", "id": jid(lp), "request_id": jid(req), "agent": "Swap Agent",
                "link": f"/d/requests/{jid(req)}",
                "title": f"{who} can't make {DAY_LONG[sh.day] if sh is not None else ''} ({why}) · {kind} found",
                "detail": "Everyone stays within limits · coverage unchanged", "risk": "low"
            }
        );
    }
    for p in sorted(
        list([_q for _q in [d --> [?:RecruitProposal]] if _q.state == "proposed"]), key=lambda (x: RecruitProposal) -> str { return x.created; }
    ) {
        st = employee_of(p.student);
        if st is None {
            continue;
        }
        covers = ", ".join([slot_label(c["day"], c["start"], c["end"]) for c in p.covers]);
        items.append(
            {
                "type": "recruit", "id": jid(p), "agent": "Recruiting Agent", "link": "/d/approvals",
                "title": f"Invite {st.name} · {p.hours} hrs/week to cover {covers}",
                "detail": p.reason, "risk": "low", "status": st.status
            }
        );
    }
    return items;
}

@guarded
def:protect get_approvals() -> dict[str, any] {
    return {"items": approvals(me_employer())};
}

"""One endpoint for every approval: {type, id, approve: bool}."""
@guarded
def:protect decide(type: str = "", id: str = "", approve: bool = False) -> dict[str, any] {
    d = me_employer();
    if not type {
        raise ApiError("Missing type.");
    }
    if not id {
        raise ApiError("Missing id.");
    }
    ok = bool(approve);
    if type == "draft" {
        dr = draft_of(id);
        if dr is None or dr.employer != jid(d) or dr.state != "draft" {
            raise ApiError("This draft is no longer waiting.");
        }
        if ok {
            res = publish_draft(d, id);
            out: dict[str, any] = {"ok": True};
            for (k, v) in res.items() {
                out[k] = v;
            }
            return out;
        }
        scheduling.discard(d, dr);
        log_event("Coordinator", "Draft discarded · autopilot will wait before drafting again", kind="human", employer=d);
        return {"ok": True};
    }
    if type == "swap" {
        return approve_loop(d, id) if ok else reject_loop(d, id);
    }
    if type == "recruit" {
        p = proposal_of(id);
        if p is None or p.employer != jid(d) or p.state != "proposed" {
            raise ApiError("This suggestion is no longer waiting.");
        }
        if ok {
            recruiting.approve(p);
        } else {
            recruiting.reject(p);
        }
        autopilot.tick();  # employee autopilots answer right away
        return {"ok": True};
    }
    raise ApiError("Unknown approval.");
}

# ------------------------------------------------------------------ mission control
@guarded
def:protect get_dashboard(week: str = "") -> dict[str, any] {
    d = me_employer();
    wk = week_arg(week) if week else autopilot.planning_week();
    cov = coverage(d, wk);
    ledger = Ledger(week=wk);
    team = team_of(d);
    did = jid(d);
    hours = sum([ledger.dept_hours(jid(st), did) for st in team]);
    cal = len([st for st in team if st.calendar_source in ("google", "ics_url", "demo")]);
    s = cov["stats"];
    events = [d --> [?:AgentEvent]];
    auto_actions = len([e for e in events if e.kind != "human"]);
    human_actions = len([e for e in events if e.kind == "human"]);
    return {
        "department": cov["department"],
        "week": wk,
        "coverage": cov,
        "kpis": {
            "coverage_pct": round(100 * s["filled"] / s["needed"]) if s["needed"] else 0,
            "filled": s["filled"], "needed": s["needed"], "open": s["needed"] - s["filled"], "hours": hours,
            "students": s["students"], "calendars": cal,
            "automation_pct": round(100 * auto_actions / max(1, auto_actions + human_actions))
        },
        "approvals": approvals(d),
        "events": events_for(d, "", 30),
        "policy": {"auto_generate": d.auto_generate, "auto_recruit": d.auto_recruit, "auto_approve_swaps": d.auto_approve_swaps},
        "agents": AGENTS
    };
}

@guarded
def:protect set_policy(
    auto_generate: any = UNSET, auto_recruit: any = UNSET, auto_approve_swaps: any = UNSET
) -> dict[str, any] {
    auto_generate = opt(auto_generate);
    auto_recruit = opt(auto_recruit);
    auto_approve_swaps = opt(auto_approve_swaps);
    d = me_employer();
    if auto_generate is not None {
        d.auto_generate = bool(auto_generate);
    }
    if auto_recruit is not None {
        d.auto_recruit = bool(auto_recruit);
    }
    if auto_approve_swaps is not None {
        d.auto_approve_swaps = bool(auto_approve_swaps);
    }
    log_event("Coordinator", "Autopilot policy updated", kind="human", employer=d);
    return {"ok": True};
}

@guarded
def:protect run_autopilot() -> dict[str, any] {
    me_employer();
    stats = autopilot.tick();
    return {"ok": True, "stats": stats};
}

"""Needs Agent: description -> staffing requirements (returned for review; saved by set_staffing_needs)."""
@guarded
def:protect generate_needs(description: str = "", save: bool = False) -> dict[str, any] {
    d = me_employer();
    desc = str(description or d.description or "")[:800];
    roles = [
        {"id": jid(p), "name": p.name}
        for p in sorted(list([d --> [?:Position]]), key=lambda (x: Position) -> str { return x.created; })
    ];
    (rows, summary, used_ai) = needs.generate(desc, roles, d.kind);
    names = {r["id"]: r["name"] for r in roles};
    for n in rows {
        n["role"] = names.get(n.get("position_id") or "") or "";
    }
    if not d.description and desc {
        d.description = desc;
    }
    if save {
        d.description = desc;
        replace_needs(
            d, [(n["day"], n["start"], n["end"], n["headcount"], n.get("position_id") or "") for n in rows]
        );
        log_event("Needs Agent", f"Built your staffing plan · {len(rows)} blocks a week", employer=d, level="done");
    }
    return {"needs": rows, "summary": summary, "ai": used_ai};
}

# ------------------------------------------------------------------ manager copilot
"""Names the copilot may resolve. The wider pool is only students at the same university (campus employers)."""
def people_of(d: Employer, pool: bool = False) -> list[tuple[str, str]] {
    if pool and d.kind == "campus" and d.university {
        uni = d.university;
        return [(jid(s), s.name) for s in employees() if s.kind == "student" and s.school == uni];
    }
    return [(jid(s), s.name) for s in team_of(d)];
}

"""The role a copilot request is about: named in the text, or the only role planned for exactly that slot."""
def slot_role(d: Employer, text: str, day: int, start: int, end: int) -> str {
    roles = sorted(list([d --> [?:Position]]), key=lambda (x: Position) -> str { return x.created; });
    low = text.lower();
    for r in roles {
        words = [w for w in r.name.lower().split() if len(w) > 2];
        if words and all([w[:5] in low for w in words[-1:]]) {
            return jid(r);
        }
    }
    (dy, s, e) = (day, start, end);
    pids = {q.position for q in [d --> [?:Requirement, day == dy, start == s, end == e]]};
    if len(pids) == 1 {
        return list(pids)[0] or "";
    }
    return "";
}

def default_slot(d: Employer, day: int, hours: float | None) -> tuple[int, int] | None {
    dy = day;
    reqs = sorted(list([d --> [?:Requirement, day == dy]]), key=lambda (r: Requirement) -> int { return r.start; });
    if hours {
        start = reqs[0].start if reqs else 12 * 60;
        return (start, min(24 * 60, int(start + hours * 60)));
    }
    return (reqs[0].start, reqs[0].end) if reqs else None;
}

def reply(tr: Trace, text: str) -> dict[str, any] {
    tr.final("Need more detail", ok=False);
    return {"reply": text, "trace": tr.rows};
}

@guarded
def:protect copilot_command(text: str = "", week: str = "") -> dict[str, any] {
    d = me_employer();
    cmd = str(text or "").strip()[:300];
    if not cmd {
        raise ApiError("Type what you need.");
    }
    wk = week_arg(week) if week else autopilot.planning_week();
    team = people_of(d);
    pool = [p for p in people_of(d, pool=True) if p not in team];
    (intent, used_ai) = copilot.parse_dept(cmd, team + pool);
    tr = Trace();
    it = intent["intent"];
    tr.step("Coordinator", "agent", f"understood: {it}", ai=used_ai);
    sid: str | None = intent.get("student_id");
    day: int | None = intent.get("day");
    start: int | None = intent.get("start");
    end: int | None = intent.get("end");
    if it in ("check", "assign", "find") and day is not None and start is None {
        slot = default_slot(d, day, intent.get("hours"));
        if slot is not None {
            (start, end) = slot;
        }
    }
    team_ids = [p[0] for p in team];
    did = jid(d);

    if it in ("check", "assign") {
        if not sid or sid not in team_ids {
            return reply(tr, "I couldn't find that person on your team. Try their first name, or say “invite …”.");
        }
        if day is None or start is None or end is None {
            return reply(tr, "Which day and time? e.g. “Wed 12 to 3”.");
        }
        st = employee_of(sid);
        if st is None {
            return reply(tr, "I couldn't find that person on your team. Try their first name, or say “invite …”.");
        }
        probe(d, sid);
        ledger = Ledger(week=wk);
        pid = slot_role(d, cmd, day, start, end);
        if pid and not ledger.qualified(sid, did, pid) {
            pid = "";  # an explicit command about someone without the role books a general shift
        }
        res = check_view(d, ledger, st, day, start, end, pid);
        conflict = res.get("reason") == "schedule_conflict";
        tr.step(
            "Conflict Agent", "rules",
            "checked every employer · hidden conflict found" if conflict else "checked every employer · clear",
            status="blocked" if conflict else "done"
        );
        if not conflict {
            over = res.get("reason") == "hour_limit";
            tr.step(
                "Compliance Checker", "rules", "over the weekly limit" if over else "within every limit",
                status="blocked" if over else "done"
            );
        }
        assigned = False;
        if res["available"] and it == "assign" {
            add_shift(
                d,
                Shift(
                    week=wk, day=day, start=start, end=end, student=sid, position=pid, state="assigned",
                    status="published", source="manual"
                )
            );
            to_student(st, f"{d.name} added a shift: {slot_label(day, start, end)}.", "/s");
            log_event(
                "Scheduling Agent", f"Added {st.first_name()} to {slot_label(day, start, end)} (your command)",
                kind="human", employer=d, level="done"
            );
            assigned = True;
        }
        tr.final("Done" if res["available"] else "Blocked", ok=res["available"]);
        label = slot_label(day, start, end);
        text_out = "";
        if assigned {
            text_out = f"Added {st.first_name()} to {label}.";
        } elif res["available"] {
            text_out = f"{st.first_name()} is free for {label}.";
        } elif conflict {
            text_out = f"Can't schedule {st.first_name()} on {label}.";
        } else {
            text_out = f"Can't add {fmt_hours((end - start) / 60)} hrs for {st.first_name()} this week.";
        }
        return {
            "reply": text_out, "trace": tr.rows,
            "card": {
                "type": "check", "student_id": sid, "name": st.first_name(), "day": day, "start": start, "end": end,
                "result": res, "assigned": assigned, "week": wk, "position_id": pid or None
            }
        };
    }

    if it == "find" {
        if day is None or start is None or end is None {
            return reply(tr, "Which slot should I cover? e.g. “Who can cover Friday 3 to 7?”");
        }
        ledger = Ledger(week=wk);
        pid = slot_role(d, cmd, day, start, end);
        ranked: list[tuple[float, Employee]] = [];
        for st in team_of(d) {
            if ledger.check(jid(st), did, day, start, end, pid=pid).ok {
                ranked.append((-ledger.hours_left(jid(st), did), st));
            }
        }
        ranked.sort(key=lambda (t: tuple[float, Employee]) -> tuple[float, str] { return (t[0], t[1].name); });
        tr.step("Conflict Agent", "rules", f"checked {len(team)} people across every employer");
        tr.step("Compliance Checker", "rules", f"{len(ranked)} within limits", status="done" if ranked else "blocked");
        tr.final("Done" if ranked else "No one free", ok=bool(ranked));
        people = [{"student_id": jid(st), "name": st.name, "hours_left": -h} for (h, st) in ranked[:4]];
        label = slot_label(day, start, end);
        text_out = (
            f"{len(ranked)} {'person' if len(ranked) == 1 else 'people'} can take {label}." if ranked
            else f"No one on your team can take {label}. The Recruiting Agent can look across campus."
        );
        return {
            "reply": text_out, "trace": tr.rows,
            "card": {"type": "people", "day": day, "start": start, "end": end, "people": people, "week": wk, "position_id": pid or None}
        };
    }

    if it == "need" {
        if day is None or start is None or end is None {
            return reply(tr, "Which slot? e.g. “Need 2 more people Saturday 3 to 7”.");
        }
        n = int(intent.get("count") or 1);
        fewer = any([w in cmd.lower() for w in ["fewer", "less", "remove", "drop"]]);
        (dy, s, e) = (day, start, end);
        found = [d --> [?:Requirement, day == dy, start == s, end == e]];
        if found {
            req = found[0];
            req.headcount = max(0, req.headcount + (-n if fewer else n));
            if req.headcount == 0 {
                del req;
            }
        } elif not fewer {
            put(d, Requirement(employer=did, day=day, start=start, end=end, headcount=n));
        }
        sign = "−" if fewer else "+";
        log_event(
            "Coordinator", f"Staffing need changed · {slot_label(day, start, end)} {sign}{n}", kind="human", employer=d
        );
        tr.step("Scheduling Agent", "agent", "autopilot will fill the new slots");
        tr.final("Done");
        autopilot.tick();
        return {
            "reply": f"Updated {slot_label(day, start, end)} ({sign}{n}). Autopilot is filling it now.", "trace": tr.rows,
            "card": {"type": "link", "label": "Open approvals", "to": "/d/approvals"}
        };
    }

    if it == "invite" {
        if not sid {
            return reply(tr, "Who should I invite?");
        }
        st = employee_of(sid);
        if st is None {
            return reply(tr, "Who should I invite?");
        }
        hours = int(intent.get("hours") or 8);
        if d.kind != "campus" or st.kind != "student" or st.school != d.university {
            return reply(tr, f"Share your join code ({d.join_code}) — people join your team by signing up with it.");
        }
        emp = employment_between(st, d);
        if emp is not None and emp.state == "active" {
            return reply(tr, f"{st.first_name()} is already on your team.");
        }
        if emp is not None {
            emp.state = "invited";
            emp.hours = hours;
        } else {
            new_emp = Employment(
                student=sid, employer=did, hours=hours, state="invited", pay_rate=d.default_pay_rate, created=now_s()
            );
            put(d, new_emp);
            also(st, new_emp);
        }
        to_student(st, f"{d.name} invited you · {hours} hrs/week", "/s");
        log_event(
            "Recruiting Agent", f"Invited {st.first_name()} · {hours} hrs/week (your command)", kind="human", employer=d
        );
        tr.final("Invite sent");
        autopilot.tick();
        return {
            "reply": f"Invited {st.first_name()} for {hours} hrs/week. Their autopilot will answer if it fits their hours.",
            "trace": tr.rows
        };
    }

    if it == "generate" {
        dr = scheduling.generate(d, wk, origin="manual");
        tr.step("Scheduling Agent", "agent", f"drafted · {dr.summary['filled']} of {dr.summary['needed']} filled");
        tr.final("Ready for review");
        return {
            "reply": f"Drafted the week · {dr.summary['filled']} of {dr.summary['needed']} slots filled.", "trace": tr.rows,
            "card": {"type": "link", "label": "Review draft", "to": f"/d/drafts/{jid(dr)}"}
        };
    }

    if it == "status" {
        cov = coverage(d, wk);
        s = cov["stats"];
        short = [
            f"{DAY_LONG[c['day']][:3]} {hm(c['start'])}–{hm(c['end'])}" for c in cov["cells"] if c["assigned"] < c["needed"]
        ];
        tr.final("Done");
        text_out = f"{s['filled']} of {s['needed']} slots filled"
            + (f" · short on {', '.join(short[:4])}" if short else " · fully covered")
            + f" · {len(approvals(d))} waiting for you.";
        return {"reply": text_out, "trace": tr.rows};
    }

    first = team[0][1].split()[0] if team else "Sam";
    return reply(
        tr,
        f"I can check or assign someone (“Can {first} work Wed 12–3?”), find cover (“Who can cover Fri evening?”), "
            + "change needs (“Need 2 more Saturday 3–7”), " + ("invite a student, " if d.kind == "campus" else "")
            + "or build the schedule."
    );
}

# ------------------------------------------------------------------ employee copilot
@guarded
def:protect student_command(text: str = "", week: str = "") -> dict[str, any] {
    st = me_student();
    msg = str(text or "").strip()[:300];
    if not msg {
        raise ApiError("Tell CampusSync what changed.");
    }
    wk = week_arg(week) if week else autopilot.planning_week();
    (intent, used_ai) = copilot.parse_student(msg);
    tr = Trace();
    tr.step("Coordinator", "agent", f"understood: {intent['intent']}", ai=used_ai);
    sid = jid(st);
    ledger = Ledger(week=wk);
    if intent["intent"] == "hours" {
        total = ledger.total_hours(sid);
        cap = st.cap();
        tr.final("Done");
        return {
            "reply": f"You're at {fmt_hours(total)} of {cap} hrs this week · {fmt_hours(max(0.0, cap - total))} left.",
            "trace": tr.rows
        };
    }
    if intent["intent"] == "unavailable" {
        for u in intent["unavailable"] {
            put(
                st,
                BusyBlock(
                    day=u["day"], start=u["start"], end=u["end"], title=u["label"], source="note",
                    week="" if u["recurring"] else wk
                )
            );
        }
        parts: list[str] = [];
        for u in intent["unavailable"] {
            whole = u["start"] == 0 and u["end"] == 1440;
            parts.append(
                f"{DAY_LONG[u['day']]}{'s' if u['recurring'] else ''}" + ("" if whole else f" {hm(u['start'])}–{hm(u['end'])}")
            );
        }
        labels = ", ".join(parts);
        log_event("Availability Agent", f"Blocked {labels} from your note", student=st);
        tr.step("Availability Agent", "agent", f"blocked {labels}", ai=used_ai);
        before = {jid(r) for r in [st --> [?:SwapRequest]]};
        if intent["want_days"] {
            saved = list(st.open_swap_days or []);
            st.open_swap_days = intent["want_days"];
            calendar.detect_disruptions(st);
            st.open_swap_days = saved;
        } else {
            calendar.detect_disruptions(st);
        }
        new = sorted(
            [r for r in [st --> [?:SwapRequest]] if jid(r) not in before],
            key=lambda (r: SwapRequest) -> str { return r.created; }
        );
        for r in new {
            tr.rows = tr.rows + [row for row in (r.trace or []) if row["kind"] != "final"];
        }
        if new {
            found = any([r.state == "awaiting_manager" for r in new]);
            tr.final("Cover found · waiting for your manager" if found else "Still searching", ok=found);
            text_out = f"Got it — {labels} is blocked. You had a shift then, so autopilot "
                + ("found a swap and sent it to your manager." if found else "is looking for cover and will keep trying.");
            return {
                "reply": text_out, "trace": tr.rows,
                "card": {"type": "link", "label": "Follow it", "to": f"/s/request?id={jid(new[0])}"}
            };
        }
        tr.final("Done");
        return {"reply": f"Got it — {labels} is blocked. No shifts were affected.", "trace": tr.rows};
    }
    if intent["intent"] == "swap" and intent.get("give_up_day") is not None {
        gd = intent["give_up_day"];
        rows = [
            s for s in [_q for _q in [st --> [?:Shift, week == wk, day == gd]] if _q.status == "published" and _q.state == "assigned"]
            if s.student == sid
        ];
        if not rows {
            return reply(tr, f"You don't have a {DAY_LONG[gd]} shift this week.");
        }
        try {
            req = swaps.create_request(
                st, jid(rows[0]), "days" if intent["want_days"] else "any", intent["want_days"], msg, origin="copilot"
            );
            tr.rows = tr.rows + [row for row in (req.trace or []) if row["kind"] != "final"];
            found = req.state == "awaiting_manager";
            tr.final("Ready for your manager" if found else "Still searching", ok=found);
            return {
                "reply": "Found a swap — sent to your manager." if found else "No swap yet. Autopilot will keep looking.",
                "trace": tr.rows,
                "card": {"type": "link", "label": "Follow it", "to": f"/s/request?id={jid(req)}"}
            };
        } except swaps.SwapError as se {
            return reply(tr, str(se));
        }
    }
    if intent["intent"] == "status" {
        shifts = [s for s in [_q for _q in [st --> [?:Shift, week == wk]] if _q.status == "published"] if s.student == sid];
        tr.final("Done");
        return {
            "reply": f"You have {len(shifts)} shifts this week · {fmt_hours(ledger.total_hours(sid))} of {st.cap()} hrs.",
            "trace": tr.rows
        };
    }
    return reply(
        tr,
        "Tell me what changed, like “I can't do Saturday, Wednesday works” or “dentist Friday 2–4”. I'll handle the rest."
    );
}

# ------------------------------------------------------------------ calendar connect
@guarded
def:protect connect_calendar(source: str = "", url: str = "") -> dict[str, any] {
    import from server.seed { sample_demo_events }
    st = me_student();
    if source == "ics_url" {
        link = str(url or "").strip();
        if not link {
            raise ApiError("Missing url.");
        }
        text = "";
        try {
            text = calendar.fetch_ics_url(link);
        } except calendar.CalendarError as ce {
            raise ApiError(str(ce));
        }
        st.calendar_source = "ics_url";
        st.calendar_url = link;
        calendar.replace_calendar_blocks(st, calendar.blocks_from_ics_text(text));
    } elif source == "demo" {
        st.calendar_source = "demo";
        if not st.demo_events {
            st.demo_events = sample_demo_events();
        }
    } else {
        raise ApiError("Choose how to connect your calendar.");
    }
    res = calendar.sync_student(st, announce=True);
    return {"ok": res.get("ok", True), "calendar": calendar_info(st), "error": res.get("error")};
}

"""Returns Google's consent URL for this employee (the browser goes there directly -- no session token in any URL)."""
@guarded
def:protect start_google_connect(next: str = "/s/availability", origin: str = "") -> dict[str, any] {
    st = me_student();
    if not calendar.google_enabled() {
        raise ApiError("Google sign-in isn't configured on this server yet. Use your calendar's secret iCal link instead.");
    }
    nxt = str(next or "/s/availability");
    if not nxt.startswith("/") or nxt.startswith("//") {
        nxt = "/s/availability";
    }
    return {"url": calendar.google_auth_url(jid(st), nxt, str(origin or ""))};
}

@guarded
def:protect sync_calendar() -> dict[str, any] {
    st = me_student();
    res = calendar.sync_student(st, announce=True);
    if not res.get("ok") {
        raise ApiError(res.get("error") or "Couldn't sync.");
    }
    out: dict[str, any] = {"ok": True, "calendar": calendar_info(st)};
    for (k, v) in res.items() {
        if k != "ok" {
            out[k] = v;
        }
    }
    return out;
}

@guarded
def:protect disconnect_calendar() -> dict[str, any] {
    st = me_student();
    if st.calendar_source == "google" or st.google_refresh_token {
        calendar.disconnect_google(st);
    }
    st.calendar_source = "";
    st.calendar_url = "";
    st.calendar_error = "";
    for b in calendar.calendar_blocks(st) {
        del b;
    }
    return {"ok": True, "calendar": calendar_info(st)};
}
