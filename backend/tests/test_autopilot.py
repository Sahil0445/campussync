"""Autopilot end to end: the demo with humans only approving."""
from app.db import SessionLocal
from app.services import autopilot
from app.services.calendar import google_events_to_blocks

SAT, WED, THU = 5, 2, 3
H = 60


def tick():
    with SessionLocal() as db:
        return autopilot.tick(db)


def cells(dining):
    return {(c["day"], c["start"]): sorted(p["name"] for p in c["people"]) for c in dining("get_coverage")["cells"]}


def test_autopilot_drafts_recruits_and_fills_everything(login):
    dining = login("dining@demo.edu", "department")
    stats = tick()
    assert stats["drafts"] == 2 and stats["recruits"] == 2  # Campus Dining + Shieldpoint draft; only campus employers recruit
    items = dining("get_approvals")["items"]
    kinds = sorted(i["type"] for i in items)
    assert kinds == ["draft", "recruit", "recruit"]
    draft = next(i for i in items if i["type"] == "draft")
    assert "22 of 24" in draft["title"]
    recruits = [i for i in items if i["type"] == "recruit"]
    assert {r["title"].split(" · ")[0] for r in recruits} == {"Invite Mia Johnson", "Invite Ravi Patel"}
    assert all("Sat 15:00–19:00" in r["title"] for r in recruits)

    dining("decide", type="draft", id=draft["id"], approve=True)
    for r in recruits:
        dining("decide", type="recruit", id=r["id"], approve=True)
    # Ravi and Mia's autopilots accept (within their wanted hours) and the gap fills itself.
    stats = dining("get_dashboard")["kpis"]
    assert (stats["filled"], stats["needed"]) == (24, 24)
    assert cells(dining)[(SAT, 15 * H)] == ["Mia", "Ravi"]
    assert tick()["drafts"] == 0  # nothing left to do
    ravi = login("ravi@demo.edu")
    assert [j["department"] for j in ravi("get_student_home")["jobs"]] == ["Campus Dining"]


def test_calendar_change_triggers_loop_decline_replan_commit(login, client):
    dining = login("dining@demo.edu", "department")
    tick()
    r = client.post("/demo/calendar-event", json={"email": "priya@demo.edu", "day": SAT, "start": 9 * H, "end": 17 * H, "title": "Family visit"})
    assert r.status_code == 200 and len(r.json()["disruptions"]) == 1
    swap = next(i for i in dining("get_approvals")["items"] if i["type"] == "swap")
    assert "calendar changed" in swap["title"] and "3-person swap" in swap["title"]
    priya = login("priya@demo.edu")
    feed = " ".join(e["text"] for e in priya("get_agent_feed")["events"])
    assert "Family visit" in feed  # the student sees their own event title…
    dfeed = " ".join(e["text"] for e in dining("get_agent_feed")["events"])
    assert "Family visit" not in dfeed and "Priya can no longer make Sat" in dfeed  # …the department doesn't

    dining("decide", type="swap", id=swap["id"], approve=True)
    marcus = login("marcus@demo.edu")
    marcus("respond_offer", offer_id=marcus("get_student_home")["offers"][0]["offer_id"], accept=False,
           reason_text="Thursday doesn't work for me anymore.")
    swap2 = next(i for i in dining("get_approvals")["items"] if i["type"] == "swap")
    assert "4-person swap" in swap2["title"]
    card = dining("decide", type="swap", id=swap2["id"], approve=True)
    assert card["loops"][-1]["state"] == "committed"
    home = priya("get_student_home")
    assert home["hours"]["scheduled"] == 20
    assert not any(s["day"] == SAT for s in home["shifts"])
    assert "Priya" in cells(dining)[(WED, 15 * H)]


def test_manager_copilot_and_privacy(login):
    dining = login("dining@demo.edu", "department")
    r = dining("copilot_command", text="Can Priya work Wednesday 12 to 3?")
    assert r["card"]["result"] == {"available": False, "reason": "schedule_conflict", "suggestions": []}
    assert r["reply"] == "Can't schedule Priya on Wed 12:00–15:00."
    r = dining("copilot_command", text="Add 3 hours for Priya on Thursday")
    assert r["card"]["result"] == {"available": False, "reason": "hour_limit", "hours_left": 0}
    r = dining("copilot_command", text="Who can cover Saturday 3 to 7?")
    assert r["card"]["type"] == "people" and r["card"]["people"] == []
    r = dining("copilot_command", text="schedule Ana on Wednesday 11 to 3")
    assert r["card"]["assigned"] is True
    assert dining("copilot_command", text="how is coverage?")["reply"].startswith("15 of 24")
    tick()
    dining("get_dashboard"), dining("get_approvals"), dining("get_agent_feed")
    blob = "\n".join(dining.raw)
    for secret in ("CSE", "Research", "STAT", "5243"):
        assert secret not in blob, f"leaked {secret!r}"


def test_student_copilot_raises_cover_from_plain_english(login):
    tick()
    priya = login("priya@demo.edu")
    r = priya("student_command", text="I can't do Saturday this week, Wednesday works")
    assert "found a swap" in r["reply"]
    assert any(row["result"].startswith("searching 3-person loops · found") for row in r["trace"])
    assert priya("student_command", text="How many hours do I have left?")["reply"].startswith("You're at 20 of 20")


def test_needs_agent_and_google_event_conversion(login):
    dining = login("dining@demo.edu", "department")
    r = dining("generate_needs", description="Library front desk, open 8am to 8pm on weekdays")
    assert r["needs"] and all(n["start"] < n["end"] for n in r["needs"])
    blocks = google_events_to_blocks([
        {"summary": "Dentist", "start": {"dateTime": "2026-10-02T14:00:00-04:00"}, "end": {"dateTime": "2026-10-02T16:00:00-04:00"}},
        {"summary": "Holiday", "start": {"date": "2026-10-03"}, "end": {"date": "2026-10-04"}},
        {"summary": "Free time", "transparency": "transparent", "start": {"dateTime": "2026-10-01T10:00:00Z"}, "end": {"dateTime": "2026-10-01T11:00:00Z"}},
    ])
    assert blocks == [{"day": 4, "start": 14 * H, "end": 16 * H, "title": "Dentist", "week": "2026-09-28"}]
