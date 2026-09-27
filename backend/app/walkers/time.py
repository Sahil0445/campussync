"""Employee walkers for time reporting, pay analytics — and push subscriptions (both roles)."""
from __future__ import annotations

from datetime import date

from sqlalchemy import select

from .. import clock
from ..models import PushSubscription, TimeEntry
from ..notify import to_department, to_student
from ..services import push, timesheets
from .base import Ctx, WalkerError, walker


@walker("student")
def get_timesheet(ctx: Ctx):
    return timesheets.employee_timesheet(ctx.db, ctx.student)


@walker("student")
def approve_time(ctx: Ctx):
    ids = ctx.get("entry_ids")
    if ids is not None:
        try:
            ids = [int(x) for x in ids]
        except (TypeError, ValueError):
            raise WalkerError("Those entries aren't valid.")
    n = timesheets.approve(ctx.db, ctx.student, ids or None)
    return {"approved": n, **timesheets.employee_timesheet(ctx.db, ctx.student)}


def _minutes(v) -> int | None:
    if v is None or v == "":
        return None
    try:
        if isinstance(v, str) and ":" in v:
            h, m = v.split(":")
            return int(h) * 60 + int(m)
        return int(v)
    except (TypeError, ValueError):
        raise WalkerError("That time isn't valid.")


@walker("student")
def correct_time(ctx: Ctx):
    e = ctx.db.get(TimeEntry, ctx.need("entry_id", int))
    if not e or e.student_id != ctx.student.id:
        raise WalkerError("Entry not found.", 404)
    try:
        timesheets.propose_correction(ctx.db, ctx.student, e, _minutes(ctx.get("start")), _minutes(ctx.get("end")),
                                      bool(ctx.get("absent")), str(ctx.get("note") or ""))
    except timesheets.TimesheetError as err:
        raise WalkerError(str(err))
    return timesheets.employee_timesheet(ctx.db, ctx.student)


@walker("student")
def get_analytics(ctx: Ctx):
    rng = str(ctx.get("range") or "week")
    if rng not in ("week", "month", "year"):
        raise WalkerError("Pick week, month or year.")
    anchor = None
    if ctx.get("anchor"):
        try:
            anchor = date.fromisoformat(str(ctx.get("anchor")))
        except ValueError:
            raise WalkerError("That date isn't valid.")
    return timesheets.analytics(ctx.db, ctx.student, rng, anchor)


# ------------------------------------------------------------------ push (both roles)
@walker("any")
def get_push_config(ctx: Ctx):
    _, public = push.keys(ctx.db)
    endpoint = str(ctx.get("endpoint") or "")
    mine = ctx.db.scalars(select(PushSubscription).where(PushSubscription.user_id == ctx.user.id)).all()
    return {"public_key": public, "devices": len(mine),
            "this_device": bool(endpoint) and any(s.endpoint_hash == push.endpoint_hash(endpoint) for s in mine)}


@walker("any")
def save_push_subscription(ctx: Ctx):
    sub = ctx.get("subscription") or {}
    if not isinstance(sub, dict):
        raise WalkerError("That subscription isn't valid.")
    endpoint = str(sub.get("endpoint") or "")
    keys = sub.get("keys") or {}
    p256dh, auth = str(keys.get("p256dh") or ""), str(keys.get("auth") or "")
    if not endpoint.startswith("https://") or not p256dh or not auth:
        raise WalkerError("Your browser returned an incomplete push subscription. Try again.")
    try:
        if len(push.unb64u(p256dh)) != 65 or len(push.unb64u(auth)) < 16:
            raise ValueError
    except Exception:
        raise WalkerError("Your browser returned invalid push keys. Try again.")
    h = push.endpoint_hash(endpoint)
    row = ctx.db.scalar(select(PushSubscription).where(PushSubscription.endpoint_hash == h))
    if row:
        row.user_id, row.p256dh, row.auth, row.failures = ctx.user.id, p256dh, auth, 0
    else:
        ctx.db.add(PushSubscription(user_id=ctx.user.id, endpoint=endpoint, endpoint_hash=h, p256dh=p256dh, auth=auth,
                                    user_agent=str(ctx.get("user_agent") or "")[:300]))
    ctx.db.commit()
    return {"ok": True}


