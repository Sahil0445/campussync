# CampusSync

> **Shift work, on autopilot.** Scheduling, automated time reporting and pay for campus jobs and any team that can't justify Workday — a security firm, a café, a clinic. Agents read calendars, draft the week, fill gaps, resolve swaps, report hours when each shift ends and remind everyone on their phone, while no employer ever sees another's schedule. **Humans just approve.**

**Rules are code. Judgment is AI. Anything that changes a real person's week needs a human's approval.**

**100% Jac.** The server (graph model, rules engine, agents, time reporting, pay, alerts, Web Push, Google Calendar, the autopilot scheduled task) and every screen of the web app (Jac client components compiled to React) are written in [Jac](https://www.jac-lang.org). Built for JacHacks 2026, deployed on [JacHammer](https://jachammer.ai).

---

## Quick start

```bash
# Jac 0.37.23 (pinned in jac.toml)
jac install        # Python + npm dependencies
jac run            # http://localhost:8000  (dev mode, hot reload)
jac run --no-dev   # production build of the web app
```

- **Deploy for friends' phones:** [docs/DEPLOY_JACHAMMER.md](docs/DEPLOY_JACHAMMER.md). Phones need HTTPS for Google sign-in and push notifications.
- **Gemini (optional):** set `GEMINI_API_KEY`. Without it the agents use built-in logic and say so in the UI; every rule still runs the same.
- **Google Calendar:** [docs/GOOGLE_CALENDAR.md](docs/GOOGLE_CALENDAR.md).
- **Demo accounts** (password `demo1234`, also one tap on the sign-in page): `dining@demo.edu` (campus employer), `shield@demo.com` (security company), `priya@demo.edu` (international student, 2 jobs), `marcus@demo.edu`, `sam@demo.edu`, `tom@demo.com` (security guard). Join codes: `DINE-2026`, `CSE-2026`, `SHLD-2026`. The demo data is created automatically on first start.
- **Rehearsals:** `/demo` resets the seed (needs the admin key when `CAMPUSSYNC_ADMIN_KEY` is set), forces an autopilot cycle, simulates calendar events.
- **Status:** `/status` shows whether Gemini and Google Calendar are configured and when the autopilot last ran.

## Who uses it

| | Employer | Employee |
|---|---|---|
| Sign up | Registers the organization (campus employer at a university, or a business) and gets a **join code** + invite link | Signs up **with the join code** and lands on that team |
| Multiple employers | — | **Campus students** can join several employers at the same university (the 20 h international cap spans all of them). **Regular employees** belong to one employer at a time |
| Roles | Creates roles (Cashier, Site guard, Night patrol…) and assigns them; shifts and staffing needs can require a role | Only scheduled into roles they hold |
| Pay | $15/hr default, editable per person or for the whole team; state tax rate for estimates | Sees hours and estimated take-home pay by week, month and year |
| Time | Timesheets: hours reported automatically, flagged lines to accept or keep, CSV export | Friday: check the auto-reported hours, approve in one tap or flag a line |
| Alerts | Approvals, flagged hours, new team members | Push: 24 h and 1 h before every shift · Friday 9 AM approve · Friday 6 PM reminder if still pending |

**Automated time reporting:** when a published shift ends, its hours are reported automatically. Employees confirm on Friday; corrections go to the employer. An international student's reported hours can never exceed 20 in a week across all jobs — a correction that would is refused in code.

**Pay estimates:** 2026 federal brackets with the standard deduction, the employer's flat state rate, and 7.65 % FICA (international students on F-1/J-1 visas are generally exempt). Labeled as an estimate everywhere.

**Phone notifications:** Web Push (VAPID + RFC 8291 encryption). Android/desktop Chrome, Edge, Firefox work directly; **iPhone needs Add to Home Screen first** (iOS 16.4+, Apple's rule). Profile → Phone alerts has a test button and previews of every alert.

## What's automated

| What used to be manual | Who does it now | Where the human is |
|---|---|---|
| Entering availability | **Availability Agent** syncs Google Calendar every few minutes and parses notes like "no Fridays before 10" | Connect once |
| Noticing a new clash | **Availability Agent** sees the event land on a shift and hands it to the **Swap Agent** | — |
| Building the week | **Scheduling Agent** drafts automatically whenever slots are open | **Approve** (1 tap) |
| Covering unfillable slots | **Recruiting Agent** finds free students across campus. Their autopilot accepts, and the slot fills itself | **Invite** (1 tap) |
| Finding swaps | **Swap Agent** tries 1:1 swaps, then 3- and 4-person loops, and re-plans on decline | **Approve** (1 tap) |
| Answering swap offers and job invites | **Employee autopilot** accepts what fits their open days and hours | Only if it doesn't fit |
| Setting up staffing needs | **Needs Agent** turns "café open 7–7, busy at lunch" into weekly blocks | Confirm |
| Checking a person or a slot | **Copilot** (Ctrl K): "Can Priya work Wed 12–3?", "Who can cover Fri evening?" | Type one sentence |
| Telling your job something changed | **Campus AI**: "I can't do Saturday, Wednesday works" | Type one sentence |

**Hard limits, enforced only in code, at every step:** 20 h/week across all employers for international students (in schedules *and* reported hours); never more than an employer's assigned hours; 8 h/day for students, 12 h/day for regular employees; 30 minutes' rest between shifts; no overlap with classes, calendar events or any other shift; only people holding a shift's role can take it.

**Minimum disclosure:** employers get only `available / schedule_conflict / hour_limit + hours_left`. Rate limits stop them mapping someone's week by trial and error.

---

## Demo script (≈3 minutes, 2–3 devices)

**Before you start:** open `/demo` and click **Reset demo data**. Autopilot drafts the week and the Recruiting Agent finds two students for Saturday. Everything waits in **Approvals**. Sign in with the one-tap demo buttons (password `demo1234`).

1. **Privacy (laptop, Campus Dining):** Ctrl K → **"Can Priya work Wednesday 12 to 3?"** → *"Can't schedule Priya… Details are private to the student."* Then **"Add 3 hours for Priya on Thursday"** → *"Hours you can still schedule: 0."* On Priya's phone: **20 / 20** across two employers.
2. **The week builds itself:** Approvals → **Review** the draft (22 of 24) → **Approve & publish** → **Invite** Mia and Ravi. Their autopilots accept and Saturday fills itself.
3. **Life happens:** in `/demo`, **Add event** on Priya's "Family visit". The Swap Agent finds a 3-person loop → **Approve**. On Marcus's phone (autopilot off) → **Decline**. Without reloading, a **4-person swap** appears → **Approve new swap** → *"Swap complete. All 4 schedules updated."*

---

## Architecture (all Jac)

```
web/  (Jac client components → React, PWA)      ──POST /function/<name>──▶   server/  (Jac, graph on Postgres)
  App.jac                routes                                              api_*.jac        endpoints (def:pub / def:protect) — the privacy boundary
  pages/*.jac            landing, sign-up, employer, employee screens        models.jac       nodes: Employer, Employee, Employment, Shift, TimeEntry, …
  components/*.jac       shell, charts, week calendar, agent panel, …        rules.jac        Conflict Agent + Compliance Checker (code, never AI)
  lib/api.jac            calls, sessions (Jac built-in accounts)            ai.jac           byLLM `by gemini(...)` typed agent calls, model fallback
  lib/push.jac           Web Push subscribe                                 scheduling.jac   Scheduling Agent (AI proposes, rules validate)
                                                                             swaps.jac        Swap Agent (search ≤4) + Commit Service (all or nothing)
                                                                             recruiting.jac   Recruiting Agent
                                                                             needs.jac        Needs Agent · copilot.jac · availability.jac
                                                                             timesheets.jac   time reporting, Friday approval, 20 h guard, analytics
                                                                             payroll.jac      take-home estimate
                                                                             alerts.jac       24 h / 1 h / Friday alerts (exactly once)
                                                                             push.jac         Web Push: VAPID + aes128gcm
                                                                             calendar.jac     Google OAuth · iCal links · demo feed · clash detection
                                                                             autopilot.jac    @schedule every 15 s: sync → draft → recruit → accept → fill → report → alert → push
                                                                             web_routes.jac   /sw.js, manifest, icons, /status, Google callback, demo room
```

Every AI call has a deterministic fallback, so a quota error on stage changes nothing except the wording.

## Development checks

```bash
jac check                      # type-check the whole program (server + web)
jac run --no-takeover tests/push_check.jac # Web Push encryption round-trip + VAPID signature
jac run --no-takeover tests/gcal_check.jac # Google Calendar sync against a fake API (idempotent writes)
jac run --no-takeover tests/ai_check.jac # typed agent calls with a mock model
```

The Jac port was verified against the original Python/React build: the same API scenarios (≈150 steps: sign-ups, schedules, swaps, time travel for alerts and timesheets) return identical results, and every screen renders pixel-identical at 390 px and 1440 px.

## Seed data notes

- Dining runs Mon–Sat, 11–15 and 15–19, with 2 people per shift (24 slots). Every shift is 4 hours, so a swap never changes anyone's total hours.
- Priya works CSE Research 12 h + Campus Dining 8 h = 20/20. She's open to swapping into Wednesday.
- Autopilot is on for everyone except **Marcus**, so he's the one who gets asked on stage.
- Ravi and Mia aren't on any team. They're the students the Recruiting Agent finds for Saturday.
- Every seed student uses the built-in demo calendar feed, so the stage needs no network. New sign-ups connect real calendars.
