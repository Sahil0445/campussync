import { FormEvent, useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { ArrowRight, BriefcaseBusiness, CalendarCheck, Check, ChevronRight, Clock, LogOut, OctagonX, Plus, RefreshCw, Send, Sparkles } from "lucide-react";
import { WorkAnalytics } from "../components/Analytics";
import { NotificationSettings } from "../components/Notifications";
import { AgentPanel, TraceRow } from "../components/AgentPanel";
import { CalendarConnect } from "../components/CalendarConnect";
import { CopilotCard } from "../components/CommandBar";
import { AvailabilityNotes } from "../components/editors";
import { LoopDiagram } from "../components/grids";
import { signOut, useMe } from "../components/shell";
import { Disclosure, ErrorBlock, Modal, Note, PageSkeleton, Privacy, StatusChip, Switch, useToast } from "../components/ui";
import { useWalker, walker } from "../lib/api";
import { ago, countdown, dateLabel, DAYS, DAYS_LONG, fmtHours, greeting, money, range, range12, relTime, weekLabel } from "../lib/time";

interface Home {
  student: { name: string; first_name: string; status: string; autopilot: boolean; kind: "student" | "worker"; international: boolean };
  calendar: { connected: boolean; label: string; synced_seconds_ago: number | null; error: string };
  week: string;
  hours: { scheduled: number; limit: number; left: number; by_job: { department: string; hours: number }[] };
  pay: { projected_gross: number };
  jobs: { department_id: number; department: string; hours: number; state: string; pay_rate: number; roles: string[] }[];
  invites: { employment_id: number; department: string; hours: number; total_assigned: number; limit: number }[];
  offers: { offer_id: number; expires_in_seconds: number }[];
  requests: { request_id: number; state: string }[];
  shifts: { id: number; day: number; date: string; start: number; end: number; department: string; role: string; state: string; hours: number; worked: boolean }[];
  next_shift: { id: number; date: string; day: number; start: number; end: number; department: string; role: string; starts_in_seconds: number; in_progress: boolean } | null;
  timesheet: { pending_count: number; pending_hours: number; next_review: string; review_today: boolean; disputed_count: number };
}
const SHADES = ["#a18bff", "#3dd8f5", "#6c8cff"];

function PageTitle({ eyebrow, title, sub }: { eyebrow?: string; title: string; sub?: string }) {
  return <div className="stack g4">{eyebrow && <span className="eyebrow">{eyebrow}</span>}<h1 className="t-page">{title}</h1>{sub && <span className="ink-2">{sub}</span>}</div>;
}

/* ---------------- Dashboard ---------------- */
export function StudentHome() {
  const { data, error, loading, reload } = useWalker<Home>("get_student_home", {}, { poll: 5000 });
  const [params] = useSearchParams();
  const toast = useToast();
  const nav = useNavigate();
  useEffect(() => { if (params.get("calendar") === "connected") toast("Google Calendar connected."); }, [params, toast]);
  if (loading && !data) return <PageSkeleton />;
  if (error || !data) return <ErrorBlock onRetry={reload} message={error ?? undefined} />;
  const h = data.hours;
  const atLimit = h.scheduled >= h.limit && data.student.international;
  const needs = data.offers.length + data.invites.length;
  const ns = data.next_shift;
  const ts = data.timesheet;
  return (
    <div className="stack g20">
      <PageTitle eyebrow={`Week of ${weekLabel(data.week)}`} title={`${greeting()}, ${data.student.first_name}`} />

      {ns && (
        <section className={`card next-shift ${ns.in_progress ? "live" : ""}`}>
          <span className="eyebrow">{ns.in_progress ? "On shift now" : "Next shift"}</span>
          <div className="when-big">{dateLabel(ns.date, { weekday: "long", month: "short", day: "numeric" })}</div>
          <div className="row between g8 wrap">
            <span className="w500">{range12(ns.start, ns.end)} · {ns.department}{ns.role ? ` · ${ns.role}` : ""}</span>
            {!ns.in_progress && <span className="chip accent">{relTime(ns.starts_in_seconds)}</span>}
          </div>
        </section>
      )}

      {ts.pending_count > 0 && (
        <button className={`note ${ts.review_today ? "wait" : "neutral"} row between`} style={{ cursor: "pointer", width: "100%", textAlign: "left", alignItems: "center" }} onClick={() => nav("/s/time")}>
          <span className="row g8"><CalendarCheck size={16} />{ts.review_today ? "Friday check: " : ""}{fmtHours(ts.pending_hours)} reported hrs to approve</span><ChevronRight size={16} />
        </button>
      )}
      {needs > 0 && (
        <button className="note wait row between" style={{ cursor: "pointer", width: "100%", textAlign: "left", alignItems: "center" }} onClick={() => nav("/s/requests")}>
          <span className="row g8"><Clock size={16} />{needs} request{needs > 1 ? "s need" : " needs"} your answer</span><ChevronRight size={16} />
        </button>
      )}
      {data.requests.map((r) => (
        <Link key={r.request_id} to={`/s/request?id=${r.request_id}`} className="collapsed-line">
          <Sparkles size={15} className="c-accent" /><span className="grow">AI is handling a change · {r.state === "searching" ? "still searching" : r.state === "offered" ? "waiting on the others" : "waiting for your manager"}</span><ChevronRight size={15} />
        </Link>
      ))}

      <section className="card stack g16">
        <span className="mono ink-2">This week</span>
        <div className="row g8" style={{ alignItems: "baseline" }}>
          <span className="hero-num">{fmtHours(h.scheduled)}{data.student.international ? ` / ${h.limit}` : ""}</span>
          <span className="ink-2" style={{ fontSize: 16 }}>hrs scheduled</span>
        </div>
        <div className="seg-bar" role="img" aria-label={`${h.scheduled} of ${h.limit} hours scheduled`}>
          {h.by_job.map((j, i) => <span key={j.department} style={{ width: `${(j.hours / Math.max(h.limit, h.scheduled, 1)) * 100}%`, background: SHADES[i % 3] }} />)}
        </div>
        {h.by_job.length > 1 && (
          <div className="row g16 wrap legend-sq ink-2" style={{ fontSize: 14 }}>
            {h.by_job.map((j, i) => <span key={j.department}><i style={{ background: SHADES[i % 3] }} />{j.department} {fmtHours(j.hours)}</span>)}
          </div>
        )}
        <div className="row between wrap g8">
          {atLimit ? <span className="row g8 c-block" style={{ fontSize: 14 }}><OctagonX size={16} />At your 20 hr international limit.</span>
            : <span className="ink-2" style={{ fontSize: 14 }}>{data.student.international ? `International limit · ${fmtHours(h.left)} hrs left` : `${data.shifts.length} shift${data.shifts.length === 1 ? "" : "s"}`}</span>}
          {data.pay.projected_gross > 0 && <span className="ink-2" style={{ fontSize: 14 }}>≈ {money(data.pay.projected_gross, false)} gross</span>}
        </div>
      </section>

      <section className="stack g12">
        <h2 className="t-section">This week</h2>
        {data.shifts.length === 0 ? <div className="card ink-2">No shifts this week yet. Your employer's schedule shows up here once it's published.</div> : (
          <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
            {data.shifts.map((s) => (
              <div key={s.id} className="shift-row">
                <div className="grow"><div className="when"><span className="nowrap">{DAYS[s.day]} {dateLabel(s.date, { month: "short", day: "numeric" })}</span> <span className="nowrap">· {range(s.start, s.end)}</span></div>
                  <div className="where">{s.department}{s.role ? ` · ${s.role}` : ""}</div></div>
                {s.worked ? <StatusChip kind="neutral">Worked</StatusChip> : s.state === "pending_swap" ? <StatusChip kind="wait">Swap pending</StatusChip> : <StatusChip kind="ok">Confirmed</StatusChip>}
              </div>
            ))}
          </div>
        )}
      </section>

      <div className="two-btn">
        <button className="btn primary lg" onClick={() => nav("/s/request/new")} disabled={!data.shifts.some((s) => !s.worked)}>Request a change</button>
        <button className="btn lg" onClick={() => nav("/s/availability")}>Availability</button>
      </div>
      <OpenShifts onTaken={() => reload(true)} />

      <section className="stack g12">
        <h2 className="t-section">Your jobs</h2>
        <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
          {data.jobs.length === 0 && <div className="shift-row ink-2">No jobs yet. Join an employer from your profile with their join code.</div>}
          {data.jobs.map((j) => (
            <div key={j.department_id} className="shift-row">
              <div className="grow"><div style={{ fontSize: 16, fontWeight: 500 }}>{j.department}</div>
                <div className="where">{j.roles.length ? `${j.roles.join(", ")} · ` : ""}{money(j.pay_rate)}/hr</div></div>
              <span className="chip">Active</span>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function OpenShifts({ onTaken }: { onTaken: () => void }) {
  const { data, reload } = useWalker<{ shifts: { id: number; day: number; start: number; end: number; department: string }[] }>("get_open_shifts", {}, { poll: 8000 });
  const toast = useToast();
  if (!data?.shifts.length) return null;
  const take = async (id: number) => {
    try { await walker("claim_open_shift", { shift_id: id }); toast("It's yours."); reload(true); onTaken(); } catch (e: any) { toast(e.message, false); reload(true); }
  };
  return (
    <section className="stack g12"><h2 className="t-section">Open shifts you can take</h2>
      <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>{data.shifts.map((s) => (
        <div key={s.id} className="shift-row"><div className="grow"><div className="when">{DAYS[s.day]} {range(s.start, s.end)}</div><div className="where">{s.department}</div></div>
          <button className="btn sm" onClick={() => take(s.id)}>Take it</button></div>
      ))}</div>
    </section>
  );
}

/* ---------------- Campus AI ---------------- */
interface Msg { id: number; me: boolean; text: string; trace?: TraceRow[]; card?: any }
const EXAMPLES = ["I can't do Saturday, Wednesday works", "Dentist Friday 2 to 4", "How many hours do I have left?", "Swap my Tuesday shift for Thursday"];

export function CampusAI() {
  const home = useWalker<Home>("get_student_home", {}, { poll: 6000 });
  const avail = useWalker<any>("get_availability");
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [syncing, setSyncing] = useState(false);
  const end = useRef<HTMLDivElement>(null);
  const toast = useToast();
  useEffect(() => { end.current?.scrollIntoView({ behavior: "smooth", block: "end" }); }, [msgs, busy]);
  const d = home.data;
  const autopilot = avail.data?.profile?.autopilot ?? d?.student.autopilot ?? true;

  const send = async (t: string) => {
    if (!t.trim() || busy) return;
    setMsgs((m) => [...m, { id: Date.now(), me: true, text: t }]); setText(""); setBusy(true);
    try {
      const r = await walker<any>("student_command", { text: t });
      setMsgs((m) => [...m, { id: Date.now() + 1, me: false, text: r.reply, trace: r.trace, card: r.card }]);
      home.reload(true);
    } catch (e: any) { setMsgs((m) => [...m, { id: Date.now() + 1, me: false, text: e.message }]); }
    setBusy(false);
  };
  const submit = (e: FormEvent) => { e.preventDefault(); send(text); };
  const setAuto = async (v: boolean) => { await walker("update_profile", { autopilot: v }); avail.reload(true); toast(v ? "Autopilot is on." : "Autopilot is off — you'll be asked about every change."); };
  const sync = async () => { setSyncing(true); try { await walker("sync_calendar"); toast("Calendar synced."); home.reload(true); } catch (e: any) { toast(e.message, false); } setSyncing(false); };

  return (
    <div className="stack g16">
      <PageTitle eyebrow={useMe()?.student?.kind === "worker" ? "Assistant" : "Campus AI"} title="Your scheduling assistant" />
      <section className="card stack g12">
        <div className="row g12">
          <span className="icon-tile"><Sparkles size={18} /></span>
          <div className="grow stack"><span className="w600">Autopilot</span><span className="ink-2 t-small">{autopilot ? "Handling swaps and invites that fit your preferences" : "Off — you'll be asked about every change"}</span></div>
          <Switch checked={autopilot} onChange={setAuto} label="Autopilot" />
        </div>
        <div className="row g12 hairline-top" style={{ paddingTop: 12 }}>
          <span className="grow ink-2 t-small">{d?.calendar.connected ? `${d.calendar.label} · synced ${d.calendar.synced_seconds_ago != null ? ago(d.calendar.synced_seconds_ago) : "just now"}` : "No calendar connected"}</span>
          {d?.calendar.connected ? <button className="btn sm" disabled={syncing} onClick={sync}><RefreshCw size={14} />Sync</button> : <Link to="/s/availability" className="btn sm primary">Connect</Link>}
        </div>
      </section>

      <div className="chat">
        {msgs.length === 0 && (
          <div className="bubble ai">Hi {d?.student.first_name ?? "there"} — tell me what changed and I'll handle it. I check every job's limits before anything moves, and your manager approves.</div>
        )}
        {msgs.map((m) => m.me ? <div key={m.id} className="bubble me">{m.text}</div> : (
          <div key={m.id} className="stack g8" style={{ alignSelf: "stretch" }}>
            <div className="bubble ai">{m.text}</div>
            {m.trace && m.trace.length > 1 && <Disclosure summary="How I did it"><AgentPanel trace={m.trace} replay={false} title="agents" /></Disclosure>}
            {m.card && <CopilotCard card={m.card} />}
          </div>
        ))}
        {busy && <AgentPanel trace={null} pending title="agents · working" />}
        <div ref={end} />
      </div>

      <div className="composer stack g8">
        {msgs.length === 0 && <div className="suggest">{EXAMPLES.map((x) => <button key={x} onClick={() => send(x)}>{x}</button>)}</div>}
        <form onSubmit={submit} className="row g8">
          <input className="input" placeholder="Tell Campus AI what changed…" value={text} onChange={(e) => setText(e.target.value)} aria-label="Message Campus AI" />
          <button className="btn primary icon" aria-label="Send" disabled={busy || !text.trim()}><Send size={16} /></button>
        </form>
      </div>
    </div>
  );
}

/* ---------------- Requests ---------------- */
interface Inbox {
  offers: { offer_id: number; state: string; auto: string; loop_state: string; size: number; kind: string; department: string; gets: string | null; gives: string | null; seconds_ago: number; expires_in_seconds: number }[];
  invites: { employment_id: number; department: string; hours: number }[];
  requests: any[];
}

export function StudentRequests() {
  const { data, error, reload } = useWalker<Inbox>("get_student_inbox", {}, { poll: 4000 });
  const [invite, setInvite] = useState<Inbox["invites"][number] | null>(null);
  const nav = useNavigate();
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  const open = data.offers.filter((o) => o.state === "waiting" && o.loop_state === "approved");
  const past = data.offers.filter((o) => !(o.state === "waiting" && o.loop_state === "approved"));
  const what = (o: Inbox["offers"][number]) => o.gets && o.gives ? `Take ${o.gets}, give up ${o.gives}` : o.gets ? `Take ${o.gets}` : `Hand off ${o.gives}`;
  const pastChip = (o: Inbox["offers"][number]) => o.loop_state === "committed" ? <StatusChip kind="ok">Confirmed</StatusChip>
    : o.state === "accepted" ? <StatusChip kind="wait">{o.auto ? "Autopilot said yes" : "You said yes"}</StatusChip>
    : o.state === "declined" ? <StatusChip kind="block">Declined</StatusChip> : <StatusChip kind="neutral">Closed</StatusChip>;
  return (
    <div className="stack g20">
      <PageTitle eyebrow="Requests" title="Requests" sub="Swaps and job offers that need you, and the changes you asked for." />

      <section className="stack g12">
        <h2 className="t-section">Needs your answer</h2>
        {open.length + data.invites.length === 0 ? <div className="card ink-2 row g8"><Check size={16} className="c-ok" />Nothing needs you right now.</div> : (
          <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
            {open.map((o) => (
              <button key={o.offer_id} className="shift-row" style={{ width: "100%", background: "transparent", border: 0, cursor: "pointer", textAlign: "left", color: "inherit" }} onClick={() => nav(`/s/offer/${o.offer_id}`)}>
                <div className="grow"><div className="w600">Swap offer · {o.size}-person {o.kind === "handoff" ? "hand-off" : "loop"}</div><div className="where">{what(o)} · {o.department}</div>
                  <div className="mono ink-3 mt4">Expires in {countdown(o.expires_in_seconds)}</div></div>
                <span className="btn sm primary">Review</span>
              </button>
            ))}
            {data.invites.map((i) => (
              <div key={i.employment_id} className="shift-row">
                <div className="grow"><div className="w600">Job offer · {i.department}</div><div className="where">{i.hours} hrs/week</div></div>
                <button className="btn sm primary" onClick={() => setInvite(i)}>Review</button>
              </div>
            ))}
          </div>
        )}
      </section>

      <section className="stack g12">
        <h2 className="t-section">Your requests</h2>
        {data.requests.length === 0 ? <div className="card ink-2">No requests yet. Use <b>Request a change</b> on your dashboard, or just tell Campus AI.</div> : (
          <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
            {data.requests.map((r: any) => (
              <Link key={r.request_id} to={`/s/request?id=${r.request_id}`} className="shift-row" style={{ color: "inherit" }}>
                <div className="grow"><div className="when" style={{ fontSize: 14 }}>{r.shift}</div><div className="where">{r.origin === "calendar" ? "From your calendar" : "Looking for"}: {r.want}</div></div>
                {r.chip === "waiting" ? <StatusChip kind="wait">Waiting</StatusChip> : r.chip === "confirmed" ? <StatusChip kind="ok">Done</StatusChip>
                  : r.chip === "blocked" ? <StatusChip kind="block">Not approved</StatusChip> : <StatusChip kind="neutral">{r.state === "cancelled" ? "Cancelled" : "Searching"}</StatusChip>}
              </Link>
            ))}
          </div>
        )}
      </section>

      {past.length > 0 && (
        <section className="stack g12">
          <h2 className="t-section">History</h2>
          <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
            {past.map((o) => (
              <Link key={o.offer_id} to={`/s/offer/${o.offer_id}`} className="shift-row" style={{ color: "inherit" }}>
                <div className="grow"><div style={{ fontSize: 14 }}>{what(o)}</div><div className="where">{o.department} · {ago(o.seconds_ago)}</div></div>{pastChip(o)}
              </Link>
            ))}
          </div>
        </section>
      )}
      {invite && <InviteModal invite={invite} onClose={() => setInvite(null)} onDone={() => { setInvite(null); reload(true); }} />}
    </div>
  );
}

function InviteModal({ invite, onClose, onDone }: { invite: { employment_id: number; department: string; hours: number }; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const respond = async (accept: boolean) => {
    setBusy(true);
    try { const r = await walker<any>("respond_invite", { employment_id: invite.employment_id, accept }); toast(accept ? `You've joined ${r.department}.` : "Invite declined."); onDone(); }
    catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  return (
    <Modal onClose={onClose} label="Job offer" sheet>
      <div className="stack g16">
        <h2 className="t-section">{invite.department} wants to add you</h2>
        <div className="t-display c-accent">{invite.hours} hours a week</div>
        <p className="ink-2">They'll be able to schedule you for up to {invite.hours} hours a week — never over your weekly limit.</p>
        <Privacy>They won't see your classes or your other jobs — only whether you're free.</Privacy>
        <div className="row g8 end mt8"><button className="btn" disabled={busy} onClick={() => respond(false)}>Decline</button><button className="btn primary" disabled={busy} onClick={() => respond(true)}>Accept</button></div>
      </div>
    </Modal>
  );
}

/* ---------------- Request a change (3 taps) ---------------- */
export function RequestChange() {
  const home = useWalker<Home>("get_student_home");
  const [step, setStep] = useState(1);
  const [shift, setShift] = useState<Home["shifts"][number] | null>(null);
  const [want, setWant] = useState<"days" | "any" | "give_up">("days");
  const [days, setDays] = useState<number[]>([]);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  const toast = useToast();
  if (!home.data) return <PageSkeleton />;
  const shifts = home.data.shifts.filter((s) => s.state !== "pending_swap");
  const send = async () => {
    if (!shift) return;
    setBusy(true);
    try { const r = await walker<any>("request_swap", { shift_id: shift.id, want_kind: want, want_days: days, reason }); nav(`/s/request?id=${r.request_id}`, { replace: true }); }
    catch (e: any) { toast(e.message, false); setBusy(false); }
  };
  const toggle = (i: number) => setDays(days.includes(i) ? days.filter((x) => x !== i) : [...days, i]);
  return (
    <div className="stack g20">
      <div className="row between"><span className="progress-text">{step} of 3</span>
        {step > 1 ? <button className="btn text sm" onClick={() => setStep(step - 1)}>Back</button> : <Link to="/s" className="btn text sm">Cancel</Link>}</div>
      {step === 1 && (
        <>
          <h1 className="t-page">Which shift?</h1>
          <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
            {shifts.length === 0 && <div className="shift-row ink-2">No shifts you can change this week.</div>}
            {shifts.map((s) => (
              <button key={s.id} className="shift-row" style={{ width: "100%", background: "transparent", border: 0, cursor: "pointer", textAlign: "left", color: "inherit" }} onClick={() => { setShift(s); setStep(2); }}>
                <div className="grow"><div className="when">{DAYS[s.day]} {range(s.start, s.end)}</div><div className="where">{s.department}</div></div><ChevronRight size={16} className="ink-3" />
              </button>
            ))}
          </div>
        </>
      )}
      {step === 2 && (
        <>
          <h1 className="t-page">What would you like instead?</h1>
          <div className="stack g8" role="radiogroup">
            <button type="button" role="radio" aria-checked={want === "days"} className="radio-card" onClick={() => setWant("days")}>
              <span className="radio-dot" /><span className="grow stack g12"><span className="w500">A different day</span>
                {want === "days" && <span className="row g8 wrap" onClick={(e) => e.stopPropagation()}>{DAYS.map((d, i) => <span key={d} role="button" tabIndex={0} className="choice" aria-pressed={days.includes(i)} onClick={() => toggle(i)} onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && toggle(i)}>{d}</span>)}</span>}
              </span>
            </button>
            <button type="button" role="radio" aria-checked={want === "any"} className="radio-card" onClick={() => setWant("any")}><span className="radio-dot" /><span className="w500">Any other time this week</span></button>
            <button type="button" role="radio" aria-checked={want === "give_up"} className="radio-card" onClick={() => setWant("give_up")}>
              <span className="radio-dot" /><span className="stack g4"><span className="w500">Just give it up</span><span className="ink-2 t-small">Someone else takes it. Your hours go down.</span></span></button>
          </div>
          <input className="input" placeholder="Reason (only your manager sees this)" value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Reason" />
          <button className="btn primary lg" disabled={want === "days" && !days.length} onClick={() => setStep(3)}>Continue</button>
        </>
      )}
      {step === 3 && shift && (
        <>
          <h1 className="t-page">Review</h1>
          <div className="card stack g8">
            <div className="when" style={{ fontFamily: "var(--mono)", fontWeight: 600 }}>{DAYS[shift.day]} {range(shift.start, shift.end)}</div>
            <div className="ink-2">{shift.department} · {want === "give_up" ? "someone else takes it" : want === "any" ? "any other time this week" : `looking for ${days.map((d) => DAYS_LONG[d]).join(", ")}`}</div>
          </div>
          <p className="ink-2">Campus AI searches direct swaps and 3–4 person loops, checks every limit, then sends it to your manager.</p>
          <button className="btn primary lg" disabled={busy} onClick={send}>{busy ? "Sending…" : "Send request"}</button>
        </>
      )}
    </div>
  );
}

/* ---------------- Request status ---------------- */
export function RequestStatus() {
  const [params] = useSearchParams();
  const id = Number(params.get("id"));
  const { data, error, reload } = useWalker<any>("get_my_request", { request_id: id }, { poll: 3000 });
  const [replayed, setReplayed] = useState(false);
  const nav = useNavigate();
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  const chip = data.chip === "waiting" ? <StatusChip kind="wait">Waiting</StatusChip> : data.chip === "confirmed" ? <StatusChip kind="ok">Confirmed</StatusChip>
    : data.chip === "blocked" ? <StatusChip kind="block">Not approved</StatusChip> : <StatusChip kind="neutral">Searching</StatusChip>;
  return (
    <div className="stack g20">
      <div className="row between"><PageTitle eyebrow="Request" title={data.shift} /><Link to="/s/requests" className="btn text sm">Done</Link></div>
      <div className="ink-2">{data.department} · looking for: {data.want}</div>
      <AgentPanel trace={data.trace} onDone={() => setReplayed(true)} title="campus ai · live" />
      {replayed && (
        <div className="card stack g12 slide-in">
          <div className="row between g12"><span className="t-card">{data.message}</span>{chip}</div>
          {data.offer?.state === "waiting" && <button className="btn primary" onClick={() => nav(`/s/offer/${data.offer.offer_id}`)}>Review your offer</button>}
        </div>
      )}
    </div>
  );
}

/* ---------------- Swap offer ---------------- */
const CHIPS = ["A different day", "A different time", "I need more hours", "Something else"];

export function SwapOffer() {
  const { id } = useParams();
  const { data, error, reload, setData } = useWalker<any>("get_offer", { offer_id: Number(id) }, { poll: 3000 });
  const me = useMe();
  const [declining, setDeclining] = useState(false);
  const [chip, setChip] = useState("");
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [prev, setPrev] = useState<string | null>(null);
  const toast = useToast();
  useEffect(() => {
    if (data && prev && prev !== "confirmed" && data.status === "confirmed") toast(`Your swap is confirmed. ${data.gets_day ?? "Your schedule"} is yours.`);
    if (data) setPrev(data.status);
  }, [data?.status]); // eslint-disable-line react-hooks/exhaustive-deps
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data) return <PageSkeleton />;
  const respond = async (accept: boolean, withReason = true) => {
    setBusy(true);
    try {
      setData(await walker<any>("respond_offer", { offer_id: data.offer_id, accept, reason_chip: withReason ? chip : "", reason_text: withReason ? text : "" }));
      setDeclining(false);
      if (!accept) toast("Declined. Campus AI is already re-planning.");
    } catch (e: any) { toast(e.message, false); reload(); }
    setBusy(false);
  };
  const title = data.gets && data.gives ? <>Take <span className="c-accent">{data.gets}</span>, give up {data.gives}?</> : data.gets ? <>Take <span className="c-accent">{data.gets}</span>?</> : <>Give up {data.gives}?</>;
  return (
    <div className="stack g20">
      {data.status === "confirmed" && <Note kind="ok">Your swap is confirmed. {data.gets_day ? `${data.gets_day} is yours.` : "The shift is off your schedule."}</Note>}
      {data.status === "closed" && <Note kind="neutral">This swap didn't go ahead — nothing changed on your schedule.</Note>}
      <span className="eyebrow">Swap offer · {data.department}</span>
      <h1 className="t-page" style={{ lineHeight: 1.25 }}>{title}</h1>
      <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
        {data.gets && <div className="shift-row"><Check size={16} className="c-ok" /><span className="grow"><span className="ink-2">You get </span>{data.gets}</span></div>}
        {data.gives && <div className="shift-row"><ArrowRight size={16} className="ink-3" /><span className="grow"><span className="ink-2">You give up </span>{data.gives}</span></div>}
        <div className="shift-row"><Clock size={16} className="ink-3" /><span className="grow ink-2">{data.hours_before === data.hours_after ? <>Your hours stay at <b>{fmtHours(data.hours_after)}</b></> : <>Your hours go from {fmtHours(data.hours_before)} to <b>{fmtHours(data.hours_after)}</b></>}</span></div>
      </div>
      <section className="card stack g8">
        <LoopDiagram moves={data.circle.map((c: any) => ({ name: c.name, gives: null, gets: c.gets }))} highlight={me?.student?.first_name} />
        <div className="ink-2" style={{ textAlign: "center" }}>{data.others} {data.others === 1 ? "other is" : "others are"} in this loop · {data.others_accepted} already said yes</div>
      </section>
      {data.state === "waiting" && data.status !== "closed" && <div className="mono ink-3">Expires in {countdown(data.expires_in_seconds)}</div>}
      <Disclosure summary="Why this swap?"><p className="ink-2">{data.rationale}</p></Disclosure>
      {data.state === "waiting" && data.status !== "closed" && (
        <div className="row g8"><button className="btn lg grow" onClick={() => setDeclining(true)}>Decline</button><button className="btn primary lg grow" disabled={busy} onClick={() => respond(true)}>Accept</button></div>
      )}
      {data.state === "accepted" && !["confirmed", "closed"].includes(data.status) && <div className="card row between g12"><span>You're in. We'll confirm once everyone says yes.</span><StatusChip kind="wait">Waiting</StatusChip></div>}
      {data.state === "declined" && <div className="card row between g12"><span>You declined this swap.</span><StatusChip kind="block">Declined</StatusChip></div>}
      {declining && (
        <Modal onClose={() => setDeclining(false)} label="Decline swap" sheet>
          <div className="stack g16">
            <h2 className="t-section">No problem. What would have made this work?</h2>
            <div className="row g8 wrap">{CHIPS.map((c) => <button key={c} type="button" className="choice" aria-pressed={chip === c} onClick={() => setChip(chip === c ? "" : c)}>{c}</button>)}</div>
            <input className="input" placeholder="Anything else? (optional)" value={text} onChange={(e) => setText(e.target.value)} aria-label="Reason" />
            <div className="helper">Your answer goes straight into Campus AI's next attempt.</div>
            <div className="row between g8 wrap"><button className="btn text" disabled={busy} onClick={() => respond(false, false)}>Decline without a reason</button><button className="btn primary" disabled={busy} onClick={() => respond(false)}>Decline</button></div>
          </div>
        </Modal>
      )}
    </div>
  );
}

/* ---------------- Update availability ---------------- */
export function UpdateAvailability() {
  const nav = useNavigate();
  return (
    <div className="stack g20">
      <PageTitle eyebrow="Availability" title="Update availability" sub="Connect your calendar once — Campus AI keeps it in sync and moves shifts when something clashes." />
      <section className="card stack g12"><h2 className="t-section">Calendar</h2><CalendarConnect next="/s/availability" /></section>
      <section className="card stack g12"><h2 className="t-section">Standing rules</h2><AvailabilityNotes /></section>
      <button className="btn primary lg" onClick={() => nav("/s")}>Done</button>
    </div>
  );
}

/* ---------------- Profile ---------------- */
interface Employers { employers: { id: number; name: string; kind: string; university: string | null; state: string; hours: number; pay_rate: number; roles: string[] }[];
  kind: "student" | "worker"; university: string | null; can_join_more: boolean }

export function StudentProfile() {
  const me = useMe();
  const { data, error, reload } = useWalker<any>("get_availability");
  const nav = useNavigate();
  const toast = useToast();
  const [p, setP] = useState<any>(null);
  const [params] = useSearchParams();
  useEffect(() => { if (data) setP(data.profile); }, [data]);
  useEffect(() => {
    const c = params.get("calendar");
    if (c === "connected") toast("Google Calendar connected.");
    else if (c === "error" || c === "unavailable") toast(params.get("message") || "Google sign-in isn't set up on this server — use a calendar link instead.", false);
  }, [params, toast]);
  if (error) return <ErrorBlock onRetry={reload} message={error} />;
  if (!data || !p || !me) return <PageSkeleton />;
  const save = async (patch: any) => { setP({ ...p, ...patch }); try { await walker("update_profile", patch); } catch (e: any) { toast(e.message, false); } };
  const cal = data.calendar;
  const st = me.student;
  const sub = st?.kind === "worker" ? "Employee" : `${p.international ? "International student · limit 20 hrs/week" : "Student employee"}${st?.university ? ` · ${st.university}` : ""}`;
  return (
    <div className="stack g20">
      <PageTitle eyebrow="Profile" title={me.name} sub={sub} />

      <WorkAnalytics />

      <Jobs />

      <section className="card"><NotificationSettings /></section>

      <section className="card stack g16">
        <div className="row g16 between">
          <div className="stack g4"><span className="t-card" style={{ fontSize: 17 }}>Autopilot</span><span className="ink-2 t-small">Says yes to swaps into your open days and to open shifts that fit your hours.</span></div>
          <Switch checked={p.autopilot} onChange={(v) => save({ autopilot: v })} label="Autopilot" />
        </div>
        <div className="field"><span className="label">Days you'd happily swap into</span>
          <div className="row g8 wrap">{DAYS.map((d, i) => <button key={d} className="choice" aria-pressed={p.open_swap_days.includes(i)} onClick={() => save({ open_swap_days: p.open_swap_days.includes(i) ? p.open_swap_days.filter((x: number) => x !== i) : [...p.open_swap_days, i] })}>{d}</button>)}</div></div>
      </section>

      <Link to="/s/availability" className="card row g12" style={{ color: "inherit" }}>
        <div className="grow stack g4"><span className="t-card" style={{ fontSize: 17 }}>Calendar & availability</span>
          <span className="ink-2 t-small">{cal.connected ? `${cal.label}${cal.account ? ` · ${cal.account}` : ""} · synced ${cal.synced_seconds_ago != null ? ago(cal.synced_seconds_ago) : "just now"}` : "Not connected"}</span>
          {cal.error && <span className="t-small c-block">{cal.error}</span>}</div>
        <ChevronRight size={18} className="ink-3" />
      </Link>

      <button className="btn lg" onClick={() => signOut(nav)}><LogOut size={16} />Sign out</button>
    </div>
  );
}

function Jobs() {
  const { data, reload } = useWalker<Employers>("get_my_employers");
  const [code, setCode] = useState("");
  const [adding, setAdding] = useState(false);
  const [busy, setBusy] = useState(false);
  const [leaving, setLeaving] = useState<Employers["employers"][number] | null>(null);
  const toast = useToast();
  if (!data) return null;
  const join = async () => {
    setBusy(true);
    try { const r = await walker<any>("join_employer", { code }); toast(`You joined ${r.employer.name}.`); setCode(""); setAdding(false); reload(true); }
    catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  const leave = async () => {
    if (!leaving) return;
    setBusy(true);
    try { const r = await walker<any>("leave_employer", { department_id: leaving.id }); toast(`You left ${leaving.name}.${r.released ? ` ${r.released} upcoming shift${r.released > 1 ? "s were" : " was"} released.` : ""}`); setLeaving(null); reload(true); }
    catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };
  return (
    <section className="card stack g12">
      <div className="row between"><span className="t-card" style={{ fontSize: 17 }}>Your employers</span>
        {data.can_join_more && !adding && <button className="btn sm" onClick={() => setAdding(true)}><Plus size={14} />Join with a code</button>}</div>
      <div className="divided">
        {data.employers.length === 0 && <div className="list-row ink-2">You're not on a team yet.</div>}
        {data.employers.map((e) => (
          <div key={e.id} className="list-row">
            <span className="icon-tile" style={{ width: 34, height: 34 }}><BriefcaseBusiness size={16} /></span>
            <div className="grow stack"><span className="w600">{e.name}</span>
              <span className="t-small ink-3">{e.roles.length ? `${e.roles.join(", ")} · ` : ""}{money(e.pay_rate)}/hr · up to {e.hours} hrs/week</span></div>
            {e.state === "invited" ? <StatusChip kind="wait">Invited</StatusChip> : <button className="btn sm text" onClick={() => setLeaving(e)}>Leave</button>}
          </div>
        ))}
      </div>
      {adding && (
        <div className="stack g8 slide-in">
          <div className="row g8"><input className="input mono" placeholder="JOIN-CODE" value={code} autoFocus onChange={(e) => setCode(e.target.value.toUpperCase())} aria-label="Join code" />
            <button className="btn primary" disabled={busy || code.replace(/[^A-Z0-9]/g, "").length < 6} onClick={join}>Join</button>
            <button className="btn text" onClick={() => setAdding(false)}>Cancel</button></div>
          <span className="helper">{data.kind === "student" ? `Student employees can work for several employers${data.university ? ` at ${data.university}` : ""}.` : "Regular employees belong to one employer at a time."}</span>
        </div>
      )}
      {!data.can_join_more && <span className="helper">Regular employees belong to one employer at a time. Leave your current employer to join another.</span>}
      {leaving && (
        <Modal onClose={() => setLeaving(null)} label="Leave employer" sheet>
          <div className="stack g16">
            <h2 className="t-section">Leave {leaving.name}?</h2>
            <p className="ink-2">Your upcoming shifts there will be released to your team. Hours you already worked stay on your timesheet.</p>
            <div className="row g8 end"><button className="btn" onClick={() => setLeaving(null)}>Stay</button><button className="btn primary" disabled={busy} onClick={leave}>Leave</button></div>
          </div>
        </Modal>
      )}
    </section>
  );
}
