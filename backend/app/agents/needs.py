"""Needs Agent — turns "one guard 7am to 7pm every day, and a night patrol 6pm to midnight" into
weekly staffing requirements (optionally tied to the employer's roles).

AI first (Gemini). When the model is unavailable, a deterministic parser reads the same sentence:
clauses -> time range, days, headcount and role. Only if nothing can be read does it fall back to a
typical-week template for the kind of place described.
"""
from __future__ import annotations

import re

from .llm import llm

H = 60
DAY_NAMES = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
DAY_ABBR = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
NUM_WORDS = {"a": 1, "an": 1, "one": 1, "single": 1, "two": 2, "couple": 2, "pair": 2, "three": 3, "four": 4, "five": 5, "six": 6,
             "seven": 7, "eight": 8, "nine": 9, "ten": 10}

TEMPLATES = {
    "dining": [([0, 1, 2, 3, 4], 7, 11, 2), ([0, 1, 2, 3, 4], 11, 15, 4), ([0, 1, 2, 3, 4], 15, 19, 2), ([5], 10, 14, 2), ([5], 14, 18, 2)],
    "library": [([0, 1, 2, 3, 4], 8, 12, 2), ([0, 1, 2, 3, 4], 12, 16, 2), ([0, 1, 2, 3, 4], 16, 20, 2), ([5, 6], 12, 16, 1)],
    "lab": [([0, 1, 2, 3, 4], 10, 14, 1), ([0, 2, 4], 14, 18, 1)],
    "rec": [([0, 1, 2, 3, 4, 5, 6], 6, 10, 2), ([0, 1, 2, 3, 4, 5, 6], 10, 16, 1), ([0, 1, 2, 3, 4], 16, 20, 3)],
    "security": [([0, 1, 2, 3, 4, 5, 6], 7, 19, 1), ([0, 1, 2, 3, 4, 5, 6], 19, 24, 1)],
    "desk": [([0, 1, 2, 3, 4], 9, 13, 2), ([0, 1, 2, 3, 4], 13, 17, 2)],
}
KEYWORDS = [
    ("security", r"secur|guard|patrol|watch"),
    ("dining", r"dining|cafe|café|food|kitchen|coffee|restaurant|meal|catering|bookstore|store|shop|retail"),
    ("library", r"library|books|archive|study"),
    ("lab", r"lab|research|clinic"),
    ("rec", r"rec|gym|fitness|pool|athletic|sports"),
]

_SYSTEM = (
    "You are the Needs Agent for an employer. From a manager's description, produce weekly staffing "
    "requirements. Days: 0=Mon..6=Sun. Use 24h HH:MM; use 24:00 for midnight at the end of a day. Headcount 1-20. "
    "Keep the shift lengths the manager describes (e.g. a 12-hour guard post stays one 7:00-19:00 block); if they only give "
    "opening hours, split into blocks of 3-5 hours and put more people at the busy times they mention. "
    "If the employer has roles, set \"role\" to the best matching role name for each block, or null for anyone. "
    "Respond with JSON only: "
    '{"needs": [{"days": [0,1,2,3,4], "start": "11:00", "end": "15:00", "headcount": 4, "role": null}], "summary": "one sentence"}'
)


def generate(description: str, roles: list[dict] | None = None, kind: str = "business") -> tuple[list[dict], str, bool]:
    """roles: [{"id", "name"}]. Returns (needs [{day,start,end,headcount,position_id}], summary, used_ai)."""
    roles = roles or []
    text = (description or "").strip()[:800]
    prompt = text + (f"\n\nRoles at this employer: {', '.join(r['name'] for r in roles)}" if roles else "")
    data = llm.json(_SYSTEM, prompt) if text else None
    if isinstance(data, dict) and isinstance(data.get("needs"), list):
        try:
            out = []
            for n in data["needs"]:
                s, e = _hm(n["start"]), _hm(n["end"])
                head = max(1, min(20, int(n["headcount"])))
                pid = _role_id(str(n.get("role") or ""), roles)
                for d in n["days"]:
                    if 0 <= int(d) <= 6 and 0 <= s < e <= 24 * H:
                        out.append({"day": int(d), "start": s, "end": e, "headcount": head, "position_id": pid})
            if out:
                return _dedupe(out), str(data.get("summary") or "Drafted from your description."), True
        except Exception:
            pass
    return fallback(text, roles, kind)


