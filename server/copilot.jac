"""Copilot -- natural language in, structured intent out.

"Can Priya work Wed 12 to 3?", "Who can cover Friday evening?", "Need 2 more people Saturday 3-7",
"I can't do Saturday, Wednesday works". Gemini parses when available; a deterministic parser is the
fallback. Parsing never decides anything -- every action still goes through the rules.
"""

import re;
import server.ai as ai;

glob DAY_WORDS: dict[str, int] = {
         "mon": 0, "monday": 0, "tue": 1, "tues": 1, "tuesday": 1, "wed": 2, "weds": 2, "wednesday": 2,
         "thu": 3, "thur": 3, "thurs": 3, "thursday": 3, "fri": 4, "friday": 4, "sat": 5,
         "saturday": 5, "sun": 6, "sunday": 6
     },
     _DAY_RE: any = re.compile(
         r"\b(mon|monday|tues?|tuesday|weds?|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)(s)?\b",
         re.I
     ),
     _SPAN_RE: any = re.compile(
         r"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\s*(?:-|–|—|to|until|till|through)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?",
         re.I
     ),
     PERIODS: list[tuple[str, tuple[int, int]]] = [
         ("morning", (8 * 60, 12 * 60)),
         ("afternoon", (12 * 60, 17 * 60)),
         ("evening", (15 * 60, 19 * 60)),
         ("night", (17 * 60, 22 * 60))
     ];

obj DayHit {
    has pos: int,
        day: int,
        plural: bool;
}

# ------------------------------------------------------------------ primitives
"""Days mentioned, in order; 'weekend' expands to Sat+Sun."""
def days_in(text: str) -> list[DayHit] {
    out: list[DayHit] = [];
    for m in _DAY_RE.finditer(text) {
        before = text[max(0, m.start() - 8):m.start()];
        out.append(
            DayHit(
                pos=m.start(),
                day=DAY_WORDS[m.group(1).lower()],
                plural=bool(m.group(2)) or bool(re.search(r"\bevery\b", before, re.I))
            )
        );
    }
    for m in re.finditer(r"\bweekends?\b", text, re.I) {
        pl = m.group(0).lower().endswith("s");
        out.append(DayHit(pos=m.start(), day=5, plural=pl));
        out.append(DayHit(pos=m.start(), day=6, plural=pl));
    }
    return sorted(
        out, key=lambda (h: DayHit) -> tuple[int, int, bool] { return (h.pos, h.day, h.plural); }
    );
}

def _clock(h: int, m: int, ampm: str | None) -> int {
    ap = (ampm or "").lower().replace(".", "");
    if ap == "pm" and h < 12 {
        h += 12;
    } elif ap == "am" and h == 12 {
        h = 0;
    }
    return h * 60 + m;
}

def span_in(text: str) -> tuple[int, int] | None {
    t = re.sub(r"\bnoon\b", "12pm", text, flags=re.I);
    t = re.sub(r"\bmidnight\b", "12am", t, flags=re.I);
    m = _SPAN_RE.search(t);
    if not m {
        for (k, v) in PERIODS {
            if re.search(rf"\b{k}s?\b", t, re.I) {
                return v;
            }
        }
        return None;
    }
    (h1s, m1s, a1, h2s, m2s, a2) = m.groups();
    h1 = int(h1s);
    h2 = int(h2s);
    m1 = int(m1s or 0);
    m2 = int(m2s or 0);
    if h1 > 24 or h2 > 24 {
        return None;
    }
    start = 0;
    end = 0;
    if not a1 and not a2 {
        start = _clock(h1, m1, "pm" if 1 <= h1 and h1 <= 6 else None);
        end = _clock(h2, m2, "pm" if (1 <= h2 and h2 <= 7) or (h2 < h1 and h2 < 12) else None);
    } elif a2 and not a1 {
        end = _clock(h2, m2, a2);
        start = _clock(h1, m1, a2);
        if start >= end {
            start = _clock(h1, m1, "am" if a2.lower().startswith("p") else "pm");
        }
    } else {
        start = _clock(h1, m1, a1);
        end = _clock(h2, m2, a2 or a1);
    }
    if end == 0 and start > 0 {
        end = 24 * 60;  # "6pm to midnight"
    }
    if end <= start and end + 12 * 60 > start {
        end += 12 * 60;
    }
    if not (0 <= start and start < end and end <= 24 * 60) {
        return None;
    }
    return (start, end);
}

