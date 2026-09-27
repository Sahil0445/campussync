"""Employee endpoints for time reporting and pay analytics -- and push subscriptions (both roles)."""

import from datetime { date }
import from server.clock { utcnow, now_s, today_local, monday, slot_datetime, to_utc_naive }
import from server.notify { to_student, to_employer }
import from server.alerts { t12 }
import from server.models {
    Account,
    Employee,
    Employer,
    PushSub,
    Shift,
    put,
    entry_of,
    employer_of
}
import from server.api_common { UNSET, opt, ApiError, guarded, me, me_student, me_employer }
import server.timesheets as timesheets;
import server.push as push;

@guarded
def:protect get_timesheet() -> dict[str, any] {
    return timesheets.employee_timesheet(me_student());
}

@guarded
def:protect approve_time(entry_ids: any = UNSET) -> dict[str, any] {
    entry_ids = opt(entry_ids);
    st = me_student();
    ids: list[str] | None = [str(x) for x in entry_ids] if entry_ids is not None else None;
    n = timesheets.approve(st, ids if ids else None);
    out = timesheets.employee_timesheet(st);
    out["approved"] = n;
    return out;
}

def _minutes(v: any) -> int | None {
    if v is None or v == "" {
        return None;
    }
    try {
        if isinstance(v, str) and ":" in v {
            parts = v.split(":");
            return int(parts[0]) * 60 + int(parts[1]);
        }
        return int(v);
    } except Exception {
        raise ApiError("That time isn't valid.");
    }
}

@guarded
def:protect correct_time(
    entry_id: str = "", start: any = UNSET, end: any = UNSET, absent: bool = False, note: str = ""
) -> dict[str, any] {
    start = opt(start);
    end = opt(end);
    st = me_student();
    ent = entry_of(str(entry_id or ""));
    if ent is None or ent.student != jid(st) {
        raise ApiError("Entry not found.");
    }
    try {
        timesheets.propose_correction(st, ent, _minutes(start), _minutes(end), bool(absent), str(note or ""));
    } except timesheets.TimesheetError as te {
        raise ApiError(str(te));
    }
    return timesheets.employee_timesheet(st);
}

@guarded
def:protect get_analytics(range: str = "week", anchor: any = UNSET) -> dict[str, any] {
    anchor = opt(anchor);
    st = me_student();
    rng = str(range or "week");
    if rng not in ("week", "month", "year") {
        raise ApiError("Pick week, month or year.");
    }
    a: date | None = None;
    if anchor {
        try {
            a = date.fromisoformat(str(anchor));
        } except ValueError {
            raise ApiError("That date isn't valid.");
        }
    }
    return timesheets.analytics(st, rng, a);
}

# ------------------------------------------------------------------ push (both roles)
def _subs(a: Account) -> list[PushSub] {
    return [a --> [?:PushSub]];
}

@guarded
def:protect get_push_config(endpoint: str = "") -> dict[str, any] {
    a = me();
    (_pk, public) = push.keys();
    mine = _subs(a);
    h = push.endpoint_hash(endpoint) if endpoint else "";
    return {
        "public_key": public,
        "devices": len(mine),
        "this_device": bool(endpoint) and any([s.endpoint_hash == h for s in mine])
    };
}

def _find_sub(h: str) -> PushSub | None {
    import from server.models { hub, Account as Acc }
    for a in [hub() --> [?:Acc]] {
        for s in [a --> [?:PushSub, endpoint_hash == h]] {
            return s;
        }
    }
    return None;
}

