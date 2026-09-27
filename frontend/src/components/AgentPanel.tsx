import { useEffect, useMemo, useRef, useState } from "react";
import { Check, X } from "lucide-react";

export interface TraceRow { agent: string; kind: "agent" | "rules" | "final" | "human"; result: string; status: "done" | "blocked"; ai?: boolean }

const reduced = () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

/** Replays a workflow trace 400ms per row, like a live terminal. Works even when the backend answered instantly. */
export function AgentPanel({ trace, pending, onDone, onProgress, collapsible, defaultCollapsed, replay = true, title = "agents · live" }: {
  trace: TraceRow[] | null; pending?: boolean; onDone?: () => void; onProgress?: (shown: number) => void;
  collapsible?: boolean; defaultCollapsed?: boolean; replay?: boolean; title?: string;
}) {
  const rows = trace ?? [];
  const key = useMemo(() => JSON.stringify(rows), [rows]);
  const [shown, setShown] = useState(replay && !reduced() ? 0 : rows.length);
  const [collapsed, setCollapsed] = useState(!!defaultCollapsed);
  const doneRef = useRef(onDone);
  doneRef.current = onDone;
  const progressRef = useRef(onProgress);
  progressRef.current = onProgress;
  useEffect(() => { progressRef.current?.(shown); }, [shown]);

  useEffect(() => {
    if (!rows.length) { setShown(0); return; }
    if (!replay || reduced()) { setShown(rows.length); doneRef.current?.(); return; }
    setShown(1);
    let n = 1;
    const id = window.setInterval(() => {
      n += 1;
      setShown(n);
      if (n >= rows.length) { window.clearInterval(id); window.setTimeout(() => doneRef.current?.(), 150); }
    }, 400);
    return () => window.clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, replay]);

  const running = pending || shown < rows.length;
  const steps = rows.filter((r) => r.kind !== "final");
  const issues = steps.filter((r) => r.status === "blocked").length;
  const fallback = rows.some((r) => r.ai === false);

  if (collapsible && collapsed && !running) {
    return (
      <div className="agents agents-collapsed">
        <span className="ink-2">{steps.length} agent steps · {issues ? `${issues} flagged something` : "no issues"}</span>
        <button className="kbd-link" onClick={() => setCollapsed(false)}>Show trace</button>
      </div>
    );
  }
  const visible = rows.slice(0, shown);
  return (
    <section className="agents" aria-label="Agent activity" aria-live="polite">
      <div className="agents-head">
        <span className="dots"><i /><i /><i /></span>
        {title}
        {running && <span className="live violet" style={{ marginLeft: 4 }} aria-label="Running" />}
        {collapsible && !running && <button className="kbd-link" style={{ marginLeft: "auto", fontSize: 12 }} onClick={() => setCollapsed(true)}>Hide</button>}
      </div>
      {pending && !rows.length && (
        <div className="agent-row">
          <span className="run-dot" />
          <div><span className="name">Coordinator</span> <span className="res">spinning up agents…</span></div>
          <span className="tag agent">agent</span>
        </div>
      )}
      {visible.map((r, i) =>
        r.kind === "final" ? (
          <div key={i} className={`agent-final ${r.status === "blocked" ? "bad" : ""}`}>
            {r.status === "blocked" ? <X size={16} className="c-block" /> : <Check size={16} className="c-ok" />}{r.result}
          </div>
        ) : (
          <div key={i} className="agent-row">
            {i === visible.length - 1 && running ? <span className="run-dot" aria-label="Running" />
              : r.status === "blocked" ? <X size={15} strokeWidth={2.2} className="c-wait" aria-label="Flagged" />
              : <Check size={15} strokeWidth={2.2} className="c-ok" aria-label="Done" />}
            <div className="grow"><span className="name">{r.agent}</span>{"  "}<span className="res">{r.result}</span></div>
            <span className={`tag ${r.kind}`}>{r.kind === "rules" ? "rules · code" : r.kind === "human" ? "human" : "agent · AI"}</span>
          </div>
        ),
      )}
      {fallback && !running && <div className="agent-foot">AI model offline — agent steps used built-in heuristics. Rules are unaffected.</div>}
    </section>
  );
}
