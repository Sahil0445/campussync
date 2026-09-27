"""Autopilot walkers: Mission Control, approvals inbox, live feed, copilot, calendar connect, policy."""
from __future__ import annotations

from datetime import date, datetime

from sqlalchemy import func, select

from .. import clock
from ..agents import copilot, needs, recruiting, scheduling
from ..agents.rules import Ledger
from ..agents.trace import Trace
from ..events import log
from ..models import (AgentEvent, BusyBlock, Employment, RecruitProposal, ScheduleDraft, Shift, StaffingRequirement,
                      Student, SwapLoop, SwapRequest)
from ..services import autopilot as autopilot_svc
from ..services import calendar, swaps
from ..timeutil import DAY_LONG, fmt_hours, hm, slot_label
from .base import Ctx, WalkerError, walker
from .department import _check, _probe, coverage
from .student import calendar_info

AGENTS = [
    {"name": "Coordinator", "kind": "agent", "role": "Orchestrates every workflow and decides which agent runs next."},
    {"name": "Availability Agent", "kind": "agent", "role": "Syncs calendars and turns notes into rules. Spots new clashes."},
    {"name": "Conflict Agent", "kind": "rules", "role": "Checks every employer's schedule. Says only yes or no."},
    {"name": "Compliance Checker", "kind": "rules", "role": "20 h international cap, assigned hours, 8 h/day, rest. Code, never AI."},
    {"name": "Scheduling Agent", "kind": "agent", "role": "Drafts the week: fairness, preferences, who takes Saturday."},
    {"name": "Swap Agent", "kind": "agent", "role": "Finds 1:1 swaps and 3–4 person loops. Re-plans on decline."},
    {"name": "Recruiting Agent", "kind": "agent", "role": "Finds students across campus for slots the team can't fill."},
    {"name": "Explainer", "kind": "agent", "role": "Writes every approval card and offer in one sentence."},
]


# ------------------------------------------------------------------ feed
def _events(ctx: Ctx, since: int, limit: int = 40) -> list[dict]:
    u = ctx.user
    scope = AgentEvent.department_id == u.department_id if u.role == "department" else AgentEvent.student_id == u.student_id
    rows = ctx.db.scalars(select(AgentEvent).where(scope, AgentEvent.id > since).order_by(AgentEvent.id.desc()).limit(limit)).all()
    now = clock.utcnow()
    return [{"id": e.id, "agent": e.agent, "kind": e.kind, "text": e.text, "level": e.level, "link": e.link,
             "seconds_ago": int((now - e.created_at).total_seconds())} for e in rows]


@walker("any")
def get_agent_feed(ctx: Ctx):
    return {"events": _events(ctx, int(ctx.get("since") or 0), int(ctx.get("limit") or 40))}


