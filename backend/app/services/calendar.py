"""Calendar sync — the Availability Agent's eyes.

Three ways in, all automatic after a one-time connect:
  * google   — OAuth. Reads busy times from the primary calendar every few minutes and writes the
               employee's shifts into a separate "CampusSync shifts" calendar (it never edits theirs)
  * ics_url  — the calendar's secret iCal address (Google, Outlook and Apple all offer one)
  * demo     — a built-in feed for the seed students, so the stage demo needs no network
When a synced event lands on top of a published shift, the Swap Agent is triggered on the
student's behalf. Nobody has to press anything.
"""
from __future__ import annotations

import json
import time
from datetime import date, datetime, timedelta
from urllib.parse import quote, urlencode

import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import clock
from .. import config
from ..agents.availability import LOCAL_TZ, import_ics
from ..agents.rules import Ledger
from ..auth import _b64, _unb64
from ..events import log
from ..models import BusyBlock, Shift, Student, SwapRequest
from ..notify import to_student
from ..timeutil import DAY_LONG, monday_of, overlaps, slot_label

GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"
GOOGLE_EVENTS = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
GOOGLE_CALENDARS = "https://www.googleapis.com/calendar/v3/calendars"
GOOGLE_REVOKE = "https://oauth2.googleapis.com/revoke"
SCOPES = [
    "openid", "email",
    "https://www.googleapis.com/auth/calendar.events.readonly",  # read busy times
    "https://www.googleapis.com/auth/calendar.app.created",  # own the "CampusSync shifts" calendar
]
SCOPE = " ".join(SCOPES)
SHIFTS_CALENDAR_NAME = "CampusSync shifts"
_tokens: dict[str, tuple[str, float]] = {}  # refresh token -> (access token, expiry)


class CalendarError(Exception):
    pass


def active_weeks() -> list[date]:
    today = monday_of(clock.today_local())
    return sorted({config.DEFAULT_WEEK, today, today + timedelta(days=7)})


def google_enabled() -> bool:
    return bool(config.GOOGLE_CLIENT_ID and config.GOOGLE_CLIENT_SECRET)


# ------------------------------------------------------------------ sources
def blocks_from_ics_text(text: str) -> list[dict]:
    seen, out = set(), []
    for wk in active_weeks():
        for b in import_ics(text, wk):
            key = (b["day"], b["start"], b["end"], b["title"], b.get("week"))
            if key not in seen:
                seen.add(key)
                out.append(b)
    return out


def fetch_ics_url(url: str) -> str:
    url = url.strip()
    if url.startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]
    if not url.startswith(("https://", "http://")):
        raise CalendarError("That link doesn't look like a calendar address.")
    try:
        r = httpx.get(url, timeout=12, follow_redirects=True)
        r.raise_for_status()
    except httpx.HTTPStatusError as e:
        raise CalendarError(f"The calendar link returned {e.response.status_code}. Check it's the secret iCal address.")
    except Exception:
        raise CalendarError("Couldn't reach that calendar link.")
    if "BEGIN:VCALENDAR" not in r.text[:3000].upper():
        raise CalendarError("That link didn't return a calendar (.ics).")
    return r.text


def demo_blocks(st: Student) -> list[dict]:
    return [dict(e) for e in (st.demo_events or [])]


# ------------------------------------------------------------------ Google OAuth
def _sign(payload: dict) -> str:
    import hashlib
    import hmac

    body = _b64(json.dumps(payload).encode())
    sig = _b64(hmac.new(config.SECRET.encode(), body.encode(), hashlib.sha256).digest())
    return f"{body}.{sig}"


