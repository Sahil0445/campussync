"""Replays a workflow trace 400ms per row, like a live terminal. Works even when the backend answered instantly.

A trace row: {agent, kind: agent|rules|final|human, result, status: done|blocked, ai?}
"""

import from react { useEffect, useRef, useState }
import from "lucide-react" { Check, X }

glob:pub JS: any = globalThis;

def:pub reducedMotion() -> bool {
    w: any = JS.window;
    if not w or not w.matchMedia {
        return False;
    }
    return w.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

def:pub AgentPanel(
    trace: any = None,
    pending: bool = False,
    onDone: any = None,
    onProgress: any = None,
    collapsible: bool = False,
    defaultCollapsed: bool = False,
    replay: bool = True,
    title: str = "agents · live"
) -> JsxElement {
    rows: any = trace or [];
    key: str = JS.JSON.stringify(rows);
    st_shown: any = useState(0 if replay and not reducedMotion() else rows.length);
    shown: int = st_shown[0];
    setShown: any = st_shown[1];
    st_col: any = useState(defaultCollapsed == True);
    collapsed: bool = st_col[0];
    setCollapsed: any = st_col[1];
    doneRef: any = useRef(onDone);
    doneRef.current = onDone;
    progressRef: any = useRef(onProgress);
    progressRef.current = onProgress;

    useEffect(
        lambda -> any {
            if progressRef.current {
                progressRef.current(shown);
            }
            return JS.undefined;
        },
        [shown]
    );

    useEffect(
        lambda -> any {
            if not rows.length {
                setShown(0);
                return JS.undefined;
            }
            if not replay or reducedMotion() {
                setShown(rows.length);
                if doneRef.current {
                    doneRef.current();
                }
                return JS.undefined;
            }
            setShown(1);
            box: any = {"n": 1, "id": 0};
            box["id"] = JS.window.setInterval(
                lambda {
                    box["n"] = box["n"] + 1;
                    setShown(box["n"]);
                    if box["n"] >= rows.length {
                        JS.window.clearInterval(box["id"]);
                        JS.window.setTimeout(lambda { if doneRef.current { doneRef.current(); } }, 150);
                    }
                },
                400
            );
            return lambda { JS.window.clearInterval(box["id"]); };
        },
        [key, replay]
    );

    running: bool = pending or shown < rows.length;
    steps: any = [r for r in rows if r.kind != "final"];
    issues: int = len([r for r in steps if r.status == "blocked"]);
    fallback: bool = any([r.ai == False for r in rows]);

    if collapsible and collapsed and not running {
        return <div className="agents agents-collapsed">
            <span className="ink-2">{len(steps)} agent steps · {(str(issues) + " flagged something") if issues else "no issues"}</span>
            <button className="kbd-link" onClick={lambda (e: MouseEvent) { setCollapsed(False); }}>Show trace</button>
        </div>;
    }
    visible: any = rows.slice(0, shown);
    nvis: int = len(visible);
    <section className="agents" aria-label="Agent activity" aria-live="polite">
        <div className="agents-head">
            <span className="dots"><i /><i /><i /></span>
            {title}
            {running and <span className="live violet" style={{"marginLeft": 4}} aria-label="Running" />}
            {collapsible and not running and <button className="kbd-link" style={{"marginLeft": "auto", "fontSize": 12}} onClick={lambda (e: MouseEvent) { setCollapsed(True); }}>Hide</button>}
        </div>
        {pending and not rows.length and <div className="agent-row">
            <span className="run-dot" />
            <div><span className="name">Coordinator</span> <span className="res">spinning up agents…</span></div>
            <span className="tag agent">agent</span>
        </div>}
        {for (i, r) in enumerate(visible) {
            if r.kind == "final" {
                <div key={i} className={"agent-final " + ("bad" if r.status == "blocked" else "")}>
                    {<X size={16} className="c-block" /> if r.status == "blocked" else <Check size={16} className="c-ok" />}{r.result}
                </div>
            } else {
                <div key={i} className="agent-row">
                    {<span className="run-dot" aria-label="Running" /> if i == nvis - 1 and running else (<X size={15} strokeWidth={2.2} className="c-wait" aria-label="Flagged" /> if r.status == "blocked" else <Check size={15} strokeWidth={2.2} className="c-ok" aria-label="Done" />)}
                    <div className="grow"><span className="name">{r.agent}</span>{"  "}<span className="res">{r.result}</span></div>
                    <span className={"tag " + r.kind}>{"rules · code" if r.kind == "rules" else ("human" if r.kind == "human" else "agent · AI")}</span>
                </div>
            }
        }}
        {fallback and not running and <div className="agent-foot">AI model offline — agent steps used built-in heuristics. Rules are unaffected.</div>}
    </section>
}
