"""CampusSync API.

Routes mirror `jac serve` so the frontend ports to JacHammer unchanged:
  POST /user/login            -> {token, role, name}
  POST /walker/<name>         -> {"reports": [<result>]}
"""
from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from urllib.parse import quote

from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import config
from .agents.llm import llm
from .auth import read_token, verify_password
from .db import get_db
from .models import Student, User
from .seed import add_demo_event, init_db
from .services import autopilot, calendar
from .walkers import REGISTRY, Ctx, WalkerError
from .walkers.common import session_payload

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("campussync")

async def _autopilot_loop():
    while True:
        await asyncio.to_thread(autopilot.run_once)
        await asyncio.sleep(config.AUTOPILOT_SECONDS)


async def _keepalive_loop():
    """Render's free plan sleeps a service after 15 minutes without inbound traffic, which would stop shift
    reminders. Pinging our own public URL every few minutes counts as traffic and keeps alerts on time."""
    import httpx

    url = config.KEEPALIVE_URL.rstrip("/") + "/healthz"
    async with httpx.AsyncClient(timeout=20) as client:
        while True:
            await asyncio.sleep(config.KEEPALIVE_MINUTES * 60)
            try:
                await client.get(url)
            except Exception as e:  # pragma: no cover - network
                log.warning("keep-alive ping failed: %s", e)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    init_db()
    log.info("CampusSync ready · AI: %s · Google Calendar OAuth: %s · Autopilot every %ss",
             f"Gemini ({config.GEMINI_MODEL})" if llm.enabled else "built-in heuristics (no GEMINI_API_KEY)",
             "on" if calendar.google_enabled() else "off (iCal links work)", config.AUTOPILOT_SECONDS or "off")
    task = asyncio.create_task(_autopilot_loop()) if config.AUTOPILOT_SECONDS > 0 else None
    keep = asyncio.create_task(_keepalive_loop()) if config.KEEPALIVE_URL else None
    if keep:
        log.info("Keep-alive: pinging %s every %s min", config.KEEPALIVE_URL, config.KEEPALIVE_MINUTES)
    yield
    for t in (task, keep):
        if t:
            t.cancel()


