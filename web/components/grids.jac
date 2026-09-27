"""Week grids: the employee's availability preview, the employer's coverage table and the swap-loop diagram."""

import from "lucide-react" { AlertTriangle, Check, OctagonX }
import from web.lib.time { DAYS, hmRange, pad2 }

glob:pub JS: any = globalThis;
glob:pub G_START: int = 6 * 60;
glob:pub G_END: int = 24 * 60;

# ---------------- availability preview (employee) ----------------
"""blocks: [{day, start, end, title, source}]"""
def:pub WeekGrid(blocks: any, hour: int = 26) -> JsxElement {
    height: float = ((G_END - G_START) / 60) * hour;
    def y(m: int) -> float {
        return ((JS.Math.min(JS.Math.max(m, G_START), G_END) - G_START) / 60) * hour;
    }
    style: any = {};
    style["--hour"] = str(hour) + "px";
    nlabels: int = (G_END - G_START) // 60 - 1;
    <div className="wgrid" style={style} role="img" aria-label="Weekly availability preview">
        <div className="hd" />
        {for d in DAYS { <div key={d} className="hd">{d}</div> }}
        <div className="times" style={{"height": height}}>
            {for i in range(nlabels) {
                <span key={i} style={{"top": (i + 1) * hour}}>{pad2(G_START // 60 + 1 + i)}</span>
            }}
        </div>
        {for day in range(7) {
            <div key={day} className="col" style={{"height": height}}>
                {for (i, b) in enumerate([b for b in blocks if b.day == day and b.end > G_START and b.start < G_END]) {
                    top: float = y(b.start);
                    h: float = y(b.end) - y(b.start);
                    <div key={i} className={"blk " + ("rule" if b.source == "note" else ("shift" if b.source == "shift" else ""))}
                        style={{"top": top, "height": JS.Math.max(12, h)}} title={b.title + " · " + hmRange(b.start, b.end)}>
                        {b.title if h >= 22 else ""}
                    </div>
                }}
            </div>
        }}
    </div>
}

# ---------------- coverage grid (employer) ----------------
"""coverage: {rows: [{start, end}], cells: [{day, start, end, needed, assigned, people: [{student_id, name, new?, pending?}], position_id?, role?, color?}]}"""
def:pub CoverageGrid(coverage: any, onCell: any = None, showNames: bool = True, skeleton: bool = False, reveal: int = -1) -> JsxElement {
    cells: any = coverage.cells;
    def find(d: int, s: int, e: int) -> any {
        for c in cells {
            if c.day == d and c.start == s and c.end == e {
                return c;
            }
        }
        return None;
    }
    days: list[int] = [d for d in range(7) if any([c.day == d for c in cells])];
    counter: any = {"n": 0};
    def pick(c: any) -> any {
        return lambda (e: MouseEvent) {
            if onCell {
                onCell(c);
            }
        };
    }
    <div className="cov-scroll">
        <table className="cov" style={{"minWidth": JS.Math.max(520, 110 + len(days) * 100)}}>
            <thead>
                <tr>
                    <th scope="col"><span className="sr-only">Time</span></th>
                    {for d in days { <th key={d} scope="col">{DAYS[d]}</th> }}
                </tr>
            </thead>
            <tbody>
                {for r in coverage.rows {
                    <tr key={str(r.start) + "-" + str(r.end)}>
                        <td><span className="mono ink-2">{hmRange(r.start, r.end)}</span></td>
                        {for day in days {
                            c: any = find(day, r.start, r.end);
                            if not c {
                                <td key={day}><div className="cell none" aria-label="No need defined" /></td>
                            } else {
                                idx: int = counter["n"];
                                counter["n"] = idx + 1;
                                if skeleton and (reveal < 0 or idx >= reveal) {
                                    <td key={day}><div className="cell skeleton" /></td>
                                } else {
                                    state: str = "full" if c.assigned >= c.needed else ("empty" if c.assigned == 0 else "partial");
                                    <td key={day}>
                                        <button className={"cell " + state + " " + ("reveal" if skeleton else "")} onClick={pick(find(day, r.start, r.end))}
                                            aria-label={DAYS[day] + " " + hmRange(c.start, c.end) + ": " + str(c.assigned) + " of " + str(c.needed) + " filled"}>
                                            <span className={"count " + ("c-ok" if state == "full" else ("c-wait" if state == "partial" else "c-block"))}>
                                                {<Check size={14} strokeWidth={2} /> if state == "full" else (<AlertTriangle size={14} strokeWidth={1.5} /> if state == "partial" else <OctagonX size={14} strokeWidth={1.5} />)}
                                                {c.assigned}/{c.needed}
                                                {state == "partial" and <span className="t-small w500">Short {c.needed - c.assigned}</span>}
                                                {state == "empty" and <span className="t-small w500">Unfilled</span>}
                                            </span>
                                            {showNames and c.people.length > 0 and <span className="names">
                                                {for (i, p) in enumerate(c.people) {
                                                    <span key={i} className={"new" if p.new else ""} style={{"display": "block"}}>
                                                        {p.name}{" ·  swap" if p.pending else ""}
                                                    </span>
                                                }}
                                            </span>}
                                        </button>
                                    </td>
                                }
                            }
                        }}
                    </tr>
                }}
            </tbody>
        </table>
    </div>
}

# ---------------- swap loop diagram ----------------
"""moves: [{name, gives, gets, student_id?}]"""
def:pub LoopDiagram(moves: any, highlight: str = "") -> JsxElement {
    n: int = moves.length;
    W = 360;
    H = 280;
    cx: float = W / 2;
    cy: float = H / 2;
    R: float = 72 if n <= 2 else 88;
    r = 20;
    PI: float = JS.Math.PI;
    pts: list[dict[str, float]] = [];
    for i in range(n) {
        a: float = -PI / 2 + (2 * PI * i) / n;
        pts.append({"x": cx + R * JS.Math.cos(a), "y": cy + R * JS.Math.sin(a)});
    }
    # Arrow i goes from giver (i-1) to receiver i, carrying moves[i].gets.
    arrows: list[any] = [];
    for i in range(n) {
        m: any = moves[i];
        if not m.gets {
            arrows.append(None);
            continue;
        }
        frm = pts[(i - 1 + n) % n];
        to = pts[i];
        dx: float = to["x"] - frm["x"];
        dy: float = to["y"] - frm["y"];
        ln: float = JS.Math.hypot(dx, dy) or 1;
        ux: float = dx / ln;
        uy: float = dy / ln;
        nx: float = -uy;
        ny: float = ux;
        bow: float = 34 if n == 2 else 22;
        sx: float = frm["x"] + ux * (r + 5);
        sy: float = frm["y"] + uy * (r + 5);
        ex: float = to["x"] - ux * (r + 7);
        ey: float = to["y"] - uy * (r + 7);
        qx: float = (frm["x"] + to["x"]) / 2 - nx * bow;
        qy: float = (frm["y"] + to["y"]) / 2 - ny * bow;
        mx: float = 0.25 * sx + 0.5 * qx + 0.25 * ex;
        my: float = 0.25 * sy + 0.5 * qy + 0.25 * ey;
        anchor: str = "middle" if JS.Math.abs(nx) < 0.3 else ("start" if -nx > 0 else "end");
        arrows.append({
            "d": "M" + str(sx) + "," + str(sy) + " Q" + str(qx) + "," + str(qy) + " " + str(ex) + "," + str(ey),
            "label": m.gets, "lx": mx - nx * 14, "ly": my - ny * 14, "anchor": anchor
        });
    }
    names: list[str] = [m.name for m in moves];
    <svg viewBox={"0 0 " + str(W) + " " + str(H)} width="100%" style={{"maxWidth": 400, "display": "block", "margin": "0 auto", "overflow": "visible"}} role="img"
        aria-label={"Swap loop: " + " → ".join(names)}>
        <defs>
            <marker id="arrowhead" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                <path d="M0,0 L10,5 L0,10 z" fill="#8fa6ff" />
            </marker>
            <linearGradient id="lg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#a18bff" /><stop offset="1" stopColor="#3dd8f5" /></linearGradient>
            <filter id="lglow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3" result="b" /><feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge></filter>
        </defs>
        {for (i, a) in enumerate(arrows) {
            if a {
                <g key={i}>
                    <path d={a["d"]} fill="none" stroke="url(#lg)" strokeWidth="1.6" className="loop-edge" markerEnd="url(#arrowhead)" />
                    <text x={a["lx"]} y={a["ly"]} textAnchor={a["anchor"]} dominantBaseline="middle" fontFamily="var(--mono)" fontSize="10.5" fill="var(--ink-2)">{a["label"]}</text>
                </g>
            }
        }}
        {for (i, m) in enumerate(moves) {
            me: bool = highlight != "" and m.name == highlight;
            px: float = pts[i]["x"];
            py: float = pts[i]["y"];
            dx: float = px - cx;
            dy: float = py - cy;
            ln: float = JS.Math.hypot(dx, dy) or 1;
            lx: float = px + (dx / ln) * (r + 12);
            ly: float = py + (dy / ln) * (r + 12);
            anc: str = "middle" if JS.Math.abs(dx / ln) < 0.3 else ("start" if dx > 0 else "end");
            nm: str = m.name;
            <g key={i}>
                <circle cx={px} cy={py} r={r} fill={"url(#lg)" if me else "#0c0f18"} stroke={"none" if me else "url(#lg)"} strokeWidth="1.4" filter="url(#lglow)" />
                <text x={px} y={py} textAnchor="middle" dominantBaseline="central" fontSize="13" fontWeight="600" fill={"#070812" if me else "var(--ink)"}>{nm[0:1]}</text>
                <text x={lx} y={ly} textAnchor={anc} dominantBaseline="middle" fontSize="11.5" fill="var(--ink-2)">{nm}</text>
            </g>
        }}
    </svg>
}
