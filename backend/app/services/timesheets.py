"""Automated time reporting.

When a published shift ends, the hours are reported for the employee automatically — nobody clocks
in. On Friday the employee checks the week and approves it (or flags a line that's wrong). The
employer only handles flagged lines. Over-reporting is blocked in code: an international student can
never end up with more than 20 reported hours in a week, across all employers.
"""
from __future__ import annotations

import csv
import io
from collections import defaultdict
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import clock, config
from ..events import log
from ..models import Department, Employment, Position, Shift, Student, TimeEntry
from ..notify import to_department, to_student
from ..timeutil import DAY_SHORT, fmt_hours, hm
from . import payroll

COUNTED = ("reported", "approved", "disputed")


class TimesheetError(Exception):
    pass


# ------------------------------------------------------------------ helpers
def primary_tz(db: Session, st: Student) -> str:
    emp = db.scalar(select(Employment).where(Employment.student_id == st.id, Employment.state == "active").order_by(Employment.id))
    if emp:
        d = db.get(Department, emp.department_id)
        if d and d.timezone:
            return d.timezone
    return config.TIMEZONE


def entry_label(e: TimeEntry) -> str:
    return f"{DAY_SHORT[e.work_date.weekday()]} {e.work_date:%b} {e.work_date.day} · {hm(e.start)}–{hm(e.end)}"


def _pay_rate(db: Session, sid: int, did: int) -> float:
    emp = db.scalar(select(Employment).where(Employment.student_id == sid, Employment.department_id == did))
    if emp and emp.pay_rate:
        return float(emp.pay_rate)
    d = db.get(Department, did)
    return float(d.default_pay_rate if d else config.DEFAULT_PAY_RATE)


def claimed_hours(e: TimeEntry) -> float:
    """Hours an entry counts for while checking limits: a pending correction counts at its new value."""
    if e.status == "void":
        return 0.0
    if e.status == "disputed":
        if e.proposed_absent:
            return 0.0
        if e.proposed_start is not None and e.proposed_end is not None:
            return max(0, e.proposed_end - e.proposed_start - (e.break_minutes or 0)) / 60
    return e.hours


def week_total(db: Session, sid: int, week: str, exclude: int | None = None) -> float:
    """Hours already committed for the week across ALL employers: reported/claimed entries plus scheduled
    shifts that haven't been reported yet (so claiming extra early can't push the week over later)."""
    rows = db.scalars(select(TimeEntry).where(TimeEntry.student_id == sid, TimeEntry.week == week)).all()
    total = sum(claimed_hours(e) for e in rows if e.id != exclude and e.status in COUNTED)
    reported = {e.shift_id for e in rows if e.shift_id}
    for sh in db.scalars(select(Shift).where(Shift.student_id == sid, Shift.week == week, Shift.status == "published")):
        if sh.id not in reported:
            total += sh.hours
    return total


# ------------------------------------------------------------------ automation
def generate_due(db: Session) -> int:
    """Report every published shift that has ended and isn't reported yet (last 3 weeks)."""
    now = clock.utcnow()
    this_week = clock.monday(clock.today_local())
    weeks = [(this_week - timedelta(days=7 * i)).isoformat() for i in range(0, 3)] + [(this_week + timedelta(days=7)).isoformat()]
    shifts = db.scalars(select(Shift).where(Shift.status == "published", Shift.student_id.is_not(None), Shift.week.in_(weeks),
                                            Shift.state.in_(("assigned", "pending_swap")))).all()
    if not shifts:
        return 0
    done = set(db.scalars(select(TimeEntry.shift_id).where(TimeEntry.shift_id.in_([s.id for s in shifts]))))
    depts: dict[int, Department] = {}
    n = 0
    for sh in shifts:
        if sh.id in done:
            continue
        dept = depts.setdefault(sh.department_id, db.get(Department, sh.department_id))
        end_utc = clock.to_utc_naive(clock.slot_datetime(sh.week, sh.day, sh.end, dept.timezone))
        if end_utc > now:
            continue
        work_date = date.fromisoformat(sh.week) + timedelta(days=sh.day)
        e = TimeEntry(student_id=sh.student_id, department_id=sh.department_id, shift_id=sh.id, position_id=sh.position_id,
                      work_date=work_date, week=sh.week, start=sh.start, end=sh.end, pay_rate=_pay_rate(db, sh.student_id, sh.department_id),
                      status="reported", source="auto")
        db.add(e)
        db.flush()
        log(db, "Time Agent", f"Reported {fmt_hours(e.hours)} hrs for {entry_label(e)} at {dept.name} · confirm it on Friday",
            student_id=sh.student_id, level="done", link="/s/time")
        n += 1
    if n:
        db.commit()
    return n


