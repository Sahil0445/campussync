"""Web Push delivery (mock push service, real encryption) and Google Calendar sync (mock Google API)."""
import json
import os
import re
import struct
from urllib.parse import parse_qs, urlparse

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hmac import HMAC
from sqlalchemy import select

from app import config
from app.db import SessionLocal
from app.models import CalendarEventLink, PushSubscription, Shift, Student, SwapRequest
from app.services import calendar, push

H = 60


# ------------------------------------------------------------------ a fake browser
def _hmac(key, data):
    h = HMAC(key, hashes.SHA256())
    h.update(data)
    return h.finalize()


class Browser:
    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.pub = self.key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        self.auth = os.urandom(16)

    def subscription(self, endpoint):
        return {"endpoint": endpoint, "keys": {"p256dh": push.b64u(self.pub), "auth": push.b64u(self.auth)}}

    def decrypt(self, body: bytes) -> dict:
        salt, rs, idlen = body[:16], struct.unpack("!L", body[16:20])[0], body[20]
        as_pub = body[21:21 + idlen]
        ct = body[21 + idlen:]
        shared = self.key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_pub))
        ikm = _hmac(_hmac(self.auth, shared), b"WebPush: info\x00" + self.pub + as_pub + b"\x01")[:32]
        prk = _hmac(salt, ikm)
        cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
        nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12]
        plain = AESGCM(cek).decrypt(nonce, ct, None)
        assert plain.endswith(b"\x02") and rs == 4096
        return json.loads(plain[:-1])


def test_push_subscription_delivery_and_cleanup(login):
    marcus = login("marcus@demo.edu")
    cfg = marcus("get_push_config")
    assert len(push.unb64u(cfg["public_key"])) == 65 and cfg["devices"] == 0
    phone, gone = Browser(), Browser()
    marcus("save_push_subscription", subscription=phone.subscription("https://fcm.googleapis.com/fcm/send/phone1"), user_agent="Pixel")
    marcus("save_push_subscription", subscription=gone.subscription("https://web.push.apple.com/gone"), user_agent="iPhone")
    marcus("save_push_subscription", expect=400, subscription={"endpoint": "https://x", "keys": {"p256dh": "bad", "auth": "bad"}})
    assert marcus("get_push_config", endpoint="https://fcm.googleapis.com/fcm/send/phone1")["this_device"] is True

    seen = []

    def service(request: httpx.Request):
        seen.append(request)
        if request.url.host == "web.push.apple.com":
            return httpx.Response(410)
        return httpx.Response(201)

    client = httpx.Client(transport=httpx.MockTransport(service))
    marcus("send_test_alert", kind="shift_24h")  # creates a push notification (delivery attempted without a network here)
    dining = login("dining@demo.edu", "department")
    tom_id = next(p["student_id"] for p in dining("get_team")["people"] if p["name"].startswith("Marcus"))
    from app.notify import to_student
    with SessionLocal() as db:
        to_student(db, tom_id, "Tomorrow 11 AM–3 PM · Campus Dining.", "/s", title="Shift reminder", kind="shift_24h", dedupe_key="t1")
        db.commit()
        sent = push.deliver_pending(db, client=client)
        assert sent == 1
        assert db.scalars(select(PushSubscription)).all()[0].endpoint.endswith("phone1")  # 410 -> removed
    req = next(r for r in seen if r.url.host == "fcm.googleapis.com")
    assert req.headers["content-encoding"] == "aes128gcm" and req.headers["ttl"]
    assert re.match(r"vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=[\w-]+", req.headers["authorization"])
    msg = phone.decrypt(req.content)
    assert msg["title"] == "Shift reminder" and msg["url"] == "/s" and "Campus Dining" in msg["body"]
    with SessionLocal() as db:  # nothing is sent twice
        assert push.deliver_pending(db, client=client) == 0


