"""One source of "now". Everything time-based (alerts, time reporting, the current week) reads it,
so tests and the demo control room can move time without touching the system clock."""

import from datetime { date, datetime, timedelta, timezone, tzinfo }
import from zoneinfo { ZoneInfo }
import from server.config { TIMEZONE, DEFAULT_WEEK }

glob _offset: timedelta = timedelta(0);

"""Naive UTC (what the graph stores)."""
def utcnow() -> datetime {
    return datetime.now(timezone.utc).replace(tzinfo=None) + _offset;
}

def tz(name: str = "") -> tzinfo {
    try {
        return ZoneInfo(name or TIMEZONE);
    } except Exception {
        return ZoneInfo(TIMEZONE);
    }
}

"""Aware datetime in the given (or default) time zone."""
def now_local(tzname: str = "") -> datetime {
    return utcnow().replace(tzinfo=timezone.utc).astimezone(tz(tzname));
}

def today_local(tzname: str = "") -> date {
    return now_local(tzname).date();
}

def monday(d: date) -> date {
    return d - timedelta(days=d.weekday());
}

def current_week(tzname: str = "") -> str {
    return monday(today_local(tzname)).isoformat();
}

"""The week screens open on: this week, but never before the demo week."""
def default_week(tzname: str = "") -> str {
    return max(monday(today_local(tzname)), DEFAULT_WEEK).isoformat();
}

"""Aware local datetime for a (week, day, minutes-from-midnight) slot."""
def slot_datetime(week: str, day: int, minutes: int, tzname: str = "") -> datetime {
    d = date.fromisoformat(week) + timedelta(days=day);
    base = datetime(d.year, d.month, d.day, tzinfo=tz(tzname));
    return base + timedelta(minutes=minutes);
}

def to_utc_naive(dt: datetime) -> datetime {
    return dt.astimezone(timezone.utc).replace(tzinfo=None);
}

def travel(delta: timedelta) {
    _offset = _offset + delta;
}

def travel_to(target_utc_naive: datetime) {
    _offset = target_utc_naive - datetime.now(timezone.utc).replace(tzinfo=None);
}

def reset_clock {
    _offset = timedelta(0);
}

def offset() -> timedelta {
    return _offset;
}

"""Epoch seconds of the (possibly shifted) clock -- used to order records."""
def stamp() -> float {
    return utcnow().replace(tzinfo=timezone.utc).timestamp();
}

"""Fixed-width ISO text, so stored times sort as strings."""
def iso(dt: datetime | None) -> str {
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f") if dt is not None else "";
}

def now_s() -> str {
    return iso(utcnow());
}

def parse_iso(s: str) -> datetime | None {
    if not s {
        return None;
    }
    try {
        return datetime.fromisoformat(s);
    } except ValueError {
        return None;
    }
}

"""Seconds between the stored ISO time and now (clock-aware)."""
def seconds_since(s: str) -> int {
    dt = parse_iso(s);
    if dt is None {
        return 0;
    }
    return int((utcnow() - dt).total_seconds());
}
