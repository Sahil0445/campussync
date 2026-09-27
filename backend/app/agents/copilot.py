"""Copilot — natural language in, structured intent out.

"Can Priya work Wed 12 to 3?", "Who can cover Friday evening?", "Need 2 more people Saturday 3-7",
"I can't do Saturday, Wednesday works". Gemini parses when available; a deterministic parser is the
fallback, so the demo never depends on the network. Parsing never decides anything — every action
still goes through the rules.
"""
from __future__ import annotations

import json
import re

from .llm import llm

DAY_WORDS = {
    "mon": 0, "monday": 0, "tue": 1, "tues": 1, "tuesday": 1, "wed": 2, "weds": 2, "wednesday": 2,
    "thu": 3, "thur": 3, "thurs": 3, "thursday": 3, "fri": 4, "friday": 4, "sat": 5, "saturday": 5, "sun": 6, "sunday": 6,
}
_DAY_RE = re.compile(r"\b(mon|monday|tues?|tuesday|weds?|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)(s)?\b", re.I)
_SPAN_RE = re.compile(
    r"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\s*(?:-|–|—|to|until|till|through)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?", re.I)
PERIODS = {"morning": (8 * 60, 12 * 60), "afternoon": (12 * 60, 17 * 60), "evening": (15 * 60, 19 * 60), "night": (17 * 60, 22 * 60)}


# ------------------------------------------------------------------ primitives
def days_in(text: str) -> list[tuple[int, int, bool]]:
    """[(position, day, plural)]; 'weekend' expands to Sat+Sun."""
    out = [(m.start(), DAY_WORDS[m.group(1).lower()], bool(m.group(2)) or bool(re.search(r"\bevery\b", text[max(0, m.start() - 8):m.start()], re.I)))
           for m in _DAY_RE.finditer(text)]
    for m in re.finditer(r"\bweekends?\b", text, re.I):
        out += [(m.start(), 5, m.group(0).lower().endswith("s")), (m.start(), 6, m.group(0).lower().endswith("s"))]
    return sorted(out)


def _clock(h: int, m: int, ampm: str | None) -> int:
    ampm = (ampm or "").lower().replace(".", "")
    if ampm == "pm" and h < 12:
        h += 12
    elif ampm == "am" and h == 12:
        h = 0
    return h * 60 + m


def span_in(text: str) -> tuple[int, int] | None:
    t = re.sub(r"\bnoon\b", "12pm", text, flags=re.I)
    t = re.sub(r"\bmidnight\b", "12am", t, flags=re.I)
    m = _SPAN_RE.search(t)
    if not m:
        per = next((v for k, v in PERIODS.items() if re.search(rf"\b{k}s?\b", t, re.I)), None)
        return per
    h1, m1, a1, h2, m2, a2 = m.groups()
    h1, h2, m1, m2 = int(h1), int(h2), int(m1 or 0), int(m2 or 0)
    if h1 > 24 or h2 > 24:
        return None
    if not a1 and not a2:
        start = _clock(h1, m1, "pm" if 1 <= h1 <= 6 else None)
        end = _clock(h2, m2, "pm" if 1 <= h2 <= 7 or (h2 < h1 and h2 < 12) else None)
    elif a2 and not a1:
        end = _clock(h2, m2, a2)
        start = _clock(h1, m1, a2)
        if start >= end:
            start = _clock(h1, m1, "am" if a2.lower().startswith("p") else "pm")
    else:
        start, end = _clock(h1, m1, a1), _clock(h2, m2, a2 or a1)
    if end == 0 and start > 0:  # "6pm to midnight"
        end = 24 * 60
    if end <= start and end + 12 * 60 > start:
        end += 12 * 60
    if not (0 <= start < end <= 24 * 60):
        return None
    return start, end


def hours_in(text: str) -> float | None:
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:more\s+)?(?:hrs?|hours?)\b", text, re.I)
    return float(m.group(1)) if m else None


