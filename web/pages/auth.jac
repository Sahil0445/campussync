"""Sign in, the sign-up chooser, employee sign-up (join code) and employer sign-up."""

import from react { useEffect, useMemo }
import from "react-router-dom" { Link, useNavigate, useSearchParams }
import from "lucide-react" { ArrowRight, Briefcase, Building2, Check, Copy, GraduationCap, Info, Share2, ShieldCheck, Sparkles, X }
import from web.components.CalendarConnect { CalendarConnect }
import from web.components.AgentPanel { AgentPanel }
import from web.components.editors { NeedsEditor }
import from web.components.Notifications { NotificationSettings }
import from web.components.ui { Disclosure, Field, Privacy, Segmented, Switch, Wordmark, useToast }
import from web.lib.api { api, errMsg, getSession, login, signup }
import from web.lib.time { DAYS, hm }

glob:pub JS: any = globalThis;

glob:pub DEMOS: list[dict[str, str]] = [
    {"role": "department", "email": "dining@demo.edu", "title": "Campus Dining", "sub": "Campus employer", "icon": "org"},
    {"role": "department", "email": "shield@demo.com", "title": "Shieldpoint", "sub": "Security company", "icon": "org"},
    {"role": "student", "email": "priya@demo.edu", "title": "Priya", "sub": "International · 2 jobs", "icon": "student"},
    {"role": "student", "email": "marcus@demo.edu", "title": "Marcus", "sub": "Student · autopilot off", "icon": "student"},
    {"role": "student", "email": "tom@demo.com", "title": "Tom", "sub": "Security guard", "icon": "worker"},
    {"role": "student", "email": "sam@demo.edu", "title": "Sam", "sub": "Student · autopilot on", "icon": "student"}
];

def home(r: str) -> str {
    return "/d" if r == "department" else "/s";
}

def _timezone() -> any {
    try {
        return JS.Intl.DateTimeFormat().resolvedOptions().timeZone;
    } except Exception {
        return "";
    }
}

# ---------------- Sign in ----------------
def:pub SignIn() -> JsxElement {
    has role: str = "student";
    has email: str = "";
    has password: str = "";
    has error: any = None;
    has busy: bool = False;
    nav: any = useNavigate();

    useEffect(
        lambda -> any {
            s: any = getSession();
            if s {
                nav(home(s.role), {"replace": True});
            }
            return JS.undefined;
        },
        [nav]
    );

    async def go(em: str, pw: str, r: str) -> None {
        busy = True;
        error = None;
        try {
            s: any = await login(em.strip(), pw, r);
            nav(home(s.role));
        } except Exception as err {
            error = errMsg(err);
        }
        busy = False;
    }

    <div className="center-page">
        <div className="auth-card stack g20">
            <Link to="/" style={{"alignSelf": "center"}}><Wordmark size={30} /></Link>
            <div className="card glow stack g20">
                <div className="stack g4"><h1 className="t-page">Welcome back</h1><span className="ink-2">Your agents kept working while you were away.</span></div>
                <form className="stack g16" onSubmit={lambda (e: FormEvent) { e.preventDefault(); go(email, password, role); }}>
                    <Segmented full={True} label="Account type" value={role} onChange={lambda (v: str) { role = v; }} options={[{"value": "student", "label": "Employee"}, {"value": "department", "label": "Employer"}]} />
                    <Field label="Email" htmlFor="email"><input id="email" className="input" type="email" autoComplete="email" required={True} value={email} onChange={lambda (e: ChangeEvent) { email = e.target.value; }} /></Field>
                    <Field label="Password" htmlFor="password"><input id="password" className="input" type="password" autoComplete="current-password" required={True} value={password} onChange={lambda (e: ChangeEvent) { password = e.target.value; }} /></Field>
                    {error and <div className="c-block" role="alert">{error}</div>}
                    <button className="btn primary block lg" disabled={busy}>{"Signing in…" if busy else "Sign in"}</button>
                </form>
                <div className="ink-2 t-small" style={{"textAlign": "center"}}>New here? <Link to="/signup/employee">Join your employer</Link> · <Link to="/signup/employer">Register an organization</Link></div>
                <Disclosure summary="Try the demo accounts">
                    <div className="demo-grid mt8">
                        {for d in DEMOS {
                            icon: str = d["icon"];
                            <button key={d["email"]} className="radio-card" style={{"padding": 12}} disabled={busy} onClick={lambda (e: MouseEvent) { go(d["email"], "demo1234", d["role"]); }}>
                                <span className="icon-tile" style={{"width": 30, "height": 30}}>{<Building2 size={15} /> if icon == "org" else (<ShieldCheck size={15} /> if icon == "worker" else <GraduationCap size={15} />)}</span>
                                <span className="stack"><span className="w600">{d["title"]}</span><span className="t-small ink-3">{d["sub"]}</span></span>
                            </button>
                        }}
                    </div>
                </Disclosure>
            </div>
            <Privacy className="ink-3">Employers never see each other's schedules.</Privacy>
        </div>
    </div>
}

