"""Availability Agent.

* import_ics: turns an .ics calendar into weekly busy blocks (code -- calendars are structured).
* parse_note: turns "no Fridays before 10, I have lab" into structured rules (AI, regex fallback).
"""

import re;
import from datetime { date, datetime, timedelta, timezone }
import from zoneinfo { ZoneInfo }
import from server.config { TIMEZONE }
import from server.timeutil { DAY_SHORT, hm }
import server.ai as ai;

glob LOCAL_TZ: ZoneInfo = ZoneInfo(TIMEZONE),
     _BYDAY: dict[str, int] = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6};

# ----------------------------------------------------------------------------- .ics
def _unfold(text: str) -> list[str] {
    lines: list[str] = [];
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n") {
        if (raw.startswith(" ") or raw.startswith("\t")) and lines {
            lines[-1] = lines[-1] + raw[1:];
        } else {
            lines.append(raw);
        }
    }
    return lines;
}

def _parse_dt(value: str, params: str) -> datetime | None {
    value = value.strip();
    if "VALUE=DATE" in params.upper() and "T" not in value {
        return None;  # all-day event: not a class block
    }
    m = re.match(r"(\d{8})T(\d{4})(\d{2})?(Z)?", value);
    if not m {
        return None;
    }
    dt = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M");
    if m.group(4) == "Z" {
        dt = dt.replace(tzinfo=timezone.utc).astimezone(LOCAL_TZ).replace(tzinfo=None);
    }
    return dt;
}

