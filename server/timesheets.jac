"""Automated time reporting.

When a published shift ends, the hours are reported for the employee automatically -- nobody clocks
in. On Friday the employee checks the week and approves it (or flags a line that's wrong). The
employer only handles flagged lines. Over-reporting is blocked in code: an international student can
never end up with more than 20 reported hours in a week, across all employers.
"""

import csv;
import io;
import from datetime { date, timedelta }
import from server.clock {
    utcnow,
    now_s,
    today_local,
    monday,
    slot_datetime,
    to_utc_naive
}
import from server.config { TIMEZONE, TIMESHEET_DAY, DEFAULT_PAY_RATE }
import from server.timeutil { DAY_SHORT, fmt_hours, hm }
import from server.notify { log_event, to_student, to_employer }
import from server.payroll { weekly_taxes }
import from server.models {
    Employer,
    Employee,
    Employment,
    Shift,
    TimeEntry,
    put,
    also,
    employers,
    employer_of,
    employee_of,
    position_of
}

glob COUNTED: list[str] = ["reported", "approved", "disputed"];

class TimesheetError(Exception) {}

# ------------------------------------------------------------------ helpers
def primary_tz(st: Employee) -> str {
    rows = sorted(
        [e for e in [st --> [?:Employment]] if e.state == "active"],
        key=lambda (e: Employment) -> str { return e.created; }
    );
    if rows {
        d = employer_of(rows[0].employer);
        if d is not None and d.timezone {
            return d.timezone;
        }
    }
    return TIMEZONE;
}

def _d(e: TimeEntry) -> date {
    return date.fromisoformat(e.work_date);
}

def entry_label(e: TimeEntry) -> str {
    wd = _d(e);
    return f"{DAY_SHORT[wd.weekday()]} {wd.strftime('%b')} {wd.day} · {hm(e.start)}–{hm(e.end)}";
}

def _pay_rate(st: Employee, did: str) -> float {
    rows = [x for x in [st --> [?:Employment]] if x.employer == did];
    if rows and rows[0].pay_rate {
        return float(rows[0].pay_rate);
    }
    d = employer_of(did);
    return float(d.default_pay_rate if d is not None else DEFAULT_PAY_RATE);
}

"""Hours an entry counts for while checking limits: a pending correction counts at its new value."""
def claimed_hours(e: TimeEntry) -> float {
    if e.status == "void" {
        return 0.0;
    }
    if e.status == "disputed" {
        if e.proposed_absent {
            return 0.0;
        }
        if e.proposed_start is not None and e.proposed_end is not None {
            return max(0, e.proposed_end - e.proposed_start - (e.break_minutes or 0)) / 60;
        }
    }
    return e.hours();
}

"""Hours already committed for the week across ALL employers: reported/claimed entries plus scheduled
shifts that haven't been reported yet (so claiming extra early can't push the week over later)."""
def week_total(st: Employee, week: str, exclude: str = "") -> float {
    wk = week;
    rows = [st --> [?:TimeEntry, week == wk]];
    total = sum([claimed_hours(e) for e in rows if jid(e) != exclude and e.status in COUNTED]);
    reported = {e.shift for e in rows if e.shift};
    sid = jid(st);
    for sh in [_q for _q in [st --> [?:Shift, week == wk]] if _q.status == "published"] {
        if sh.student == sid and jid(sh) not in reported {
            total += sh.hours();
        }
    }
    return total;
}

