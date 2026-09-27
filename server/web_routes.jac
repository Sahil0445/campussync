"""Plain web routes: the PWA files at the site root, Google's OAuth callback, app status and the demo
control room.

These are raw (non-envelope) function endpoints so the browser gets exactly what it expects --
a service worker at /sw.js (scope "/"), a manifest, icons, and an HTML redirect after Google sign-in.
"""

import json;
import html;
import logging;
import from pathlib { Path }
import from http { HTTPMethod }
import from urllib.parse { quote }
import from server.clock { utcnow, now_s, travel }
import from datetime { timedelta }
import from server.config { DEMO_MODE, ADMIN_KEY, GEMINI_MODEL, AUTOPILOT_SECONDS }
import from server.models { Employee, hub, employee_of, meta_get }
import from server.api_common { UNSET, opt, ApiError, guarded }
import server.ai as ai;
import server.calendar as calendar;
import server.autopilot as autopilot;
import server.seed as seed;

glob log = logging.getLogger("campussync.web"),
     PUBLIC: Path = Path(__file__).resolve().parent.parent / "public",
     ICONS: list[str] = ["icon-192.png", "icon-512.png", "maskable-512.png", "apple-touch-icon.png", "badge-96.png"];

def _read(name: str) -> str {
    return (PUBLIC / name).read_text(encoding="utf-8");
}

# ------------------------------------------------------------------ PWA files at the root
@restspec(method=HTTPMethod.GET, path="/sw.js", produces="text/javascript", envelope=False)
def:pub service_worker() -> str {
    return _read("sw.js");
}

@restspec(method=HTTPMethod.GET, path="/manifest.webmanifest", produces="application/manifest+json", envelope=False)
def:pub web_manifest() -> str {
    return _read("manifest.webmanifest");
}

@restspec(method=HTTPMethod.GET, path="/favicon.svg", produces="image/svg+xml", envelope=False)
def:pub favicon() -> str {
    return _read("favicon.svg");
}

@restspec(method=HTTPMethod.GET, path="/sample-calendar.ics", produces="text/calendar", envelope=False)
def:pub sample_calendar() -> str {
    return _read("sample-calendar.ics");
}

@restspec(method=HTTPMethod.GET, path="/icons/{name}", produces="image/png", envelope=False)
def:pub app_icon(name: str) -> bytes {
    if name not in ICONS {
        return (PUBLIC / "icons" / "icon-192.png").read_bytes();
    }
    return (PUBLIC / "icons" / name).read_bytes();
}

# ------------------------------------------------------------------ status
@guarded
def:pub app_status() -> dict[str, any] {
    return {
        "ok": True,
        "ai": "gemini" if ai.enabled() else "fallback",
        "model": (ai.last_model or GEMINI_MODEL) if ai.enabled() else None,
        "models_tried": ai.models(),
        "google_calendar": calendar.google_enabled(),
        "google_redirect_uri": calendar.redirect_uri() if calendar.google_enabled() else None,
        "autopilot_seconds": AUTOPILOT_SECONDS,
        "last_autopilot": autopilot.last_run_iso() or None,
        "last_autopilot_stats": autopilot.last_stats,
        "database": "jac graph (postgres)",
        "seeded": hub().seeded,
        "last_ai_error": ai.last_error or None,
        "demo": DEMO_MODE,
        "server_time": utcnow().isoformat() + "Z"
    };
}

"""The same status as a plain GET page, so it can be opened in a browser: <your-url>/status"""
@restspec(method=HTTPMethod.GET, path="/status", produces="application/json", envelope=False)
def:pub status_page() -> str {
    return json.dumps(app_status(), indent=2);
}

# ------------------------------------------------------------------ Google Calendar OAuth
def _with(path: str, query: str) -> str {
    return f"{path}{'&' if '?' in path else '?'}{query}";
}

def _safe_next(path: str) -> str {
    return path if path.startswith("/") and not path.startswith("//") else "/s";
}

