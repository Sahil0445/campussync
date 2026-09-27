"""Employer pages: dashboard, approvals, schedule, draft review, swap approval, team & roles, settings."""

import from react { useEffect, useRef }
import from "react-router-dom" { Link, useNavigate, useParams, useSearchParams }
import from "lucide-react" { ArrowRight, CalendarCheck, Check, ChevronLeft, Clock, Copy, Inbox, OctagonX, Pencil, Plus, Repeat, Share2, Sparkles, Trash2, UserMinus, UserPlus, X }
import from web.components.Notifications { NotificationSettings }
import from web.components.AgentPanel { AgentPanel }
import from web.components.AgentOrbit { AgentOrbit }
import from web.components.CommandBar { CopilotCard }
import from web.components.editors { NeedsEditor }
import from web.components.grids { LoopDiagram }
import from web.components.WeekCalendar { WeekCalendar }
import from web.components.LiveFeed { useAgentFeed }
import from web.components.ui { CloseButton, CountUp, Disclosure, Drawer, ErrorBlock, Field, Modal, PageSkeleton, Privacy, Ring, SearchInput, StatusChip, Stepper, Switch, useToast }
import from web.lib.api { api, errMsg, useWalker }
import from web.lib.time { ago, fmtHours, money, mondayOf, shiftWeek, slot, weekLabel }
import from web.components.shell { useMe }

glob:pub JS: any = globalThis;

# An approval: {type: draft|swap|recruit, id, request_id?, agent, link, title, detail, risk, status?}

# ---------------- approvals ----------------
glob:pub TYPE_ICON: dict[str, any] = {"draft": CalendarCheck, "swap": Repeat, "recruit": UserPlus};

