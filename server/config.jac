"""Runtime configuration. Values come from environment variables (JacHammer project variables)."""

import os;
import from datetime { date }

def _env(key: str, dflt: str = "") -> str {
    return str(os.getenv(key, dflt) or dflt).strip().strip('"').strip("'").strip();
}

def _envf(key: str, dflt: float) -> float {
    try {
        return float(_env(key, str(dflt)));
    } except ValueError {
        return dflt;
    }
}

def _envi(key: str, dflt: int) -> int {
    try {
        return int(_env(key, str(dflt)));
    } except ValueError {
        return dflt;
    }
}

# AI: Gemini through byLLM. Empty key -> deterministic fallback for every agent.
glob GEMINI_API_KEY: str = _env("CAMPUSSYNC_GEMINI_API_KEY") or _env("GEMINI_API_KEY") or _env("GOOGLE_API_KEY"),
     GEMINI_MODEL: str = _env("GEMINI_MODEL", "gemini-3.5-flash"),
     GEMINI_FALLBACK_MODELS: str = _env(
         "GEMINI_FALLBACK_MODELS",
         "gemini-3.5-flash-lite,gemini-3.8-flash,gemini-3.1-flash-lite"
     ),
     AI_TIMEOUT_SECONDS: float = _envf("AI_TIMEOUT_SECONDS", 12.0);

# Demo week (Mon). The whole seed is built around it.
glob DEFAULT_WEEK: date = date.fromisoformat(_env("CAMPUSSYNC_WEEK", "2026-09-28")),
     DEMO_MODE: bool = _env("CAMPUSSYNC_DEMO", "1") == "1",
     ADMIN_KEY: str = _env("CAMPUSSYNC_ADMIN_KEY");

# Hard rules. Enforced in code only, never by a model.
glob INTERNATIONAL_WEEKLY_CAP: int = 20,
     MAX_DAILY_HOURS: int = 8,
     MAX_DAILY_HOURS_WORKER: int = 12,
     WORKER_WEEKLY_LIMIT: int = 60,
     MIN_REST_MINUTES: int = 30;

# Pay. Every employee starts at the employer's dflt rate; employers can change it per person.
glob DEFAULT_PAY_RATE: float = _envf("CAMPUSSYNC_DEFAULT_PAY", 15.0);

# Alerts (employee's local time).
glob TIMESHEET_DAY: int = 4,
     TIMESHEET_MORNING: int = _envi("CAMPUSSYNC_TIMESHEET_AM", 9 * 60),
     TIMESHEET_EVENING: int = _envi("CAMPUSSYNC_TIMESHEET_PM", 18 * 60);

# Web Push (VAPID). If unset, keys are generated once and stored in the graph.
glob VAPID_PUBLIC_KEY: str = _env("VAPID_PUBLIC_KEY"),
     VAPID_PRIVATE_KEY: str = _env("VAPID_PRIVATE_KEY"),
     VAPID_SUBJECT: str = _env("VAPID_SUBJECT", "mailto:alerts@campussync.app");

# Minimum-disclosure guard: availability probes per employer per employee per hour.
glob PROBE_LIMIT_PER_HOUR: int = _envi("CAMPUSSYNC_PROBE_LIMIT", 20),
     OFFER_TTL_HOURS: int = 24;

# Autopilot cadence.
glob AUTOPILOT_SECONDS: float = _envf("CAMPUSSYNC_AUTOPILOT_SECONDS", 15.0),
     CALENDAR_SYNC_MINUTES: float = _envf("CAMPUSSYNC_CALENDAR_SYNC_MINUTES", 5.0);

# Google Calendar OAuth (optional).
glob GOOGLE_CLIENT_ID: str = _env("GOOGLE_CLIENT_ID"),
     GOOGLE_CLIENT_SECRET: str = _env("GOOGLE_CLIENT_SECRET"),
     PUBLIC_BASE_URL: str = (
         _env("CAMPUSSYNC_PUBLIC_URL") or _env("RENDER_EXTERNAL_URL")
     ).rstrip("/"),
     SECRET: str = _env("CAMPUSSYNC_SECRET") or _env("JAC_SERVE_AUTH_SECRET") or "campussync-dev-secret-change-me",
     TIMEZONE: str = _env("CAMPUSSYNC_TZ", "America/New_York");

# Keep-alive (hosts that sleep when idle).
glob KEEPALIVE_URL: str = _env("CAMPUSSYNC_KEEPALIVE_URL"),
     KEEPALIVE_MINUTES: float = _envf("CAMPUSSYNC_KEEPALIVE_MINUTES", 10.0);

glob SCHEMA_VERSION: str = "jac-1";