# ------------------------------------------------------------------ approvals inbox
def _approvals(ctx: Ctx) -> list[dict]:
    dept = ctx.department
    items: list[dict] = []
    for d in ctx.db.scalars(select(ScheduleDraft).where(ScheduleDraft.department_id == dept.id, ScheduleDraft.state == "draft")
                            .order_by(ScheduleDraft.id.desc())):
        s = d.summary or {}
        wk = date.fromisoformat(d.week)
        gaps = s.get("open_seats", 0)
        items.append({"type": "draft", "id": d.id, "agent": "Scheduling Agent", "link": f"/d/drafts/{d.id}",
                      "title": f"Week of {wk:%b} {wk.day} is drafted · {s.get('filled')} of {s.get('needed')} slots filled",
                      "detail": (f"{gaps} slot{'s' if gaps != 1 else ''} flagged · the Recruiting Agent is on it" if gaps else "Every slot is covered")
                                + " · every rule checked", "risk": "low" if not gaps else "medium"})
    for req in ctx.db.scalars(select(SwapRequest).where(SwapRequest.department_id == dept.id, SwapRequest.state == "awaiting_manager")):
        lp = ctx.db.scalar(select(SwapLoop).where(SwapLoop.request_id == req.id, SwapLoop.state == "proposed"))
        if not lp:
            continue
        sh = ctx.db.get(Shift, req.shift_id)
        who = ctx.db.get(Student, req.requester_id).first_name
        why = "calendar changed" if req.origin == "calendar" else "asked for a change"
        kind = {"loop": f"{lp.size}-person swap", "direct": "direct swap", "handoff": "hand-off"}[lp.kind]
        items.append({"type": "swap", "id": lp.id, "request_id": req.id, "agent": "Swap Agent", "link": f"/d/requests/{req.id}",
                      "title": f"{who} can't make {DAY_LONG[sh.day]} ({why}) · {kind} found",
                      "detail": "Everyone stays within limits · coverage unchanged", "risk": "low"})
    for p in ctx.db.scalars(select(RecruitProposal).where(RecruitProposal.department_id == dept.id, RecruitProposal.state == "proposed")):
        st = ctx.db.get(Student, p.student_id)
        covers = ", ".join(slot_label(c["day"], c["start"], c["end"]) for c in p.covers)
        items.append({"type": "recruit", "id": p.id, "agent": "Recruiting Agent", "link": "/d/approvals",
                      "title": f"Invite {st.name} · {p.hours} hrs/week to cover {covers}",
                      "detail": p.reason, "risk": "low", "status": st.status})
    return items


@walker("department")
def get_approvals(ctx: Ctx):
    return {"items": _approvals(ctx)}


@walker("department")
def decide(ctx: Ctx):
    """One endpoint for every approval: {type, id, approve: bool}."""
    kind, oid, ok = ctx.need("type"), ctx.need("id", int), bool(ctx.get("approve"))
    dept = ctx.department
    if kind == "draft":
        d = ctx.db.get(ScheduleDraft, oid)
        if not d or d.department_id != dept.id or d.state != "draft":
            raise WalkerError("This draft is no longer waiting.")
        if ok:
            from .department import publish_schedule
            ctx.body["draft_id"] = oid
            return {"ok": True, **publish_schedule(ctx)}
        scheduling.discard(ctx.db, d)
        log(ctx.db, "Coordinator", "Draft discarded · autopilot will wait before drafting again", kind="human", department_id=dept.id)
        ctx.db.commit()
        return {"ok": True}
    if kind == "swap":
        from .department import approve_swap, reject_swap
        ctx.body["loop_id"] = oid
        return approve_swap(ctx) if ok else reject_swap(ctx)
    if kind == "recruit":
        p = ctx.db.get(RecruitProposal, oid)
        if not p or p.department_id != dept.id or p.state != "proposed":
            raise WalkerError("This suggestion is no longer waiting.")
        recruiting.approve(ctx.db, p) if ok else recruiting.reject(ctx.db, p)
        ctx.db.commit()
        autopilot_svc.run_once()  # student autopilots answer right away
        return {"ok": True}
    raise WalkerError("Unknown approval.")


# ------------------------------------------------------------------ mission control
@walker("department")
def get_dashboard(ctx: Ctx):
    dept = ctx.department
    week = ctx.week if ctx.get("week") else autopilot_svc.planning_week()
    cov = coverage(ctx, week)
    ledger = Ledger(ctx.db, week)
    team = scheduling.team_of(ctx.db, dept.id)
    hours = sum(ledger.dept_hours(st.id, dept.id) for st in team)
    cal = sum(1 for st in team if st.calendar_source in ("google", "ics_url", "demo"))
    s = cov["stats"]
    auto_actions = ctx.db.scalar(select(func.count(AgentEvent.id)).where(AgentEvent.department_id == dept.id, AgentEvent.kind != "human"))
    human_actions = ctx.db.scalar(select(func.count(AgentEvent.id)).where(AgentEvent.department_id == dept.id, AgentEvent.kind == "human"))
    return {
        "department": cov["department"], "week": week, "coverage": cov,
        "kpis": {"coverage_pct": round(100 * s["filled"] / s["needed"]) if s["needed"] else 0, "filled": s["filled"], "needed": s["needed"],
                 "open": s["needed"] - s["filled"], "hours": hours, "students": s["students"], "calendars": cal,
                 "automation_pct": round(100 * auto_actions / max(1, auto_actions + human_actions))},
        "approvals": _approvals(ctx),
        "events": _events(ctx, 0, 30),
        "policy": {"auto_generate": dept.auto_generate, "auto_recruit": dept.auto_recruit, "auto_approve_swaps": dept.auto_approve_swaps},
        "agents": AGENTS,
    }


