"""The agent network. Nodes light up (and their links carry traffic) when an agent is working."""

import from react { useEffect, useState }
import from "lucide-react" { CalendarRange, CalendarClock, MessageSquareText, Network, Repeat, Scale, ShieldCheck, UserPlus }

glob:pub JS: any = globalThis;

glob:pub AGENT_META: list[dict[str, any]] = [
    {"name": "Availability Agent", "short": "Availability", "kind": "agent", "Icon": CalendarClock},
    {"name": "Conflict Agent", "short": "Conflict", "kind": "rules", "Icon": ShieldCheck},
    {"name": "Compliance Checker", "short": "Compliance", "kind": "rules", "Icon": Scale},
    {"name": "Scheduling Agent", "short": "Scheduling", "kind": "agent", "Icon": CalendarRange},
    {"name": "Swap Agent", "short": "Swap", "kind": "agent", "Icon": Repeat},
    {"name": "Recruiting Agent", "short": "Recruiting", "kind": "agent", "Icon": UserPlus},
    {"name": "Explainer", "short": "Explainer", "kind": "agent", "Icon": MessageSquareText},
    {"name": "Coordinator", "short": "Coordinator", "kind": "agent", "Icon": Network}
];

def:pub AgentOrbit(active: any = None, cycle: bool = False, compact: bool = False) -> JsxElement {
    st: any = useState(0);
    tick: int = st[0];
    setTick: any = st[1];
    useEffect(
        lambda -> any {
            if not cycle {
                return JS.undefined;
            }
            iv: any = JS.window.setInterval(lambda { setTick(lambda (t: int) -> int { return t + 1; }); }, 900);
            return lambda { JS.window.clearInterval(iv); };
        },
        [cycle]
    );
    cycled: list[str] = [AGENT_META[tick % 7]["name"], AGENT_META[(tick + 3) % 7]["name"], "Coordinator"] if cycle else [];
    on_list: list[str] = list(active or []) + cycled;
    on: set[str] = set(on_list);
    W = 520;
    c: float = W / 2;
    R: float = 178 if compact else 190;
    ring: list[dict[str, any]] = AGENT_META[0:7];
    n: int = len(ring);
    PI: float = JS.Math.PI;
    active_count: int = len(on) - (1 if "Coordinator" in on else 0);
    <svg className="orbit" viewBox={"0 0 " + str(W) + " " + str(W)} role="img" aria-label="CampusSync agent network">
        <defs>
            <linearGradient id="og" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#a18bff" /><stop offset="0.5" stopColor="#6c8cff" /><stop offset="1" stopColor="#3dd8f5" /></linearGradient>
            <radialGradient id="cg" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stopColor="#c7bcff" /><stop offset="0.45" stopColor="#6c8cff" /><stop offset="1" stopColor="#1f7a94" /></radialGradient>
            <filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4" result="b" /><feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge></filter>
        </defs>
        <circle className="ring" cx={c} cy={c} r={R + 46} />
        <circle className="ring dash" cx={c} cy={c} r={R} />
        <circle className="ring" cx={c} cy={c} r={92} />
        {for (i, a) in enumerate(ring) {
            ang: float = -PI / 2 + (2 * PI * i) / n;
            x: float = c + R * JS.Math.cos(ang);
            y: float = c + R * JS.Math.sin(ang);
            <line key={"e" + a["name"]} className={"edge " + ("on" if a["name"] in on else "")} x1={c} y1={c} x2={x} y2={y} />
        }}
        <g>
            <circle cx={c} cy={c} r={64} fill="rgba(108,140,255,0.08)" />
            <circle className="core" cx={c} cy={c} r={46} />
            <text x={c} y={c - 4} textAnchor="middle" fontSize="13" fontWeight="600" fill="#070812">Coordinator</text>
            <text x={c} y={c + 13} textAnchor="middle" fontSize="10" fill="#0b1030" fontFamily="var(--mono)">{(str(active_count) + " active") if len(on) else "idle"}</text>
        </g>
        {for (i, a) in enumerate(ring) {
            ang: float = -PI / 2 + (2 * PI * i) / n;
            x: float = c + R * JS.Math.cos(ang);
            y: float = c + R * JS.Math.sin(ang);
            lit: bool = a["name"] in on;
            below: bool = JS.Math.sin(ang) > 0.2;
            <g key={a["name"]} className={"node " + ("on" if lit else "")}>
                <circle className="halo" cx={x} cy={y} r={40} />
                <circle className="bg" cx={x} cy={y} r={27} />
                <@{a["Icon"]} x={x - 11} y={y - 11} width={22} height={22} color={"#dfe3ff" if lit else "#8a90a6"} strokeWidth={1.6} />
                <text x={x} y={y + 46 if below else y - 38} textAnchor="middle">{a["short"]}</text>
                <text x={x} y={y + 60 if below else y - 52} textAnchor="middle" style={{"fontSize": 9, "fill": "#7fdcf0" if a["kind"] == "rules" else "#a9b2ff", "opacity": 0.8}}>
                    {"RULES · CODE" if a["kind"] == "rules" else "AGENT · AI"}
                </text>
            </g>
        }}
    </svg>
}
