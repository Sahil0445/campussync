import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { ArrowRight, CalendarCheck, Check, ChevronLeft, Clock, Copy, Inbox, OctagonX, Pencil, Plus, Repeat, Share2, Sparkles, Trash2, UserMinus, UserPlus, X } from "lucide-react";
import { NotificationSettings } from "../components/Notifications";
import { AgentPanel, TraceRow } from "../components/AgentPanel";
import { AgentOrbit } from "../components/AgentOrbit";
import { CopilotCard, CopilotResult } from "../components/CommandBar";
import { Need, NeedsEditor } from "../components/editors";
import { Cell, Coverage, LoopDiagram } from "../components/grids";
import { WeekCalendar } from "../components/WeekCalendar";
import { AgentEvent, useAgentFeed } from "../components/LiveFeed";
import { CloseButton, CountUp, Disclosure, Drawer, ErrorBlock, Field, Modal, PageSkeleton, Privacy, Ring, SearchInput, StatusChip, Stepper, Switch, useToast } from "../components/ui";
import { useWalker, walker } from "../lib/api";
import { ago, fmtHours, money, mondayOf, shiftWeek, slot, weekLabel } from "../lib/time";
import { useMe } from "../components/shell";

interface Approval { type: "draft" | "swap" | "recruit"; id: number; request_id?: number; agent: string; link: string; title: string; detail: string; risk: string; status?: string }
interface Dashboard {
  department: { name: string }; week: string; coverage: Coverage & { stats: any };
  kpis: { coverage_pct: number; filled: number; needed: number; open: number; hours: number; students: number; calendars: number; automation_pct: number };
  approvals: Approval[]; events: AgentEvent[]; policy: Record<string, boolean>; agents: { name: string; kind: string; role: string }[];
}

/* ---------------- approvals ---------------- */
const TYPE_ICON = { draft: CalendarCheck, swap: Repeat, recruit: UserPlus };