def:pub Steps(n: int, of: int) -> JsxElement {
    <div className="stack g8"><span className="progress-text">Step {n} of {of}</span><div className="steps">{for k in range(of) { <i key={k} className={"on" if k < n else ""} /> }}</div></div>
}

# ---------------- Who are you? ----------------
def:pub SignupChooser() -> JsxElement {
    <div className="onboard">
        <Link to="/"><Wordmark /></Link>
        <h1 className="t-display mt32">Create your <span className="grad-text">account</span></h1>
        <div className="stack g12 mt32">
            <Link to="/signup/employee" className="radio-card" style={{"padding": 20, "color": "inherit"}}>
                <span className="icon-tile"><Briefcase size={18} /></span>
                <span className="grow stack g4"><span className="w600" style={{"fontSize": 16}}>I'm an employee</span><span className="ink-2">You'll need the join code your manager gave you.</span></span><ArrowRight size={18} className="ink-3" />
            </Link>
            <Link to="/signup/employer" className="radio-card" style={{"padding": 20, "color": "inherit"}}>
                <span className="icon-tile"><Building2 size={18} /></span>
                <span className="grow stack g4"><span className="w600" style={{"fontSize": 16}}>I'm an employer</span><span className="ink-2">A campus department, or any business with a team to schedule.</span></span><ArrowRight size={18} className="ink-3" />
            </Link>
        </div>
        <div className="ink-2 mt24">Already have an account? <Link to="/signin">Sign in</Link></div>
    </div>
}

