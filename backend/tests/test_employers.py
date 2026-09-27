"""Employers, employees, join codes, roles, pay — the multi-organization model."""
H = 60


def test_employer_signup_gets_join_code_and_employee_joins(signup, login):
    boss, reg = signup("register_employer", organization="Night Owl Security", kind="business", name="Rosa Park",
                       email="rosa@nightowl.com", password="supersecret", timezone="America/Chicago")
    code = reg["join_code"]
    assert code.startswith("NOS-") and len(code) == 8
    org = boss("get_org")
    assert org["kind"] == "business" and org["timezone"] == "America/Chicago" and org["default_pay_rate"] == 15
    # lookup is public and case/format insensitive
    card = guard_lookup = boss.client.post("/walker/lookup_join_code", json={"code": code.lower().replace("-", " ")}).json()["reports"][0]
    assert card["name"] == "Night Owl Security" and card["university"] is None

    guard, g = signup("register_employee", name="Sam Guard", email="sam@nightowl.com", password="supersecret", kind="worker", code=code)
    assert g["employer"]["name"] == "Night Owl Security"
    team = boss("get_team")["people"]
    assert [p["name"] for p in team] == ["Sam Guard"] and team[0]["pay_rate"] == 15 and team[0]["hours"] == 40
    me = guard("whoami")["student"]
    assert me["kind"] == "worker" and me["international"] is False and me["cap"] == 60
    assert any("joined" in n["text"] for n in boss("get_notifications")["items"])


def test_regular_employee_can_only_have_one_employer(signup):
    _, a = signup("register_employer", organization="Alpha Guards", kind="business", name="A", email="a@a.com", password="supersecret")
    _, b = signup("register_employer", organization="Beta Guards", kind="business", name="B", email="b@b.com", password="supersecret")
    worker, _ = signup("register_employee", name="Wes Worker", email="wes@x.com", password="supersecret", kind="worker", code=a["join_code"])
    r = worker("join_employer", expect=400, code=b["join_code"])
    assert "one employer at a time" in r["error"]
    assert worker("get_my_employers")["can_join_more"] is False
    # after leaving, joining the other works
    worker("leave_employer", department_id=a["department_id"])
    worker("join_employer", code=b["join_code"])
    assert [e["name"] for e in worker("get_my_employers")["employers"]] == ["Beta Guards"]


def test_students_join_many_employers_but_only_at_their_university(signup, login):
    # Northfield (seeded) codes: DINE-2026, CSE-2026. Another campus employer at a different university:
    _, other = signup("register_employer", organization="Lakeside Library", kind="campus", university="Lakeside College",
                      name="L", email="lib@lakeside.edu", password="supersecret")
    _, biz = signup("register_employer", organization="Corner Cafe", kind="business", name="C", email="c@cafe.com", password="supersecret")
    stu, _ = signup("register_employee", name="Nia Student", email="nia@northfield.edu", password="supersecret", kind="student",
                    status="international", code="DINE-2026")
    stu("join_employer", code="CSE-2026")
    assert sorted(e["name"] for e in stu("get_my_employers")["employers"]) == ["CSE Research", "Campus Dining"]
    r = stu("join_employer", expect=400, code=other["join_code"])
    assert "Lakeside College" in r["error"]
    r = stu("join_employer", expect=400, code=biz["join_code"])
    assert "business" in r["error"]
    # A student can't sign up straight into a business either
    _, err = signup("register_employee", expect=400, name="X Y", email="xy@x.com", password="supersecret", kind="student", code=biz["join_code"])
    assert "business" in err["error"]
    # bad code
    _, err = signup("register_employee", expect=400, name="X Y", email="xy@x.com", password="supersecret", kind="worker", code="NOPE-0000")
    assert "join code" in err["error"]


def test_roles_restrict_scheduling_and_pay_rate_edits(login):
    shield = login("shield@demo.com", "department")
    org = shield("get_org")
    roles = {p["name"]: p["id"] for p in org["positions"]}
    team = {p["name"]: p for p in shield("get_team")["people"]}
    tom = team["Tom Alvarez"]
    assert tom["positions"] == [roles["Site guard"]]
    # Tom doesn't hold Night patrol -> assigning him to a patrol shift is refused with a clear reason
    r = shield("assign_shift", expect=400, student_id=tom["student_id"], day=2, start=18 * H, end=24 * H, position_id=roles["Night patrol"])
    assert "Night patrol" in r["error"]
    # give him the role; now the rules (not the role) decide
    shield("update_member", student_id=tom["student_id"], positions=[roles["Site guard"], roles["Night patrol"]], pay_rate=18.5, hours=48)
    t2 = {p["name"]: p for p in shield("get_team")["people"]}["Tom Alvarez"]
    assert t2["pay_rate"] == 18.5 and len(t2["positions"]) == 2
    tom_api = login("tom@demo.com")
    assert any("18.50" in n["text"] for n in tom_api("get_notifications")["items"])
    # 12 h/day limit for regular employees: a 7–19 post plus an evening patrol the same day is refused
    shield("assign_shift", student_id=tom["student_id"], day=0, start=7 * H, end=19 * H, position_id=roles["Site guard"], week="2026-10-05")
    r = shield("assign_shift", student_id=tom["student_id"], day=0, start=19 * H + 30, end=23 * H, position_id=roles["Night patrol"], week="2026-10-05")
    assert r["available"] is False and r["reason"] == "schedule_conflict"


