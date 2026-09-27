"""Time helpers. Times are minutes from midnight; days are 0=Mon .. 6=Sun."""
from __future__ import annotations

from datetime import date, timedelta

DAY_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
DAY_LONG = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


def hm(minutes: int) -> str:
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def parse_hm(text: str) -> int:
    h, _, m = text.strip().partition(":")
    return int(h) * 60 + int(m or 0)


def slot_label(day: int, start: int, end: int) -> str:
    return f"{DAY_SHORT[day]} {hm(start)}–{hm(end)}"


def hours(start: int, end: int) -> float:
    return (end - start) / 60


def overlaps(a_start: int, a_end: int, b_start: int, b_end: int) -> bool:
    return a_start < b_end and b_start < a_end


def monday_of(d: date) -> date:
    return d - timedelta(days=d.weekday())


def week_key(d: date | str | None, default: date) -> str:
    if d is None or d == "":
        return default.isoformat()
    if isinstance(d, str):
        d = date.fromisoformat(d)
    return monday_of(d).isoformat()


def fmt_hours(h: float) -> str:
    return str(int(h)) if float(h).is_integer() else f"{h:.1f}"
