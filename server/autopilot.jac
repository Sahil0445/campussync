"""Autopilot -- the loop that runs the operation so people don't have to.

Every cycle (15 s, a Jac scheduled task running as the system user):
  1. expire stale swap offers                       (Commit Service)
  2. sync connected calendars, catch new clashes    (Availability Agent -> Swap Agent)
  3. draft the upcoming week when slots are open    (Scheduling Agent)       -> manager approves
  4. recruit from campus for slots the team can't   (Recruiting Agent)       -> manager approves
  5. accept invites that fit an employee's limits   (employee autopilot)
  6. hand open shifts to eligible employees         (employee autopilot)
  7. report hours for shifts that just ended        (Time Agent)             -> employee approves Friday
  8. shift reminders + Friday timesheet alerts      (Notifier)               -> phone push
Humans only approve. Every hard rule is still checked in code at every step.
"""

import logging;
import traceback;
import httpx;
import from datetime { datetime, timedelta }
import from server.clock { utcnow, iso, today_local }
import from server.config { DEFAULT_WEEK, KEEPALIVE_URL, AUTOPILOT_SECONDS }
import from server.timeutil { monday_of, slot_label }
import from server.rules { Ledger }
import from server.notify { log_event, to_student, to_employer }
import from server.models {
    Employer,
    Employee,
    Employment,
    Requirement,
    Draft,
    Shift,
    hub,
    employers,
    employee_of,
    set_holder
}
import from server.scheduling { team_of, fillable_seats, generate }
import from server.membership { can_join }
import server.recruiting as recruiting;
import server.swaps as swaps;
import server.calendar as calendar;
import server.timesheets as timesheets;
import server.alerts as alerts;
import server.push as push;

glob log = logging.getLogger("campussync.autopilot"),
     last_run: str = "",
     last_stats: dict[str, int] = {};

def planning_week() -> str {
    upcoming = monday_of(today_local()) + timedelta(days=7);
    return max(upcoming, DEFAULT_WEEK).isoformat();
}

def _maybe_draft(dept: Employer, week: str) -> bool {
    wk = week;
    drafts = [dept --> [?:Draft, week == wk]];
    if any([d.state == "draft" for d in drafts]) {
        return False;
    }
    recent_cut = iso(utcnow() - timedelta(minutes=30));
    if any([d.state == "discarded" and d.created > recent_cut for d in drafts]) {
        return False;  # the manager just said no -- don't nag
    }
    (_open, fillable) = fillable_seats(dept, week);
    if not fillable {
        return False;
    }
    generate(dept, week, origin="autopilot");
    to_employer(dept, "Autopilot drafted next week's schedule. Review and approve.", "/d/approvals");
    return True;
}

def _accept_invites() -> int {
    n = 0;
    for dept in employers() {
        for emp in [_q for _q in [dept --> [?:Employment]] if _q.state == "invited"] {
            st = employee_of(emp.student);
            if st is None or not st.autopilot {
                continue;
            }
            if can_join(st, dept, ignore_invite=jid(emp)) is not None {
                continue;  # the rules say no (e.g. a regular employee already has an employer)
            }
            assigned = sum([e.hours for e in [_q for _q in [st --> [?:Employment]] if _q.state == "active"]]);
            if assigned + emp.hours > st.cap() {
                continue;
            }
            emp.state = "active";
            log_event(
                "Autopilot",
                f"Accepted {dept.name}'s invite for you · {emp.hours} hrs/week fits your limits",
                student=st,
                level="done"
            );
            log_event(
                "Autopilot", f"{st.first_name()} accepted your invite ({emp.hours} hrs/week)", employer=dept, level="done"
            );
            recruiting.on_invite_answer(st, dept, True);
            n += 1;
        }
    }
    return n;
}