# ------------------------------------------------------------------ automation
"""Report every published shift that has ended and isn't reported yet (last 3 weeks)."""
def generate_due() -> int {
    now = utcnow();
    this_week = monday(today_local());
    weeks = [(this_week - timedelta(days=7 * i)).isoformat() for i in range(0, 3)]
        + [(this_week + timedelta(days=7)).isoformat()];
    n = 0;
    for dept in employers() {
        for wk in weeks {
            shifts = [
                s for s in [_q for _q in [dept --> [?:Shift, week == wk]] if _q.status == "published"]
                if s.student and s.state in ("assigned", "pending_swap")
            ];
            if not shifts {
                continue;
            }
            done = {e.shift for e in [dept --> [?:TimeEntry, week == wk]]};
            for sh in sorted(shifts, key=lambda (s: Shift) -> str { return s.created; }) {
                if jid(sh) in done {
                    continue;
                }
                end_utc = to_utc_naive(slot_datetime(sh.week, sh.day, sh.end, dept.timezone));
                if end_utc > now {
                    continue;
                }
                st = employee_of(sh.student);
                if st is None {
                    continue;
                }
                work_date = date.fromisoformat(sh.week) + timedelta(days=sh.day);
                e = TimeEntry(
                    student=sh.student,
                    employer=sh.employer,
                    shift=jid(sh),
                    position=sh.position,
                    work_date=work_date.isoformat(),
                    week=sh.week,
                    start=sh.start,
                    end=sh.end,
                    pay_rate=_pay_rate(st, sh.employer),
                    status="reported",
                    source="auto",
                    created=now_s()
                );
                put(st, e);
                also(dept, e);
                log_event(
                    "Time Agent",
                    f"Reported {fmt_hours(e.hours())} hrs for {entry_label(e)} at {dept.name} · confirm it on Friday",
                    student=st,
                    level="done",
                    link="/s/time"
                );
                n += 1;
            }
        }
    }
    return n;
}

# ------------------------------------------------------------------ employee actions
def approve(st: Employee, ids: list[str] | None = None) -> int {
    rows = [e for e in [_q for _q in [st --> [?:TimeEntry]] if _q.status == "reported"] if not ids or jid(e) in ids];
    now = now_s();
    by_dept: dict[str, float] = {};
    order: list[str] = [];
    for e in rows {
        e.status = "approved";
        e.approved_at = now;
        if e.employer not in by_dept {
            by_dept[e.employer] = 0.0;
            order.append(e.employer);
        }
        by_dept[e.employer] = by_dept[e.employer] + e.hours();
    }
    for did in order {
        log_event(
            "Time Agent",
            f"{st.first_name()} approved {fmt_hours(by_dept[did])} reported hrs",
            employer=employer_of(did),
            kind="human",
            level="done",
            link="/d/timesheets"
        );
    }
    if rows {
        log_event(
            "Time Agent",
            f"You approved {fmt_hours(sum([e.hours() for e in rows]))} hrs",
            student=st,
            kind="human",
            level="done"
        );
    }
    return len(rows);
}

def propose_correction(
    st: Employee, ent: TimeEntry, start: int | None, end: int | None, absent: bool, note: str
) -> TimeEntry {
    if ent.student != jid(st) {
        raise TimesheetError("That entry isn't yours.");
    }
    if ent.status not in ("reported", "disputed") {
        raise TimesheetError("This entry is already approved. Ask your manager if something is wrong.");
    }
    clean_note = (note or "").strip()[:300];
    what = "";
    if absent {
        ent.proposed_start = None;
        ent.proposed_end = None;
        ent.proposed_absent = True;
        what = "says they didn't work it";
    } else {
        if start is None or end is None or not (0 <= start and start < end and end <= 24 * 60) {
            raise TimesheetError("The end time has to be after the start time.");
        }
        s: int = start;
        en: int = end;
        if en - s > 16 * 60 {
            raise TimesheetError("A single entry can't be longer than 16 hours.");
        }
        if s == ent.start and en == ent.end {
            raise TimesheetError("That's the same as what was reported — approve it instead.");
        }
        new_hours = max(0, en - s - (ent.break_minutes or 0)) / 60;
        if st.is_international() {
            other = week_total(st, ent.week, exclude=jid(ent));
            if other + new_hours > st.cap() + 1e-9 {
                raise TimesheetError(
                    f"That would bring your reported week to {fmt_hours(other + new_hours)} hrs across all jobs. "
                    + f"International students can't go over {st.cap()} hrs a week — CampusSync blocks it to keep you compliant."
                );
            }
        }
        ent.proposed_start = s;
        ent.proposed_end = en;
        ent.proposed_absent = False;
        what = f"says {hm(s)}–{hm(en)}";
    }
    ent.status = "disputed";
    ent.note = clean_note;
    dept = employer_of(ent.employer);
    if dept is not None {
        to_employer(
            dept,
            f"{st.first_name()} flagged {entry_label(ent)}: {what}.",
            f"/d/timesheets?week={ent.week}"
        );
        log_event(
            "Time Agent",
            f"{st.first_name()} flagged {entry_label(ent)} ({what}) · needs your decision",
            employer=dept,
            level="action",
            link=f"/d/timesheets?week={ent.week}"
        );
    }
    return ent;
}