# ------------------------------------------------------------------ a fake Google
class FakeGoogle:
    def __init__(self, events):
        self.events = events
        self.calendars = {}
        self.calls = []
        self.revoked = []

    def handle(self, method, url, **kw):
        self.calls.append((method, url))
        u = urlparse(url)
        if u.netloc == "oauth2.googleapis.com" and u.path == "/token":
            data = kw.get("data", {})
            if data.get("grant_type") == "authorization_code":
                idt = "x." + push.b64u(json.dumps({"email": "priya.real@gmail.com"}).encode()) + ".y"
                return httpx.Response(200, json={"refresh_token": "r-1", "access_token": "a-1", "expires_in": 3600, "id_token": idt,
                                                 "scope": " ".join(calendar.SCOPES[2:]) + " openid email"})
            return httpx.Response(200, json={"access_token": "a-2", "expires_in": 3600})
        if u.path == "/revoke":
            self.revoked.append(kw.get("params", {}).get("token"))
            return httpx.Response(200)
        if u.path == "/calendar/v3/calendars/primary/events":
            return httpx.Response(200, json={"items": self.events})
        if u.path == "/calendar/v3/calendars" and method == "POST":
            self.calendars["cs-cal"] = {}
            return httpx.Response(200, json={"id": "cs-cal"})
        m = re.match(r"/calendar/v3/calendars/([^/]+)(/events(?:/(.+))?)?$", u.path)
        if m:
            cal, ev, eid = m.group(1), m.group(2), m.group(3)
            if cal not in self.calendars:
                return httpx.Response(404)
            if not ev:
                if method == "DELETE":
                    del self.calendars[cal]
                return httpx.Response(200 if method == "GET" else 204, json={"id": cal} if method == "GET" else None)
            store = self.calendars[cal]
            if method == "POST":
                eid = f"ev{len(store) + 1}"
                store[eid] = kw["json"]
                return httpx.Response(200, json={"id": eid})
            if method == "PUT":
                store[eid] = kw["json"]
                return httpx.Response(200, json={"id": eid})
            if method == "DELETE":
                store.pop(eid, None)
                return httpx.Response(204)
        return httpx.Response(404)