# ------------------------------------------------------------------ employee actions
def approve(db: Session, st: Student, ids: list[int] | None = None) -> int:
    q = select(TimeEntry).where(TimeEntry.student_id == st.id, TimeEntry.status == "reported")
    if ids:
        q = q.where(TimeEntry.id.in_(ids))
    rows = db.scalars(q).all()
    now = clock.utcnow()
    by_dept: dict[int, float] = defaultdict(float)
    for e in rows:
        e.status, e.approved_at = "approved", now
        by_dept[e.department_id] += e.hours
    for did, hrs in by_dept.items():
        log(db, "Time Agent", f"{st.first_name} approved {fmt_hours(hrs)} reported hrs", department_id=did, kind="human", level="done",
            link="/d/timesheets")
    if rows:
        log(db, "Time Agent", f"You approved {fmt_hours(sum(e.hours for e in rows))} hrs", student_id=st.id, kind="human", level="done")
    db.commit()
    return len(rows)


def propose_correction(db: Session, st: Student, entry: TimeEntry, start: int | None, end: int | None, absent: bool, note: str) -> TimeEntry:
    if entry.student_id != st.id:
        raise TimesheetError("That entry isn't yours.")
    if entry.status not in ("reported", "disputed"):
        raise TimesheetError("This entry is already approved. Ask your manager if something is wrong.")
    note = (note or "").strip()[:300]
    if absent:
        entry.proposed_start = entry.proposed_end = None
        entry.proposed_absent = True
    else:
        if start is None or end is None or not (0 <= start < end <= 24 * 60):
            raise TimesheetError("The end time has to be after the start time.")
        if end - start > 16 * 60:
            raise TimesheetError("A single entry can't be longer than 16 hours.")
        if (start, end) == (entry.start, entry.end):
            raise TimesheetError("That's the same as what was reported — approve it instead.")
        new_hours = max(0, end - start - (entry.break_minutes or 0)) / 60
        if st.is_international:
            other = week_total(db, st.id, entry.week, exclude=entry.id)
            if other + new_hours > st.cap + 1e-9:
                raise TimesheetError(
                    f"That would bring your reported week to {fmt_hours(other + new_hours)} hrs across all jobs. "
                    f"International students can't go over {st.cap} hrs a week — CampusSync blocks it to keep you compliant.")
        entry.proposed_start, entry.proposed_end, entry.proposed_absent = start, end, False
    entry.status, entry.note = "disputed", note
    dept = db.get(Department, entry.department_id)
    what = "says they didn't work it" if absent else f"says {hm(start)}–{hm(end)}"
    to_department(db, dept.id, f"{st.first_name} flagged {entry_label(entry)}: {what}.", f"/d/timesheets?week={entry.week}")
    log(db, "Time Agent", f"{st.first_name} flagged {entry_label(entry)} ({what}) · needs your decision", department_id=dept.id,
        level="action", link=f"/d/timesheets?week={entry.week}")
    db.commit()
    return entry


def resolve(db: Session, dept: Department, entry: TimeEntry, accept: bool, note: str = "") -> TimeEntry:
    if entry.department_id != dept.id:
        raise TimesheetError("Entry not found.")
    if entry.status != "disputed":
        raise TimesheetError("This entry isn't waiting for a decision.")
    st = db.get(Student, entry.student_id)
    label = entry_label(entry)
    if accept:
        if entry.proposed_absent:
            entry.status = "void"
        else:
            new_hours = max(0, entry.proposed_end - entry.proposed_start - (entry.break_minutes or 0)) / 60
            if st.is_international:
                other = week_total(db, st.id, entry.week, exclude=entry.id)
                if other + new_hours > st.cap + 1e-9:
                    raise TimesheetError(f"Accepting would put {st.first_name} over the {st.cap} hr international limit for that week.")
            entry.start, entry.end = entry.proposed_start, entry.proposed_end
            entry.status = "approved"
        msg = f"{dept.name} accepted your correction for {label}."
    else:
        entry.status = "approved"
        msg = f"{dept.name} kept {label} as reported" + (f": {note.strip()[:200]}" if note.strip() else ".")
    entry.approved_at = clock.utcnow()
    entry.employer_note = (note or "").strip()[:300]
    entry.proposed_start = entry.proposed_end = None
    entry.proposed_absent = False
    to_student(db, st.id, msg, "/s/time", title="Timesheet updated")
    db.commit()
    return entry


