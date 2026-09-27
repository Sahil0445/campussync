"""Walker registry. Each walker maps 1:1 to a Jac walker exposed by `jac serve` (POST /walker/<name>).

Privacy is enforced HERE, in what walkers return — never in the frontend.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from sqlalchemy.orm import Session

from .. import clock
from ..models import Department, Student, User
from ..timeutil import week_key


class WalkerError(Exception):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.message = message
        self.status = status


@dataclass
class Ctx:
    db: Session
    user: User | None
    body: dict

    @property
    def student(self) -> Student:
        if not self.user or self.user.role != "student" or not self.user.student_id:
            raise WalkerError("Employees only.", 403)
        return self.db.get(Student, self.user.student_id)

    @property
    def department(self) -> Department:
        if not self.user or self.user.role != "department" or not self.user.department_id:
            raise WalkerError("Employers only.", 403)
        return self.db.get(Department, self.user.department_id)

    @property
    def week(self) -> str:
        try:
            return week_key(self.body.get("week"), clock.monday(clock.today_local())) if self.body.get("week") else clock.default_week()
        except ValueError:
            raise WalkerError("That week isn't a valid date.")

    def get(self, key: str, default: Any = None) -> Any:
        return self.body.get(key, default)

    def need(self, key: str, kind: type = str) -> Any:
        if key not in self.body or self.body[key] in (None, ""):
            raise WalkerError(f"Missing {key.replace('_', ' ')}.")
        try:
            return kind(self.body[key])
        except (TypeError, ValueError):
            raise WalkerError(f"{key.replace('_', ' ').capitalize()} isn't valid.")


REGISTRY: dict[str, tuple[Callable[[Ctx], Any], str]] = {}


def walker(role: str = "any", name: str | None = None):
    """role: public | student | department | any"""

    def deco(fn: Callable[[Ctx], Any]):
        REGISTRY[name or fn.__name__] = (fn, role)
        return fn

    return deco
