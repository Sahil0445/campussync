"""Automated time reporting, Friday approval, over-reporting guard, pay estimates and alerts."""
from datetime import datetime

from sqlalchemy import select

from app import clock
from app.db import SessionLocal
from app.models import Notification, TimeEntry
from app.services import alerts, autopilot, payroll, timesheets

H = 60


def at(y, mo, d, h, mi=0):
    """Travel to a New York local time (EDT = UTC-4 in Sep/Oct)."""
    clock.travel_to(datetime(y, mo, d, h + 4, mi) if h + 4 < 24 else datetime(y, mo, d + 1, h + 4 - 24, mi))


def run():
    with SessionLocal() as db:
        return autopilot.tick(db)


def test_hours_are_reported_automatically_after_shifts_end(login):
    priya = login("priya@demo.edu")
    before = priya("get_timesheet")
    assert before["pending_count"] == 5  # last week's hours, waiting for Friday approval
    at(2026, 9, 29, 20)  # Tue 8 PM: Mon CSE 10–14 and Tue Dining 15–19 are over
    stats = run()
    assert stats["reported"] >= 2
    ts = priya("get_timesheet")
    this_week = next(w for w in ts["weeks"] if w["week"] == "2026-09-28")
    assert [(e["label"], e["department"], e["status"]) for e in this_week["entries"]] == [
        ("Mon Sep 28 · 10:00–14:00", "CSE Research", "reported"),
        ("Tue Sep 29 · 15:00–19:00", "Campus Dining", "reported"),
    ]
    assert this_week["entries"][0]["role"] == "Lab assistant" and this_week["entries"][1]["gross"] == 60.0
    assert run()["reported"] == 0  # idempotent


def test_friday_approval_and_correction_with_20h_guard(login):
    at(2026, 10, 2, 9, 30)  # Friday 9:30 AM
    run()
    priya = login("priya@demo.edu")
    ts = priya("get_timesheet")
    assert ts["review_today"] is True
    wk = next(w for w in ts["weeks"] if w["week"] == "2026-09-28")
    tue = next(e for e in wk["entries"] if e["label"].startswith("Tue"))
    # Claiming 6 hours on Tuesday would make the week 22 h across both jobs -> blocked in code
    r = priya("correct_time", expect=400, entry_id=tue["id"], start="15:00", end="21:00", note="stayed late")
    assert "20" in r["error"] and "International" in r["error"]
    # A small correction is fine and goes to the employer
    priya("correct_time", entry_id=tue["id"], start=15 * H, end=18 * H, note="left early for an exam")
    dining = login("dining@demo.edu", "department")
    sheet = dining("get_timesheets", week="2026-09-28")
    p = next(x for x in sheet["people"] if x["name"] == "Priya Nair")
    assert p["disputed"] == 1
    dining("resolve_time_entry", entry_id=tue["id"], accept=True)
    after = next(e for w in priya("get_timesheet")["weeks"] for e in w["entries"] if e["id"] == tue["id"])
    assert (after["status"], after["hours"]) == ("approved", 3.0)
    # approve the rest in one tap
    out = priya("approve_time")
    assert out["approved"] >= 1 and out["pending_count"] == 0


def test_employer_resolves_seeded_flag_and_exports_csv(login):
    dining = login("dining@demo.edu", "department")
    sheet = dining("get_timesheets", week="2026-09-21")
    sam = next(p for p in sheet["people"] if p["name"] == "Sam Ortiz")
    flagged = next(e for e in sam["entries"] if e["status"] == "disputed")
    assert flagged["proposed_end"] == 19 * H + 30 and "register" in flagged["note"]
    r = dining("resolve_time_entry", entry_id=flagged["id"], accept=False, note="Close-out is covered by the next shift")
    assert r["entry"]["status"] == "approved" and r["entry"]["end"] == 19 * H
    csv = dining("export_timesheets", week="2026-09-21")
    assert csv["filename"].endswith("2026-09-21.csv")
    lines = csv["csv"].strip().splitlines()
    assert lines[0].startswith("Employee,Email,Date") and any("Sam Ortiz" in ln for ln in lines)
    assert all("CSE" not in ln for ln in lines)  # never another employer's lines
    sam_api = login("sam@demo.edu")
    assert any("kept" in n["text"] for n in sam_api("get_notifications")["items"])


