# Deploying CampusSync (Render, free)

Phones need HTTPS for Google sign-in and push notifications, so friends test against a hosted copy.

## 1. Push the code to GitHub
The repo root holds `render.yaml`. `frontend/dist` is committed, so Render doesn't need Node.

## 2. Create the Render Blueprint
1. render.com → sign in with GitHub.
2. **New → Blueprint** → pick the `campussync` repo → **Apply**.
3. It creates **campussync** (web, free) and **campussync-db** (Postgres, free). When asked for env values:
   - `GEMINI_API_KEY` — your key (optional).
   - `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` — leave blank for now; fill in after step 3.
4. First deploy takes ~3 minutes. Your URL is shown at the top, e.g. `https://campussync.onrender.com`.
5. Open `https://…/healthz` → `"ok": true, "database": "postgres"`.

## 3. Google Calendar
Follow [GOOGLE_CALENDAR.md](GOOGLE_CALENDAR.md) with that URL, then paste the client ID/secret into Render → Environment → Save.

## 4. Admin key
Render → campussync → Environment → `CAMPUSSYNC_ADMIN_KEY` (generated). The `/demo` page asks for it before resetting — resetting wipes every account on the server.

## Free-plan notes
- **Sleeping:** free web services sleep after 15 minutes without traffic, which would delay alerts. The app pings its own URL every 10 minutes (`RENDER_EXTERNAL_URL`), so it stays awake. Optional backup: a free monitor at cron-job.org or UptimeRobot hitting `/healthz` every 5–10 minutes.
- **Database:** Render's free Postgres expires 30 days after creation (upgrade to keep data).
- **Deploys:** every push to `main` redeploys. Data survives deploys; it is only reset when the database schema version changes.

## Local run
`run.bat` / `run.sh` use SQLite at `backend/campussync.db`. Set `DATABASE_URL` to use Postgres.
