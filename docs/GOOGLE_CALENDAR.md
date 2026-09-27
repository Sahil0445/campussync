# Connecting Google Calendar

With Google connected, CampusSync:
- **reads busy times** from the employee's primary calendar every ~5 minutes, so nobody is scheduled over a class or appointment (a new event on top of a shift automatically starts the Swap Agent), and
- **writes their shifts** into a separate calendar it creates, called **"CampusSync shifts"**. Publishes, swaps and pick-ups update it within a minute. It never edits the person's own events.

Scopes requested: `openid email`, `calendar.events.readonly` (busy times), `calendar.app.created` (the shifts calendar it owns).

## Setup (the person who runs the server, ~10 minutes)

1. https://console.cloud.google.com/ → create a project, e.g. **CampusSync**.
2. **APIs & Services → Library → Google Calendar API → Enable.**
3. **APIs & Services → OAuth consent screen** (now called "Google Auth Platform"):
   - User type **External**, app name, support email, developer email.
   - Leave publishing status on **Testing**.
   - **Audience → Test users → Add users:** every Google account that will connect (yours and your friends'). Up to 100. Only listed accounts can connect while the app is in Testing.
4. **Clients (Credentials) → Create client → OAuth client ID:**
   - Application type **Web application**
   - **Authorized JavaScript origins:** `https://YOUR-APP.onrender.com`
   - **Authorized redirect URIs:** `https://YOUR-APP.onrender.com/auth/google/callback`
     (for local testing also add `http://localhost:8000/auth/google/callback`)
5. Copy the **Client ID** and **Client secret** into Render → your service → **Environment** as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` (or into `backend/.env` locally). Save; Render redeploys.
6. Check `https://YOUR-APP.onrender.com/healthz` → `"google_calendar": true` and `google_redirect_uri` exactly matching step 4.

## What testers will see
- Google shows **"Google hasn't verified this app"** → **Continue** (normal for apps in Testing).
- Two permission boxes (see events, manage calendars CampusSync creates) — both must be ticked.
- In Testing mode Google expires the connection after **7 days**; the app then shows "Reconnect Google Calendar". Publishing the app (Google verification) removes that limit.

## Without Google setup
Employees can paste their calendar's **secret iCal address** (Google: Settings → your calendar → Integrate calendar), or upload an .ics file. That reads busy times but can't write shifts back.