def test_autopilot_draft_respects_roles(login):
    from app.db import SessionLocal
    from app.services import autopilot

    with SessionLocal() as db:
        autopilot.tick(db)
    shield = login("shield@demo.com", "department")
    items = [i for i in shield("get_approvals")["items"] if i["type"] == "draft"]
    assert len(items) == 1
    d = shield("get_draft", draft_id=items[0]["id"])
    roles = {p["id"]: p["name"] for p in shield("get_org")["positions"]}
    team = {p["name"].split()[0]: set(p["positions"]) for p in shield("get_team")["people"]}
    for c in d["coverage"]["cells"]:
        for person in c["people"]:
            assert c["position_id"] in team[person["name"]], f"{person['name']} got a {roles[c['position_id']]} shift"
    # Diego only patrols, Tom only guards
    names_by_role = {}
    for c in d["coverage"]["cells"]:
        names_by_role.setdefault(c["role"], set()).update(p["name"] for p in c["people"])
    assert "Diego" not in names_by_role.get("Site guard", set())
    assert "Tom" not in names_by_role.get("Night patrol", set())


def test_org_settings_validation_and_code_regeneration(login):
    dining = login("dining@demo.edu", "department")
    old = dining("get_org")["join_code"]
    new = dining("regenerate_join_code")["join_code"]
    assert new != old and new.startswith("CD-")
    r = dining("update_org", expect=400, default_pay_rate=-1)
    assert "between" in r["error"]
    out = dining("update_org", default_pay_rate=16.25, apply_to_team=True, state_tax_pct=5)
    assert out["default_pay_rate"] == 16.25 and out["state_tax_pct"] == 5
    assert all(p["pay_rate"] == 16.25 for p in dining("get_team")["people"])
    dining("save_position", name="Barista")
    r = dining("save_position", expect=400, name="barista")
    assert "already" in r["error"]
    pid = next(p["id"] for p in dining("get_org")["positions"] if p["name"] == "Barista")
    dining("delete_position", id=pid)
    assert "Barista" not in [p["name"] for p in dining("get_org")["positions"]]


def test_business_cannot_search_or_invite_outside_team(login):
    shield = login("shield@demo.com", "department")
    r = shield("search_students", query="Priya")
    assert r["results"] == [] and r["join_code_only"] is True
    dining = login("dining@demo.edu", "department")
    priya = next(p for p in dining("get_team")["people"] if p["name"].startswith("Priya"))
    r = shield("invite_student", expect=400, student_id=priya["student_id"], hours=10)
    assert "join code" in r["error"]


def test_employer_removes_member_and_shifts_reopen(login):
    dining = login("dining@demo.edu", "department")
    marcus = next(p for p in dining("get_team")["people"] if p["name"].startswith("Marcus"))
    r = dining("remove_member", student_id=marcus["student_id"])
    assert r["released"] == 3
    cov = dining("get_coverage")
    assert all("Marcus" not in [p["name"] for p in c["people"]] for c in cov["cells"])
    assert "Marcus Lee" not in [p["name"] for p in dining("get_team")["people"]]


def test_business_copilot_cannot_reach_outside_team_and_cover_respects_roles(login):
    shield = login("shield@demo.com", "department")
    r = shield("copilot_command", text="Invite Priya for 10 hours")
    assert "Invited" not in r["reply"] and "Priya" not in r["reply"]
    assert "Priya Nair" not in [p["name"] for p in shield("get_team")["people"]]
    r = shield("copilot_command", text="Who can cover Monday 6pm to midnight?", week="2026-10-05")
    names = {p["name"] for p in r.get("card", {}).get("people", [])}
    assert names and "Tom Alvarez" not in names  # Tom holds only Site guard; the slot is the Night patrol post
    assert names <= {"Aisha Khan", "Diego Santos", "Grace Liu"}


def test_copilot_assign_books_the_slot_role(login):
    shield = login("shield@demo.com", "department")
    r = shield("copilot_command", text="Put Diego on Monday 6pm to midnight", week="2026-10-05")
    assert r["card"]["assigned"] is True
    cov = shield("get_coverage", week="2026-10-05")
    cell = next(c for c in cov["cells"] if (c["day"], c["start"], c["end"]) == (0, 18 * 60, 24 * 60))
    assert cell["role"] == "Night patrol" and [p["name"] for p in cell["people"]] == ["Diego"]