export function ApprovalItem({ a, onDone }: { a: Approval; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  const toast = useToast();
  const Icon = TYPE_ICON[a.type];
  const decide = async (approve: boolean) => {
    setBusy(true);
    try {
      const r = await walker<any>("decide", { type: a.type, id: a.id, approve });
      if (a.type === "draft" && approve) toast(`Published. ${r.notified ?? 0} ${r.notified === 1 ? "person" : "people"} notified.`);
      else if (a.type === "recruit" && approve) toast("Invite sent — their autopilot will answer.");
      else if (a.type === "swap" && approve) toast("Approved. Offers sent — autopilots answer instantly.");
      else toast("Done.");
      onDone();
      if (a.type === "swap" && approve) nav(a.link);
    } catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  const yes = a.type === "draft" ? "Approve & publish" : a.type === "recruit" ? "Invite" : "Approve";
  return (
    <div className="approval">
      <span className="ic"><Icon size={18} /></span>
      <div className="grow">
        <div className="row g8 wrap"><span className="title">{a.title}</span></div>
        <div className="detail">{a.detail}</div>
        <div className="feed-meta mt4"><span style={{ color: "#b9c1ff" }}>{a.agent}</span><span>· rules checked</span></div>
      </div>
      <div className="acts">
        {a.type === "recruit" ? <button className="btn sm ghost" disabled={busy} onClick={() => decide(false)}>Skip</button>
          : <button className="btn sm ghost" disabled={busy} onClick={() => nav(a.link)}>Review</button>}
        <button className="btn sm primary" disabled={busy} onClick={() => decide(true)}>{yes}</button>
      </div>
    </div>
  );
}

function ApprovalList({ items, onDone, limit }: { items: Approval[]; onDone: () => void; limit?: number }) {
  if (!items.length) return <div className="empty-state"><span className="icon-tile"><Check size={18} /></span><span>Nothing needs you. Autopilot has it.</span></div>;
  return <div className="stack g8">{items.slice(0, limit ?? 99).map((a) => <ApprovalItem key={`${a.type}-${a.id}`} a={a} onDone={onDone} />)}</div>;
}

/* ---------------- Dashboard ---------------- */
export function MissionControl() {
  const { data, error, loading, reload } = useWalker<Dashboard>("get_dashboard", {}, { poll: 4000 });
  const [active, setActive] = useState<string[]>([]);
  useAgentFeed(data?.events, 2500, setActive);
  const [cell, setCell] = useState<Cell | null>(null);
  const nav = useNavigate();
  if (loading && !data) return <PageSkeleton />;
  if (error || !data) return <ErrorBlock onRetry={reload} message={error ?? undefined} />;
  const k = data.kpis;
  return (
    <>
      <div className="dheader">
        <div className="stack g8">
          <span className="eyebrow">Dashboard · week of {weekLabel(data.week)}</span>
          <h1 className="t-page">{data.department.name}</h1>
        </div>
        <div className="actions"><span className="pill"><span className="live" />Autopilot on</span></div>
      </div>

      <div className="kpis big">
        <div className="card kpi">
          <span className="lbl">Coverage</span>
          <div className="row g12">
            <Ring value={k.filled} max={k.needed} size={76} stroke={7}><span className="w600" style={{ fontSize: 17 }}><CountUp value={k.coverage_pct} />%</span></Ring>
            <div className="stack"><span className="num nowrap" style={{ fontSize: 34 }}>{k.filled}<span className="ink-3" style={{ fontSize: 18 }}>/{k.needed}</span></span><span className="ink-3 t-small nowrap">slots filled</span></div>
          </div>
        </div>
        <button className="card kpi" style={{ textAlign: "left", cursor: "pointer" }} onClick={() => nav("/d/approvals")}>
          <span className="lbl row g8"><Inbox size={15} />Waiting for you</span>
          <span className={`num ${data.approvals.length ? "c-accent" : ""}`}><CountUp value={data.approvals.length} /></span>
          <span className="ink-3 t-small">{data.approvals.length ? "One tap each" : "All clear"}</span>
        </button>
        <div className="card kpi">
          <span className="lbl row g8"><Sparkles size={15} />Done by agents</span>
          <span className="num"><CountUp value={k.automation_pct} />%</span>
          <span className="ink-3 t-small">You only approved the rest</span>
        </div>
        <div className="card kpi">
          <span className="lbl">Hours scheduled</span>
          <span className="num"><CountUp value={k.hours} /></span>
          <span className="ink-3 t-small">{k.students} {k.students === 1 ? "person" : "people"} on the team</span>
        </div>
      </div>

      {k.students === 0 && <JoinCodeCard className="mt16" />}

      <div className="dash-row mt16">
        <section className="card">
          <div className="card-head"><h2 className="t-section row g8">Needs your approval{data.approvals.length > 0 && <span className="badge" style={{ marginLeft: 4 }}>{data.approvals.length}</span>}</h2>
            <Link to="/d/approvals" className="btn text sm">View all<ArrowRight size={14} /></Link></div>
          <ApprovalList items={data.approvals} onDone={() => reload(true)} limit={3} />
        </section>
        <section className="card network-card">
          <div className="card-head" style={{ marginBottom: 0 }}><h2 className="t-section">Agent network</h2>
            <span className="pill"><span className="live violet" />{active.length ? `${active.length} working` : "Standing by"}</span></div>
          <div className="orbit-wrap"><AgentOrbit active={active} compact /></div>
        </section>
      </div>

      <section className="card mt16">
        <div className="card-head"><h2 className="t-section">Schedule</h2><Link to="/d/schedule" className="btn text sm">Open schedule<ArrowRight size={14} /></Link></div>
        <WeekCalendar week={data.week} cells={data.coverage.cells} onCell={setCell} hourHeight={40} toolbar={false} />
      </section>
      {cell && <SlotDrawer week={data.week} cell={cell} onClose={() => setCell(null)} />}
    </>
  );
}

export function ApprovalsPage() {
  const { data, error, reload } = useWalker<{ items: Approval[] }>("get_approvals", {}, { poll: 3000 });
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  return (
    <>
      <div className="dheader"><div className="stack g8"><span className="eyebrow">Human in the loop</span><h1 className="t-page">Approvals</h1>
        <span className="ink-2">Every item was drafted by an agent and has already passed every hard rule. You decide.</span></div></div>
      <section className="card"><ApprovalList items={data.items} onDone={() => reload(true)} /></section>
    </>
  );
}

/* ---------------- slot drawer (copilot-powered, no forms) ---------------- */
function SlotDrawer({ week, cell, onClose }: { week: string; cell: Cell; onClose: () => void }) {
  const slotQ = useWalker<any>("get_slot", { week, day: cell.day, start: cell.start, end: cell.end, position_id: cell.position_id ?? null });
  const [res, setRes] = useState<CopilotResult | null>(null);
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  const label = slot(cell.day, cell.start, cell.end);
  const title = label + (cell.role ? ` · ${cell.role}` : "");
  const run = async (text: string) => {
    setBusy(true); setRes(null);
    try { setRes(await walker<CopilotResult>("copilot_command", { text, week })); slotQ.reload(true); } catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  return (
    <Drawer onClose={onClose} label="Slot">
      <div className="stack g20">
        <div className="row between"><div className="stack g4"><span className="eyebrow">Slot</span><h2 className="t-section">{title} · needs {cell.needed}</h2></div><CloseButton onClick={onClose} /></div>
        <div className="stack g8">
          <span className="label">On this shift</span>
          {slotQ.data?.people.length === 0 && <div className="ink-2">No one yet.</div>}
          <div className="divided">
            {slotQ.data?.people.map((p: any) => (
              <div key={p.student_id} className="list-row"><span className="grow">{p.name}</span>{p.pending && <StatusChip kind="wait">Swap pending</StatusChip>}<span className="ink-3 t-small">{fmtHours(p.hours_with_you)} hrs with you</span></div>
            ))}
          </div>
        </div>
        <div className="stack g8">
          <span className="label">Ask the agents</span>
          <div className="suggest">
            <button onClick={() => run(`Who can cover ${label.replace("–", " to ")}?`)}>Who can cover this?</button>
            <button onClick={() => run(`Need 1 more people ${label.replace("–", " to ")}`)}>Need one more here</button>
          </div>
        </div>
        {(busy || res) && <AgentPanel trace={res?.trace ?? null} pending={busy} title="copilot · agents" />}
        {res && <div className="reply w500">{res.reply}</div>}
        {res?.card && <CopilotCard card={res.card} onClose={onClose} onRun={run} />}
      </div>
    </Drawer>
  );
}

/* ---------------- Schedule ---------------- */
function useWeek(): [string | undefined, (w: string) => void] {
  const [params, setParams] = useSearchParams();
  return [params.get("week") || undefined, (w: string) => setParams({ week: w })];
}

export function SchedulePage() {
  const [weekParam, setWeek] = useWeek();
  const { data, error, reload } = useWalker<any>("get_coverage", weekParam ? { week: weekParam } : {}, { poll: 5000 });
  const [cell, setCell] = useState<Cell | null>(null);
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  const toast = useToast();
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  const week: string = data.week;
  const regen = async () => {
    setBusy(true);
    try { const d = await walker<any>("generate_schedule", { week }); nav(`/d/drafts/${d.draft_id}?replay=1`); } catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  const today = mondayOf();
  return (
    <>
      <div className="dheader">
        <div className="stack g8"><span className="eyebrow">Schedule</span><h1 className="t-page">Week of {weekLabel(week)}</h1></div>
        <div className="actions">
          <span className="pill"><b>{data.stats.filled}</b>/{data.stats.needed} filled</span>
          <button className="btn primary" disabled={busy || !data.has_needs} onClick={regen}><Sparkles size={15} />Re-plan with agents</button>
        </div>
      </div>
      {!data.has_needs ? <div className="card empty"><span>Tell the Needs Agent what a normal week looks like.</span><button className="btn primary" onClick={() => nav("/d/settings")}>Set up needs</button></div>
        : <section className="card"><WeekCalendar week={week} cells={data.cells} onCell={setCell} hourHeight={56}
                                                  onPrev={() => setWeek(shiftWeek(week, -1))} onNext={() => setWeek(shiftWeek(week, 1))} onToday={() => setWeek(today)} /></section>}
      {cell && <SlotDrawer week={week} cell={cell} onClose={() => { setCell(null); reload(true); }} />}
    </>
  );
}

/* ---------------- Draft review (agent replay) ---------------- */
export function DraftReview() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const [draft, setDraft] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);
  const [phase, setPhase] = useState<"replay" | "review">(params.get("replay") === "0" ? "review" : "replay");
  const [reveal, setReveal] = useState(0);
  const [current, setCurrent] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  const toast = useToast();
  const revealed = useRef(false);

  const load = async (did = id) => {
    try { setDraft(await walker<any>("get_draft", { draft_id: Number(did) })); } catch (e: any) { setError(e.message); }
  };
  useEffect(() => { revealed.current = false; setReveal(0); load(); }, [id]); // eslint-disable-line react-hooks/exhaustive-deps

  const schedIdx = useMemo(() => (draft?.trace ?? []).findIndex((r: TraceRow) => r.agent === "Scheduling Agent"), [draft]);
  const onProgress = (n: number) => {
    const row = draft?.trace?.[Math.max(0, n - 1)];
    if (row?.agent) setCurrent([row.agent, "Coordinator"]);
    if (!revealed.current && schedIdx >= 0 && n > schedIdx) {
      revealed.current = true;
      const total = draft.coverage.cells.length;
      let i = 0;
      const t = window.setInterval(() => { i += 2; setReveal(i); if (i >= total) window.clearInterval(t); }, 45);
    }
  };
  if (error) return <ErrorBlock message={error} />;
  if (!draft) return <PageSkeleton />;
  const s = draft.summary;
  const decided = draft.state !== "draft";

  const publish = async () => {
    setBusy(true);
    try { const r = await walker<any>("decide", { type: "draft", id: draft.draft_id, approve: true }); toast(`Schedule published. ${r.notified} ${r.notified === 1 ? "person" : "people"} notified.`); nav("/d"); }
    catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  const discard = async () => { await walker("decide", { type: "draft", id: draft.draft_id, approve: false }); nav("/d"); };
  const regen = async () => {
    setBusy(true);
    const d = await walker<any>("generate_schedule", { week: draft.week });
    setBusy(false); setPhase("replay"); nav(`/d/drafts/${d.draft_id}`);
  };

  if (phase === "replay") {
    return (
      <>
        <div className="dheader"><div className="stack g8"><span className="eyebrow">{draft.state === "draft" ? "Autopilot draft" : "Draft"} · replaying the agent run</span><h1 className="t-page">Building week of {weekLabel(draft.week)}…</h1></div>
          <button className="btn ghost sm" onClick={() => setPhase("review")}>Skip replay</button></div>
        <div className="two-col">
          <div className="stack g16">
            <div className="card" style={{ padding: 10 }}><AgentOrbit active={current} compact /></div>
            <AgentPanel trace={draft.trace} onProgress={onProgress} onDone={() => window.setTimeout(() => setPhase("review"), 700)} />
          </div>
          <section className="card"><WeekCalendar week={draft.week} cells={draft.coverage.cells} skeleton reveal={reveal} toolbar={false} hourHeight={44} /></section>
        </div>
      </>
    );
  }
  return (
    <>
      <div className="dheader">
        <div className="stack g8"><span className="eyebrow">{draft.state === "draft" ? "Waiting for your approval" : `Draft · ${draft.state}`}</span>
          <h1 className="t-page">Schedule ready. <span className="grad-text">{s.filled} of {s.needed}</span> slots filled.</h1>
          {s.open_seats > 0 && <span className="c-wait row g8"><Clock size={15} />{s.open_seats} {s.open_seats === 1 ? "slot needs" : "slots need"} attention — the Recruiting Agent is already on it.</span>}
        </div>
        <button className="btn ghost sm" onClick={() => { revealed.current = false; setReveal(0); setPhase("replay"); }}>Replay agent run</button>
      </div>
      <div className="stack g20">
        <section className="card"><WeekCalendar week={draft.week} cells={draft.coverage.cells} toolbar={false} hourHeight={44} /></section>
        {s.gaps.length > 0 && (
          <section className="card stack g12"><h2 className="t-section">Flagged, never hidden</h2>
            {s.gaps.map((g: any) => (
              <div key={g.label} className="approval" style={{ gridTemplateColumns: "40px 1fr" }}>
                <span className="ic" style={{ background: "var(--wait-bg)", borderColor: "rgba(255,200,87,.3)", color: "var(--wait)" }}><Clock size={18} /></span>
                <div><div className="title"><span className="mono" style={{ fontSize: 13 }}>{g.label}</span> · needs {g.needed}, found {g.found}</div><div className="detail">{g.reason} Recruiting Agent is searching campus.</div></div>
              </div>
            ))}
          </section>
        )}
        <section className="card"><h2 className="t-section">Why each person got what they got</h2>
          <div className="divided mt12">
            {s.students.map((st: any) => (
              <div key={st.student_id} className="list-row" style={{ alignItems: "flex-start" }}>
                <div className="grow stack g4"><span>{st.line}{st.new_shifts > 0 && <span className="chip accent" style={{ marginLeft: 8 }}>+{st.new_shifts} new</span>}</span>
                  <Disclosure summary="Why?"><span className="ink-2">{st.why}</span></Disclosure></div>
              </div>
            ))}
          </div>
        </section>
        <AgentPanel trace={draft.trace} replay={false} collapsible defaultCollapsed />
      </div>
      {!decided && (
        <div className="sticky-foot row g8 end wrap">
          <span className="ink-2 grow hide-mobile">Every assignment passed the Conflict Agent and Compliance Checker.</span>
          <button className="btn text" onClick={discard}>Discard</button>
          <button className="btn" disabled={busy} onClick={regen}>Regenerate</button>
          <button className="btn primary" disabled={busy} onClick={publish}>Approve &amp; publish</button>
        </div>
      )}
    </>
  );
}

/* ---------------- Swap approval ---------------- */
export function SwapApproval() {
  const { id } = useParams();
  const { data, error, reload, setData } = useWalker<any>("get_swap_request", { request_id: Number(id) }, { poll: 2500 });
  const seen = useRef<Set<number> | null>(null);
  const [replayed, setReplayed] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  if (seen.current === null) seen.current = new Set(data.loops.map((l: any) => l.loop_id));
  const act = async (name: "approve_swap" | "reject_swap", loopId: number) => {
    setBusy(true);
    try { setData(await walker<any>(name, { loop_id: loopId })); } catch (e: any) { toast(e.message, false); reload(true); }
    setBusy(false);
  };
  const loops: any[] = data.loops;
  const current = loops[loops.length - 1];
  const previous = loops.slice(0, -1);
  const lastDeclined = [...loops].reverse().find((l) => l.state === "declined");
  const isNew = current && !seen.current.has(current.loop_id);
  const showCurrent = current && (!isNew || replayed.has(current.loop_id));
  const replanning = lastDeclined && current && current.loop_id !== lastDeclined.loop_id && current.state === "proposed";
  return (
    <div className="stack g20" style={{ maxWidth: 980 }}>
      <Link to="/d/approvals" className="row g4 ink-2"><ChevronLeft size={16} />Approvals</Link>
      {data.reason && <div className="ink-2">Trigger: “{data.reason}”</div>}
      {lastDeclined && (current?.state === "proposed" || data.state === "searching") && (
        <div className="note wait"><Clock size={16} /><div>{lastDeclined.declined_by} declined{lastDeclined.decline_reason ? <> — “{lastDeclined.decline_reason.replace(/[.!\s]+$/, "")}.”</> : "."} {data.state === "searching" ? "No other option yet — the Swap Agent will retry when the week changes." : "The Swap Agent re-planned without them."}</div></div>
      )}
      {previous.map((l) => (
        <div key={l.loop_id} className="collapsed-line">{l.state === "declined" ? <X size={16} className="c-block" /> : <Clock size={16} />}Previous option · {l.headline.split(" · ")[0]} · {l.state === "declined" ? `declined by ${l.declined_by}` : l.state}</div>
      ))}
      {current && isNew && !replayed.has(current.loop_id) && <AgentPanel trace={current.trace} onDone={() => setReplayed((s) => new Set(s).add(current.loop_id))} title="swap agent · re-planning" />}
      {current && replanning && replayed.has(current.loop_id) && <AgentPanel trace={current.trace} replay={false} collapsible defaultCollapsed />}
      {current && showCurrent && <LoopCard loop={current} isNewOption={!!replanning || previous.some((p) => p.state === "declined")} busy={busy}
                                           onApprove={() => act("approve_swap", current.loop_id)} onReject={() => act("reject_swap", current.loop_id)} />}
      {!current && data.state === "searching" && <div className="card ink-2">No swap found yet. The Swap Agent will look again when the schedule changes.</div>}
    </div>
  );
}

function LoopCard({ loop, isNewOption, busy, onApprove, onReject }: { loop: any; isNewOption: boolean; busy: boolean; onApprove: () => void; onReject: () => void }) {
  const done = loop.state === "committed";
  const title = done ? `Swap complete. All ${loop.moves.length} schedules updated.` : `${isNewOption ? "New option · " : ""}${loop.headline}`;
  return (
    <section className={`card stack g24 slide-in ${done ? "" : "glow"}`} aria-label="Swap proposal">
      <div className="stack g4"><h1 className={`t-page row g8 ${done ? "c-ok" : ""}`}>{done && <Check size={26} />}{title}</h1><span className="ink-2">{loop.subline}</span></div>
      <div className="two-col" style={{ gridTemplateColumns: "1.2fr 1fr" }}>
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>Student</th><th>Gives up</th><th>Gets</th><th>Hrs with you</th></tr></thead>
            <tbody>{loop.moves.map((m: any) => (
              <tr key={m.student_id}><td className="w600">{m.name}</td><td className="mono">{m.gives ?? "—"}</td><td className="mono">{m.gets ?? "—"}</td>
                <td className="mono">{fmtHours(m.hrs_before)} → {fmtHours(m.hrs_after)} <Check size={12} className="c-ok" style={{ verticalAlign: -1 }} /></td></tr>
            ))}</tbody>
          </table>
        </div>
        {loop.kind !== "handoff" ? <LoopDiagram moves={loop.moves} /> : <div />}
      </div>
      <div className="row g16 wrap">{loop.checks.map((c: any) => <span key={c.label} className="row g6"><Check size={14} className="c-ok" />{c.label}<span className={`tag ${c.kind}`}>{c.kind === "rules" ? "code" : "AI"}</span></span>)}</div>
      <Disclosure summary="Why this swap?"><div className="stack g8 ink-2"><p>{loop.rationale}</p>
        {loop.alternatives.length > 0 && <p>Other options considered: {loop.alternatives.length}. {loop.alternatives[0].summary} — {loop.alternatives[0].why_lower}</p>}</div></Disclosure>
      {loop.state === "proposed" && (
        <div className="row g8 end hairline-top" style={{ paddingTop: 16 }}>
          <button className="btn" disabled={busy} onClick={onReject}>Reject</button>
          <button className="btn primary" disabled={busy} onClick={onApprove}>{isNewOption ? "Approve new swap" : "Approve"}</button>
        </div>
      )}
      {["approved", "committed", "declined"].includes(loop.state) && (
        <div className="stack hairline-top" style={{ paddingTop: 8 }}>
          {loop.participants.map((p: any) => (
            <div key={p.name} className="list-row">
              <span className="grow">{p.name}{p.auto === "carried" && <span className="ink-3 t-small"> · already agreed to this move</span>}{p.auto === "auto_accept" && <span className="ink-3 t-small"> · <Sparkles size={11} style={{ verticalAlign: -1 }} /> autopilot accepted</span>}</span>
              {p.state === "accepted" ? <StatusChip kind="ok">Accepted</StatusChip> : p.state === "declined" ? <StatusChip kind="block">Declined</StatusChip>
                : p.state === "waiting" ? <StatusChip kind="wait">Waiting</StatusChip> : <StatusChip kind="neutral">{p.state === "expired" ? "Expired" : "Cancelled"}</StatusChip>}
              <span className="ink-3 t-small" style={{ width: 64, textAlign: "right" }}>{p.seconds_ago != null ? ago(p.seconds_ago) : ""}</span>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

/* ---------------- Team & roles ---------------- */
interface Role { id: number; name: string; color: string; members?: number }
interface PersonRow {
  student_id: number; name: string; email: string; kind: "student" | "worker"; status: string; international: boolean; state: string;
  hours: number; pay_rate: number; positions: number[]; scheduled_with_you: number; can_still_schedule: number | null; calendar: boolean; autopilot: boolean; new: boolean;
}

export function JoinCodeCard({ className = "" }: { className?: string }) {
  const me = useMe();
  const toast = useToast();
  const code = me?.department?.join_code ?? "";
  const link = `${location.origin}/join/${code}`;
  const copy = async (text: string, what: string) => { try { await navigator.clipboard.writeText(text); toast(`${what} copied.`); } catch { toast(text); } };
  const share = async () => {
    const data = { title: `Join ${me?.department?.name} on CampusSync`, text: `Join ${me?.department?.name} on CampusSync with code ${code}`, url: link };
    if ((navigator as any).share) { try { await (navigator as any).share(data); } catch { /* cancelled */ } } else copy(link, "Invite link");
  };
  return (
    <section className={`card glow join-card ${className}`}>
      <div className="stack g4 grow">
        <span className="eyebrow">Join code</span>
        <span className="join-code-big mono">{code}</span>
        <span className="ink-2 t-small">Employees sign up with this code (or your invite link) and land on your team.</span>
      </div>
      <div className="row g8 wrap">
        <button className="btn sm" onClick={() => copy(code, "Join code")}><Copy size={14} />Copy code</button>
        <button className="btn sm primary" onClick={share}><Share2 size={14} />Share invite link</button>
      </div>
    </section>
  );
}

export function TeamPage() {
  const me = useMe();
  const { data, error, reload } = useWalker<{ people: PersonRow[]; positions: Role[]; join_code: string; kind: string }>("get_team", {}, { poll: 8000 });
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<PersonRow | null>(null);
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  const roles = new Map(data.positions.map((p) => [p.id, p]));
  const campus = me?.department?.kind === "campus";
  return (
    <>
      <div className="dheader"><div className="stack g8"><span className="eyebrow">Team & roles</span><h1 className="t-page">People</h1>
        <span className="ink-2">Give each person their roles, weekly hours and pay. The agents only schedule people into roles they hold.</span></div>
        {campus && <div className="actions"><button className="btn" onClick={() => setAdding(true)}><UserPlus size={15} />Invite a student</button></div>}</div>
      <JoinCodeCard />
      <RolesEditor key={data.people.map((p) => `${p.student_id}:${p.positions.join(".")}`).join("|")} className="mt16" onChange={() => reload(true)} />
      <div className="table-wrap mt16">
        <table className="table">
          <thead><tr><th>Name</th><th>Roles</th><th>Hours / week</th><th>Pay</th><th>With you this week</th><th>Can still schedule</th><th /></tr></thead>
          <tbody>{data.people.length === 0 && <tr><td colSpan={7} className="ink-2">No one yet — share your join code.</td></tr>}
            {data.people.map((p) => (
            <tr key={p.student_id}>
              <td><div className="row g8 wrap"><span className="w600">{p.name}</span>{p.new && <span className="chip accent">New</span>}{p.state === "invited" && <StatusChip kind="wait">Invited</StatusChip>}</div>
                <div className="t-small ink-3">{p.email}{p.kind === "student" ? ` · ${p.international ? "International student" : "Student"}` : ""}{p.calendar ? " · calendar synced" : ""}</div></td>
              <td><span className="row g4 wrap">{p.positions.length === 0 ? <span className="ink-3">{data.positions.length ? "No role yet" : "—"}</span>
                : p.positions.map((id) => roles.get(id)).filter(Boolean).map((r) => <span key={r!.id} className="chip role-chip"><i style={{ background: r!.color || "var(--accent)" }} />{r!.name}</span>)}</span></td>
              <td className="num">{p.hours}</td>
              <td className="num">{money(p.pay_rate)}/hr</td>
              <td className="num">{fmtHours(p.scheduled_with_you)} hrs</td>
              <td>{p.can_still_schedule === null ? <span className="ink-3">—</span> : p.can_still_schedule === 0
                ? <span className="row g4 c-block" title="Other commitments are private to the employee."><OctagonX size={14} />0 · at limit</span>
                : `${fmtHours(p.can_still_schedule)} hrs`}</td>
              <td><button className="btn sm ghost" onClick={() => setEditing(p)} aria-label={`Edit ${p.name}`}><Pencil size={14} />Edit</button></td>
            </tr>
          ))}</tbody>
        </table>
      </div>
      <Privacy className="mt16">You see whether people are free and how many hours you can still give them — never their classes or other jobs.</Privacy>
      {adding && <InviteModal onClose={() => setAdding(false)} onDone={() => { setAdding(false); reload(true); }} />}
      {editing && <MemberModal person={editing} roles={data.positions} onClose={() => setEditing(null)} onDone={() => { setEditing(null); reload(true); }} />}
    </>
  );
}

function MemberModal({ person, roles, onClose, onDone }: { person: PersonRow; roles: Role[]; onClose: () => void; onDone: () => void }) {
  const [picked, setPicked] = useState<number[]>(person.positions);
  const [hours, setHours] = useState(person.hours);
  const [rate, setRate] = useState(String(person.pay_rate.toFixed(2)));
  const [busy, setBusy] = useState(false);
  const [confirmRemove, setConfirmRemove] = useState(false);
  const toast = useToast();
  const save = async () => {
    setBusy(true);
    try { await walker("update_member", { student_id: person.student_id, positions: picked, hours, pay_rate: Number(rate) }); toast(`${person.name.split(" ")[0]} updated.`); onDone(); }
    catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  const remove = async () => {
    setBusy(true);
    try { const r = await walker<any>("remove_member", { student_id: person.student_id }); toast(`${person.name} removed.${r.released ? ` ${r.released} upcoming shift${r.released > 1 ? "s are" : " is"} open again.` : ""}`); onDone(); }
    catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  const cap = person.international ? 20 : 80;
  return (
    <Modal onClose={onClose} label={`Edit ${person.name}`}>
      <div className="stack g20">
        <div className="row between"><div className="stack g4"><h2 className="t-section">{person.name}</h2><span className="ink-3 t-small">{person.email}</span></div><CloseButton onClick={onClose} /></div>
        <div className="field"><span className="label">Roles</span>
          {roles.length === 0 ? <span className="ink-2 t-small">Add roles on the Team page first (e.g. Cashier, Site guard).</span> : (
            <div className="row g8 wrap">{roles.map((r) => (
              <button key={r.id} type="button" className="choice" aria-pressed={picked.includes(r.id)} onClick={() => setPicked(picked.includes(r.id) ? picked.filter((x) => x !== r.id) : [...picked, r.id])}>
                <i className="role-dot" style={{ background: r.color || "var(--accent)" }} />{r.name}</button>))}</div>
          )}</div>
        <div className="row between g16 wrap">
          <div className="field"><span className="label">Hours you can schedule per week</span><Stepper value={hours} min={0} max={cap} onChange={setHours} label="Hours per week" />
            {person.international && <span className="helper">International students: 20 hrs across all jobs, enforced automatically.</span>}</div>
          <div className="field"><label className="label" htmlFor="rate">Pay rate (USD / hour)</label>
            <div className="row g8"><span className="ink-2">$</span><input id="rate" className="input" type="number" inputMode="decimal" min={0} max={500} step="0.25" style={{ width: 120 }} value={rate} onChange={(e) => setRate(e.target.value)} /></div></div>
        </div>
        <div className="row between g8 wrap">
          {confirmRemove ? (
            <span className="row g8"><span className="c-block t-small">Remove {person.name.split(" ")[0]}? Upcoming shifts become open.</span><button className="btn sm danger-text" disabled={busy} onClick={remove}>Yes, remove</button><button className="btn sm text" onClick={() => setConfirmRemove(false)}>No</button></span>
          ) : <button className="btn text" style={{ color: "var(--block)" }} onClick={() => setConfirmRemove(true)}><UserMinus size={15} />Remove from team</button>}
          <div className="row g8"><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={busy || !(Number(rate) >= 0)} onClick={save}>Save</button></div>
        </div>
      </div>
    </Modal>
  );
}

function RolesEditor({ className = "", onChange }: { className?: string; onChange?: () => void }) {
  const { data, reload } = useWalker<{ positions: Role[] }>("get_org");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [renaming, setRenaming] = useState<{ id: number; name: string } | null>(null);
  const toast = useToast();
  if (!data) return null;
  const act = async (fn: () => Promise<any>, ok?: string) => {
    setBusy(true);
    try { await fn(); if (ok) toast(ok); reload(true); onChange?.(); } catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  return (
    <section className={`card stack g12 ${className}`}>
      <div className="row between wrap g8"><div className="stack g4"><h2 className="t-section">Roles</h2><span className="ink-2 t-small">Sub-jobs inside your organization. Staffing needs and shifts can require a role.</span></div></div>
      <div className="row g8 wrap">
        {data.positions.length === 0 && <span className="ink-3">No roles yet — everyone can take every shift.</span>}
        {data.positions.map((r) => renaming?.id === r.id ? (
          <span key={r.id} className="row g4"><input className="input" style={{ height: 34, width: 160 }} value={renaming.name} autoFocus onChange={(e) => setRenaming({ ...renaming, name: e.target.value })}
                                                     onKeyDown={(e) => { if (e.key === "Enter") act(() => walker("save_position", { id: r.id, name: renaming.name }), "Role renamed.").then(() => setRenaming(null)); if (e.key === "Escape") setRenaming(null); }} aria-label="Role name" />
            <button className="btn sm" disabled={busy} onClick={() => act(() => walker("save_position", { id: r.id, name: renaming.name }), "Role renamed.").then(() => setRenaming(null))}>Save</button></span>
        ) : (
          <span key={r.id} className="chip role-chip lg"><i style={{ background: r.color || "var(--accent)" }} />{r.name}<span className="ink-3">· {r.members ?? 0}</span>
            <button aria-label={`Rename ${r.name}`} onClick={() => setRenaming({ id: r.id, name: r.name })}><Pencil size={12} /></button>
            <button aria-label={`Delete ${r.name}`} disabled={busy} onClick={() => act(() => walker("delete_position", { id: r.id }), `${r.name} removed.`)}><Trash2 size={12} /></button></span>
        ))}
      </div>
      <form className="row g8" onSubmit={(e) => { e.preventDefault(); if (name.trim()) act(() => walker("save_position", { name }), "Role added.").then(() => setName("")); }}>
        <input className="input" placeholder="New role, e.g. Night patrol" value={name} onChange={(e) => setName(e.target.value)} maxLength={80} aria-label="New role" />
        <button className="btn" disabled={busy || name.trim().length < 2}><Plus size={15} />Add role</button>
      </form>
    </section>
  );
}

function InviteModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [q, setQ] = useState("");
  const [results, setResults] = useState<any[]>([]);
  const [pick, setPick] = useState<any>(null);
  const [hours, setHours] = useState(10);
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  useEffect(() => {
    const t = window.setTimeout(async () => { try { setResults((await walker<any>("search_students", { query: q })).results); } catch { /* empty */ } }, 200);
    return () => window.clearTimeout(t);
  }, [q]);
  const send = async () => {
    setBusy(true);
    try { await walker("invite_student", { student_id: pick.student_id, hours }); await walker("run_autopilot"); toast(`Invite sent to ${pick.name}.`); onDone(); }
    catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  return (
    <Modal onClose={onClose} label="Invite a student" wide>
      <div className="stack g16">
        <div className="row between"><h2 className="t-section">Invite a student from your university</h2><CloseButton onClick={onClose} /></div>
        <SearchInput placeholder="Search by name, email, or student ID" value={q} onChange={(e) => { setQ(e.target.value); setPick(null); }} autoFocus aria-label="Search students" />
        <div className="divided" style={{ maxHeight: 300, overflow: "auto" }}>
          {results.length === 0 && <div className="list-row ink-3">No students found. Anyone can also join with your join code.</div>}
          {results.map((r) => (
            <button key={r.student_id} className="list-row" onClick={() => setPick(r)}
                    style={{ width: "100%", border: 0, background: pick?.student_id === r.student_id ? "var(--glass-2)" : "transparent", cursor: "pointer", textAlign: "left", padding: "12px 8px", borderRadius: 4 }}>
              <span className="grow stack"><span className="row g8"><span className="w600">{r.name}</span>{r.team_state === "active" && <span className="chip">On your team</span>}{r.team_state === "invited" && <StatusChip kind="wait">Invited</StatusChip>}</span><span className="t-small ink-3">{r.email}</span></span>
              <span className="ink-2 t-small">Can take up to {fmtHours(r.can_take_more_hrs)} more hrs</span>
            </button>
          ))}
        </div>
        {pick && <div className="row between"><span className="label">Hours per week</span><Stepper value={hours} min={1} max={40} onChange={setHours} label="Hours per week" /></div>}
        <Privacy>You'll only see whether this student is free. Their classes and other jobs stay private.</Privacy>
        <div className="row end"><button className="btn primary" disabled={!pick || busy} onClick={send}>Send invite</button></div>
      </div>
    </Modal>
  );
}

/* ---------------- Settings ---------------- */
const TIMEZONES = ["America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu",
  "Europe/London", "Europe/Berlin", "Asia/Kolkata", "Asia/Singapore", "Australia/Sydney"];

export function SettingsPage() {
  const org = useWalker<any>("get_org");
  const needsQ = useWalker<{ needs: Need[] }>("get_staffing_needs");
  const [policy, setPolicy] = useState<Record<string, boolean> | null>(null);
  const [needs, setNeeds] = useState<Need[] | null>(null);
  const [f, setF] = useState<any>(null);
  const [desc, setDesc] = useState("");
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  useEffect(() => {
    if (!org.data) return;
    setPolicy(org.data.policy);
    setF({ name: org.data.name, timezone: org.data.timezone, default_pay_rate: String(org.data.default_pay_rate), default_weekly_hours: org.data.default_weekly_hours,
           state_tax_pct: String(org.data.state_tax_pct), apply_to_team: false });
  }, [org.data]);
  useEffect(() => { if (needsQ.data) setNeeds(needsQ.data.needs); }, [needsQ.data]);
  if (!policy || !needs || !f || !org.data) return <PageSkeleton />;
  const roles: Role[] = org.data.positions;
  const toggle = async (k: string, v: boolean) => { setPolicy({ ...policy, [k]: v }); await walker("set_policy", { [k]: v }); toast("Autopilot policy saved."); };
  const saveOrg = async () => {
    setBusy(true);
    try { await walker("update_org", { ...f, default_pay_rate: Number(f.default_pay_rate), state_tax_pct: Number(f.state_tax_pct) }); toast("Settings saved."); org.reload(true); }
    catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  const newCode = async () => { setBusy(true); try { const r = await walker<any>("regenerate_join_code"); toast(`New join code: ${r.join_code}. The old one no longer works.`); org.reload(true); } catch (e: any) { toast(e.message, false); } setBusy(false); };
  const rebuild = async () => {
    setBusy(true);
    try { const r = await walker<any>("generate_needs", { description: desc }); setNeeds(r.needs); toast(r.summary); } catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  const save = async () => { setBusy(true); try { await walker("set_staffing_needs", { needs }); await walker("run_autopilot"); toast("Needs saved. Autopilot is re-planning."); } catch (e: any) { toast(e.message, false); } setBusy(false); };
  const rows: [string, string, string][] = [
    ["auto_generate", "Draft every week automatically", "The Scheduling Agent drafts the upcoming week whenever slots are open. You approve before anything is published."],
    ...(org.data.kind === "campus" ? [["auto_recruit", "Recruit for gaps from your university", "When no one on your team can cover a slot, the Recruiting Agent proposes free students. You approve each invite."] as [string, string, string]] : []),
    ["auto_approve_swaps", "Auto-approve low-risk swaps", "Swaps where every hour and every slot stay covered skip your approval. Hand-offs always come to you."],
  ];
  return (
    <>
      <div className="dheader"><div className="stack g8"><span className="eyebrow">Settings</span><h1 className="t-page">{org.data.name}</h1>
        <span className="ink-2">{org.data.kind === "campus" ? `Campus employer · ${org.data.university}` : "Business"} · join code <span className="mono">{org.data.join_code}</span></span></div></div>
      <div className="stack g20" style={{ maxWidth: 880 }}>
        <section className="card stack g16">
          <h2 className="t-section">Organization & pay</h2>
          <div className="form-grid">
            <Field label="Organization name" htmlFor="oname"><input id="oname" className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
            <Field label="Time zone" htmlFor="tz" helper="Shift reminders and Friday alerts use it.">
              <select id="tz" className="select" value={f.timezone} onChange={(e) => setF({ ...f, timezone: e.target.value })}>
                {[...new Set([f.timezone, ...TIMEZONES])].map((z) => <option key={z} value={z}>{z.replace("_", " ")}</option>)}</select></Field>
            <Field label="Default pay rate (USD / hour)" htmlFor="rate" helper="New people start here. Change individuals on the Team page.">
              <input id="rate" className="input" type="number" min={0} max={500} step="0.25" value={f.default_pay_rate} onChange={(e) => setF({ ...f, default_pay_rate: e.target.value })} /></Field>
            <Field label="Default hours per person per week" htmlFor="dh"><input id="dh" className="input" type="number" min={1} max={80} value={f.default_weekly_hours} onChange={(e) => setF({ ...f, default_weekly_hours: Number(e.target.value) })} /></Field>
            <Field label="State income tax (%)" htmlFor="st" helper="Used for employees' take-home estimates."><input id="st" className="input" type="number" min={0} max={15} step="0.05" value={f.state_tax_pct} onChange={(e) => setF({ ...f, state_tax_pct: e.target.value })} /></Field>
          </div>
          <label className="row g8 ink-2" style={{ cursor: "pointer" }}><input type="checkbox" checked={f.apply_to_team} onChange={(e) => setF({ ...f, apply_to_team: e.target.checked })} />Also set everyone on the team to the default pay rate</label>
          <div className="row between g8 wrap"><button className="btn text" disabled={busy} onClick={newCode}>Get a new join code</button><button className="btn primary" disabled={busy} onClick={saveOrg}>Save settings</button></div>
        </section>
        <section className="card divided">
          <h2 className="t-section" style={{ paddingBottom: 8 }}>Autopilot</h2>
          {rows.map(([k, t, d]) => (
            <div key={k} className="list-row" style={{ alignItems: "flex-start", padding: "16px 0" }}>
              <div className="grow stack g4"><span className="w600">{t}</span><span className="ink-2">{d}</span></div>
              <Switch checked={!!policy[k]} onChange={(v) => toggle(k, v)} label={t} />
            </div>
          ))}
        </section>
        <section className="card stack g16">
          <div className="stack g4"><h2 className="t-section">Staffing plan</h2><span className="ink-2">Describe changes in words, or adjust blocks by hand. Pick a role for blocks that need one.</span></div>
          <div className="row g8"><input className="input" placeholder="Describe a normal week, e.g. Café open 7am to 7pm weekdays, busiest at lunch" value={desc} onChange={(e) => setDesc(e.target.value)} />
            <button className="btn" disabled={!desc || busy} onClick={rebuild}><Sparkles size={15} />Rebuild plan</button></div>
          <Disclosure summary={`Edit ${needs.length} blocks by hand`}><NeedsEditor needs={needs} onChange={setNeeds} roles={roles} /></Disclosure>
          <div className="row end"><button className="btn primary" disabled={busy} onClick={save}>Save plan</button></div>
        </section>
        <section className="card"><NotificationSettings employer /></section>
      </div>
    </>
  );
}