# ------------------------------------------------------------------ deterministic parser
_T = r"(noon|midnight|midday|\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)?)"
_RANGE = re.compile(_T + r"\s*(?:-|–|—|to|until|till|through)\s*" + _T)


def _time(tok: str, default_pm: bool | None = None) -> int | None:
    t = tok.strip().lower().replace(".", "")
    if t in ("noon", "midday"):
        return 12 * H
    if t == "midnight":
        return 24 * H
    m = re.match(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$", t)
    if not m:
        return None
    h, mi, ap = int(m.group(1)), int(m.group(2) or 0), m.group(3)
    if h > 24 or mi > 59:
        return None
    if ap == "am":
        h = 0 if h == 12 else h
    elif ap == "pm":
        h = h if h == 12 else h + 12
    elif default_pm and h < 12:
        h += 12
    return h * H + mi


def _range(clause: str) -> tuple[int, int] | None:
    m = _RANGE.search(clause)
    if not m:
        return None
    a_raw, b_raw = m.group(1), m.group(2)
    b = _time(b_raw)
    a_has_ampm = re.search(r"am|pm|noon|midnight|midday", a_raw.replace(".", ""))
    a = _time(a_raw)
    if not a_has_ampm and b is not None:  # "7 to 7pm" -> 7am, "5 to 9pm" -> 5pm
        a_pm = _time(a_raw, default_pm=True)
        a = a if a is not None and a < b else a_pm if a_pm is not None and a_pm < b else a
    if b is not None and not re.search(r"am|pm|noon|midnight|midday", b_raw.replace(".", "")) and a is not None and b <= a:
        b = _time(b_raw, default_pm=True)
    if a is None or b is None:
        return None
    if b <= a and b == 0:
        b = 24 * H
    return (a, b) if a < b else None


def _days(clause: str) -> list[int] | None:
    c = clause.lower()
    if re.search(r"every ?day|daily|7 days|seven days|all week|around the clock|24/7|each day", c):
        return list(range(7))
    if re.search(r"weekday|mon(day)?\s*(?:-|–|to|through)\s*fri(day)?|work ?week|business days", c):
        return [0, 1, 2, 3, 4]
    if re.search(r"weekend", c):
        return [5, 6]
    m = re.search(r"\b(" + "|".join(DAY_ABBR) + r")[a-z]*\s*(?:-|–|to|through)\s*(" + "|".join(DAY_ABBR) + r")[a-z]*", c)
    if m:
        a, b = DAY_ABBR.index(m.group(1)[:3]), DAY_ABBR.index(m.group(2)[:3])
        return list(range(a, b + 1)) if a <= b else list(range(a, 7)) + list(range(0, b + 1))
    found = sorted({i for i, (full, ab) in enumerate(zip(DAY_NAMES, DAY_ABBR)) if re.search(rf"\b{full}s?\b|\b{ab}\b", c)})
    return found or None


_NOUNS = (r"people|persons?|staff|crew|workers?|employees?|students?|guards?|officers?|patrols?|cashiers?|cooks?|servers?|baristas?|"
          r"assistants?|agents?|nurses?|drivers?|tutors?|clerks?|attendants?|hosts?|dishwashers?|managers?|lifeguards?|receptionists?|"
          r"techs?|technicians?|associates?|leads?|supervisors?|posts?|shifts?|bartenders?|runners?|stockers?|helpers?|volunteers?")


def _count(clause: str) -> int | None:
    c = clause.lower()
    m = re.search(r"\b(\d{1,2})\s+(?:[a-z-]+\s){0,2}?(?:" + _NOUNS + r")\b", c)
    if m:
        return max(1, min(20, int(m.group(1))))
    m = re.search(r"\b(" + "|".join(NUM_WORDS) + r")\s+(?:[a-z-]+\s){0,2}?(?:" + _NOUNS + r")\b", c)
    if m:
        return NUM_WORDS[m.group(1)]
    # "... and two 7pm to midnight" — a number word right before a time
    m = re.search(r"\b(" + "|".join(k for k in NUM_WORDS if k not in ("a", "an")) + r")\s+(?=\d{1,2}(?::\d{2})?\s*(?:am|pm)|noon|midnight)", c)
    if m:
        return NUM_WORDS[m.group(1)]
    return None


def _role_id(text: str, roles: list[dict]) -> int | None:
    low = text.lower()
    if not low or not roles:
        return None
    best, score = None, 0
    for r in roles:
        words = [w for w in re.findall(r"[a-z]+", r["name"].lower()) if len(w) > 2]
        hit = sum(1 for w in words if re.search(rf"\b{w[:5]}", low))
        if hit > score:
            best, score = r["id"], hit
    return best


def _split(start: int, end: int, kind: str) -> list[tuple[int, int]]:
    """Campus jobs: blocks of about 4 h (students max 8 h/day). Businesses keep posts up to 12 h."""
    limit = 12 * H if kind == "business" else 5 * H
    length = end - start
    if length <= limit:
        return [(start, end)]
    n = -(-length // (4 * H if kind != "business" else limit))
    step = -(-length // n)
    step = max(H, (step // 30) * 30)
    out, t = [], start
    while t < end:
        e = end if end - t < step + 30 else t + step
        out.append((t, e))
        t = e
    return out


def parse(text: str, roles: list[dict], kind: str) -> list[dict]:
    clauses = [c.strip() for c in re.split(r"[;.\n]|,\s*(?:and\s+)?|\band\s+(?=(?:a|an|one|two|three|four|\d+)\b)|\bplus\b|\balso\b", text) if c and c.strip()]
    out: list[dict] = []
    last_days: list[int] | None = None
    last_range: tuple[int, int] | None = None
    for c in clauses:
        rng, days = _range(c), _days(c)
        low = c.lower()
        if rng is None and days is None:
            # "slammed at lunch", "busiest in the evening" -> more people in that window on existing blocks
            window = (11 * H, 14 * H) if re.search(r"lunch|midday|noon", low) else (17 * H, 20 * H) if re.search(r"dinner|evening", low) \
                else (7 * H, 10 * H) if re.search(r"breakfast|morning", low) else None
            if window and re.search(r"busy|busiest|rush|slammed|packed|peak|crowded|more", low):
                for n in out:
                    if n["start"] < window[1] and window[0] < n["end"]:
                        n["headcount"] = min(20, n["headcount"] + 1)
            continue
        rng = rng or last_range
        days = days or last_days or (list(range(7)) if kind == "business" else [0, 1, 2, 3, 4])
        if rng is None:
            continue
        head = _count(c) or (1 if re.search(r"smaller|small|skeleton|light", low) else 1 if kind == "business" else 2)
        pid = _role_id(c, roles)
        for s, e in _split(rng[0], rng[1], kind):
            for d in days:
                out.append({"day": d, "start": s, "end": e, "headcount": head, "position_id": pid})
        last_days, last_range = days, rng
    return _dedupe(out)


def _dedupe(rows: list[dict]) -> list[dict]:
    seen, out = set(), []
    for r in sorted(rows, key=lambda r: (r["day"], r["start"], r["end"], r.get("position_id") or 0)):
        k = (r["day"], r["start"], r["end"], r.get("position_id"))
        if k in seen:
            continue
        seen.add(k)
        out.append(r)
    return out


def fallback(text: str, roles: list[dict] | None = None, kind: str = "business") -> tuple[list[dict], str, bool]:
    roles = roles or []
    parsed = parse(text, roles, kind) if text else []
    if parsed:
        days = sorted({n["day"] for n in parsed})
        blocks = len({(n["start"], n["end"], n.get("position_id")) for n in parsed})
        span = "every day" if len(days) == 7 else "weekdays" if days == [0, 1, 2, 3, 4] else f"{len(days)} days a week"
        return parsed, f"Read your description: {blocks} shift{'s' if blocks != 1 else ''} {span}. Adjust anything that's off.", False
    low = text.lower()
    k = next((k for k, pat in KEYWORDS if re.search(pat, low)), "desk")
    out = [{"day": d, "start": s * H, "end": e * H, "headcount": c, "position_id": None} for days, s, e, c in TEMPLATES[k] for d in days]
    if re.search(r"weekend|saturday|sunday", low) and not any(n["day"] >= 5 for n in out):
        out += [{"day": d, "start": 10 * H, "end": 14 * H, "headcount": 2, "position_id": None} for d in (5, 6)]
    labels = {"dining": "food service", "library": "a library", "lab": "a lab", "rec": "a rec center", "desk": "a front desk", "security": "a security team"}
    return out, f"Drafted a typical week for {labels[k]}. Adjust anything that's off.", False


def _hm(v) -> int:
    h, _, m = str(v).partition(":")
    return int(h) * 60 + int(m or 0)