def test_google_calendar_connect_read_write_and_disconnect(client, login, monkeypatch):
    monkeypatch.setattr(config, "GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
    monkeypatch.setattr(config, "GOOGLE_CLIENT_SECRET", "secret")
    # Priya adds "Family visit" on Saturday Oct 3, 10:00–16:00 — on top of her Dining 11–15 shift.
    g = FakeGoogle([{"summary": "Family visit", "start": {"dateTime": "2026-10-03T10:00:00-04:00"},
                     "end": {"dateTime": "2026-10-03T16:00:00-04:00"}},
                    {"summary": "Declined meeting", "start": {"dateTime": "2026-10-01T09:00:00-04:00"},
                     "end": {"dateTime": "2026-10-01T10:00:00-04:00"}, "attendees": [{"self": True, "responseStatus": "declined"}]},
                    {"summary": "Office", "eventType": "workingLocation", "start": {"dateTime": "2026-10-01T09:00:00-04:00"},
                     "end": {"dateTime": "2026-10-01T17:00:00-04:00"}}])
    monkeypatch.setattr(calendar.httpx, "post", lambda url, **kw: g.handle("POST", url, **kw))
    monkeypatch.setattr(calendar.httpx, "get", lambda url, **kw: g.handle("GET", url, **kw))
    monkeypatch.setattr(calendar.httpx, "request", lambda method, url, **kw: g.handle(method, url, **kw))
    calendar._tokens.clear()

    priya = login("priya@demo.edu")
    token = priya.headers["Authorization"][7:]
    r = client.get("/auth/google/start", params={"token": token, "next": "/s/availability"}, follow_redirects=False)
    assert r.status_code in (302, 307)
    loc = urlparse(r.headers["location"])
    q = parse_qs(loc.query)
    assert loc.netloc == "accounts.google.com" and q["access_type"] == ["offline"] and "calendar.app.created" in q["scope"][0]
    assert q["redirect_uri"] == [f"{config.PUBLIC_BASE_URL}/auth/google/callback"]
    r = client.get("/auth/google/callback", params={"code": "c-1", "state": q["state"][0]}, follow_redirects=False)
    assert r.headers["location"] == "/s/availability?calendar=connected"

    info = priya("get_availability")["calendar"]
    assert info["connected"] and info["source"] == "google" and info["account"] == "priya.real@gmail.com" and info["writes_shifts"]
    busy = {b["title"] for b in priya("get_availability")["blocks"]}
    assert "Family visit" in busy and "Declined meeting" not in busy and "Office" not in busy
    with SessionLocal() as db:
        st = db.scalar(select(Student).where(Student.email == "priya@demo.edu"))
        # the clash raised a cover request on her behalf
        assert db.scalar(select(SwapRequest).where(SwapRequest.requester_id == st.id, SwapRequest.origin == "calendar"))
        links = db.scalars(select(CalendarEventLink).where(CalendarEventLink.student_id == st.id)).all()
        n_shifts = len(calendar.upcoming_shift_events(db, st))
    assert n_shifts >= 5 and len(links) == n_shifts and len(g.calendars["cs-cal"]) == n_shifts
    ev = next(iter(g.calendars["cs-cal"].values()))
    assert ev["start"]["timeZone"] == "America/New_York" and "shift" in ev["summary"]

    # A shift moves away -> the mirrored event is removed on the next cycle without waiting for the full sync
    with SessionLocal() as db:
        st = db.scalar(select(Student).where(Student.email == "priya@demo.edu"))
        sh = db.scalar(select(Shift).where(Shift.student_id == st.id, Shift.week == "2026-09-28", Shift.day == 1))
        sh.student_id, sh.state = None, "open"
        db.commit()
        calendar.sync_due(db)
    assert len(g.calendars["cs-cal"]) == n_shifts - 1

    # Revoked access surfaces a clear message
    monkeypatch.setattr(calendar.httpx, "post", lambda url, **kw: httpx.Response(400, text='{"error":"invalid_grant"}')
                        if "token" in url else g.handle("POST", url, **kw))
    calendar._tokens.clear()
    r = priya("sync_calendar", expect=400)
    assert "Reconnect Google Calendar" in r["error"]
    monkeypatch.setattr(calendar.httpx, "post", lambda url, **kw: g.handle("POST", url, **kw))

    priya("disconnect_calendar")
    assert "cs-cal" not in g.calendars and g.revoked == ["r-1"]
    info = priya("get_availability")["calendar"]
    assert not info["connected"] and info["account"] == ""


def test_google_not_configured_is_honest(client, login):
    priya = login("priya@demo.edu")
    token = priya.headers["Authorization"][7:]
    r = client.get("/auth/google/start", params={"token": token, "next": "/s/availability"}, follow_redirects=False)
    assert r.headers["location"] == "/s/availability?calendar=unavailable"
    assert priya("get_availability")["calendar"]["google_available"] is False
    # open-redirect guard
    r = client.get("/auth/google/start", params={"token": token, "next": "//evil.com"}, follow_redirects=False)
    assert r.headers["location"].startswith("/s?")


def test_google_connect_walker_keeps_token_out_of_urls(login, monkeypatch):
    monkeypatch.setattr(config, "GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setattr(config, "GOOGLE_CLIENT_SECRET", "s")
    priya = login("priya@demo.edu")
    url = priya("start_google_connect", next="/s/availability")["url"]
    assert url.startswith("https://accounts.google.com/") and priya.headers["Authorization"][7:] not in url
    assert "//evil" not in priya("start_google_connect", next="//evil.com")["url"]


def test_login_throttle(client):
    for _ in range(10):
        assert client.post("/user/login", json={"email": "sam@demo.edu", "password": "wrong"}).status_code == 401
    r = client.post("/user/login", json={"email": "sam@demo.edu", "password": "demo1234"})
    assert r.status_code == 429
    from app import main
    main._failed.clear()
    assert client.post("/user/login", json={"email": "sam@demo.edu", "password": "demo1234"}).status_code == 200
