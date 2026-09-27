"""Employee screens: dashboard, Campus AI, requests, request a change, request status, swap offer, availability, profile."""

import from react { useEffect, useRef }
import from "react-router-dom" { Link, useNavigate, useParams, useSearchParams }
import from "lucide-react" { ArrowRight, BriefcaseBusiness, CalendarCheck, Check, ChevronRight, Clock, LogOut, OctagonX, Plus, RefreshCw, Send, Sparkles }
import from web.components.Analytics { WorkAnalytics }
import from web.components.Notifications { NotificationSettings }
import from web.components.AgentPanel { AgentPanel }
import from web.components.CalendarConnect { CalendarConnect }
import from web.components.CommandBar { CopilotCard }
import from web.components.editors { AvailabilityNotes }
import from web.components.grids { LoopDiagram }
import from web.components.shell { signOut, useMe }
import from web.components.ui { Disclosure, ErrorBlock, Modal, Note, PageSkeleton, Privacy, StatusChip, Switch, useToast }
import from web.lib.api { api, errMsg, useWalker }
import from web.lib.time { ago, countdown, dateLabel, DAYS, DAYS_LONG, fmtHours, greeting, money, hmRange, range12, relTime, weekLabel }

glob:pub JS: any = globalThis;
glob:pub SHADES: list[str] = ["#a18bff", "#3dd8f5", "#6c8cff"];
glob:pub EXAMPLES: list[str] = ["I can't do Saturday, Wednesday works", "Dentist Friday 2 to 4", "How many hours do I have left?", "Swap my Tuesday shift for Thursday"];
glob:pub CHIPS: list[str] = ["A different day", "A different time", "I need more hours", "Something else"];
glob:pub SHIFT_BTN: dict[str, any] = {"width": "100%", "background": "transparent", "border": 0, "cursor": "pointer", "textAlign": "left", "color": "inherit"};
glob:pub NOTE_BTN: dict[str, any] = {"cursor": "pointer", "width": "100%", "textAlign": "left", "alignItems": "center"};
glob:pub CARD_PAD: dict[str, any] = {"paddingTop": 4, "paddingBottom": 4};

def:pub PageTitle(title: any, eyebrow: any = None, sub: any = None) -> JsxElement {
    <div className="stack g4">{eyebrow and <span className="eyebrow">{eyebrow}</span>}<h1 className="t-page">{title}</h1>{sub and <span className="ink-2">{sub}</span>}</div>
}

