"""Dates, times and money formatting for the screens (same output as before)."""

glob:pub JS: any = globalThis;
glob:pub DAYS: list[str] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
glob:pub DAYS_LONG: list[str] = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
glob:pub DEFAULT_WEEK: str = "2026-09-28";
glob:pub _money0: any = new(JS.Intl.NumberFormat, "en-US", {"style": "currency", "currency": "USD", "maximumFractionDigits": 0});
glob:pub _money2: any = new(JS.Intl.NumberFormat, "en-US", {"style": "currency", "currency": "USD", "minimumFractionDigits": 2, "maximumFractionDigits": 2});
# 00:00 -> 24:00 in 30 minute steps
glob:pub TIME_OPTIONS: list[int] = [i * 30 for i in range(49)];

def:pub pad2(n: int) -> str {
    s: any = JS.String(n);
    return s.padStart(2, "0");
}

def:pub floor(x: float) -> int {
    return JS.Math.floor(x);
}

"""Monday (ISO date) of the week containing `d` (default today), in the viewer's local time."""
def:pub mondayOf(d: any = None) -> str {
    base: any = d if d else new(JS.Date);
    x: any = new(JS.Date, base.getFullYear(), base.getMonth(), base.getDate());
    x.setDate(x.getDate() - ((x.getDay() + 6) % 7));
    return str(x.getFullYear()) + "-" + pad2(x.getMonth() + 1) + "-" + pad2(x.getDate());
}

"""'Mon, Sep 28' from an ISO date."""
def:pub dateLabel(iso: str, opts: any = None) -> str {
    o: any = opts if opts else {"weekday": "short", "month": "short", "day": "numeric"};
    d: any = new(JS.Date, iso + "T12:00:00");
    return d.toLocaleDateString("en-US", o);
}

def:pub money(n: any, cents: bool = True) -> str {
    f: any = _money2 if cents else _money0;
    return f.format(n or 0);
}

def:pub relTime(seconds: float) -> str {
    if seconds <= 0 {
        return "now";
    }
    m: int = JS.Math.round(seconds / 60);
    if m < 60 {
        return "in " + str(m) + " min";
    }
    h = floor(m / 60);
    mm = m % 60;
    if h < 24 {
        return "in " + str(h) + " h" + ((" " + str(mm) + " min") if mm else "");
    }
    d: int = JS.Math.round(h / 24);
    return "in " + str(d) + " day" + ("" if d == 1 else "s");
}

def:pub downloadText(filename: str, text: str, kind: str = "text/csv") -> None {
    blob: any = new(JS.Blob, [text], {"type": kind});
    url: any = JS.URL.createObjectURL(blob);
    a: any = JS.document.createElement("a");
    a.href = url;
    a.download = filename;
    JS.document.body.appendChild(a);
    a.click();
    a.remove();
    JS.window.setTimeout(lambda { JS.URL.revokeObjectURL(url); }, 2000);
}

def:pub hm(m: int) -> str {
    return pad2(floor(m / 60)) + ":" + pad2(m % 60);
}

"""12-hour format for sentences: '10 AM', '3:30 PM'."""
def:pub h12(m: int) -> str {
    h = floor(m / 60) % 24;
    mm = m % 60;
    suffix = "PM" if h >= 12 else "AM";
    hh = 12 if h % 12 == 0 else h % 12;
    if mm {
        return str(hh) + ":" + pad2(mm) + " " + suffix;
    }
    return str(hh) + " " + suffix;
}

"""12-hour range for people: '11 AM – 3 PM'."""
def:pub range12(s: int, e: int) -> str {
    return h12(s) + " – " + h12(e);
}

def:pub hmRange(s: int, e: int) -> str {
    return hm(s) + "–" + hm(e);
}

def:pub slot(d: int, s: int, e: int) -> str {
    return DAYS[d] + " " + hmRange(s, e);
}

def:pub fmtHours(h: float) -> str {
    x: any = h;
    if JS.Number.isInteger(x) {
        return JS.String(x);
    }
    return x.toFixed(1);
}

def:pub parseHm(t: str) -> int {
    parts = t.split(":");
    h: int = JS.Number(parts[0]);
    m: int = JS.Number(parts[1]) if len(parts) > 1 else 0;
    return h * 60 + (m or 0);
}

"""'Wed 15:00-18:00' -> {day, start, end} (None if it doesn't parse)."""
def:pub parseSlot(label: str) -> any {
    rx: any = new(JS.RegExp, "^(\\w{3})\\s+(\\d{2}:\\d{2})\\s*[-–]\\s*(\\d{2}:\\d{2})$");
    s: any = label;
    m: any = s.match(rx);
    if not m {
        return None;
    }
    return {"day": DAYS.index(m[1]) if m[1] in DAYS else -1, "start": parseHm(m[2]), "end": parseHm(m[3])};
}

def:pub weekLabel(iso: str) -> str {
    d: any = new(JS.Date, iso + "T12:00:00");
    return d.toLocaleDateString("en-US", {"month": "short", "day": "numeric"});
}

def:pub shiftWeek(iso: str, delta: int) -> str {
    d: any = new(JS.Date, iso + "T12:00:00");
    d.setDate(d.getDate() + delta * 7);
    s: str = d.toISOString();
    return s[0:10];
}

def:pub ago(seconds: float) -> str {
    if seconds < 45 {
        return "just now";
    }
    m: int = JS.Math.round(seconds / 60);
    if m < 60 {
        return str(m) + "m ago";
    }
    h: int = JS.Math.round(m / 60);
    if h < 24 {
        return str(h) + "h ago";
    }
    return str(JS.Math.round(h / 24)) + "d ago";
}

def:pub greeting(d: any = None) -> str {
    x: any = d if d else new(JS.Date);
    h: int = x.getHours();
    return "Good morning" if h < 12 else ("Good afternoon" if h < 18 else "Good evening");
}

def:pub countdown(seconds: float) -> str {
    h = floor(seconds / 3600);
    m = floor((seconds % 3600) / 60);
    return str(h) + "h " + pad2(m) + "m";
}

"""n.toFixed(d) -- a fixed number of decimals, as a string."""
def:pub fixed(n: any, d: int = 0) -> str {
    x: any = JS.Number(n or 0);
    return x.toFixed(d);
}

"""A sorted copy of a JS array with a JS comparator cmp(a, b) -> negative/0/positive.
(`xs.sort(fn)` on an `any` value is Python's sort(key=...), not JavaScript's.)"""
def:pub jsSort(xs: any, cmp: any) -> any {
    copy: any = JS.Array.prototype.slice.call(xs);
    return JS.Array.prototype.sort.call(copy, cmp);
}