@walker("department")
def set_policy(ctx: Ctx):
    dept = ctx.department
    for k in ("auto_generate", "auto_recruit", "auto_approve_swaps"):
        if ctx.get(k) is not None:
            setattr(dept, k, bool(ctx.get(k)))
    log(ctx.db, "Coordinator", "Autopilot policy updated", kind="human", department_id=dept.id)
    ctx.db.commit()
    return {"ok": True}


@walker("department")
def run_autopilot(ctx: Ctx):
    stats = autopilot_svc.run_once()
    return {"ok": True, "stats": stats}


@walker("department")
def generate_needs(ctx: Ctx):
    """Needs Agent: description -> staffing requirements (returned for review; saved by set_staffing_needs)."""
    from ..models import Position

    dept = ctx.department
    desc = str(ctx.get("description") or dept.description or "")[:800]
    roles = [{"id": p.id, "name": p.name} for p in ctx.db.scalars(select(Position).where(Position.department_id == dept.id))]
    rows, summary, used_ai = needs.generate(desc, roles, dept.kind)
    names = {r["id"]: r["name"] for r in roles}
    for n in rows:
        n["role"] = names.get(n.get("position_id")) or ""
    if not dept.description and desc:
        dept.description = desc
        ctx.db.commit()
    if ctx.get("save"):
        dept.description = desc
        for r in ctx.db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == dept.id)):
            ctx.db.delete(r)
        for n in rows:
            ctx.db.add(StaffingRequirement(department_id=dept.id, day=n["day"], start=n["start"], end=n["end"], headcount=n["headcount"],
                                           position_id=n.get("position_id")))
        log(ctx.db, "Needs Agent", f"Built your staffing plan · {len(rows)} blocks a week", department_id=dept.id, level="done")
        ctx.db.commit()
    return {"needs": rows, "summary": summary, "ai": used_ai}


# ------------------------------------------------------------------ manager copilot
def _people(ctx: Ctx, pool: bool = False) -> list[tuple[int, str]]:
    """Names the copilot may resolve. The wider pool is only students at the same university (campus employers)."""
    dept = ctx.department
    if pool and dept.kind == "campus" and dept.university_id:
        return [(s.id, s.name) for s in ctx.db.scalars(select(Student).where(Student.kind == "student", Student.school_id == dept.university_id))]
    return [(s.id, s.name) for s in scheduling.team_of(ctx.db, dept.id)]


def _slot_role(ctx: Ctx, text: str, day: int, start: int, end: int) -> int | None:
    """The role a copilot request is about: named in the text, or the only role planned for exactly that slot."""
    from ..models import Position

    roles = list(ctx.db.scalars(select(Position).where(Position.department_id == ctx.department.id)))
    low = text.lower()
    for r in roles:
        words = [w for w in r.name.lower().split() if len(w) > 2]
        if words and all(w[:5] in low for w in words[-1:]):
            return r.id
    pids = {q.position_id for q in ctx.db.scalars(select(StaffingRequirement).where(
        StaffingRequirement.department_id == ctx.department.id, StaffingRequirement.day == day,
        StaffingRequirement.start == start, StaffingRequirement.end == end))}
    return next(iter(pids)) if len(pids) == 1 else None


def _default_slot(ctx: Ctx, day: int, hours: float | None) -> tuple[int, int] | None:
    reqs = ctx.db.scalars(select(StaffingRequirement).where(StaffingRequirement.department_id == ctx.department.id,
                                                            StaffingRequirement.day == day).order_by(StaffingRequirement.start)).all()
    if hours:
        start = reqs[0].start if reqs else 12 * 60
        return start, min(24 * 60, int(start + hours * 60))
    return (reqs[0].start, reqs[0].end) if reqs else None


