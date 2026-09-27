"""Gemini client (Generative Language REST API) with model failover and a hard fallback.

Every caller must handle `None` — that is the deterministic-fallback path. The demo never
depends on the network:
  * 503 / 429 / 500 (model busy)  -> one quick retry, then the next model in GEMINI_FALLBACK_MODELS
  * 404 (model not available)     -> next model
  * every model failing           -> built-in heuristics, and AI is skipped for a short cool-down
                                     so screens stay instant instead of waiting on a busy API
The model that answered last is tried first next time.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time

import httpx

from .. import config

log = logging.getLogger("campussync.llm")

_RETRYABLE = {429, 500, 502, 503, 504}
_COOLDOWN_SECONDS = 45


class LLM:
    def __init__(self) -> None:
        self.last_error: str | None = None
        self.last_model: str | None = None
        self._preferred: str | None = None
        self._cooldown_until = 0.0
        self._lock = threading.Lock()

    @property
    def enabled(self) -> bool:
        return bool(config.GEMINI_API_KEY)

    def models(self) -> list[str]:
        chain = [config.GEMINI_MODEL] + [m.strip() for m in config.GEMINI_FALLBACK_MODELS.split(",") if m.strip()]
        seen: list[str] = []
        for m in ([self._preferred] if self._preferred else []) + chain:
            if m and m not in seen:
                seen.append(m)
        return seen

    def json(self, system: str, prompt: str) -> dict | list | None:
        """Ask Gemini for a JSON answer. Returns None on any failure (callers fall back)."""
        if not self.enabled or time.time() < self._cooldown_until:
            return None
        errors = []
        for model in self.models():
            for attempt in range(2):
                status, data, err = self._call(model, system, prompt)
                if data is not None:
                    with self._lock:
                        self._preferred, self.last_model, self.last_error = model, model, None
                    return data
                errors.append(f"{model}: {err}")
                if status in (401, 403):
                    self._fail(errors, cooldown=300)  # bad key: stop trying for a while
                    return None
                if status in _RETRYABLE and attempt == 0:
                    time.sleep(0.6)
                    continue
                break  # 404 / parse error / second failure -> next model
        self._fail(errors, cooldown=_COOLDOWN_SECONDS)
        return None

    def _fail(self, errors: list[str], cooldown: float) -> None:
        with self._lock:
            self.last_error = " | ".join(errors)[-400:]
            self._cooldown_until = time.time() + cooldown
        log.warning("Gemini unavailable (%s) — using built-in heuristics for %ss", self.last_error, int(cooldown))

    def _call(self, model: str, system: str, prompt: str) -> tuple[int | None, dict | list | None, str]:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        body = {
            "system_instruction": {"parts": [{"text": system}]},
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json", "temperature": 0.2},
        }
        try:
            resp = httpx.post(url, json=body, headers={"x-goog-api-key": config.GEMINI_API_KEY}, timeout=config.AI_TIMEOUT_SECONDS)
        except Exception as exc:
            return None, None, type(exc).__name__
        if resp.status_code != 200:
            return resp.status_code, None, f"HTTP {resp.status_code}"
        try:
            text = resp.json()["candidates"][0]["content"]["parts"][0]["text"]
            return 200, _loads(text), ""
        except Exception as exc:
            return 200, None, f"bad response ({type(exc).__name__})"


def _loads(text: str):
    text = text.strip()
    fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.S)
    if fence:
        text = fence.group(1)
    return json.loads(text)


llm = LLM()
