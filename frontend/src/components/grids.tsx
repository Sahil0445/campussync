import { AlertTriangle, Check, OctagonX } from "lucide-react";
import { DAYS, range } from "../lib/time";

/* ---------------- availability preview (student) ---------------- */
export interface Block { day: number; start: number; end: number; title: string; source: string }

const G_START = 6 * 60;
const G_END = 24 * 60;

export function WeekGrid({ blocks, hour = 26 }: { blocks: Block[]; hour?: number }) {
  const height = ((G_END - G_START) / 60) * hour;
  const y = (m: number) => ((Math.min(Math.max(m, G_START), G_END) - G_START) / 60) * hour;
  return (
    <div className="wgrid" style={{ ["--hour" as any]: `${hour}px` }} role="img" aria-label="Weekly availability preview">
      <div className="hd" />
      {DAYS.map((d) => <div key={d} className="hd">{d}</div>)}
      <div className="times" style={{ height }}>
        {Array.from({ length: (G_END - G_START) / 60 - 1 }, (_, i) => (
          <span key={i} style={{ top: (i + 1) * hour }}>{String(G_START / 60 + 1 + i).padStart(2, "0")}</span>
        ))}
      </div>
      {DAYS.map((_, day) => (
        <div key={day} className="col" style={{ height }}>
          {blocks.filter((b) => b.day === day && b.end > G_START && b.start < G_END).map((b, i) => (
            <div key={i} className={`blk ${b.source === "note" ? "rule" : b.source === "shift" ? "shift" : ""}`}
                 style={{ top: y(b.start), height: Math.max(12, y(b.end) - y(b.start)) }} title={`${b.title} · ${range(b.start, b.end)}`}>
              {y(b.end) - y(b.start) >= 22 ? b.title : ""}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

/* ---------------- coverage grid (department) ---------------- */
export interface Person { student_id: number; name: string; new?: boolean; pending?: boolean }
export interface Cell { day: number; start: number; end: number; needed: number; assigned: number; people: Person[]; position_id?: number | null; role?: string; color?: string; planned?: boolean }
export interface Coverage { rows: { start: number; end: number }[]; cells: Cell[] }

export function CoverageGrid({ coverage, onCell, showNames = true, skeleton, reveal }: {
  coverage: Coverage; onCell?: (c: Cell) => void; showNames?: boolean; skeleton?: boolean; reveal?: number;
}) {
  const find = (d: number, s: number, e: number) => coverage.cells.find((c) => c.day === d && c.start === s && c.end === e);
  const days = DAYS.map((_, i) => i).filter((d) => coverage.cells.some((c) => c.day === d));
  let order = 0;
  return (
    <div className="cov-scroll">
      <table className="cov" style={{ minWidth: Math.max(520, 110 + days.length * 100) }}>
        <thead>
          <tr>
            <th scope="col"><span className="sr-only">Time</span></th>
            {days.map((d) => <th key={d} scope="col">{DAYS[d]}</th>)}
          </tr>
        </thead>
        <tbody>
          {coverage.rows.map((r) => (
            <tr key={`${r.start}-${r.end}`}>
              <td><span className="mono ink-2">{range(r.start, r.end)}</span></td>
              {days.map((day) => {
                const c = find(day, r.start, r.end);
                if (!c) return <td key={day}><div className="cell none" aria-label="No need defined" /></td>;
                const idx = order++;
                if (skeleton && (reveal === undefined || idx >= reveal)) return <td key={day}><div className="cell skeleton" /></td>;
                const state = c.assigned >= c.needed ? "full" : c.assigned === 0 ? "empty" : "partial";
                return (
                  <td key={day}>
                    <button className={`cell ${state} ${skeleton ? "reveal" : ""}`} onClick={() => onCell?.(c)}
                            aria-label={`${DAYS[day]} ${range(c.start, c.end)}: ${c.assigned} of ${c.needed} filled`}>
                      <span className={`count ${state === "full" ? "c-ok" : state === "partial" ? "c-wait" : "c-block"}`}>
                        {state === "full" ? <Check size={14} strokeWidth={2} /> : state === "partial" ? <AlertTriangle size={14} strokeWidth={1.5} /> : <OctagonX size={14} strokeWidth={1.5} />}
                        {c.assigned}/{c.needed}
                        {state === "partial" && <span className="t-small w500">Short {c.needed - c.assigned}</span>}
                        {state === "empty" && <span className="t-small w500">Unfilled</span>}
                      </span>
                      {showNames && c.people.length > 0 && (
                        <span className="names">
                          {c.people.map((p, i) => (
                            <span key={i} className={p.new ? "new" : ""} style={{ display: "block" }}>
                              {p.name}{p.pending ? " ·  swap" : ""}
                            </span>
                          ))}
                        </span>
                      )}
                    </button>
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* ---------------- swap loop diagram ---------------- */
export interface LoopMove { name: string; gives: string | null; gets: string | null; student_id?: number }

export function LoopDiagram({ moves, highlight }: { moves: LoopMove[]; highlight?: string }) {
  const n = moves.length;
  const W = 360, H = 280, cx = W / 2, cy = H / 2, R = n <= 2 ? 72 : 88, r = 20;
  const pts = moves.map((_, i) => {
    const a = -Math.PI / 2 + (2 * Math.PI * i) / n + (n === 2 ? 0 : 0);
    return { x: cx + R * Math.cos(a), y: cy + R * Math.sin(a) };
  });
  // Arrow i goes from giver (i-1) to receiver i, carrying moves[i].gets.
  const arrows = moves.map((m, i) => {
    if (!m.gets) return null;
    const from = pts[(i - 1 + n) % n];
    const to = pts[i];
    const dx = to.x - from.x, dy = to.y - from.y;
    const len = Math.hypot(dx, dy) || 1;
    const ux = dx / len, uy = dy / len;
    const nx = -uy, ny = ux; // left normal; clockwise order makes this point outward
    const bow = n === 2 ? 34 : 22;
    const s = { x: from.x + ux * (r + 5), y: from.y + uy * (r + 5) };
    const e = { x: to.x - ux * (r + 7), y: to.y - uy * (r + 7) };
    const c = { x: (from.x + to.x) / 2 - nx * bow, y: (from.y + to.y) / 2 - ny * bow };
    const mid = { x: 0.25 * s.x + 0.5 * c.x + 0.25 * e.x, y: 0.25 * s.y + 0.5 * c.y + 0.25 * e.y };
    const lx = mid.x - nx * 14, ly = mid.y - ny * 14;
    return { d: `M${s.x},${s.y} Q${c.x},${c.y} ${e.x},${e.y}`, label: m.gets, lx, ly, anchor: Math.abs(nx) < 0.3 ? "middle" : -nx > 0 ? "start" : "end" };
  });
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" style={{ maxWidth: 400, display: "block", margin: "0 auto", overflow: "visible" }} role="img"
         aria-label={`Swap loop: ${moves.map((m) => m.name).join(" → ")}`}>
      <defs>
        <marker id="arrowhead" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0,0 L10,5 L0,10 z" fill="#8fa6ff" />
        </marker>
        <linearGradient id="lg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#a18bff" /><stop offset="1" stopColor="#3dd8f5" /></linearGradient>
        <filter id="lglow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3" result="b" /><feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge></filter>
      </defs>
      {arrows.map((a, i) => a && (
        <g key={i}>
          <path d={a.d} fill="none" stroke="url(#lg)" strokeWidth="1.6" className="loop-edge" markerEnd="url(#arrowhead)" />
          <text x={a.lx} y={a.ly} textAnchor={a.anchor as any} dominantBaseline="middle" fontFamily="var(--mono)" fontSize="10.5" fill="var(--ink-2)">{a.label}</text>
        </g>
      ))}
      {moves.map((m, i) => {
        const me = highlight && m.name === highlight;
        return (
          <g key={i}>
            <circle cx={pts[i].x} cy={pts[i].y} r={r} fill={me ? "url(#lg)" : "#0c0f18"} stroke={me ? "none" : "url(#lg)"} strokeWidth="1.4" filter="url(#lglow)" />
            <text x={pts[i].x} y={pts[i].y} textAnchor="middle" dominantBaseline="central" fontSize="13" fontWeight="600" fill={me ? "#070812" : "var(--ink)"}>{m.name.slice(0, 1)}</text>
            {(() => {
              const dx = pts[i].x - cx, dy = pts[i].y - cy, len = Math.hypot(dx, dy) || 1;
              const lx = pts[i].x + (dx / len) * (r + 12), ly = pts[i].y + (dy / len) * (r + 12);
              const anchor = Math.abs(dx / len) < 0.3 ? "middle" : dx > 0 ? "start" : "end";
              return <text x={lx} y={ly} textAnchor={anchor} dominantBaseline="middle" fontSize="11.5" fill="var(--ink-2)">{m.name}</text>;
            })()}
          </g>
        );
      })}
    </svg>
  );
}
