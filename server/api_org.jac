"""Employer endpoints: organization settings, join code, positions (roles), team pay/hours, timesheets."""

import from datetime { timedelta }
import from server.clock { utcnow, current_week, iso, parse_iso }
import from server.rules { Ledger }
import from server.notify { log_event, to_student }
import from server.models {
    Employer,
    Employee,
    Employment,
    Position,
    Requirement,
    Shift,
    TimeEntry,
    put,
    employee_of,
    entry_of,
    position_of,
    university_of
}
import from server.membership { JoinError, new_join_code, leave_team }
import from server.api_membership { _tz }
import from server.api_common { UNSET, opt, ApiError, guarded, me_employer, week_arg }
import server.timesheets as timesheets;
import server.autopilot as autopilot;

glob ROLE_COLORS: list[str] = ["#a18bff", "#3dd8f5", "#6c8cff", "#f5a3c7", "#7ee0b5", "#ffc46b", "#ff8f7a", "#9fb4ff"];

def positions_sorted(d: Employer) -> list[Position] {
    return sorted(list([d --> [?:Position]]), key=lambda (p: Position) -> str { return p.created; });
}

def org_view(d: Employer) -> dict[str, any] {
    uni = university_of(d.university);
    emps = [e for e in [d --> [?:Employment]] if e.state == "active"];
    roles: list[dict[str, any]] = [];
    for p in positions_sorted(d) {
        pj = jid(p);
        roles.append(
            {"id": pj, "name": p.name, "color": p.color, "members": len([e for e in emps if pj in (e.positions or [])])}
        );
    }
    return {
        "id": jid(d),
        "name": d.name,
        "kind": d.kind,
        "university": uni.name if uni is not None else None,
        "join_code": d.join_code,
        "timezone": d.timezone,
        "default_pay_rate": d.default_pay_rate,
        "default_weekly_hours": d.default_weekly_hours,
        "state_tax_pct": d.state_tax_pct,
        "description": d.description,
        "positions": roles,
        "team_size": len(emps),
        "policy": {
            "auto_generate": d.auto_generate, "auto_recruit": d.auto_recruit, "auto_approve_swaps": d.auto_approve_swaps
        }
    };
}

@guarded
def:protect get_org() -> dict[str, any] {
    return org_view(me_employer());
}

def num_arg(v: any, lo: float, hi: float, label: str) -> float | None {
    if v is None or v == "" {
        return None;
    }
    f = 0.0;
    try {
        f = float(v);
    } except Exception {
        raise ApiError(f"{label} isn't a number.");
    }
    if not (lo <= f and f <= hi) {
        raise ApiError(f"{label} must be between {lo:g} and {hi:g}.");
    }
    return f;
}

@guarded
def:protect update_org(
    name: any = UNSET,
    timezone: str = "",
    description: any = UNSET,
    default_pay_rate: any = UNSET,
    apply_to_team: bool = False,
    default_weekly_hours: any = UNSET,
    state_tax_pct: any = UNSET
) -> dict[str, any] {
    name = opt(name);
    description = opt(description);
    default_pay_rate = opt(default_pay_rate);
    default_weekly_hours = opt(default_weekly_hours);
    state_tax_pct = opt(state_tax_pct);
    d = me_employer();
    if name is not None {
        nm = str(name).strip()[:120];
        if len(nm) < 2 {
            raise ApiError("The organization name is too short.");
        }
        d.name = nm;
    }
    if timezone {
        d.timezone = _tz(timezone);
    }
    if description is not None {
        d.description = str(description).strip()[:500];
    }
    rate = num_arg(default_pay_rate, 0, 500, "Pay rate");
    if rate is not None {
        d.default_pay_rate = round(rate, 2);
        if apply_to_team {
            for e in [d --> [?:Employment]] {
                if e.state in ("active", "invited") {
                    e.pay_rate = d.default_pay_rate;
                }
            }
        }
    }
    hours = num_arg(default_weekly_hours, 1, 80, "Weekly hours");
    if hours is not None {
        d.default_weekly_hours = int(hours);
    }
    tax = num_arg(state_tax_pct, 0, 15, "State tax");
    if tax is not None {
        d.state_tax_pct = round(tax, 2);
    }
    log_event("Coordinator", "Organization settings updated", kind="human", employer=d);
    return org_view(d);
}

