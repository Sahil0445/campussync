import { FormEvent, useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { ArrowRight, Briefcase, Building2, Check, Copy, GraduationCap, Info, Share2, ShieldCheck, Sparkles, X } from "lucide-react";
import { CalendarConnect } from "../components/CalendarConnect";
import { AgentPanel, TraceRow } from "../components/AgentPanel";
import { Need, NeedsEditor } from "../components/editors";
import { NotificationSettings } from "../components/Notifications";
import { Disclosure, Field, Privacy, Segmented, Switch, Wordmark, useToast } from "../components/ui";
import { getSession, login, Role, setSession, walker } from "../lib/api";
import { DAYS, hm } from "../lib/time";

const DEMOS: { role: Role; email: string; title: string; sub: string; icon: "org" | "student" | "worker" }[] = [
  { role: "department", email: "dining@demo.edu", title: "Campus Dining", sub: "Campus employer", icon: "org" },
  { role: "department", email: "shield@demo.com", title: "Shieldpoint", sub: "Security company", icon: "org" },
  { role: "student", email: "priya@demo.edu", title: "Priya", sub: "International · 2 jobs", icon: "student" },
  { role: "student", email: "marcus@demo.edu", title: "Marcus", sub: "Student · autopilot off", icon: "student" },
  { role: "student", email: "tom@demo.com", title: "Tom", sub: "Security guard", icon: "worker" },
  { role: "student", email: "sam@demo.edu", title: "Sam", sub: "Student · autopilot on", icon: "student" },
];

const home = (r: Role) => (r === "department" ? "/d" : "/s");

/* ---------------- Sign in ---------------- */
export function SignIn() {
  const [role, setRole] = useState<Role>("student");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();

  useEffect(() => { const s = getSession(); if (s) nav(home(s.role), { replace: true }); }, [nav]);

  const go = async (e: string, p: string, r: Role) => {
    setBusy(true); setError(null);
    try { const s = await login(e.trim(), p, r); nav(home(s.role)); }
    catch (err: any) { setError(err.message); }
    setBusy(false);
  };
  const submit = (e: FormEvent) => { e.preventDefault(); go(email, password, role); };

  return (
    <div className="center-page">
      <div className="auth-card stack g20">
        <Link to="/" style={{ alignSelf: "center" }}><Wordmark size={30} /></Link>
        <div className="card glow stack g20">
          <div className="stack g4"><h1 className="t-page">Welcome back</h1><span className="ink-2">Your agents kept working while you were away.</span></div>
          <form className="stack g16" onSubmit={submit}>
            <Segmented full label="Account type" value={role} onChange={setRole} options={[{ value: "student", label: "Employee" }, { value: "department", label: "Employer" }]} />
            <Field label="Email" htmlFor="email"><input id="email" className="input" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
            <Field label="Password" htmlFor="password"><input id="password" className="input" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
            {error && <div className="c-block" role="alert">{error}</div>}
            <button className="btn primary block lg" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
          </form>
          <div className="ink-2 t-small" style={{ textAlign: "center" }}>New here? <Link to="/signup/employee">Join your employer</Link> · <Link to="/signup/employer">Register an organization</Link></div>
          <Disclosure summary="Try the demo accounts">
            <div className="demo-grid mt8">
              {DEMOS.map((d) => (
                <button key={d.email} className="radio-card" style={{ padding: 12 }} disabled={busy} onClick={() => go(d.email, "demo1234", d.role)}>
                  <span className="icon-tile" style={{ width: 30, height: 30 }}>{d.icon === "org" ? <Building2 size={15} /> : d.icon === "worker" ? <ShieldCheck size={15} /> : <GraduationCap size={15} />}</span>
                  <span className="stack"><span className="w600">{d.title}</span><span className="t-small ink-3">{d.sub}</span></span>
                </button>
              ))}
            </div>
          </Disclosure>
        </div>
        <Privacy className="ink-3">Employers never see each other's schedules.</Privacy>
      </div>
    </div>
  );
}

function Steps({ n, of }: { n: number; of: number }) {
  return <div className="stack g8"><span className="progress-text">Step {n} of {of}</span><div className="steps">{Array.from({ length: of }, (_, i) => <i key={i} className={i < n ? "on" : ""} />)}</div></div>;
}

/* ---------------- Who are you? ---------------- */
export function SignupChooser() {
  return (
    <div className="onboard">
      <Link to="/"><Wordmark /></Link>
      <h1 className="t-display mt32">Create your <span className="grad-text">account</span></h1>
      <div className="stack g12 mt32">
        <Link to="/signup/employee" className="radio-card" style={{ padding: 20, color: "inherit" }}>
          <span className="icon-tile"><Briefcase size={18} /></span>
          <span className="grow stack g4"><span className="w600" style={{ fontSize: 16 }}>I'm an employee</span><span className="ink-2">You'll need the join code your manager gave you.</span></span><ArrowRight size={18} className="ink-3" />
        </Link>
        <Link to="/signup/employer" className="radio-card" style={{ padding: 20, color: "inherit" }}>
          <span className="icon-tile"><Building2 size={18} /></span>
          <span className="grow stack g4"><span className="w600" style={{ fontSize: 16 }}>I'm an employer</span><span className="ink-2">A campus department, or any business with a team to schedule.</span></span><ArrowRight size={18} className="ink-3" />
        </Link>
      </div>
      <div className="ink-2 mt24">Already have an account? <Link to="/signin">Sign in</Link></div>
    </div>
  );
}

/* ---------------- Employee sign-up (join code) ---------------- */
interface OrgCard { id: number; name: string; kind: "campus" | "business"; university: string | null }

export function EmployeeSignup() {
  const [params, setParams] = useSearchParams();
  const initialStep = Number(params.get("step") || 1);
  const [step, setStep] = useState(getSession() && initialStep > 2 ? initialStep : 1);
  const [code, setCode] = useState(params.get("code") ?? "");
  const [org, setOrg] = useState<OrgCard | null>(null);
  const [codeError, setCodeError] = useState<string | null>(null);
  const [kind, setKind] = useState<"student" | "worker">("student");
  const [f, setF] = useState({ name: "", email: "", password: "", status: "domestic", student_number: "" });
  const [openDays, setOpenDays] = useState<number[]>([]);
  const [autopilot, setAutopilot] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  const toast = useToast();

  useEffect(() => {
    const c = params.get("calendar");
    if (c === "connected") toast("Google Calendar connected.");
    else if (c === "error") toast(params.get("message") || "Couldn't connect Google Calendar.", false);
  }, [params, toast]);

  // Look the code up as the user types (debounced).
  useEffect(() => {
    const clean = code.replace(/[^A-Za-z0-9]/g, "");
    setOrg(null); setCodeError(null);
    if (clean.length < 6) return;
    const t = window.setTimeout(async () => {
      try {
        const o = await walker<OrgCard>("lookup_join_code", { code }, false);
        setOrg(o);
        setKind(o.kind === "business" ? "worker" : "student");
      } catch (e: any) { setCodeError(e.message); }
    }, 300);
    return () => window.clearTimeout(t);
  }, [code]);

  const go = (n: number) => { setStep(n); setParams(n > 2 ? { step: String(n) } : code ? { code } : {}, { replace: true }); window.scrollTo(0, 0); };

  const next = async (e?: FormEvent) => {
    e?.preventDefault(); setError(null);
    if (step === 1) { if (org) go(2); return; }
    if (step === 2) {
      setBusy(true);
      try {
        const r = await walker<any>("register_employee", { ...f, kind, code }, false);
        setSession({ token: r.token, role: r.role, name: r.name });
        toast(`You joined ${r.employer.name}.`);
        go(3);
      } catch (err: any) { setError(err.message); }
      setBusy(false);
      return;
    }
    if (step === 3) { go(4); return; }
    setBusy(true);
    try { await walker("update_profile", { open_swap_days: openDays, autopilot }); nav("/s"); }
    catch (err: any) { setError(err.message); }
    setBusy(false);
  };
  const toggleDay = (i: number) => setOpenDays(openDays.includes(i) ? openDays.filter((x) => x !== i) : [...openDays, i]);

  return (
    <div className="onboard">
      <div className="row between"><Link to="/"><Wordmark /></Link></div>
      <div className="mt32"><Steps n={step} of={4} /></div>
      <form className="stack g24 mt32" onSubmit={next}>
        {step === 1 && (
          <>
            <div className="stack g8"><h1 className="t-display">Join your <span className="grad-text">employer.</span></h1>
              <p className="ink-2">Enter the join code your manager shared. It connects you to the right team.</p></div>
            <div className="card stack g16">
              <Field label="Join code" htmlFor="code" helper="Looks like DINE-7K2Q. Not case sensitive.">
                <input id="code" className="input mono code-input" required autoFocus autoCapitalize="characters" autoComplete="off" spellCheck={false}
                       value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="XXXX-XXXX" maxLength={20} />
              </Field>
              {codeError && <div className="c-block row g8" role="alert"><X size={16} />{codeError}</div>}
              {org && (
                <div className="note ok slide-in" style={{ alignItems: "center" }}>
                  <Check size={16} />
                  <div className="grow"><b style={{ color: "inherit" }}>{org.name}</b>{org.university ? ` · ${org.university}` : ""}
                    <div className="t-small">{org.kind === "campus" ? "Campus employer" : "Business"}</div></div>
                </div>
              )}
              {org?.kind === "campus" && (
                <div className="field"><span className="label">How do you work here?</span>
                  <Segmented full label="Employee type" value={kind} onChange={setKind}
                             options={[{ value: "student", label: "Student employee" }, { value: "worker", label: "Staff / full-time" }]} />
                  <span className="helper">{kind === "student" ? `You can join other employers at ${org.university} later with their codes.` : "Staff belong to one employer at a time."}</span>
                </div>
              )}
              {org?.kind === "business" && <span className="helper">Regular employees belong to one employer at a time.</span>}
            </div>
          </>
        )}
        {step === 2 && org && (
          <>
            <div className="stack g8"><h1 className="t-display">Create your <span className="grad-text">account.</span></h1>
              <p className="ink-2">Joining <b style={{ color: "var(--ink)" }}>{org.name}</b>{kind === "student" ? " as a student employee" : ""}.</p></div>
            <div className="card stack g16">
              <Field label="Full name" htmlFor="n"><input id="n" className="input" required autoComplete="name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
              <Field label="Email" htmlFor="e" helper="Use the email you check — alerts and your Google Calendar link to it."><input id="e" className="input" type="email" required autoComplete="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
              <Field label="Password" htmlFor="p" helper="At least 8 characters."><input id="p" className="input" type="password" required minLength={8} autoComplete="new-password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} /></Field>
              {kind === "student" && (
                <>
                  <div className="field"><span className="label">Student status</span>
                    <Segmented label="Student status" value={f.status} onChange={(v) => setF({ ...f, status: v })} options={[{ value: "domestic", label: "Domestic" }, { value: "international", label: "International" }]} /></div>
                  {f.status === "international" && (
                    <div className="note neutral"><Info size={16} /><div>International students can work up to <b>20 hours a week across all campus jobs combined</b>. CampusSync blocks anything over that — in schedules and in reported hours.</div></div>
                  )}
                  <Field label="Student ID (optional)" htmlFor="u"><input id="u" className="input" value={f.student_number} onChange={(e) => setF({ ...f, student_number: e.target.value })} /></Field>
                </>
              )}
            </div>
          </>
        )}
        {step === 3 && (
          <>
            <div className="stack g8"><h1 className="t-display">Connect your calendar <span className="grad-text">once.</span></h1>
              <p className="ink-2">CampusSync reads when you're busy so you're never scheduled over a class or appointment — and puts your shifts into a separate “CampusSync shifts” calendar.</p></div>
            <div className="card"><CalendarConnect next="/signup/employee?step=3" /></div>
            <span className="helper">You can do this later from your profile.</span>
          </>
        )}
        {step === 4 && (
          <>
            <h1 className="t-display">Alerts and <span className="grad-text">autopilot.</span></h1>
            <div className="card stack g16"><NotificationSettings compact /></div>
            <div className="card stack g20">
              <div className="field"><span className="label">Days you'd happily swap into</span>
                <div className="row g8 wrap">{DAYS.map((d, i) => <button key={d} type="button" className="choice" aria-pressed={openDays.includes(i)} onClick={() => toggleDay(i)}>{d}</button>)}</div></div>
              <div className="row g16 between hairline-top" style={{ paddingTop: 18 }}>
                <div className="stack g4"><span className="w600 row g8"><Sparkles size={15} className="c-accent" />Autopilot</span>
                  <span className="ink-2 t-small">Says yes to swaps into your open days and to open shifts that fit your hours — without asking. Every move still passes every limit.</span></div>
                <Switch checked={autopilot} onChange={setAutopilot} label="Autopilot" />
              </div>
            </div>
          </>
        )}
        {error && <div className="c-block" role="alert">{error}</div>}
        <div className="onboard-foot">
          {step === 1 ? <Link to="/signin" className="btn">Back</Link> : step === 2 ? <button type="button" className="btn" onClick={() => go(1)}>Back</button> : <span />}
          <button className="btn primary lg" disabled={busy || (step === 1 && !org)}>{step === 4 ? "Finish" : step === 3 ? "Continue" : busy ? "Joining…" : "Continue"}<ArrowRight size={16} /></button>
        </div>
      </form>
    </div>
  );
}

/* ---------------- Employer sign-up ---------------- */
export function EmployerSignup() {
  const [step, setStep] = useState(1);
  const [f, setF] = useState({ organization: "", kind: "business", university: "", name: "", email: "", password: "" });
  const [unis, setUnis] = useState<string[]>([]);
  const [joinCode, setJoinCode] = useState("");
  const [roles, setRoles] = useState("");
  const [desc, setDesc] = useState("");
  const [plan, setPlan] = useState<{ needs: Need[]; summary: string; ai: boolean } | null>(null);
  const [roleList, setRoleList] = useState<{ id: number; name: string }[]>([]);
  const [trace, setTrace] = useState<TraceRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  const toast = useToast();
  const tz = useMemo(() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch { return ""; } }, []);

  useEffect(() => {
    if (f.kind !== "campus") return;
    const t = window.setTimeout(async () => {
      try { setUnis((await walker<any>("list_universities", { query: f.university }, false)).universities.map((u: any) => u.name)); } catch { /* empty */ }
    }, 200);
    return () => window.clearTimeout(t);
  }, [f.kind, f.university]);

  const link = `${location.origin}/join/${joinCode}`;
  const submit = async (e: FormEvent) => {
    e.preventDefault(); setError(null); setBusy(true);
    try {
      if (step === 1) {
        const r = await walker<any>("register_employer", { ...f, timezone: tz }, false);
        setSession({ token: r.token, role: r.role, name: r.name });
        setJoinCode(r.join_code); setStep(2);
      } else if (step === 2) {
        const names = roles.split(/[,\n]/).map((x) => x.trim()).filter(Boolean);
        for (const name of names) await walker("save_position", { name });
        setStep(3);
      } else if (!plan) {
        setTrace(null);
        const r = await walker<any>("generate_needs", { description: desc });
        setTrace([{ agent: "Coordinator", kind: "agent", result: "read your description", status: "done" },
                  { agent: "Needs Agent", kind: "agent", result: `drafted ${r.needs.length} weekly blocks`, status: "done", ai: r.ai },
                  { agent: "", kind: "final", result: "Staffing plan ready", status: "done" }]);
        setPlan(r);
        try { setRoleList((await walker<any>("get_org")).positions); } catch { /* roles are optional */ }
      } else {
        await walker("set_staffing_needs", { needs: plan.needs });
        await walker("run_autopilot");
        toast("Autopilot is live."); nav("/d");
      }
    } catch (err: any) { setError(err.message); }
    setBusy(false);
  };
  const copy = async (text: string, what: string) => { try { await navigator.clipboard.writeText(text); toast(`${what} copied.`); } catch { toast(text); } };
  const share = async () => {
    const data = { title: `Join ${f.organization} on CampusSync`, text: `Join ${f.organization} on CampusSync with code ${joinCode}`, url: link };
    if ((navigator as any).share) { try { await (navigator as any).share(data); } catch { /* cancelled */ } } else copy(link, "Invite link");
  };
  const byDay = plan ? DAYS.map((d, i) => ({ d, rows: plan.needs.filter((n) => n.day === i) })).filter((x) => x.rows.length) : [];

  return (
    <div className="onboard">
      <Link to="/"><Wordmark /></Link>
      <div className="mt32"><Steps n={step} of={3} /></div>
      <form className="stack g24 mt32" onSubmit={submit}>
        {step === 1 && (
          <>
            <h1 className="t-display">Put your team <span className="grad-text">on autopilot.</span></h1>
            <div className="card stack g16">
              <div className="field"><span className="label">What kind of employer?</span>
                <Segmented full label="Employer type" value={f.kind} onChange={(v) => setF({ ...f, kind: v })} options={[{ value: "business", label: "Business" }, { value: "campus", label: "Campus employer" }]} />
                <span className="helper">{f.kind === "campus" ? "A university department or campus vendor. Students can hold jobs with several campus employers." : "Security firms, cafés, clinics, stores — any team with shifts."}</span></div>
              <Field label="Organization name" htmlFor="on" helper={f.kind === "campus" ? "e.g. Campus Dining" : "e.g. Shieldpoint Security"}>
                <input id="on" className="input" required value={f.organization} onChange={(e) => setF({ ...f, organization: e.target.value })} /></Field>
              {f.kind === "campus" && (
                <Field label="University" htmlFor="uni" helper="Pick yours if it's listed, so students can work across its employers.">
                  <input id="uni" className="input" required list="unis" value={f.university} onChange={(e) => setF({ ...f, university: e.target.value })} />
                  <datalist id="unis">{unis.map((u) => <option key={u} value={u} />)}</datalist>
                </Field>
              )}
              <Field label="Your name" htmlFor="yn"><input id="yn" className="input" required autoComplete="name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
              <Field label="Work email" htmlFor="we"><input id="we" className="input" type="email" required autoComplete="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
              <Field label="Password" htmlFor="pw" helper="At least 8 characters."><input id="pw" className="input" type="password" required minLength={8} autoComplete="new-password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} /></Field>
              {tz && <span className="helper">Time zone: {tz} — shift alerts use it. Change it later in Settings.</span>}
            </div>
          </>
        )}
        {step === 2 && (
          <>
            <div className="stack g8"><h1 className="t-display">Your join code <span className="grad-text">is ready.</span></h1>
              <p className="ink-2">Employees sign up with this code and land on your team. Share the link — it fills the code in for them.</p></div>
            <div className="card stack g16">
              <div className="join-code-big mono">{joinCode}</div>
              <div className="row g8 wrap">
                <button type="button" className="btn" onClick={() => copy(joinCode, "Join code")}><Copy size={15} />Copy code</button>
                <button type="button" className="btn" onClick={share}><Share2 size={15} />Share invite link</button>
              </div>
              <span className="t-small ink-3 mono" style={{ wordBreak: "break-all" }}>{link}</span>
            </div>
            <div className="card stack g12">
              <Field label="Roles on your team (optional)" htmlFor="roles" helper="Comma separated, e.g. Site guard, Night patrol. Shifts can require a role; only people with it get scheduled.">
                <input id="roles" className="input" value={roles} onChange={(e) => setRoles(e.target.value)} placeholder={f.kind === "campus" ? "Cashier, Line cook" : "Site guard, Night patrol"} />
              </Field>
              <span className="helper">Everyone starts at $15.00/hr. You can change pay per person on the Team page.</span>
            </div>
          </>
        )}
        {step === 3 && (
          <>
            <div className="stack g8"><h1 className="t-display">Describe a normal week. <span className="grad-text">We'll plan it.</span></h1>
              <p className="ink-2">One or two sentences. The Needs Agent turns it into staffing blocks; the Scheduling Agent drafts every week for your approval.</p></div>
            <div className="card stack g16">
              <textarea className="textarea" required value={desc} onChange={(e) => { setDesc(e.target.value); setPlan(null); }}
                        placeholder={f.kind === "campus" ? "e.g. We're a campus café open 7am to 7pm on weekdays, slammed at lunch, and a smaller crew on Saturdays."
                          : "e.g. One guard on site 7am to 7pm every day, and a night patrol 6pm to midnight."} />
              {trace && <AgentPanel trace={trace} title="needs agent · live" />}
              {plan && (
                <div className="stack g12 slide-in">
                  <div className="w500">{plan.summary}</div>
                  <div className="divided">
                    {byDay.map(({ d, rows }) => (
                      <div key={d} className="list-row"><span className="mono" style={{ width: 36 }}>{d}</span>
                        <span className="row g8 wrap">{rows.map((r, i) => <span key={i} className="chip accent">{hm(r.start)}–{hm(r.end)} · {r.headcount}{(r as any).role ? ` · ${(r as any).role}` : ""}</span>)}</span></div>
                    ))}
                  </div>
                  <Disclosure summary="Adjust by hand"><NeedsEditor needs={plan.needs} onChange={(n) => setPlan({ ...plan, needs: n })} roles={roleList} /></Disclosure>
                </div>
              )}
            </div>
          </>
        )}
        {error && <div className="c-block" role="alert">{error}</div>}
        <div className="onboard-foot" style={{ alignItems: "center" }}>
          {step === 1 ? <Link to="/signin" className="btn">Back</Link> : step === 3 ? <Link to="/d" className="btn text">Skip for now</Link> : <span />}
          <button className="btn primary lg" disabled={busy || (step === 3 && !desc.trim())}>
            {step === 1 ? (busy ? "Creating…" : "Create organization") : step === 2 ? "Continue" : plan ? "Launch autopilot" : busy ? "Planning…" : "Build my staffing plan"}<ArrowRight size={16} />
          </button>
        </div>
      </form>
    </div>
  );
}
