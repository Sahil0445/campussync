# Connecting Google Calendar

With Google connected, CampusSync:
- **reads busy times** from the employee's primary calendar every ~5 minutes, so nobody is scheduled over a class or appointment (a new event on top of a shift automatically starts the Swap Agent), and
- **writes their shifts** into a separate calendar it creates, called **"CampusSync shifts"**. Publishes, swaps and pick-ups update it within a minute. It never edits the person's own events.

Scopes requested: `openid email`, `calendar.events.readonly` (busy times), `calendar.app.created` (the shifts calendar it owns).

## Setup (~10 minutes)

You can reuse the OAuth client you made for the Render version — just add the new address to it (step 4).

1. https://console.cloud.google.com/ → your **CampusSync** project (or create one).
2. **APIs & Services → Library → Google Calendar API → Enable.**
3. **Google Auth Platform → Audience:** publishing status **Testing**; under **Test users** add every Google account that will connect (yours and your friends'). Up to 100. Only listed accounts can connect while the app is in Testing.
4. **Google Auth Platform → Clients →** your Web client (or **Create client → Web application**):
   - **Authorized JavaScript origins:** `https://YOUR-APP-URL` (your JacHammer address, no trailing slash)
   - **Authorized redirect URIs:** `https://YOUR-APP-URL/auth/google/callback`
     (for local testing also add `http://localhost:8000/auth/google/callback`)
5. In JacHammer → your project → **Settings → Environment**, set `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `CAMPUSSYNC_PUBLIC_URL=https://YOUR-APP-URL`, then redeploy.
6. Open `https://YOUR-APP-URL/status` → `"google_calendar": true` and `"google_redirect_uri"` exactly matching step 4.

Never commit the client secret (or the downloaded client JSON/txt) to git.

## What testers will see
- Google shows **"Google hasn't verified this app"** → **Continue** (normal for apps in Testing).
- Two permission boxes (see events, manage calendars CampusSync creates) — both must be ticked.
- In Testing mode Google expires the connection after **7 days**; the app then shows "Reconnect Google". Publishing the app (Google verification) removes that limit.

## Without Google setup
Employees can paste their calendar's **secret iCal address** (Google: Settings → your calendar → Integrate calendar), or upload an .ics file. That reads busy times but can't write shifts back.
