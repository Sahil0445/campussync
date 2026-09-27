"""Employee timesheet: hours are reported automatically when a shift ends; the employee just checks them."""

import from react { useState }
import from "react-router-dom" { Link }
import from "lucide-react" { AlertTriangle, CalendarCheck, Check, ChevronRight, Clock, ShieldCheck }
import from web.components.ui { ErrorBlock, Modal, Note, PageSkeleton, Segmented, StatusChip, useToast }
import from web.lib.api { api, errMsg, useWalker }
import from web.lib.time { dateLabel, fmtHours, hm, money, weekLabel }

glob:pub JS: any = globalThis;
glob:pub QUARTERS: list[int] = [i * 15 for i in range(97)];

"""A number from the server, or the fallback when it is null/missing (like `??`)."""
def _num_or(v: any, fallback: any) -> any {
    if JS.Number.isFinite(v) {
        return v;
    }
    return fallback;
}

def:pub EntryChip(e: any) -> JsxElement {
    if e.status == "approved" {
        return <StatusChip kind="ok">Approved</StatusChip>;
    }
    if e.status == "disputed" {
        return <StatusChip kind="wait">With manager</StatusChip>;
    }
    if e.status == "void" {
        return <StatusChip kind="neutral">Not worked</StatusChip>;
    }
    return <StatusChip kind="neutral">To check</StatusChip>;
}

