import { useState } from "react";
import { Link } from "react-router-dom";
import { CalendarPlus, Play, RotateCcw } from "lucide-react";
import { Wordmark, useToast } from "../components/ui";
import { setSession } from "../lib/api";

async function post(path: string, body?: unknown, key?: string) {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (key) headers["X-Admin-Key"] = key;
  const r = await fetch(path, { method: "POST", headers, body: JSON.stringify(body ?? {}) });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.error || "Demo mode is off.");
  return d;
}

const SCENARIOS = [
  { email: "priya@demo.edu", day: 5, start: 540, end: 1020, title: "Family visit", label: "Priya adds “Family visit” to her calendar — Saturday 9:00–17:00", note: "Lands on her Sat 11:00–15:00 shift → Swap Agent finds the 3-person loop." },
  { email: "sam@demo.edu", day: 0, start: 900, end: 1080, title: "Midterm review", label: "Sam adds “Midterm review” — Monday 15:00–18:00", note: "Lands on his Mon 15:00–19:00 shift → autopilot looks for cover." },
];

/** Rehearsal control room: reset the seed, run an autopilot cycle, or simulate a calendar change. */
export function DemoPage() {
  const [busy, setBusy] = useState(false);
  const [key, setKey] = useState("");
  const toast = useToast();
  const run = async (fn: () => Promise<any>, ok: string) => {
    setBusy(true);
    try { await fn(); toast(ok); } catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  return (
    <div className="onboard">
      <Link to="/"><Wordmark /></Link>
      <h1 className="t-display mt32">Demo <span className="grad-text">control room</span></h1>
      <p className="ink-2 mt8">For rehearsals and the stage. Open Mission Control in another tab and watch these land live.</p>
      <div className="stack g16 mt32">
        <section className="card stack g12">
          <div className="t-card">Reset the week</div>
          <p className="ink-2">Restores the seed (Sep 28 – Oct 4) and runs one autopilot cycle, so the draft and recruiting suggestions are waiting in Approvals. <b style={{ color: "var(--ink)" }}>This wipes every account on this server</b>, so on the live server it needs the admin key.</p>
          <div className="row g8 wrap"><input className="input" style={{ maxWidth: 260 }} type="password" placeholder="Admin key (live server only)" value={key} onChange={(e) => setKey(e.target.value)} aria-label="Admin key" />
            <button className="btn primary" disabled={busy} onClick={() => run(async () => { await post("/demo/reset", {}, key); setSession(null); }, "Demo reset. Everyone is signed out.")}><RotateCcw size={15} />Reset demo data</button></div>
        </section>
        <section className="card stack g12">
          <div className="t-card">Simulate a calendar change</div>
          <p className="ink-2">Seeded students use a built-in demo calendar. This is exactly what happens when a real Google Calendar gets a new event: the Availability Agent syncs, sees the clash and hands it to the Swap Agent. Nobody presses anything.</p>
          {SCENARIOS.map((s) => (
            <div key={s.label} className="approval" style={{ gridTemplateColumns: "40px 1fr auto" }}>
              <span className="ic"><CalendarPlus size={18} /></span>
              <div><div className="title">{s.label}</div><div className="detail">{s.note}</div></div>
              <button className="btn sm primary" disabled={busy} onClick={() => run(() => post("/demo/calendar-event", s), "Calendar event added — autopilot is on it.")}>Add event</button>
            </div>
          ))}
        </section>
        <section className="card stack g12">
          <div className="t-card">Run an autopilot cycle now</div>
          <p className="ink-2">Autopilot runs on its own every few seconds. This just forces a cycle.</p>
          <div><button className="btn" disabled={busy} onClick={() => run(() => post("/demo/tick"), "Autopilot cycle complete.")}><Play size={15} />Run cycle</button></div>
        </section>
        <div className="row g8 wrap"><Link to="/signin" className="btn">Open sign-in</Link><Link to="/" className="btn ghost">Landing page</Link></div>
      </div>
    </div>
  );
}