@guarded
def:protect save_push_subscription(subscription: any = UNSET, user_agent: str = "") -> dict[str, any] {
    subscription = opt(subscription);
    a = me();
    sub = subscription or {};
    if not isinstance(sub, dict) {
        raise ApiError("That subscription isn't valid.");
    }
    endpoint = str(sub.get("endpoint") or "");
    keys = sub.get("keys") or {};
    p256dh = str(keys.get("p256dh") or "");
    auth = str(keys.get("auth") or "");
    if not endpoint.startswith("https://") or not p256dh or not auth {
        raise ApiError("Your browser returned an incomplete push subscription. Try again.");
    }
    try {
        if len(push.unb64u(p256dh)) != 65 or len(push.unb64u(auth)) < 16 {
            raise ValueError("bad keys");
        }
    } except Exception {
        raise ApiError("Your browser returned invalid push keys. Try again.");
    }
    h = push.endpoint_hash(endpoint);
    row = _find_sub(h);
    if row is not None and row.account != jid(a) {
        del row;
        row = None;
    }
    if row is not None {
        row.p256dh = p256dh;
        row.auth = auth;
        row.failures = 0;
    } else {
        put(
            a,
            PushSub(
                account=jid(a), endpoint=endpoint, endpoint_hash=h, p256dh=p256dh, auth=auth,
                user_agent=str(user_agent or "")[:300], created=now_s()
            )
        );
    }
    return {"ok": True};
}

@guarded
def:protect delete_push_subscription(endpoint: str = "") -> dict[str, any] {
    a = me();
    h = push.endpoint_hash(str(endpoint or ""));
    for s in [a --> [?:PushSub, endpoint_hash == h]] {
        del s;
    }
    return {"ok": True};
}

@guarded
def:protect send_test_push() -> dict[str, any] {
    a = me();
    subs = _subs(a);
    if not subs {
        raise ApiError("Turn on notifications on this device first.");
    }
    text = "Notifications work. You'll get shift reminders 24 h and 1 h before, and your Friday timesheet check.";
    stamp = utcnow().strftime("%H%M%S%f");
    owner: any = None;
    if a.role == "department" {
        d = me_employer();
        owner = d;
        to_employer(d, text, "/d", title="CampusSync test", kind="test", dedupe_key=f"test:{jid(a)}:{stamp}");
    } else {
        st = me_student();
        owner = st;
        to_student(st, text, "/s", title="CampusSync test", kind="test", dedupe_key=f"test:{jid(a)}:{stamp}");
    }
    sent = push.deliver_pending([owner], now=True);
    return {"ok": sent > 0, "sent": sent, "devices": len(subs)};
}

"""Preview one of the real alerts on this phone right now (uses the employee's real next shift / hours)."""
@guarded
def:protect send_test_alert(kind: str = "shift_24h") -> dict[str, any] {
    a = me();
    st = me_student();
    k = str(kind or "shift_24h");
    stamp = utcnow().strftime("%H%M%S%f");
    key = f"preview:{jid(st)}:{stamp}";
    if k in ("shift_24h", "shift_1h") {
        this_week = monday(today_local()).isoformat();
        sid = jid(st);
        rows = sorted(
            [s for s in [_q for _q in [st --> [?:Shift]] if _q.status == "published"] if s.student == sid and s.week >= this_week],
            key=lambda (s: Shift) -> tuple[str, int, int] { return (s.week, s.day, s.start); }
        );
        what = "Your next shift";
        if rows {
            sh = rows[0];
            d = employer_of(sh.employer);
            what = f"{d.name if d is not None else ''} · {t12(sh.start)}–{t12(sh.end)}";
        }
        if k == "shift_24h" {
            to_student(
                st, f"Tomorrow {what}." if rows else "Tomorrow · your next shift.", "/s",
                title="Shift reminder (preview)", kind="test", dedupe_key=key
            );
        } else {
            to_student(
                st, f"{what}. Starts in 60 min.", "/s", title="Your shift starts soon (preview)", kind="test",
                dedupe_key=key
            );
        }
    } elif k in ("timesheet_am", "timesheet_pm") {
        ts = timesheets.employee_timesheet(st);
        hrs = ts["pending_hours"];
        if k == "timesheet_am" {
            to_student(
                st, f"CampusSync reported {hrs:g} hrs for you. Check the days you worked and approve.", "/s/time",
                title="Approve your timesheet (preview)", kind="test", dedupe_key=key
            );
        } else {
            to_student(
                st, f"You still have {hrs:g} hrs waiting for your approval. It takes one tap.", "/s/time",
                title="Reminder: timesheet not approved (preview)", kind="test", dedupe_key=key
            );
        }
    } else {
        raise ApiError("Unknown alert.");
    }
    subs = _subs(a);
    sent = push.deliver_pending([st], now=True) if subs else 0;
    return {"ok": True, "pushed": sent, "devices": len(subs)};
}
