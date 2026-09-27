"""Manager copilot: one sentence instead of forms. Ctrl+K / Cmd+K focuses it from anywhere."""

import from react { useEffect, useRef, useState }
import from "react-router-dom" { useNavigate }
import from "lucide-react" { ArrowRight, Check, CornerDownLeft, OctagonX, Sparkles }
import from web.lib.api { api, errMsg }
import from web.lib.time { fmtHours, parseSlot, slot }
import from web.components.AgentPanel { AgentPanel }
import from web.components.ui { Privacy, useToast }

glob:pub JS: any = globalThis;
glob:pub DEPT_SUGGESTIONS: list[str] = [
    "Can Priya work Wednesday 12 to 3?",
    "Add 3 hours for Priya on Thursday",
    "Who can cover Saturday 3 to 7?",
    "Need 2 more people Friday 11 to 3",
    "How is coverage looking?"
];

def:pub CommandBar() -> JsxElement {
    has text: str = "";
    has open: bool = False;
    has busy: bool = False;
    has res: any = None;
    has asked: str = "";
    inputRef: any = useRef(None);
    wrapRef: any = useRef(None);
    toast: any = useToast();

    useEffect(
        lambda -> any {
            k: any = lambda (e: any) {
                if (e.metaKey or e.ctrlKey) and e.key.toLowerCase() == "k" {
                    e.preventDefault();
                    if inputRef.current {
                        inputRef.current.focus();
                    }
                    open = True;
                }
                if e.key == "Escape" {
                    open = False;
                }
            };
            m: any = lambda (e: any) {
                if wrapRef.current and not wrapRef.current.contains(e.target) {
                    open = False;
                }
            };
            JS.window.addEventListener("keydown", k);
            JS.document.addEventListener("mousedown", m);
            return lambda {
                JS.window.removeEventListener("keydown", k);
                JS.document.removeEventListener("mousedown", m);
            };
        },
        []
    );

    async def run(t: str) -> None {
        if not t.strip() {
            return;
        }
        busy = True;
        open = True;
        res = None;
        asked = t;
        try {
            res = await api("copilot_command", {"text": t});
            text = "";
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }

    def ask(q: str) -> any {
        return lambda (e: MouseEvent) { run(q); };
    }

    <div className="cmd" ref={wrapRef}>
        <form onSubmit={lambda (e: FormEvent) { e.preventDefault(); run(text); }}>
            <Sparkles size={17} className="cmd-icon" />
            <input ref={inputRef} className="cmd-input" value={text} onChange={lambda (e: ChangeEvent) { text = e.target.value; }} onFocus={lambda (e: FocusEvent) { open = True; }}
                placeholder="Tell CampusSync what you need…" aria-label="Command CampusSync" />
            <span className="cmd-kbd hide-mobile"><span className="kbd">Ctrl K</span><span className="kbd"><CornerDownLeft size={10} /></span></span>
        </form>
        {open and <div className="cmd-panel">
            {not res and not busy and <div className="stack g12">
                <span className="eyebrow">Try</span>
                <div className="suggest">
                    {for s in DEPT_SUGGESTIONS {
                        <button key={s} onClick={ask(s)}>{s}</button>
                    }}
                </div>
                <Privacy>Answers never reveal another department's schedule. Every action passes the rules first.</Privacy>
            </div>}
            {(busy or res) and <div className="stack g16">
                <div className="row g8 ink-2" style={{"fontSize": 13}}><span className="eyebrow">You</span>{asked}</div>
                <AgentPanel trace={res.trace if res else None} pending={busy} title="copilot · agents" />
                {res and <div className="reply slide-in w500">{res.reply}</div>}
                {res and res.card and <CopilotCard card={res.card} onClose={lambda { open = False; }} onRun={lambda (t: str) { run(t); }} />}
            </div>}
        </div>}
    </div>
}

def:pub CopilotCard(card: any, onClose: any = None, onRun: any = None) -> JsxElement {
    nav: any = useNavigate();
    toast: any = useToast();
    has assigned: bool = card.assigned == True;

    def runIt(t: str) -> None {
        if onRun {
            onRun(t);
        }
    }

    def putOn(p: any) -> any {
        first: str = p.name.split(" ")[0];
        return lambda (e: MouseEvent) { runIt("Put " + first + " on " + slot(card.day, card.start, card.end)); };
    }

    def tryAt(s: str) -> any {
        return lambda (e: MouseEvent) { if parseSlot(s) { runIt("Can " + card.name + " work " + s); } };
    }

    if card.type == "link" {
        return <div><button className="btn primary sm" onClick={lambda (e: MouseEvent) { if onClose { onClose(); } nav(card.to); }}>{card.label}<ArrowRight size={14} /></button></div>;
    }
    if card.type == "people" {
        return <div className="stack g8">
            {card.people.length == 0 and <div className="note wait">No one on your team is free and under their hours. The Recruiting Agent will look across campus.</div>}
            {for p in card.people {
                <div key={p.student_id} className="row between g12 collapsed-line" style={{"color": "var(--ink)"}}>
                    <span>{p.name}<span className="ink-2"> · can take {fmtHours(p.hours_left)} more hrs</span></span>
                    <button className="btn sm" onClick={putOn(p)}>Assign</button>
                </div>
            }}
        </div>;
    }
    if card.type == "check" {
        r: any = card.result;
        label: str = slot(card.day, card.start, card.end);
        async def assign() -> None {
            try {
                x: any = await api("assign_shift", {
                    "week": card.week, "student_id": card.student_id, "day": card.day, "start": card.start, "end": card.end,
                    "position_id": card.position_id or None
                });
                if x.assigned {
                    assigned = True;
                    toast("Added " + card.name + " to " + label + ".");
                }
            } except Exception as e {
                toast(errMsg(e), False);
            }
        }
        if r.available {
            return <div className="note ok" style={{"alignItems": "center"}}>
                <Check size={16} />
                <div className="grow">{(card.name + " is on " + label + ".") if assigned else <>{card.name} is free · you can schedule up to <b>{fmtHours(r.hours_left)}</b> more hrs.</>}</div>
                {not assigned and <button className="btn sm primary" onClick={lambda (e: MouseEvent) { assign(); }}>Assign</button>}
            </div>;
        }
        conflict: bool = r.reason == "schedule_conflict";
        suggestions: any = r.suggestions or [];
        return <div className="card tight stack g12" style={{"borderColor": "rgba(255,107,122,.35)"}} role="alert">
            <div className="row g8 c-block w600"><OctagonX size={16} />{("Can't schedule " + card.name + " on " + label + ".") if conflict else ("Can't add " + fmtHours((card.end - card.start) / 60) + " hrs for " + card.name + " this week.")}</div>
            <span>{(card.name + " isn't available for this slot.") if conflict else <>This would go over their weekly limit. Hours you can still schedule: <b>{fmtHours(r.hours_left)}</b></>}</span>
            <Privacy>{"Details are private to the student." if conflict else "Other commitments are private to the student."}</Privacy>
            {conflict and suggestions.length > 0 and <div className="row g8 wrap"><span className="ink-2">Try instead:</span>
                {for s in suggestions {
                    <button key={s} className="choice mono" onClick={tryAt(s)}>{s}</button>
                }}
            </div>}
            <div><button className="btn sm" onClick={lambda (e: MouseEvent) { runIt("Who can cover " + label.replace("–", " to ") + "?"); }}>Find someone else</button></div>
        </div>;
    }
    return <></>;
}
