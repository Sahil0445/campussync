"""Google-Calendar-style week view. Each staffing slot is an event block, coloured by coverage."""

import from react { useEffect, useState }
import from "lucide-react" { ArrowLeftRight, ChevronLeft, ChevronRight }
import from web.lib.time { pad2, jsSort }

glob:pub JS: any = globalThis;
glob:pub DOW: list[str] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

def dateOf(week: str, day: int) -> any {
    d: any = new(JS.Date, week + "T12:00:00");
    d.setDate(d.getDate() + day);
    return d;
}

def hourLabel(h: int) -> str {
    if h == 0 or h == 24 {
        return "12 AM";
    }
    if h == 12 {
        return "12 PM";
    }
    return (str(h) + " AM") if h < 12 else (str(h - 12) + " PM");
}

def time12(m: int) -> str {
    h: int = m // 60;
    mm: int = m % 60;
    hh: int = 12 if h % 12 == 0 else h % 12;
    return str(hh) + ((":" + pad2(mm)) if mm else "") + ("am" if h % 24 < 12 else "pm");
}

def:pub monthLabel(week: str) -> str {
    a: any = dateOf(week, 0);
    b: any = dateOf(week, 6);
    ma: str = a.toLocaleDateString("en-US", {"month": "long"});
    mb: str = b.toLocaleDateString("en-US", {"month": "long"});
    if a.getMonth() == b.getMonth() {
        return ma + " " + str(a.getFullYear());
    }
    return ma[0:3] + " – " + mb[0:3] + " " + str(b.getFullYear());
}

def _cell_order(a: any, b: any) -> int {
    if a.day != b.day {
        return a.day - b.day;
    }
    if a.start != b.start {
        return a.start - b.start;
    }
    pa = str(a.position_id or "");
    pb = str(b.position_id or "");
    return -1 if pa < pb else (1 if pa > pb else 0);
}

def _num_order(a: int, b: int) -> int {
    return a - b;
}

"""Lane layout per cell index: side-by-side lanes when blocks overlap (two roles at 18:00); staggered starts cascade."""
def _lanes(ordered: any) -> dict[int, dict[str, any]] {
    lanes: dict[int, dict[str, any]] = {};
    for d in range(7) {
        day: list[int] = [i for i in range(ordered.length) if ordered[i].day == d];
        cluster: list[int] = [];
        cluster_end: int = -1;
        groups: list[list[int]] = [];
        for i in day {
            c: any = ordered[i];
            if len(cluster) and c.start >= cluster_end {
                groups.append(cluster);
                cluster = [];
                cluster_end = -1;
            }
            cluster.append(i);
            cluster_end = JS.Math.max(cluster_end, c.end);
        }
        groups.append(cluster);
        for grp in groups {
            ends: list[int] = [];
            placed: list[list[int]] = [];
            for i in grp {
                c: any = ordered[i];
                l: int = -1;
                for (k, e) in enumerate(ends) {
                    if e <= c.start {
                        l = k;
                        break;
                    }
                }
                if l < 0 {
                    l = len(ends);
                    ends.append(c.end);
                } else {
                    ends[l] = c.end;
                }
                placed.append([i, l]);
            }
            starts: any = [ordered[i].start for i in grp];
            starts = jsSort(starts, _num_order);
            cascade: bool = len(grp) > 1;
            for k in range(1, len(grp)) {
                if starts[k] - starts[k - 1] < 60 {
                    cascade = False;
                }
            }
            for pl in placed {
                lanes[pl[0]] = {"lane": pl[1], "of": len(ends), "cascade": cascade};
            }
        }
    }
    return lanes;
}

