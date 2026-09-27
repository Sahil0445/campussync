import { useEffect, useState } from "react";
import { ArrowLeftRight, ChevronLeft, ChevronRight } from "lucide-react";
import type { Cell } from "./grids";

const DOW = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

function dateOf(week: string, day: number) {
  const d = new Date(week + "T12:00:00");
  d.setDate(d.getDate() + day);
  return d;
}
function hourLabel(h: number) {
  if (h === 0 || h === 24) return "12 AM";
  if (h === 12) return "12 PM";
  return h < 12 ? `${h} AM` : `${h - 12} PM`;
}
function time12(m: number) {
  const h = Math.floor(m / 60), mm = m % 60;
  const hh = h % 12 === 0 ? 12 : h % 12;
  return `${hh}${mm ? `:${String(mm).padStart(2, "0")}` : ""}${h % 24 < 12 ? "am" : "pm"}`;
}
export function monthLabel(week: string) {
  const a = dateOf(week, 0), b = dateOf(week, 6);
  const m = (d: Date) => d.toLocaleDateString("en-US", { month: "long" });
  return a.getMonth() === b.getMonth() ? `${m(a)} ${a.getFullYear()}` : `${m(a).slice(0, 3)} – ${m(b).slice(0, 3)} ${b.getFullYear()}`;
}

