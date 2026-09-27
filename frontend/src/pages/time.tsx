import { useState } from "react";
import { Link } from "react-router-dom";
import { AlertTriangle, CalendarCheck, Check, ChevronRight, Clock, ShieldCheck } from "lucide-react";
import { ErrorBlock, Modal, Note, PageSkeleton, Segmented, StatusChip, useToast } from "../components/ui";
import { useWalker, walker } from "../lib/api";
import { dateLabel, fmtHours, hm, money, weekLabel } from "../lib/time";

interface Entry {
  id: number; date: string; label: string; start: number; end: number; hours: number; status: "reported" | "approved" | "disputed" | "void";
  department: string; role: string; pay_rate: number; gross: number;
  proposed_start: number | null; proposed_end: number | null; proposed_absent: boolean; note: string; employer_note: string;
}
interface Week { week: string; hours: number; pay: { gross: number; net: number; taxes: number }; state: "needs_you" | "waiting" | "approved"; entries: Entry[] }
interface Sheet { pending_count: number; pending_hours: number; disputed_count: number; next_review: string; review_today: boolean; weeks: Week[]; cap: number; international: boolean }

const QUARTERS = Array.from({ length: 97 }, (_, i) => i * 15);

function EntryChip({ e }: { e: Entry }) {
  if (e.status === "approved") return <StatusChip kind="ok">Approved</StatusChip>;
  if (e.status === "disputed") return <StatusChip kind="wait">With manager</StatusChip>;
  if (e.status === "void") return <StatusChip kind="neutral">Not worked</StatusChip>;
  return <StatusChip kind="neutral">To check</StatusChip>;
}

export function TimePage() {
  const { data, error, reload, setData } = useWalker<Sheet>("get_timesheet", {}, { poll: 15000 });
  const [fixing, setFixing] = useState<Entry | null>(null);
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;

  const approve = async (ids?: number[]) => {
    setBusy(true);
    try {
      const r = await walker<Sheet & { approved: number }>("approve_time", ids ? { entry_ids: ids } : {});
      setData(r);
      toast(ids ? "Approved." : `Approved ${r.approved} entr${r.approved === 1 ? "y" : "ies"}. Thanks!`);
    } catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };

  return (
    <div className="stack g20">
      <div className="stack g4"><span className="eyebrow">Time & pay</span><h1 className="t-page">Your timesheet</h1>
        <span className="ink-2">Hours are reported automatically when a shift ends. You just check them.</span></div>

      {data.pending_count > 0 ? (
        <section className="card glow stack g12">
          <div className="row g12">
            <span className="icon-tile"><CalendarCheck size={18} /></span>
            <div className="grow stack">
              <span className="w600">{data.review_today ? "It's Friday — check your week" : `${data.pending_count} ${data.pending_count === 1 ? "entry" : "entries"} to check`}</span>
              <span className="ink-2 t-small">{fmtHours(data.pending_hours)} hrs reported · make sure they match the days you actually worked</span>
            </div>
          </div>
          <button className="btn primary lg" disabled={busy} onClick={() => approve()}><Check size={16} />All correct · approve {fmtHours(data.pending_hours)} hrs</button>
        </section>
      ) : (
        <Note kind="ok" icon={<Check size={16} />}>You're all caught up. Next check: {data.review_today ? "today" : dateLabel(data.next_review, { weekday: "long", month: "short", day: "numeric" })}.</Note>
      )}
      {data.disputed_count > 0 && <Note kind="wait" icon={<Clock size={16} />}>{data.disputed_count} correction{data.disputed_count > 1 ? "s are" : " is"} waiting for your manager.</Note>}
      {data.international && (
        <div className="row g8 ink-2 t-small"><ShieldCheck size={15} className="c-accent" />International limit: reported hours can never go over {data.cap} a week across all your jobs — CampusSync blocks it.</div>
      )}

      {data.weeks.length === 0 && <div className="card ink-2">No hours reported yet. They show up here automatically after your first shift ends.</div>}
      {data.weeks.map((w) => (
        <section key={w.week} className="stack g8">
          <div className="row between g8">
            <h2 className="t-section">Week of {weekLabel(w.week)}</h2>
            {w.state === "needs_you" ? <StatusChip kind="wait">Needs you</StatusChip> : w.state === "waiting" ? <StatusChip kind="wait">With manager</StatusChip> : <StatusChip kind="ok">Approved</StatusChip>}
          </div>
          <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
            {w.entries.map((e) => (
              <div key={e.id} className="ts-row">
                <div className="grow stack g4">
                  <div className="when"><span className="nowrap">{dateLabel(e.date)}</span> <span className="nowrap">· {hm(e.start)}–{hm(e.end)}</span></div>
                  <div className="where">{e.department}{e.role ? ` · ${e.role}` : ""} · {fmtHours(e.hours)} h · {money(e.gross)}</div>
                  {e.status === "disputed" && (
                    <div className="t-small c-wait">You said: {e.proposed_absent ? "I didn't work this shift" : `${hm(e.proposed_start!)}–${hm(e.proposed_end!)}`}{e.note ? ` · “${e.note}”` : ""}</div>
                  )}
                  {e.employer_note && e.status !== "disputed" && <div className="t-small ink-3">Manager: {e.employer_note}</div>}
                </div>
                <div className="stack g8" style={{ alignItems: "flex-end" }}>
                  <EntryChip e={e} />
                  {(e.status === "reported" || e.status === "disputed") && (
                    <div className="row g4">
                      <button className="btn sm text" disabled={busy} onClick={() => setFixing(e)}>{e.status === "disputed" ? "Change" : "Fix"}</button>
                      {e.status === "reported" && <button className="btn sm" disabled={busy} onClick={() => approve([e.id])}>OK</button>}
                    </div>
                  )}
                </div>
              </div>
            ))}
            <div className="ts-foot"><span>{fmtHours(w.hours)} hrs</span><span>{money(w.pay.gross)} gross · <b>{money(w.pay.net)}</b> take-home (est.)</span></div>
          </div>
        </section>
      ))}
      <Link to="/s/profile" className="collapsed-line"><span className="grow">See hours and pay trends by week, month and year</span><ChevronRight size={15} /></Link>
      {fixing && <FixModal entry={fixing} onClose={() => setFixing(null)} onDone={(s) => { setData(s); setFixing(null); toast("Sent to your manager."); }} />}
    </div>
  );
}

