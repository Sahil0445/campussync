"""Alert scheduler. Runs inside every autopilot cycle; every alert is sent exactly once (dedupe keys).

Employees get:
  * 24 hours before a shift   "Tomorrow 11 AM-3 PM · Campus Dining"
  * 1 hour before a shift     "Starts in 1 hour"
  * Friday morning (09:00)    "Check and approve this week's reported hours"
  * Friday evening (18:00)    reminder, only if they still haven't approved
A shift created less than 24 h ahead gets the 24 h alert right away (if it's more than an hour off).
"""

import from datetime { timedelta }
import from server.clock { utcnow, today_local, now_local, monday, slot_datetime, to_utc_naive }
import from server.config { TIMESHEET_DAY, TIMESHEET_MORNING, TIMESHEET_EVENING }
import from server.timeutil { fmt_hours }
import from server.notify { to_student }
import from server.timesheets { primary_tz }
import from server.models {
    Employee,
    Shift,
    TimeEntry,
    employers,
    employees,
    employee_of,
    position_of
}

def t12(minutes: int) -> str {
    (h, m) = divmod(minutes, 60);
    suffix = "AM" if h < 12 or h == 24 else "PM";
    hh = h % 12 or 12;
    return f"{hh}:{m:02d} {suffix}" if m else f"{hh} {suffix}";
}

def shift_alerts() -> int {
    now = utcnow();
    this_week = monday(today_local());
    weeks = [(this_week + timedelta(days=7 * i)).isoformat() for i in [-1, 0, 1]];
    sent = 0;
    roles: dict[str, str] = {};
    for dept in employers() {
        for wk in weeks {
            for sh in [_q for _q in [dept --> [?:Shift, week == wk]] if _q.status == "published"] {
                if not sh.student or sh.state not in ("assigned", "pending_swap") {
                    continue;
                }
                start_local = slot_datetime(sh.week, sh.day, sh.start, dept.timezone);
                until = to_utc_naive(start_local) - now;
                if until <= timedelta(0) or until > timedelta(hours=24) {
                    continue;
                }
                st = employee_of(sh.student);
                if st is None {
                    continue;
                }
                if sh.position and sh.position not in roles {
                    p = position_of(sh.position);
                    roles[sh.position] = p.name if p is not None else "";
                }
                role = roles.get(sh.position, "") if sh.position else "";
                what = dept.name + (f" · {role}" if role else "");
                when = f"{t12(sh.start)}–{t12(sh.end)}";
                slot = f"{sh.week}:{sh.day}:{sh.start}:{sh.end}";
                sid = sh.student;
                n: any = None;
                if until <= timedelta(hours=1) {
                    mins = max(1, round(until.total_seconds() / 60));
                    n = to_student(
                        st, f"{what} · {when}. Starts in {mins} min.", "/s",
                        title="Your shift starts soon", kind="shift_1h",
                        dedupe_key=f"s1h:{jid(sh)}:{sid}:{slot}"
                    );
                } else {
                    local_now = now_local(dept.timezone);
                    day_word = start_local.strftime("%A");
                    if start_local.date() == local_now.date() {
                        day_word = "Today";
                    } elif start_local.date() == local_now.date() + timedelta(days=1) {
                        day_word = "Tomorrow";
                    }
                    n = to_student(
                        st, f"{day_word} {when} · {what}.", "/s",
                        title="Shift reminder", kind="shift_24h",
                        dedupe_key=f"s24h:{jid(sh)}:{sid}:{slot}"
                    );
                }
                if n is not None {
                    sent += 1;
                }
            }
        }
    }
    return sent;
}

def timesheet_alerts() -> int {
    sent = 0;
    for st in employees() {
        tzname = primary_tz(st);
        local = now_local(tzname);
        if local.weekday() != TIMESHEET_DAY {
            continue;
        }
        entries = [_q for _q in [st --> [?:TimeEntry]] if _q.status == "reported"];
        if not entries {
            continue;
        }
        minutes = local.hour * 60 + local.minute;
        day = local.date().isoformat();
        hrs = fmt_hours(round(sum([e.hours() for e in entries]), 2));
        sid = jid(st);
        n: any = None;
        if TIMESHEET_MORNING <= minutes and minutes < TIMESHEET_EVENING {
            n = to_student(
                st, f"CampusSync reported {hrs} hrs for you. Check the days you worked and approve.", "/s/time",
                title="Approve your timesheet", kind="timesheet_am", dedupe_key=f"tsam:{sid}:{day}"
            );
        } elif minutes >= TIMESHEET_EVENING {
            n = to_student(
                st, f"You still have {hrs} hrs waiting for your approval. It takes one tap.", "/s/time",
                title="Reminder: timesheet not approved", kind="timesheet_pm", dedupe_key=f"tspm:{sid}:{day}"
            );
        }
        if n is not None {
            sent += 1;
        }
    }
    return sent;
}

def run_alerts() -> int {
    return shift_alerts() + timesheet_alerts();
}
