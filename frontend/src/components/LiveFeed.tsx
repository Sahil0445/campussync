import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { walker } from "../lib/api";
import { ago } from "../lib/time";

export interface AgentEvent { id: number; agent: string; kind: string; text: string; level: string; link: string; seconds_ago: number; at?: number }

const stamp = (xs: AgentEvent[]) => xs.map((e) => (e.at ? e : { ...e, at: Date.now() - e.seconds_ago * 1000 }));

/** Polls the agent event log and streams new rows in. `onActive` reports agents seen in the last ~20s. */
export function useAgentFeed(initial: AgentEvent[] | undefined, poll = 2500, onActive?: (agents: string[]) => void) {
  const [events, setEvents] = useState<AgentEvent[]>(stamp(initial ?? []));
  const [, setNow] = useState(0);
  const last = useRef(0);
  const cb = useRef(onActive);
  cb.current = onActive;
  useEffect(() => {
    if (initial && !events.length) { setEvents(stamp(initial)); }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initial]);
  useEffect(() => { last.current = Math.max(last.current, ...events.map((e) => e.id)); }, [events]);
  useEffect(() => {
    let alive = true;
    const run = async () => {
      if (document.hidden) return;
      try {
        const r = await walker<{ events: AgentEvent[] }>("get_agent_feed", { since: last.current, limit: 30 });
        if (!alive || !r.events.length) return;
        setEvents((xs) => {
          const seen = new Set(xs.map((x) => x.id));
          const fresh = stamp(r.events.filter((x) => !seen.has(x.id)));
          return fresh.length ? [...fresh, ...xs].sort((a, b) => b.id - a.id).slice(0, 80) : xs;
        });
      } catch { /* offline: keep what we have */ }
    };
    run();
    const id = window.setInterval(() => { run(); setNow(Date.now()); }, poll);
    return () => { alive = false; window.clearInterval(id); };
  }, [poll]);
  const recent = events.filter((e) => Date.now() - (e.at ?? 0) < 20000 && e.kind !== "human").map((e) => e.agent);
  const key = Array.from(new Set(recent)).sort().join("|");
  useEffect(() => { cb.current?.(key ? key.split("|") : []); }, [key]);
  return events;
}

export function LiveFeed({ events, limit = 12, empty = "Agents are standing by." }: { events: AgentEvent[]; limit?: number; empty?: string }) {
  const nav = useNavigate();
  if (!events.length) return <div className="ink-3" style={{ padding: "12px 0" }}>{empty}</div>;
  return (
    <div className="feed" aria-live="polite">
      {events.slice(0, limit).map((e) => (
        <div key={e.id} className="feed-row">
          <span className={`feed-dot ${e.level}`} />
          <div className="stack g4">
            <div className="feed-meta"><span style={{ color: e.kind === "rules" ? "#7fdcf0" : e.kind === "human" ? "#ffe3a3" : "#b9c1ff" }}>{e.agent}</span><span>·</span><span>{ago(Math.max(0, Math.round((Date.now() - (e.at ?? Date.now() - e.seconds_ago * 1000)) / 1000)))}</span></div>
            {e.link ? (
              <a href={e.link} className="feed-text" onClick={(ev) => { ev.preventDefault(); nav(e.link); }}>{e.text}</a>
            ) : <span className="feed-text">{e.text}</span>}
          </div>
        </div>
      ))}
    </div>
  );
}
