"""Calendar sync -- the Availability Agent's eyes.

Three ways in, all automatic after a one-time connect:
  * google   -- OAuth. Reads busy times from the primary calendar every few minutes and writes the
                employee's shifts into a separate "CampusSync shifts" calendar (it never edits theirs)
  * ics_url  -- the calendar's secret iCal address (Google, Outlook and Apple all offer one)
  * demo     -- a built-in feed for the seed employees, so a demo needs no network
When a synced event lands on top of a published shift, the Swap Agent is triggered on the
employee's behalf. Nobody has to press anything.

Writing to Google is idempotent: every event id is derived from the shift id, so a retried unit of
work updates the same event instead of creating a second one.
"""

import base64;
import hashlib;
import hmac;
import json;
import time;
import httpx;
import from datetime { date, datetime, timedelta }
import from urllib.parse { quote, urlencode }
import from server.clock { utcnow, now_s, iso, parse_iso, today_local, slot_datetime }
import from server.config {
    DEFAULT_WEEK,
    GOOGLE_CLIENT_ID,
    GOOGLE_CLIENT_SECRET,
    PUBLIC_BASE_URL,
    SECRET,
    TIMEZONE,
    CALENDAR_SYNC_MINUTES
}
import from server.timeutil { DAY_LONG, monday_of, overlaps, slot_label }
import from server.availability { LOCAL_TZ, import_ics }
import from server.rules { Ledger }
import from server.notify { log_event, to_student }
import from server.models {
    Employee,
    Employer,
    BusyBlock,
    Shift,
    SwapRequest,
    put,
    employees,
    employer_of,
    position_of
}
import server.swaps as swaps;

glob GOOGLE_AUTH: str = "https://accounts.google.com/o/oauth2/v2/auth",
     GOOGLE_TOKEN: str = "https://oauth2.googleapis.com/token",
     GOOGLE_EVENTS: str = "https://www.googleapis.com/calendar/v3/calendars/primary/events",
     GOOGLE_CALENDARS: str = "https://www.googleapis.com/calendar/v3/calendars",
     GOOGLE_REVOKE: str = "https://oauth2.googleapis.com/revoke",
     SCOPE: str = " ".join(
         [
             "openid",
             "email",
             "https://www.googleapis.com/auth/calendar.events.readonly",
             "https://www.googleapis.com/auth/calendar.app.created"
         ]
     ),
     SHIFTS_CALENDAR_NAME: str = "CampusSync shifts",
     _tokens: dict[str, tuple[str, float]] = {};

class CalendarError(Exception) {}

def active_weeks() -> list[date] {
    today = monday_of(today_local());
    return sorted({DEFAULT_WEEK, today, today + timedelta(days=7)});
}

def google_enabled() -> bool {
    return bool(GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET);
}

# ------------------------------------------------------------------ sources
def blocks_from_ics_text(text: str) -> list[dict[str, any]] {
    seen: set[str] = set();
    out: list[dict[str, any]] = [];
    for wk in active_weeks() {
        for b in import_ics(text, wk) {
            key = f"{b['day']}|{b['start']}|{b['end']}|{b['title']}|{b['week']}";
            if key not in seen {
                seen.add(key);
                out.append(b);
            }
        }
    }
    return out;
}

def fetch_ics_url(url_in: str) -> str {
    url = url_in.strip();
    if url.startswith("webcal://") {
        url = "https://" + url[len("webcal://"):];
    }
    if not (url.startswith("https://") or url.startswith("http://")) {
        raise CalendarError("That link doesn't look like a calendar address.");
    }
    text = "";
    try {
        r = httpx.get(url, timeout=12, follow_redirects=True);
        if r.status_code >= 400 {
            raise CalendarError(
                f"The calendar link returned {r.status_code}. Check it's the secret iCal address."
            );
        }
        text = r.text;
    } except CalendarError as ce {
        raise ce;
    } except Exception {
        raise CalendarError("Couldn't reach that calendar link.");
    }
    if "BEGIN:VCALENDAR" not in text[:3000].upper() {
        raise CalendarError("That link didn't return a calendar (.ics).");
    }
    return text;
}

def demo_blocks(st: Employee) -> list[dict[str, any]] {
    out: list[dict[str, any]] = [];
    for e in (st.demo_events or []) {
        b = dict(e);
        b["week"] = b.get("week") or "";
        out.append(b);
    }
    return out;
}

