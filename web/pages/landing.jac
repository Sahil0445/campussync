"""The public landing page."""

import from react { useEffect, useState }
import from "react-router-dom" { Link }
import from "lucide-react" { ArrowRight, BellRing, CalendarClock, Clock3, DollarSign, Lock, Repeat, ShieldCheck, Sparkles, UserPlus, Wand2 }
import from web.components.AgentOrbit { AGENT_META, AgentOrbit }
import from web.components.ui { Wordmark }

glob:pub JS: any = globalThis;

glob:pub TICKER: list[list[str]] = [
    ["Availability Agent", "Synced Priya's Google Calendar · new event Saturday"],
    ["Conflict Agent", "Checked every employer · hidden overlap blocked"],
    ["Swap Agent", "No 1:1 swap — found a 3-person loop"],
    ["Compliance Checker", "Everyone stays under the 20 h international cap"],
    ["Coordinator", "Marcus declined — re-planning without him"],
    ["Swap Agent", "Found a 4-person loop · all autopilots agreed"],
    ["Recruiting Agent", "Sat 15:00–19:00 unfillable — found 2 students on campus"],
    ["Commit Service", "Applied 4 moves at once · every schedule updated"]
];

glob:pub ROLES: dict[str, str] = {
    "Availability Agent": "Reads every employee's Google Calendar and turns notes like “no Fridays before 10” into rules.",
    "Conflict Agent": "Walks every employer's schedule for a student — then answers only yes or no.",
    "Compliance Checker": "20 h international cap, assigned hours, 8 h/day, rest. Deterministic code, never a model.",
    "Scheduling Agent": "Drafts the whole week: fairness, preferences, who takes Saturday.",
    "Swap Agent": "Finds 1:1 swaps, then 3- and 4-person loops. Re-plans the instant someone declines.",
    "Recruiting Agent": "When the team can't cover a slot, finds free students anywhere on campus.",
    "Explainer": "Every decision arrives as one sentence you can approve in one tap.",
    "Coordinator": "Orchestrates the agents and keeps humans in the loop only where it matters."
};

glob:pub FEATURES: list[dict[str, any]] = [
    {"icon": CalendarClock, "t": "Calendars sync themselves", "d": "Employees connect Google Calendar once. Busy times flow in, shifts flow out to their own calendar, and clashes get covered before anyone asks."},
    {"icon": Wand2, "t": "The week drafts itself", "d": "The Scheduling Agent fills every slot by role, fairly, inside every hour limit. Managers approve in two taps."},
    {"icon": Clock3, "t": "Hours report themselves", "d": "When a shift ends its hours are on the timesheet. Friday, employees check and approve — over-reporting past 20 h is blocked."},
    {"icon": DollarSign, "t": "Pay you can see", "d": "$15/hr by default, set per person. Employees see hours and take-home pay by week, month and year."},
    {"icon": BellRing, "t": "Alerts on every phone", "d": "Reminders 24 h and 1 h before each shift, and a Friday morning and evening nudge to approve hours."},
    {"icon": UserPlus, "t": "Gaps recruit themselves", "d": "Campus employers: when nobody on the team can cover, the Recruiting Agent finds free students at the same university."},
    {"icon": Repeat, "t": "Swaps resolve in loops", "d": "No 1:1 match? It finds 3- and 4-person loops and re-plans instantly when someone declines."},
    {"icon": ShieldCheck, "t": "One code to join", "d": "Employers get a join code. Students can hold several campus jobs; a regular employee belongs to one employer."}
];