# ---------------- Dashboard ----------------
def:pub StudentHome() -> JsxElement {
    q: any = useWalker("get_student_home", {}, 5000);
    data: any = q["data"];
    error: any = q["error"];
    loading: any = q["loading"];
    reload: any = q["reload"];
    sp: any = useSearchParams();
    params: any = sp[0];
    toast: any = useToast();
    nav: any = useNavigate();
    useEffect(
        lambda -> any {
            if params.get("calendar") == "connected" {
                toast("Google Calendar connected.");
            }
            return JS.undefined;
        },
        [params, toast]
    );
    if loading and not data {
        return <PageSkeleton />;
    }
    if error or not data {
        return <ErrorBlock onRetry={reload} message={error or JS.undefined} />;
    }
    h: any = data.hours;
    atLimit: bool = h.scheduled >= h.limit and data.student.international;
    needs: int = data.offers.length + data.invites.length;
    ns: any = data.next_shift;
    ts: any = data.timesheet;
    barMax: float = JS.Math.max(h.limit, h.scheduled, 1);
    hasOpen: bool = any([not s.worked for s in data.shifts]);
    <div className="stack g20">
        <PageTitle eyebrow={"Week of " + weekLabel(data.week)} title={greeting() + ", " + data.student.first_name} />

        {ns and <section className={"card next-shift " + ("live" if ns.in_progress else "")}>
            <span className="eyebrow">{"On shift now" if ns.in_progress else "Next shift"}</span>
            <div className="when-big">{dateLabel(ns.date, {"weekday": "long", "month": "short", "day": "numeric"})}</div>
            <div className="row between g8 wrap">
                <span className="w500">{range12(ns.start, ns.end)} · {ns.department}{(" · " + ns.role) if ns.role else ""}</span>
                {not ns.in_progress and <span className="chip accent">{relTime(ns.starts_in_seconds)}</span>}
            </div>
        </section>}

        {ts.pending_count > 0 and <button className={"note " + ("wait" if ts.review_today else "neutral") + " row between"} style={NOTE_BTN} onClick={lambda (e: MouseEvent) { nav("/s/time"); }}>
            <span className="row g8"><CalendarCheck size={16} />{"Friday check: " if ts.review_today else ""}{fmtHours(ts.pending_hours)} reported hrs to approve</span><ChevronRight size={16} />
        </button>}
        {needs > 0 and <button className="note wait row between" style={NOTE_BTN} onClick={lambda (e: MouseEvent) { nav("/s/requests"); }}>
            <span className="row g8"><Clock size={16} />{needs} request{"s need" if needs > 1 else " needs"} your answer</span><ChevronRight size={16} />
        </button>}
        {for r in data.requests {
            <Link key={r.request_id} to={"/s/request?id=" + r.request_id} className="collapsed-line">
                <Sparkles size={15} className="c-accent" /><span className="grow">AI is handling a change · {"still searching" if r.state == "searching" else ("waiting on the others" if r.state == "offered" else "waiting for your manager")}</span><ChevronRight size={15} />
            </Link>
        }}

        <section className="card stack g16">
            <span className="mono ink-2">This week</span>
            <div className="row g8" style={{"alignItems": "baseline"}}>
                <span className="hero-num">{fmtHours(h.scheduled)}{(" / " + str(h.limit)) if data.student.international else ""}</span>
                <span className="ink-2" style={{"fontSize": 16}}>hrs scheduled</span>
            </div>
            <div className="seg-bar" role="img" aria-label={str(h.scheduled) + " of " + str(h.limit) + " hours scheduled"}>
                {for (i, j) in enumerate(h.by_job) {
                    <span key={j.department} style={{"width": str((j.hours / barMax) * 100) + "%", "background": SHADES[i % 3]}} />
                }}
            </div>
            {h.by_job.length > 1 and <div className="row g16 wrap legend-sq ink-2" style={{"fontSize": 14}}>
                {for (i, j) in enumerate(h.by_job) {
                    <span key={j.department}><i style={{"background": SHADES[i % 3]}} />{j.department} {fmtHours(j.hours)}</span>
                }}
            </div>}
            <div className="row between wrap g8">
                {<span className="row g8 c-block" style={{"fontSize": 14}}><OctagonX size={16} />At your 20 hr international limit.</span>
                    if atLimit else <span className="ink-2" style={{"fontSize": 14}}>{("International limit · " + fmtHours(h.left) + " hrs left") if data.student.international else (str(data.shifts.length) + " shift" + ("" if data.shifts.length == 1 else "s"))}</span>}
                {data.pay.projected_gross > 0 and <span className="ink-2" style={{"fontSize": 14}}>≈ {money(data.pay.projected_gross, False)} gross</span>}
            </div>
        </section>

        <section className="stack g12">
            <h2 className="t-section">This week</h2>
            {<div className="card ink-2">No shifts this week yet. Your employer's schedule shows up here once it's published.</div> if data.shifts.length == 0 else <div className="card" style={CARD_PAD}>
                {for s in data.shifts {
                    <div key={s.id} className="shift-row">
                        <div className="grow"><div className="when"><span className="nowrap">{DAYS[s.day]} {dateLabel(s.date, {"month": "short", "day": "numeric"})}</span>{" "}<span className="nowrap">· {hmRange(s.start, s.end)}</span></div>
                            <div className="where">{s.department}{(" · " + s.role) if s.role else ""}</div></div>
                        {<StatusChip kind="neutral">Worked</StatusChip> if s.worked else (<StatusChip kind="wait">Swap pending</StatusChip> if s.state == "pending_swap" else <StatusChip kind="ok">Confirmed</StatusChip>)}
                    </div>
                }}
            </div>}
        </section>

        <div className="two-btn">
            <button className="btn primary lg" onClick={lambda (e: MouseEvent) { nav("/s/request/new"); }} disabled={not hasOpen}>Request a change</button>
            <button className="btn lg" onClick={lambda (e: MouseEvent) { nav("/s/availability"); }}>Availability</button>
        </div>
        <OpenShifts onTaken={lambda { reload(True); }} />

        <section className="stack g12">
            <h2 className="t-section">Your jobs</h2>
            <div className="card" style={CARD_PAD}>
                {data.jobs.length == 0 and <div className="shift-row ink-2">No jobs yet. Join an employer from your profile with their join code.</div>}
                {for j in data.jobs {
                    <div key={j.department_id} className="shift-row">
                        <div className="grow"><div style={{"fontSize": 16, "fontWeight": 500}}>{j.department}</div>
                            <div className="where">{(", ".join(j.roles) + " · ") if j.roles.length else ""}{money(j.pay_rate)}/hr</div></div>
                        <span className="chip">Active</span>
                    </div>
                }}
            </div>
        </section>
    </div>
}

def:pub OpenShifts(onTaken: any) -> JsxElement {
    q: any = useWalker("get_open_shifts", {}, 8000);
    data: any = q["data"];
    reload: any = q["reload"];
    toast: any = useToast();

    async def take(sid: any) -> None {
        try {
            await api("claim_open_shift", {"shift_id": sid});
            toast("It's yours.");
            reload(True);
            onTaken();
        } except Exception as e {
            toast(errMsg(e), False);
            reload(True);
        }
    }

    if not data or not data.shifts.length {
        return <></>;
    }
    <section className="stack g12"><h2 className="t-section">Open shifts you can take</h2>
        <div className="card" style={CARD_PAD}>{for s in data.shifts {
            <div key={s.id} className="shift-row"><div className="grow"><div className="when">{DAYS[s.day]} {hmRange(s.start, s.end)}</div><div className="where">{s.department}</div></div>
                <button className="btn sm" onClick={lambda (e: MouseEvent) { take(s.id); }}>Take it</button></div>
        }}</div>
    </section>
}