function FixModal({ entry, onClose, onDone }: { entry: Entry; onClose: () => void; onDone: (s: Sheet) => void }) {
  const [mode, setMode] = useState<"times" | "absent">(entry.proposed_absent ? "absent" : "times");
  const [start, setStart] = useState(entry.proposed_start ?? entry.start);
  const [end, setEnd] = useState(entry.proposed_end ?? entry.end);
  const [note, setNote] = useState(entry.note || "");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const send = async () => {
    setBusy(true); setError(null);
    try { onDone(await walker<Sheet>("correct_time", { entry_id: entry.id, start, end, absent: mode === "absent", note })); }
    catch (e: any) { setError(e.message); setBusy(false); }
  };
  const hrs = Math.max(0, end - start) / 60;
  return (
    <Modal onClose={onClose} label="Fix reported time" sheet>
      <div className="stack g16">
        <div className="stack g4"><span className="eyebrow">{entry.department}{entry.role ? ` · ${entry.role}` : ""}</span>
          <h2 className="t-section">{dateLabel(entry.date, { weekday: "long", month: "short", day: "numeric" })}</h2>
          <span className="ink-2">Reported {hm(entry.start)}–{hm(entry.end)} · {fmtHours(entry.hours)} h</span></div>
        <Segmented full label="What's wrong?" value={mode} onChange={setMode} options={[{ value: "times", label: "Different times" }, { value: "absent", label: "I didn't work it" }]} />
        {mode === "times" && (
          <div className="row g8 wrap" style={{ alignItems: "center" }}>
            <select className="select" style={{ width: 110 }} aria-label="Start" value={start} onChange={(e) => setStart(+e.target.value)}>
              {QUARTERS.slice(0, 96).map((t) => <option key={t} value={t}>{hm(t)}</option>)}</select>
            <span className="ink-2">to</span>
            <select className="select" style={{ width: 110 }} aria-label="End" value={end} onChange={(e) => setEnd(+e.target.value)}>
              {QUARTERS.filter((t) => t > start).map((t) => <option key={t} value={t}>{hm(t)}</option>)}</select>
            <span className="ink-2 mono">{fmtHours(hrs)} h</span>
          </div>
        )}
        <input className="input" placeholder="Note for your manager (optional)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} aria-label="Note" />
        {error && <div className="note block"><AlertTriangle size={16} /><div>{error}</div></div>}
        <div className="row g8 end"><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={busy || (mode === "times" && end <= start)} onClick={send}>Send to manager</button></div>
      </div>
    </Modal>
  );
}