def:pub TimePage() -> JsxElement {
    q: any = useWalker("get_timesheet", {}, 15000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    setData: any = q["setData"];
    has fixing: any = None;
    has busy: bool = False;
    toast: any = useToast();

    async def approve(ids: any) -> None {
        busy = True;
        try {
            r: any = await api("approve_time", {"entry_ids": ids} if ids else {});
            setData(r);
            toast("Approved." if ids else "Approved " + str(r.approved) + " entr" + ("y" if r.approved == 1 else "ies") + ". Thanks!");
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }

    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }

    <div className="stack g20">
        <div className="stack g4"><span className="eyebrow">Time & pay</span><h1 className="t-page">Your timesheet</h1>
            <span className="ink-2">Hours are reported automatically when a shift ends. You just check them.</span></div>

        {<section className="card glow stack g12">
            <div className="row g12">
                <span className="icon-tile"><CalendarCheck size={18} /></span>
                <div className="grow stack">
                    <span className="w600">{"It's Friday — check your week" if data.review_today else str(data.pending_count) + " " + ("entry" if data.pending_count == 1 else "entries") + " to check"}</span>
                    <span className="ink-2 t-small">{fmtHours(data.pending_hours)} hrs reported · make sure they match the days you actually worked</span>
                </div>
            </div>
            <button className="btn primary lg" disabled={busy} onClick={lambda (e: MouseEvent) { approve(None); }}><Check size={16} />All correct · approve {fmtHours(data.pending_hours)} hrs</button>
        </section> if data.pending_count > 0 else <Note kind="ok" icon={<Check size={16} />}>You're all caught up. Next check: {"today" if data.review_today else dateLabel(data.next_review, {"weekday": "long", "month": "short", "day": "numeric"})}.</Note>}
        {data.disputed_count > 0 and <Note kind="wait" icon={<Clock size={16} />}>{data.disputed_count} correction{"s are" if data.disputed_count > 1 else " is"} waiting for your manager.</Note>}
        {data.international and <div className="row g8 ink-2 t-small"><ShieldCheck size={15} className="c-accent" />International limit: reported hours can never go over {data.cap} a week across all your jobs — CampusSync blocks it.</div>}

        {len(data.weeks) == 0 and <div className="card ink-2">No hours reported yet. They show up here automatically after your first shift ends.</div>}
        {for w in data.weeks {
            <section key={w.week} className="stack g8">
                <div className="row between g8">
                    <h2 className="t-section">Week of {weekLabel(w.week)}</h2>
                    {<StatusChip kind="wait">Needs you</StatusChip> if w.state == "needs_you" else (<StatusChip kind="wait">With manager</StatusChip> if w.state == "waiting" else <StatusChip kind="ok">Approved</StatusChip>)}
                </div>
                <div className="card" style={{"paddingTop": 4, "paddingBottom": 4}}>
                    {for e in w.entries {
                        <div key={e.id} className="ts-row">
                            <div className="grow stack g4">
                                <div className="when"><span className="nowrap">{dateLabel(e.date)}</span>{" "}<span className="nowrap">· {hm(e.start)}–{hm(e.end)}</span></div>
                                <div className="where">{e.department}{(" · " + e.role) if e.role else ""} · {fmtHours(e.hours)} h · {money(e.gross)}</div>
                                {e.status == "disputed" and <div className="t-small c-wait">You said: {"I didn't work this shift" if e.proposed_absent else hm(e.proposed_start) + "–" + hm(e.proposed_end)}{(" · “" + e.note + "”") if e.note else ""}</div>}
                                {e.employer_note and e.status != "disputed" and <div className="t-small ink-3">Manager: {e.employer_note}</div>}
                            </div>
                            <div className="stack g8" style={{"alignItems": "flex-end"}}>
                                <EntryChip e={e} />
                                {(e.status == "reported" or e.status == "disputed") and <div className="row g4">
                                    <button className="btn sm text" disabled={busy} onClick={lambda (ev: MouseEvent) { fixing = e; }}>{"Change" if e.status == "disputed" else "Fix"}</button>
                                    {e.status == "reported" and <button className="btn sm" disabled={busy} onClick={lambda (ev: MouseEvent) { approve([e.id]); }}>OK</button>}
                                </div>}
                            </div>
                        </div>
                    }}
                    <div className="ts-foot"><span>{fmtHours(w.hours)} hrs</span><span>{money(w.pay.gross)} gross · <b>{money(w.pay.net)}</b> take-home (est.)</span></div>
                </div>
            </section>
        }}
        <Link to="/s/profile" className="collapsed-line"><span className="grow">See hours and pay trends by week, month and year</span><ChevronRight size={15} /></Link>
        {fixing and <FixModal ent={fixing} onClose={lambda { fixing = None; }} onDone={lambda (s: any) { setData(s); fixing = None; toast("Sent to your manager."); }} />}
    </div>
}

def:pub FixModal(ent: any, onClose: any, onDone: any) -> JsxElement {
    has mode: str = "absent" if ent.proposed_absent else "times";
    has start: any = _num_or(ent.proposed_start, ent.start);
    has end: any = _num_or(ent.proposed_end, ent.end);
    has note: str = ent.note or "";
    has error: any = None;
    has busy: bool = False;

    async def send() -> None {
        busy = True;
        error = None;
        try {
            s: any = await api("correct_time", {"entry_id": ent.id, "start": start, "end": end, "absent": mode == "absent", "note": note});
            onDone(s);
        } except Exception as e {
            error = errMsg(e);
            busy = False;
        }
    }

    hrs: float = JS.Math.max(0, end - start) / 60;
    <Modal onClose={onClose} label="Fix reported time" sheet={True}>
        <div className="stack g16">
            <div className="stack g4"><span className="eyebrow">{ent.department}{(" · " + ent.role) if ent.role else ""}</span>
                <h2 className="t-section">{dateLabel(ent.date, {"weekday": "long", "month": "short", "day": "numeric"})}</h2>
                <span className="ink-2">Reported {hm(ent.start)}–{hm(ent.end)} · {fmtHours(ent.hours)} h</span></div>
            <Segmented full={True} label="What's wrong?" value={mode} onChange={lambda (v: str) { mode = v; }} options={[{"value": "times", "label": "Different times"}, {"value": "absent", "label": "I didn't work it"}]} />
            {mode == "times" and <div className="row g8 wrap" style={{"alignItems": "center"}}>
                <select className="select" style={{"width": 110}} aria-label="Start" value={start} onChange={lambda (e: ChangeEvent) { start = JS.Number(e.target.value); }}>
                    {for t in QUARTERS[0:96] { <option key={t} value={t}>{hm(t)}</option> }}</select>
                <span className="ink-2">to</span>
                <select className="select" style={{"width": 110}} aria-label="End" value={end} onChange={lambda (e: ChangeEvent) { end = JS.Number(e.target.value); }}>
                    {for t in [t for t in QUARTERS if t > start] { <option key={t} value={t}>{hm(t)}</option> }}</select>
                <span className="ink-2 mono">{fmtHours(hrs)} h</span>
            </div>}
            <input className="input" placeholder="Note for your manager (optional)" value={note} onChange={lambda (e: ChangeEvent) { note = e.target.value; }} maxLength={300} aria-label="Note" />
            {error and <div className="note block"><AlertTriangle size={16} /><div>{error}</div></div>}
            <div className="row g8 end"><button className="btn" onClick={lambda (e: MouseEvent) { onClose(); }}>Cancel</button><button className="btn primary" disabled={busy or (mode == "times" and end <= start)} onClick={lambda (e: MouseEvent) { send(); }}>Send to manager</button></div>
        </div>
    </Modal>
}