@walker("any")
def delete_push_subscription(ctx: Ctx):
    endpoint = str(ctx.get("endpoint") or "")
    row = ctx.db.scalar(select(PushSubscription).where(PushSubscription.endpoint_hash == push.endpoint_hash(endpoint)))
    if row and row.user_id == ctx.user.id:
        ctx.db.delete(row)
        ctx.db.commit()
    return {"ok": True}


@walker("any")
def send_test_push(ctx: Ctx):
    u = ctx.user
    subs = ctx.db.scalars(select(PushSubscription).where(PushSubscription.user_id == u.id)).all()
    if not subs:
        raise WalkerError("Turn on notifications on this device first.")
    text = "Notifications work. You'll get shift reminders 24 h and 1 h before, and your Friday timesheet check."
    stamp = clock.utcnow().strftime("%H%M%S%f")
    if u.role == "department":
        to_department(ctx.db, u.department_id, text, "/d", title="CampusSync test", kind="test", dedupe_key=f"test:{u.id}:{stamp}")
    else:
        to_student(ctx.db, u.student_id, text, "/s", title="CampusSync test", kind="test", dedupe_key=f"test:{u.id}:{stamp}")
    ctx.db.commit()
    sent = push.deliver_pending(ctx.db)
    return {"ok": sent > 0, "sent": sent, "devices": len(subs)}


@walker("student")
def send_test_alert(ctx: Ctx):
    """Preview one of the real alerts on this phone right now (uses the employee's real next shift / hours)."""
    from datetime import timedelta

    from ..models import Department, Shift
    from ..services.alerts import _t12

    st = ctx.student
    kind = str(ctx.get("kind") or "shift_24h")
    stamp = clock.utcnow().strftime("%H%M%S%f")
    if kind in ("shift_24h", "shift_1h"):
        today = clock.monday(clock.today_local())
        sh = ctx.db.scalar(select(Shift).where(Shift.student_id == st.id, Shift.status == "published", Shift.week >= today.isoformat())
                           .order_by(Shift.week, Shift.day, Shift.start).limit(1))
        what = f"{ctx.db.get(Department, sh.department_id).name} · {_t12(sh.start)}–{_t12(sh.end)}" if sh else "Your next shift"
        if kind == "shift_24h":
            to_student(ctx.db, st.id, f"Tomorrow {what}." if sh else "Tomorrow · your next shift.", "/s", title="Shift reminder (preview)",
                       kind="test", dedupe_key=f"preview:{st.id}:{stamp}")
        else:
            to_student(ctx.db, st.id, f"{what}. Starts in 60 min.", "/s", title="Your shift starts soon (preview)", kind="test",
                       dedupe_key=f"preview:{st.id}:{stamp}")
    elif kind in ("timesheet_am", "timesheet_pm"):
        ts = timesheets.employee_timesheet(ctx.db, st)
        hrs = ts["pending_hours"]
        if kind == "timesheet_am":
            to_student(ctx.db, st.id, f"CampusSync reported {hrs:g} hrs for you. Check the days you worked and approve.", "/s/time",
                       title="Approve your timesheet (preview)", kind="test", dedupe_key=f"preview:{st.id}:{stamp}")
        else:
            to_student(ctx.db, st.id, f"You still have {hrs:g} hrs waiting for your approval. It takes one tap.", "/s/time",
                       title="Reminder: timesheet not approved (preview)", kind="test", dedupe_key=f"preview:{st.id}:{stamp}")
    else:
        raise WalkerError("Unknown alert.")
    ctx.db.commit()
    subs = ctx.db.scalars(select(PushSubscription).where(PushSubscription.user_id == ctx.user.id)).all()
    sent = push.deliver_pending(ctx.db) if subs else 0
    return {"ok": True, "pushed": sent, "devices": len(subs)}