def _fill_open_shifts() -> int {
    n = 0;
    this_week = monday_of(today_local());
    weeks = [(this_week + timedelta(days=7 * i)).isoformat() for i in range(-1, 4)];
    for dept in employers() {
        found: list[Shift] = [];
        for wk in weeks {
            found = found + [
                s for s in [dept --> [?:Shift, week == wk]]
                if s.state == "open" and s.status == "published" and not s.student
            ];
        }
        opens = sorted(found, key=lambda (s: Shift) -> str { return s.created; });
        if not opens {
            continue;
        }
        team = team_of(dept);
        did = jid(dept);
        for sh in opens {
            ledger = Ledger(week=sh.week);
            best: Employee | None = None;
            best_spare = -1.0;
            for st in team {
                sid = jid(st);
                if not st.autopilot or not ledger.check(sid, did, sh.day, sh.start, sh.end, pid=sh.position).ok {
                    continue;
                }
                spare = ledger.hours_left(sid, did);
                if best is None or spare > best_spare {
                    best = st;
                    best_spare = spare;
                }
            }
            if best is not None {
                pick: Employee = best;
                set_holder(sh, jid(pick));
                sh.state = "assigned";
                label = slot_label(sh.day, sh.start, sh.end);
                log_event("Autopilot", f"Picked up the open shift {label} for you — it fits your hours", student=pick, level="done");
                log_event("Autopilot", f"{pick.first_name()} picked up the open shift {label}", employer=dept, level="done");
                to_student(pick, f"Autopilot picked up {label} for you.", "/s");
                n += 1;
            }
        }
    }
    return n;
}

def _stage(name: str, fn: any) -> int {
    try {
        out = fn();
        return int(out or 0);
    } except Exception as ex {
        log.error("autopilot stage failed: %s: %s\n%s", name, str(ex), traceback.format_exc());
        return 0;
    }
}

def _sweep_all() -> int {
    for dept in employers() {
        swaps.sweep_employer(dept);
    }
    return 0;
}

def _plan_all() -> dict[str, int] {
    out: dict[str, int] = {"drafts": 0, "recruits": 0};
    week = planning_week();
    for dept in employers() {
        if not [dept --> [?:Requirement]] {
            continue;
        }
        if dept.auto_generate and _maybe_draft(dept, week) {
            out["drafts"] += 1;
        }
        if dept.auto_recruit {
            out["recruits"] += len(recruiting.recruit(dept, week));
        }
    }
    return out;
}

"""One autopilot cycle. Safe to call any time (endpoints call it so answers are instant)."""
def tick() -> dict[str, int] {
    stats: dict[str, int] = {
        "synced": 0, "drafts": 0, "recruits": 0, "invites": 0, "open_filled": 0, "reported": 0, "alerts": 0, "pushed": 0
    };
    hub();
    _stage("results", lambda { push.apply_results(); return 0; });
    _stage("sweep", _sweep_all);
    stats["synced"] = _stage("calendar sync", calendar.sync_due);
    try {
        planned = _plan_all();
        stats["drafts"] = planned["drafts"];
        stats["recruits"] = planned["recruits"];
    } except Exception as ex {
        log.error("autopilot stage failed: plan: %s\n%s", str(ex), traceback.format_exc());
    }
    stats["invites"] = _stage("invites", _accept_invites);
    stats["open_filled"] = _stage("open shifts", _fill_open_shifts);
    stats["reported"] = _stage("time reporting", timesheets.generate_due);
    stats["alerts"] = _stage("alerts", alerts.run_alerts);
    stats["pushed"] = _stage("push", lambda { return push.deliver_pending(); });
    last_run = iso(utcnow()) + "Z";
    last_stats = stats;
    return stats;
}

def last_run_iso() -> str {
    return last_run;
}

@schedule(trigger=ScheduleTrigger.STATIC, interval=15)
def:priv autopilot_cycle {
    import from server.seed { ensure_seeded }
    ensure_seeded();
    if AUTOPILOT_SECONDS <= 0 {
        return;  # tests drive the cycle themselves (demo_tick)
    }
    tick();
}

@schedule(trigger=ScheduleTrigger.STATIC, interval=600)
def:priv keepalive {
    if not KEEPALIVE_URL {
        return;
    }
    try {
        httpx.get(KEEPALIVE_URL.rstrip("/") + "/healthz", timeout=20);
    } except Exception as ex {
        log.warning("keep-alive ping failed: %s", str(ex));
    }
}
