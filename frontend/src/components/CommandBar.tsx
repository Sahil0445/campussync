import { FormEvent, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowRight, Check, CornerDownLeft, OctagonX, Sparkles } from "lucide-react";
import { walker } from "../lib/api";
import { fmtHours, parseSlot, slot } from "../lib/time";
import { AgentPanel, TraceRow } from "./AgentPanel";
import { Privacy, useToast } from "./ui";

export interface CopilotResult { reply: string; trace: TraceRow[]; card?: any }

const DEPT_SUGGESTIONS = [
  "Can Priya work Wednesday 12 to 3?",
  "Add 3 hours for Priya on Thursday",
  "Who can cover Saturday 3 to 7?",
  "Need 2 more people Friday 11 to 3",
  "How is coverage looking?",
];

/** Manager copilot: one sentence instead of forms. ⌘K / Ctrl+K focuses it from anywhere. */
export function CommandBar() {
  const [text, setText] = useState("");
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [res, setRes] = useState<CopilotResult | null>(null);
  const [asked, setAsked] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const toast = useToast();

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); input.current?.focus(); setOpen(true); }
      if (e.key === "Escape") setOpen(false);
    };
    const m = (e: MouseEvent) => { if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false); };
    window.addEventListener("keydown", k);
    document.addEventListener("mousedown", m);
    return () => { window.removeEventListener("keydown", k); document.removeEventListener("mousedown", m); };
  }, []);

  const run = async (t: string) => {
    if (!t.trim()) return;
    setBusy(true); setOpen(true); setRes(null); setAsked(t);
    try { setRes(await walker<CopilotResult>("copilot_command", { text: t })); setText(""); }
    catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  const submit = (e: FormEvent) => { e.preventDefault(); run(text); };

  return (
    <div className="cmd" ref={wrap}>
      <form onSubmit={submit}>
        <Sparkles size={17} className="cmd-icon" />
        <input ref={input} className="cmd-input" value={text} onChange={(e) => setText(e.target.value)} onFocus={() => setOpen(true)}
               placeholder="Tell CampusSync what you need…" aria-label="Command CampusSync" />
        <span className="cmd-kbd hide-mobile"><span className="kbd">Ctrl K</span><span className="kbd"><CornerDownLeft size={10} /></span></span>
      </form>
      {open && (
        <div className="cmd-panel">
          {!res && !busy && (
            <div className="stack g12">
              <span className="eyebrow">Try</span>
              <div className="suggest">{DEPT_SUGGESTIONS.map((s) => <button key={s} onClick={() => run(s)}>{s}</button>)}</div>
              <Privacy>Answers never reveal another department's schedule. Every action passes the rules first.</Privacy>
            </div>
          )}
          {(busy || res) && (
            <div className="stack g16">
              <div className="row g8 ink-2" style={{ fontSize: 13 }}><span className="eyebrow">You</span>{asked}</div>
              <AgentPanel trace={res?.trace ?? null} pending={busy} title="copilot · agents" />
              {res && <div className="reply slide-in w500">{res.reply}</div>}
              {res?.card && <CopilotCard card={res.card} onClose={() => setOpen(false)} onRun={run} />}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export function CopilotCard({ card, onClose, onRun }: { card: any; onClose?: () => void; onRun?: (t: string) => void }) {
  const nav = useNavigate();
  const toast = useToast();
  const [assigned, setAssigned] = useState<boolean>(!!card.assigned);
  if (card.type === "link") return <div><button className="btn primary sm" onClick={() => { onClose?.(); nav(card.to); }}>{card.label}<ArrowRight size={14} /></button></div>;
  if (card.type === "people") {
    return (
      <div className="stack g8">
        {card.people.length === 0 && <div className="note wait">No one on your team is free and under their hours. The Recruiting Agent will look across campus.</div>}
        {card.people.map((p: any) => (
          <div key={p.student_id} className="row between g12 collapsed-line" style={{ color: "var(--ink)" }}>
            <span>{p.name}<span className="ink-2"> · can take {fmtHours(p.hours_left)} more hrs</span></span>
            <button className="btn sm" onClick={() => onRun?.(`Put ${p.name.split(" ")[0]} on ${slot(card.day, card.start, card.end)}`)}>Assign</button>
          </div>
        ))}
      </div>
    );
  }
  if (card.type === "check") {
    const r = card.result;
    const label = slot(card.day, card.start, card.end);
    const assign = async () => {
      try {
        const x = await walker<any>("assign_shift", { week: card.week, student_id: card.student_id, day: card.day, start: card.start, end: card.end, position_id: card.position_id ?? null });
        if (x.assigned) { setAssigned(true); toast(`Added ${card.name} to ${label}.`); }
      } catch (e: any) { toast(e.message, false); }
    };
    if (r.available) {
      return (
        <div className="note ok" style={{ alignItems: "center" }}>
          <Check size={16} />
          <div className="grow">{assigned ? `${card.name} is on ${label}.` : <>{card.name} is free · you can schedule up to <b>{fmtHours(r.hours_left)}</b> more hrs.</>}</div>
          {!assigned && <button className="btn sm primary" onClick={assign}>Assign</button>}
        </div>
      );
    }
    const conflict = r.reason === "schedule_conflict";
    return (
      <div className="card tight stack g12" style={{ borderColor: "rgba(255,107,122,.35)" }} role="alert">
        <div className="row g8 c-block w600"><OctagonX size={16} />{conflict ? `Can't schedule ${card.name} on ${label}.` : `Can't add ${fmtHours((card.end - card.start) / 60)} hrs for ${card.name} this week.`}</div>
        <span>{conflict ? `${card.name} isn't available for this slot.` : <>This would go over their weekly limit. Hours you can still schedule: <b>{fmtHours(r.hours_left)}</b></>}</span>
        <Privacy>{conflict ? "Details are private to the student." : "Other commitments are private to the student."}</Privacy>
        {conflict && r.suggestions?.length > 0 && (
          <div className="row g8 wrap"><span className="ink-2">Try instead:</span>
            {r.suggestions.map((s: string) => { const p = parseSlot(s); return <button key={s} className="choice mono" onClick={() => p && onRun?.(`Can ${card.name} work ${s}`)}>{s}</button>; })}
          </div>
        )}
        <div><button className="btn sm" onClick={() => onRun?.(`Who can cover ${label.replace("–", " to ")}?`)}>Find someone else</button></div>
      </div>
    );
  }
  return null;
}