@walker("department")
def copilot_command(ctx: Ctx):
    text = str(ctx.get("text") or "").strip()[:300]
    if not text:
        raise WalkerError("Type what you need.")
    dept = ctx.department
    week = ctx.week if ctx.get("week") else autopilot_svc.planning_week()
    team = _people(ctx)
    intent, used_ai = copilot.parse_dept(text, team + [p for p in _people(ctx, pool=True) if p not in team])
    tr = Trace()
    it = intent["intent"]
    tr.step("Coordinator", "agent", f"understood: {it}", ai=used_ai)
    sid, day = intent.get("student_id"), intent.get("day")
    start, end = intent.get("start"), intent.get("end")
    if it in ("check", "assign", "find") and day is not None and start is None:
        slot = _default_slot(ctx, day, intent.get("hours"))
        if slot:
            start, end = slot
    team_ids = {p[0] for p in team}

    if it in ("check", "assign"):
        if not sid or sid not in team_ids:
            return _reply(tr, "I couldn't find that person on your team. Try their first name, or say “invite …”.")
        if day is None or start is None:
            return _reply(tr, "Which day and time? e.g. “Wed 12 to 3”.")
        st = ctx.db.get(Student, sid)
        _probe(ctx, sid)
        ledger = Ledger(ctx.db, week)
        pid = _slot_role(ctx, text, day, start, end)
        if pid and not ledger.qualified(sid, dept.id, pid):
            pid = None  # an explicit command about someone without the role books a general shift
        res = _check(ctx, ledger, st, day, start, end, pid)
        conflict = res.get("reason") == "schedule_conflict"
        tr.step("Conflict Agent", "rules", "checked every employer · hidden conflict found" if conflict else "checked every employer · clear",
                status="blocked" if conflict else "done")
        if not conflict:
            over = res.get("reason") == "hour_limit"
            tr.step("Compliance Checker", "rules", "over the weekly limit" if over else "within every limit", status="blocked" if over else "done")
        assigned = False
        if res["available"] and it == "assign":
            ctx.db.add(Shift(department_id=dept.id, week=week, day=day, start=start, end=end, student_id=sid, position_id=pid,
                             state="assigned", status="published", source="manual"))
            from ..notify import to_student
            to_student(ctx.db, sid, f"{dept.name} added a shift: {slot_label(day, start, end)}.", "/s")
            log(ctx.db, "Scheduling Agent", f"Added {st.first_name} to {slot_label(day, start, end)} (your command)", kind="human", department_id=dept.id, level="done")
            assigned = True
        ctx.db.commit()
        tr.final("Done" if res["available"] else "Blocked", ok=res["available"])
        reply = (f"Added {st.first_name} to {slot_label(day, start, end)}." if assigned else
                 f"{st.first_name} is free for {slot_label(day, start, end)}." if res["available"] else
                 f"Can't schedule {st.first_name} on {slot_label(day, start, end)}." if conflict else
                 f"Can't add {fmt_hours((end - start) / 60)} hrs for {st.first_name} this week.")
        return {"reply": reply, "trace": tr.rows, "card": {"type": "check", "student_id": sid, "name": st.first_name,
                "day": day, "start": start, "end": end, "result": res, "assigned": assigned, "week": week, "position_id": pid}}

    if it == "find":
        if day is None or start is None:
            return _reply(tr, "Which slot should I cover? e.g. “Who can cover Friday 3 to 7?”")
        ledger = Ledger(ctx.db, week)
        pid = _slot_role(ctx, text, day, start, end)
        ranked = []
        for st in scheduling.team_of(ctx.db, dept.id):
            if ledger.check(st.id, dept.id, day, start, end, pid=pid).ok:
                ranked.append((-ledger.hours_left(st.id, dept.id), st))
        ranked.sort(key=lambda t: (t[0], t[1].name))
        tr.step("Conflict Agent", "rules", f"checked {len(team)} people across every employer")
        tr.step("Compliance Checker", "rules", f"{len(ranked)} within limits", status="done" if ranked else "blocked")
        tr.final("Done" if ranked else "No one free", ok=bool(ranked))
        people = [{"student_id": st.id, "name": st.name, "hours_left": -h} for h, st in ranked[:4]]
        reply = (f"{len(ranked)} {'person' if len(ranked) == 1 else 'people'} can take {slot_label(day, start, end)}." if ranked else
                 f"No one on your team can take {slot_label(day, start, end)}. The Recruiting Agent can look across campus.")
        return {"reply": reply, "trace": tr.rows, "card": {"type": "people", "day": day, "start": start, "end": end, "people": people, "week": week,
                                                           "position_id": pid}}

    if it == "need":
        if day is None or start is None:
            return _reply(tr, "Which slot? e.g. “Need 2 more people Saturday 3 to 7”.")
        n = int(intent.get("count") or 1)
        fewer = any(w in text.lower() for w in ("fewer", "less", "remove", "drop"))
        req = ctx.db.scalar(select(StaffingRequirement).where(StaffingRequirement.department_id == dept.id, StaffingRequirement.day == day,
                                                               StaffingRequirement.start == start, StaffingRequirement.end == end))
        if req:
            req.headcount = max(0, req.headcount + (-n if fewer else n))
            if req.headcount == 0:
                ctx.db.delete(req)
        elif not fewer:
            ctx.db.add(StaffingRequirement(department_id=dept.id, day=day, start=start, end=end, headcount=n))
        log(ctx.db, "Coordinator", f"Staffing need changed · {slot_label(day, start, end)} {'−' if fewer else '+'}{n}", kind="human", department_id=dept.id)
        ctx.db.commit()
        tr.step("Scheduling Agent", "agent", "autopilot will fill the new slots")
        tr.final("Done")
        autopilot_svc.run_once()
        return {"reply": f"Updated {slot_label(day, start, end)} ({'−' if fewer else '+'}{n}). Autopilot is filling it now.", "trace": tr.rows,
                "card": {"type": "link", "label": "Open approvals", "to": "/d/approvals"}}

    if it == "invite":
        if not sid:
            return _reply(tr, "Who should I invite?")
        st = ctx.db.get(Student, sid)
        hours = int(intent.get("hours") or 8)
        if dept.kind != "campus" or st.kind != "student" or st.school_id != dept.university_id:
            return _reply(tr, f"Share your join code ({dept.join_code}) — people join your team by signing up with it.")
        emp = ctx.db.scalar(select(Employment).where(Employment.student_id == sid, Employment.department_id == dept.id))
        if emp and emp.state == "active":
            return _reply(tr, f"{st.first_name} is already on your team.")
        if emp:
            emp.state, emp.hours = "invited", hours
        else:
            ctx.db.add(Employment(student_id=sid, department_id=dept.id, hours=hours, state="invited", pay_rate=dept.default_pay_rate))
        from ..notify import to_student
        to_student(ctx.db, sid, f"{dept.name} invited you · {hours} hrs/week", "/s")
        log(ctx.db, "Recruiting Agent", f"Invited {st.first_name} · {hours} hrs/week (your command)", kind="human", department_id=dept.id)
        ctx.db.commit()
        tr.final("Invite sent")
        autopilot_svc.run_once()
        return {"reply": f"Invited {st.first_name} for {hours} hrs/week. Their autopilot will answer if it fits their hours.", "trace": tr.rows}

    if it == "generate":
        d = scheduling.generate(ctx.db, dept, week, origin="manual")
        tr.step("Scheduling Agent", "agent", f"drafted · {d.summary['filled']} of {d.summary['needed']} filled")
        tr.final("Ready for review")
        return {"reply": f"Drafted the week · {d.summary['filled']} of {d.summary['needed']} slots filled.", "trace": tr.rows,
                "card": {"type": "link", "label": "Review draft", "to": f"/d/drafts/{d.id}"}}

    if it == "status":
        cov = coverage(ctx, week)
        s = cov["stats"]
        short = [f"{DAY_LONG[c['day']][:3]} {hm(c['start'])}–{hm(c['end'])}" for c in cov["cells"] if c["assigned"] < c["needed"]]
        tr.final("Done")
        reply = f"{s['filled']} of {s['needed']} slots filled" + (f" · short on {', '.join(short[:4])}" if short else " · fully covered") + \
                f" · {len(_approvals(ctx))} waiting for you."
        return {"reply": reply, "trace": tr.rows}

    first = team[0][1].split()[0] if team else "Sam"
    return _reply(tr, f"I can check or assign someone (“Can {first} work Wed 12–3?”), find cover (“Who can cover Fri evening?”), "
                      "change needs (“Need 2 more Saturday 3–7”), " + ("invite a student, " if dept.kind == "campus" else "") + "or build the schedule.")


