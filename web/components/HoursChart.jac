"""Stacked bar chart of hours or pay per day/month, plus the same numbers as a table.

Categorical palette validated for the dark card surface (#0c0e15). Colour follows the entity (series key),
never its rank. Past five series fold into "Other".
"""

import from react { useEffect, useLayoutEffect, useRef, useState }

glob:pub JS: any = globalThis;
glob:pub PALETTE: list[str] = ["#8a7dff", "#d95926", "#16a3b8", "#c98500", "#d55181"];
glob:pub OTHER: str = "#6b7185";

def niceMax(v: float) -> float {
    if v <= 0 {
        return 1;
    }
    pw: float = JS.Math.pow(10, JS.Math.floor(JS.Math.log10(v)));
    for m in [1, 2, 2.5, 5, 10] {
        if m * pw >= v {
            return m * pw;
        }
    }
    return 10 * pw;
}

def topRounded(x: float, y: float, w: float, h: float, r: float) -> str {
    rr: float = JS.Math.min(r, w / 2, h);
    return (
        "M" + str(x) + "," + str(y + h) + " V" + str(y + rr) + " Q" + str(x) + "," + str(y) + " " + str(x + rr) + "," + str(y)
        + " H" + str(x + w - rr) + " Q" + str(x + w) + "," + str(y) + " " + str(x + w) + "," + str(y + rr)
        + " V" + str(y + h) + " Z"
    );
}

def:pub colorFor(keys: any) -> any {
    srt: list[str] = sorted([str(k) for k in keys]);
    def pick(k: str) -> str {
        i: int = srt.index(k) if k in srt else -1;
        return PALETTE[i] if i >= 0 and i < len(PALETTE) else OTHER;
    }
    return pick;
}