def resolve(dept: Employer, ent: TimeEntry, accept: bool, note: str = "") -> TimeEntry {
    if ent.employer != jid(dept) {
        raise TimesheetError("Entry not found.");
    }
    if ent.status != "disputed" {
        raise TimesheetError("This entry isn't waiting for a decision.");
    }
    st = employee_of(ent.student);
    if st is None {
        raise TimesheetError("Entry not found.");
    }
    label = entry_label(ent);
    msg = "";
    if accept {
        if ent.proposed_absent {
            ent.status = "void";
        } else {
            ps = ent.proposed_start or 0;
            pe = ent.proposed_end or 0;
            new_hours = max(0, pe - ps - (ent.break_minutes or 0)) / 60;
            if st.is_international() {
                other = week_total(st, ent.week, exclude=jid(ent));
                if other + new_hours > st.cap() + 1e-9 {
                    raise TimesheetError(
                        f"Accepting would put {st.first_name()} over the {st.cap()} hr international limit for that week."
                    );
                }
            }
            ent.start = ps;
            ent.end = pe;
            ent.status = "approved";
        }
        msg = f"{dept.name} accepted your correction for {label}.";
    } else {
        ent.status = "approved";
        msg = f"{dept.name} kept {label} as reported" + (f": {note.strip()[:200]}" if note.strip() else ".");
    }
    ent.approved_at = now_s();
    ent.employer_note = (note or "").strip()[:300];
    ent.proposed_start = None;
    ent.proposed_end = None;
    ent.proposed_absent = False;
    to_student(st, msg, "/s/time", title="Timesheet updated");
    return ent;
}

# ------------------------------------------------------------------ views
def _role_name(pid: str, cache: dict[str, str]) -> str {
    if not pid {
        return "";
    }
    if pid not in cache {
        p = position_of(pid);
        cache[pid] = p.name if p is not None else "";
    }
    return cache[pid];
}

def _dept_name(did: str, cache: dict[str, str]) -> str {
    if did not in cache {
        d = employer_of(did);
        cache[did] = d.name if d is not None else "Job";
    }
    return cache[did];
}

def entry_dict(e: TimeEntry, roles: dict[str, str] | None = None, depts: dict[str, str] | None = None) -> dict[str, any] {
    rc: dict[str, str] = roles if roles is not None else {};
    dc: dict[str, str] = depts if depts is not None else {};
    wd = _d(e);
    return {
        "id": jid(e),
        "date": e.work_date,
        "day": wd.weekday(),
        "week": e.week,
        "label": entry_label(e),
        "start": e.start,
        "end": e.end,
        "hours": round(e.hours(), 2),
        "status": e.status,
        "source": e.source,
        "department_id": e.employer,
        "department": _dept_name(e.employer, dc),
        "role": _role_name(e.position, rc),
        "pay_rate": e.pay_rate,
        "gross": round(e.hours() * e.pay_rate, 2),
        "proposed_start": e.proposed_start,
        "proposed_end": e.proposed_end,
        "proposed_absent": e.proposed_absent,
        "note": e.note,
        "employer_note": e.employer_note
    };
}