@guarded
def:protect regenerate_join_code() -> dict[str, any] {
    d = me_employer();
    try {
        d.join_code = new_join_code(d.name);
    } except JoinError as je {
        raise ApiError(str(je));
    }
    log_event("Coordinator", f"New join code {d.join_code} · the old one stopped working", kind="human", employer=d);
    return org_view(d);
}

@guarded
def:protect save_position(name: str = "", id: str = "", color: str = "") -> dict[str, any] {
    d = me_employer();
    nm = str(name or "").strip()[:80];
    if not nm {
        raise ApiError("Missing name.");
    }
    if len(nm) < 2 {
        raise ApiError("Give the role a name.");
    }
    existing = positions_sorted(d);
    if any([p.name.lower() == nm.lower() and jid(p) != (id or "") for p in existing]) {
        raise ApiError("You already have a role with that name.");
    }
    if id {
        p = position_of(id);
        if p is None or p.employer != jid(d) {
            raise ApiError("Role not found.");
        }
        p.name = nm;
        if color {
            p.color = str(color)[:9];
        }
    } else {
        if len(existing) >= 30 {
            raise ApiError("That's a lot of roles — 30 is the limit.");
        }
        put(
            d,
            Position(
                employer=jid(d), name=nm, color=str(color or ROLE_COLORS[len(existing) % len(ROLE_COLORS)])[:9],
                created=iso(utcnow())
            )
        );
        log_event("Coordinator", f"Added the {nm} role", kind="human", employer=d);
    }
    return org_view(d);
}

@guarded
def:protect delete_position(id: str = "") -> dict[str, any] {
    d = me_employer();
    p = position_of(str(id or ""));
    if p is None or p.employer != jid(d) {
        raise ApiError("Role not found.");
    }
    pj = jid(p);
    for e in [d --> [?:Employment]] {
        if pj in (e.positions or []) {
            e.positions = [x for x in e.positions if x != pj];
        }
    }
    for r in [_q for _q in [d --> [?:Requirement]] if _q.position == pj] {
        r.position = "";
    }
    for sh in [_q for _q in [d --> [?:Shift]] if _q.position == pj] {
        sh.position = "";
    }
    log_event("Coordinator", f"Removed the {p.name} role", kind="human", employer=d);
    del p;
    return org_view(d);
}

# ------------------------------------------------------------------ team
def member_of(d: Employer, sid: str) -> tuple[Employee, Employment] {
    st = employee_of(sid);
    if st is None {
        raise ApiError("This person isn't on your team.");
    }
    did = jid(d);
    rows = [e for e in [st --> [?:Employment]] if e.employer == did and e.state in ("active", "invited")];
    if not rows {
        raise ApiError("This person isn't on your team.");
    }
    return (st, rows[0]);
}

@guarded
def:protect get_team(week: str = "") -> dict[str, any] {
    d = me_employer();
    wk = week_arg(week) if week else autopilot.planning_week();
    ledger = Ledger(week=wk);
    roles = {jid(p): p for p in positions_sorted(d)};
    did = jid(d);
    rows: list[dict[str, any]] = [];
    now = utcnow();
    for e in [d --> [?:Employment]] {
        if e.state not in ("active", "invited") {
            continue;
        }
        st = employee_of(e.student);
        if st is None {
            continue;
        }
        sid = jid(st);
        active = e.state == "active";
        created = parse_iso(e.created);
        recent = created is not None and (now - created).days < 7;
        rows.append(
            {
                "student_id": sid,
                "name": st.name,
                "email": st.email,
                "kind": st.kind,
                "status": st.status,
                "international": st.is_international(),
                "state": e.state,
                "hours": e.hours,
                "pay_rate": e.pay_rate,
                "positions": [pid for pid in (e.positions or []) if pid in roles],
                "scheduled_with_you": ledger.dept_hours(sid, did) if active else 0,
                "can_still_schedule": ledger.hours_left(sid, did) if active else None,
                "calendar": st.calendar_source in ("google", "ics_url", "demo"),
                "autopilot": st.autopilot,
                "new": active and not (e.positions or []) and bool(roles) and recent
            }
        );
    }
    rows.sort(
        key=lambda (r: dict[str, any]) -> tuple[bool, bool, str] {
            return (r["state"] != "active", not r["new"], r["name"]);
        }
    );
    return {
        "week": wk,
        "people": rows,
        "positions": [{"id": pid, "name": p.name, "color": p.color} for (pid, p) in roles.items()],
        "join_code": d.join_code,
        "kind": d.kind
    };
}

