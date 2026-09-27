# CampusSync — handoff summary (as of Sat Sep 26, 2026, 8 PM ET)

## What it is
A JacHacks 2026 hackathon project. CampusSync is a multi-agent **autopilot for campus student employment**. Students hold several campus jobs, and departments schedule independently without seeing each other. CampusSync knows everything centrally but shows each department only the minimum: *available or not*, and *hours you can still assign*. The goal is roughly 99% automation, with humans only approving.
The pitch line: **"Rules are code. Judgment is AI. Humans just approve."**

## Where the code lives
- On the user's PC: `E:\CampusSync`, a Windows machine linked to Claude through the desktop app.
- The team's original spec is `CampusSync_JacHacks_Project_Idea.md` (sections 0–18).
- Docs in the repo: `README.md` (demo script), `docs/JAC_PORT.md` (how to move to Jac/JacHammer), `docs/GOOGLE_CALENDAR.md` (OAuth setup), and this file.

## Stack (decisions made with the user)
- **Backend:** Python 3.10+, FastAPI, SQLAlchemy, SQLite (`backend/campussync.db`, which resets itself when `SCHEMA_VERSION` changes; currently "2").
- **Frontend:** React 18 + Vite + TypeScript, prebuilt into `frontend/dist` and served by FastAPI.
- **API:** shaped like `jac serve` (`POST /user/login`, `POST /walker/<name>`, returns `{"reports":[...]}`) so it can be ported to **JacHammer** later.
- **AI:** Gemini REST (`backend/agents/llm.py`). Default model `gemini-3.5-flash`, with fallbacks `gemini-3.5-flash-lite, gemini-3.8-flash, gemini-3.1-flash-lite`. It retries on 503/429, fails over to the next model, then waits ~45 s before trying again. Every AI call has a deterministic fallback, so the app works with no key.
- **Running it:** `run.bat` (Windows) or `run.sh`, then http://localhost:8000. `dev.bat` gives hot reload. The rehearsal control room is `/demo` (reset the demo, run an autopilot cycle, simulate a calendar event). Status is at `/healthz` (shows AI mode, model, last AI error, Google OAuth on/off).
- **`.env`:** the user's Gemini key is in `backend\.env`. The key starts with `AQ.`, and Google returned 503 (overloaded), which means the key was accepted. `backend\.env.txt` also holds a copy of the key and should be deleted. Leftover `campussync*.tgz` files and `frontend\frontend-theme.tgz` are also safe to delete; Claude can't delete files in that folder.

## Agents
Coordinator · Availability Agent (AI notes + calendar sync) · **Conflict Agent (code)** · **Compliance Checker (code)** · Scheduling Agent (AI proposes, rules validate) · Swap Agent (deterministic search of 1:1 swaps and 3–4 person loops, AI rationale, re-plans on decline, falls back to a hand-off) · Recruiting Agent (finds campus students for gaps) · Needs Agent (turns a text description into staffing blocks) · Explainer · Commit Service (all moves or none) · Copilot (natural language → intents, for managers and students).

**Hard rules (code only):** 20 h/week cap across all jobs for international students, a department's assigned hours, 8 h/day, 30 min rest between shifts, and no overlaps with classes, calendar events or other shifts. Privacy responses are exactly `{available:false, reason:"schedule_conflict", suggestions}` and `{available:false, reason:"hour_limit", hours_left}`. Checks are rate-limited to 20 per student per hour per department.

**Autopilot loop** (`services/autopilot.py`, every 15 s): expire old offers → sync calendars and detect clashes (which auto-raise swap requests) → draft the upcoming week → recruit for gaps → auto-accept invites that fit a student's wanted hours → fill open shifts.

**Calendar** (`services/calendar.py`): Google OAuth (needs `GOOGLE_CLIENT_ID/SECRET`; not set up yet), a secret iCal URL, .ics upload, or the demo feed that all seed students use.