# ------------------------------------------------------------------ views
def entry_dict(db: Session, e: TimeEntry, roles: dict[int, str] | None = None, depts: dict[int, str] | None = None) -> dict:
    roles = roles if roles is not None else {}
    role = roles.get(e.position_id) if e.position_id else None
    if role is None and e.position_id:
        p = db.get(Position, e.position_id)
        role = p.name if p else ""
    dname = (depts or {}).get(e.department_id) or db.get(Department, e.department_id).name
    return {
        "id": e.id, "date": e.work_date.isoformat(), "day": e.work_date.weekday(), "week": e.week, "label": entry_label(e),
        "start": e.start, "end": e.end, "hours": round(e.hours, 2), "status": e.status, "source": e.source,
        "department_id": e.department_id, "department": dname, "role": role or "",
        "pay_rate": e.pay_rate, "gross": round(e.hours * e.pay_rate, 2),
        "proposed_start": e.proposed_start, "proposed_end": e.proposed_end, "proposed_absent": e.proposed_absent,
        "note": e.note, "employer_note": e.employer_note,
    }


def _week_taxes(db: Session, st: Student, weeks: set[str]) -> dict[str, dict]:
    """Full-week tax estimate per week (all employers), so any slice of a week can be prorated."""
    if not weeks:
        return {}
    rows = db.scalars(select(TimeEntry).where(TimeEntry.student_id == st.id, TimeEntry.week.in_(weeks), TimeEntry.status.in_(COUNTED))).all()
    state_pct = {d.id: d.state_tax_pct for d in db.scalars(select(Department).where(Department.id.in_({e.department_id for e in rows})))} if rows else {}
    by_week: dict[str, dict[float, float]] = defaultdict(lambda: defaultdict(float))
    for e in rows:
        by_week[e.week][float(state_pct.get(e.department_id, 0.0))] += e.hours * e.pay_rate
    fica_exempt = st.is_international
    return {w: payroll.weekly_taxes(dict(g), fica_exempt) for w, g in by_week.items()}


def _prorate(entries: list[TimeEntry], taxes: dict[str, dict]) -> dict:
    out = {"gross": 0.0, "federal": 0.0, "state": 0.0, "fica": 0.0}
    for e in entries:
        g = e.hours * e.pay_rate
        t = taxes.get(e.week)
        out["gross"] += g
        if t and t["gross"]:
            share = g / t["gross"]
            for k in ("federal", "state", "fica"):
                out[k] += t[k] * share
    out = {k: round(v, 2) for k, v in out.items()}
    out["taxes"] = round(out["federal"] + out["state"] + out["fica"], 2)
    out["net"] = round(out["gross"] - out["taxes"], 2)
    return out


def employee_timesheet(db: Session, st: Student) -> dict:
    tzname = primary_tz(db, st)
    today = clock.today_local(tzname)
    since = clock.monday(today) - timedelta(days=21)
    rows = db.scalars(select(TimeEntry).where(TimeEntry.student_id == st.id, TimeEntry.work_date >= since)
                      .order_by(TimeEntry.work_date.desc(), TimeEntry.start.desc())).all()
    roles = {p.id: p.name for p in db.scalars(select(Position).where(Position.id.in_({e.position_id for e in rows if e.position_id})))} if rows else {}
    depts = {d.id: d.name for d in db.scalars(select(Department))}
    weeks: dict[str, list[TimeEntry]] = defaultdict(list)
    for e in rows:
        weeks[e.week].append(e)
    taxes = _week_taxes(db, st, set(weeks))
    week_rows = []
    for w in sorted(weeks, reverse=True):
        es = weeks[w]
        counted = [e for e in es if e.status in COUNTED]
        pay = _prorate(counted, taxes)
        statuses = {e.status for e in es}
        week_rows.append({
            "week": w, "hours": round(sum(e.hours for e in counted), 2), "pay": pay,
            "state": "needs_you" if "reported" in statuses else "waiting" if "disputed" in statuses else "approved",
            "entries": [entry_dict(db, e, roles, depts) for e in sorted(es, key=lambda e: (e.work_date, e.start))],
        })
    pending = [e for e in rows if e.status == "reported"]
    days_to_friday = (config.TIMESHEET_DAY - today.weekday()) % 7
    friday = today + timedelta(days=days_to_friday)
    return {
        "pending_count": len(pending), "pending_hours": round(sum(e.hours for e in pending), 2),
        "disputed_count": sum(1 for e in rows if e.status == "disputed"),
        "next_review": friday.isoformat(), "review_today": days_to_friday == 0,
        "weeks": week_rows, "cap": st.cap, "international": st.is_international,
    }


