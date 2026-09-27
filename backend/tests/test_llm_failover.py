"""Gemini busy (503) -> retry -> next model -> fallback with cool-down."""
import httpx

from app import config
from app.agents import llm as llm_mod


class Resp:
    def __init__(self, status, text=None):
        self.status_code = status
        self._text = text

    def json(self):
        return {"candidates": [{"content": {"parts": [{"text": self._text}]}}]}


def test_busy_model_fails_over_to_backup(monkeypatch):
    calls = []

    def fake_post(url, **kw):
        model = url.split("/models/")[1].split(":")[0]
        calls.append(model)
        return Resp(503) if model == "gemini-3.5-flash" else Resp(200, '{"ok": true}')

    monkeypatch.setattr(config, "GEMINI_API_KEY", "k")
    monkeypatch.setattr(config, "GEMINI_MODEL", "gemini-3.5-flash")
    monkeypatch.setattr(config, "GEMINI_FALLBACK_MODELS", "gemini-3.5-flash-lite")
    monkeypatch.setattr(httpx, "post", fake_post)
    monkeypatch.setattr(llm_mod.time, "sleep", lambda s: None)
    c = llm_mod.LLM()
    assert c.json("s", "p") == {"ok": True}
    assert calls == ["gemini-3.5-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite"]
    calls.clear()
    assert c.json("s", "p") == {"ok": True}  # remembers the model that worked
    assert calls == ["gemini-3.5-flash-lite"]


def test_all_busy_falls_back_and_cools_down(monkeypatch):
    calls = []
    monkeypatch.setattr(config, "GEMINI_API_KEY", "k")
    monkeypatch.setattr(config, "GEMINI_FALLBACK_MODELS", "m2")
    monkeypatch.setattr(httpx, "post", lambda url, **kw: calls.append(url) or Resp(503))
    monkeypatch.setattr(llm_mod.time, "sleep", lambda s: None)
    c = llm_mod.LLM()
    assert c.json("s", "p") is None and "503" in c.last_error
    n = len(calls)
    assert c.json("s", "p") is None and len(calls) == n  # cool-down: no waiting on a busy API
