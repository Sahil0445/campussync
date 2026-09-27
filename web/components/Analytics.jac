"""Hours worked (by job/role) and take-home pay, by week, month or year."""

import from react { useState }
import from "lucide-react" { ChevronLeft, ChevronRight, Info }
import from web.lib.api { useWalker }
import from web.lib.time { fmtHours, money }
import from web.components.HoursChart { ChartTable, HoursChart }
import from web.components.ui { Disclosure, Segmented, Skeleton }

glob:pub JS: any = globalThis;

def:pub WorkAnalytics() -> JsxElement {
    has metric: str = "hours";
    has rng: str = "week";
    has anchor: any = None;
    q: any = useWalker("get_analytics", {"range": rng, "anchor": anchor});
    data: any = q["data"];
    error: any = q["error"];
    def pick(r: str) -> None {
        rng = r;
        anchor = None;
    }
    t: any = data.totals if data else None;
    hours: bool = metric == "hours";
    def fmt(v: float) -> str {
        if hours {
            return fmtHours(JS.Math.round(v * 10) / 10) + "h";
        }
        return money(v, v < 100 and v % 1 != 0);
    }
    series: list[any] = [{"key": s.key, "label": s.label, "values": s.hours if hours else s.net} for s in (data.series if data else [])];
    options: list[dict[str, str]] = [{"value": "week", "label": "Week"}, {"value": "month", "label": "Month"}];
    if (data and data.has_year) or rng == "year" {
        options = options + [{"value": "year", "label": "Year"}];
    }
    hours_line: str = "";
    if t {
        bits: list[str] = [];
        if t.pending_hours > 0 {
            bits.append(fmtHours(t.pending_hours) + " hrs waiting for your approval");
        }
        if t.scheduled_hours > 0 {
            bits.append(fmtHours(t.scheduled_hours) + " hrs still scheduled");
        }
        hours_line = " · ".join(bits);
        if not hours_line and data.series.length {
            hours_line = "Every hour here is approved";
        }
    }

    <section className="card stack g16">
        <div className="row between wrap g8">
            <h2 className="t-card" style={{"fontSize": 17}}>Your work</h2>
            <Segmented label="Show" value={metric} onChange={lambda (v: str) { metric = v; }} options={[{"value": "hours", "label": "Hours"}, {"value": "pay", "label": "Pay"}]} />
        </div>
        <div className="row between wrap g8">
            <Segmented label="Period" value={rng} onChange={lambda (v: str) { pick(v); }} options={options} />
            <div className="row g4">
                <button className="btn icon sm ghost" aria-label="Previous period" disabled={not (data and data.prev)} onClick={lambda (e: MouseEvent) { if data and data.prev { anchor = data.prev; } }}><ChevronLeft size={16} /></button>
                <span className="mono t-small ink-2" style={{"minWidth": 104, "textAlign": "center"}}>{data.title if data else "…"}</span>
                <button className="btn icon sm ghost" aria-label="Next period" disabled={not (data and data.next)} onClick={lambda (e: MouseEvent) { if data and data.next { anchor = data.next; } }}><ChevronRight size={16} /></button>
            </div>
        </div>
        {error and <div className="c-block">{error}</div>}
        {<Skeleton h={220} /> if not data else <>
            <div className="row g12 wrap" style={{"alignItems": "baseline"}}>
                <span className="hero-num">{fmtHours(JS.Math.round(t.hours * 10) / 10) if hours else money(t.net)}</span>
                <span className="ink-2" style={{"fontSize": 15}}>{"hrs worked" if hours else "estimated take-home"}</span>
            </div>
            {<span className="ink-2 t-small">{hours_line}</span> if hours else <div className="pay-lines">
                <div><span>Gross pay</span><span className="num">{money(t.gross)}</span></div>
                <div><span>Federal income tax</span><span className="num">−{money(t.federal)}</span></div>
                <div><span>State income tax</span><span className="num">−{money(t.state)}</span></div>
                <div><span>Social Security + Medicare</span><span className="num">{"Exempt" if data.fica_exempt else "−" + money(t.fica)}</span></div>
                <div className="total"><span>Take-home</span><span className="num">{money(t.net)}</span></div>
                {t.projected_gross > 0 and <div className="ink-3"><span>Still scheduled this period</span><span className="num">+{money(t.projected_gross)} gross</span></div>}
            </div>}
            <HoursChart buckets={data.buckets} series={series} scheduled={data.scheduled if hours else None} format={fmt} unit={"Hours" if hours else "Take-home pay"}
                height={190 if rng == "month" else 200} allKeys={[s.key for s in data.series]} />
            <Disclosure summary="Show as a table"><ChartTable buckets={data.buckets} series={series} format={fmt} /></Disclosure>
            {not hours and <div className="helper row g8" style={{"alignItems": "flex-start"}}><Info size={14} style={{"marginTop": 3}} />
                <span>Estimate: 2026 federal brackets with the standard deduction, your employer's state rate{", and no FICA — international students on F-1/J-1 visas are generally exempt" if data.fica_exempt else ", and 7.65% FICA"}. Your pay stub is the final word.</span></div>}
        </>}
    </section>
}