# ------------------------------------------------------------------ Google OAuth
def _b64(data: bytes) -> str {
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode();
}

def _unb64(text: str) -> bytes {
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4));
}

def _sign(payload: dict[str, any]) -> str {
    body = _b64(json.dumps(payload).encode());
    sig = _b64(hmac.new(SECRET.encode(), body.encode(), hashlib.sha256).digest());
    return f"{body}.{sig}";
}

def _unsign(token: str) -> dict[str, any] | None {
    try {
        parts = token.split(".");
        if len(parts) != 2 {
            return None;
        }
        good = _b64(hmac.new(SECRET.encode(), parts[0].encode(), hashlib.sha256).digest());
        if not hmac.compare_digest(parts[1], good) {
            return None;
        }
        data = json.loads(_unb64(parts[0]));
        return data if data.get("exp", 0) > time.time() else None;
    } except Exception {
        return None;
    }
}

"""The public address Google sends people back to (env, else the origin the browser is on)."""
def base_url(origin: str = "") -> str {
    if PUBLIC_BASE_URL {
        return PUBLIC_BASE_URL;
    }
    o = (origin or "").rstrip("/");
    if o.startswith("https://") or o.startswith("http://localhost") or o.startswith("http://127.0.0.1") {
        return o;
    }
    return "http://localhost:8000";
}

def redirect_uri(origin: str = "") -> str {
    return f"{base_url(origin)}/auth/google/callback";
}

def google_auth_url(student_id: str, next_path: str, origin: str = "") -> str {
    state = _sign(
        {"sid": student_id, "next": next_path, "exp": int(time.time()) + 900, "origin": base_url(origin)}
    );
    return GOOGLE_AUTH + "?" + urlencode(
        {
            "client_id": GOOGLE_CLIENT_ID,
            "redirect_uri": redirect_uri(origin),
            "response_type": "code",
            "scope": SCOPE,
            "access_type": "offline",
            "prompt": "consent",
            "include_granted_scopes": "true",
            "state": state
        }
    );
}

def read_state(state: str) -> dict[str, any] | None {
    return _unsign(state);
}

"""The id_token comes straight from Google's token endpoint over TLS, so reading the claim is enough."""
def _id_token_email(id_token: str) -> str {
    try {
        return str(json.loads(_unb64(id_token.split(".")[1])).get("email") or "");
    } except Exception {
        return "";
    }
}

def exchange_code(code: str, origin: str = "") -> dict[str, any] {
    r: any = None;
    try {
        r = httpx.post(
            GOOGLE_TOKEN,
            data={
                "code": code,
                "client_id": GOOGLE_CLIENT_ID,
                "client_secret": GOOGLE_CLIENT_SECRET,
                "redirect_uri": redirect_uri(origin),
                "grant_type": "authorization_code"
            },
            timeout=15
        );
    } except Exception {
        raise CalendarError("Couldn't reach Google. Try connecting again.");
    }
    if r.status_code != 200 {
        raise CalendarError("Google didn't accept the sign-in. Try connecting again.");
    }
    data = r.json();
    token = data.get("refresh_token");
    if not token {
        raise CalendarError(
            "Google didn't return offline access. Remove CampusSync at myaccount.google.com → Security → "
            + "Third-party access, then connect again."
        );
    }
    granted = set(str(data.get("scope") or "").split());
    if "https://www.googleapis.com/auth/calendar.events.readonly" not in granted
        and "https://www.googleapis.com/auth/calendar.readonly" not in granted {
        raise CalendarError(
            "CampusSync needs permission to see your calendar's busy times. Connect again and tick the calendar box."
        );
    }
    if data.get("access_token") {
        _tokens[token] = (data["access_token"], time.time() + int(data.get("expires_in", 3600)) - 120);
    }
    return {
        "refresh_token": token,
        "access_token": data.get("access_token", ""),
        "email": _id_token_email(data.get("id_token", "")),
        "scopes": sorted(granted)
    };
}