## Seed / demo (week of Mon Sep 28, 2026)
- **Campus Dining:** Mon–Sat 11–15 and 15–19, 2 people each, 24 slots. **CSE Research** exists only to hide Priya's other job.
- **Priya:** CSE 12 h + Dining 8 h = 20/20, international, open to swapping into Wednesday. **Marcus** is the only student with autopilot off. **Ravi** and **Mia** aren't on any team; they're the students the Recruiting Agent finds.
- **Logins:** `dining@demo.edu`, `priya@`, `marcus@`, `sam@` … all with password `demo1234`, plus one-tap demo buttons on `/signin`.
- **Demo flow:**
  1. Copilot: "Can Priya work Wednesday 12 to 3?" → private conflict. "Add 3 hours for Priya on Thursday" → 0 hours left.
  2. Approvals: publish the autopilot draft (22/24), then Invite Mia and Ravi. Their autopilots accept and coverage reaches 24/24.
  3. `/demo`: "Priya adds Family visit Sat" → 3-person loop → manager approves → Marcus declines on his phone → a 4-person loop appears live → approve → all 4 schedules commit.
- **Tests:** 16 backend tests pass (`cd backend && python -m pytest -q`), including the three acts, autopilot end to end, copilot, Gemini failover, and checks that "CSE" never leaks to Dining.

## Current UI (after the user's last feedback)
- **Theme:** dark futuristic, violet→blue→cyan gradient (`#a18bff → #6c8cff → #3dd8f5`), Geist / Geist Mono fonts. The user tried a flat soft-blue theme and asked to **revert to the gradient one**, which is what's current. **All cards (and most controls) have 4px corners.**
- **Logo:** a gradient calendar tile with a sync loop inside (in `components/ui.tsx` and `public/favicon.svg`).
- **Landing** at `/`, and sign-in at `/signin`.
- **Department:** a sidebar with Dashboard · Approvals · Schedule · Team · Autopilot settings, plus a copilot command bar at the top (Ctrl+K). There's no "agents online" tag, and the Agents page was removed.
  - **Dashboard:** 4 large stat cards (Coverage ring, Waiting for you, Done by agents %, Hours scheduled), then *Needs your approval* next to an equal-height *Agent network* diagram, then a **Schedule** widget laid out like Google Calendar (`components/WeekCalendar.tsx`).
  - **Schedule page:** the same calendar with Today and previous/next buttons. There's also draft review with an agent replay, the swap approval page, Team, and Settings (autopilot policies + Needs Agent).
- **Student** (mobile-first; on desktop it shows inside a phone frame): bottom tabs **Dashboard · Campus AI · Requests · Profile**.
  - **Dashboard:** "20 / 20 hrs" card with a split bar, Your jobs, and a *This week* list (bold mono time, department below, Confirmed chip), with **Request a change** and **Update availability** buttons.
  - **Campus AI:** chat, autopilot switch, calendar sync.
  - **Requests:** needs your answer (swap and job offers), your requests, history.
  - **Profile:** Hours and preferences (big number, slider, chips), Autopilot + open days, a Calendar & availability link, sign out.
  - Other routes: `/s/request/new` (3-step request), `/s/request?id=`, `/s/offer/:id`, `/s/availability`.

## Open items / ideas not built yet
- **Super admin profile:** the user wants it, and the Agents screen with the full agent feed should move there.
- **Google OAuth:** needs the user to create credentials (steps in `docs/GOOGLE_CALENDAR.md`).
- **Gemini:** the model was busy (503) at last check. Confirm AI responses via `/healthz` → `last_ai_error`.
- **Later:** port to Jac/JacHammer (see `docs/JAC_PORT.md`), real-time Google push instead of polling, inter-department hour negotiation.

## How Claude delivered changes
Claude builds in its cloud workspace (`/home/claude/campussync`), runs pytest and Playwright screenshots at 375 px and 1440 px, then copies a tarball to `E:\CampusSync` and extracts it with `--overwrite`, excluding `backend/.env` and the database. Deleting files in that folder isn't allowed.