app = FastAPI(title="CampusSync", version="1.0.0", docs_url="/api/docs", openapi_url="/api/openapi.json", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


def _error(message: str, status: int) -> JSONResponse:
    return JSONResponse({"error": message}, status_code=status)


@app.get("/healthz")
@app.head("/healthz")
def healthz():
    from . import clock

    return {"ok": True, "ai": "gemini" if llm.enabled else "fallback", "model": (llm.last_model or config.GEMINI_MODEL) if llm.enabled else None,
            "models_tried": llm.models() if llm.enabled else [],
            "google_calendar": calendar.google_enabled(), "google_redirect_uri": calendar.redirect_uri() if calendar.google_enabled() else None,
            "autopilot_seconds": config.AUTOPILOT_SECONDS, "last_autopilot": autopilot.last_run_iso(),
            "database": "postgres" if config.DB_URL.startswith("postgresql") else "sqlite",
            "last_ai_error": llm.last_error, "demo": config.DEMO_MODE, "server_time": clock.utcnow().isoformat() + "Z"}


# ---------------------------------------------------------------- Google Calendar OAuth
def _with(path: str, query: str) -> str:
    return f"{path}{'&' if '?' in path else '?'}{query}"


def _safe_next(path: str) -> str:
    return path if path.startswith("/") and not path.startswith("//") else "/s"


@app.get("/auth/google/start")
def google_start(token: str, next: str = "/s", db: Session = Depends(get_db)):
    uid = read_token(token)
    user = db.get(User, uid) if uid else None
    if not user or user.role != "student":
        return RedirectResponse("/signin")
    if not calendar.google_enabled():
        return RedirectResponse(_with(_safe_next(next), "calendar=unavailable"))
    return RedirectResponse(calendar.google_auth_url(user.student_id, _safe_next(next)))


@app.get("/auth/google/callback")
def google_callback(code: str = "", state: str = "", error: str = "", db: Session = Depends(get_db)):
    data = calendar.read_state(state)
    nxt = _safe_next((data or {}).get("next", "/s"))
    if error or not data or not code:
        return RedirectResponse(_with(nxt, "calendar=cancelled"))
    st = db.get(Student, data["sid"])
    if not st:
        return RedirectResponse("/signin")
    try:
        tokens = calendar.exchange_code(code)
    except calendar.CalendarError as e:
        return RedirectResponse(_with(nxt, f"calendar=error&message={quote(str(e))}"))
    if st.google_refresh_token and st.google_refresh_token != tokens["refresh_token"]:
        calendar.revoke(st.google_refresh_token)
    st.google_refresh_token = tokens["refresh_token"]
    st.google_email = tokens["email"][:200]
    st.calendar_source, st.calendar_url, st.calendar_error = "google", "", ""
    st.shifts_signature = ""
    db.commit()
    res = calendar.sync_student(db, st, announce=True)
    if not res.get("ok"):
        return RedirectResponse(_with(nxt, f"calendar=error&message={quote(res.get('error') or 'Sync failed')}"))
    return RedirectResponse(_with(nxt, "calendar=connected"))


_failed: dict[str, list[float]] = {}
_FAIL_WINDOW, _FAIL_MAX = 15 * 60, 10


def _throttled(key: str) -> bool:
    import time as _t

    now = _t.time()
    hits = [t for t in _failed.get(key, []) if now - t < _FAIL_WINDOW]
    _failed[key] = hits
    return len(hits) >= _FAIL_MAX


def _note_failure(key: str) -> None:
    import time as _t

    _failed.setdefault(key, []).append(_t.time())
    if len(_failed) > 10_000:  # keep memory bounded
        _failed.clear()


@app.post("/user/login")
async def login(request: Request, db: Session = Depends(get_db)):
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    email = str(body.get("email", "")).strip().lower()[:200]
    if _throttled(email):
        return _error("Too many wrong passwords. Wait 15 minutes and try again.", 429)
    user = db.scalar(select(User).where(User.email == email))
    if not user or not verify_password(str(body.get("password", ""))[:200], user.password_hash):
        _note_failure(email)
        return _error("That email and password don't match.", 401)
    _failed.pop(email, None)
    role = body.get("role")
    if role and role != user.role:
        other = "Employer" if user.role == "department" else "Employee"
        return _error(f"This is an {other.lower()} account. Switch to “{other}” above.", 401)
    return session_payload(user)


@app.post("/walker/{name}")
async def run_walker(name: str, request: Request, db: Session = Depends(get_db)):
    entry = REGISTRY.get(name)
    if not entry:
        return _error("Unknown action.", 404)
    fn, role = entry
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    user = None
    if role != "public":
        header = request.headers.get("authorization", "")
        uid = read_token(header[7:]) if header.lower().startswith("bearer ") else None
        user = db.get(User, uid) if uid else None
        if not user:
            return _error("Please sign in again.", 401)
        if role in ("student", "department") and user.role != role:
            return _error("You don't have access to this.", 403)
    try:
        result = fn(Ctx(db=db, user=user, body=body))
    except WalkerError as e:
        db.rollback()
        return _error(e.message, e.status)
    except Exception:  # never leak internals (they could name another department)
        db.rollback()
        log.exception("walker %s failed", name)
        return _error("Something went wrong. Your data is safe.", 500)
    return {"reports": [result]}


def _admin_ok(request: Request) -> bool:
    key = config.ADMIN_KEY
    return not key or request.headers.get("x-admin-key") == key or request.query_params.get("key") == key


@app.post("/demo/reset")
def demo_reset(request: Request):
    if not config.DEMO_MODE:
        return _error("Demo mode is off.", 403)
    if not _admin_ok(request):
        return _error("Resetting wipes everyone's data. Enter the admin key to do it.", 403)
    from .db import engine

    engine.dispose()
    init_db(reset=True)
    autopilot.run_once()
    return {"ok": True}


@app.post("/demo/tick")
def demo_tick():
    if not config.DEMO_MODE:
        return _error("Demo mode is off.", 403)
    return {"ok": True, "stats": autopilot.run_once()}


@app.post("/demo/calendar-event")
async def demo_calendar_event(request: Request, db: Session = Depends(get_db)):
    """Simulates a student adding an event in Google Calendar (the demo calendar feed)."""
    if not config.DEMO_MODE:
        return _error("Demo mode is off.", 403)
    body = await request.json()
    st = db.scalar(select(Student).where(Student.email == str(body.get("email", "")).lower()))
    if not st:
        return _error("Student not found.", 404)
    if st.calendar_source != "demo":
        return _error("This student's calendar is a real one — add the event there.", 400)
    week = body.get("week") or autopilot.planning_week()
    add_demo_event(db, st, int(body["day"]), int(body["start"]), int(body["end"]), str(body.get("title") or "Busy")[:60], week)
    db.commit()
    res = calendar.sync_student(db, st)  # a push notification from the calendar would do exactly this
    return {"ok": True, "disruptions": res.get("disruptions", [])}


# ---------------------------------------------------------------- frontend (built SPA)
if config.FRONTEND_DIST.exists():
    assets = config.FRONTEND_DIST / "assets"
    if assets.exists():
        app.mount("/assets", StaticFiles(directory=assets), name="assets")

    _NO_CACHE = {"Cache-Control": "no-cache"}
    _TYPES = {".webmanifest": "application/manifest+json", ".js": "text/javascript", ".svg": "image/svg+xml"}

    @app.get("/{path:path}")
    def spa(path: str):
        if path.startswith(("walker/", "user/", "api/", "auth/", "demo/")):
            return _error("Not found.", 404)
        target = (config.FRONTEND_DIST / path).resolve()
        if path and target.is_file() and config.FRONTEND_DIST.resolve() in target.parents:
            headers = _NO_CACHE if target.name in ("sw.js", "manifest.webmanifest") else {"Cache-Control": "public, max-age=3600"}
            return FileResponse(target, media_type=_TYPES.get(target.suffix), headers=headers)
        return FileResponse(config.FRONTEND_DIST / "index.html", headers=_NO_CACHE)