def _access_token(refresh_token: str) -> str {
    cached = _tokens.get(refresh_token);
    if cached and cached[1] > time.time() {
        return cached[0];
    }
    r: any = None;
    try {
        r = httpx.post(
            GOOGLE_TOKEN,
            data={
                "refresh_token": refresh_token,
                "client_id": GOOGLE_CLIENT_ID,
                "client_secret": GOOGLE_CLIENT_SECRET,
                "grant_type": "refresh_token"
            },
            timeout=15
        );
    } except Exception {
        raise CalendarError("Couldn't reach Google right now — will retry automatically.");
    }
    if r.status_code != 200 {
        if "invalid_grant" in r.text {
            raise CalendarError("Google access expired or was removed. Reconnect Google Calendar.");
        }
        raise CalendarError("Google didn't refresh access — will retry automatically.");
    }
    data = r.json();
    _tokens[refresh_token] = (data["access_token"], time.time() + int(data.get("expires_in", 3600)) - 120);
    return data["access_token"];
}

def revoke(refresh_token: str) {
    _tokens.pop(refresh_token, None);
    try {
        httpx.post(GOOGLE_REVOKE, params={"token": refresh_token}, timeout=10);
    } except Exception { }
}

def _parse_google_dt(value: str) -> datetime {
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"));
    if dt.tzinfo is not None {
        dt = dt.astimezone(LOCAL_TZ);
    }
    return dt.replace(tzinfo=None);
}

"""Google Calendar API events (singleEvents=true) -> week-specific busy blocks."""
def google_events_to_blocks(items: list[dict[str, any]]) -> list[dict[str, any]] {
    out: list[dict[str, any]] = [];
    for ev in items {
        if ev.get("status") == "cancelled" or ev.get("transparency") == "transparent" {
            continue;
        }
        if ev.get("eventType") in ("workingLocation", "birthday") {
            continue;
        }
        me: dict[str, any] | None = None;
        for a in (ev.get("attendees") or []) {
            if a.get("self") {
                me = a;
                break;
            }
        }
        if me is not None and me.get("responseStatus") == "declined" {
            continue;
        }
        s = (ev.get("start") or {}).get("dateTime");
        e = (ev.get("end") or {}).get("dateTime");
        if not s or not e {
            continue;  # all-day events don't block work
        }
        start = _parse_google_dt(s);
        end = _parse_google_dt(e);
        if end <= start or (end - start) > timedelta(hours=12) {
            continue;
        }
        e_min = end.hour * 60 + end.minute if end.date() == start.date() else 24 * 60;
        out.append(
            {
                "day": start.weekday(),
                "start": start.hour * 60 + start.minute,
                "end": e_min,
                "title": (ev.get("summary") or "Busy")[:60],
                "week": monday_of(start.date()).isoformat()
            }
        );
    }
    return out;
}

def _g(method: str, url: str, token: str, params: dict[str, any] | None = None, body: dict[str, any] | None = None) -> any {
    try {
        return httpx.request(
            method, url, headers={"Authorization": f"Bearer {token}"}, timeout=15, params=params, json=body
        );
    } except Exception {
        raise CalendarError("Couldn't reach Google right now — will retry automatically.");
    }
}

def google_blocks(refresh_token: str) -> list[dict[str, any]] {
    token = _access_token(refresh_token);
    weeks = active_weeks();
    lo = datetime.combine(weeks[0], datetime.min.time()).replace(tzinfo=LOCAL_TZ);
    hi = datetime.combine(weeks[-1] + timedelta(days=7), datetime.min.time()).replace(tzinfo=LOCAL_TZ);
    items: list[dict[str, any]] = [];
    page = "";
    for _i in range(5) {
        params: dict[str, any] = {
            "timeMin": lo.isoformat(),
            "timeMax": hi.isoformat(),
            "singleEvents": "true",
            "orderBy": "startTime",
            "maxResults": 250
        };
        if page {
            params["pageToken"] = page;
        }
        r = _g("GET", GOOGLE_EVENTS, token, params=params);
        if r.status_code in (401, 403) {
            _tokens.pop(refresh_token, None);
            raise CalendarError(
                "Google refused access to your calendar. Reconnect Google Calendar and allow calendar access."
            );
        }
        if r.status_code != 200 {
            raise CalendarError("Couldn't read your Google Calendar — will retry automatically.");
        }
        data = r.json();
        items = items + (data.get("items") or []);
        page = data.get("nextPageToken") or "";
        if not page {
            break;
        }
    }
    return google_events_to_blocks(items);
}

