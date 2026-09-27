"""Employer timesheets: hours arrive automatically; the employer only handles what employees flag."""

import from react { useState }
import from "react-router-dom" { useSearchParams }
import from "lucide-react" { AlertTriangle, Check, ChevronDown, ChevronLeft, ChevronRight, Download, Flag }
import from web.components.ui { ErrorBlock, PageSkeleton, StatusChip, useToast }
import from web.lib.api { api, errMsg, useWalker }
import from web.lib.time { dateLabel, downloadText, fmtHours, hm, money, shiftWeek, weekLabel }

glob:pub JS: any = globalThis;

def statusChip(s: str) -> JsxElement {
    if s == "approved" {
        return <StatusChip kind="ok">Approved</StatusChip>;
    }
    if s == "disputed" {
        return <StatusChip kind="wait">Flagged</StatusChip>;
    }
    if s == "void" {
        return <StatusChip kind="neutral">Not worked</StatusChip>;
    }
    return <StatusChip kind="neutral">With employee</StatusChip>;
}

def:pub TimesheetsPage() -> JsxElement {
    sp: any = useSearchParams();
    params: any = sp[0];
    setParams: any = sp[1];
    week: any = params.get("week") or JS.undefined;
    q: any = useWalker("get_timesheets", {"week": week} if week else {}, 10000);
    data: any = q["data"];
    error: any = q["error"];
    reload: any = q["reload"];
    has open: any = None;
    has busy: bool = False;
    has notes: any = {};
    toast: any = useToast();

    async def resolve(eid: any, accept: bool) -> None {
        busy = True;
        try {
            await api("resolve_time_entry", {"entry_id": eid, "accept": accept, "note": notes[eid] or ""});
            toast("Correction accepted." if accept else "Kept as reported.");
            reload(True);
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }

    async def exportCsv() -> None {
        try {
            r: any = await api("export_timesheets", {"week": data.week});
            downloadText(r.filename, r.csv);
        } except Exception as e {
            toast(errMsg(e), False);
        }
    }

    def setNote(eid: any, v: str) -> None {
        nn: any = JS.Object.assign({}, notes);
        nn[eid] = v;
        notes = nn;
    }

    if error {
        return <ErrorBlock onRetry={reload} message={error} />;
    }
    if not data {
        return <PageSkeleton />;
    }

    def go(w: str) -> None {
        setParams({} if w == data.current_week else {"week": w});
    }

    flagged: list[any] = [];
    for p in data.people {
        for e in p.entries {
            if e.status == "disputed" {
                flagged.append({"p": p, "e": e});
            }
        }
    }
    t: any = data.totals;

    <>
        <div className="dheader">
            <div className="stack g8"><span className="eyebrow">Automated time reporting</span><h1 className="t-page">Timesheets · week of {weekLabel(data.week)}</h1>
                <span className="ink-2">Hours are reported when each shift ends. Employees confirm them on Friday; you only handle what they flag.</span></div>
            <div className="actions">
                <button className="btn icon sm ghost" aria-label="Previous week" onClick={lambda (ev: MouseEvent) { go(shiftWeek(data.week, -1)); }}><ChevronLeft size={18} /></button>
                {data.week != data.current_week and <button className="btn sm" onClick={lambda (ev: MouseEvent) { go(data.current_week); }}>This week</button>}
                <button className="btn icon sm ghost" aria-label="Next week" onClick={lambda (ev: MouseEvent) { go(shiftWeek(data.week, 1)); }}><ChevronRight size={18} /></button>
                <button className="btn sm" disabled={not t.entries} onClick={lambda (ev: MouseEvent) { exportCsv(); }}><Download size={15} />Export CSV</button>
            </div>
        </div>

        <div className="kpis">
            <div className="card kpi"><span className="lbl">Hours reported</span><span className="num">{fmtHours(t.hours)}</span><span className="ink-3 t-small">{t.entries} shifts</span></div>
            <div className="card kpi"><span className="lbl">Labor cost</span><span className="num">{money(t.cost, False)}</span><span className="ink-3 t-small">gross pay</span></div>
            <div className="card kpi"><span className="lbl">Waiting on employees</span><span className="num">{t.pending}</span><span className="ink-3 t-small">they confirm on Friday</span></div>
            <div className="card kpi"><span className="lbl row g8"><Flag size={14} />Flagged for you</span><span className={"num " + ("c-wait" if t.disputed else "")}>{t.disputed}</span><span className="ink-3 t-small">{t.approved} approved</span></div>
        </div>

        {len(flagged) > 0 and <section className="card mt16 stack g12">
            <h2 className="t-section row g8"><AlertTriangle size={17} className="c-wait" />Flagged by employees</h2>
            {for f in flagged {
                p: any = f["p"];
                e: any = f["e"];
                <div key={e.id} className="approval" style={{"gridTemplateColumns": "1fr auto"}}>
                    <div className="stack g4">
                        <span className="title">{p.name} · {dateLabel(e.date)}{(" · " + e.role) if e.role else ""}</span>
                        <span className="detail">Reported {hm(e.start)}–{hm(e.end)} ({fmtHours(e.hours)} h) → says <b style={{"color": "var(--ink)"}}>{"didn't work this shift" if e.proposed_absent else hm(e.proposed_start) + "–" + hm(e.proposed_end) + " (" + fmtHours((e.proposed_end - e.proposed_start) / 60) + " h)"}</b></span>
                        {e.note and <span className="detail">“{e.note}”</span>}
                        <input className="input" style={{"height": 36, "maxWidth": 420}} placeholder="Reply (optional, shown to the employee)" value={notes[e.id] or ""} onChange={lambda (ev: ChangeEvent) { setNote(f["e"].id, ev.target.value); }} aria-label="Reply" />
                    </div>
                    <div className="acts" style={{"alignSelf": "center"}}>
                        <button className="btn sm ghost" disabled={busy} onClick={lambda (ev: MouseEvent) { resolve(f["e"].id, False); }}>Keep reported</button>
                        <button className="btn sm primary" disabled={busy} onClick={lambda (ev: MouseEvent) { resolve(f["e"].id, True); }}><Check size={14} />Accept</button>
                    </div>
                </div>
            }}
        </section>}

        <section className="card mt16">
            <h2 className="t-section">People</h2>
            {len(data.people) == 0 and <div className="ink-2 mt12">No hours reported this week yet. They appear automatically as shifts end.</div>}
            <div className="divided mt12">
                {for p in data.people {
                    isOpen: bool = open == p.student_id;
                    <div key={p.student_id}>
                        <button className="list-row ts-person" onClick={lambda (ev: MouseEvent) { open = None if open == p.student_id else p.student_id; }} aria-expanded={isOpen}>
                            <span className="grow stack" style={{"textAlign": "left"}}><span className="w600">{p.name}</span><span className="t-small ink-3">{len(p.entries)} shift{"" if len(p.entries) == 1 else "s"} · {p.email}</span></span>
                            <span className="row g8 wrap" style={{"justifyContent": "flex-end"}}>
                                {p.disputed > 0 and <StatusChip kind="wait">{p.disputed} flagged</StatusChip>}
                                {p.pending > 0 and <StatusChip kind="neutral">{p.pending} to confirm</StatusChip>}
                                {p.pending == 0 and p.disputed == 0 and <StatusChip kind="ok">Approved</StatusChip>}
                            </span>
                            <span className="num" style={{"width": 64, "textAlign": "right"}}>{fmtHours(p.hours)} h</span>
                            <span className="num hide-mobile" style={{"width": 90, "textAlign": "right"}}>{money(p.gross)}</span>
                            <ChevronDown size={16} className="ink-3" style={{"transform": "rotate(180deg)" if isOpen else JS.undefined}} />
                        </button>
                        {isOpen and <div className="table-wrap slide-in" style={{"marginBottom": 12}}><table className="table compact">
                            <thead><tr><th>Date</th><th>Time</th><th>Role</th><th>Hours</th><th>Rate</th><th>Gross</th><th>Status</th></tr></thead>
                            <tbody>{for e in p.entries {
                                <tr key={e.id}><td>{dateLabel(e.date)}</td><td className="mono">{hm(e.start)}–{hm(e.end)}</td><td>{e.role or "—"}</td>
                                    <td className="num">{fmtHours(e.hours)}</td><td className="num">{money(e.pay_rate)}</td><td className="num">{money(e.gross)}</td><td>{statusChip(e.status)}</td></tr>
                            }}</tbody>
                        </table></div>}
                    </div>
                }}
            </div>
        </section>
    </>
}
