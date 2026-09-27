"""Agent event log — the live feed on Mission Control and in the student app."""
from __future__ import annotations

from sqlalchemy.orm import Session

from .models import AgentEvent


def log(db: Session, agent: str, text: str, *, kind: str = "agent", department_id: int | None = None,
        student_id: int | None = None, level: str = "info", link: str = "") -> None:
    """department_id events are shown to that department only; text must never name another department.
    student_id events are shown to that student only."""
    db.add(AgentEvent(agent=agent, kind=kind, text=text[:400], department_id=department_id,
                      student_id=student_id, level=level, link=link))
