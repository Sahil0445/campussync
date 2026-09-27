import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

/* Categorical palette validated for the dark card surface (#0c0e15): lightness band, chroma, CVD & contrast all pass.
   Colour follows the entity (series key), never its rank. Past five series fold into "Other". */
const PALETTE = ["#8a7dff", "#d95926", "#16a3b8", "#c98500", "#d55181"];
const OTHER = "#6b7185";

export interface ChartSeries { key: string; label: string; values: number[] }
export interface ChartBucket { key: string; label: string; sub: string }

function niceMax(v: number) {
  if (v <= 0) return 1;
  const pow = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * pow >= v) return m * pow;
  return 10 * pow;
}

function topRounded(x: number, y: number, w: number, h: number, r: number) {
  const rr = Math.min(r, w / 2, h);
  return `M${x},${y + h} V${y + rr} Q${x},${y} ${x + rr},${y} H${x + w - rr} Q${x + w},${y} ${x + w},${y + rr} V${y + h} Z`;
}

export function colorFor(keys: string[]) {
  const sorted = [...keys].sort();
  return (k: string) => { const i = sorted.indexOf(k); return i >= 0 && i < PALETTE.length ? PALETTE[i] : OTHER; };
}

export function HoursChart({ buckets, series, scheduled, format, unit, height = 200, allKeys }: {
  buckets: ChartBucket[]; series: ChartSeries[]; scheduled?: number[]; format: (v: number) => string; unit: string; height?: number;
  allKeys?: string[];
}) {
  const wrap = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(320);
  const [hover, setHover] = useState<number | null>(null);
  useLayoutEffect(() => {
    const el = wrap.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    setWidth(el.clientWidth);
    return () => ro.disconnect();
  }, []);
  useEffect(() => setHover(null), [buckets]);

  // Fold anything past the palette into "Other" so no hue is ever generated.
  const color = colorFor(allKeys ?? series.map((s) => s.key));
  const shown = useMemo(() => {
    const named = series.filter((s) => color(s.key) !== OTHER);
    const rest = series.filter((s) => color(s.key) === OTHER);
    if (!rest.length) return named;
    return [...named, { key: "~other", label: "Other", values: buckets.map((_, i) => rest.reduce((a, s) => a + (s.values[i] || 0), 0)) }];
  }, [series, buckets]); // eslint-disable-line react-hooks/exhaustive-deps
  const colorOf = (k: string) => (k === "~other" ? OTHER : color(k));

  const totals = buckets.map((_, i) => shown.reduce((a, s) => a + (s.values[i] || 0), 0));
  const sched = scheduled ?? buckets.map(() => 0);
  const max = niceMax(Math.max(0, ...totals.map((t, i) => t + (sched[i] || 0))));
  const ticks = [0, max / 2, max];
  const padL = 36, padR = 4, padT = 8, padB = 26;
  const innerW = Math.max(40, width - padL - padR), innerH = height - padT - padB;
  const band = innerW / Math.max(1, buckets.length);
  const barW = Math.max(3, Math.min(24, band * 0.62));
  const y = (v: number) => padT + innerH - (v / max) * innerH;
  const every = buckets.length > 14 ? Math.ceil(buckets.length / 7) : 1;
  const hasData = totals.some((t) => t > 0) || sched.some((t) => t > 0);

  return (
    <div className="hchart" ref={wrap}>
      <svg width={width} height={height} role="img" aria-label={`${unit} per ${buckets.length > 12 ? "day" : buckets.length === 12 ? "month" : "day"}`}>
        <defs>
          <pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
            <rect width="6" height="6" fill="rgba(255,255,255,0.04)" />
            <line x1="0" y1="0" x2="0" y2="6" stroke="rgba(166,171,189,0.55)" strokeWidth="2" />
          </pattern>
        </defs>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={padL} x2={width - padR} y1={y(t)} y2={y(t)} stroke="rgba(255,255,255,0.07)" strokeWidth={1} />
            <text x={padL - 8} y={y(t) + 4} textAnchor="end" className="hchart-tick">{format(t)}</text>
          </g>
        ))}
        {buckets.map((b, i) => {
          const cx = padL + band * i + band / 2;
          let acc = 0;
          const segs = shown.map((s) => ({ key: s.key, v: s.values[i] || 0 })).filter((s) => s.v > 0);
          const topKey = sched[i] > 0 ? "~sched" : segs.length ? segs[segs.length - 1].key : null;
          return (
            <g key={b.key}>
              {segs.map((s, j) => {
                const y0 = y(acc), y1 = y(acc + s.v);
                acc += s.v;
                const gap = j > 0 ? 2 : 0; // surface gap between stacked segments
                const h = Math.max(1, y0 - y1 - gap);
                return s.key === topKey
                  ? <path key={s.key} d={topRounded(cx - barW / 2, y1, barW, h, 4)} fill={colorOf(s.key)} />
                  : <rect key={s.key} x={cx - barW / 2} y={y1} width={barW} height={h} fill={colorOf(s.key)} />;
              })}
              {sched[i] > 0 && (() => {
                const y0 = y(acc), y1 = y(acc + sched[i]);
                const h = Math.max(1, y0 - y1 - (acc > 0 ? 2 : 0));
                return <path d={topRounded(cx - barW / 2, y1, barW, h, 4)} fill="url(#hatch)" />;
              })()}
              {i % every === 0 && <text x={cx} y={height - 8} textAnchor="middle" className={`hchart-x ${hover === i ? "on" : ""}`}>{band < 30 && buckets.length === 12 ? b.label[0] : b.label}</text>}
              <rect x={padL + band * i} y={padT} width={band} height={innerH} fill="transparent"
                    onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover(null)} onClick={() => setHover(hover === i ? null : i)} />
              {hover === i && <line x1={cx} x2={cx} y1={padT} y2={padT + innerH} stroke="rgba(255,255,255,0.12)" strokeWidth={1} pointerEvents="none" />}
            </g>
          );
        })}
      </svg>
      {!hasData && <div className="hchart-empty">No hours in this period yet.</div>}
      {hover !== null && (totals[hover] > 0 || sched[hover] > 0) && (
        <div className="hchart-tip" style={{ left: Math.min(Math.max(8, padL + band * hover + band / 2 - 90), width - 188) }}>
          <div className="w600">{buckets[hover].sub || buckets[hover].label}</div>
          {shown.filter((s) => (s.values[hover] || 0) > 0).map((s) => (
            <div key={s.key} className="row g8"><i className="sw" style={{ background: colorOf(s.key) }} /><span className="grow ink-2">{s.label}</span><span className="num">{format(s.values[hover])}</span></div>
          ))}
          {sched[hover] > 0 && <div className="row g8"><i className="sw hatch" /><span className="grow ink-2">Scheduled</span><span className="num">{format(sched[hover])}</span></div>}
          {shown.length > 1 && totals[hover] > 0 && <div className="row g8 hairline-top" style={{ paddingTop: 4 }}><span className="grow ink-2">Total</span><span className="num w600">{format(totals[hover])}</span></div>}
        </div>
      )}
      {(shown.length > 1 || sched.some((v) => v > 0)) && (
        <div className="hchart-legend">
          {shown.map((s) => <span key={s.key}><i className="sw" style={{ background: colorOf(s.key) }} />{s.label}</span>)}
          {sched.some((v) => v > 0) && <span><i className="sw hatch" />Scheduled</span>}
        </div>
      )}
    </div>
  );
}

/** The same numbers as a table (accessibility + exact values). */
export function ChartTable({ buckets, series, format }: { buckets: ChartBucket[]; series: ChartSeries[]; format: (v: number) => string }) {
  const rows = buckets.map((b, i) => ({ b, vals: series.map((s) => s.values[i] || 0) })).filter((r) => r.vals.some((v) => v > 0));
  if (!rows.length) return <div className="ink-3 t-small">Nothing to show.</div>;
  return (
    <div className="table-wrap"><table className="table compact">
      <thead><tr><th>Date</th>{series.map((s) => <th key={s.key}>{s.label}</th>)}{series.length > 1 && <th>Total</th>}</tr></thead>
      <tbody>{rows.map(({ b, vals }) => (
        <tr key={b.key}><td>{b.sub || b.label}</td>{vals.map((v, i) => <td key={i} className="num">{v ? format(v) : "—"}</td>)}
          {series.length > 1 && <td className="num w600">{format(vals.reduce((a, x) => a + x, 0))}</td>}</tr>
      ))}</tbody>
    </table></div>
  );
}