def:pub WeekCalendar(
    week: str,
    cells: any,
    onCell: any = None,
    hourHeight: int = 48,
    onPrev: any = None,
    onNext: any = None,
    onToday: any = None,
    toolbar: bool = True,
    skeleton: bool = False,
    reveal: int = -1
) -> JsxElement {
    st: any = useState(new(JS.Date));
    now: any = st[0];
    setNow: any = st[1];
    useEffect(
        lambda -> any {
            iv: any = JS.window.setInterval(lambda { setNow(new(JS.Date)); }, 60000);
            return lambda { JS.window.clearInterval(iv); };
        },
        []
    );
    minStart: int = JS.Math.min.apply(None, [c.start for c in cells]) if cells.length else 9 * 60;
    maxEnd: int = JS.Math.max.apply(None, [c.end for c in cells]) if cells.length else 17 * 60;
    h0: int = JS.Math.max(0, JS.Math.floor(minStart / 60) - 1);
    h1: int = JS.Math.min(24, JS.Math.ceil(maxEnd / 60) + 1);
    hours: list[int] = [h0 + i for i in range(h1 - h0)];
    def y(m: float) -> float {
        return ((m - h0 * 60) / 60) * hourHeight;
    }
    todayIdx: int = -1;
    for d in range(7) {
        if todayIdx < 0 and dateOf(week, d).toDateString() == now.toDateString() {
            todayIdx = d;
        }
    }
    ordered: any = jsSort(cells, _cell_order);
    lanes: dict[int, dict[str, any]] = _lanes(ordered);
    def pick(c: any) -> any {
        return lambda (e: MouseEvent) {
            if onCell {
                onCell(c);
            }
        };
    }
    nowH: int = now.getHours();
    nowTop: float = y(nowH * 60 + now.getMinutes());

    <div className="wcal">
        {toolbar and <div className="wcal-bar">
            {onToday and <button className="btn sm" onClick={lambda (e: MouseEvent) { onToday(); }}>Today</button>}
            {onPrev and <button className="btn icon sm ghost" aria-label="Previous week" onClick={lambda (e: MouseEvent) { onPrev(); }}><ChevronLeft size={18} /></button>}
            {onNext and <button className="btn icon sm ghost" aria-label="Next week" onClick={lambda (e: MouseEvent) { onNext(); }}><ChevronRight size={18} /></button>}
            <span className="wcal-month">{monthLabel(week)}</span>
            <span className="wcal-legend hide-mobile">
                <span><i className="lg lg-full" />Staffed</span><span><i className="lg lg-partial" />Short</span><span><i className="lg lg-empty" />Unfilled</span>
            </span>
        </div>}
        <div className="wcal-scroll">
            <div className="wcal-grid">
                <div className="wcal-head">
                    <div className="wcal-gutter" />
                    {for (i, d) in enumerate(DOW) {
                        date: any = dateOf(week, i);
                        <div key={d} className={"wcal-day " + ("today" if i == todayIdx else "")}>
                            <span className="dow">{d.upper()}</span>
                            <span className="dnum">{date.getDate()}</span>
                        </div>
                    }}
                </div>
                <div className="wcal-body" style={{"height": len(hours) * hourHeight}}>
                    <div className="wcal-gutter">
                        {for h in hours[1:] { <span key={h} style={{"top": y(h * 60)}}>{hourLabel(h)}</span> }}
                    </div>
                    {for day in range(7) {
                        <div key={day} className="wcal-col" style={{"backgroundSize": "100% " + str(hourHeight) + "px"}}>
                            {for idx in range(ordered.length) {
                                c: any = ordered[idx];
                                if c.day == day {
                                    state: str = "full" if c.assigned >= c.needed else ("empty" if c.assigned == 0 else "partial");
                                    top: float = y(c.start);
                                    height: float = JS.Math.max(22, y(c.end) - y(c.start) - 3);
                                    ln: dict[str, any] = lanes[idx] if idx in lanes else {"lane": 0, "of": 1, "cascade": False};
                                    lane: int = ln["lane"];
                                    of: int = ln["of"];
                                    place: dict[str, any] = {};
                                    if ln["cascade"] {
                                        place = {
                                            "top": top, "height": height, "left": "calc(" + str(lane * 22) + "% + 2px)",
                                            "width": "calc(" + str(100 - lane * 22) + "% - 4px)", "right": "auto", "zIndex": 1 + lane
                                        };
                                        if lane {
                                            place["boxShadow"] = ("inset 3px 0 0 var(--role), " if c.role else "") + "0 0 0 2px var(--bg-2)";
                                        }
                                    } else {
                                        place = {
                                            "top": top, "height": height, "left": "calc(" + str((lane / of) * 100) + "% + 2px)",
                                            "width": "calc(" + str(100 / of) + "% - 4px)", "right": "auto"
                                        };
                                    }
                                    key: str = str(c.start) + "-" + str(c.end) + "-" + str(c.position_id or 0);
                                    if skeleton and (reveal < 0 or idx >= reveal) {
                                        <div key={key} className="wcal-ev skel" style={place} />
                                    } else {
                                        names: str = ", ".join([p.name for p in c.people]);
                                        title: str = "Unfilled" if state == "empty" else ((names + " · need " + str(c.needed - c.assigned)) if state == "partial" else names);
                                        style: any = JS.Object.assign({}, place);
                                        if c.color {
                                            style["--role"] = c.color;
                                        }
                                        <button key={key} className={"wcal-ev " + state + " " + ("pop" if skeleton else "") + " " + ("has-role" if c.role else "")} style={style}
                                            onClick={pick(ordered[idx])}
                                            aria-label={DOW[day] + " " + time12(c.start) + " to " + time12(c.end) + ((", " + c.role) if c.role else "") + ": " + str(c.assigned) + " of " + str(c.needed) + " staffed"}>
                                            <span className="ev-title">
                                                {any([p.pending for p in c.people]) and <ArrowLeftRight size={11} style={{"marginRight": 4, "verticalAlign": -1}} />}
                                                {title}
                                            </span>
                                            {c.role and <span className="ev-role"><i style={{"background": c.color or "var(--accent)"}} />{c.role}</span>}
                                            <span className="ev-time">{time12(c.start)} – {time12(c.end)} · {c.assigned}/{c.needed}</span>
                                            {height > 70 and any([p.new for p in c.people]) and <span className="ev-new">New from draft</span>}
                                        </button>
                                    }
                                }
                            }}
                            {day == todayIdx and nowH >= h0 and nowH < h1 and <div className="wcal-now" style={{"top": nowTop}}><i /></div>}
                        </div>
                    }}
                </div>
            </div>
        </div>
    </div>
}
