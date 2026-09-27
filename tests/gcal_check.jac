"""Google Calendar write check against a fake Google API: first sync creates the calendar and events,
a retry changes nothing, a moved shift is updated in place, a removed shift is deleted, busy times are read."""

import json;
import httpx;
import from datetime { date, timedelta }
import server.calendar as calendar;
import from server.models { Employer, Employee, Shift, put, add_shift, hub }
import from server.clock { today_local }
import from server.timeutil { monday_of }

glob calendars: dict[str, dict[str, any]] = {},
     events: dict[str, dict[str, dict[str, any]]] = {},
     log: list[str] = [];

obj Resp {
    has status_code: int,
        payload: any = None,
        text: str = "";

    def json -> any {
        return self.payload;
    }
}

def fake_request(method: str, url: str, headers: any = None, timeout: any = None, params: any = None, json: any = None) -> Resp {
    log.append(method + " " + url.split("/calendar/v3")[-1]);
    base = "https://www.googleapis.com/calendar/v3/calendars";
    if url == base + "/primary/events" {
        return Resp(status_code=200, payload={"items": [
            {"summary": "Dentist", "start": {"dateTime": "2026-09-30T14:00:00-04:00"}, "end": {"dateTime": "2026-09-30T16:00:00-04:00"}}
        ]});
    }
    if url == base and method == "POST" {
        cid = f"cal{len(calendars) + 1}@group.calendar.google.com";
        calendars[cid] = json;
        events[cid] = {};
        return Resp(status_code=200, payload={"id": cid});
    }
    rest = url[len(base) + 1:];
    parts = rest.split("/");
    import from urllib.parse { unquote }
    cid = unquote(parts[0]);
    if len(parts) == 1 {
        return Resp(status_code=200 if cid in calendars else 404, payload={"id": cid});
    }
    evs = events.get(cid);
    if evs is None {
        return Resp(status_code=404);
    }
    if len(parts) == 2 and method == "GET" {
        return Resp(status_code=200, payload={"items": list(evs.values())});
    }
    if len(parts) == 2 and method == "POST" {
        if json["id"] in evs {
            return Resp(status_code=409);
        }
        evs[json["id"]] = json;
        return Resp(status_code=200, payload=json);
    }
    eid = unquote(parts[2]);
    if method == "PUT" {
        evs[eid] = json;
        return Resp(status_code=200, payload=json);
    }
    if method == "DELETE" {
        if eid in evs {
            evs.pop(eid);
            return Resp(status_code=204);
        }
        return Resp(status_code=410);
    }
    return Resp(status_code=400);
}

def fake_post(url: str, data: any = None, params: any = None, timeout: any = None) -> Resp {
    return Resp(status_code=200, payload={"access_token": "tok", "expires_in": 3600});
}

with entry:__main__ {
    setattr(calendar.httpx, "request", fake_request);
    setattr(calendar.httpx, "post", fake_post);
    setattr(calendar, "GOOGLE_CLIENT_ID", "x");
    setattr(calendar, "GOOGLE_CLIENT_SECRET", "y");
    e = put(hub(), Employer(name="Test Cafe", timezone="America/New_York"));
    st = put(hub(), Employee(name="Gina Test", calendar_source="google", google_refresh_token="rt"));
    wk = monday_of(today_local()).isoformat();
    s1 = add_shift(e, Shift(week=wk, day=3, start=600, end=840, student=jid(st), status="published"));
    s2 = add_shift(e, Shift(week=wk, day=4, start=600, end=840, student=jid(st), status="published"));
    n1 = calendar.write_shifts(st);
    cid = st.google_calendar_id;
    assert n1 == 2 and len(events[cid]) == 2, f"first write {n1}";
    n2 = calendar.write_shifts(st);
    assert n2 == 0, f"retry changed {n2}";
    s1.start = 660;
    n3 = calendar.write_shifts(st);
    assert n3 == 1 and events[cid]["cs" + jid(s1)]["start"]["dateTime"].endswith("T11:00:00"), "moved";
    s2.status = "draft";
    n4 = calendar.write_shifts(st);
    assert n4 == 1 and len(events[cid]) == 1, f"removed {n4}";
    st.google_calendar_id = "";
    n5 = calendar.write_shifts(st);
    print("recreate after lost calendar id:", n5, len(calendars));
    blocks = calendar.google_blocks("rt");
    assert blocks[0]["title"] == "Dentist" and blocks[0]["start"] == 14 * 60 and blocks[0]["end"] == 16 * 60;
    print("google calendar ok", log[:4]);
}