def _reply(tr: Trace, text: str) -> dict:
    tr.final("Need more detail", ok=False)
    return {"reply": text, "trace": tr.rows}


# ------------------------------------------------------------------ student copilot
@walker("student")
def student_command(ctx: Ctx):
    st = ctx.student
    text = str(ctx.get("text") or "").strip()[:300]
    if not text:
        raise WalkerError("Tell CampusSync what changed.")
    week = ctx.week if ctx.get("week") else autopilot_svc.planning_week()
    intent, used_ai = copilot.parse_student(text)
    tr = Trace()
    tr.step("Coordinator", "agent", f"understood: {intent['intent']}", ai=used_ai)
    ledger = Ledger(ctx.db, week)
    if intent["intent"] == "hours":
        total, cap = ledger.total_hours(st.id), st.cap
        tr.final("Done")
        return {"reply": f"You're at {fmt_hours(total)} of {cap} hrs this week · {fmt_hours(max(0, cap - total))} left.", "trace": tr.rows}

    if intent["intent"] == "unavailable":
        for u in intent["unavailable"]:
            ctx.db.add(BusyBlock(student_id=st.id, day=u["day"], start=u["start"], end=u["end"], title=u["label"], source="note",
                                 week=None if u["recurring"] else week))
        labels = ", ".join(f"{DAY_LONG[u['day']]}{'s' if u['recurring'] else ''}" + ("" if (u["start"], u["end"]) == (0, 1440) else f" {hm(u['start'])}–{hm(u['end'])}")
                           for u in intent["unavailable"])
        log(ctx.db, "Availability Agent", f"Blocked {labels} from your note", student_id=st.id)
        ctx.db.commit()
        tr.step("Availability Agent", "agent", f"blocked {labels}", ai=used_ai)
        before = set(ctx.db.scalars(select(SwapRequest.id).where(SwapRequest.requester_id == st.id)))
        if intent["want_days"]:
            saved = st.open_swap_days
            st.open_swap_days = intent["want_days"]
            calendar.detect_disruptions(ctx.db, st)
            st.open_swap_days = saved
        else:
            calendar.detect_disruptions(ctx.db, st)
        ctx.db.commit()
        new = [r for r in ctx.db.scalars(select(SwapRequest).where(SwapRequest.requester_id == st.id)) if r.id not in before]
        for r in new:
            tr.rows += [row for row in (r.trace or []) if row["kind"] != "final"]
        if new:
            found = any(r.state == "awaiting_manager" for r in new)
            tr.final("Cover found · waiting for your manager" if found else "Still searching", ok=found)
            reply = (f"Got it — {labels} is blocked. You had a shift then, so autopilot " +
                     ("found a swap and sent it to your manager." if found else "is looking for cover and will keep trying."))
            return {"reply": reply, "trace": tr.rows, "card": {"type": "link", "label": "Follow it", "to": f"/s/request?id={new[0].id}"}}
        tr.final("Done")
        return {"reply": f"Got it — {labels} is blocked. No shifts were affected.", "trace": tr.rows}

    if intent["intent"] == "swap" and intent.get("give_up_day") is not None:
        sh = ctx.db.scalar(select(Shift).where(Shift.student_id == st.id, Shift.week == week, Shift.status == "published",
                                                Shift.state == "assigned", Shift.day == intent["give_up_day"]))
        if not sh:
            return _reply(tr, f"You don't have a {DAY_LONG[intent['give_up_day']]} shift this week.")
        try:
            req = swaps.create_request(ctx.db, st, sh.id, "days" if intent["want_days"] else "any", intent["want_days"], text, origin="copilot")
        except swaps.SwapError as e:
            return _reply(tr, str(e))
        tr.rows += [row for row in (req.trace or []) if row["kind"] != "final"]
        found = req.state == "awaiting_manager"
        tr.final("Ready for your manager" if found else "Still searching", ok=found)
        return {"reply": "Found a swap — sent to your manager." if found else "No swap yet. Autopilot will keep looking.",
                "trace": tr.rows, "card": {"type": "link", "label": "Follow it", "to": f"/s/request?id={req.id}"}}

    if intent["intent"] == "status":
        shifts = ctx.db.scalars(select(Shift).where(Shift.student_id == st.id, Shift.week == week, Shift.status == "published")).all()
        tr.final("Done")
        return {"reply": f"You have {len(shifts)} shifts this week · {fmt_hours(ledger.total_hours(st.id))} of {st.cap} hrs.", "trace": tr.rows}

    return _reply(tr, "Tell me what changed, like “I can't do Saturday, Wednesday works” or “dentist Friday 2–4”. I'll handle the rest.")