def:pub ApprovalItem(a: any, onDone: any) -> JsxElement {
    has busy: bool = False;
    nav: any = useNavigate();
    toast: any = useToast();
    Icon: any = TYPE_ICON[a.type];
    async def decide(approve: bool) -> None {
        busy = True;
        try {
            r: any = await api("decide", {"type": a.type, "id": a.id, "approve": approve});
            if a.type == "draft" and approve {
                toast("Published. " + str(r.notified or 0) + " " + ("person" if r.notified == 1 else "people") + " notified.");
            } elif a.type == "recruit" and approve {
                toast("Invite sent — their autopilot will answer.");
            } elif a.type == "swap" and approve {
                toast("Approved. Offers sent — autopilots answer instantly.");
            } else {
                toast("Done.");
            }
            onDone();
            if a.type == "swap" and approve {
                nav(a.link);
            }
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }
    yesLabel: str = "Approve & publish" if a.type == "draft" else ("Invite" if a.type == "recruit" else "Approve");
    <div className="approval">
        <span className="ic"><@{Icon} size={18} /></span>
        <div className="grow">
            <div className="row g8 wrap"><span className="title">{a.title}</span></div>
            <div className="detail">{a.detail}</div>
            <div className="feed-meta mt4"><span style={{"color": "#b9c1ff"}}>{a.agent}</span><span>· rules checked</span></div>
        </div>
        <div className="acts">
            {<button className="btn sm ghost" disabled={busy} onClick={lambda (e: MouseEvent) { decide(False); }}>Skip</button> if a.type == "recruit" else <button className="btn sm ghost" disabled={busy} onClick={lambda (e: MouseEvent) { nav(a.link); }}>Review</button>}
            <button className="btn sm primary" disabled={busy} onClick={lambda (e: MouseEvent) { decide(True); }}>{yesLabel}</button>
        </div>
    </div>
}

def:pub ApprovalList(items: any, onDone: any, limit: int = 99) -> JsxElement {
    if not items.length {
        return <div className="empty-state"><span className="icon-tile"><Check size={18} /></span><span>Nothing needs you. Autopilot has it.</span></div>;
    }
    <div className="stack g8">{for a in items.slice(0, limit) { <ApprovalItem key={a.type + "-" + str(a.id)} a={a} onDone={onDone} /> }}</div>
}

# ---------------- Dashboard ----------------
def:pub MissionControl() -> JsxElement {
    q: any = useWalker("get_dashboard", {}, 4000);
    data: any = q["data"];
    error: any = q["error"];
    loading: any = q["loading"];
    reload: any = q["reload"];
    has active: list[any] = [];
    useAgentFeed(data.events if data else None, 2500, lambda (xs: any) { active = xs; });
    has cell: any = None;
    nav: any = useNavigate();
    if loading and not data {
        return <PageSkeleton />;
    }
    if error or not data {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    k: any = data.kpis;
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
                    <Ring value={k.filled} max={k.needed} size={76} stroke={7}><span className="w600" style={{"fontSize": 17}}><CountUp value={k.coverage_pct} />%</span></Ring>
                    <div className="stack"><span className="num nowrap" style={{"fontSize": 34}}>{k.filled}<span className="ink-3" style={{"fontSize": 18}}>/{k.needed}</span></span><span className="ink-3 t-small nowrap">slots filled</span></div>
                </div>
            </div>
            <button className="card kpi" style={{"textAlign": "left", "cursor": "pointer"}} onClick={lambda (e: MouseEvent) { nav("/d/approvals"); }}>
                <span className="lbl row g8"><Inbox size={15} />Waiting for you</span>
                <span className={"num " + ("c-accent" if data.approvals.length else "")}><CountUp value={data.approvals.length} /></span>
                <span className="ink-3 t-small">{"One tap each" if data.approvals.length else "All clear"}</span>
            </button>
            <div className="card kpi">
                <span className="lbl row g8"><Sparkles size={15} />Done by agents</span>
                <span className="num"><CountUp value={k.automation_pct} />%</span>
                <span className="ink-3 t-small">You only approved the rest</span>
            </div>
            <div className="card kpi">
                <span className="lbl">Hours scheduled</span>
                <span className="num"><CountUp value={k.hours} /></span>
                <span className="ink-3 t-small">{k.students} {"person" if k.students == 1 else "people"} on the team</span>
            </div>
        </div>

        {k.students == 0 and <JoinCodeCard className="mt16" />}

        <div className="dash-row mt16">
            <section className="card">
                <div className="card-head"><h2 className="t-section row g8">Needs your approval{data.approvals.length > 0 and <span className="badge" style={{"marginLeft": 4}}>{data.approvals.length}</span>}</h2>
                    <Link to="/d/approvals" className="btn text sm">View all<ArrowRight size={14} /></Link></div>
                <ApprovalList items={data.approvals} onDone={lambda { reload(True); }} limit={3} />
            </section>
            <section className="card network-card">
                <div className="card-head" style={{"marginBottom": 0}}><h2 className="t-section">Agent network</h2>
                    <span className="pill"><span className="live violet" />{(str(len(active)) + " working") if len(active) else "Standing by"}</span></div>
                <div className="orbit-wrap"><AgentOrbit active={active} compact={True} /></div>
            </section>
        </div>

        <section className="card mt16">
            <div className="card-head"><h2 className="t-section">Schedule</h2><Link to="/d/schedule" className="btn text sm">Open schedule<ArrowRight size={14} /></Link></div>
            <WeekCalendar week={data.week} cells={data.coverage.cells} onCell={lambda (c: any) { cell = c; }} hourHeight={40} toolbar={False} />
        </section>
        {cell and <SlotDrawer week={data.week} cell={cell} onClose={lambda { cell = None; }} />}
    </>
}

def:pub ApprovalsPage() -> JsxElement {
    q: any = useWalker("get_approvals", {}, 3000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }
    <>
        <div className="dheader"><div className="stack g8"><span className="eyebrow">Human in the loop</span><h1 className="t-page">Approvals</h1>
            <span className="ink-2">Every item was drafted by an agent and has already passed every hard rule. You decide.</span></div></div>
        <section className="card"><ApprovalList items={data.items} onDone={lambda { reload(True); }} /></section>
    </>
}

# ---------------- slot drawer (copilot-powered, no forms) ----------------
def:pub SlotDrawer(week: str, cell: any, onClose: any) -> JsxElement {
    slotQ: any = useWalker("get_slot", {"week": week, "day": cell.day, "start": cell.start, "end": cell.end, "position_id": cell.position_id or None});
    has res: any = None;
    has busy: bool = False;
    toast: any = useToast();
    slotData: any = slotQ["data"];
    slotReload: any = slotQ["reload"];
    label: str = slot(cell.day, cell.start, cell.end);
    title: str = label + ((" · " + cell.role) if cell.role else "");
    async def run(text: str) -> None {
        busy = True;
        res = None;
        try {
            res = await api("copilot_command", {"text": text, "week": week});
            slotReload(True);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }
    <Drawer onClose={onClose} label="Slot">
        <div className="stack g20">
            <div className="row between"><div className="stack g4"><span className="eyebrow">Slot</span><h2 className="t-section">{title} · needs {cell.needed}</h2></div><CloseButton onClick={onClose} /></div>
            <div className="stack g8">
                <span className="label">On this shift</span>
                {slotData and slotData.people.length == 0 and <div className="ink-2">No one yet.</div>}
                <div className="divided">
                    {for p in (slotData.people if slotData else []) {
                        <div key={p.student_id} className="list-row"><span className="grow">{p.name}</span>{p.pending and <StatusChip kind="wait">Swap pending</StatusChip>}<span className="ink-3 t-small">{fmtHours(p.hours_with_you)} hrs with you</span></div>
                    }}
                </div>
            </div>
            <div className="stack g8">
                <span className="label">Ask the agents</span>
                <div className="suggest">
                    <button onClick={lambda (e: MouseEvent) { run("Who can cover " + label.replace("–", " to ") + "?"); }}>Who can cover this?</button>
                    <button onClick={lambda (e: MouseEvent) { run("Need 1 more people " + label.replace("–", " to ")); }}>Need one more here</button>
                </div>
            </div>
            {(busy or res) and <AgentPanel trace={res.trace if res else None} pending={busy} title="copilot · agents" />}
            {res and <div className="reply w500">{res.reply}</div>}
            {res and res.card and <CopilotCard card={res.card} onClose={onClose} onRun={lambda (t: str) { run(t); }} />}
        </div>
    </Drawer>
}

# ---------------- Schedule ----------------
def:pub SchedulePage() -> JsxElement {
    sp: any = useSearchParams();
    params: any = sp[0];
    setParams: any = sp[1];
    weekParam: any = params.get("week") or JS.undefined;
    def setWeek(w: str) -> None {
        setParams({"week": w});
    }
    q: any = useWalker("get_coverage", {"week": weekParam} if weekParam else {}, 5000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    has cell: any = None;
    has busy: bool = False;
    nav: any = useNavigate();
    toast: any = useToast();
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }
    week: str = data.week;
    async def regen() -> None {
        busy = True;
        try {
            d: any = await api("generate_schedule", {"week": week});
            nav("/d/drafts/" + str(d.draft_id) + "?replay=1");
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }
    today: str = mondayOf();
    <>
        <div className="dheader">
            <div className="stack g8"><span className="eyebrow">Schedule</span><h1 className="t-page">Week of {weekLabel(week)}</h1></div>
            <div className="actions">
                <span className="pill"><b>{data.stats.filled}</b>/{data.stats.needed} filled</span>
                <button className="btn primary" disabled={busy or not data.has_needs} onClick={lambda (e: MouseEvent) { regen(); }}><Sparkles size={15} />Re-plan with agents</button>
            </div>
        </div>
        {<div className="card empty"><span>Tell the Needs Agent what a normal week looks like.</span><button className="btn primary" onClick={lambda (e: MouseEvent) { nav("/d/settings"); }}>Set up needs</button></div> if not data.has_needs else <section className="card"><WeekCalendar week={week} cells={data.cells} onCell={lambda (c: any) { cell = c; }} hourHeight={56}
            onPrev={lambda { setWeek(shiftWeek(week, -1)); }} onNext={lambda { setWeek(shiftWeek(week, 1)); }} onToday={lambda { setWeek(today); }} /></section>}
        {cell and <SlotDrawer week={week} cell={cell} onClose={lambda { cell = None; reload(True); }} />}
    </>
}

# ---------------- Draft review (agent replay) ----------------
def:pub DraftReview() -> JsxElement {
    pp: any = useParams();
    id: str = pp["id"] or "";
    sp: any = useSearchParams();
    params: any = sp[0];
    has draft: any = None;
    has error: any = None;
    has phase: str = "review" if params.get("replay") == "0" else "replay";
    has reveal: int = 0;
    has activeAgents: list[any] = [];
    has busy: bool = False;
    nav: any = useNavigate();
    toast: any = useToast();
    revealed: any = useRef(False);

    async def load() -> None {
        try {
            draft = await api("get_draft", {"draft_id": id});
        } except Exception as e {
            error = errMsg(e);
        }
    }
    useEffect(lambda -> any { revealed.current = False; reveal = 0; load(); return JS.undefined; }, [id]);

    trace0: any = (draft.trace if draft else None) or [];
    schedIdx: int = -1;
    for (i, row0) in enumerate(trace0) {
        if schedIdx < 0 and row0.agent == "Scheduling Agent" {
            schedIdx = i;
        }
    }
    def onProgress(n: int) -> None {
        row: any = draft.trace[JS.Math.max(0, n - 1)] if draft and draft.trace else None;
        if row and row.agent {
            activeAgents = [row.agent, "Coordinator"];
        }
        if not revealed.current and schedIdx >= 0 and n > schedIdx {
            revealed.current = True;
            total: int = draft.coverage.cells.length;
            box: any = {"i": 0, "t": 0};
            box["t"] = JS.window.setInterval(
                lambda {
                    box["i"] = box["i"] + 2;
                    reveal = box["i"];
                    if box["i"] >= total {
                        JS.window.clearInterval(box["t"]);
                    }
                },
                45
            );
        }
    }
    if error {
        return <ErrorBlock message={error} />;
    }
    if not draft {
        return <PageSkeleton />;
    }
    s: any = draft.summary;
    decided: bool = draft.state != "draft";

    async def publish() -> None {
        busy = True;
        try {
            r: any = await api("decide", {"type": "draft", "id": draft.draft_id, "approve": True});
            toast("Schedule published. " + str(r.notified) + " " + ("person" if r.notified == 1 else "people") + " notified.");
            nav("/d");
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }
    async def discard() -> None {
        await api("decide", {"type": "draft", "id": draft.draft_id, "approve": False});
        nav("/d");
    }
    async def regen() -> None {
        busy = True;
        d: any = await api("generate_schedule", {"week": draft.week});
        busy = False;
        phase = "replay";
        nav("/d/drafts/" + str(d.draft_id));
    }

    if phase == "replay" {
        return <>
            <div className="dheader"><div className="stack g8"><span className="eyebrow">{"Autopilot draft" if draft.state == "draft" else "Draft"} · replaying the agent run</span><h1 className="t-page">Building week of {weekLabel(draft.week)}…</h1></div>
                <button className="btn ghost sm" onClick={lambda (e: MouseEvent) { phase = "review"; }}>Skip replay</button></div>
            <div className="two-col">
                <div className="stack g16">
                    <div className="card" style={{"padding": 10}}><AgentOrbit active={activeAgents} compact={True} /></div>
                    <AgentPanel trace={draft.trace} onProgress={lambda (n: int) { onProgress(n); }} onDone={lambda { JS.window.setTimeout(lambda { phase = "review"; }, 700); }} />
                </div>
                <section className="card"><WeekCalendar week={draft.week} cells={draft.coverage.cells} skeleton={True} reveal={reveal} toolbar={False} hourHeight={44} /></section>
            </div>
        </>;
    }
    <>
        <div className="dheader">
            <div className="stack g8"><span className="eyebrow">{"Waiting for your approval" if draft.state == "draft" else ("Draft · " + draft.state)}</span>
                <h1 className="t-page">Schedule ready. <span className="grad-text">{s.filled} of {s.needed}</span> slots filled.</h1>
                {s.open_seats > 0 and <span className="c-wait row g8"><Clock size={15} />{s.open_seats} {"slot needs" if s.open_seats == 1 else "slots need"} attention — the Recruiting Agent is already on it.</span>}
            </div>
            <button className="btn ghost sm" onClick={lambda (e: MouseEvent) { revealed.current = False; reveal = 0; phase = "replay"; }}>Replay agent run</button>
        </div>
        <div className="stack g20">
            <section className="card"><WeekCalendar week={draft.week} cells={draft.coverage.cells} toolbar={False} hourHeight={44} /></section>
            {s.gaps.length > 0 and <section className="card stack g12"><h2 className="t-section">Flagged, never hidden</h2>
                {for g in s.gaps {
                    <div key={g.label} className="approval" style={{"gridTemplateColumns": "40px 1fr"}}>
                        <span className="ic" style={{"background": "var(--wait-bg)", "borderColor": "rgba(255,200,87,.3)", "color": "var(--wait)"}}><Clock size={18} /></span>
                        <div><div className="title"><span className="mono" style={{"fontSize": 13}}>{g.label}</span> · needs {g.needed}, found {g.found}</div><div className="detail">{g.reason} Recruiting Agent is searching campus.</div></div>
                    </div>
                }}
            </section>}
            <section className="card"><h2 className="t-section">Why each person got what they got</h2>
                <div className="divided mt12">
                    {for st in s.students {
                        <div key={st.student_id} className="list-row" style={{"alignItems": "flex-start"}}>
                            <div className="grow stack g4"><span>{st.line}{st.new_shifts > 0 and <span className="chip accent" style={{"marginLeft": 8}}>+{st.new_shifts} new</span>}</span>
                                <Disclosure summary="Why?"><span className="ink-2">{st.why}</span></Disclosure></div>
                        </div>
                    }}
                </div>
            </section>
            <AgentPanel trace={draft.trace} replay={False} collapsible={True} defaultCollapsed={True} />
        </div>
        {not decided and <div className="sticky-foot row g8 end wrap">
            <span className="ink-2 grow hide-mobile">Every assignment passed the Conflict Agent and Compliance Checker.</span>
            <button className="btn text" onClick={lambda (e: MouseEvent) { discard(); }}>Discard</button>
            <button className="btn" disabled={busy} onClick={lambda (e: MouseEvent) { regen(); }}>Regenerate</button>
            <button className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { publish(); }}>{"Approve & publish"}</button>
        </div>}
    </>
}

# ---------------- Swap approval ----------------
def:pub SwapApproval() -> JsxElement {
    pp: any = useParams();
    id: str = pp["id"] or "";
    q: any = useWalker("get_swap_request", {"request_id": id}, 2500);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    setData: any = q["setData"];
    seen: any = useRef(None);
    has replayed: list[any] = [];
    has busy: bool = False;
    toast: any = useToast();
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }
    if seen.current is None {
        seen.current = [l.loop_id for l in data.loops];
    }
    async def act(name: str, loopId: any) -> None {
        busy = True;
        try {
            setData(await api(name, {"loop_id": loopId}));
        } except Exception as e {
            toast(errMsg(e), False);
            reload(True);
        }
        busy = False;
    }
    loops: any = data.loops;
    current: any = loops[loops.length - 1] if loops.length else None;
    previous: any = loops.slice(0, -1);
    lastDeclined: any = None;
    for l in loops {
        if l.state == "declined" {
            lastDeclined = l;
        }
    }
    seenIds: any = seen.current;
    isNew: bool = False;
    showCurrent: bool = False;
    replanning: bool = False;
    if current {
        isNew = not seenIds.includes(current.loop_id);
        showCurrent = not isNew or current.loop_id in replayed;
        replanning = bool(lastDeclined) and current.loop_id != lastDeclined.loop_id and current.state == "proposed";
    }
    declineText: str = "";
    if lastDeclined and lastDeclined.decline_reason {
        declineText = JS.String.prototype.replace.call(lastDeclined.decline_reason, new(JS.RegExp, "[.!\\s]+$"), "");
    }
    previousDeclined: bool = any([p.state == "declined" for p in previous]);
    <div className="stack g20" style={{"maxWidth": 980}}>
        <Link to="/d/approvals" className="row g4 ink-2"><ChevronLeft size={16} />Approvals</Link>
        {data.reason and <div className="ink-2">Trigger: “{data.reason}”</div>}
        {lastDeclined and ((current and current.state == "proposed") or data.state == "searching") and
            <div className="note wait"><Clock size={16} /><div>{lastDeclined.declined_by} declined{<>{" — “"}{declineText}{".”"}</> if lastDeclined.decline_reason else "."} {"No other option yet — the Swap Agent will retry when the week changes." if data.state == "searching" else "The Swap Agent re-planned without them."}</div></div>}
        {for l in previous {
            <div key={l.loop_id} className="collapsed-line">{<X size={16} className="c-block" /> if l.state == "declined" else <Clock size={16} />}Previous option · {l.headline.split(" · ")[0]} · {("declined by " + l.declined_by) if l.state == "declined" else l.state}</div>
        }}
        {current and isNew and not (current.loop_id in replayed) and <AgentPanel trace={current.trace} onDone={lambda { replayed = replayed + [current.loop_id]; }} title="swap agent · re-planning" />}
        {current and replanning and current.loop_id in replayed and <AgentPanel trace={current.trace} replay={False} collapsible={True} defaultCollapsed={True} />}
        {current and showCurrent and <LoopCard loop={current} isNewOption={replanning or previousDeclined} busy={busy}
            onApprove={lambda { act("approve_swap", current.loop_id); }} onReject={lambda { act("reject_swap", current.loop_id); }} />}
        {not current and data.state == "searching" and <div className="card ink-2">No swap found yet. The Swap Agent will look again when the schedule changes.</div>}
    </div>
}

def:pub LoopCard(loop: any, isNewOption: bool, busy: bool, onApprove: any, onReject: any) -> JsxElement {
    done: bool = loop.state == "committed";
    title: str = ("Swap complete. All " + str(loop.moves.length) + " schedules updated.") if done else (("New option · " if isNewOption else "") + loop.headline);
    <section className={"card stack g24 slide-in " + ("" if done else "glow")} aria-label="Swap proposal">
        <div className="stack g4"><h1 className={"t-page row g8 " + ("c-ok" if done else "")}>{done and <Check size={26} />}{title}</h1><span className="ink-2">{loop.subline}</span></div>
        <div className="two-col" style={{"gridTemplateColumns": "1.2fr 1fr"}}>
            <div className="table-wrap">
                <table className="table">
                    <thead><tr><th>Student</th><th>Gives up</th><th>Gets</th><th>Hrs with you</th></tr></thead>
                    <tbody>{for m in loop.moves {
                        <tr key={m.student_id}><td className="w600">{m.name}</td><td className="mono">{m.gives or "—"}</td><td className="mono">{m.gets or "—"}</td>
                            <td className="mono">{fmtHours(m.hrs_before)} → {fmtHours(m.hrs_after)} <Check size={12} className="c-ok" style={{"verticalAlign": -1}} /></td></tr>
                    }}</tbody>
                </table>
            </div>
            {<LoopDiagram moves={loop.moves} /> if loop.kind != "handoff" else <div />}
        </div>
        <div className="row g16 wrap">{for c in loop.checks { <span key={c.label} className="row g6"><Check size={14} className="c-ok" />{c.label}<span className={"tag " + c.kind}>{"code" if c.kind == "rules" else "AI"}</span></span> }}</div>
        <Disclosure summary="Why this swap?"><div className="stack g8 ink-2"><p>{loop.rationale}</p>
            {loop.alternatives.length > 0 and <p>Other options considered: {loop.alternatives.length}. {loop.alternatives[0].summary} — {loop.alternatives[0].why_lower}</p>}</div></Disclosure>
        {loop.state == "proposed" and <div className="row g8 end hairline-top" style={{"paddingTop": 16}}>
            <button className="btn" disabled={busy} onClick={lambda (e: MouseEvent) { onReject(); }}>Reject</button>
            <button className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { onApprove(); }}>{"Approve new swap" if isNewOption else "Approve"}</button>
        </div>}
        {loop.state in ["approved", "committed", "declined"] and <div className="stack hairline-top" style={{"paddingTop": 8}}>
            {for p in loop.participants {
                <div key={p.name} className="list-row">
                    <span className="grow">{p.name}{p.auto == "carried" and <span className="ink-3 t-small">{" · already agreed to this move"}</span>}{p.auto == "auto_accept" and <span className="ink-3 t-small">{" · "}<Sparkles size={11} style={{"verticalAlign": -1}} />{" autopilot accepted"}</span>}</span>
                    {<StatusChip kind="ok">Accepted</StatusChip> if p.state == "accepted" else (<StatusChip kind="block">Declined</StatusChip> if p.state == "declined" else (<StatusChip kind="wait">Waiting</StatusChip> if p.state == "waiting" else <StatusChip kind="neutral">{"Expired" if p.state == "expired" else "Cancelled"}</StatusChip>))}
                    <span className="ink-3 t-small" style={{"width": 64, "textAlign": "right"}}>{"" if p.seconds_ago == None else ago(p.seconds_ago)}</span>
                </div>
            }}
        </div>}
    </section>
}

# ---------------- Team & roles ----------------
# A role: {id, name, color, members?}
# A person row: {student_id, name, email, kind: student|worker, status, international, state, hours, pay_rate,
#                positions: [role ids], scheduled_with_you, can_still_schedule (None = unknown), calendar, autopilot, new}

def:pub JoinCodeCard(className: str = "") -> JsxElement {
    me: any = useMe();
    toast: any = useToast();
    code: str = (me.department.join_code or "") if me and me.department else "";
    link: str = JS.location.origin + "/join/" + code;
    deptName: any = me.department.name if me and me.department else JS.undefined;
    async def copy(text: str, what: str) -> None {
        try {
            await JS.navigator.clipboard.writeText(text);
            toast(what + " copied.");
        } except Exception {
            toast(text);
        }
    }
    async def share() -> None {
        payload: any = {"title": "Join " + str(deptName) + " on CampusSync", "text": "Join " + str(deptName) + " on CampusSync with code " + code, "url": link};
        if JS.navigator.share {
            try {
                await JS.navigator.share(payload);
            } except Exception {
                return;
            }
        } else {
            copy(link, "Invite link");
        }
    }
    <section className={"card glow join-card " + className}>
        <div className="stack g4 grow">
            <span className="eyebrow">Join code</span>
            <span className="join-code-big mono">{code}</span>
            <span className="ink-2 t-small">Employees sign up with this code (or your invite link) and land on your team.</span>
        </div>
        <div className="row g8 wrap">
            <button className="btn sm" onClick={lambda (e: MouseEvent) { copy(code, "Join code"); }}><Copy size={14} />Copy code</button>
            <button className="btn sm primary" onClick={lambda (e: MouseEvent) { share(); }}><Share2 size={14} />Share invite link</button>
        </div>
    </section>
}

def:pub TeamPage() -> JsxElement {
    me: any = useMe();
    q: any = useWalker("get_team", {}, 8000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    has adding: bool = False;
    has editing: any = None;
    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }
    roles: dict[str, any] = {};
    for pos in data.positions {
        roles[pos.id] = pos;
    }
    campus: bool = bool(me and me.department and me.department.kind == "campus");
    rolesKey: str = "|".join([str(p.student_id) + ":" + ".".join(p.positions) for p in data.people]);
    <>
        <div className="dheader"><div className="stack g8"><span className="eyebrow">{"Team & roles"}</span><h1 className="t-page">People</h1>
            <span className="ink-2">Give each person their roles, weekly hours and pay. The agents only schedule people into roles they hold.</span></div>
            {campus and <div className="actions"><button className="btn" onClick={lambda (e: MouseEvent) { adding = True; }}><UserPlus size={15} />Invite a student</button></div>}</div>
        <JoinCodeCard />
        <RolesEditor key={rolesKey} className="mt16" onChange={lambda { reload(True); }} />
        <div className="table-wrap mt16">
            <table className="table">
                <thead><tr><th>Name</th><th>Roles</th><th>Hours / week</th><th>Pay</th><th>With you this week</th><th>Can still schedule</th><th /></tr></thead>
                <tbody>{data.people.length == 0 and <tr><td colSpan={7} className="ink-2">No one yet — share your join code.</td></tr>}
                    {for p in data.people {
                        <tr key={p.student_id}>
                            <td><div className="row g8 wrap"><span className="w600">{p.name}</span>{p.new and <span className="chip accent">New</span>}{p.state == "invited" and <StatusChip kind="wait">Invited</StatusChip>}</div>
                                <div className="t-small ink-3">{p.email}{(" · " + ("International student" if p.international else "Student")) if p.kind == "student" else ""}{" · calendar synced" if p.calendar else ""}</div></td>
                            <td><span className="row g4 wrap">{p.positions.length == 0 and <span className="ink-3">{"No role yet" if data.positions.length else "—"}</span>}
                                {for r in [roles[i] for i in p.positions if i in roles] { <span key={r.id} className="chip role-chip"><i style={{"background": r.color or "var(--accent)"}} />{r.name}</span> }}</span></td>
                            <td className="num">{p.hours}</td>
                            <td className="num">{money(p.pay_rate)}/hr</td>
                            <td className="num">{fmtHours(p.scheduled_with_you)} hrs</td>
                            <td>{<span className="ink-3">—</span> if p.can_still_schedule == None else (<span className="row g4 c-block" title="Other commitments are private to the employee."><OctagonX size={14} />0 · at limit</span> if p.can_still_schedule == 0 else fmtHours(p.can_still_schedule) + " hrs")}</td>
                            <td><button className="btn sm ghost" onClick={lambda (e: MouseEvent) { editing = p; }} aria-label={"Edit " + p.name}><Pencil size={14} />Edit</button></td>
                        </tr>
                    }}</tbody>
            </table>
        </div>
        <Privacy className="mt16">You see whether people are free and how many hours you can still give them — never their classes or other jobs.</Privacy>
        {adding and <InviteModal onClose={lambda { adding = False; }} onDone={lambda { adding = False; reload(True); }} />}
        {editing and <MemberModal person={editing} roles={data.positions} onClose={lambda { editing = None; }} onDone={lambda { editing = None; reload(True); }} />}
    </>
}

def:pub MemberModal(person: any, roles: any, onClose: any, onDone: any) -> JsxElement {
    has picked: list[any] = person.positions;
    has hours: int = person.hours;
    has rate: str = JS.String(person.pay_rate.toFixed(2));
    has busy: bool = False;
    has confirmRemove: bool = False;
    toast: any = useToast();
    first: str = person.name.split(" ")[0];
    async def save() -> None {
        busy = True;
        try {
            await api("update_member", {"student_id": person.student_id, "positions": picked, "hours": hours, "pay_rate": JS.Number(rate)});
            toast(first + " updated.");
            onDone();
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }
    async def remove() -> None {
        busy = True;
        try {
            r: any = await api("remove_member", {"student_id": person.student_id});
            released: str = (" " + str(r.released) + " upcoming shift" + ("s are" if r.released > 1 else " is") + " open again.") if r.released else "";
            toast(person.name + " removed." + released);
            onDone();
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }
    cap: int = 20 if person.international else 80;
    <Modal onClose={onClose} label={"Edit " + person.name}>
        <div className="stack g20">
            <div className="row between"><div className="stack g4"><h2 className="t-section">{person.name}</h2><span className="ink-3 t-small">{person.email}</span></div><CloseButton onClick={onClose} /></div>
            <div className="field"><span className="label">Roles</span>
                {<span className="ink-2 t-small">Add roles on the Team page first (e.g. Cashier, Site guard).</span> if roles.length == 0 else <div className="row g8 wrap">{for r in roles {
                    <button key={r.id} type="button" className="choice" aria-pressed={r.id in picked} onClick={lambda (e: MouseEvent) { picked = [x for x in picked if x != r.id] if r.id in picked else picked + [r.id]; }}>
                        <i className="role-dot" style={{"background": r.color or "var(--accent)"}} />{r.name}</button>
                }}</div>}</div>
            <div className="row between g16 wrap">
                <div className="field"><span className="label">Hours you can schedule per week</span><Stepper value={hours} min={0} max={cap} onChange={lambda (v: int) { hours = v; }} label="Hours per week" />
                    {person.international and <span className="helper">International students: 20 hrs across all jobs, enforced automatically.</span>}</div>
                <div className="field"><label className="label" htmlFor="rate">Pay rate (USD / hour)</label>
                    <div className="row g8"><span className="ink-2">$</span><input id="rate" className="input" type="number" inputMode="decimal" min="0" max="500" step="0.25" style={{"width": 120}} value={rate} onChange={lambda (e: ChangeEvent) { rate = e.target.value; }} /></div></div>
            </div>
            <div className="row between g8 wrap">
                {<span className="row g8"><span className="c-block t-small">Remove {first}? Upcoming shifts become open.</span><button className="btn sm danger-text" disabled={busy} onClick={lambda (e: MouseEvent) { remove(); }}>Yes, remove</button><button className="btn sm text" onClick={lambda (e: MouseEvent) { confirmRemove = False; }}>No</button></span> if confirmRemove else <button className="btn text" style={{"color": "var(--block)"}} onClick={lambda (e: MouseEvent) { confirmRemove = True; }}><UserMinus size={15} />Remove from team</button>}
                <div className="row g8"><button className="btn" onClick={lambda (e: MouseEvent) { onClose(); }}>Cancel</button><button className="btn primary" disabled={busy or not (JS.Number(rate) >= 0)} onClick={lambda (e: MouseEvent) { save(); }}>Save</button></div>
            </div>
        </div>
    </Modal>
}

def:pub RolesEditor(className: str = "", onChange: any = None) -> JsxElement {
    q: any = useWalker("get_org");
    data: any = q["data"];
    reload: any = q["reload"];
    has name: str = "";
    has busy: bool = False;
    has renaming: any = None;
    toast: any = useToast();
    if not data {
        return <></>;
    }
    async def act(fn: any, ok: str) -> None {
        busy = True;
        try {
            await fn();
            if ok {
                toast(ok);
            }
            reload(True);
            if onChange {
                onChange();
            }
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }
    async def rename(rid: any) -> None {
        await act(lambda -> any { return api("save_position", {"id": rid, "name": renaming.name}); }, "Role renamed.");
        renaming = None;
    }
    async def removeRole(rid: any, rname: str) -> None {
        await act(lambda -> any { return api("delete_position", {"id": rid}); }, rname + " removed.");
    }
    def onRenameKey(e: any, rid: any) -> None {
        if e.key == "Enter" {
            rename(rid);
        }
        if e.key == "Escape" {
            renaming = None;
        }
    }
    async def addRole() -> None {
        await act(lambda -> any { return api("save_position", {"name": name}); }, "Role added.");
        name = "";
    }
    <section className={"card stack g12 " + className}>
        <div className="row between wrap g8"><div className="stack g4"><h2 className="t-section">Roles</h2><span className="ink-2 t-small">Sub-jobs inside your organization. Staffing needs and shifts can require a role.</span></div></div>
        <div className="row g8 wrap">
            {data.positions.length == 0 and <span className="ink-3">No roles yet — everyone can take every shift.</span>}
            {for r in data.positions {
                if renaming and renaming.id == r.id {
                    <span key={r.id} className="row g4"><input className="input" style={{"height": 34, "width": 160}} value={renaming.name} autoFocus={True} onChange={lambda (e: ChangeEvent) { renaming = JS.Object.assign({}, renaming, {"name": e.target.value}); }}
                        onKeyDown={lambda (e: KeyboardEvent) { onRenameKey(e, r.id); }} aria-label="Role name" />
                        <button className="btn sm" disabled={busy} onClick={lambda (e: MouseEvent) { rename(r.id); }}>Save</button></span>
                } else {
                    <span key={r.id} className="chip role-chip lg"><i style={{"background": r.color or "var(--accent)"}} />{r.name}<span className="ink-3">· {r.members or 0}</span>
                        <button aria-label={"Rename " + r.name} onClick={lambda (e: MouseEvent) { renaming = {"id": r.id, "name": r.name}; }}><Pencil size={12} /></button>
                        <button aria-label={"Delete " + r.name} disabled={busy} onClick={lambda (e: MouseEvent) { removeRole(r.id, r.name); }}><Trash2 size={12} /></button></span>
                }
            }}
        </div>
        <form className="row g8" onSubmit={lambda (e: FormEvent) { e.preventDefault(); if name.strip() { addRole(); } }}>
            <input className="input" placeholder="New role, e.g. Night patrol" value={name} onChange={lambda (e: ChangeEvent) { name = e.target.value; }} maxLength={80} aria-label="New role" />
            <button className="btn" disabled={busy or len(name.strip()) < 2}><Plus size={15} />Add role</button>
        </form>
    </section>
}

def:pub InviteModal(onClose: any, onDone: any) -> JsxElement {
    has q: str = "";
    has results: any = [];
    has pick: any = None;
    has hours: int = 10;
    has busy: bool = False;
    toast: any = useToast();
    useEffect(
        lambda -> any {
            async def search() -> None {
                try {
                    r: any = await api("search_students", {"query": q});
                    results = r.results;
                } except Exception {
                    return;
                }
            }
            t: any = JS.window.setTimeout(lambda { search(); }, 200);
            return lambda { JS.window.clearTimeout(t); };
        },
        [q]
    );
    async def send() -> None {
        busy = True;
        try {
            await api("invite_student", {"student_id": pick.student_id, "hours": hours});
            await api("run_autopilot");
            toast("Invite sent to " + pick.name + ".");
            onDone();
        } except Exception as e {
            toast(errMsg(e), False);
            busy = False;
        }
    }
    <Modal onClose={onClose} label="Invite a student" wide={True}>
        <div className="stack g16">
            <div className="row between"><h2 className="t-section">Invite a student from your university</h2><CloseButton onClick={onClose} /></div>
            <SearchInput placeholder="Search by name, email, or student ID" value={q} onChange={lambda (e: ChangeEvent) { q = e.target.value; pick = None; }} autoFocus={True} aria-label="Search students" />
            <div className="divided" style={{"maxHeight": 300, "overflow": "auto"}}>
                {results.length == 0 and <div className="list-row ink-3">No students found. Anyone can also join with your join code.</div>}
                {for r in results {
                    <button key={r.student_id} className="list-row" onClick={lambda (e: MouseEvent) { pick = r; }}
                        style={{"width": "100%", "border": 0, "background": "var(--glass-2)" if pick and pick.student_id == r.student_id else "transparent", "cursor": "pointer", "textAlign": "left", "padding": "12px 8px", "borderRadius": 4}}>
                        <span className="grow stack"><span className="row g8"><span className="w600">{r.name}</span>{r.team_state == "active" and <span className="chip">On your team</span>}{r.team_state == "invited" and <StatusChip kind="wait">Invited</StatusChip>}</span><span className="t-small ink-3">{r.email}</span></span>
                        <span className="ink-2 t-small">Can take up to {fmtHours(r.can_take_more_hrs)} more hrs</span>
                    </button>
                }}
            </div>
            {pick and <div className="row between"><span className="label">Hours per week</span><Stepper value={hours} min={1} max={40} onChange={lambda (v: int) { hours = v; }} label="Hours per week" /></div>}
            <Privacy>You'll only see whether this student is free. Their classes and other jobs stay private.</Privacy>
            <div className="row end"><button className="btn primary" disabled={not pick or busy} onClick={lambda (e: MouseEvent) { send(); }}>Send invite</button></div>
        </div>
    </Modal>
}

# ---------------- Settings ----------------
glob:pub TIMEZONES: list[str] = [
    "America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu",
    "Europe/London", "Europe/Berlin", "Asia/Kolkata", "Asia/Singapore", "Australia/Sydney"
];

def:pub SettingsPage() -> JsxElement {
    org: any = useWalker("get_org");
    needsQ: any = useWalker("get_staffing_needs");
    has policy: any = None;
    has needs: any = None;
    has f: any = None;
    has desc: str = "";
    has busy: bool = False;
    toast: any = useToast();
    od: any = org["data"];
    nd: any = needsQ["data"];
    orgReload: any = org["reload"];
    useEffect(
        lambda -> any {
            if not od {
                return JS.undefined;
            }
            policy = od.policy;
            f = {
                "name": od.name, "timezone": od.timezone, "default_pay_rate": JS.String(od.default_pay_rate), "default_weekly_hours": od.default_weekly_hours,
                "state_tax_pct": JS.String(od.state_tax_pct), "apply_to_team": False
            };
            return JS.undefined;
        },
        [od]
    );
    useEffect(
        lambda -> any {
            if nd {
                needs = nd.needs;
            }
            return JS.undefined;
        },
        [nd]
    );
    if policy is None or needs is None or f is None or not od {
        return <PageSkeleton />;
    }
    roles: any = od.positions;
    async def toggle(k: str, v: bool) -> None {
        patch: any = {};
        patch[k] = v;
        policy = JS.Object.assign({}, policy, patch);
        await api("set_policy", patch);
        toast("Autopilot policy saved.");
    }
    async def saveOrg() -> None {
        busy = True;
        try {
            await api("update_org", JS.Object.assign({}, f, {"default_pay_rate": JS.Number(f.default_pay_rate), "state_tax_pct": JS.Number(f.state_tax_pct)}));
            toast("Settings saved.");
            orgReload(True);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }
    async def newCode() -> None {
        busy = True;
        try {
            r: any = await api("regenerate_join_code");
            toast("New join code: " + r.join_code + ". The old one no longer works.");
            orgReload(True);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }
    async def rebuild() -> None {
        busy = True;
        try {
            r: any = await api("generate_needs", {"description": desc});
            needs = r.needs;
            toast(r.summary);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }
    async def save() -> None {
        busy = True;
        try {
            await api("set_staffing_needs", {"needs": needs});
            await api("run_autopilot");
            toast("Needs saved. Autopilot is re-planning.");
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }
    rows: list[list[str]] = [
        ["auto_generate", "Draft every week automatically", "The Scheduling Agent drafts the upcoming week whenever slots are open. You approve before anything is published."]
    ];
    if od.kind == "campus" {
        rows.append(["auto_recruit", "Recruit for gaps from your university", "When no one on your team can cover a slot, the Recruiting Agent proposes free students. You approve each invite."]);
    }
    rows.append(["auto_approve_swaps", "Auto-approve low-risk swaps", "Swaps where every hour and every slot stay covered skip your approval. Hand-offs always come to you."]);
    zones: list[str] = [f.timezone] + [z for z in TIMEZONES if z != f.timezone];
    <>
        <div className="dheader"><div className="stack g8"><span className="eyebrow">Settings</span><h1 className="t-page">{od.name}</h1>
            <span className="ink-2">{("Campus employer · " + od.university) if od.kind == "campus" else "Business"}{" · join code "}<span className="mono">{od.join_code}</span></span></div></div>
        <div className="stack g20" style={{"maxWidth": 880}}>
            <section className="card stack g16">
                <h2 className="t-section">{"Organization & pay"}</h2>
                <div className="form-grid">
                    <Field label="Organization name" htmlFor="oname"><input id="oname" className="input" value={f.name} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"name": e.target.value}); }} /></Field>
                    <Field label="Time zone" htmlFor="tz" helper="Shift reminders and Friday alerts use it.">
                        <select id="tz" className="select" value={f.timezone} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"timezone": e.target.value}); }}>
                            {for z in zones { <option key={z} value={z}>{JS.String.prototype.replace.call(z, "_", " ")}</option> }}</select></Field>
                    <Field label="Default pay rate (USD / hour)" htmlFor="rate" helper="New people start here. Change individuals on the Team page.">
                        <input id="rate" className="input" type="number" min="0" max="500" step="0.25" value={f.default_pay_rate} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"default_pay_rate": e.target.value}); }} /></Field>
                    <Field label="Default hours per person per week" htmlFor="dh"><input id="dh" className="input" type="number" min="1" max="80" value={f.default_weekly_hours} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"default_weekly_hours": JS.Number(e.target.value)}); }} /></Field>
                    <Field label="State income tax (%)" htmlFor="st" helper="Used for employees' take-home estimates."><input id="st" className="input" type="number" min="0" max="15" step="0.05" value={f.state_tax_pct} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"state_tax_pct": e.target.value}); }} /></Field>
                </div>
                <label className="row g8 ink-2" style={{"cursor": "pointer"}}><input type="checkbox" checked={f.apply_to_team} onChange={lambda (e: ChangeEvent) { f = JS.Object.assign({}, f, {"apply_to_team": e.target.checked}); }} />Also set everyone on the team to the default pay rate</label>
                <div className="row between g8 wrap"><button className="btn text" disabled={busy} onClick={lambda (e: MouseEvent) { newCode(); }}>Get a new join code</button><button className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { saveOrg(); }}>Save settings</button></div>
            </section>
            <section className="card divided">
                <h2 className="t-section" style={{"paddingBottom": 8}}>Autopilot</h2>
                {for row in rows {
                    <div key={row[0]} className="list-row" style={{"alignItems": "flex-start", "padding": "16px 0"}}>
                        <div className="grow stack g4"><span className="w600">{row[1]}</span><span className="ink-2">{row[2]}</span></div>
                        <Switch checked={True if policy[row[0]] else False} onChange={lambda (v: bool) { toggle(row[0], v); }} label={row[1]} />
                    </div>
                }}
            </section>
            <section className="card stack g16">
                <div className="stack g4"><h2 className="t-section">Staffing plan</h2><span className="ink-2">Describe changes in words, or adjust blocks by hand. Pick a role for blocks that need one.</span></div>
                <div className="row g8"><input className="input" placeholder="Describe a normal week, e.g. Café open 7am to 7pm weekdays, busiest at lunch" value={desc} onChange={lambda (e: ChangeEvent) { desc = e.target.value; }} />
                    <button className="btn" disabled={not desc or busy} onClick={lambda (e: MouseEvent) { rebuild(); }}><Sparkles size={15} />Rebuild plan</button></div>
                <Disclosure summary={"Edit " + str(needs.length) + " blocks by hand"}><NeedsEditor needs={needs} onChange={lambda (n: any) { needs = n; }} roles={roles} /></Disclosure>
                <div className="row end"><button className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { save(); }}>Save plan</button></div>
            </section>
            <section className="card"><NotificationSettings employer={True} /></section>
        </div>
    </>
}
