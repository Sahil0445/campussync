# Deploying CampusSync on JacHammer

Phones need HTTPS for Google sign-in and push notifications, so friends test against the hosted copy.
JacHammer docs: https://docs.jachammer.ai

## 1. Code on GitHub
The repository root must be this Jac project (`jac.toml`, `main.jac`, `server/`, `web/`, `public/`).
`jac.toml` pins `jac-version = "==0.37.23"`, the version everything was built and tested with.

## 2. Import into JacHammer
1. https://jachammer.ai → sign in.
2. Import an existing repository: point it at `https://github.com/<you>/campussync` (public repos are cloned directly;
   for a private repo connect GitHub first). Import works on the Free plan.

## 3. Environment variables (Project → Settings → Environment)
| Name | Value | Needed |
|---|---|---|
| `JAC_SERVE_AUTH_SECRET` | a long random string (e.g. 48+ characters) — signs everyone's login tokens | **yes** |
| `CAMPUSSYNC_ADMIN_KEY` | a random string you keep private — required to reset the demo at `/demo` | **yes** |
| `GEMINI_API_KEY` | your Gemini key | optional (agents fall back to built-in logic) |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | from Google Cloud, see [GOOGLE_CALENDAR.md](GOOGLE_CALENDAR.md) | optional |
| `CAMPUSSYNC_PUBLIC_URL` | your deploy URL, e.g. `https://campussync-xxxx.jachammer.app` (no trailing slash) | with Google |
| `CAMPUSSYNC_TZ` | default time zone, default `America/New_York` | optional |
| `CAMPUSSYNC_KEEPALIVE_URL` | your deploy URL — the app pings itself every 10 min (only if the host sleeps when idle) | optional |

Never put these values in files in the repo.

## 4. Deploy
**Deploy tab → Sandbox deploy** (free on every plan, lives 7 days; deploying uses no credits).
Or from a terminal:
```bash
curl -fsSL https://jachammer.ai/static/assets/cli/install.sh | bash
jachammer login
jachammer link <project-name>
jachammer deploy
```
A permanent deploy (Builder or Pro plan) has no expiry and supports a custom domain with automatic HTTPS.

## 5. Check it
- `https://YOUR-URL/status` → `"ok": true`, `"seeded": true` (the demo data is created on the first autopilot cycle, ~15 s after start),
  `"ai": "gemini"` when the key works.
- Sign in with a demo account (password `demo1234`), e.g. `dining@demo.edu` and `priya@demo.edu`.
- Google: add the URL to your OAuth client (origin + `/auth/google/callback`), set the three Google variables, redeploy.
  `/status` should then show `"google_calendar": true` and the exact redirect URI.

## 6. Friends
- Share the URL. Employers register at **Get started → I'm an employer** and share their join code / invite link;
  employees sign up with the code. Accounts from the Render version don't carry over — everyone signs up once here.
- Alerts: Profile → **Phone alerts → Turn on alerts**. iPhone: Safari → Share → **Add to Home Screen** first, then open
  CampusSync from the Home Screen icon.
- Google Calendar: each friend's Gmail must be a **test user** on the OAuth consent screen.

## 7. After 7 days
A sandbox expires after 7 days. Deploy again to get a fresh one (the URL and data may change), or move to a
permanent deploy to keep one address.