def _unsign(token: str) -> dict | None:
    import hashlib
    import hmac

    try:
        body, sig = token.split(".")
        good = _b64(hmac.new(config.SECRET.encode(), body.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, good):
            return None
        data = json.loads(_unb64(body))
        return data if data.get("exp", 0) > time.time() else None
    except Exception:
        return None


def redirect_uri() -> str:
    return f"{config.PUBLIC_BASE_URL}/auth/google/callback"


def google_auth_url(student_id: int, next_path: str) -> str:
    state = _sign({"sid": student_id, "next": next_path, "exp": int(time.time()) + 900})
    return GOOGLE_AUTH + "?" + urlencode({
        "client_id": config.GOOGLE_CLIENT_ID, "redirect_uri": redirect_uri(), "response_type": "code",
        "scope": SCOPE, "access_type": "offline", "prompt": "consent", "include_granted_scopes": "true", "state": state,
    })


def read_state(state: str) -> dict | None:
    return _unsign(state)


def _id_token_email(id_token: str) -> str:
    """The id_token comes straight from Google's token endpoint over TLS, so reading the claim is enough."""
    try:
        return str(json.loads(_unb64(id_token.split(".")[1])).get("email") or "")
    except Exception:
        return ""


def exchange_code(code: str) -> dict:
    """-> {"refresh_token", "access_token", "email", "scopes"}"""
    try:
        r = httpx.post(GOOGLE_TOKEN, data={
            "code": code, "client_id": config.GOOGLE_CLIENT_ID, "client_secret": config.GOOGLE_CLIENT_SECRET,
            "redirect_uri": redirect_uri(), "grant_type": "authorization_code"}, timeout=15)
    except httpx.HTTPError:
        raise CalendarError("Couldn't reach Google. Try connecting again.")
    if r.status_code != 200:
        raise CalendarError("Google didn't accept the sign-in. Try connecting again.")
    data = r.json()
    token = data.get("refresh_token")
    if not token:
        raise CalendarError("Google didn't return offline access. Remove CampusSync at myaccount.google.com → Security → "
                            "Third-party access, then connect again.")
    granted = set(str(data.get("scope") or "").split())
    if "https://www.googleapis.com/auth/calendar.events.readonly" not in granted and "https://www.googleapis.com/auth/calendar.readonly" not in granted:
        raise CalendarError("CampusSync needs permission to see your calendar's busy times. Connect again and tick the calendar box.")
    if data.get("access_token"):
        _tokens[token] = (data["access_token"], time.time() + int(data.get("expires_in", 3600)) - 120)
    return {"refresh_token": token, "access_token": data.get("access_token", ""), "email": _id_token_email(data.get("id_token", "")),
            "scopes": sorted(granted)}


def _access_token(refresh_token: str) -> str:
    cached = _tokens.get(refresh_token)
    if cached and cached[1] > time.time():
        return cached[0]
    try:
        r = httpx.post(GOOGLE_TOKEN, data={
            "refresh_token": refresh_token, "client_id": config.GOOGLE_CLIENT_ID,
            "client_secret": config.GOOGLE_CLIENT_SECRET, "grant_type": "refresh_token"}, timeout=15)
    except httpx.HTTPError:
        raise CalendarError("Couldn't reach Google right now — will retry automatically.")
    if r.status_code != 200:
        if "invalid_grant" in r.text:
            raise CalendarError("Google access expired or was removed. Reconnect Google Calendar.")
        raise CalendarError("Google didn't refresh access — will retry automatically.")
    data = r.json()
    _tokens[refresh_token] = (data["access_token"], time.time() + int(data.get("expires_in", 3600)) - 120)
    return data["access_token"]


def revoke(refresh_token: str) -> None:
    _tokens.pop(refresh_token, None)
    try:
        httpx.post(GOOGLE_REVOKE, params={"token": refresh_token}, timeout=10)
    except httpx.HTTPError:
        pass


def _parse_google_dt(value: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is not None and LOCAL_TZ is not None:
        dt = dt.astimezone(LOCAL_TZ)
    return dt.replace(tzinfo=None)


def google_events_to_blocks(items: list[dict]) -> list[dict]:
    """Google Calendar API events (singleEvents=true) -> week-specific busy blocks."""
    out = []
    for ev in items:
        if ev.get("status") == "cancelled" or ev.get("transparency") == "transparent":
            continue
        if ev.get("eventType") in ("workingLocation", "birthday"):
            continue
        me = next((a for a in ev.get("attendees") or [] if a.get("self")), None)
        if me and me.get("responseStatus") == "declined":
            continue
        s, e = ev.get("start", {}).get("dateTime"), ev.get("end", {}).get("dateTime")
        if not s or not e:
            continue  # all-day events don't block work
        start, end = _parse_google_dt(s), _parse_google_dt(e)
        if end <= start or (end - start) > timedelta(hours=12):
            continue
        e_min = end.hour * 60 + end.minute if end.date() == start.date() else 24 * 60
        out.append({"day": start.weekday(), "start": start.hour * 60 + start.minute, "end": e_min,
                    "title": (ev.get("summary") or "Busy")[:60], "week": monday_of(start.date()).isoformat()})
    return out


def google_blocks(refresh_token: str) -> list[dict]:
    token = _access_token(refresh_token)
    weeks = active_weeks()
    lo = datetime.combine(weeks[0], datetime.min.time())
    hi = datetime.combine(weeks[-1] + timedelta(days=7), datetime.min.time())
    if LOCAL_TZ is not None:
        lo, hi = lo.replace(tzinfo=LOCAL_TZ), hi.replace(tzinfo=LOCAL_TZ)
    items: list[dict] = []
    page = None
    for _ in range(5):
        params = {"timeMin": lo.isoformat(), "timeMax": hi.isoformat(), "singleEvents": "true", "orderBy": "startTime", "maxResults": 250}
        if page:
            params["pageToken"] = page
        try:
            r = httpx.get(GOOGLE_EVENTS, headers={"Authorization": f"Bearer {token}"}, timeout=15, params=params)
        except httpx.HTTPError:
            raise CalendarError("Couldn't reach Google right now — will retry automatically.")
        if r.status_code in (401, 403):
            _tokens.pop(refresh_token, None)
            raise CalendarError("Google refused access to your calendar. Reconnect Google Calendar and allow calendar access.")
        if r.status_code != 200:
            raise CalendarError("Couldn't read your Google Calendar — will retry automatically.")
        data = r.json()
        items += data.get("items", [])
        page = data.get("nextPageToken")
        if not page:
            break
    return google_events_to_blocks(items)


# ------------------------------------------------------------------ writing shifts to Google
def _g(method: str, url: str, token: str, **kw) -> httpx.Response:
    try:
        return httpx.request(method, url, headers={"Authorization": f"Bearer {token}"}, timeout=15, **kw)
    except httpx.HTTPError:
        raise CalendarError("Couldn't reach Google right now — will retry automatically.")


def _ensure_shift_calendar(st: Student, token: str, tzname: str) -> str:
    if st.google_calendar_id:
        r = _g("GET", f"{GOOGLE_CALENDARS}/{quote(st.google_calendar_id, safe='')}", token)
        if r.status_code == 200:
            return st.google_calendar_id
        if r.status_code not in (404, 410):
            raise CalendarError("Couldn't check your CampusSync shifts calendar.")
    r = _g("POST", GOOGLE_CALENDARS, token, json={"summary": SHIFTS_CALENDAR_NAME, "timeZone": tzname,
                                                  "description": "Your work shifts, kept up to date by CampusSync."})
    if r.status_code not in (200, 201):
        raise CalendarError("Couldn't create the CampusSync shifts calendar (permission missing?). Reconnect Google Calendar.")
    st.google_calendar_id = r.json()["id"]
    return st.google_calendar_id


def upcoming_shift_events(db: Session, st: Student) -> list[dict]:
    """What the employee's shifts calendar should contain: published shifts from this week on (3 weeks)."""
    from ..models import Department, Position

    this_week = monday_of(clock.today_local())
    weeks = [(this_week + timedelta(days=7 * i)).isoformat() for i in range(0, 4)]
    rows = db.scalars(select(Shift).where(Shift.student_id == st.id, Shift.status == "published", Shift.week.in_(weeks))).all()
    out = []
    for sh in rows:
        d = db.get(Department, sh.department_id)
        role = db.get(Position, sh.position_id).name if sh.position_id and db.get(Position, sh.position_id) else ""
        start = clock.slot_datetime(sh.week, sh.day, sh.start, d.timezone)
        end = clock.slot_datetime(sh.week, sh.day, sh.end, d.timezone)
        summary = f"{d.name} shift" + (f" · {role}" if role else "")
        out.append({"shift_id": sh.id, "tz": d.timezone, "summary": summary,
                    "start": start.strftime("%Y-%m-%dT%H:%M:%S"), "end": end.strftime("%Y-%m-%dT%H:%M:%S")})
    return out


def shifts_signature(events: list[dict]) -> str:
    import hashlib

    raw = json.dumps(sorted((e["shift_id"], e["summary"], e["start"], e["end"]) for e in events))
    return hashlib.sha256(raw.encode()).hexdigest()


def write_shifts(db: Session, st: Student) -> int:
    """Mirror upcoming shifts into the employee's "CampusSync shifts" Google calendar. Returns changes made."""
    from ..models import CalendarEventLink, Department

    if st.calendar_source != "google" or not st.google_refresh_token:
        return 0
    token = _access_token(st.google_refresh_token)
    events = upcoming_shift_events(db, st)
    tzname = events[0]["tz"] if events else config.TIMEZONE
    if not events and not st.google_calendar_id:
        st.shifts_signature = shifts_signature(events)
        return 0
    cal = _ensure_shift_calendar(st, token, tzname)
    base = f"{GOOGLE_CALENDARS}/{quote(cal, safe='')}/events"
    links = {l.shift_id: l for l in db.scalars(select(CalendarEventLink).where(CalendarEventLink.student_id == st.id))}
    changes = 0
    wanted = {e["shift_id"]: e for e in events}
    for sid, e in wanted.items():
        sig = f"{e['summary']}|{e['start']}|{e['end']}|{e['tz']}"
        body = {"summary": e["summary"], "description": "Scheduled with CampusSync. Swaps and changes update this automatically.",
                "start": {"dateTime": e["start"], "timeZone": e["tz"]}, "end": {"dateTime": e["end"], "timeZone": e["tz"]},
                "source": {"title": "CampusSync", "url": f"{config.PUBLIC_BASE_URL}/s"},
                "extendedProperties": {"private": {"campussync_shift": str(sid)}},
                "reminders": {"useDefault": False, "overrides": []}}  # CampusSync sends its own 24 h / 1 h alerts
        link = links.get(sid)
        if link and link.signature == sig:
            continue
        if link:
            r = _g("PUT", f"{base}/{quote(link.event_id, safe='')}", token, json=body)
            if r.status_code in (404, 410):
                link = None
            elif r.status_code != 200:
                raise CalendarError("Couldn't update a shift in your Google Calendar — will retry.")
            else:
                link.signature = sig
                changes += 1
        if not link:
            r = _g("POST", base, token, json=body)
            if r.status_code not in (200, 201):
                raise CalendarError("Couldn't add your shifts to Google Calendar — will retry.")
            db.add(CalendarEventLink(student_id=st.id, shift_id=sid, event_id=r.json()["id"], signature=sig))
            changes += 1
    for sid, link in links.items():
        if sid in wanted:
            continue
        r = _g("DELETE", f"{base}/{quote(link.event_id, safe='')}", token)
        if r.status_code not in (200, 204, 404, 410):
            raise CalendarError("Couldn't remove an old shift from your Google Calendar — will retry.")
        db.delete(link)
        changes += 1
    st.shifts_signature = shifts_signature(events)
    db.flush()
    return changes


def disconnect_google(db: Session, st: Student) -> None:
    """Remove the shifts calendar we created, revoke access, forget the tokens."""
    from ..models import CalendarEventLink

    if st.google_refresh_token:
        try:
            if st.google_calendar_id:
                token = _access_token(st.google_refresh_token)
                _g("DELETE", f"{GOOGLE_CALENDARS}/{quote(st.google_calendar_id, safe='')}", token)
        except CalendarError:
            pass
        revoke(st.google_refresh_token)
    for l in db.scalars(select(CalendarEventLink).where(CalendarEventLink.student_id == st.id)):
        db.delete(l)
    st.google_refresh_token = st.google_calendar_id = st.google_email = ""
    st.shifts_signature = ""


# ------------------------------------------------------------------ sync + disruption detection
def _blocks_for(st: Student) -> list[dict]:
    if st.calendar_source == "google":
        return google_blocks(st.google_refresh_token)
    if st.calendar_source == "ics_url":
        return blocks_from_ics_text(fetch_ics_url(st.calendar_url))
    if st.calendar_source == "demo":
        return demo_blocks(st)
    raise CalendarError("No calendar connected.")


def replace_calendar_blocks(db: Session, st: Student, blocks: list[dict]) -> None:
    for b in db.scalars(select(BusyBlock).where(BusyBlock.student_id == st.id, BusyBlock.source == "calendar")):
        db.delete(b)
    for b in blocks:
        db.add(BusyBlock(student_id=st.id, day=b["day"], start=b["start"], end=b["end"], title=b.get("title", "Busy"),
                         source="calendar", week=b.get("week")))
    db.flush()


def sync_student(db: Session, st: Student, *, announce: bool = False) -> dict:
    """Pull the student's calendar, replace their calendar blocks, then look for new clashes."""
    if st.calendar_source in ("", "upload"):
        return {"ok": True, "skipped": True}
    try:
        blocks = _blocks_for(st)
    except CalendarError as e:
        st.calendar_error = str(e)
        st.calendar_synced_at = clock.utcnow()  # back off until the next sync window instead of hammering Google
        db.commit()
        return {"ok": False, "error": str(e)}
    before = {(b.day, b.start, b.end, b.week) for b in db.scalars(select(BusyBlock).where(BusyBlock.student_id == st.id, BusyBlock.source == "calendar"))}
    replace_calendar_blocks(db, st, blocks)
    after = {(b["day"], b["start"], b["end"], b.get("week")) for b in blocks}
    st.calendar_synced_at = clock.utcnow()
    st.calendar_error = ""
    changed = before != after
    if changed or announce:
        label = {"google": "Google Calendar", "ics_url": "calendar", "demo": "Google Calendar"}.get(st.calendar_source, "calendar")
        log(db, "Availability Agent", f"Synced your {label} · {len(blocks)} events" + (" · changes found" if changed and before else ""),
            student_id=st.id, level="info")
    db.commit()
    raised = detect_disruptions(db, st) if changed or announce else []
    written = 0
    if st.calendar_source == "google":
        try:
            written = write_shifts(db, st)
            db.commit()
        except CalendarError as e:
            db.rollback()
            st = db.get(Student, st.id)
            st.calendar_error = str(e)
            db.commit()
    return {"ok": True, "events": len(blocks), "changed": changed, "disruptions": raised, "shifts_written": written}


def detect_disruptions(db: Session, st: Student) -> list[int]:
    """A published shift now overlaps the student's calendar -> raise a swap/cover request for them."""
    from . import swaps  # local import: swaps imports agents that import this package

    raised: list[int] = []
    weeks = {w.isoformat() for w in active_weeks()}
    shifts = db.scalars(select(Shift).where(Shift.student_id == st.id, Shift.status == "published",
                                            Shift.state == "assigned", Shift.week.in_(weeks))).all()
    for sh in shifts:
        ledger = Ledger(db, sh.week)
        clash = next((b for b in ledger.busy(st.id) if b.day == sh.day and overlaps(sh.start, sh.end, b.start, b.end)), None)
        if not clash:
            continue
        open_req = db.scalar(select(SwapRequest).where(SwapRequest.shift_id == sh.id, SwapRequest.state.in_(swaps.ACTIVE_REQUEST_STATES)))
        if open_req:
            continue
        label = slot_label(sh.day, sh.start, sh.end)
        to_student(db, st.id, f"“{clash.title}” overlaps your {label} shift. Autopilot is finding cover — nothing for you to do.", "/s")
        log(db, "Availability Agent", f"“{clash.title}” overlaps your {label} shift — asking the Swap Agent for cover",
            student_id=st.id, level="alert")
        log(db, "Availability Agent", f"{st.first_name} can no longer make {label} (calendar change). Swap Agent is on it.",
            department_id=sh.department_id, level="alert")
        want_days = [d for d in (st.open_swap_days or []) if d != sh.day]
        try:
            req = swaps.create_request(db, st, sh.id, "days" if want_days else "any", want_days,
                                       f"Calendar: {clash.title}", origin="calendar")
            raised.append(req.id)
        except swaps.SwapError:
            db.rollback()
    return raised


def sync_due(db: Session) -> int:
    """Background: sync every connected calendar that hasn't been synced recently."""
    cutoff = clock.utcnow() - timedelta(minutes=config.CALENDAR_SYNC_MINUTES)
    n = 0
    for st in db.scalars(select(Student).where(Student.calendar_source.in_(("google", "ics_url", "demo")))).all():
        if st.calendar_synced_at is None or st.calendar_synced_at < cutoff or st.calendar_source == "demo":
            sync_student(db, st)
            n += 1
        elif st.calendar_source == "google" and st.google_refresh_token:
            # Shifts changed since we last wrote them (publish, swap, pickup)? Mirror right away.
            wanted = shifts_signature(upcoming_shift_events(db, st))
            if wanted != (st.shifts_signature or ""):
                try:
                    write_shifts(db, st)
                    if st.calendar_error:
                        st.calendar_error = ""
                    db.commit()
                except CalendarError as e:
                    db.rollback()
                    st = db.get(Student, st.id)
                    st.calendar_error = str(e)
                    st.shifts_signature = wanted  # retried at the next full sync, not every cycle
                    db.commit()
    return n


def day_name(d: int) -> str:
    return DAY_LONG[d]
