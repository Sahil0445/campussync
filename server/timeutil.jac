"""Time helpers. Times are minutes from midnight; days are 0=Mon .. 6=Sun."""

import from datetime { date, timedelta }

glob DAY_SHORT: list[str] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
     DAY_LONG: list[str] = [
         "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
     ];

def hm(minutes: int) -> str {
    return f"{minutes // 60:02d}:{minutes % 60:02d}";
}

def parse_hm(text: str) -> int {
    parts = text.strip().split(":");
    return int(parts[0]) * 60 + (int(parts[1]) if len(parts) > 1 and parts[1] else 0);
}

def slot_label(day: int, start: int, end: int) -> str {
    return f"{DAY_SHORT[day]} {hm(start)}–{hm(end)}";
}

def hours(start: int, end: int) -> float {
    return (end - start) / 60;
}

def overlaps(a_start: int, a_end: int, b_start: int, b_end: int) -> bool {
    return a_start < b_end and b_start < a_end;
}

def monday_of(d: date) -> date {
    return d - timedelta(days=d.weekday());
}

def week_key(d: str, dflt: date) -> str {
    if not d {
        return dflt.isoformat();
    }
    return monday_of(date.fromisoformat(d)).isoformat();
}

def fmt_hours(h: float) -> str {
    return str(int(h)) if float(h).is_integer() else f"{h:.1f}";
}

"""Python-style %g for numbers shown in messages."""
def g(v: float) -> str {
    return f"{v:g}";
}

def plural(n: int | float, word: str, many: str = "") -> str {
    return word if n == 1 else (many or word + "s");
}