"""Full-week tax estimate per week (all employers), so any slice of a week can be prorated."""
def _week_taxes(st: Employee, weeks: set[str]) -> dict[str, dict[str, float]] {
    if not weeks {
        return {};
    }
    rows = [e for e in [st --> [?:TimeEntry]] if e.week in weeks and e.status in COUNTED];
    pct: dict[str, float] = {};
    by_week: dict[str, dict[float, float]] = {};
    for e in rows {
        if e.employer not in pct {
            d = employer_of(e.employer);
            pct[e.employer] = float(d.state_tax_pct) if d is not None else 0.0;
        }
        rate = pct[e.employer];
        wkmap = by_week.setdefault(e.week, {});
        wkmap[rate] = wkmap.get(rate, 0.0) + e.hours() * e.pay_rate;
    }
    fica_exempt = st.is_international();
    return {w: weekly_taxes(g, fica_exempt) for (w, g) in by_week.items()};
}

def _prorate(entries: list[TimeEntry], taxes: dict[str, dict[str, float]]) -> dict[str, float] {
    out: dict[str, float] = {"gross": 0.0, "federal": 0.0, "state": 0.0, "fica": 0.0};
    for e in entries {
        g = e.hours() * e.pay_rate;
        t = taxes.get(e.week);
        out["gross"] += g;
        if t and t["gross"] {
            share = g / t["gross"];
            for k in ["federal", "state", "fica"] {
                out[k] += t[k] * share;
            }
        }
    }
    res: dict[str, float] = {k: round(v, 2) for (k, v) in out.items()};
    res["taxes"] = round(res["federal"] + res["state"] + res["fica"], 2);
    res["net"] = round(res["gross"] - res["taxes"], 2);
    return res;
}

def _entry_sort(e: TimeEntry) -> tuple[str, int] {
    return (e.work_date, e.start);
}

def employee_timesheet(st: Employee) -> dict[str, any] {
    tzname = primary_tz(st);
    today = today_local(tzname);
    since = (monday(today) - timedelta(days=21)).isoformat();
    rows = sorted(
        [e for e in [st --> [?:TimeEntry]] if e.work_date >= since],
        key=_entry_sort,
        reverse=True
    );
    roles: dict[str, str] = {};
    depts: dict[str, str] = {};
    weeks: dict[str, list[TimeEntry]] = {};
    for e in rows {
        weeks.setdefault(e.week, []).append(e);
    }
    taxes = _week_taxes(st, set(weeks.keys()));
    week_rows: list[dict[str, any]] = [];
    for w in sorted(weeks.keys(), reverse=True) {
        es = weeks[w];
        counted = [e for e in es if e.status in COUNTED];
        pay = _prorate(counted, taxes);
        statuses = {e.status for e in es};
        state = "needs_you" if "reported" in statuses else ("waiting" if "disputed" in statuses else "approved");
        week_rows.append(
            {
                "week": w,
                "hours": round(sum([e.hours() for e in counted]), 2),
                "pay": pay,
                "state": state,
                "entries": [entry_dict(e, roles, depts) for e in sorted(es, key=_entry_sort)]
            }
        );
    }
    pending = [e for e in rows if e.status == "reported"];
    days_to_friday = (TIMESHEET_DAY - today.weekday()) % 7;
    friday = today + timedelta(days=days_to_friday);
    return {
        "pending_count": len(pending),
        "pending_hours": round(sum([e.hours() for e in pending]), 2),
        "disputed_count": len([e for e in rows if e.status == "disputed"]),
        "next_review": friday.isoformat(),
        "review_today": days_to_friday == 0,
        "weeks": week_rows,
        "cap": st.cap(),
        "international": st.is_international()
    };
}