# ------------------------------------------------------------------ writing shifts to Google
def _ensure_shift_calendar(st: Employee, token: str, tzname: str) -> str {
    if st.google_calendar_id {
        r = _g("GET", f"{GOOGLE_CALENDARS}/{quote(st.google_calendar_id, safe='')}", token);
        if r.status_code == 200 {
            return st.google_calendar_id;
        }
        if r.status_code not in (404, 410) {
            raise CalendarError("Couldn't check your CampusSync shifts calendar.");
        }
    }
    r2 = _g(
        "POST",
        GOOGLE_CALENDARS,
        token,
        body={
            "summary": SHIFTS_CALENDAR_NAME,
            "timeZone": tzname,
            "description": "Your work shifts, kept up to date by CampusSync."
        }
    );
    if r2.status_code not in (200, 201) {
        raise CalendarError(
            "Couldn't create the CampusSync shifts calendar (permission missing?). Reconnect Google Calendar."
        );
    }
    st.google_calendar_id = r2.json()["id"];
    return st.google_calendar_id;
}

"""What the employee's shifts calendar should contain: published shifts from this week on (4 weeks)."""
def upcoming_shift_events(st: Employee) -> list[dict[str, any]] {
    this_week = monday_of(today_local());
    weeks = [(this_week + timedelta(days=7 * i)).isoformat() for i in range(0, 4)];
    sid = jid(st);
    rows = sorted(
        [s for s in [_q for _q in [st --> [?:Shift]] if _q.status == "published"] if s.student == sid and s.week in weeks],
        key=lambda (s: Shift) -> str { return s.created; }
    );
    out: list[dict[str, any]] = [];
    for sh in rows {
        d = employer_of(sh.employer);
        if d is None {
            continue;
        }
        p = position_of(sh.position);
        role = p.name if p is not None else "";
        start = slot_datetime(sh.week, sh.day, sh.start, d.timezone);
        end = slot_datetime(sh.week, sh.day, sh.end, d.timezone);
        out.append(
            {
                "shift_id": jid(sh),
                "tz": d.timezone,
                "summary": f"{d.name} shift" + (f" · {role}" if role else ""),
                "start": start.strftime("%Y-%m-%dT%H:%M:%S"),
                "end": end.strftime("%Y-%m-%dT%H:%M:%S")
            }
        );
    }
    return out;
}

def shifts_signature(events: list[dict[str, any]]) -> str {
    rows = sorted([[e["shift_id"], e["summary"], e["start"], e["end"]] for e in events]);
    return hashlib.sha256(json.dumps(rows).encode()).hexdigest();
}

def _event_id(shift_id: str) -> str {
    return "cs" + shift_id.replace("-", "").lower();
}

"""Mirror upcoming shifts into the employee's "CampusSync shifts" Google calendar. Returns changes made."""
def write_shifts(st: Employee) -> int {
    if st.calendar_source != "google" or not st.google_refresh_token {
        return 0;
    }
    token = _access_token(st.google_refresh_token);
    events = upcoming_shift_events(st);
    tzname = events[0]["tz"] if events else TIMEZONE;
    if not events and not st.google_calendar_id {
        st.shifts_signature = shifts_signature(events);
        return 0;
    }
    cal = _ensure_shift_calendar(st, token, tzname);
    base = f"{GOOGLE_CALENDARS}/{quote(cal, safe='')}/events";
    # What is in our calendar right now (it's ours alone, so everything there is a shift we wrote).
    existing: dict[str, dict[str, any]] = {};
    page = "";
    lo = datetime.combine(monday_of(today_local()) - timedelta(days=7), datetime.min.time()).replace(tzinfo=LOCAL_TZ);
    for _i in range(5) {
        params: dict[str, any] = {"timeMin": lo.isoformat(), "maxResults": 250, "showDeleted": "false"};
        if page {
            params["pageToken"] = page;
        }
        r = _g("GET", base, token, params=params);
        if r.status_code != 200 {
            raise CalendarError("Couldn't read your CampusSync shifts calendar — will retry.");
        }
        data = r.json();
        for ev in (data.get("items") or []) {
            if ev.get("status") != "cancelled" {
                existing[str(ev.get("id"))] = ev;
            }
        }
        page = data.get("nextPageToken") or "";
        if not page {
            break;
        }
    }
    changes = 0;
    wanted: dict[str, dict[str, any]] = {};
    for e in events {
        wanted[_event_id(e["shift_id"])] = e;
    }
    for (eid, e) in wanted.items() {
        sig = f"{e['summary']}|{e['start']}|{e['end']}|{e['tz']}";
        body = {
            "id": eid,
            "summary": e["summary"],
            "description": "Scheduled with CampusSync. Swaps and changes update this automatically.",
            "start": {"dateTime": e["start"], "timeZone": e["tz"]},
            "end": {"dateTime": e["end"], "timeZone": e["tz"]},
            "source": {"title": "CampusSync", "url": f"{base_url()}/s"},
            "extendedProperties": {"private": {"campussync_shift": e["shift_id"], "campussync_sig": sig}},
            "reminders": {"useDefault": False, "overrides": []},
            "status": "confirmed"
        };
        have = existing.get(eid);
        if have is not None {
            props = ((have.get("extendedProperties") or {}).get("private") or {});
            if props.get("campussync_sig") == sig {
                continue;
            }
            r = _g("PUT", f"{base}/{quote(eid, safe='')}", token, body=body);
            if r.status_code != 200 {
                raise CalendarError("Couldn't update a shift in your Google Calendar — will retry.");
            }
            changes += 1;
            continue;
        }
        r = _g("POST", base, token, body=body);
        if r.status_code == 409 {
            # Same id written before (a retry, or a shift that came back): update it in place.
            r = _g("PUT", f"{base}/{quote(eid, safe='')}", token, body=body);
        }
        if r.status_code not in (200, 201) {
            raise CalendarError("Couldn't add your shifts to Google Calendar — will retry.");
        }
        changes += 1;
    }
    for eid in existing {
        if eid in wanted or not eid.startswith("cs") {
            continue;
        }
        r = _g("DELETE", f"{base}/{quote(eid, safe='')}", token);
        if r.status_code not in (200, 204, 404, 410) {
            raise CalendarError("Couldn't remove an old shift from your Google Calendar — will retry.");
        }
        changes += 1;
    }
    st.shifts_signature = shifts_signature(events);
    return changes;
}