def _parse_duration(value: str) -> timedelta | None {
    m = re.match(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?", value.strip());
    if not m {
        return None;
    }
    (d, h, mi) = m.groups();
    return timedelta(
        days=int(d) if d else 0, hours=int(h) if h else 0, minutes=int(mi) if mi else 0
    );
}

"""Weekly busy blocks: [{day, start, end, title, week}]. Recurring events repeat every week
(week ""); one-off events are kept only when they fall inside the given week."""
def import_ics(text: str, week: date) -> list[dict[str, any]] {
    blocks: list[dict[str, any]] = [];
    event: dict[str, tuple[str, str]] | None = None;
    for line in _unfold(text) {
        if line.strip() == "BEGIN:VEVENT" {
            event = {};
            continue;
        }
        if line.strip() == "END:VEVENT" {
            if event is not None {
                blocks.extend(_event_blocks(event, week));
            }
            event = None;
            continue;
        }
        if event is None or ":" not in line {
            continue;
        }
        (head, _sep, value) = line.partition(":");
        (name, _sep2, params) = head.partition(";");
        event[name.upper()] = (value, params);
    }
    seen: set[str] = set();
    out: list[dict[str, any]] = [];
    for b in blocks {
        key = f"{b['day']}|{b['start']}|{b['end']}|{b['title']}|{b['week']}";
        if key not in seen {
            seen.add(key);
            out.append(b);
        }
    }
    out.sort(key=lambda (b: dict[str, any]) -> tuple[int, int] { return (b["day"], b["start"]); });
    return out;
}

def _event_blocks(ev: dict[str, tuple[str, str]], week: date) -> list[dict[str, any]] {
    if "DTSTART" not in ev {
        return [];
    }
    start = _parse_dt(ev["DTSTART"][0], ev["DTSTART"][1]);
    if start is None {
        return [];
    }
    end: datetime | None = _parse_dt(ev["DTEND"][0], ev["DTEND"][1]) if "DTEND" in ev else None;
    if end is None and "DURATION" in ev {
        dur = _parse_duration(ev["DURATION"][0]);
        end = start + dur if dur is not None else None;
    }
    if end is None or end <= start or (end - start) > timedelta(hours=12) {
        return [];
    }
    if end.date() != start.date() {
        end = datetime.combine(start.date(), datetime.max.time()).replace(second=0, microsecond=0);
    }
    title = (ev.get("SUMMARY", ("Class", ""))[0] or "Class").replace("\\,", ",").strip()[:60];
    s_min = start.hour * 60 + start.minute;
    e_min = end.hour * 60 + end.minute if end.date() == start.date() else 24 * 60;
    rrule = ev.get("RRULE", ("", ""))[0].upper();
    days: list[int] = [];
    wk = "";
    if "FREQ=WEEKLY" in rrule or "FREQ=DAILY" in rrule {
        m = re.search(r"BYDAY=([A-Z,0-9+-]+)", rrule);
        if m {
            days = sorted({_BYDAY[d[-2:]] for d in m.group(1).split(",") if d[-2:] in _BYDAY});
        } elif "FREQ=DAILY" in rrule {
            days = list(range(7));
        } else {
            days = [start.weekday()];
        }
        until = re.search(r"UNTIL=(\d{8})", rrule);
        if until and datetime.strptime(until.group(1), "%Y%m%d").date() < week {
            return [];
        }
        if start.date() > week + timedelta(days=6) {
            return [];
        }
        wk = "";  # repeats every week
    } else {
        if not (week <= start.date() and start.date() <= week + timedelta(days=6)) {
            return [];
        }
        days = [start.weekday()];
        wk = week.isoformat();  # one-off: only this week
    }
    return [{"day": d, "start": s_min, "end": e_min, "title": title, "week": wk} for d in days];
}

# ----------------------------------------------------------------------------- notes
glob _DAY_WORDS: dict[str, list[int]] = {
         "mon": [0], "monday": [0], "mondays": [0],
         "tue": [1], "tues": [1], "tuesday": [1], "tuesdays": [1],
         "wed": [2], "weds": [2], "wednesday": [2], "wednesdays": [2],
         "thu": [3], "thur": [3], "thurs": [3], "thursday": [3], "thursdays": [3],
         "fri": [4], "friday": [4], "fridays": [4],
         "sat": [5], "saturday": [5], "saturdays": [5],
         "sun": [6], "sunday": [6], "sundays": [6],
         "weekend": [5, 6], "weekends": [5, 6],
         "weekday": [0, 1, 2, 3, 4], "weekdays": [0, 1, 2, 3, 4]
     },
     _TIME: str = r"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?",
     _NEG: str = r"(?:no|not|never|can'?t|cannot|won'?t|unavailable|busy|off|avoid|don'?t)";

def _to_min(h: str, m: str | None, ampm: str | None) -> int {
    hour = int(h);
    minute = int(m or 0);
    ap = (ampm or "").replace(".", "");
    if ap == "pm" and hour < 12 {
        hour += 12;
    } elif ap == "am" and hour == 12 {
        hour = 0;
    } elif not ap and 1 <= hour and hour <= 6 {
        hour += 12;  # "after 5" means 5 PM on a campus schedule
    }
    return max(0, min(24 * 60, hour * 60 + minute));
}

def rule_label(day: int, start: int, end: int) -> str {
    d = DAY_SHORT[day];
    if start <= 0 and end >= 24 * 60 {
        return f"Unavailable {d}";
    }
    if start <= 0 {
        return f"Unavailable {d} before {hm(end)}";
    }
    if end >= 24 * 60 {
        return f"Unavailable {d} after {hm(start)}";
    }
    return f"Unavailable {d} {hm(start)}–{hm(end)}";
}

def _finish(rules: list[dict[str, any]]) -> list[dict[str, any]] {
    seen: set[str] = set();
    out: list[dict[str, any]] = [];
    for r in rules {
        r["start"] = max(0, r["start"]);
        r["end"] = min(24 * 60, r["end"]);
        if r["end"] <= r["start"] {
            continue;
        }
        key = f"{r['day']}|{r['start']}|{r['end']}";
        if key not in seen {
            seen.add(key);
            r["label"] = rule_label(r["day"], r["start"], r["end"]);
            out.append(r);
        }
    }
    return sorted(
        out, key=lambda (r: dict[str, any]) -> tuple[int, int] { return (r["day"], r["start"]); }
    );
}

def parse_note_fallback(text: str) -> list[dict[str, any]] {
    rules: list[dict[str, any]] = [];
    for raw_clause in re.split(r"[.;\n—–]|,\s*(?=\D)|\bbut\b", text.lower()) {
        clause = (raw_clause or "").strip();
        if not clause {
            continue;
        }
        words = re.findall(r"[a-z]+", clause);
        days = sorted({d for w in words for d in _DAY_WORDS.get(w, [])});
        period: tuple[int, int] | None = None;
        if re.search(r"\bmornings?\b", clause) {
            period = (0, 12 * 60);
        } elif re.search(r"\bafternoons?\b", clause) {
            period = (12 * 60, 17 * 60);
        } elif re.search(r"\bevenings?|nights?\b", clause) {
            period = (17 * 60, 24 * 60);
        }
        before = re.search(r"before\s+" + _TIME, clause);
        after = re.search(r"after\s+" + _TIME, clause);
        span = re.search(_TIME + r"\s*(?:-|to|until|till)\s*" + _TIME, clause);
        if re.search(r"\b(fine|ok|okay|works?|available|free|prefer|love|happy)\b", clause)
            and not re.search(r"\b(not|no|never|can'?t|cannot|un)\b", clause) {
            continue;  # a positive statement is not an unavailability rule
        }
        negative = (
            re.search(r"\b" + _NEG + r"\b", clause) is not None
            or clause.startswith("no ")
            or re.search(r"\b(go home|away|out of town|travel|lab|class|practice)\b", clause) is not None
        );
        if not days and period is not None and negative {
            days = list(range(7));
        }
        if not days {
            continue;
        }
        start = 0;
        end = 0;
        if before {
            (bh, bm, bap) = before.groups();
            start = 0;
            end = _to_min(bh, bm, bap);
        } elif after {
            (ah, am, aap) = after.groups();
            start = _to_min(ah, am, aap);
            end = 24 * 60;
        } elif span {
            g = span.groups();
            end_ampm = g[5];
            start = _to_min(g[0], g[1], g[2] or end_ampm);
            end = _to_min(g[3], g[4], end_ampm);
        } elif period is not None {
            (start, end) = period;
        } elif negative {
            start = 0;
            end = 24 * 60;
        } else {
            continue;
        }
        rules.extend([{"day": d, "start": start, "end": end} for d in days]);
    }
    return _finish(rules);
}

def _hhmm(v: str) -> int {
    parts = str(v).split(":");
    h = int(parts[0]);
    mi = int(parts[1]) if len(parts) > 1 and parts[1] else 0;
    return max(0, min(24 * 60, h * 60 + mi));
}

"""Returns (rules, used_ai)."""
def parse_note(text: str) -> tuple[list[dict[str, any]], bool] {
    note = (text or "").strip()[:500];
    if not note {
        return ([], False);
    }
    if ai.ready() {
        try {
            res = ai.read_note(note);
            rules: list[dict[str, any]] = [];
            for r in res.rules {
                s = _hhmm(r.start);
                e = _hhmm(r.end);
                for d in r.days {
                    if 0 <= d and d <= 6 {
                        rules.append({"day": d, "start": s, "end": e});
                    }
                }
            }
            ai.succeeded();
            return (_finish(rules), True);
        } except Exception as ex {
            ai.failed(ex);
        }
    }
    return (parse_note_fallback(note), False);
}
