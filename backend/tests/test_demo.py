"""The demo script (section 10) and definition of done (section 18), end to end through the API."""

WED, THU, SAT = 2, 3, 5
H = 60


def names(dining, day, start, end):
    cov = dining("get_coverage")
    cell = next(c for c in cov["cells"] if (c["day"], c["start"], c["end"]) == (day, start, end))
    return sorted(p["name"] for p in cell["people"])


def student_id(dining, first):
    return next(p["student_id"] for p in dining("get_team")["people"] if p["name"].startswith(first))


def test_act1_blind_conflict_and_hour_ceiling(login):
    dining = login("dining@demo.edu", "department")
    priya = student_id(dining, "Priya")

    r = dining("check_assignment", student_id=priya, day=WED, start=12 * H, end=15 * H)
    assert set(r) == {"available", "reason", "suggestions"}
    assert r["available"] is False and r["reason"] == "schedule_conflict"

    r = dining("check_assignment", student_id=priya, day=THU, start=12 * H, end=15 * H)
    assert r == {"available": False, "reason": "hour_limit", "hours_left": 0}

    people = {p["name"]: p for p in dining("get_team")["people"]}
    assert people["Priya Nair"]["can_still_schedule"] == 0

    me = login("priya@demo.edu")("get_student_home")
    assert me["hours"]["scheduled"] == 20 and me["hours"]["limit"] == 20
    assert {j["department"] for j in me["hours"]["by_job"]} == {"CSE Research", "Campus Dining"}


def test_act2_generate_flags_saturday_gap_and_publishes(login):
    dining = login("dining@demo.edu", "department")
    before = dining("get_coverage")["stats"]
    assert before["filled"] == 14 and before["needed"] == 24

    d = dining("generate_schedule")
    s = d["summary"]
    assert (s["filled"], s["needed"]) == (22, 24)
    assert [(g["label"], g["found"]) for g in s["gaps"]] == [("Sat 15:00–19:00", 0)]
    assert s["gaps"][0]["reason"] == "Everyone available is at their weekly limit."
    agents = [row["agent"] for row in d["trace"] if row["kind"] != "final"]
    assert agents == ["Coordinator", "Availability Agent", "Conflict Agent", "Compliance Checker", "Scheduling Agent", "Explainer"]
    assert {row["kind"] for row in d["trace"]} == {"agent", "rules", "final"}

    r = dining("publish_schedule", draft_id=d["draft_id"])
    assert r["dropped"] == 0 and r["notified"] >= 1
    after = dining("get_coverage")["stats"]
    assert after["filled"] == 22

    # Priya never goes past 20 by any path
    assert login("priya@demo.edu")("get_student_home")["hours"]["scheduled"] == 20


def run_swap_demo(login, generate_first: bool):
    dining = login("dining@demo.edu", "department")
    if generate_first:
        d = dining("generate_schedule")
        dining("publish_schedule", draft_id=d["draft_id"])

    priya = login("priya@demo.edu")
    sat = next(s for s in priya("get_student_home")["shifts"] if s["day"] == SAT)
    req = priya("request_swap", shift_id=sat["id"], want_kind="days", want_days=[WED], reason="Family visiting")
    assert req["state"] == "awaiting_manager"
    trace = [r["result"] for r in req["trace"]]
    assert "direct swap · none found" in trace and "searching 3-person loops · found 1" in trace

    card = dining("get_swap_request", request_id=req["request_id"])
    loop1 = card["loops"][-1]
    assert loop1["headline"] == "3-person swap · everyone stays within limits"
    assert [(m["name"], m["gives"], m["gets"]) for m in loop1["moves"]] == [
        ("Priya", "Sat 11:00–15:00", "Wed 15:00–19:00"),
        ("Sam", "Thu 11:00–15:00", "Sat 11:00–15:00"),
        ("Marcus", "Wed 15:00–19:00", "Thu 11:00–15:00"),
    ]
    assert all(m["hrs_before"] == m["hrs_after"] for m in loop1["moves"])
    assert loop1["alternatives"] and "4-person" in loop1["alternatives"][0]["summary"]

    card = dining("approve_swap", loop_id=loop1["loop_id"])
    # Priya asked for Wednesday and Sam is open to Saturdays: their autopilots accept. Only Marcus is asked.
    states = {p["name"]: (p["state"], p["auto"]) for p in card["loops"][-1]["participants"]}
    assert states == {"Priya": ("accepted", "auto_accept"), "Sam": ("accepted", "auto_accept"), "Marcus": ("waiting", "")}
    sam, marcus = login("sam@demo.edu"), login("marcus@demo.edu")
    assert priya("get_student_home")["offers"] == [] and sam("get_student_home")["offers"] == []
    offer = lambda api: api("get_student_home")["offers"][0]["offer_id"]  # noqa: E731
    snapshot = {s["id"]: s for s in sam("get_student_home")["shifts"]}
    marcus("respond_offer", offer_id=offer(marcus), accept=False, reason_chip="A different day",
           reason_text="Thursday doesn't work for me anymore.")
    # Nothing changed for anyone
    assert {s["id"] for s in sam("get_student_home")["shifts"]} == set(snapshot)

    card = dining("get_swap_request", request_id=req["request_id"])
    old, new = card["loops"][-2], card["loops"][-1]
    assert old["state"] == "declined" and old["declined_by"] == "Marcus"
    assert new["state"] == "proposed" and new["headline"] == "4-person swap · everyone stays within limits"
    assert [m["name"] for m in new["moves"]] == ["Priya", "Sam", "Leo", "Dana"]

    card = dining("approve_swap", loop_id=new["loop_id"])
    final = card["loops"][-1]
    # Priya and Sam already agreed to identical moves; Leo and Dana auto-accept their open days.
    assert final["state"] == "committed", final
    assert {p["auto"] for p in final["participants"]} == {"carried", "auto_accept"}

    home = priya("get_student_home")
    assert home["hours"]["scheduled"] == 20
    assert any(s["day"] == WED and s["start"] == 15 * H and s["department"] == "Campus Dining" for s in home["shifts"])
    assert not any(s["day"] == SAT for s in home["shifts"])
    assert names(dining, SAT, 11 * H, 15 * H)[0:1] and "Sam" in names(dining, SAT, 11 * H, 15 * H)
    assert "Leo" in names(dining, THU, 11 * H, 15 * H)
    assert "Dana" in names(dining, 4, 15 * H, 19 * H)
    assert "Priya" in names(dining, WED, 15 * H, 19 * H)
    return dining