"""Remove the shifts calendar we created, revoke access, forget the tokens."""
def disconnect_google(st: Employee) {
    if st.google_refresh_token {
        try {
            if st.google_calendar_id {
                token = _access_token(st.google_refresh_token);
                _g("DELETE", f"{GOOGLE_CALENDARS}/{quote(st.google_calendar_id, safe='')}", token);
            }
        } except CalendarError { }
        revoke(st.google_refresh_token);
    }
    st.google_refresh_token = "";
    st.google_calendar_id = "";
    st.google_email = "";
    st.shifts_signature = "";
}

# ------------------------------------------------------------------ sync + disruption detection
def _blocks_for(st: Employee) -> list[dict[str, any]] {
    if st.calendar_source == "google" {
        return google_blocks(st.google_refresh_token);
    }
    if st.calendar_source == "ics_url" {
        return blocks_from_ics_text(fetch_ics_url(st.calendar_url));
    }
    if st.calendar_source == "demo" {
        return demo_blocks(st);
    }
    raise CalendarError("No calendar connected.");
}

def calendar_blocks(st: Employee) -> list[BusyBlock] {
    return [st --> [?:BusyBlock, source == "calendar"]];
}

def replace_calendar_blocks(st: Employee, blocks: list[dict[str, any]]) {
    for b in calendar_blocks(st) {
        del b;
    }
    for b in blocks {
        put(
            st,
            BusyBlock(
                day=b["day"], start=b["start"], end=b["end"], title=b.get("title", "Busy") or "Busy",
                source="calendar", week=b.get("week") or ""
            )
        );
    }
}

"""Pull the employee's calendar, replace their calendar blocks, then look for new clashes."""
def sync_student(st: Employee, announce: bool = False) -> dict[str, any] {
    if st.calendar_source in ("", "upload") {
        return {"ok": True, "skipped": True};
    }
    blocks: list[dict[str, any]] = [];
    try {
        blocks = _blocks_for(st);
    } except CalendarError as ce {
        st.calendar_error = str(ce);
        st.calendar_synced_at = now_s();  # back off until the next sync window instead of hammering Google
        return {"ok": False, "error": str(ce)};
    }
    before = {f"{b.day}|{b.start}|{b.end}|{b.week}" for b in calendar_blocks(st)};
    after = {f"{b['day']}|{b['start']}|{b['end']}|{b.get('week') or ''}" for b in blocks};
    changed = before != after;
    if changed or len(calendar_blocks(st)) != len(blocks) {
        replace_calendar_blocks(st, blocks);
    }
    st.calendar_synced_at = now_s();
    if st.calendar_error {
        st.calendar_error = "";
    }
    if changed or announce {
        label = {"google": "Google Calendar", "ics_url": "calendar", "demo": "Google Calendar"}.get(
            st.calendar_source, "calendar"
        );
        log_event(
            "Availability Agent",
            f"Synced your {label} · {len(blocks)} events" + (" · changes found" if changed and before else ""),
            student=st,
            level="info"
        );
    }
    raised = detect_disruptions(st) if changed or announce else [];
    written = 0;
    if st.calendar_source == "google" {
        try {
            written = write_shifts(st);
        } except CalendarError as ce2 {
            st.calendar_error = str(ce2);
        }
    }
    return {"ok": True, "events": len(blocks), "changed": changed, "disruptions": raised, "shifts_written": written};
}