# ------------------------------------------------------------------ calendar connect
@walker("student")
def connect_calendar(ctx: Ctx):
    st = ctx.student
    source = str(ctx.get("source") or "")
    if source == "ics_url":
        url = str(ctx.need("url")).strip()
        try:
            text = calendar.fetch_ics_url(url)
        except calendar.CalendarError as e:
            raise WalkerError(str(e))
        st.calendar_source, st.calendar_url = "ics_url", url
        calendar.replace_calendar_blocks(ctx.db, st, calendar.blocks_from_ics_text(text))
    elif source == "demo":
        st.calendar_source = "demo"
        if not st.demo_events:
            from ..seed import sample_demo_events
            st.demo_events = sample_demo_events()
    else:
        raise WalkerError("Choose how to connect your calendar.")
    ctx.db.commit()
    res = calendar.sync_student(ctx.db, st, announce=True)
    return {"ok": res.get("ok", True), "calendar": calendar_info(st), "error": res.get("error")}


@walker("student")
def start_google_connect(ctx: Ctx):
    """Returns Google's consent URL for this employee (the browser goes there directly — no session token in any URL)."""
    if not calendar.google_enabled():
        raise WalkerError("Google sign-in isn't configured on this server yet. Use your calendar's secret iCal link instead.")
    nxt = str(ctx.get("next") or "/s/availability")
    if not nxt.startswith("/") or nxt.startswith("//"):
        nxt = "/s/availability"
    return {"url": calendar.google_auth_url(ctx.student.id, nxt)}


@walker("student")
def sync_calendar(ctx: Ctx):
    st = ctx.student
    res = calendar.sync_student(ctx.db, st, announce=True)
    if not res.get("ok"):
        raise WalkerError(res.get("error") or "Couldn't sync.")
    return {"ok": True, "calendar": calendar_info(st), **{k: v for k, v in res.items() if k != "ok"}}


@walker("student")
def disconnect_calendar(ctx: Ctx):
    st = ctx.student
    if st.calendar_source == "google" or st.google_refresh_token:
        calendar.disconnect_google(ctx.db, st)
    st.calendar_source, st.calendar_url, st.calendar_error = "", "", ""
    for b in ctx.db.scalars(select(BusyBlock).where(BusyBlock.student_id == st.id, BusyBlock.source == "calendar")):
        ctx.db.delete(b)
    ctx.db.commit()
    return {"ok": True, "calendar": calendar_info(st)}