def hours_in(text: str) -> float | None {
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:more\s+)?(?:hrs?|hours?)\b", text, re.I);
    return float(m.group(1)) if m else None;
}

def count_in(text: str) -> int | None {
    m = re.search(r"(\d+)\s*(?:more\s+)?(?:people|students|staff|persons?|workers|heads?|folks)\b", text, re.I);
    if m {
        return int(m.group(1));
    }
    words = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5};
    m2 = re.search(r"\b(one|two|three|four|five)\s+(?:more\s+)?(?:people|students|staff|persons?|workers)\b", text, re.I);
    return words[m2.group(1).lower()] if m2 else None;
}

"""people: [(id, full name)]."""
def person_in(text: str, people: list[tuple[str, str]]) -> str | None {
    low = text.lower();
    by_len = sorted(people, key=lambda (p: tuple[str, str]) -> int { return -len(p[1]); });
    for (pid, name) in by_len {
        if re.search(rf"\b{re.escape(name.lower())}\b", low) {
            return pid;
        }
    }
    for (pid, name) in people {
        first = name.split()[0].lower();
        if re.search(rf"\b{re.escape(first)}('s)?\b", low) {
            return pid;
        }
    }
    return None;
}

def _hm(v: str) -> int {
    parts = str(v).split(":");
    h = int(parts[0]);
    mi = int(parts[1]) if len(parts) > 1 and parts[1] else 0;
    return max(0, min(24 * 60, h * 60 + mi));
}

# ------------------------------------------------------------------ manager intents
glob DEPT_INTENTS: list[str] = ["check", "assign", "find", "need", "invite", "generate", "status", "help"];

def parse_dept(text: str, people: list[tuple[str, str]]) -> tuple[dict[str, any], bool] {
    base = _fallback_dept(text, people);
    if ai.ready() {
        try {
            data = ai.read_manager_command(text, [n for (_i, n) in people]);
            if data.intent in DEPT_INTENTS {
                out = dict(base);
                out["intent"] = data.intent;
                if data.student {
                    out["student_id"] = person_in(str(data.student), people) or base.get("student_id");
                }
                if data.day is not None and 0 <= data.day and data.day <= 6 {
                    out["day"] = data.day;
                }
                try {
                    if data.start and data.end {
                        s = _hm(data.start);
                        e = _hm(data.end);
                        if s < e {
                            out["start"] = s;
                            out["end"] = e;
                        }
                    }
                } except Exception { }
                if data.hours is not None and data.hours > 0 {
                    out["hours"] = data.hours;
                }
                if data.count is not None and data.count > 0 {
                    out["count"] = data.count;
                }
                ai.succeeded();
                return (out, True);
            }
        } except Exception as ex {
            ai.failed(ex);
        }
    }
    return (base, False);
}

def _fallback_dept(text: str, people: list[tuple[str, str]]) -> dict[str, any] {
    low = text.lower();
    d = days_in(text);
    span = span_in(text);
    out: dict[str, any] = {
        "intent": "help",
        "student_id": person_in(text, people),
        "day": d[0].day if d else None,
        "start": span[0] if span is not None else None,
        "end": span[1] if span is not None else None,
        "hours": hours_in(text),
        "count": count_in(text)
    };
    if re.search(r"\b(generate|build|make|draft|create|plan)\b.*\b(schedule|week|roster|rota)\b|\bautopilot\b", low) {
        out["intent"] = "generate";
    } elif re.search(r"\b(invite|hire|recruit|onboard)\b", low) and out["student_id"] {
        out["intent"] = "invite";
    } elif out["count"] and re.search(r"\b(need|needs|more|add|extra|another|fewer|less)\b", low) and out["day"] is not None {
        out["intent"] = "need";
    } elif out["student_id"] and re.search(r"\b(put|assign|schedule|add|give|book|place|slot)\b", low) {
        out["intent"] = "assign";
    } elif out["student_id"] {
        out["intent"] = "check";
    } elif re.search(r"\b(who|find|cover|anyone|someone|somebody|available|free)\b", low) {
        out["intent"] = "find";
    } elif re.search(r"\b(status|coverage|how('?s| is| are)|summary|gaps?|understaffed|overview)\b", low) {
        out["intent"] = "status";
    }
    return out;
}

