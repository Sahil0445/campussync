# CampusSync

> **Shift work, on autopilot.** Scheduling, automated time reporting and pay for campus jobs and any team that can't justify Workday — a security firm, a café, a clinic. Agents read calendars, draft the week, fill gaps, resolve swaps, report hours when each shift ends and remind everyone on their phone, while no employer ever sees another's schedule. **Humans just approve.**

**Rules are code. Judgment is AI. Anything that changes a real person's week needs a human's approval.**

---

## Quick start

- **Windows:** double-click `run.bat` · **macOS / Linux:** `./run.sh` → http://localhost:8000 (Python 3.10+; the frontend is prebuilt).
- **Live for friends' phones:** deploy to Render — [docs/DEPLOY.md](docs/DEPLOY.md). Phones need HTTPS for Google sign-in and push notifications.
- **Gemini (optional):** `GEMINI_API_KEY=` in `backend/.env`. Without it the agents use built-in logic.
- **Google Calendar:** [docs/GOOGLE_CALENDAR.md](docs/GOOGLE_CALENDAR.md).
- **Demo accounts** (password `demo1234`, also on the sign-in page): `dining@demo.edu` (campus employer), `shield@demo.com` (security company), `priya@demo.edu` (international student, 2 jobs), `marcus@demo.edu`, `sam@demo.edu`, `tom@demo.com` (security guard). Join codes: `DINE-2026`, `CSE-2026`, `SHLD-2026`.
- **Rehearsals:** `/demo` resets the seed (needs the admin key on the live server), forces an autopilot cycle, simulates calendar events.

> The first start after upgrading resets the database automatically (schema v3).

## Who uses it

| | Employer | Employee |
|---|---|---|
| Sign up | Registers the organization (campus employer at a university, or a business) and gets a **join code** + invite link | Signs up **with the join code** and lands on that team |
| Multiple employers | — | **Campus students** can join several employers at the same university (the 20 h international cap spans all of them). **Regular employees** belong to one employer at a time |
| Roles | Creates roles (Cashier, Site guard, Night patrol…) and assigns them; shifts and staffing needs can require a role | Only scheduled into roles they hold |
| Pay | $15/hr default, editable per person or for the whole team; state tax rate for estimates | Sees hours and estimated take-home pay by week, month and year |
| Time | Timesheets: hours reported automatically, flagged lines to accept or keep, CSV export | Friday: check the auto-reported hours, approve in one tap or flag a line |
| Alerts | Approvals, flagged hours, new team members | Push: 24 h and 1 h before every shift · Friday 9 AM approve · Friday 6 PM reminder if still pending |

**Automated time reporting:** when a published shift ends, its hours are reported automatically. Employees confirm on Friday; corrections go to the employer. An international student's reported hours can never exceed 20 in a week across all jobs — a correction that would is refused in code ("over-clocking" protection).

**Pay estimates:** 2026 federal brackets with the standard deduction, the employer's flat state rate, and 7.65 % FICA (international students on F-1/J-1 visas are generally exempt). Labeled as an estimate everywhere.

