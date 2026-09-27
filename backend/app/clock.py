"""One source of "now". Everything time-based (alerts, time reporting, the current week) reads it,
so tests and the /demo control room can move time without touching the system clock."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

try:  # Windows needs the tzdata package for zoneinfo
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover
    ZoneInfo = None  # type: ignore

from . import config

_offset = timedelta(0)  # demo/test time travel


def utcnow() -> datetime:
    """Naive UTC (what the database stores)."""
    return datetime.utcnow() + _offset


def tz(name: str | None = None):
    if ZoneInfo is None:
        return timezone.utc
    try:
        return ZoneInfo(name or config.TIMEZONE)
    except Exception:
        return ZoneInfo(config.TIMEZONE)


def now_local(tzname: str | None = None) -> datetime:
    """Aware datetime in the given (or default) time zone."""
    return utcnow().replace(tzinfo=timezone.utc).astimezone(tz(tzname))


def today_local(tzname: str | None = None) -> date:
    return now_local(tzname).date()


def monday(d: date) -> date:
    return d - timedelta(days=d.weekday())


def current_week(tzname: str | None = None) -> str:
    return monday(today_local(tzname)).isoformat()


def default_week(tzname: str | None = None) -> str:
    """The week screens open on: this week, but never before the demo week."""
    return max(monday(today_local(tzname)), config.DEFAULT_WEEK).isoformat()


def slot_datetime(week: str, day: int, minutes: int, tzname: str | None = None) -> datetime:
    """Aware local datetime for a (week, day, minutes-from-midnight) slot."""
    d = date.fromisoformat(week) + timedelta(days=day)
    base = datetime(d.year, d.month, d.day, tzinfo=tz(tzname))
    return base + timedelta(minutes=minutes)


def to_utc_naive(dt: datetime) -> datetime:
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


def travel(delta: timedelta) -> None:
    global _offset
    _offset += delta


def travel_to(target_utc_naive: datetime) -> None:
    global _offset
    _offset = target_utc_naive - datetime.utcnow()


def reset() -> None:
    global _offset
    _offset = timedelta(0)


def offset() -> timedelta:
    return _offset