def count_in(text: str) -> int | None:
    m = re.search(r"(\d+)\s*(?:more\s+)?(?:people|students|staff|persons?|workers|heads?|folks)\b", text, re.I)
    if m:
        return int(m.group(1))
    words = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5}
    m = re.search(r"\b(one|two|three|four|five)\s+(?:more\s+)?(?:people|students|staff|persons?|workers)\b", text, re.I)
    return words[m.group(1).lower()] if m else None


def person_in(text: str, people: list[tuple[int, str]]) -> int | None:
    low = text.lower()
    for pid, name in sorted(people, key=lambda p: -len(p[1])):
        if re.search(rf"\b{re.escape(name.lower())}\b", low):
            return pid
    for pid, name in people:
        first = name.split()[0].lower()
        if re.search(rf"\b{re.escape(first)}('s)?\b", low):
            return pid
    return None


# ------------------------------------------------------------------ manager intents
_DEPT_SYSTEM = (
    "You parse a campus employer's manager command into JSON. intents: check (is a student free?), assign (put a student "
    "on a shift), find (who can cover a slot), need (change how many people a slot needs), invite (bring a student onto "
    "the team), generate (build the schedule), status (how is coverage), help. Days 0=Mon..6=Sun. Times 24h HH:MM. "
    'Respond with JSON only: {"intent": "...", "student": "<name or null>", "day": <int or null>, "start": "HH:MM or null", '
    '"end": "HH:MM or null", "hours": <number or null>, "count": <int or null>}'
)


def parse_dept(text: str, people: list[tuple[int, str]]) -> tuple[dict, bool]:
    base = _fallback_dept(text, people)
    data = llm.json(_DEPT_SYSTEM, json.dumps({"command": text, "people": [n for _, n in people]}))
    if isinstance(data, dict) and data.get("intent") in {"check", "assign", "find", "need", "invite", "generate", "status", "help"}:
        out = dict(base)
        out["intent"] = data["intent"]
        if data.get("student"):
            out["student_id"] = person_in(str(data["student"]), people) or base.get("student_id")
        if isinstance(data.get("day"), int) and 0 <= data["day"] <= 6:
            out["day"] = data["day"]
        try:
            if data.get("start") and data.get("end"):
                s, e = _hm(data["start"]), _hm(data["end"])
                if s < e:
                    out["start"], out["end"] = s, e
        except Exception:
            pass
        for k in ("hours", "count"):
            if isinstance(data.get(k), (int, float)) and data[k] > 0:
                out[k] = data[k]
        return out, True
    return base, False


def _fallback_dept(text: str, people: list[tuple[int, str]]) -> dict:
    low = text.lower()
    d = days_in(text)
    span = span_in(text)
    out = {"intent": "help", "student_id": person_in(text, people), "day": d[0][1] if d else None,
           "start": span[0] if span else None, "end": span[1] if span else None,
           "hours": hours_in(text), "count": count_in(text)}
    if re.search(r"\b(generate|build|make|draft|create|plan)\b.*\b(schedule|week|roster|rota)\b|\bautopilot\b", low):
        out["intent"] = "generate"
    elif re.search(r"\b(invite|hire|recruit|onboard)\b", low) and out["student_id"]:
        out["intent"] = "invite"
    elif out["count"] and re.search(r"\b(need|needs|more|add|extra|another|fewer|less)\b", low) and out["day"] is not None:
        out["intent"] = "need"
    elif out["student_id"] and re.search(r"\b(put|assign|schedule|add|give|book|place|slot)\b", low):
        out["intent"] = "assign"
    elif out["student_id"]:
        out["intent"] = "check"
    elif re.search(r"\b(who|find|cover|anyone|someone|somebody|available|free)\b", low):
        out["intent"] = "find"
    elif re.search(r"\b(status|coverage|how('?s| is| are)|summary|gaps?|understaffed|overview)\b", low):
        out["intent"] = "status"
    return out