def employer_week(dept: Employer, week: str) -> dict[str, any] {
    wk = week;
    rows = sorted(list([dept --> [?:TimeEntry, week == wk]]), key=_entry_sort);
    roles: dict[str, str] = {};
    depts: dict[str, str] = {jid(dept): dept.name};
    people: dict[str, list[TimeEntry]] = {};
    for e in rows {
        people.setdefault(e.student, []).append(e);
    }
    out: list[dict[str, any]] = [];
    for (sid, es) in people.items() {
        st = employee_of(sid);
        counted = [e for e in es if e.status in COUNTED];
        out.append(
            {
                "student_id": sid,
                "name": st.name if st is not None else "",
                "email": st.email if st is not None else "",
                "hours": round(sum([e.hours() for e in counted]), 2),
                "gross": round(sum([e.hours() * e.pay_rate for e in counted]), 2),
                "pending": len([e for e in es if e.status == "reported"]),
                "disputed": len([e for e in es if e.status == "disputed"]),
                "approved": len([e for e in es if e.status == "approved"]),
                "entries": [entry_dict(e, roles, depts) for e in es]
            }
        );
    }
    out.sort(key=lambda (r: dict[str, any]) -> tuple[int, str] { return (-r["disputed"], r["name"]); });
    counted = [e for e in rows if e.status in COUNTED];
    return {
        "week": week,
        "people": out,
        "totals": {
            "hours": round(sum([e.hours() for e in counted]), 2),
            "cost": round(sum([e.hours() * e.pay_rate for e in counted]), 2),
            "pending": len([e for e in rows if e.status == "reported"]),
            "disputed": len([e for e in rows if e.status == "disputed"]),
            "approved": len([e for e in rows if e.status == "approved"]),
            "entries": len(rows)
        }
    };
}

def employer_csv(dept: Employer, week: str) -> str {
    data = employer_week(dept, week);
    buf = io.StringIO();
    w = csv.writer(buf);
    w.writerow(["Employee", "Email", "Date", "Start", "End", "Hours", "Role", "Rate (USD/hr)", "Gross (USD)", "Status"]);
    for p in data["people"] {
        for e in p["entries"] {
            w.writerow(
                [
                    p["name"], p["email"], e["date"], hm(e["start"]), hm(e["end"]), f"{e['hours']:.2f}",
                    e["role"], f"{e['pay_rate']:.2f}", f"{e['gross']:.2f}", e["status"]
                ]
            );
        }
    }
    return buf.getvalue();
}

# ------------------------------------------------------------------ analytics (employee)
def _add_months(d: date, n: int) -> date {
    (y, m) = divmod(d.month - 1 + n, 12);
    return date(d.year + y, m + 1, 1);
}

def _bkey(rng: str, d: date) -> str {
    if rng == "year" {
        return f"{d.year}-{d.month:02d}";
    }
    return d.isoformat();
}