def test_pay_estimate_rules():
    t = payroll.weekly_taxes({4.25: 300.0}, fica_exempt=True)  # international student, $300 week
    assert t["federal"] == 0 and t["fica"] == 0 and t["state"] == 12.75 and t["net"] == 287.25
    t = payroll.weekly_taxes({4.25: 1000.0}, fica_exempt=False)  # $52k/yr worker
    assert t["fica"] == 76.5 and 60 < t["federal"] < 90 and t["net"] < 1000 - 76.5 - 42.5


def test_analytics_week_month_year(login):
    priya = login("priya@demo.edu")
    w = priya("get_analytics", range="week", anchor="2026-09-21")
    assert len(w["buckets"]) == 7 and w["totals"]["hours"] == 20 and w["totals"]["gross"] == 300
    labels = sorted(s["label"] for s in w["series"])
    assert labels == ["CSE Research · Lab assistant", "Campus Dining"]
    assert w["fica_exempt"] is True and w["totals"]["fica"] == 0 and w["totals"]["net"] == 287.25
    m = priya("get_analytics", range="month", anchor="2026-09-01")
    assert len(m["buckets"]) == 30 and m["totals"]["hours"] > 40
    y = priya("get_analytics", range="year", anchor="2026-09-01")
    assert len(y["buckets"]) == 12 and y["has_year"] is True
    assert sum(sum(s["hours"]) for s in y["series"]) == y["totals"]["hours"]
    # upcoming shifts appear as "scheduled" in the demo week
    nxt = priya("get_analytics", range="week", anchor="2026-09-28")
    assert nxt["totals"]["scheduled_hours"] == 20


def test_shift_alerts_24h_and_1h_exactly_once(login):
    at(2026, 9, 27, 12)  # Sunday noon: Monday's shifts are within 24 h
    with SessionLocal() as db:
        n1 = alerts.run(db)
        n2 = alerts.run(db)
        # Priya (CSE 10:00), Marcus and Leo (Dining 11:00) tomorrow, Diego's patrol tonight
        assert n1 == 4 and n2 == 0
    marcus = login("marcus@demo.edu")
    items = marcus("get_notifications")["items"]
    rem = [i for i in items if i["kind"] == "shift_24h"]
    assert len(rem) == 1 and rem[0]["text"].startswith("Tomorrow 11 AM–3 PM · Campus Dining")
    at(2026, 9, 28, 10, 15)  # Monday 10:15, Marcus starts at 11
    with SessionLocal() as db:
        alerts.run(db)
    soon = [i for i in marcus("get_notifications")["items"] if i["kind"] == "shift_1h"]
    assert len(soon) == 1 and "Starts in 45 min" in soon[0]["text"]
    # Priya's CSE shift started at 10:00 — no late alert
    priya = login("priya@demo.edu")
    assert not [i for i in priya("get_notifications")["items"] if i["kind"] == "shift_1h"]


def test_friday_timesheet_alerts_morning_then_evening_only_if_pending(login):
    at(2026, 10, 1, 21)  # Thursday night: nothing
    with SessionLocal() as db:
        timesheets.generate_due(db)
        assert alerts.timesheet_alerts(db) == 0
    at(2026, 10, 2, 9, 5)
    with SessionLocal() as db:
        assert alerts.timesheet_alerts(db) > 0
        db.commit()
    priya = login("priya@demo.edu")
    am = [i for i in priya("get_notifications")["items"] if i["kind"] == "timesheet_am"]
    assert len(am) == 1 and am[0]["link"] == "/s/time"
    sam = login("sam@demo.edu")
    sam("approve_time")  # Sam approves during the day
    at(2026, 10, 2, 18, 1)
    with SessionLocal() as db:
        alerts.timesheet_alerts(db)
        db.commit()
        pm = db.scalars(select(Notification).where(Notification.kind == "timesheet_pm")).all()
        sids = {n.student_id for n in pm}
    assert priya("whoami")["student"]["id"] in sids
    assert sam("whoami")["student"]["id"] not in sids


def test_alert_preview_walker(login):
    marcus = login("marcus@demo.edu")
    r = marcus("send_test_alert", kind="shift_1h")
    assert r["ok"] and r["devices"] == 0
    assert any("preview" in (i["title"] or "") for i in marcus("get_notifications")["items"])