**Phone notifications:** Web Push (VAPID + RFC 8291 encryption, implemented on `cryptography`). Android/desktop Chrome, Edge, Firefox work directly; **iPhone needs Add to Home Screen first** (iOS 16.4+, Apple's rule). Profile → Phone alerts has a test button and previews of every alert.

## What's automated

| What used to be manual | Who does it now | Where the human is |
|---|---|---|
| Entering availability | **Availability Agent** syncs Google Calendar every few minutes and parses notes like "no Fridays before 10" | Connect once |
| Noticing a new clash | **Availability Agent** sees the event land on a shift and hands it to the **Swap Agent** | — |
| Building the week | **Scheduling Agent** drafts automatically whenever slots are open | **Approve** (1 tap) |
| Covering unfillable slots | **Recruiting Agent** finds free students across campus. Their autopilot accepts, and the slot fills itself | **Invite** (1 tap) |
| Finding swaps | **Swap Agent** tries 1:1 swaps, then 3- and 4-person loops, and re-plans on decline. Falls back to finding someone to take the shift | **Approve** (1 tap) |
| Answering swap offers | **Student autopilot** accepts moves into days the student said they're open to | Only if the move is outside their preferences |
| Answering job invites | **Student autopilot** accepts if it fits the hours they want | Only if it doesn't |
| Setting up staffing needs | **Needs Agent** turns "café open 7–7, busy at lunch" into weekly blocks | Confirm |
| Checking a person or a slot | **Copilot** (Ctrl K): "Can Priya work Wed 12–3?", "Who can cover Fri evening?", "Need 2 more Saturday 3–7" | Type one sentence |
| Telling your job something changed | **Student copilot**: "I can't do Saturday, Wednesday works" | Type one sentence |

the Dashboard shows **Done by agents** as a live percentage. In the full demo, humans make about 6 clicks and the agents do everything else.

**Hard limits, enforced only in code, at every step:** 20 h/week across all employers for international students (in schedules *and* reported hours); never more than an employer's assigned hours; 8 h/day for students, 12 h/day for regular employees; 30 minutes' rest between shifts; no overlap with classes, calendar events or any other shift; only people holding a shift's role can take it.

**Minimum disclosure:** departments get only `available / schedule_conflict / hour_limit + hours_left`. Rate limits stop them mapping a student's week by trial and error. Calendar event titles appear in the student's own feed, never in a department's feed.

---

## Demo script (≈3 minutes, 2–3 devices)

**Before you start:** open `/demo` and click **Reset demo data**. Autopilot immediately drafts the week and the Recruiting Agent finds two students for Saturday. Everything is waiting in **Approvals**.

Sign in with the **one-tap demo buttons** on the sign-in page. Everyone's password is `demo1234`.

**Act 1 — Privacy (laptop, Campus Dining)**
1. In the command bar (Ctrl K), type **"Can Priya work Wednesday 12 to 3?"** You'll see *"Can't schedule Priya… 🔒 Details are private to the student."*
2. Type **"Add 3 hours for Priya on Thursday"**. You'll see *"Hours you can still schedule: 0."*
3. On Priya's phone: **20 / 20**, across CSE Research and Campus Dining. *"Neither department could have caught that. The coordination layer did."*

**Act 2 — The week builds itself**

4. **Approvals → Review** the draft. The agent network lights up while the run replays and the grid fills in: **22 of 24**, with Saturday 15–19 flagged.
5. **Approve & publish.** Then click **Invite** on Mia and on Ravi. Their autopilots accept, the Saturday gap fills itself, and the Dashboard shows **100% · 24 of 24**.

**Act 3 — Life happens (nobody presses "request a change")**

6. In the `/demo` tab, click **Add event** on *"Priya adds 'Family visit' Saturday 9–17"*. Within seconds, the live feed on the Dashboard shows *"Priya can no longer make Sat 11:00–15:00 (calendar change). Swap Agent is on it."* Priya's phone shows *"Campus AI is handling a change."*
7. **Approvals → Review** shows the 3-person loop (Priya → Sam → Marcus). Click **Approve**. Priya's and Sam's autopilots accept instantly.
8. On Marcus's phone (his autopilot is off): **Decline** → *"Thursday doesn't work for me anymore."*
9. Watch the laptop without reloading. The Swap Agent re-plans live and a **New option · 4-person swap** appears. Click **Approve new swap** to get **"Swap complete. All 4 schedules updated."** Every autopilot agreed. Priya has Wednesday and is still at 20.

**Close:** point at the **Done by agents** percentage on the Dashboard.

---

## Architecture

```
frontend (React + Vite, PWA)  ──POST /walker/<name>──▶  backend (FastAPI + Postgres/SQLite)
                                                   │
  services/autopilot.py   background loop: sync → draft → recruit → auto-accept → fill → report hours → alerts → push
  services/timesheets.py  automated time reporting, Friday approval, 20 h guard, analytics
  services/payroll.py     take-home estimate (federal brackets, state rate, FICA)
  services/alerts.py      24 h / 1 h shift reminders, Friday 9 AM / 6 PM timesheet alerts (sent exactly once)
  services/push.py        Web Push: VAPID + aes128gcm encryption
  walkers/membership.py   employers, employees, join codes, one-employer rule
  walkers/org.py          organization settings, roles, team pay, timesheets
  services/calendar.py    Google OAuth (read busy + write "CampusSync shifts") · iCal links · demo feed · clash detection
  services/swaps.py       swap workflow + Commit Service (all moves or none)
  agents/rules.py         Conflict Agent + Compliance Checker (code, never AI)
  agents/scheduling.py    Scheduling Agent (AI proposes, rules validate)
  agents/swap.py          Swap Agent (deterministic search ≤4, AI explains)
  agents/recruiting.py    Recruiting Agent
  agents/needs.py         Needs Agent
  agents/copilot.py       natural-language → intent (Gemini, regex fallback)
  agents/availability.py  .ics parsing + note parsing
  walkers/                privacy boundary — decides what leaves
  events.py               live agent feed
```

All AI calls go through `agents/llm.py`. Every caller has a deterministic fallback, so a quota error on stage changes nothing except the wording.

## Development

```bash
cd backend && python -m pytest -q        # 37 tests: demo acts, employers & join codes, roles, time reporting, alerts, push, Google (mocked), privacy
TEST_DATABASE_URL=postgresql+psycopg://user@host/db python -m pytest -q   # same suite on Postgres
cd frontend && npm install && npm run dev   # http://localhost:5173 (proxies the API)
```

API docs: http://localhost:8000/api/docs. The API matches `jac serve` (`POST /walker/<name>` → `{"reports": [...]}`), so the frontend ports to JacHammer unchanged. See [docs/JAC_PORT.md](docs/JAC_PORT.md).

## Seed data notes

These are deliberate choices so the demo is guaranteed, not lucky:
- Dining runs Mon–Sat, 11–15 and 15–19, with 2 people per shift (24 slots). Every shift is 4 hours, so a swap never changes anyone's total hours.
- Priya works CSE Research 12 h + Campus Dining 8 h = 20/20. She's open to swapping into Wednesday.
- Autopilot is on for everyone except **Marcus**, so he's the one who gets asked on stage.
- Ravi and Mia aren't on any team. They're the students the Recruiting Agent finds for Saturday.
- Every seed student uses the built-in demo calendar feed, so the stage needs no network. New sign-ups connect real calendars.

## Roadmap

Google Calendar watch channels instead of 5-minute polling · password reset by email · email/SMS alerts · payroll export formats (ADP, Gusto) · Google app verification (removes the 7-day reconnect in Testing mode).
