"""Staffing-needs editor and the employee's standing availability rules (Availability Agent)."""

import from react { useEffect, useState }
import from "lucide-react" { Plus, Trash2 }
import from web.lib.api { api, errMsg }
import from web.lib.time { DAYS_LONG, TIME_OPTIONS, hm, jsSort }
import from web.components.ui { Stepper, useToast }

glob:pub JS: any = globalThis;

def _by_end_desc(a: any, b: any) -> int {
    return b.end - a.end;
}

def _by_start(a: any, b: any) -> int {
    return a.n.start - b.n.start;
}

"""needs: [{day, start, end, headcount, position_id?}] -- roles: [{id, name}]"""
def:pub NeedsEditor(needs: any, onChange: any, roles: any = None) -> JsxElement {
    role_list: any = roles or [];
    def update(i: int, patch: any) -> None {
        out: list[any] = [];
        for (j, n) in enumerate(needs) {
            out.append(JS.Object.assign({}, n, patch) if j == i else n);
        }
        onChange(out);
    }
    def remove(i: int) -> None {
        onChange([n for (j, n) in enumerate(needs) if j != i]);
    }
    def add(day: int) -> None {
        same: any = [n for n in needs if n.day == day];
        same = jsSort(same, _by_end_desc);
        last: any = same[0] if same.length else None;
        start: int = JS.Math.min(last.end, 20 * 60) if last else 9 * 60;
        extra: any = {
            "day": day, "start": start, "end": JS.Math.min(start + 4 * 60, 24 * 60),
            "headcount": last.headcount if last else 1,
            "position_id": (last.position_id or None) if last else None
        };
        onChange(JS.Array.prototype.concat.call(needs, [extra]));
    }
    def copyMonday() -> None {
        mon: any = [n for n in needs if n.day == 0];
        rest: any = [n for n in needs if n.day > 4];
        out: list[any] = [];
        for d in [0, 1, 2, 3, 4] {
            for n in mon {
                out.append(JS.Object.assign({}, n, {"day": d}));
            }
        }
        onChange(JS.Array.prototype.concat.call(out, rest));
    }
    has_monday: bool = any([n.day == 0 for n in needs]);
    def addTo(day: int) -> any {
        return lambda (e: MouseEvent) { add(day); };
    }
    def setNum(i: int, field: str) -> any {
        return lambda (e: ChangeEvent) {
            patch: any = {};
            patch[field] = JS.Number(e.target.value);
            update(i, patch);
        };
    }
    def setCount(i: int) -> any {
        return lambda (v: int) { update(i, {"headcount": v}); };
    }
    def setRole(i: int) -> any {
        return lambda (e: ChangeEvent) { update(i, {"position_id": e.target.value or None}); };
    }
    def removeAt(i: int) -> any {
        return lambda (e: MouseEvent) { remove(i); };
    }
    <div className="stack g16">
        <div className="row end">
            <button type="button" className="btn sm" onClick={lambda (e: MouseEvent) { copyMonday(); }} disabled={not has_monday}>Copy Monday to weekdays</button>
        </div>
        {for (day, label) in enumerate(DAYS_LONG) {
            rows: any = [{"n": n, "i": i} for (i, n) in enumerate(needs) if n.day == day];
            rows = jsSort(rows, _by_start);
            <section key={day} className="card tight">
                <div className="row between">
                    <h3 className="t-card">{label}</h3>
                    <button type="button" className="btn text sm" onClick={addTo(day)}><Plus size={14} strokeWidth={1.5} />Add block</button>
                </div>
                {rows.length == 0 and <div className="ink-2 mt8">No one needed.</div>}
                <div className="stack g8 mt8">
                    {for row in rows {
                        n: any = row["n"];
                        ends: any = [t for t in TIME_OPTIONS if t > n.start];
                        if n.end <= n.start {
                            ends = JS.Array.prototype.concat.call(ends, [n.end]);
                        }
                        <div key={row["i"]} className="row g8 wrap">
                            <select className="select" style={{"width": 104}} aria-label="Start time" value={n.start}
                                onChange={setNum(row["i"], "start")}>
                                {for t in TIME_OPTIONS { <option key={t} value={t}>{hm(t)}</option> }}
                            </select>
                            <span className="ink-2">to</span>
                            <select className="select" style={{"width": 104}} aria-label="End time" value={n.end}
                                onChange={setNum(row["i"], "end")}>
                                {for t in ends { <option key={t} value={t}>{hm(t)}</option> }}
                            </select>
                            <Stepper value={n.headcount} min={1} max={50} onChange={setCount(row["i"])} label="People needed" />
                            <span className="ink-2 hide-mobile">{"person" if n.headcount == 1 else "people"}</span>
                            {role_list.length > 0 and <select className="select" style={{"width": 150}} aria-label="Role" value={n.position_id or ""}
                                onChange={setRole(row["i"])}>
                                <option value="">Any role</option>
                                {for r in role_list { <option key={r.id} value={r.id}>{r.name}</option> }}
                            </select>}
                            <button type="button" className="btn icon text" style={{"color": "var(--ink-2)", "marginLeft": "auto"}} aria-label="Delete block" onClick={removeAt(row["i"])}>
                                <Trash2 size={16} strokeWidth={1.5} />
                            </button>
                            {n.end <= n.start and <span className="helper c-block" style={{"width": "100%"}}>This block ends before it starts.</span>}
                        </div>
                    }}
                </div>
            </section>
        }}
    </div>
}

# ---------------- standing availability rules (Availability Agent) ----------------
def:pub AvailabilityNotes() -> JsxElement {
    has note: str = "";
    has savedNote: str = "";
    has rules: list[any] = [];
    has parsing: bool = False;
    toast: any = useToast();

    async can with entry {
        try {
            d: any = await api("get_availability");
            note = d.note;
            savedNote = d.note;
            rules = d.rules;
        } except Exception {
            return;
        }
    }

    async def parse() -> None {
        if note == savedNote {
            return;
        }
        parsing = True;
        try {
            r: any = await api("parse_availability_note", {"note": note});
            rules = r.rules;
            savedNote = note;
        } except Exception as e {
            toast(errMsg(e), False);
        }
        parsing = False;
    }

    async def removeRule(r: any) -> None {
        await api("remove_availability_rule", {"day": r.day, "start": r.start, "end": r.end});
        rules = [x for x in rules if x is not r];
    }

    def removeClick(r: any) -> any {
        return lambda (e: MouseEvent) { removeRule(r); };
    }

    <div className="field">
        <label htmlFor="note">Anything that's true every week?</label>
        <textarea id="note" className="textarea" placeholder="e.g. No Fridays before 10 AM — I have lab." value={note}
            onChange={lambda (e: ChangeEvent) { note = e.target.value; }} onBlur={lambda (e: FocusEvent) { parse(); }} />
        {parsing and <div className="helper mono">Availability Agent is reading this…</div>}
        {not parsing and len(rules) > 0 and <div className="stack g8 mt4">
            <span className="mono ink-3">Understood by Availability Agent</span>
            <div className="row g8 wrap">
                {for (i, r) in enumerate(rules) {
                    <span key={i} className="rule-chip">{r.label}<button type="button" aria-label={"Remove " + r.label} onClick={removeClick(r)}>×</button></span>
                }}
            </div>
        </div>}
        {not parsing and savedNote and note == savedNote and len(rules) == 0 and <div className="helper">No time limits found in this note.</div>}
    </div>
}