# ---------------- Campus AI ----------------
def:pub CampusAI() -> JsxElement {
    home: any = useWalker("get_student_home", {}, 6000);
    avail: any = useWalker("get_availability");
    has msgs: list[any] = [];
    has text: str = "";
    has busy: bool = False;
    has syncing: bool = False;
    endRef: any = useRef(None);
    toast: any = useToast();
    me: any = useMe();
    useEffect(
        lambda -> any {
            if endRef.current {
                endRef.current.scrollIntoView({"behavior": "smooth", "block": "end"});
            }
            return JS.undefined;
        },
        [msgs, busy]
    );
    d: any = home["data"];
    ad: any = avail["data"];
    autopilot: bool = True;
    if ad and ad.profile and ad.profile.autopilot != None {
        autopilot = ad.profile.autopilot;
    } elif d and d.student.autopilot != None {
        autopilot = d.student.autopilot;
    }

    async def send(t: str) -> None {
        if not t.strip() or busy {
            return;
        }
        msgs = msgs + [{"id": JS.Date.now(), "me": True, "text": t}];
        text = "";
        busy = True;
        try {
            r: any = await api("student_command", {"text": t});
            msgs = msgs + [{"id": JS.Date.now() + 1, "me": False, "text": r.reply, "trace": r.trace, "card": r.card}];
            home["reload"](True);
        } except Exception as e {
            msgs = msgs + [{"id": JS.Date.now() + 1, "me": False, "text": errMsg(e)}];
        }
        busy = False;
    }

    async def setAuto(v: bool) -> None {
        await api("update_profile", {"autopilot": v});
        avail["reload"](True);
        toast("Autopilot is on." if v else "Autopilot is off — you'll be asked about every change.");
    }

    async def sync() -> None {
        syncing = True;
        try {
            await api("sync_calendar");
            toast("Calendar synced.");
            home["reload"](True);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        syncing = False;
    }

    worker: bool = bool(me and me.student and me.student.kind == "worker");
    connected: bool = bool(d and d.calendar.connected);
    calText: str = "No calendar connected";
    if connected {
        calText = d.calendar.label + " · synced " + (ago(d.calendar.synced_seconds_ago) if d.calendar.synced_seconds_ago != None else "just now");
    }
    firstName: any = None;
    if d {
        firstName = d.student.first_name;
    }
    <div className="stack g16">
        <PageTitle eyebrow={"Assistant" if worker else "Campus AI"} title="Your scheduling assistant" />
        <section className="card stack g12">
            <div className="row g12">
                <span className="icon-tile"><Sparkles size={18} /></span>
                <div className="grow stack"><span className="w600">Autopilot</span><span className="ink-2 t-small">{"Handling swaps and invites that fit your preferences" if autopilot else "Off — you'll be asked about every change"}</span></div>
                <Switch checked={autopilot} onChange={lambda (v: bool) { setAuto(v); }} label="Autopilot" />
            </div>
            <div className="row g12 hairline-top" style={{"paddingTop": 12}}>
                <span className="grow ink-2 t-small">{calText}</span>
                {<button className="btn sm" disabled={syncing} onClick={lambda (e: MouseEvent) { sync(); }}><RefreshCw size={14} />Sync</button> if connected else <Link to="/s/availability" className="btn sm primary">Connect</Link>}
            </div>
        </section>

        <div className="chat">
            {len(msgs) == 0 and <div className="bubble ai">Hi {firstName if firstName != None else "there"} — tell me what changed and I'll handle it. I check every job's limits before anything moves, and your manager approves.</div>}
            {for m in msgs {
                if m.me {
                    <div key={m.id} className="bubble me">{m.text}</div>
                } else {
                    <div key={m.id} className="stack g8" style={{"alignSelf": "stretch"}}>
                        <div className="bubble ai">{m.text}</div>
                        {m.trace and m.trace.length > 1 and <Disclosure summary="How I did it"><AgentPanel trace={m.trace} replay={False} title="agents" /></Disclosure>}
                        {m.card and <CopilotCard card={m.card} />}
                    </div>
                }
            }}
            {busy and <AgentPanel trace={None} pending={True} title="agents · working" />}
            <div ref={endRef} />
        </div>

        <div className="composer stack g8">
            {len(msgs) == 0 and <div className="suggest">{for x in EXAMPLES {
                <button key={x} onClick={lambda (e: MouseEvent) { send(x); }}>{x}</button>
            }}</div>}
            <form onSubmit={lambda (e: FormEvent) { e.preventDefault(); send(text); }} className="row g8">
                <input className="input" placeholder="Tell Campus AI what changed…" value={text} onChange={lambda (e: ChangeEvent) { text = e.target.value; }} aria-label="Message Campus AI" />
                <button className="btn primary icon" aria-label="Send" disabled={busy or not text.strip()}><Send size={16} /></button>
            </form>
        </div>
    </div>
}

# ---------------- Requests ----------------
def _what(o: any) -> str {
    if o.gets and o.gives {
        return "Take " + o.gets + ", give up " + o.gives;
    }
    if o.gets {
        return "Take " + o.gets;
    }
    return "Hand off " + o.gives;
}

def _pastChip(o: any) -> JsxElement {
    if o.loop_state == "committed" {
        return <StatusChip kind="ok">Confirmed</StatusChip>;
    }
    if o.state == "accepted" {
        return <StatusChip kind="wait">{"Autopilot said yes" if o.auto else "You said yes"}</StatusChip>;
    }
    if o.state == "declined" {
        return <StatusChip kind="block">Declined</StatusChip>;
    }
    return <StatusChip kind="neutral">Closed</StatusChip>;
}

def:pub StudentRequests() -> JsxElement {
    q: any = useWalker("get_student_inbox", {}, 4000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    has invite: any = None;
    nav: any = useNavigate();
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }
    openOffers: list[any] = [o for o in data.offers if o.state == "waiting" and o.loop_state == "approved"];
    past: list[any] = [o for o in data.offers if not (o.state == "waiting" and o.loop_state == "approved")];
    <div className="stack g20">
        <PageTitle eyebrow="Requests" title="Requests" sub="Swaps and job offers that need you, and the changes you asked for." />

        <section className="stack g12">
            <h2 className="t-section">Needs your answer</h2>
            {<div className="card ink-2 row g8"><Check size={16} className="c-ok" />Nothing needs you right now.</div> if len(openOffers) + data.invites.length == 0 else <div className="card" style={CARD_PAD}>
                {for o in openOffers {
                    <button key={o.offer_id} className="shift-row" style={SHIFT_BTN} onClick={lambda (e: MouseEvent) { nav("/s/offer/" + o.offer_id); }}>
                        <div className="grow"><div className="w600">Swap offer · {o.size}-person {"hand-off" if o.kind == "handoff" else "loop"}</div><div className="where">{_what(o)} · {o.department}</div>
                            <div className="mono ink-3 mt4">Expires in {countdown(o.expires_in_seconds)}</div></div>
                        <span className="btn sm primary">Review</span>
                    </button>
                }}
                {for i in data.invites {
                    inv: any = i;
                    <div key={i.employment_id} className="shift-row">
                        <div className="grow"><div className="w600">Job offer · {i.department}</div><div className="where">{i.hours} hrs/week</div></div>
                        <button className="btn sm primary" onClick={lambda (e: MouseEvent) { invite = inv; }}>Review</button>
                    </div>
                }}
            </div>}
        </section>

        <section className="stack g12">
            <h2 className="t-section">Your requests</h2>
            {<div className="card ink-2">No requests yet. Use <b>Request a change</b> on your dashboard, or just tell Campus AI.</div> if data.requests.length == 0 else <div className="card" style={CARD_PAD}>
                {for r in data.requests {
                    <Link key={r.request_id} to={"/s/request?id=" + r.request_id} className="shift-row" style={{"color": "inherit"}}>
                        <div className="grow"><div className="when" style={{"fontSize": 14}}>{r.shift}</div><div className="where">{"From your calendar" if r.origin == "calendar" else "Looking for"}: {r.want}</div></div>
                        {<StatusChip kind="wait">Waiting</StatusChip> if r.chip == "waiting" else (<StatusChip kind="ok">Done</StatusChip> if r.chip == "confirmed" else (<StatusChip kind="block">Not approved</StatusChip> if r.chip == "blocked" else <StatusChip kind="neutral">{"Cancelled" if r.state == "cancelled" else "Searching"}</StatusChip>))}
                    </Link>
                }}
            </div>}
        </section>

        {len(past) > 0 and <section className="stack g12">
            <h2 className="t-section">History</h2>
            <div className="card" style={CARD_PAD}>
                {for o in past {
                    <Link key={o.offer_id} to={"/s/offer/" + o.offer_id} className="shift-row" style={{"color": "inherit"}}>
                        <div className="grow"><div style={{"fontSize": 14}}>{_what(o)}</div><div className="where">{o.department} · {ago(o.seconds_ago)}</div></div>{_pastChip(o)}
                    </Link>
                }}
            </div>
        </section>}
        {invite and <InviteModal invite={invite} onClose={lambda { invite = None; }} onDone={lambda { invite = None; reload(True); }} />}
    </div>
}

def:pub InviteModal(invite: any, onClose: any, onDone: any) -> JsxElement {
    toast: any = useToast();
    has busy: bool = False;

    async def respond(accept: bool) -> None {
        busy = True;
        try {
            r: any = await api("respond_invite", {"employment_id": invite.employment_id, "accept": accept});
            toast(("You've joined " + r.department + ".") if accept else "Invite declined.");
            onDone();
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }

    <Modal onClose={onClose} label="Job offer" sheet={True}>
        <div className="stack g16">
            <h2 className="t-section">{invite.department} wants to add you</h2>
            <div className="t-display c-accent">{invite.hours} hours a week</div>
            <p className="ink-2">They'll be able to schedule you for up to {invite.hours} hours a week — never over your weekly limit.</p>
            <Privacy>They won't see your classes or your other jobs — only whether you're free.</Privacy>
            <div className="row g8 end mt8"><button className="btn" disabled={busy} onClick={lambda (e: MouseEvent) { respond(False); }}>Decline</button><button className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { respond(True); }}>Accept</button></div>
        </div>
    </Modal>
}

# ---------------- Request a change (3 taps) ----------------
def:pub RequestChange() -> JsxElement {
    home: any = useWalker("get_student_home");
    has step: int = 1;
    has shift: any = None;
    has want: str = "days";
    has days: list[int] = [];
    has reason: str = "";
    has busy: bool = False;
    nav: any = useNavigate();
    toast: any = useToast();
    hd: any = home["data"];
    if not hd {
        return <PageSkeleton />;
    }
    shifts: list[any] = [s for s in hd.shifts if s.state != "pending_swap"];

    async def send() -> None {
        if not shift {
            return;
        }
        busy = True;
        try {
            r: any = await api("request_swap", {"shift_id": shift.id, "want_kind": want, "want_days": days, "reason": reason});
            nav("/s/request?id=" + r.request_id, {"replace": True});
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }

    def toggle(i: int) -> None {
        if i in days {
            days = [x for x in days if x != i];
        } else {
            days = days + [i];
        }
    }

    def pickShift(s: any) -> any {
        return lambda (e: MouseEvent) {
            shift = s;
            step = 2;
        };
    }

    def dayKey(i: int) -> any {
        return lambda (e: KeyboardEvent) {
            if e.key == "Enter" or e.key == " " {
                toggle(i);
            }
        };
    }

    wantText: str = "";
    if want == "give_up" {
        wantText = "someone else takes it";
    } elif want == "any" {
        wantText = "any other time this week";
    } else {
        wantText = "looking for " + ", ".join([DAYS_LONG[x] for x in days]);
    }

    <div className="stack g20">
        <div className="row between"><span className="progress-text">{step} of 3</span>
            {<button className="btn text sm" onClick={lambda (e: MouseEvent) { step = step - 1; }}>Back</button> if step > 1 else <Link to="/s" className="btn text sm">Cancel</Link>}</div>
        {step == 1 and <>
            <h1 className="t-page">Which shift?</h1>
            <div className="card" style={CARD_PAD}>
                {len(shifts) == 0 and <div className="shift-row ink-2">No shifts you can change this week.</div>}
                {for s in shifts {
                    <button key={s.id} className="shift-row" style={SHIFT_BTN} onClick={pickShift(s)}>
                        <div className="grow"><div className="when">{DAYS[s.day]} {hmRange(s.start, s.end)}</div><div className="where">{s.department}</div></div><ChevronRight size={16} className="ink-3" />
                    </button>
                }}
            </div>
        </>}
        {step == 2 and <>
            <h1 className="t-page">What would you like instead?</h1>
            <div className="stack g8" role="radiogroup">
                <button type="button" role="radio" aria-checked={want == "days"} className="radio-card" onClick={lambda (e: MouseEvent) { want = "days"; }}>
                    <span className="radio-dot" /><span className="grow stack g12"><span className="w500">A different day</span>
                        {want == "days" and <span className="row g8 wrap" onClick={lambda (e: MouseEvent) { e.stopPropagation(); }}>{for (i, dn) in enumerate(DAYS) {
                            <span key={dn} role="button" tabIndex={0} className="choice" aria-pressed={i in days} onClick={lambda (e: MouseEvent) { toggle(i); }}
                                onKeyDown={dayKey(i)}>{dn}</span>
                        }}</span>}
                    </span>
                </button>
                <button type="button" role="radio" aria-checked={want == "any"} className="radio-card" onClick={lambda (e: MouseEvent) { want = "any"; }}><span className="radio-dot" /><span className="w500">Any other time this week</span></button>
                <button type="button" role="radio" aria-checked={want == "give_up"} className="radio-card" onClick={lambda (e: MouseEvent) { want = "give_up"; }}>
                    <span className="radio-dot" /><span className="stack g4"><span className="w500">Just give it up</span><span className="ink-2 t-small">Someone else takes it. Your hours go down.</span></span></button>
            </div>
            <input className="input" placeholder="Reason (only your manager sees this)" value={reason} onChange={lambda (e: ChangeEvent) { reason = e.target.value; }} aria-label="Reason" />
            <button className="btn primary lg" disabled={want == "days" and len(days) == 0} onClick={lambda (e: MouseEvent) { step = 3; }}>Continue</button>
        </>}
        {step == 3 and shift and <>
            <h1 className="t-page">Review</h1>
            <div className="card stack g8">
                <div className="when" style={{"fontFamily": "var(--mono)", "fontWeight": 600}}>{DAYS[shift.day]} {hmRange(shift.start, shift.end)}</div>
                <div className="ink-2">{shift.department} · {wantText}</div>
            </div>
            <p className="ink-2">Campus AI searches direct swaps and 3–4 person loops, checks every limit, then sends it to your manager.</p>
            <button className="btn primary lg" disabled={busy} onClick={lambda (e: MouseEvent) { send(); }}>{"Sending…" if busy else "Send request"}</button>
        </>}
    </div>
}

# ---------------- Request status ----------------
def:pub RequestStatus() -> JsxElement {
    sp: any = useSearchParams();
    params: any = sp[0];
    rid: str = params.get("id") or "";
    q: any = useWalker("get_my_request", {"request_id": rid}, 3000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    has replayed: bool = False;
    nav: any = useNavigate();
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }
    chip: any = None;
    if data.chip == "waiting" {
        chip = <StatusChip kind="wait">Waiting</StatusChip>;
    } elif data.chip == "confirmed" {
        chip = <StatusChip kind="ok">Confirmed</StatusChip>;
    } elif data.chip == "blocked" {
        chip = <StatusChip kind="block">Not approved</StatusChip>;
    } else {
        chip = <StatusChip kind="neutral">Searching</StatusChip>;
    }
    <div className="stack g20">
        <div className="row between"><PageTitle eyebrow="Request" title={data.shift} /><Link to="/s/requests" className="btn text sm">Done</Link></div>
        <div className="ink-2">{data.department} · looking for: {data.want}</div>
        <AgentPanel trace={data.trace} onDone={lambda { replayed = True; }} title="campus ai · live" />
        {replayed and <div className="card stack g12 slide-in">
            <div className="row between g12"><span className="t-card">{data.message}</span>{chip}</div>
            {data.offer and data.offer.state == "waiting" and <button className="btn primary" onClick={lambda (e: MouseEvent) { nav("/s/offer/" + data.offer.offer_id); }}>Review your offer</button>}
        </div>}
    </div>
}

# ---------------- Swap offer ----------------
def:pub SwapOffer() -> JsxElement {
    p: any = useParams();
    oid: str = p["id"] or "";
    q: any = useWalker("get_offer", {"offer_id": oid}, 3000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    setData: any = q["setData"];
    me: any = useMe();
    has declining: bool = False;
    has chip: str = "";
    has text: str = "";
    has busy: bool = False;
    has prev: any = None;
    toast: any = useToast();
    status: any = data.status if data else JS.undefined;
    useEffect(
        lambda -> any {
            if data and prev and prev != "confirmed" and data.status == "confirmed" {
                toast("Your swap is confirmed. " + (data.gets_day if data.gets_day != None else "Your schedule") + " is yours.");
            }
            if data {
                prev = data.status;
            }
            return JS.undefined;
        },
        [status]
    );
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }

    async def respond(accept: bool, withReason: bool) -> None {
        busy = True;
        try {
            r: any = await api("respond_offer", {"offer_id": data.offer_id, "accept": accept, "reason_chip": chip if withReason else "", "reason_text": text if withReason else ""});
            setData(r);
            declining = False;
            if not accept {
                toast("Declined. Campus AI is already re-planning.");
            }
        } except Exception as e {
            toast(errMsg(e), False);
            reload();
        }
        busy = False;
    }

    title: any = None;
    if data.gets and data.gives {
        title = <>Take <span className="c-accent">{data.gets}</span>, give up {data.gives}?</>;
    } elif data.gets {
        title = <>Take <span className="c-accent">{data.gets}</span>?</>;
    } else {
        title = <>Give up {data.gives}?</>;
    }
    moves: list[any] = [{"name": c.name, "gives": None, "gets": c.gets} for c in data.circle];
    hl: any = JS.undefined;
    if me and me.student {
        hl = me.student.first_name;
    }
    live: bool = data.state == "waiting" and data.status != "closed";
    <div className="stack g20">
        {data.status == "confirmed" and <Note kind="ok">Your swap is confirmed. {(data.gets_day + " is yours.") if data.gets_day else "The shift is off your schedule."}</Note>}
        {data.status == "closed" and <Note kind="neutral">This swap didn't go ahead — nothing changed on your schedule.</Note>}
        <span className="eyebrow">Swap offer · {data.department}</span>
        <h1 className="t-page" style={{"lineHeight": 1.25}}>{title}</h1>
        <div className="card" style={CARD_PAD}>
            {data.gets and <div className="shift-row"><Check size={16} className="c-ok" /><span className="grow"><span className="ink-2">You get </span>{data.gets}</span></div>}
            {data.gives and <div className="shift-row"><ArrowRight size={16} className="ink-3" /><span className="grow"><span className="ink-2">You give up </span>{data.gives}</span></div>}
            <div className="shift-row"><Clock size={16} className="ink-3" /><span className="grow ink-2">{<>Your hours stay at <b>{fmtHours(data.hours_after)}</b></> if data.hours_before == data.hours_after else <>Your hours go from {fmtHours(data.hours_before)} to <b>{fmtHours(data.hours_after)}</b></>}</span></div>
        </div>
        <section className="card stack g8">
            <LoopDiagram moves={moves} highlight={hl} />
            <div className="ink-2" style={{"textAlign": "center"}}>{data.others} {"other is" if data.others == 1 else "others are"} in this loop · {data.others_accepted} already said yes</div>
        </section>
        {live and <div className="mono ink-3">Expires in {countdown(data.expires_in_seconds)}</div>}
        <Disclosure summary="Why this swap?"><p className="ink-2">{data.rationale}</p></Disclosure>
        {live and <div className="row g8"><button className="btn lg grow" onClick={lambda (e: MouseEvent) { declining = True; }}>Decline</button><button className="btn primary lg grow" disabled={busy} onClick={lambda (e: MouseEvent) { respond(True, True); }}>Accept</button></div>}
        {data.state == "accepted" and data.status not in ["confirmed", "closed"] and <div className="card row between g12"><span>You're in. We'll confirm once everyone says yes.</span><StatusChip kind="wait">Waiting</StatusChip></div>}
        {data.state == "declined" and <div className="card row between g12"><span>You declined this swap.</span><StatusChip kind="block">Declined</StatusChip></div>}
        {declining and <Modal onClose={lambda { declining = False; }} label="Decline swap" sheet={True}>
            <div className="stack g16">
                <h2 className="t-section">No problem. What would have made this work?</h2>
                <div className="row g8 wrap">{for c in CHIPS {
                    cc: str = c;
                    <button key={c} type="button" className="choice" aria-pressed={chip == c} onClick={lambda (e: MouseEvent) { chip = "" if chip == cc else cc; }}>{c}</button>
                }}</div>
                <input className="input" placeholder="Anything else? (optional)" value={text} onChange={lambda (e: ChangeEvent) { text = e.target.value; }} aria-label="Reason" />
                <div className="helper">Your answer goes straight into Campus AI's next attempt.</div>
                <div className="row between g8 wrap"><button className="btn text" disabled={busy} onClick={lambda (e: MouseEvent) { respond(False, False); }}>Decline without a reason</button><button className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { respond(False, True); }}>Decline</button></div>
            </div>
        </Modal>}
    </div>
}

# ---------------- Update availability ----------------
def:pub UpdateAvailability() -> JsxElement {
    nav: any = useNavigate();
    <div className="stack g20">
        <PageTitle eyebrow="Availability" title="Update availability" sub="Connect your calendar once — Campus AI keeps it in sync and moves shifts when something clashes." />
        <section className="card stack g12"><h2 className="t-section">Calendar</h2><CalendarConnect next="/s/availability" /></section>
        <section className="card stack g12"><h2 className="t-section">Standing rules</h2><AvailabilityNotes /></section>
        <button className="btn primary lg" onClick={lambda (e: MouseEvent) { nav("/s"); }}>Done</button>
    </div>
}

# ---------------- Profile ----------------
def:pub StudentProfile() -> JsxElement {
    me: any = useMe();
    q: any = useWalker("get_availability");
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    nav: any = useNavigate();
    toast: any = useToast();
    has p: any = None;
    sp: any = useSearchParams();
    params: any = sp[0];
    useEffect(
        lambda -> any {
            if data {
                p = data.profile;
            }
            return JS.undefined;
        },
        [data]
    );
    useEffect(
        lambda -> any {
            c: any = params.get("calendar");
            if c == "connected" {
                toast("Google Calendar connected.");
            } elif c == "error" or c == "unavailable" {
                toast(params.get("message") or "Google sign-in isn't set up on this server — use a calendar link instead.", False);
            }
            return JS.undefined;
        },
        [params, toast]
    );
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data or not p or not me {
        return <PageSkeleton />;
    }

    async def save(patch: any) -> None {
        p = JS.Object.assign({}, p, patch);
        try {
            await api("update_profile", patch);
        } except Exception as e {
            toast(errMsg(e), False);
        }
    }

    def swapDayClick(di: int) -> any {
        return lambda (e: MouseEvent) {
            cur: list[int] = p.open_swap_days or [];
            save({"open_swap_days": [x for x in cur if x != di] if di in cur else cur + [di]});
        };
    }

    cal: any = data.calendar;
    st: any = me.student;
    sub: str = "";
    if st and st.kind == "worker" {
        sub = "Employee";
    } else {
        sub = ("International student · limit 20 hrs/week" if p.international else "Student employee") + ((" · " + st.university) if st and st.university else "");
    }
    calText: str = "Not connected";
    if cal.connected {
        calText = cal.label + ((" · " + cal.account) if cal.account else "") + " · synced " + (ago(cal.synced_seconds_ago) if cal.synced_seconds_ago != None else "just now");
    }
    swapDays: any = p.open_swap_days;
    <div className="stack g20">
        <PageTitle eyebrow="Profile" title={me.name} sub={sub} />

        <WorkAnalytics />

        <Jobs />

        <section className="card"><NotificationSettings /></section>

        <section className="card stack g16">
            <div className="row g16 between">
                <div className="stack g4"><span className="t-card" style={{"fontSize": 17}}>Autopilot</span><span className="ink-2 t-small">Says yes to swaps into your open days and to open shifts that fit your hours.</span></div>
                <Switch checked={p.autopilot} onChange={lambda (v: bool) { save({"autopilot": v}); }} label="Autopilot" />
            </div>
            <div className="field"><span className="label">Days you'd happily swap into</span>
                <div className="row g8 wrap">{for (i, dn) in enumerate(DAYS) {
                    <button key={dn} className="choice" aria-pressed={i in swapDays} onClick={swapDayClick(i)}>{dn}</button>
                }}</div></div>
        </section>

        <Link to="/s/availability" className="card row g12" style={{"color": "inherit"}}>
            <div className="grow stack g4"><span className="t-card" style={{"fontSize": 17}}>Calendar & availability</span>
                <span className="ink-2 t-small">{calText}</span>
                {cal.error and <span className="t-small c-block">{cal.error}</span>}</div>
            <ChevronRight size={18} className="ink-3" />
        </Link>

        <button className="btn lg" onClick={lambda (e: MouseEvent) { signOut(nav); }}><LogOut size={16} />Sign out</button>
    </div>
}

glob:pub CODE_JUNK: any = new(JS.RegExp, "[^A-Z0-9]", "g");

def:pub Jobs() -> JsxElement {
    q: any = useWalker("get_my_employers");
    data: any = q["data"];
    reload: any = q["reload"];
    has code: str = "";
    has adding: bool = False;
    has busy: bool = False;
    has leaving: any = None;
    toast: any = useToast();

    async def join() -> None {
        busy = True;
        try {
            r: any = await api("join_employer", {"code": code});
            toast("You joined " + r.employer.name + ".");
            code = "";
            adding = False;
            reload(True);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }

    async def leave() -> None {
        lv: any = leaving;
        if not lv {
            return;
        }
        busy = True;
        try {
            r: any = await api("leave_employer", {"department_id": lv.id});
            extra: str = "";
            if r.released {
                extra = " " + str(r.released) + " upcoming shift" + ("s were" if r.released > 1 else " was") + " released.";
            }
            toast("You left " + lv.name + "." + extra);
            leaving = None;
            reload(True);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }

    if not data {
        return <></>;
    }
    cleanLen: int = JS.String.prototype.replace.call(code, CODE_JUNK, "").length;
    <section className="card stack g12">
        <div className="row between"><span className="t-card" style={{"fontSize": 17}}>Your employers</span>
            {data.can_join_more and not adding and <button className="btn sm" onClick={lambda (e: MouseEvent) { adding = True; }}><Plus size={14} />Join with a code</button>}</div>
        <div className="divided">
            {data.employers.length == 0 and <div className="list-row ink-2">You're not on a team yet.</div>}
            {for emp in data.employers {
                em: any = emp;
                <div key={emp.id} className="list-row">
                    <span className="icon-tile" style={{"width": 34, "height": 34}}><BriefcaseBusiness size={16} /></span>
                    <div className="grow stack"><span className="w600">{emp.name}</span>
                        <span className="t-small ink-3">{(", ".join(emp.roles) + " · ") if emp.roles.length else ""}{money(emp.pay_rate)}/hr · up to {emp.hours} hrs/week</span></div>
                    {<StatusChip kind="wait">Invited</StatusChip> if emp.state == "invited" else <button className="btn sm text" onClick={lambda (e: MouseEvent) { leaving = em; }}>Leave</button>}
                </div>
            }}
        </div>
        {adding and <div className="stack g8 slide-in">
            <div className="row g8"><input className="input mono" placeholder="JOIN-CODE" value={code} autoFocus={True} onChange={lambda (e: ChangeEvent) { code = e.target.value.upper(); }} aria-label="Join code" />
                <button className="btn primary" disabled={busy or cleanLen < 6} onClick={lambda (e: MouseEvent) { join(); }}>Join</button>
                <button className="btn text" onClick={lambda (e: MouseEvent) { adding = False; }}>Cancel</button></div>
            <span className="helper">{("Student employees can work for several employers" + ((" at " + data.university) if data.university else "") + ".") if data.kind == "student" else "Regular employees belong to one employer at a time."}</span>
        </div>}
        {not data.can_join_more and <span className="helper">Regular employees belong to one employer at a time. Leave your current employer to join another.</span>}
        {leaving and <Modal onClose={lambda { leaving = None; }} label="Leave employer" sheet={True}>
            <div className="stack g16">
                <h2 className="t-section">Leave {leaving.name}?</h2>
                <p className="ink-2">Your upcoming shifts there will be released to your team. Hours you already worked stay on your timesheet.</p>
                <div className="row g8 end"><button className="btn" onClick={lambda (e: MouseEvent) { leaving = None; }}>Stay</button><button className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { leave(); }}>Leave</button></div>
            </div>
        </Modal>}
    </section>
}