"""buckets: [{key, label, sub}] -- series: [{key, label, values}] -- format(v) -> str"""
def:pub HoursChart(
    buckets: any,
    series: any,
    format: any,
    unit: str,
    scheduled: any = None,
    height: int = 200,
    allKeys: any = None
) -> JsxElement {
    wrap: any = useRef(None);
    st_w: any = useState(320);
    width: float = st_w[0];
    setWidth: any = st_w[1];
    st_h: any = useState(-1);
    hover: int = st_h[0];
    setHover: any = st_h[1];
    useLayoutEffect(
        lambda -> any {
            el: any = wrap.current;
            if not el {
                return JS.undefined;
            }
            ro: any = new(JS.ResizeObserver, lambda { setWidth(el.clientWidth); });
            ro.observe(el);
            setWidth(el.clientWidth);
            return lambda { ro.disconnect(); };
        },
        []
    );
    useEffect(lambda -> any { setHover(-1); return JS.undefined; }, [buckets]);

    color: any = colorFor(allKeys if allKeys else [s.key for s in series]);
    named: list[any] = [s for s in series if color(s.key) != OTHER];
    rest: list[any] = [s for s in series if color(s.key) == OTHER];
    nb: int = buckets.length;
    shown: list[any] = named;
    if len(rest) {
        other_vals: list[float] = [];
        for i in range(nb) {
            other_vals.append(sum([(s.values[i] or 0) for s in rest]));
        }
        shown = named + [{"key": "~other", "label": "Other", "values": other_vals}];
    }
    def colorOf(k: str) -> str {
        return OTHER if k == "~other" else color(k);
    }
    totals: list[float] = [sum([(s["values"][i] or 0) for s in shown]) for i in range(nb)];
    sched: list[float] = [(scheduled[i] or 0) for i in range(nb)] if scheduled else [0 for i in range(nb)];
    peak: float = 0;
    for i in range(nb) {
        peak = JS.Math.max(peak, totals[i] + sched[i]);
    }
    mx: float = niceMax(peak);
    ticks: list[float] = [0, mx / 2, mx];
    padL = 36;
    padR = 4;
    padT = 8;
    padB = 26;
    innerW: float = JS.Math.max(40, width - padL - padR);
    innerH: float = height - padT - padB;
    band: float = innerW / JS.Math.max(1, nb);
    barW: float = JS.Math.max(3, JS.Math.min(24, band * 0.62));
    def y(v: float) -> float {
        return padT + innerH - (v / mx) * innerH;
    }
    every: int = JS.Math.ceil(nb / 7) if nb > 14 else 1;
    hasData: bool = any([t > 0 for t in totals]) or any([t > 0 for t in sched]);
    anySched: bool = any([v > 0 for v in sched]);
    per: str = "day" if nb > 12 else ("month" if nb == 12 else "day");
    tipLeft: float = JS.Math.min(JS.Math.max(8, padL + band * hover + band / 2 - 90), width - 188) if hover >= 0 else 0;

    def barParts(i: int) -> list[any] {
        cx: float = padL + band * i + band / 2;
        segs: list[dict[str, any]] = [{"key": s["key"], "v": s["values"][i] or 0} for s in shown if (s["values"][i] or 0) > 0];
        topKey: str = "~sched" if sched[i] > 0 else (segs[len(segs) - 1]["key"] if len(segs) else "");
        parts: list[any] = [];
        acc: float = 0;
        for (j, sg) in enumerate(segs) {
            y0: float = y(acc);
            y1: float = y(acc + sg["v"]);
            acc = acc + sg["v"];
            gap: int = 2 if j > 0 else 0;
            h: float = JS.Math.max(1, y0 - y1 - gap);
            if sg["key"] == topKey {
                parts.append(<path key={sg["key"]} d={topRounded(cx - barW / 2, y1, barW, h, 4)} fill={colorOf(sg["key"])} />);
            } else {
                parts.append(<rect key={sg["key"]} x={cx - barW / 2} y={y1} width={barW} height={h} fill={colorOf(sg["key"])} />);
            }
        }
        if sched[i] > 0 {
            sy0: float = y(acc);
            sy1: float = y(acc + sched[i]);
            sh: float = JS.Math.max(1, sy0 - sy1 - (2 if acc > 0 else 0));
            parts.append(<path key="~sched" d={topRounded(cx - barW / 2, sy1, barW, sh, 4)} fill="url(#hatch)" />);
        }
        return parts;
    }

    def enter(i: int) -> any {
        return lambda (e: MouseEvent) { setHover(i); };
    }
    def toggleAt(i: int) -> any {
        return lambda (e: MouseEvent) { setHover(-1 if hover == i else i); };
    }

    <div className="hchart" ref={wrap}>
        <svg width={width} height={height} role="img" aria-label={unit + " per " + per}>
            <defs>
                <pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
                    <rect width="6" height="6" fill="rgba(255,255,255,0.04)" />
                    <line x1="0" y1="0" x2="0" y2="6" stroke="rgba(166,171,189,0.55)" strokeWidth="2" />
                </pattern>
            </defs>
            {for t in ticks {
                <g key={t}>
                    <line x1={padL} x2={width - padR} y1={y(t)} y2={y(t)} stroke="rgba(255,255,255,0.07)" strokeWidth={1} />
                    <text x={padL - 8} y={y(t) + 4} textAnchor="end" className="hchart-tick">{format(t)}</text>
                </g>
            }}
            {for (i, b) in enumerate(buckets) {
                cx: float = padL + band * i + band / 2;
                lbl: str = b.label;
                <g key={b.key}>
                    {barParts(i)}
                    {i % every == 0 and <text x={cx} y={height - 8} textAnchor="middle" className={"hchart-x " + ("on" if hover == i else "")}>{lbl[0:1] if band < 30 and nb == 12 else lbl}</text>}
                    <rect x={padL + band * i} y={padT} width={band} height={innerH} fill="transparent"
                        onMouseEnter={enter(i)} onMouseLeave={lambda (e: MouseEvent) { setHover(-1); }}
                        onClick={toggleAt(i)} />
                    {hover == i and <line x1={cx} x2={cx} y1={padT} y2={padT + innerH} stroke="rgba(255,255,255,0.12)" strokeWidth={1} pointerEvents="none" />}
                </g>
            }}
        </svg>
        {not hasData and <div className="hchart-empty">No hours in this period yet.</div>}
        {hover >= 0 and hover < nb and (totals[hover] > 0 or sched[hover] > 0) and <div className="hchart-tip" style={{"left": tipLeft}}>
            <div className="w600">{buckets[hover].sub or buckets[hover].label}</div>
            {for s in shown {
                if (s["values"][hover] or 0) > 0 {
                    <div key={s["key"]} className="row g8"><i className="sw" style={{"background": colorOf(s["key"])}} /><span className="grow ink-2">{s["label"]}</span><span className="num">{format(s["values"][hover])}</span></div>
                }
            }}
            {sched[hover] > 0 and <div className="row g8"><i className="sw hatch" /><span className="grow ink-2">Scheduled</span><span className="num">{format(sched[hover])}</span></div>}
            {len(shown) > 1 and totals[hover] > 0 and <div className="row g8 hairline-top" style={{"paddingTop": 4}}><span className="grow ink-2">Total</span><span className="num w600">{format(totals[hover])}</span></div>}
        </div>}
        {(len(shown) > 1 or anySched) and <div className="hchart-legend">
            {for s in shown { <span key={s["key"]}><i className="sw" style={{"background": colorOf(s["key"])}} />{s["label"]}</span> }}
            {anySched and <span><i className="sw hatch" />Scheduled</span>}
        </div>}
    </div>
}

"""The same numbers as a table (accessibility + exact values)."""
def:pub ChartTable(buckets: any, series: any, format: any) -> JsxElement {
    rows: list[dict[str, any]] = [];
    for (i, b) in enumerate(buckets) {
        vals: list[float] = [(s.values[i] or 0) for s in series];
        if any([v > 0 for v in vals]) {
            rows.append({"b": b, "vals": vals});
        }
    }
    if not len(rows) {
        return <div className="ink-3 t-small">Nothing to show.</div>;
    }
    multi: bool = series.length > 1;
    <div className="table-wrap"><table className="table compact">
        <thead><tr><th>Date</th>{for s in series { <th key={s.key}>{s.label}</th> }}{multi and <th>Total</th>}</tr></thead>
        <tbody>
            {for row in rows {
                b: any = row["b"];
                vals: list[float] = row["vals"];
                <tr key={b.key}><td>{b.sub or b.label}</td>{for (i, v) in enumerate(vals) { <td key={i} className="num">{format(v) if v else "—"}</td> }}
                    {multi and <td className="num w600">{format(sum(vals))}</td>}</tr>
            }}
        </tbody>
    </table></div>
}