def _redirect_page(url: str) -> str {
    u = html.escape(url, quote=True);
    target = json.dumps(url);
    return (
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">"
        + f"<meta http-equiv=\"refresh\" content=\"0;url={u}\"><title>CampusSync</title></head>"
        + "<body style=\"background:#05060a;color:#e8eaf2;font-family:system-ui,sans-serif\">"
        + f"<p style=\"padding:24px\">Returning to CampusSync… <a style=\"color:#a18bff\" href=\"{u}\">continue</a></p>"
        + f"<script>location.replace({target});</script></body></html>"
    );
}

@restspec(method=HTTPMethod.GET, path="/auth/google/callback", produces="text/html", envelope=False)
def:pub google_callback(code: str = "", state: str = "", error: str = "") -> str {
    data = calendar.read_state(state) or {};
    nxt = _safe_next(str(data.get("next") or "/s"));
    if error or not data or not code {
        return _redirect_page(_with(nxt, "calendar=cancelled"));
    }
    st = employee_of(str(data.get("sid") or ""));
    if st is None {
        return _redirect_page("/signin");
    }
    tokens: dict[str, any] = {};
    try {
        tokens = calendar.exchange_code(code, str(data.get("origin") or ""));
    } except calendar.CalendarError as ce {
        return _redirect_page(_with(nxt, f"calendar=error&message={quote(str(ce))}"));
    }
    if st.google_refresh_token and st.google_refresh_token != tokens["refresh_token"] {
        calendar.revoke(st.google_refresh_token);
    }
    st.google_refresh_token = tokens["refresh_token"];
    st.google_email = str(tokens["email"])[:200];
    st.calendar_source = "google";
    st.calendar_url = "";
    st.calendar_error = "";
    st.shifts_signature = "";
    res = calendar.sync_student(st, announce=True);
    if not res.get("ok") {
        return _redirect_page(_with(nxt, f"calendar=error&message={quote(str(res.get('error') or 'Sync failed'))}"));
    }
    return _redirect_page(_with(nxt, "calendar=connected"));
}

# ------------------------------------------------------------------ demo control room
def _admin_ok(key: str) -> bool {
    return not ADMIN_KEY or key == ADMIN_KEY;
}

@guarded
def:pub demo_reset(key: str = "") -> dict[str, any] {
    if not DEMO_MODE {
        raise ApiError("Demo mode is off.");
    }
    if not _admin_ok(str(key or "")) {
        raise ApiError("Resetting wipes everyone's data. Enter the admin key to do it.");
    }
    seed.wipe();
    seed.seed();
    autopilot.tick();
    return {"ok": True};
}

@guarded
def:pub demo_tick() -> dict[str, any] {
    if not DEMO_MODE {
        raise ApiError("Demo mode is off.");
    }
    seed.ensure_seeded();
    return {"ok": True, "stats": autopilot.tick()};
}

"""Simulates an employee adding an event in Google Calendar (the demo calendar feed)."""
@guarded
def:pub demo_calendar_event(
    email: str = "", day: int = 0, start: int = 0, end: int = 0, title: str = "Busy", week: str = ""
) -> dict[str, any] {
    if not DEMO_MODE {
        raise ApiError("Demo mode is off.");
    }
    e = str(email or "").strip().lower();
    rows = [hub() --> [?:Employee, email == e]];
    if not rows {
        raise ApiError("Student not found.");
    }
    st = rows[0];
    if st.calendar_source != "demo" {
        raise ApiError("This student's calendar is a real one — add the event there.");
    }
    wk = week or autopilot.planning_week();
    seed.add_demo_event(st, int(day), int(start), int(end), str(title or "Busy")[:60], wk);
    res = calendar.sync_student(st);
    return {"ok": True, "disruptions": res.get("disruptions", [])};
}

"""Tests and rehearsals only: move this server's clock (admin key required)."""
@guarded
def:pub demo_travel(key: str = "", hours: float = 0.0, reset: bool = False) -> dict[str, any] {
    import from server.clock { reset_clock, offset }
    if not DEMO_MODE or not ADMIN_KEY or key != ADMIN_KEY {
        raise ApiError("Not allowed.");
    }
    if reset {
        reset_clock();
    } else {
        travel(timedelta(hours=float(hours)));
    }
    return {"ok": True, "now": utcnow().isoformat() + "Z", "offset_hours": offset().total_seconds() / 3600};
}
