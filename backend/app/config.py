"""Runtime configuration. Values come from environment variables or backend/.env."""
from __future__ import annotations

import os
from datetime import date
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent


def _load_dotenv() -> None:
    env_file = BACKEND_DIR / ".env"
    if not env_file.exists():
        return
    for raw in env_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv()

def _db_url() -> str:
    url = os.getenv("DATABASE_URL") or os.getenv("CAMPUSSYNC_DB") or f"sqlite:///{(BACKEND_DIR / 'campussync.db').as_posix()}"
    # Render/Heroku hand out postgres:// URLs; SQLAlchemy wants an explicit driver.
    if url.startswith("postgres://"):
        url = "postgresql+psycopg://" + url[len("postgres://"):]
    elif url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]
    return url


DB_URL = _db_url()
SECRET = os.getenv("CAMPUSSYNC_SECRET", "campussync-dev-secret-change-me")
TOKEN_TTL_SECONDS = int(os.getenv("CAMPUSSYNC_TOKEN_TTL", str(60 * 60 * 24 * 7)))

# AI: Gemini via the Generative Language REST API. Empty key -> deterministic fallback.
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "").strip()
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3.5-flash")
# Tried in order when the main model is busy (503) or unavailable to this key (404).
GEMINI_FALLBACK_MODELS = os.getenv("GEMINI_FALLBACK_MODELS", "gemini-3.5-flash-lite,gemini-3.8-flash,gemini-3.1-flash-lite")
AI_TIMEOUT_SECONDS = float(os.getenv("AI_TIMEOUT_SECONDS", "12"))

# Demo week (Mon). The whole seed is built around it.
DEFAULT_WEEK = date.fromisoformat(os.getenv("CAMPUSSYNC_WEEK", "2026-09-28"))
DEMO_MODE = os.getenv("CAMPUSSYNC_DEMO", "1") == "1"
# When set (production), destructive demo actions (reset) need this key.
ADMIN_KEY = os.getenv("CAMPUSSYNC_ADMIN_KEY", "").strip()

# Hard rules. Enforced in code only, never by a model.
INTERNATIONAL_WEEKLY_CAP = 20
MAX_DAILY_HOURS = 8  # campus student employees
MAX_DAILY_HOURS_WORKER = 12  # regular employees (e.g. 12-hour security shifts)
WORKER_WEEKLY_LIMIT = 60
MIN_REST_MINUTES = 30

# Pay. Every employee starts at the employer's default rate; employers can change it per person.
DEFAULT_PAY_RATE = float(os.getenv("CAMPUSSYNC_DEFAULT_PAY", "15"))

# Alerts (employee's local time). Shift reminders go out 24 h and 1 h before a shift.
TIMESHEET_DAY = 4  # Friday
TIMESHEET_MORNING = int(os.getenv("CAMPUSSYNC_TIMESHEET_AM", str(9 * 60)))  # 09:00
TIMESHEET_EVENING = int(os.getenv("CAMPUSSYNC_TIMESHEET_PM", str(18 * 60)))  # 18:00

# Web Push (VAPID). If unset, keys are generated once and stored in the database.
VAPID_PUBLIC_KEY = os.getenv("VAPID_PUBLIC_KEY", "").strip()
VAPID_PRIVATE_KEY = os.getenv("VAPID_PRIVATE_KEY", "").strip()
VAPID_SUBJECT = os.getenv("VAPID_SUBJECT", "mailto:alerts@campussync.app").strip()

# Minimum-disclosure guard: availability probes per department per student per hour.
PROBE_LIMIT_PER_HOUR = int(os.getenv("CAMPUSSYNC_PROBE_LIMIT", "20"))
OFFER_TTL_HOURS = 24

# Autopilot loop (seconds between cycles). 0 disables the background loop (tests call tick() directly).
AUTOPILOT_SECONDS = float(os.getenv("CAMPUSSYNC_AUTOPILOT_SECONDS", "15"))
CALENDAR_SYNC_MINUTES = float(os.getenv("CAMPUSSYNC_CALENDAR_SYNC_MINUTES", "5"))

# Google Calendar OAuth (optional). Without these, students connect with their calendar's secret iCal link.
GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID", "").strip()
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET", "").strip()
PUBLIC_BASE_URL = (os.getenv("CAMPUSSYNC_PUBLIC_URL") or os.getenv("RENDER_EXTERNAL_URL") or "http://localhost:8000").rstrip("/")
TIMEZONE = os.getenv("CAMPUSSYNC_TZ", "America/New_York")

# Keep-alive (free hosting that sleeps when idle). Defaults to the Render URL when running on Render.
KEEPALIVE_URL = (os.getenv("CAMPUSSYNC_KEEPALIVE_URL") or os.getenv("RENDER_EXTERNAL_URL") or "").strip()
KEEPALIVE_MINUTES = float(os.getenv("CAMPUSSYNC_KEEPALIVE_MINUTES", "10"))

SCHEMA_VERSION = "3"

FRONTEND_DIST = Path(os.getenv("CAMPUSSYNC_FRONTEND", str(BACKEND_DIR.parent / "frontend" / "dist")))