# ---------------- Employee sign-up (join code) ----------------
"""org card: {id, name, kind: campus|business, university}"""
def:pub EmployeeSignup() -> JsxElement {
    sp: any = useSearchParams();
    params: any = sp[0];
    setParams: any = sp[1];
    initialStep: int = JS.Number(params.get("step") or 1);
    has step: int = initialStep if getSession() and initialStep > 2 else 1;
    has code: str = params.get("code") or "";
    has org: any = None;
    has codeError: any = None;
    has kind: str = "student";
    has f: any = {"name": "", "email": "", "password": "", "status": "domestic", "student_number": ""};
    has openDays: list[int] = [];
    has autopilot: bool = True;
    has error: any = None;
    has busy: bool = False;
    nav: any = useNavigate();
    toast: any = useToast();

    useEffect(
        lambda -> any {
            c: any = params.get("calendar");
            if c == "connected" {
                toast("Google Calendar connected.");
            } elif c == "error" {
                toast(params.get("message") or "Couldn't connect Google Calendar.", False);
            }
            return JS.undefined;
        },
        [params, toast]
    );

    async def lookup(c: str) -> None {
        try {
            o: any = await api("lookup_join_code", {"code": c}, False);
            org = o;
            kind = "worker" if o.kind == "business" else "student";
        } except Exception as e {
            codeError = errMsg(e);
        }
    }

    # Look the code up as the user types (debounced).
    useEffect(
        lambda -> any {
            cs: any = code;
            clean: any = cs.replace(new(JS.RegExp, "[^A-Za-z0-9]", "g"), "");
            org = None;
            codeError = None;
            if clean.length < 6 {
                return JS.undefined;
            }
            c: str = code;
            t: any = JS.window.setTimeout(lambda { lookup(c); }, 300);
            return lambda { JS.window.clearTimeout(t); };
        },
        [code]
    );

    def go(n: int) -> None {
        step = n;
        setParams({"step": str(n)} if n > 2 else ({"code": code} if code else {}), {"replace": True});
        JS.window.scrollTo(0, 0);
    }

    async def next() -> None {
        error = None;
        if step == 1 {
            if org {
                go(2);
            }
            return;
        }
        if step == 2 {
            busy = True;
            try {
                r: any = await signup("register_employee", "student", JS.Object.assign({}, f, {"kind": kind, "code": code}));
                toast("You joined " + r.employer.name + ".");
                go(3);
            } except Exception as err {
                error = errMsg(err);
            }
            busy = False;
            return;
        }
        if step == 3 {
            go(4);
            return;
        }
        busy = True;
        try {
            await api("update_profile", {"open_swap_days": openDays, "autopilot": autopilot});
            nav("/s");
        } except Exception as err {
            error = errMsg(err);
        }
        busy = False;
    }

    def toggleDay(i: int) -> None {
        openDays = [x for x in openDays if x != i] if i in openDays else openDays + [i];
    }

    <div className="onboard">
        <div className="row between"><Link to="/"><Wordmark /></Link></div>
        <div className="mt32"><Steps n={step} of={4} /></div>
        <form className="stack g24 mt32" onSubmit={lambda (e: FormEvent) { e.preventDefault(); next(); }}>
            {step == 1 and <>
                <div className="stack g8"><h1 className="t-display">Join your <span className="grad-text">employer.</span></h1>
                    <p className="ink-2">Enter the join code your manager shared. It connects you to the right team.</p></div>
                <div className="card stack g16">
                    <Field label="Join code" htmlFor="code" helper="Looks like DINE-7K2Q. Not case sensitive.">
                        <input id="code" className="input mono code-input" required={True} autoFocus={True} autoCapitalize="characters" autoComplete="off" spellCheck={False}
                            value={code} onChange={lambda (e: ChangeEvent) { code = e.target.value.upper(); }} placeholder="XXXX-XXXX" maxLength={20} />
                    </Field>
                    {codeError and <div className="c-block row g8" role="alert"><X size={16} />{codeError}</div>}
                    {org and <div className="note ok slide-in" style={{"alignItems": "center"}}>
                        <Check size={16} />
                        <div className="grow"><b style={{"color": "inherit"}}>{org.name}</b>{(" · " + org.university) if org.university else ""}
                            <div className="t-small">{"Campus employer" if org.kind == "campus" else "Business"}</div></div>
                    </div>}
                    {org and org.kind == "campus" and <div className="field"><span className="label">How do you work here?</span>
                        <Segmented full={True} label="Employee type" value={kind} onChange={lambda (v: str) { kind = v; }}
                            options={[{"value": "student", "label": "Student employee"}, {"value": "worker", "label": "Staff / full-time"}]} />
                        <span className="helper">{("You can join other employers at " + JS.String(org.university) + " later with their codes.") if kind == "student" else "Staff belong to one employer at a time."}</span>
                    </div>}
                    {org and org.kind == "business" and <span className="helper">Regular employees belong to one employer at a time.</span>}
                </div>
            </>}
            {step == 2 and org and <>
                <div className="stack g8"><h1 className="t-display">Create your <span className="grad-text">account.</span></h1>
                    <p className="ink-2">Joining <b style={{"color": "var(--ink)"}}>{org.name}</b>{" as a student employee" if kind == "student" else ""}.</p></div>
                <div className="card stack g16">
                    <Field label="Full name" htmlFor="n"><input id="n" className="input" required={True} autoComplete="name" value={f.name} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"name": e.target.value}); }} /></Field>
                    <Field label="Email" htmlFor="e" helper="Use the email you check — alerts and your Google Calendar link to it."><input id="e" className="input" type="email" required={True} autoComplete="email" value={f.email} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"email": e.target.value}); }} /></Field>
                    <Field label="Password" htmlFor="p" helper="At least 8 characters."><input id="p" className="input" type="password" required={True} minLength={8} autoComplete="new-password" value={f.password} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"password": e.target.value}); }} /></Field>
                    {kind == "student" and <>
                        <div className="field"><span className="label">Student status</span>
                            <Segmented label="Student status" value={f.status} onChange={lambda (v: str) { f = JS.Object.assign({}, f, {"status": v}); }} options={[{"value": "domestic", "label": "Domestic"}, {"value": "international", "label": "International"}]} /></div>
                        {f.status == "international" and <div className="note neutral"><Info size={16} /><div>International students can work up to <b>20 hours a week across all campus jobs combined</b>. CampusSync blocks anything over that — in schedules and in reported hours.</div></div>}
                        <Field label="Student ID (optional)" htmlFor="u"><input id="u" className="input" value={f.student_number} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"student_number": e.target.value}); }} /></Field>
                    </>}
                </div>
            </>}
            {step == 3 and <>
                <div className="stack g8"><h1 className="t-display">Connect your calendar <span className="grad-text">once.</span></h1>
                    <p className="ink-2">CampusSync reads when you're busy so you're never scheduled over a class or appointment — and puts your shifts into a separate “CampusSync shifts” calendar.</p></div>
                <div className="card"><CalendarConnect next="/signup/employee?step=3" /></div>
                <span className="helper">You can do this later from your profile.</span>
            </>}
            {step == 4 and <>
                <h1 className="t-display">Alerts and <span className="grad-text">autopilot.</span></h1>
                <div className="card stack g16"><NotificationSettings compact={True} /></div>
                <div className="card stack g20">
                    <div className="field"><span className="label">Days you'd happily swap into</span>
                        <div className="row g8 wrap">{for (i, d) in enumerate(DAYS) {
                            <button key={d} type="button" className="choice" aria-pressed={i in openDays} onClick={lambda (e: MouseEvent) { toggleDay(i); }}>{d}</button>
                        }}</div></div>
                    <div className="row g16 between hairline-top" style={{"paddingTop": 18}}>
                        <div className="stack g4"><span className="w600 row g8"><Sparkles size={15} className="c-accent" />Autopilot</span>
                            <span className="ink-2 t-small">Says yes to swaps into your open days and to open shifts that fit your hours — without asking. Every move still passes every limit.</span></div>
                        <Switch checked={autopilot} onChange={lambda (v: bool) { autopilot = v; }} label="Autopilot" />
                    </div>
                </div>
            </>}
            {error and <div className="c-block" role="alert">{error}</div>}
            <div className="onboard-foot">
                {<Link to="/signin" className="btn">Back</Link> if step == 1 else (<button type="button" className="btn" onClick={lambda (e: MouseEvent) { go(1); }}>Back</button> if step == 2 else <span />)}
                <button className="btn primary lg" disabled={busy or (step == 1 and not org)}>{"Finish" if step == 4 else ("Continue" if step == 3 else ("Joining…" if busy else "Continue"))}<ArrowRight size={16} /></button>
            </div>
        </form>
    </div>
}