"""A published shift now overlaps the employee's calendar -> raise a swap/cover request for them."""
def detect_disruptions(st: Employee) -> list[str] {
    raised: list[str] = [];
    weeks = {w.isoformat() for w in active_weeks()};
    sid = jid(st);
    shifts = sorted(
        [
            s for s in [_q for _q in [st --> [?:Shift]] if _q.status == "published" and _q.state == "assigned"]
            if s.student == sid and s.week in weeks
        ],
        key=lambda (s: Shift) -> str { return s.created; }
    );
    for sh in shifts {
        ledger = Ledger(week=sh.week);
        clash: any = None;
        for b in ledger.busy(sid) {
            if b.day == sh.day and overlaps(sh.start, sh.end, b.start, b.end) {
                clash = b;
                break;
            }
        }
        if clash is None {
            continue;
        }
        e = employer_of(sh.employer);
        if e is None {
            continue;
        }
        shj = jid(sh);
        if any([r.state in swaps.ACTIVE_REQUEST_STATES for r in [e --> [?:SwapRequest, shift == shj]]]) {
            continue;
        }
        label = slot_label(sh.day, sh.start, sh.end);
        want_days = [d for d in (st.open_swap_days or []) if d != sh.day];
        to_student(st, f"“{clash.title}” overlaps your {label} shift. Autopilot is finding cover — nothing for you to do.", "/s");
        log_event(
            "Availability Agent",
            f"“{clash.title}” overlaps your {label} shift — asking the Swap Agent for cover",
            student=st,
            level="alert"
        );
        log_event(
            "Availability Agent",
            f"{st.first_name()} can no longer make {label} (calendar change). Swap Agent is on it.",
            employer=e,
            level="alert"
        );
        try {
            req = swaps.create_request(
                st, shj, "days" if want_days else "any", want_days, f"Calendar: {clash.title}", origin="calendar"
            );
            raised.append(jid(req));
        } except swaps.SwapError { }
    }
    return raised;
}

"""Background: sync every connected calendar that hasn't been synced recently."""
def sync_due() -> int {
    cutoff = utcnow() - timedelta(minutes=CALENDAR_SYNC_MINUTES);
    n = 0;
    for st in employees() {
        if st.calendar_source not in ("google", "ics_url", "demo") {
            continue;
        }
        last = parse_iso(st.calendar_synced_at);
        if last is None or last < cutoff {
            sync_student(st);
            n += 1;
        } elif st.calendar_source == "demo" {
            _sync_demo_quietly(st);
        } elif st.calendar_source == "google" and st.google_refresh_token {
            # Shifts changed since we last wrote them (publish, swap, pickup)? Mirror right away.
            wanted = shifts_signature(upcoming_shift_events(st));
            if wanted != (st.shifts_signature or "") {
                try {
                    write_shifts(st);
                    if st.calendar_error {
                        st.calendar_error = "";
                    }
                } except CalendarError as ce {
                    st.calendar_error = str(ce);
                    st.shifts_signature = wanted;  # retried at the next full sync, not every cycle
                }
            }
        }
    }
    return n;
}

"""The demo feed is local: re-read it every cycle, but only touch the graph when it changed."""
def _sync_demo_quietly(st: Employee) {
    blocks = demo_blocks(st);
    before = {f"{b.day}|{b.start}|{b.end}|{b.week}" for b in calendar_blocks(st)};
    after = {f"{b['day']}|{b['start']}|{b['end']}|{b.get('week') or ''}" for b in blocks};
    if before != after {
        sync_student(st);
    }
}

def day_name(d: int) -> str {
    return DAY_LONG[d];
}