def employer_week(db: Session, dept: Department, week: str) -> dict:
    rows = db.scalars(select(TimeEntry).where(TimeEntry.department_id == dept.id, TimeEntry.week == week)
                      .order_by(TimeEntry.work_date, TimeEntry.start)).all()
    roles = {p.id: p.name for p in db.scalars(select(Position).where(Position.department_id == dept.id))}
    depts = {dept.id: dept.name}
    people: dict[int, list[TimeEntry]] = defaultdict(list)
    for e in rows:
        people[e.student_id].append(e)
    out = []
    for sid, es in people.items():
        st = db.get(Student, sid)
        counted = [e for e in es if e.status in COUNTED]
        out.append({
            "student_id": sid, "name": st.name, "email": st.email,
            "hours": round(sum(e.hours for e in counted), 2),
            "gross": round(sum(e.hours * e.pay_rate for e in counted), 2),
            "pending": sum(1 for e in es if e.status == "reported"),
            "disputed": sum(1 for e in es if e.status == "disputed"),
            "approved": sum(1 for e in es if e.status == "approved"),
            "entries": [entry_dict(db, e, roles, depts) for e in es],
        })
    out.sort(key=lambda r: (-r["disputed"], r["name"]))
    counted = [e for e in rows if e.status in COUNTED]
    return {
        "week": week, "people": out,
        "totals": {"hours": round(sum(e.hours for e in counted), 2), "cost": round(sum(e.hours * e.pay_rate for e in counted), 2),
                   "pending": sum(1 for e in rows if e.status == "reported"), "disputed": sum(1 for e in rows if e.status == "disputed"),
                   "approved": sum(1 for e in rows if e.status == "approved"), "entries": len(rows)},
    }


def employer_csv(db: Session, dept: Department, week: str) -> str:
    data = employer_week(db, dept, week)
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["Employee", "Email", "Date", "Start", "End", "Hours", "Role", "Rate (USD/hr)", "Gross (USD)", "Status"])
    for p in data["people"]:
        for e in p["entries"]:
            w.writerow([p["name"], p["email"], e["date"], hm(e["start"]), hm(e["end"]), f"{e['hours']:.2f}", e["role"],
                        f"{e['pay_rate']:.2f}", f"{e['gross']:.2f}", e["status"]])
    return buf.getvalue()


# ------------------------------------------------------------------ analytics (employee)
def _add_months(d: date, n: int) -> date:
    y, m = divmod(d.month - 1 + n, 12)
    return date(d.year + y, m + 1, 1)