# ------------------------------------------------------------------ employee intents
glob _NEG: str = r"\b(can'?t|cannot|won'?t|not|no|unavailable|busy|away|off|sick|dentist|doctor|appointment|exam|interview|trip|travel|visit|family|out)\b",
     _POS: str = r"\b(works?|instead|prefer|rather|better|free|fine|ok|okay|good|available|could do|can do)\b",
     STUDENT_INTENTS: list[str] = ["unavailable", "swap", "hours", "status", "help"];

def parse_student(text: str) -> tuple[dict[str, any], bool] {
    if ai.ready() {
        try {
            data = ai.read_employee_message(text);
            if data.intent in STUDENT_INTENTS {
                unav: list[dict[str, any]] = [];
                for u in data.unavailable {
                    s = _hm(u.start or "00:00");
                    e = _hm(u.end or "24:00");
                    if 0 <= int(u.day) and int(u.day) <= 6 and s < e {
                        unav.append(
                            {
                                "day": int(u.day), "start": s, "end": e,
                                "recurring": bool(u.recurring), "label": str(u.label or "Busy")[:40]
                            }
                        );
                    }
                }
                want = [int(d) for d in data.want_days if 0 <= int(d) and int(d) <= 6];
                gu = data.give_up_day;
                ai.succeeded();
                return (
                    {
                        "intent": data.intent,
                        "unavailable": unav,
                        "want_days": want,
                        "give_up_day": int(gu) if gu is not None and 0 <= gu and gu <= 6 else None
                    },
                    True
                );
            }
        } except Exception as ex {
            ai.failed(ex);
        }
    }
    return (_fallback_student(text), False);
}

def _fallback_student(text: str) -> dict[str, any] {
    low = text.lower();
    unavailable: list[dict[str, any]] = [];
    want_days: list[int] = [];
    give_up_day: int | None = None;
    intent = "help";
    if re.search(r"\b(how many|hours? (left|remaining)|my hours|am i at)\b", low) {
        return {"intent": "hours", "unavailable": [], "want_days": [], "give_up_day": None};
    }
    label_m = re.search(
        r"\b(dentist|doctor|appointment|exam|interview|trip|family visit|visit|wedding|game|practice|class|lab)\b", low
    );
    label = label_m.group(1).capitalize() if label_m else "Busy";
    for clause in re.split(r"[.;!\n]|,|\bbut\b|\binstead\b(?=.*\b(?:mon|tue|wed|thu|fri|sat|sun))", text, flags=re.I) {
        if not clause or not clause.strip() {
            continue;
        }
        ds = days_in(clause);
        if not ds {
            continue;
        }
        span = span_in(clause);
        if re.search(_NEG, clause, re.I) and not re.search(r"\b(works?|prefer|rather)\b", clause, re.I) {
            for h in ds {
                (s, e) = span if span is not None else (0, 24 * 60);
                unavailable.append(
                    {"day": h.day, "start": s, "end": e, "recurring": h.plural, "label": label}
                );
            }
        } elif re.search(_POS, clause, re.I) or re.search(r"\b(swap|switch|trade|move|change)\b", clause, re.I) {
            if re.search(r"\b(swap|switch|trade|move|change)\b", clause, re.I) and len(ds) >= 2 {
                give_up_day = ds[0].day;
                want_days = want_days + [h.day for h in ds[1:]];
            } elif re.search(r"\b(swap|switch|trade|move|change|give up|drop)\b", clause, re.I)
                and give_up_day is None
                and not unavailable {
                give_up_day = ds[0].day;
            } else {
                want_days = want_days + [h.day for h in ds];
            }
        }
    }
    blocked = {u["day"] for u in unavailable};
    want_days = sorted(set(want_days) - blocked);
    if unavailable {
        intent = "unavailable";
    } elif give_up_day is not None {
        intent = "swap";
    } elif re.search(r"\b(status|schedule|shifts?|this week)\b", low) {
        intent = "status";
    }
    return {"intent": intent, "unavailable": unavailable, "want_days": want_days, "give_up_day": give_up_day};
}
