"""One-time calendar connect; after that the Availability Agent keeps it in sync on its own (every few minutes)."""

import from react { useRef }
import from "lucide-react" { AlertTriangle, CalendarClock, CalendarPlus, Link2, RefreshCw, Unplug, Upload }
import from web.lib.api { api, errMsg }
import from web.lib.time { ago }
import from web.components.grids { WeekGrid }
import from web.components.ui { Disclosure, useToast }

glob:pub JS: any = globalThis;

def:pub CalendarConnect(next: str = "/s/profile", onChange: any = None) -> JsxElement {
    has info: any = None;
    has blocks: list[any] = [];
    has url: str = "";
    has busy: bool = False;
    has showLink: bool = False;
    fileRef: any = useRef(None);
    toast: any = useToast();

    async def load() -> None {
        d: any = await api("get_availability");
        info = d.calendar;
        blocks = d.blocks;
    }

    async can with entry {
        try {
            await load();
        } except Exception {
            return;
        }
    }

    async def act(name: str, body: any, ok: str) -> None {
        busy = True;
        try {
            r: any = await api(name, body);
            if r.error {
                toast(r.error, False);
            } else {
                toast(ok);
            }
            await load();
            if onChange {
                onChange();
            }
        } except Exception as e {
            toast(errMsg(e), False);
            try {
                await load();
            } except Exception {
                busy = False;
            }
        }
        busy = False;
    }

    async def google() -> None {
        busy = True;
        try {
            r: any = await api("start_google_connect", {"next": next, "origin": JS.window.location.origin});
            JS.window.location.href = r.url;
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }

    async def onFile(f: any) -> None {
        if f {
            text: str = await f.text();
            await act("import_calendar", {"ics": text}, "Calendar imported.");
        }
    }

    if not info {
        return <div className="ink-3 t-small">Loading your calendar…</div>;
    }
    synced: str = ago(info.synced_seconds_ago) if info.synced_seconds_ago != None else "just now";
    <div className="stack g16">
        {<div className="stack g12">
            <div className="note ok" style={{"alignItems": "center"}}>
                <CalendarClock size={16} />
                <div className="grow"><b style={{"color": "inherit"}}>{info.label} connected</b>{(" · " + info.account) if info.account else ""}
                    <div className="t-small">Synced {synced} · re-syncs every few minutes on its own</div></div>
            </div>
            {info.writes_shifts and <div className="row g8 ink-2 t-small"><CalendarPlus size={15} className="c-accent" />Your shifts appear in a separate “CampusSync shifts” calendar in Google Calendar, and update when anything changes.</div>}
            <div className="row g8 wrap">
                <button className="btn sm" disabled={busy} onClick={lambda (e: MouseEvent) { act("sync_calendar", {}, "Synced."); }}><RefreshCw size={14} />Sync now</button>
                {info.source == "google" and info.error and <button className="btn sm primary" onClick={lambda (e: MouseEvent) { google(); }}>Reconnect Google</button>}
                <button className="btn sm text" disabled={busy} onClick={lambda (e: MouseEvent) { act("disconnect_calendar", {}, "Calendar disconnected."); }}><Unplug size={14} />Disconnect</button>
            </div>
        </div> if info.connected else <div className="stack g12">
            {<button className="btn primary lg block" onClick={lambda (e: MouseEvent) { google(); }} disabled={busy}><CalendarClock size={18} />Connect Google Calendar</button>
                if info.google_available else
             <div className="note neutral"><AlertTriangle size={16} /><div>Google sign-in isn't configured on this server yet — use your calendar's secret link below (works with Google, Outlook and Apple).</div></div>}
            <div className="row g8 wrap">
                <button className="btn sm" onClick={lambda (e: MouseEvent) { showLink = not showLink; }}><Link2 size={14} />Use a calendar link (Google, Outlook, Apple)</button>
                <button className="btn sm" onClick={lambda (e: MouseEvent) { if fileRef.current { fileRef.current.click(); } }}><Upload size={14} />Upload .ics</button>
                <input ref={fileRef} type="file" accept=".ics,text/calendar" hidden={True} onChange={lambda (e: ChangeEvent) { fl: any = e.target; onFile(fl.files[0] if fl.files else None); }} />
            </div>
            {info.google_available and <span className="helper">Google asks you to allow two things: seeing your calendar's events (so you're never booked over them) and managing a calendar CampusSync creates for your shifts. It never edits your own events.</span>}
        </div>}
        {info.error and <div className="note block"><AlertTriangle size={16} /><div>{info.error}</div></div>}
        {(showLink or info.source == "ics_url") and not info.connected and <div className="card tight stack g12 slide-in">
            <div className="t-card">Paste your calendar's secret iCal address</div>
            <ol className="ink-2" style={{"margin": 0, "paddingLeft": 18, "lineHeight": 1.8}}>
                <li>Google Calendar on a computer → ⚙ Settings → click your calendar under “Settings for my calendars”.</li>
                <li>Scroll to <b>Integrate calendar</b> → copy <b>Secret address in iCal format</b>.</li>
                <li>Paste it here. CampusSync re-reads it automatically.</li>
            </ol>
            <div className="row g8">
                <input className="input" placeholder="https://calendar.google.com/calendar/ical/…/basic.ics" value={url} onChange={lambda (e: ChangeEvent) { url = e.target.value; }} />
                <button className="btn primary" disabled={not url or busy} onClick={lambda (e: MouseEvent) { act("connect_calendar", {"source": "ics_url", "url": url}, "Calendar connected."); }}>Connect</button>
            </div>
            <div className="helper">Only busy times are used. Employers never see your calendar — only whether you're free.</div>
        </div>}
        {len(blocks) > 0 and <Disclosure summary={"Your week as the agents see it · " + str(len(blocks)) + " busy blocks"}>
            <WeekGrid blocks={blocks} />
        </Disclosure>}
    </div>
}
