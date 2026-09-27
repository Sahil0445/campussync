import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { AlertTriangle, Check, ChevronDown, ChevronLeft, ChevronRight, Download, Flag } from "lucide-react";
import { ErrorBlock, PageSkeleton, StatusChip, useToast } from "../components/ui";
import { useWalker, walker } from "../lib/api";
import { dateLabel, downloadText, fmtHours, hm, money, shiftWeek, weekLabel } from "../lib/time";

interface TEntry {
  id: number; date: string; label: string; start: number; end: number; hours: number; status: string; role: string; pay_rate: number; gross: number;
  proposed_start: number | null; proposed_end: number | null; proposed_absent: boolean; note: string; employer_note: string;
}
interface TPerson { student_id: number; name: string; email: string; hours: number; gross: number; pending: number; disputed: number; approved: number; entries: TEntry[] }
interface TWeek { week: string; current_week: string; people: TPerson[]; totals: { hours: number; cost: number; pending: number; disputed: number; approved: number; entries: number } }

function statusChip(s: string) {
  if (s === "approved") return <StatusChip kind="ok">Approved</StatusChip>;
  if (s === "disputed") return <StatusChip kind="wait">Flagged</StatusChip>;
  if (s === "void") return <StatusChip kind="neutral">Not worked</StatusChip>;
  return <StatusChip kind="neutral">With employee</StatusChip>;
}