# ---------------- Employer sign-up ----------------
def:pub EmployerSignup() -> JsxElement {
    has step: int = 1;
    has f: any = {"organization": "", "kind": "business", "university": "", "name": "", "email": "", "password": ""};
    has unis: list[any] = [];
    has joinCode: str = "";
    has roles: str = "";
    has desc: str = "";
    has plan: any = None;
    has roleList: list[any] = [];
    has trace: any = None;
    has error: any = None;
    has busy: bool = False;
    nav: any = useNavigate();
    toast: any = useToast();
    tz: any = useMemo(lambda -> any { return _timezone(); }, []);

    async def loadUnis(query: str) -> None {
        try {
            r: any = await api("list_universities", {"query": query}, False);
            unis = [u.name for u in r.universities];
        } except Exception {
            return;
        }
    }

    useEffect(
        lambda -> any {
            if f.kind != "campus" {
                return JS.undefined;
            }
            qy: str = f.university;
            t: any = JS.window.setTimeout(lambda { loadUnis(qy); }, 200);
            return lambda { JS.window.clearTimeout(t); };
        },
        [f.kind, f.university]
    );

    link: str = JS.location.origin + "/join/" + joinCode;

    async def submit() -> None {
        error = None;
        busy = True;
        try {
            if step == 1 {
                r: any = await signup("register_employer", "department", JS.Object.assign({}, f, {"timezone": tz}));
                joinCode = r.join_code;
                step = 2;
            } elif step == 2 {
                rs: any = roles;
                parts: any = rs.split(new(JS.RegExp, "[,\\n]"));
                names: list[any] = [x.trim() for x in parts if x.trim()];
                for nm in names {
                    await api("save_position", {"name": nm});
                }
                step = 3;
            } elif not plan {
                trace = None;
                r2: any = await api("generate_needs", {"description": desc});
                trace = [
                    {"agent": "Coordinator", "kind": "agent", "result": "read your description", "status": "done"},
                    {"agent": "Needs Agent", "kind": "agent", "result": "drafted " + str(r2.needs.length) + " weekly blocks", "status": "done", "ai": r2.ai},
                    {"agent": "", "kind": "final", "result": "Staffing plan ready", "status": "done"}
                ];
                plan = r2;
                try {
                    o: any = await api("get_org");
                    roleList = o.positions;
                } except Exception {
                    # roles are optional
                    optional: bool = True;
                }
            } else {
                await api("set_staffing_needs", {"needs": plan.needs});
                await api("run_autopilot");
                toast("Autopilot is live.");
                nav("/d");
            }
        } except Exception as err {
            error = errMsg(err);
        }
        busy = False;
    }

    async def copy(text: str, what: str) -> None {
        try {
            await JS.navigator.clipboard.writeText(text);
            toast(what + " copied.");
        } except Exception {
            toast(text);
        }
    }

    async def share() -> None {
        sdata: any = {"title": "Join " + f.organization + " on CampusSync", "text": "Join " + f.organization + " on CampusSync with code " + joinCode, "url": link};
        if JS.navigator.share {
            try {
                await JS.navigator.share(sdata);
            } except Exception {
                # cancelled
                return;
            }
        } else {
            await copy(link, "Invite link");
        }
    }

    byDay: list[any] = [];
    if plan {
        for (i, d) in enumerate(DAYS) {
            rows: list[any] = [n for n in plan.needs if n.day == i];
            if len(rows) > 0 {
                byDay.append({"d": d, "rows": rows});
            }
        }
    }

    <div className="onboard">
        <Link to="/"><Wordmark /></Link>
        <div className="mt32"><Steps n={step} of={3} /></div>
        <form className="stack g24 mt32" onSubmit={lambda (e: FormEvent) { e.preventDefault(); submit(); }}>
            {step == 1 and <>
                <h1 className="t-display">Put your team <span className="grad-text">on autopilot.</span></h1>
                <div className="card stack g16">
                    <div className="field"><span className="label">What kind of employer?</span>
                        <Segmented full={True} label="Employer type" value={f.kind} onChange={lambda (v: str) { f = JS.Object.assign({}, f, {"kind": v}); }} options={[{"value": "business", "label": "Business"}, {"value": "campus", "label": "Campus employer"}]} />
                        <span className="helper">{"A university department or campus vendor. Students can hold jobs with several campus employers." if f.kind == "campus" else "Security firms, cafés, clinics, stores — any team with shifts."}</span></div>
                    <Field label="Organization name" htmlFor="on" helper={"e.g. Campus Dining" if f.kind == "campus" else "e.g. Shieldpoint Security"}>
                        <input id="on" className="input" required={True} value={f.organization} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"organization": e.target.value}); }} /></Field>
                    {f.kind == "campus" and <Field label="University" htmlFor="uni" helper="Pick yours if it's listed, so students can work across its employers.">
                        <input id="uni" className="input" required={True} list="unis" value={f.university} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"university": e.target.value}); }} />
                        <datalist id="unis">{for u in unis { <option key={u} value={u} /> }}</datalist>
                    </Field>}
                    <Field label="Your name" htmlFor="yn"><input id="yn" className="input" required={True} autoComplete="name" value={f.name} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"name": e.target.value}); }} /></Field>
                    <Field label="Work email" htmlFor="we"><input id="we" className="input" type="email" required={True} autoComplete="email" value={f.email} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"email": e.target.value}); }} /></Field>
                    <Field label="Password" htmlFor="pw" helper="At least 8 characters."><input id="pw" className="input" type="password" required={True} minLength={8} autoComplete="new-password" value={f.password} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"password": e.target.value}); }} /></Field>
                    {tz and <span className="helper">Time zone: {tz} — shift alerts use it. Change it later in Settings.</span>}
                </div>
            </>}
            {step == 2 and <>
                <div className="stack g8"><h1 className="t-display">Your join code <span className="grad-text">is ready.</span></h1>
                    <p className="ink-2">Employees sign up with this code and land on your team. Share the link — it fills the code in for them.</p></div>
                <div className="card stack g16">
                    <div className="join-code-big mono">{joinCode}</div>
                    <div className="row g8 wrap">
                        <button type="button" className="btn" onClick={lambda (e: MouseEvent) { copy(joinCode, "Join code"); }}><Copy size={15} />Copy code</button>
                        <button type="button" className="btn" onClick={lambda (e: MouseEvent) { share(); }}><Share2 size={15} />Share invite link</button>
                    </div>
                    <span className="t-small ink-3 mono" style={{"wordBreak": "break-all"}}>{link}</span>
                </div>
                <div className="card stack g12">
                    <Field label="Roles on your team (optional)" htmlFor="roles" helper="Comma separated, e.g. Site guard, Night patrol. Shifts can require a role; only people with it get scheduled.">
                        <input id="roles" className="input" value={roles} onChange={lambda (e: ChangeEvent) { roles = e.target.value; }} placeholder={"Cashier, Line cook" if f.kind == "campus" else "Site guard, Night patrol"} />
                    </Field>
                    <span className="helper">Everyone starts at $15.00/hr. You can change pay per person on the Team page.</span>
                </div>
            </>}
            {step == 3 and <>
                <div className="stack g8"><h1 className="t-display">Describe a normal week. <span className="grad-text">We'll plan it.</span></h1>
                    <p className="ink-2">One or two sentences. The Needs Agent turns it into staffing blocks; the Scheduling Agent drafts every week for your approval.</p></div>
                <div className="card stack g16">
                    <textarea className="textarea" required={True} value={desc} onChange={lambda (e: ChangeEvent) { desc = e.target.value; plan = None; }}
                        placeholder={"e.g. We're a campus café open 7am to 7pm on weekdays, slammed at lunch, and a smaller crew on Saturdays." if f.kind == "campus" else "e.g. One guard on site 7am to 7pm every day, and a night patrol 6pm to midnight."} />
                    {trace and <AgentPanel trace={trace} title="needs agent · live" />}
                    {plan and <div className="stack g12 slide-in">
                        <div className="w500">{plan.summary}</div>
                        <div className="divided">
                            {for x in byDay {
                                <div key={x["d"]} className="list-row"><span className="mono" style={{"width": 36}}>{x["d"]}</span>
                                    <span className="row g8 wrap">{for (i, r) in enumerate(x["rows"]) { <span key={i} className="chip accent">{hm(r.start)}–{hm(r.end)} · {r.headcount}{(" · " + r.role) if r.role else ""}</span> }}</span></div>
                            }}
                        </div>
                        <Disclosure summary="Adjust by hand"><NeedsEditor needs={plan.needs} onChange={lambda (n: any) { plan = JS.Object.assign({}, plan, {"needs": n}); }} roles={roleList} /></Disclosure>
                    </div>}
                </div>
            </>}
            {error and <div className="c-block" role="alert">{error}</div>}
            <div className="onboard-foot" style={{"alignItems": "center"}}>
                {<Link to="/signin" className="btn">Back</Link> if step == 1 else (<Link to="/d" className="btn text">Skip for now</Link> if step == 3 else <span />)}
                <button className="btn primary lg" disabled={busy or (step == 3 and not desc.strip())}>
                    {("Creating…" if busy else "Create organization") if step == 1 else ("Continue" if step == 2 else ("Launch autopilot" if plan else ("Planning…" if busy else "Build my staffing plan")))}<ArrowRight size={16} />
                </button>
            </div>
        </form>
    </div>
}