@guarded
def:protect update_member(
    student_id: str = "", hours: any = UNSET, pay_rate: any = UNSET, positions: any = UNSET
) -> dict[str, any] {
    hours = opt(hours);
    pay_rate = opt(pay_rate);
    positions = opt(positions);
    d = me_employer();
    if not student_id {
        raise ApiError("Missing student id.");
    }
    (st, emp) = member_of(d, student_id);
    changed: list[str] = [];
    if hours is not None {
        h = num_arg(hours, 0, 80, "Weekly hours");
        if h is not None {
            emp.hours = int(h);
            changed.append(f"{emp.hours} hrs/week");
        }
    }
    rate = num_arg(pay_rate, 0, 500, "Pay rate");
    if rate is not None {
        emp.pay_rate = round(rate, 2);
        changed.append(f"${emp.pay_rate:.2f}/hr");
    }
    if positions is not None {
        valid = [jid(p) for p in positions_sorted(d)];
        wanted = sorted({str(x) for x in positions});
        if any([x not in valid for x in wanted]) {
            raise ApiError("One of those roles doesn't exist.");
        }
        emp.positions = wanted;
        names = [p.name for p in positions_sorted(d) if jid(p) in wanted];
        changed.append("roles: " + (", ".join(names) if names else "none"));
    }
    if changed {
        to_student(st, f"{d.name} updated your job: {'; '.join(changed)}.", "/s/profile", title="Job updated");
        log_event("Coordinator", f"Updated {st.first_name()}: {'; '.join(changed)}", kind="human", employer=d);
    }
    return {"ok": True};
}

@guarded
def:protect remove_member(student_id: str = "") -> dict[str, any] {
    d = me_employer();
    (st, _emp) = member_of(d, str(student_id or ""));
    released = 0;
    try {
        released = leave_team(st, d, by_employer=True);
    } except JoinError as je {
        raise ApiError(str(je));
    }
    return {"ok": True, "released": released};
}

# ------------------------------------------------------------------ timesheets
def _ts_week(d: Employer, week: str) -> str {
    if week {
        return week_arg(week);
    }
    return current_week(d.timezone);
}

@guarded
def:protect get_timesheets(week: str = "") -> dict[str, any] {
    d = me_employer();
    data = timesheets.employer_week(d, _ts_week(d, week));
    data["current_week"] = current_week(d.timezone);
    return data;
}

@guarded
def:protect resolve_time_entry(entry_id: str = "", accept: bool = False, note: str = "") -> dict[str, any] {
    d = me_employer();
    ent = entry_of(str(entry_id or ""));
    if ent is None {
        raise ApiError("Entry not found.");
    }
    try {
        timesheets.resolve(d, ent, bool(accept), str(note or ""));
    } except timesheets.TimesheetError as te {
        raise ApiError(str(te));
    }
    return {"ok": True, "entry": timesheets.entry_dict(ent)};
}

@guarded
def:protect export_timesheets(week: str = "") -> dict[str, any] {
    d = me_employer();
    wk = _ts_week(d, week);
    safe = "".join([ch if ch.isalnum() else "-" for ch in d.name]).strip("-").lower() or "timesheet";
    return {"filename": f"{safe}-timesheet-{wk}.csv", "csv": timesheets.employer_csv(d, wk)};
}
