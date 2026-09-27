"""Agent Activity trace. Every workflow returns one; the UI replays it row by row."""

obj Trace {
    has rows: list[dict[str, any]] = [],
        fallback_used: bool = False;

    """kind: 'agent' (AI agent) or 'rules' (deterministic code). ai=False marks an agent step that ran
    on its built-in heuristic because the model was unavailable."""
    def step(agent: str, kind: str, result: str, status: str = "done", ai: bool | None = None) {
        row: dict[str, any] = {"agent": agent, "kind": kind, "result": result, "status": status};
        if ai is not None {
            row["ai"] = ai;
            if not ai {
                self.fallback_used = True;
            }
        }
        self.rows.append(row);
    }

    def final(text: str, ok: bool = True) -> list[dict[str, any]] {
        self.rows.append(
            {"agent": "", "kind": "final", "result": text, "status": "done" if ok else "blocked"}
        );
        return self.rows;
    }
}