export function TimesheetsPage() {
  const [params, setParams] = useSearchParams();
  const week = params.get("week") || undefined;
  const { data, error, reload } = useWalker<TWeek>("get_timesheets", week ? { week } : {}, { poll: 10000 });
  const [open, setOpen] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [notes, setNotes] = useState<Record<number, string>>({});
  const toast = useToast();
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  const go = (w: string) => setParams(w === data.current_week ? {} : { week: w });
  const flagged = data.people.flatMap((p) => p.entries.filter((e) => e.status === "disputed").map((e) => ({ p, e })));
  const resolve = async (id: number, accept: boolean) => {
    setBusy(true);
    try { await walker("resolve_time_entry", { entry_id: id, accept, note: notes[id] || "" }); toast(accept ? "Correction accepted." : "Kept as reported."); reload(true); }
    catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  const exportCsv = async () => {
    try { const r = await walker<{ filename: string; csv: string }>("export_timesheets", { week: data.week }); downloadText(r.filename, r.csv); }
    catch (e: any) { toast(e.message, false); }
  };
  const t = data.totals;
  return (
    <>
      <div className="dheader">
        <div className="stack g8"><span className="eyebrow">Automated time reporting</span><h1 className="t-page">Timesheets · week of {weekLabel(data.week)}</h1>
          <span className="ink-2">Hours are reported when each shift ends. Employees confirm them on Friday; you only handle what they flag.</span></div>
        <div className="actions">
          <button className="btn icon sm ghost" aria-label="Previous week" onClick={() => go(shiftWeek(data.week, -1))}><ChevronLeft size={18} /></button>
          {data.week !== data.current_week && <button className="btn sm" onClick={() => go(data.current_week)}>This week</button>}
          <button className="btn icon sm ghost" aria-label="Next week" onClick={() => go(shiftWeek(data.week, 1))}><ChevronRight size={18} /></button>
          <button className="btn sm" disabled={!t.entries} onClick={exportCsv}><Download size={15} />Export CSV</button>
        </div>
      </div>

      <div className="kpis">
        <div className="card kpi"><span className="lbl">Hours reported</span><span className="num">{fmtHours(t.hours)}</span><span className="ink-3 t-small">{t.entries} shifts</span></div>
        <div className="card kpi"><span className="lbl">Labor cost</span><span className="num">{money(t.cost, false)}</span><span className="ink-3 t-small">gross pay</span></div>
        <div className="card kpi"><span className="lbl">Waiting on employees</span><span className="num">{t.pending}</span><span className="ink-3 t-small">they confirm on Friday</span></div>
        <div className="card kpi"><span className="lbl row g8"><Flag size={14} />Flagged for you</span><span className={`num ${t.disputed ? "c-wait" : ""}`}>{t.disputed}</span><span className="ink-3 t-small">{t.approved} approved</span></div>
      </div>

      {flagged.length > 0 && (
        <section className="card mt16 stack g12">
          <h2 className="t-section row g8"><AlertTriangle size={17} className="c-wait" />Flagged by employees</h2>
          {flagged.map(({ p, e }) => (
            <div key={e.id} className="approval" style={{ gridTemplateColumns: "1fr auto" }}>
              <div className="stack g4">
                <span className="title">{p.name} · {dateLabel(e.date)}{e.role ? ` · ${e.role}` : ""}</span>
                <span className="detail">Reported {hm(e.start)}–{hm(e.end)} ({fmtHours(e.hours)} h) → says <b style={{ color: "var(--ink)" }}>{e.proposed_absent ? "didn't work this shift" : `${hm(e.proposed_start!)}–${hm(e.proposed_end!)} (${fmtHours((e.proposed_end! - e.proposed_start!) / 60)} h)`}</b></span>
                {e.note && <span className="detail">“{e.note}”</span>}
                <input className="input" style={{ height: 36, maxWidth: 420 }} placeholder="Reply (optional, shown to the employee)" value={notes[e.id] || ""} onChange={(ev) => setNotes({ ...notes, [e.id]: ev.target.value })} aria-label="Reply" />
              </div>
              <div className="acts" style={{ alignSelf: "center" }}>
                <button className="btn sm ghost" disabled={busy} onClick={() => resolve(e.id, false)}>Keep reported</button>
                <button className="btn sm primary" disabled={busy} onClick={() => resolve(e.id, true)}><Check size={14} />Accept</button>
              </div>
            </div>
          ))}
        </section>
      )}

      <section className="card mt16">
        <h2 className="t-section">People</h2>
        {data.people.length === 0 && <div className="ink-2 mt12">No hours reported this week yet. They appear automatically as shifts end.</div>}
        <div className="divided mt12">
          {data.people.map((p) => (
            <div key={p.student_id}>
              <button className="list-row ts-person" onClick={() => setOpen(open === p.student_id ? null : p.student_id)} aria-expanded={open === p.student_id}>
                <span className="grow stack" style={{ textAlign: "left" }}><span className="w600">{p.name}</span><span className="t-small ink-3">{p.entries.length} shift{p.entries.length === 1 ? "" : "s"} · {p.email}</span></span>
                <span className="row g8 wrap" style={{ justifyContent: "flex-end" }}>
                  {p.disputed > 0 && <StatusChip kind="wait">{p.disputed} flagged</StatusChip>}
                  {p.pending > 0 && <StatusChip kind="neutral">{p.pending} to confirm</StatusChip>}
                  {p.pending === 0 && p.disputed === 0 && <StatusChip kind="ok">Approved</StatusChip>}
                </span>
                <span className="num" style={{ width: 64, textAlign: "right" }}>{fmtHours(p.hours)} h</span>
                <span className="num hide-mobile" style={{ width: 90, textAlign: "right" }}>{money(p.gross)}</span>
                <ChevronDown size={16} className="ink-3" style={{ transform: open === p.student_id ? "rotate(180deg)" : undefined }} />
              </button>
              {open === p.student_id && (
                <div className="table-wrap slide-in" style={{ marginBottom: 12 }}><table className="table compact">
                  <thead><tr><th>Date</th><th>Time</th><th>Role</th><th>Hours</th><th>Rate</th><th>Gross</th><th>Status</th></tr></thead>
                  <tbody>{p.entries.map((e) => (
                    <tr key={e.id}><td>{dateLabel(e.date)}</td><td className="mono">{hm(e.start)}–{hm(e.end)}</td><td>{e.role || "—"}</td>
                      <td className="num">{fmtHours(e.hours)}</td><td className="num">{money(e.pay_rate)}</td><td className="num">{money(e.gross)}</td><td>{statusChip(e.status)}</td></tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>
          ))}
        </div>
      </section>
    </>
  );
}