def analytics(db: Session, st: Student, rng: str, anchor: date | None) -> dict:
    tzname = primary_tz(db, st)
    today = clock.today_local(tzname)
    anchor = anchor or today
    if rng == "year":
        start, end = date(anchor.year, 1, 1), date(anchor.year + 1, 1, 1)
        prev_a, next_a = date(anchor.year - 1, 1, 1), date(anchor.year + 1, 1, 1)
    elif rng == "month":
        start = anchor.replace(day=1)
        end = _add_months(start, 1)
        prev_a, next_a = _add_months(start, -1), end
    else:
        rng = "week"
        start = clock.monday(anchor)
        end = start + timedelta(days=7)
        prev_a, next_a = start - timedelta(days=7), end

    if rng == "year":
        buckets = [{"key": f"{start.year}-{m:02d}", "label": date(start.year, m, 1).strftime("%b"), "sub": ""} for m in range(1, 13)]
        bkey = lambda d: f"{d.year}-{d.month:02d}"  # noqa: E731
    else:
        n = (end - start).days
        buckets = [{"key": (start + timedelta(days=i)).isoformat(),
                    "label": DAY_SHORT[(start + timedelta(days=i)).weekday()] if rng == "week" else str((start + timedelta(days=i)).day),
                    "sub": f"{(start + timedelta(days=i)):%b} {(start + timedelta(days=i)).day}"} for i in range(n)]
        bkey = lambda d: d.isoformat()  # noqa: E731
    index = {b["key"]: i for i, b in enumerate(buckets)}

    rows = db.scalars(select(TimeEntry).where(TimeEntry.student_id == st.id, TimeEntry.work_date >= start, TimeEntry.work_date < end,
                                              TimeEntry.status.in_(COUNTED))).all()
    depts = {d.id: d for d in db.scalars(select(Department))}
    roles = {p.id: p.name for p in db.scalars(select(Position))}
    multi = len({e.department_id for e in rows}) > 1

    def series_key(did: int, pid: int | None) -> str:
        return f"{did}:{pid or 0}"

    def series_label(did: int, pid: int | None) -> str:
        dn = depts[did].name if did in depts else "Job"
        rn = roles.get(pid) if pid else None
        if rn and multi:
            return f"{dn} · {rn}"
        return rn or dn

    series: dict[str, dict] = {}
    taxes = _week_taxes(db, st, {e.week for e in rows})
    for e in rows:
        k = series_key(e.department_id, e.position_id)
        s = series.setdefault(k, {"key": k, "label": series_label(e.department_id, e.position_id), "department": depts[e.department_id].name,
                                  "hours": [0.0] * len(buckets), "gross": [0.0] * len(buckets), "net": [0.0] * len(buckets), "total_hours": 0.0})
        i = index.get(bkey(e.work_date))
        if i is None:
            continue
        g = e.hours * e.pay_rate
        t = taxes.get(e.week)
        rate = t["rate"] if t else 0.0
        s["hours"][i] += e.hours
        s["gross"][i] += g
        s["net"][i] += g * (1 - rate)
        s["total_hours"] += e.hours
    for s in series.values():
        for k in ("hours", "gross", "net"):
            s[k] = [round(v, 2) for v in s[k]]
        s["total_hours"] = round(s["total_hours"], 2)

    # Upcoming shifts in the range that haven't been worked yet (shown as "scheduled").
    scheduled = [0.0] * len(buckets)
    projected = 0.0
    if end > today:
        wk_from = clock.monday(max(start, today)).isoformat()
        wk_to = clock.monday(end - timedelta(days=1)).isoformat()
        shifts = db.scalars(select(Shift).where(Shift.student_id == st.id, Shift.status == "published",
                                                Shift.week >= wk_from, Shift.week <= wk_to)).all()
        reported = set(db.scalars(select(TimeEntry.shift_id).where(TimeEntry.student_id == st.id, TimeEntry.shift_id.is_not(None))))
        for sh in shifts:
            d = date.fromisoformat(sh.week) + timedelta(days=sh.day)
            if sh.id in reported or not (start <= d < end) or d < today:
                continue
            i = index.get(bkey(d))
            if i is None:
                continue
            scheduled[i] += sh.hours
            projected += sh.hours * _pay_rate(db, st.id, sh.department_id)
    months_with_data = {(e.work_date.year, e.work_date.month) for e in db.scalars(select(TimeEntry).where(
        TimeEntry.student_id == st.id, TimeEntry.status.in_(COUNTED)))}
    earliest = db.scalar(select(TimeEntry.work_date).where(TimeEntry.student_id == st.id).order_by(TimeEntry.work_date).limit(1))
    pay = _prorate(rows, taxes)
    return {
        "range": rng, "start": start.isoformat(), "end": (end - timedelta(days=1)).isoformat(),
        "title": (f"{start:%b} {start.day} – {(end - timedelta(days=1)):%b} {(end - timedelta(days=1)).day}" if rng == "week"
                  else f"{start:%B %Y}" if rng == "month" else str(start.year)),
        "prev": prev_a.isoformat() if earliest and prev_a >= clock.monday(earliest) - timedelta(days=366) else None,
        "next": next_a.isoformat() if next_a <= today + timedelta(days=21) else None,
        "buckets": buckets, "series": sorted(series.values(), key=lambda s: -s["total_hours"]),
        "scheduled": [round(v, 2) for v in scheduled],
        "totals": {"hours": round(sum(e.hours for e in rows), 2), "pending_hours": round(sum(e.hours for e in rows if e.status != "approved"), 2),
                   "scheduled_hours": round(sum(scheduled), 2), "projected_gross": round(projected, 2), **pay},
        "fica_exempt": st.is_international,
        "has_year": len(months_with_data) >= 2,
        "today": today.isoformat(),
    }