def:pub Landing() -> JsxElement {
    has i: int = 0;
    useEffect(
        lambda -> any {
            iv: any = JS.window.setInterval(lambda { i = i + 1; }, 2200);
            return lambda { JS.window.clearInterval(iv); };
        },
        []
    );
    ticker: list[list[str]] = [TICKER[(i + k) % len(TICKER)] for k in [0, 1, 2]];
    <div>
        <div className="lnav-wrap">
            <nav className="lnav">
                <Wordmark />
                <div className="row g24 hide-mobile ink-2">
                    <a href="#how" className="ink-2">How it works</a><a href="#privacy" className="ink-2">Privacy</a><a href="#agents" className="ink-2">Agents</a>
                </div>
                <div className="row g8">
                    <Link to="/signin" className="btn ghost sm">Sign in</Link>
                    <Link to="/signup" className="btn primary sm">Get started<ArrowRight size={14} /></Link>
                </div>
            </nav>
        </div>

        <section className="hero">
            <div className="stack g24">
                <span className="pill" style={{"alignSelf": "flex-start"}}><span className="live" />Scheduling, time and pay — on autopilot</span>
                <h1 className="t-hero">Shift work,<br /><span className="grad-text">on autopilot.</span></h1>
                <p className="ink-2" style={{"fontSize": 18, "maxWidth": 580, "lineHeight": 1.55}}>
                    {"For campus jobs and any team that can't justify Workday. Agents read calendars, draft the week, fill gaps, resolve swaps, report hours when each shift ends and remind everyone on their phone — while no employer ever sees another's schedule."}
                    <span style={{"color": "var(--ink)"}}> Humans just approve.</span>
                </p>
                <div className="row g12 wrap">
                    <Link to="/signup" className="btn primary lg">Create your team<ArrowRight size={16} /></Link>
                    <Link to="/signin" className="btn lg">Try the demo accounts</Link>
                </div>
                <div className="row g16 wrap ink-3 t-small">
                    <span className="row g6"><Lock size={13} />Minimum disclosure by design</span>
                    <span className="row g6"><ShieldCheck size={13} />Hard limits enforced in code</span>
                    <span className="row g6"><Sparkles size={13} />Gemini-powered agents</span>
                </div>
            </div>
            <div className="card glow" style={{"padding": 18}}>
                <div className="row between" style={{"padding": "4px 6px 0"}}>
                    <span className="eyebrow">Agent network · live</span><span className="pill"><span className="live violet" />coordinating</span>
                </div>
                <AgentOrbit cycle={True} />
                <div className="agents" style={{"marginTop": 4}}>
                    {for (k, row) in enumerate(ticker) {
                        <div key={str(i) + "-" + str(k)} className="agent-row" style={{"opacity": 1 - k * 0.28}}>
                            {<span className="run-dot" /> if k == 0 else <span className="feed-dot done" style={{"marginTop": 0}} />}
                            <div className="grow"><span className="name">{row[0]}</span>{"  "}<span className="res">{row[1]}</span></div>
                        </div>
                    }}
                </div>
            </div>
        </section>

        <section className="section" style={{"paddingTop": 16}}>
            <div className="stat-band">
                <div><div className="n grad-text">8</div><div className="ink-2 mt8">agents — 6 AI, 2 deterministic</div></div>
                <div><div className="n grad-text">2 taps</div><div className="ink-2 mt8">for a manager to approve a whole week</div></div>
                <div><div className="n grad-text">0</div><div className="ink-2 mt8">schedules shared between employers</div></div>
                <div><div className="n grad-text">20 h</div><div className="ink-2 mt8">international cap — enforced in code, never by AI</div></div>
            </div>
        </section>

        <section className="section" id="how">
            <span className="eyebrow">How it works</span>
            <h2 className="t-display mt12" style={{"maxWidth": 760}}>From calendar to confirmed shift — <span className="grad-text">without a spreadsheet.</span></h2>
            <div className="features mt32">
                {for f in FEATURES {
                    <div key={f["t"]} className="card stack g12">
                        <span className="icon-tile"><@{f["icon"]} size={18} /></span>
                        <div className="t-card">{f["t"]}</div>
                        <p className="ink-2">{f["d"]}</p>
                    </div>
                }}
            </div>
        </section>

        <section className="section" id="privacy">
            <span className="eyebrow">Minimum disclosure</span>
            <h2 className="t-display mt12" style={{"maxWidth": 760}}>It knows everything. <span className="grad-text">It says almost nothing.</span></h2>
            <div className="privacy-demo mt32">
                <div className="card stack g12">
                    <span className="eyebrow">What CampusSync knows</span>
                    <div className="t-card">Priya · international</div>
                    <div className="mono ink-2" style={{"lineHeight": 1.9}}>CSE Research · Mon Wed Fri 10:00–14:00<br />Campus Dining · Tue 15:00–19:00 · Sat 11:00–15:00<br />Total · 20 / 20 h</div>
                </div>
                <div className="stack g8" style={{"alignItems": "center"}}><span className="icon-tile" style={{"width": 52, "height": 52, "borderRadius": 16}}><Lock size={22} /></span><span className="mono ink-3">walker boundary</span></div>
                <div className="card glow stack g12">
                    <span className="eyebrow">What Campus Dining sees</span>
                    <div className="t-card">“Can Priya work Wed 12–3?”</div>
                    <div className="mono" style={{"lineHeight": 1.9, "color": "#c9d0ff"}}>{'{ "available": false, "reason": "schedule_conflict" }'}<br />{'{ "available": false, "reason": "hour_limit", "hours_left": 0 }'}</div>
                </div>
            </div>
        </section>

        <section className="section" id="agents">
            <span className="eyebrow">The team</span>
            <h2 className="t-display mt12">Rules are code. <span className="grad-text">Judgment is AI.</span></h2>
            <div className="agent-grid mt32">
                {for a in AGENT_META {
                    <div key={a["name"]} className="card stack g12">
                        <div className="row between"><span className="icon-tile"><@{a["Icon"]} size={18} /></span><span className={"tag " + a["kind"]}>{"rules · code" if a["kind"] == "rules" else "agent · AI"}</span></div>
                        <div className="t-card">{a["name"]}</div>
                        <p className="ink-2">{ROLES[a["name"]]}</p>
                    </div>
                }}
            </div>
        </section>

        <section className="section">
            <div className="card glow stack g16" style={{"alignItems": "center", "textAlign": "center", "padding": "56px 24px"}}>
                <h2 className="t-display">Humans approve. <span className="grad-text">Agents do the rest.</span></h2>
                <p className="ink-2" style={{"maxWidth": 520}}>Register your organization, share the join code, and your team is scheduled, reminded and paid on autopilot.</p>
                <div className="row g12 wrap" style={{"justifyContent": "center"}}><Link to="/signup" className="btn primary lg">Get started<ArrowRight size={16} /></Link><Link to="/signin" className="btn lg">Demo accounts</Link></div>
            </div>
        </section>
        <footer className="section row between wrap g12 ink-3 t-small" style={{"paddingTop": 0}}>
            <Wordmark size={20} /><span>Built for JacHacks 2026 · Written in Jac</span>
        </footer>
    </div>
}