# ------------------------------------------------------------------ student intents
_STUDENT_SYSTEM = (
    "You parse a student's message to their campus job scheduler into JSON. unavailable: times they can't work "
    "(recurring=true only if they say every/always or use a plural like 'Saturdays'). want_days: days they'd like "
    "instead. intent: unavailable | swap | hours | status | help. Days 0=Mon..6=Sun, times 24h HH:MM (whole day = "
    '00:00-24:00). Respond with JSON only: {"intent": "...", "unavailable": [{"day": 5, "start": "00:00", "end": "24:00", '
    '"recurring": false, "label": "Family visit"}], "want_days": [2], "give_up_day": <int or null>}'
)
_NEG = r"\b(can'?t|cannot|won'?t|not|no|unavailable|busy|away|off|sick|dentist|doctor|appointment|exam|interview|trip|travel|visit|family|out)\b"
_POS = r"\b(works?|instead|prefer|rather|better|free|fine|ok|okay|good|available|could do|can do)\b"


def parse_student(text: str) -> tuple[dict, bool]:
    data = llm.json(_STUDENT_SYSTEM, json.dumps({"message": text}))
    if isinstance(data, dict) and data.get("intent") in {"unavailable", "swap", "hours", "status", "help"}:
        try:
            unav = []
            for u in data.get("unavailable") or []:
                s, e = _hm(u.get("start", "00:00")), _hm(u.get("end", "24:00"))
                if 0 <= int(u["day"]) <= 6 and s < e:
                    unav.append({"day": int(u["day"]), "start": s, "end": e, "recurring": bool(u.get("recurring")),
                                 "label": str(u.get("label") or "Busy")[:40]})
            want = [int(d) for d in data.get("want_days") or [] if 0 <= int(d) <= 6]
            gu = data.get("give_up_day")
            return {"intent": data["intent"], "unavailable": unav, "want_days": want,
                    "give_up_day": int(gu) if isinstance(gu, int) and 0 <= gu <= 6 else None}, True
        except Exception:
            pass
    return _fallback_student(text), False


def _fallback_student(text: str) -> dict:
    low = text.lower()
    out = {"intent": "help", "unavailable": [], "want_days": [], "give_up_day": None}
    if re.search(r"\b(how many|hours? (left|remaining)|my hours|am i at)\b", low):
        out["intent"] = "hours"
        return out
    label_m = re.search(r"\b(dentist|doctor|appointment|exam|interview|trip|family visit|visit|wedding|game|practice|class|lab)\b", low)
    label = label_m.group(1).capitalize() if label_m else "Busy"
    for clause in re.split(r"[.;!\n]|,|\bbut\b|\binstead\b(?=.*\b(?:mon|tue|wed|thu|fri|sat|sun))", text, flags=re.I):
        if not clause or not clause.strip():
            continue
        ds = days_in(clause)
        if not ds:
            continue
        span = span_in(clause)
        if re.search(_NEG, clause, re.I) and not re.search(r"\b(works?|prefer|rather)\b", clause, re.I):
            for _, day, plural in ds:
                s, e = span if span else (0, 24 * 60)
                out["unavailable"].append({"day": day, "start": s, "end": e, "recurring": plural, "label": label})
        elif re.search(_POS, clause, re.I) or re.search(r"\b(swap|switch|trade|move|change)\b", clause, re.I):
            if re.search(r"\b(swap|switch|trade|move|change)\b", clause, re.I) and len(ds) >= 2:
                out["give_up_day"] = ds[0][1]
                out["want_days"] += [d for _, d, _ in ds[1:]]
            elif re.search(r"\b(swap|switch|trade|move|change|give up|drop)\b", clause, re.I) and out["give_up_day"] is None and not out["unavailable"]:
                out["give_up_day"] = ds[0][1]
            else:
                out["want_days"] += [d for _, d, _ in ds]
    out["want_days"] = sorted(set(out["want_days"]) - {u["day"] for u in out["unavailable"]})
    if out["unavailable"]:
        out["intent"] = "unavailable"
    elif out["give_up_day"] is not None:
        out["intent"] = "swap"
    elif re.search(r"\b(status|schedule|shifts?|this week)\b", low):
        out["intent"] = "status"
    return out


def _hm(v) -> int:
    h, _, m = str(v).partition(":")
    return max(0, min(24 * 60, int(h) * 60 + int(m or 0)))