/** Google-Calendar-style week view. Each staffing slot is an event block, coloured by coverage. */
export function WeekCalendar({ week, cells, onCell, hourHeight = 48, onPrev, onNext, onToday, toolbar = true, skeleton, reveal }: {
  week: string; cells: Cell[]; onCell?: (c: Cell) => void; hourHeight?: number;
  onPrev?: () => void; onNext?: () => void; onToday?: () => void; toolbar?: boolean; skeleton?: boolean; reveal?: number;
}) {
  const [now, setNow] = useState(new Date());
  useEffect(() => { const id = window.setInterval(() => setNow(new Date()), 60000); return () => window.clearInterval(id); }, []);
  const minStart = cells.length ? Math.min(...cells.map((c) => c.start)) : 9 * 60;
  const maxEnd = cells.length ? Math.max(...cells.map((c) => c.end)) : 17 * 60;
  const h0 = Math.max(0, Math.floor(minStart / 60) - 1), h1 = Math.min(24, Math.ceil(maxEnd / 60) + 1);
  const hours = Array.from({ length: h1 - h0 }, (_, i) => h0 + i);
  const y = (m: number) => ((m - h0 * 60) / 60) * hourHeight;
  const todayIdx = [0, 1, 2, 3, 4, 5, 6].find((d) => dateOf(week, d).toDateString() === now.toDateString());
  const ordered = [...cells].sort((a, b) => a.day - b.day || a.start - b.start || (a.position_id ?? 0) - (b.position_id ?? 0));
  // Side-by-side lanes when blocks overlap in time (e.g. two roles at 18:00).
  const lanes = new Map<Cell, { lane: number; of: number; cascade?: boolean }>();
  for (let d = 0; d < 7; d++) {
    const day = ordered.filter((c) => c.day === d);
    let cluster: Cell[] = [], clusterEnd = -1;
    const flush = () => {
      const ends: number[] = [];
      const placed = cluster.map((c) => { let l = ends.findIndex((e) => e <= c.start); if (l < 0) { l = ends.length; ends.push(c.end); } else ends[l] = c.end; return [c, l] as const; });
      // Staggered starts (7am post + 6pm patrol) cascade like Google Calendar; simultaneous starts split the column.
      const starts = cluster.map((c) => c.start).sort((a, b) => a - b);
      const cascade = cluster.length > 1 && starts.every((st, i) => i === 0 || st - starts[i - 1] >= 60);
      placed.forEach(([c, l]) => lanes.set(c, { lane: l, of: ends.length, cascade }));
      cluster = []; clusterEnd = -1;
    };
    for (const c of day) { if (cluster.length && c.start >= clusterEnd) flush(); cluster.push(c); clusterEnd = Math.max(clusterEnd, c.end); }
    flush();
  }

  return (
    <div className="wcal">
      {toolbar && (
        <div className="wcal-bar">
          {onToday && <button className="btn sm" onClick={onToday}>Today</button>}
          {onPrev && <button className="btn icon sm ghost" aria-label="Previous week" onClick={onPrev}><ChevronLeft size={18} /></button>}
          {onNext && <button className="btn icon sm ghost" aria-label="Next week" onClick={onNext}><ChevronRight size={18} /></button>}
          <span className="wcal-month">{monthLabel(week)}</span>
          <span className="wcal-legend hide-mobile">
            <span><i className="lg lg-full" />Staffed</span><span><i className="lg lg-partial" />Short</span><span><i className="lg lg-empty" />Unfilled</span>
          </span>
        </div>
      )}
      <div className="wcal-scroll">
        <div className="wcal-grid">
          <div className="wcal-head">
            <div className="wcal-gutter" />
            {DOW.map((d, i) => {
              const date = dateOf(week, i);
              return (
                <div key={d} className={`wcal-day ${i === todayIdx ? "today" : ""}`}>
                  <span className="dow">{d.toUpperCase()}</span>
                  <span className="dnum">{date.getDate()}</span>
                </div>
              );
            })}
          </div>
          <div className="wcal-body" style={{ height: hours.length * hourHeight }}>
            <div className="wcal-gutter">
              {hours.slice(1).map((h) => <span key={h} style={{ top: y(h * 60) }}>{hourLabel(h)}</span>)}
            </div>
            {DOW.map((_, day) => (
              <div key={day} className="wcal-col" style={{ backgroundSize: `100% ${hourHeight}px` }}>
                {ordered.filter((c) => c.day === day).map((c) => {
                  const idx = ordered.indexOf(c);
                  const state = c.assigned >= c.needed ? "full" : c.assigned === 0 ? "empty" : "partial";
                  const top = y(c.start), height = Math.max(22, y(c.end) - y(c.start) - 3);
                  const ln = lanes.get(c) ?? { lane: 0, of: 1 };
                  const place = ln.cascade
                    ? { top, height, left: `calc(${ln.lane * 22}% + 2px)`, width: `calc(${100 - ln.lane * 22}% - 4px)`, right: "auto", zIndex: 1 + ln.lane,
                        boxShadow: ln.lane ? `${c.role ? "inset 3px 0 0 var(--role), " : ""}0 0 0 2px var(--bg-2)` : undefined }
                    : { top, height, left: `calc(${(ln.lane / ln.of) * 100}% + 2px)`, width: `calc(${100 / ln.of}% - 4px)`, right: "auto" };
                  const key = `${c.start}-${c.end}-${c.position_id ?? 0}`;
                  if (skeleton && (reveal === undefined || idx >= reveal)) {
                    return <div key={key} className="wcal-ev skel" style={place} />;
                  }
                  const names = c.people.map((p) => p.name).join(", ");
                  const title = state === "empty" ? "Unfilled" : state === "partial" ? `${names} · need ${c.needed - c.assigned}` : names;
                  return (
                    <button key={key} className={`wcal-ev ${state} ${skeleton ? "pop" : ""} ${c.role ? "has-role" : ""}`} style={{ ...place, ...(c.color ? { ["--role" as any]: c.color } : {}) }}
                            onClick={() => onCell?.(c)} aria-label={`${DOW[day]} ${time12(c.start)} to ${time12(c.end)}${c.role ? `, ${c.role}` : ""}: ${c.assigned} of ${c.needed} staffed`}>
                      <span className="ev-title">
                        {c.people.some((p) => p.pending) && <ArrowLeftRight size={11} style={{ marginRight: 4, verticalAlign: -1 }} />}
                        {title}
                      </span>
                      {c.role && <span className="ev-role"><i style={{ background: c.color || "var(--accent)" }} />{c.role}</span>}
                      <span className="ev-time">{time12(c.start)} – {time12(c.end)} · {c.assigned}/{c.needed}</span>
                      {height > 70 && c.people.some((p) => p.new) && <span className="ev-new">New from draft</span>}
                    </button>
                  );
                })}
                {day === todayIdx && now.getHours() >= h0 && now.getHours() < h1 && (
                  <div className="wcal-now" style={{ top: y(now.getHours() * 60 + now.getMinutes()) }}><i /></div>
                )}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