def analytics(st: Employee, rng: str, anchor_in: date | None) -> dict[str, any] {
    tzname = primary_tz(st);
    today = today_local(tzname);
    anchor: date = anchor_in if anchor_in is not None else today;
    start = today;
    end = today;
    prev_a = today;
    next_a = today;
    if rng == "year" {
        start = date(anchor.year, 1, 1);
        end = date(anchor.year + 1, 1, 1);
        prev_a = date(anchor.year - 1, 1, 1);
        next_a = date(anchor.year + 1, 1, 1);
    } elif rng == "month" {
        start = anchor.replace(day=1);
        end = _add_months(start, 1);
        prev_a = _add_months(start, -1);
        next_a = end;
    } else {
        rng = "week";
        start = monday(anchor);
        end = start + timedelta(days=7);
        prev_a = start - timedelta(days=7);
        next_a = end;
    }
    buckets: list[dict[str, str]] = [];
    if rng == "year" {
        for m in range(1, 13) {
            buckets.append({"key": f"{start.year}-{m:02d}", "label": date(start.year, m, 1).strftime("%b"), "sub": ""});
        }
    } else {
        n = (end - start).days;
        for i in range(n) {
            d = start + timedelta(days=i);
            buckets.append(
                {
                    "key": d.isoformat(),
                    "label": DAY_SHORT[d.weekday()] if rng == "week" else str(d.day),
                    "sub": f"{d.strftime('%b')} {d.day}"
                }
            );
        }
    }
    index: dict[str, int] = {};
    for (i, b) in enumerate(buckets) {
        index[b["key"]] = i;
    }
    s_iso = start.isoformat();
    e_iso = end.isoformat();
    all_rows = [e for e in [st --> [?:TimeEntry]]];
    rows = sorted(
        [e for e in all_rows if s_iso <= e.work_date and e.work_date < e_iso and e.status in COUNTED],
        key=lambda (e: TimeEntry) -> str { return e.created; }
    );
    depts: dict[str, str] = {};
    roles: dict[str, str] = {};
    multi = len({e.employer for e in rows}) > 1;
    series: dict[str, dict[str, any]] = {};
    taxes = _week_taxes(st, {e.week for e in rows});
    nb = len(buckets);
    for e in rows {
        k = f"{e.employer}:{e.position or 0}";
        if k not in series {
            dn = _dept_name(e.employer, depts);
            rn = _role_name(e.position, roles);
            label = (f"{dn} · {rn}" if rn and multi else (rn or dn));
            series[k] = {
                "key": k,
                "label": label,
                "department": dn,
                "hours": [0.0] * nb,
                "gross": [0.0] * nb,
                "net": [0.0] * nb,
                "total_hours": 0.0
            };
        }
        s = series[k];
        i = index.get(_bkey(rng, _d(e)));
        if i is None {
            continue;
        }
        g = e.hours() * e.pay_rate;
        t = taxes.get(e.week);
        rate = t["rate"] if t else 0.0;
        s["hours"][i] += e.hours();
        s["gross"][i] += g;
        s["net"][i] += g * (1 - rate);
        s["total_hours"] += e.hours();
    }
    for s in series.values() {
        for k in ["hours", "gross", "net"] {
            s[k] = [round(v, 2) for v in s[k]];
        }
        s["total_hours"] = round(s["total_hours"], 2);
    }
    # Upcoming shifts in the range that haven't been worked yet (shown as "scheduled").
    scheduled = [0.0] * nb;
    projected = 0.0;
    if end > today {
        wk_from = monday(max(start, today)).isoformat();
        wk_to = monday(end - timedelta(days=1)).isoformat();
        sid = jid(st);
        reported = {e.shift for e in all_rows if e.shift};
        for sh in [_q for _q in [st --> [?:Shift]] if _q.status == "published"] {
            if sh.student != sid or sh.week < wk_from or sh.week > wk_to {
                continue;
            }
            d = date.fromisoformat(sh.week) + timedelta(days=sh.day);
            if jid(sh) in reported or not (start <= d and d < end) or d < today {
                continue;
            }
            i = index.get(_bkey(rng, d));
            if i is None {
                continue;
            }
            scheduled[i] += sh.hours();
            projected += sh.hours() * _pay_rate(st, sh.employer);
        }
    }
    months_with_data = {e.work_date[:7] for e in all_rows if e.status in COUNTED};
    earliest = min([e.work_date for e in all_rows]) if all_rows else "";
    pay = _prorate(rows, taxes);
    last = end - timedelta(days=1);
    title = "";
    if rng == "week" {
        title = f"{start.strftime('%b')} {start.day} – {last.strftime('%b')} {last.day}";
    } elif rng == "month" {
        title = start.strftime("%B %Y");
    } else {
        title = str(start.year);
    }
    prev_ok = bool(earliest) and prev_a >= monday(date.fromisoformat(earliest)) - timedelta(days=366);
    totals: dict[str, any] = {
        "hours": round(sum([e.hours() for e in rows]), 2),
        "pending_hours": round(sum([e.hours() for e in rows if e.status != "approved"]), 2),
        "scheduled_hours": round(sum(scheduled), 2),
        "projected_gross": round(projected, 2)
    };
    for (k, v) in pay.items() {
        totals[k] = v;
    }
    return {
        "range": rng,
        "start": start.isoformat(),
        "end": last.isoformat(),
        "title": title,
        "prev": prev_a.isoformat() if prev_ok else None,
        "next": next_a.isoformat() if next_a <= today + timedelta(days=21) else None,
        "buckets": buckets,
        "series": sorted(
            list(series.values()),
            key=lambda (s: dict[str, any]) -> float { return -s["total_hours"]; }
        ),
        "scheduled": [round(v, 2) for v in scheduled],
        "totals": totals,
        "fica_exempt": st.is_international(),
        "has_year": len(months_with_data) >= 2,
        "today": today.isoformat()
    };
}
