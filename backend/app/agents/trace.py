"""Agent Activity trace. Every workflow returns one; the UI replays it 400ms per row."""
from __future__ import annotations


class Trace:
    def __init__(self) -> None:
        self.rows: list[dict] = []
        self.fallback_used = False

    def step(self, agent: str, kind: str, result: str, status: str = "done", ai: bool | None = None) -> None:
        """kind: 'agent' (AI agent) or 'rules' (deterministic code). ai=False marks an agent step that
        ran on its built-in heuristic because the model was unavailable."""
        row = {"agent": agent, "kind": kind, "result": result, "status": status}
        if ai is not None:
            row["ai"] = ai
            if not ai:
                self.fallback_used = True
        self.rows.append(row)

    def final(self, text: str, ok: bool = True) -> list[dict]:
        self.rows.append({"agent": "", "kind": "final", "result": text, "status": "done" if ok else "blocked"})
        return self.rows
