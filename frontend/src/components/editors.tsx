import { useEffect, useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { walker } from "../lib/api";
import { DAYS_LONG, TIME_OPTIONS, hm } from "../lib/time";
import { Stepper, useToast } from "./ui";

/* ---------------- staffing needs editor (15.3 step 2, 15.8) ---------------- */
export interface Need { day: number; start: number; end: number; headcount: number; position_id?: number | null }

export function NeedsEditor({ needs, onChange, roles = [] }: { needs: Need[]; onChange: (n: Need[]) => void; roles?: { id: number; name: string }[] }) {
  const update = (i: number, patch: Partial<Need>) => onChange(needs.map((n, j) => (j === i ? { ...n, ...patch } : n)));
  const remove = (i: number) => onChange(needs.filter((_, j) => j !== i));
  const add = (day: number) => {
    const last = [...needs].filter((n) => n.day === day).sort((a, b) => b.end - a.end)[0];
    const start = last ? Math.min(last.end, 20 * 60) : 9 * 60;
    onChange([...needs, { day, start, end: Math.min(start + 4 * 60, 24 * 60), headcount: last?.headcount ?? 1, position_id: last?.position_id ?? null }]);
  };
  const copyMonday = () => {
    const mon = needs.filter((n) => n.day === 0);
    const rest = needs.filter((n) => n.day > 4);
    onChange([...[0, 1, 2, 3, 4].flatMap((d) => mon.map((n) => ({ ...n, day: d }))), ...rest]);
  };
  return (
    <div className="stack g16">
      <div className="row end">
        <button type="button" className="btn sm" onClick={copyMonday} disabled={!needs.some((n) => n.day === 0)}>Copy Monday to weekdays</button>
      </div>
      {DAYS_LONG.map((label, day) => {
        const rows = needs.map((n, i) => ({ n, i })).filter(({ n }) => n.day === day).sort((a, b) => a.n.start - b.n.start);
        return (
          <section key={day} className="card tight">
            <div className="row between">
              <h3 className="t-card">{label}</h3>
              <button type="button" className="btn text sm" onClick={() => add(day)}><Plus size={14} strokeWidth={1.5} />Add block</button>
            </div>
            {rows.length === 0 && <div className="ink-2 mt8">No one needed.</div>}
            <div className="stack g8 mt8">
              {rows.map(({ n, i }) => (
                <div key={i} className="row g8 wrap">
                  <select className="select" style={{ width: 104 }} aria-label="Start time" value={n.start}
                          onChange={(e) => update(i, { start: +e.target.value })}>
                    {TIME_OPTIONS.map((t) => <option key={t} value={t}>{hm(t)}</option>)}
                  </select>
                  <span className="ink-2">to</span>
                  <select className="select" style={{ width: 104 }} aria-label="End time" value={n.end}
                          onChange={(e) => update(i, { end: +e.target.value })}>
                    {TIME_OPTIONS.filter((t) => t > n.start).concat(n.end <= n.start ? [n.end] : []).map((t) => <option key={t} value={t}>{hm(t)}</option>)}
                  </select>
                  <Stepper value={n.headcount} min={1} max={50} onChange={(v) => update(i, { headcount: v })} label="People needed" />
                  <span className="ink-2 hide-mobile">{n.headcount === 1 ? "person" : "people"}</span>
                  {roles.length > 0 && (
                    <select className="select" style={{ width: 150 }} aria-label="Role" value={n.position_id ?? ""}
                            onChange={(e) => update(i, { position_id: e.target.value ? +e.target.value : null })}>
                      <option value="">Any role</option>
                      {roles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
                    </select>
                  )}
                  <button type="button" className="btn icon text" style={{ color: "var(--ink-2)", marginLeft: "auto" }} aria-label="Delete block" onClick={() => remove(i)}>
                    <Trash2 size={16} strokeWidth={1.5} />
                  </button>
                  {n.end <= n.start && <span className="helper c-block" style={{ width: "100%" }}>This block ends before it starts.</span>}
                </div>
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}

/* ---------------- standing availability rules (Availability Agent) ---------------- */
interface Rule { day: number; start: number; end: number; label: string }

export function AvailabilityNotes() {
  const [note, setNote] = useState("");
  const [savedNote, setSavedNote] = useState("");
  const [rules, setRules] = useState<Rule[]>([]);
  const [parsing, setParsing] = useState(false);
  const toast = useToast();
  useEffect(() => {
    walker<any>("get_availability").then((d) => { setNote(d.note); setSavedNote(d.note); setRules(d.rules); }).catch(() => {});
  }, []);
  const parse = async () => {
    if (note === savedNote) return;
    setParsing(true);
    try { const r = await walker<any>("parse_availability_note", { note }); setRules(r.rules); setSavedNote(note); }
    catch (e: any) { toast(e.message, false); }
    setParsing(false);
  };
  const removeRule = async (r: Rule) => {
    await walker<any>("remove_availability_rule", { day: r.day, start: r.start, end: r.end });
    setRules((xs) => xs.filter((x) => x !== r));
  };
  return (
    <div className="field">
      <label htmlFor="note">Anything that's true every week?</label>
      <textarea id="note" className="textarea" placeholder="e.g. No Fridays before 10 AM — I have lab." value={note} onChange={(e) => setNote(e.target.value)} onBlur={parse} />
      {parsing && <div className="helper mono">Availability Agent is reading this…</div>}
      {!parsing && rules.length > 0 && (
        <div className="stack g8 mt4">
          <span className="mono ink-3">Understood by Availability Agent</span>
          <div className="row g8 wrap">{rules.map((r, i) => <span key={i} className="rule-chip">{r.label}<button type="button" aria-label={`Remove ${r.label}`} onClick={() => removeRule(r)}>×</button></span>)}</div>
        </div>
      )}
      {!parsing && savedNote && note === savedNote && rules.length === 0 && <div className="helper">No time limits found in this note.</div>}
    </div>
  );
}
