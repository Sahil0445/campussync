"""The AI path, with Gemini mocked: a model proposal that breaks a hard rule must be removed by code."""
from app.agents import llm as llm_mod


def test_ai_proposal_is_validated_by_rules(login, monkeypatch):
    dining = login("dining@demo.edu", "department")
    priya = next(p["student_id"] for p in dining("get_team")["people"] if p["name"].startswith("Priya"))
    ana = next(p["student_id"] for p in dining("get_team")["people"] if p["name"].startswith("Ana"))

    def fake(system, prompt):
        if "Scheduling Agent" in system:
            # Priya is at 20/20 and has a hidden conflict Wed 10-14: the rules must reject her.
            return {"assignments": {"2-660-900-0": [priya, ana]}, "notes": {str(ana): "Wants more afternoon hours"}}
        if "Explainer" in system:
            return {"why": "Sam takes Saturday, Marcus takes Thursday, Priya gets Wednesday. Nobody's hours change."}
        return None

    monkeypatch.setattr(llm_mod.LLM, "enabled", property(lambda self: True))
    monkeypatch.setattr(llm_mod.llm, "json", fake)

    d = dining("generate_schedule")
    compliance = next(r for r in d["trace"] if r["agent"] == "Compliance Checker")
    assert compliance["result"].startswith("removed 1 assignment")
    assert d["summary"]["filled"] == 22 and d["summary"]["ai"] is True
    assert next(s for s in d["summary"]["students"] if s["student_id"] == ana)["why"] == "Wants more afternoon hours"
    wed = next(c for c in d["coverage"]["cells"] if (c["day"], c["start"]) == (2, 660))
    assert "Priya" not in [p["name"] for p in wed["people"]]


def test_note_parsing_uses_ai_when_available(login, monkeypatch):
    monkeypatch.setattr(llm_mod.LLM, "enabled", property(lambda self: True))
    monkeypatch.setattr(llm_mod.llm, "json", lambda s, p: {"rules": [{"days": [4], "start": "00:00", "end": "10:00"}]})
    me = login("mia@demo.edu")
    r = me("parse_availability_note", note="Fridays I have a lab until ten")
    assert r["ai"] is True and [x["label"] for x in r["rules"]] == ["Unavailable Fri before 10:00"]