def test_act3_swap_loop_decline_replan_commit(login):
    run_swap_demo(login, generate_first=False)


def test_full_demo_in_order_and_no_cse_leak(login):
    dining = login("dining@demo.edu", "department")
    priya_id = student_id(dining, "Priya")
    dining("check_assignment", student_id=priya_id, day=WED, start=12 * H, end=15 * H)
    dining("check_assignment", student_id=priya_id, day=THU, start=12 * H, end=15 * H)
    dining = run_swap_demo(login, generate_first=True)
    for name, body in [("get_coverage", {}), ("get_people", {}), ("get_team", {}), ("get_org", {}), ("get_timesheets", {}), ("search_students", {"query": "priya"}),
                       ("get_requests", {}), ("get_notifications", {}), ("get_staffing_needs", {}),
                       ("get_slot", {"day": 0, "start": 11 * H, "end": 15 * H}),
                       ("find_someone_else", {"day": WED, "start": 12 * H, "end": 15 * H})]:
        dining(name, **body)
    blob = "\n".join(dining.raw)
    for secret in ("CSE", "Research", "10:00–14:00", "STAT", "5243"):
        assert secret not in blob, f"leaked {secret!r} to Campus Dining"


def test_decline_without_replan_option_leaves_everything_unchanged(login):
    dining = login("dining@demo.edu", "department")
    priya = login("priya@demo.edu")
    sam = login("sam@demo.edu")
    sam("update_profile", autopilot=False)
    sat = next(s for s in priya("get_student_home")["shifts"] if s["day"] == SAT)
    req = priya("request_swap", shift_id=sat["id"], want_kind="days", want_days=[WED])
    loop = dining("get_swap_request", request_id=req["request_id"])["loops"][-1]
    dining("approve_swap", loop_id=loop["loop_id"])
    before = dining("get_coverage")["cells"]
    sam("respond_offer", offer_id=sam("get_student_home")["offers"][0]["offer_id"], accept=False)
    after = dining("get_coverage")["cells"]
    strip = lambda cells: [(c["day"], c["start"], sorted(p["name"] for p in c["people"])) for c in cells]  # noqa: E731
    assert strip(before) == strip(after)
    # Sam is excluded, so no loop exists any more (every loop needs Sam to take Saturday)
    assert priya("get_my_request", request_id=req["request_id"])["state"] == "searching"


def test_manual_assign_cannot_break_cap_and_probe_limit(login):
    dining = login("dining@demo.edu", "department")
    priya = student_id(dining, "Priya")
    r = dining("assign_shift", student_id=priya, day=THU, start=15 * H, end=19 * H)
    assert r["available"] is False and r["reason"] == "hour_limit"
    for _ in range(20):
        dining("check_assignment", student_id=priya, day=THU, start=15 * H, end=19 * H)
    dining("check_assignment", expect=429, student_id=priya, day=THU, start=15 * H, end=19 * H)


def test_signup_ics_note_and_invite_flow(login, client):
    # A student signs up with CSE Research's join code, then Campus Dining (same university) invites them.
    r = client.post("/walker/register_employee", json={"name": "Test Person", "email": "t@demo.edu", "password": "longpassword",
                                                       "code": "cse-2026", "kind": "student", "status": "international"})
    assert r.status_code == 200, r.text
    token = r.json()["reports"][0]["token"]
    h = {"Authorization": f"Bearer {token}"}
    call = lambda n, **b: client.post(f"/walker/{n}", json=b, headers=h).json()["reports"][0]  # noqa: E731
    imp = call("import_calendar", sample=True)
    assert imp["count"] == 4 and len(imp["blocks"]) >= 8
    note = call("parse_availability_note", note="No Fridays before 10 AM — I have lab.")
    assert [x["label"] for x in note["rules"]] == ["Unavailable Fri before 10:00"]
    home = call("get_student_home")
    assert home["hours"]["limit"] == 20  # international forced to 20
    assert [j["department"] for j in home["jobs"]] == ["CSE Research"]

    dining = login("dining@demo.edu", "department")
    found = dining("search_students", query="Test")["results"][0]
    assert set(found) == {"student_id", "name", "email", "status", "can_take_more_hrs", "team_state"}
    dining("invite_student", student_id=found["student_id"], hours=10)
    inv = call("get_student_home")["invites"][0]
    call("respond_invite", employment_id=inv["employment_id"], accept=True)
    assert sorted(j["department"] for j in call("get_student_home")["jobs"]) == ["CSE Research", "Campus Dining"]
