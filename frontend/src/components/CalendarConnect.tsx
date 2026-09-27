import { useEffect, useRef, useState } from "react";
import { AlertTriangle, CalendarClock, CalendarPlus, Link2, RefreshCw, Unplug, Upload } from "lucide-react";
import { walker } from "../lib/api";
import { ago } from "../lib/time";
import { Block, WeekGrid } from "./grids";
import { Disclosure, useToast } from "./ui";

export interface CalendarInfo {
  source: string; connected: boolean; label: string; account: string; writes_shifts: boolean;
  synced_seconds_ago: number | null; error: string; google_available: boolean;
}

/** One-time connect; after that the Availability Agent keeps it in sync on its own (every few minutes). */
export function CalendarConnect({ next = "/s/profile", onChange }: { next?: string; onChange?: () => void }) {
  const [info, setInfo] = useState<CalendarInfo | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const [showLink, setShowLink] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const toast = useToast();

  const load = async () => {
    const d = await walker<any>("get_availability");
    setInfo(d.calendar); setBlocks(d.blocks);
  };
  useEffect(() => { load().catch(() => {}); }, []);

  const act = async (name: string, body: Record<string, unknown>, ok: string) => {
    setBusy(true);
    try {
      const r = await walker<any>(name, body);
      if (r.error) toast(r.error, false); else toast(ok);
      await load(); onChange?.();
    } catch (e: any) { toast(e.message, false); await load().catch(() => {}); }
    setBusy(false);
  };
  const google = async () => {
    setBusy(true);
    try { const r = await walker<{ url: string }>("start_google_connect", { next }); window.location.href = r.url; }
    catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  const onFile = async (f?: File) => { if (f) await act("import_calendar", { ics: await f.text() }, "Calendar imported."); };
  if (!info) return <div className="ink-3 t-small">Loading your calendar…</div>;

  return (
    <div className="stack g16">
      {info.connected ? (
        <div className="stack g12">
          <div className="note ok" style={{ alignItems: "center" }}>
            <CalendarClock size={16} />
            <div className="grow"><b style={{ color: "inherit" }}>{info.label} connected</b>{info.account ? ` · ${info.account}` : ""}
              <div className="t-small">Synced {info.synced_seconds_ago != null ? ago(info.synced_seconds_ago) : "just now"} · re-syncs every few minutes on its own</div></div>
          </div>
          {info.writes_shifts && <div className="row g8 ink-2 t-small"><CalendarPlus size={15} className="c-accent" />Your shifts appear in a separate “CampusSync shifts” calendar in Google Calendar, and update when anything changes.</div>}
          <div className="row g8 wrap">
            <button className="btn sm" disabled={busy} onClick={() => act("sync_calendar", {}, "Synced.")}><RefreshCw size={14} />Sync now</button>
            {info.source === "google" && info.error && <button className="btn sm primary" onClick={google}>Reconnect Google</button>}
            <button className="btn sm text" disabled={busy} onClick={() => act("disconnect_calendar", {}, "Calendar disconnected.")}><Unplug size={14} />Disconnect</button>
          </div>
        </div>
      ) : (
        <div className="stack g12">
          {info.google_available ? (
            <button className="btn primary lg block" onClick={google} disabled={busy}><CalendarClock size={18} />Connect Google Calendar</button>
          ) : (
            <div className="note neutral"><AlertTriangle size={16} /><div>Google sign-in isn't configured on this server yet — use your calendar's secret link below (works with Google, Outlook and Apple).</div></div>
          )}
          <div className="row g8 wrap">
            <button className="btn sm" onClick={() => setShowLink((v) => !v)}><Link2 size={14} />Use a calendar link (Google, Outlook, Apple)</button>
            <button className="btn sm" onClick={() => file.current?.click()}><Upload size={14} />Upload .ics</button>
            <input ref={file} type="file" accept=".ics,text/calendar" hidden onChange={(e) => onFile(e.target.files?.[0])} />
          </div>
          {info.google_available && <span className="helper">Google asks you to allow two things: seeing your calendar's events (so you're never booked over them) and managing a calendar CampusSync creates for your shifts. It never edits your own events.</span>}
        </div>
      )}
      {info.error && <div className="note block"><AlertTriangle size={16} /><div>{info.error}</div></div>}
      {(showLink || info.source === "ics_url") && !info.connected && (
        <div className="card tight stack g12 slide-in">
          <div className="t-card">Paste your calendar's secret iCal address</div>
          <ol className="ink-2" style={{ margin: 0, paddingLeft: 18, lineHeight: 1.8 }}>
            <li>Google Calendar on a computer → ⚙ Settings → click your calendar under “Settings for my calendars”.</li>
            <li>Scroll to <b>Integrate calendar</b> → copy <b>Secret address in iCal format</b>.</li>
            <li>Paste it here. CampusSync re-reads it automatically.</li>
          </ol>
          <div className="row g8">
            <input className="input" placeholder="https://calendar.google.com/calendar/ical/…/basic.ics" value={url} onChange={(e) => setUrl(e.target.value)} />
            <button className="btn primary" disabled={!url || busy} onClick={() => act("connect_calendar", { source: "ics_url", url }, "Calendar connected.")}>Connect</button>
          </div>
          <div className="helper">Only busy times are used. Employers never see your calendar — only whether you're free.</div>
        </div>
      )}
      {blocks.length > 0 && (
        <Disclosure summary={`Your week as the agents see it · ${blocks.length} busy blocks`}>
          <WeekGrid blocks={blocks} />
        </Disclosure>
      )}
    </div>
  );
}
