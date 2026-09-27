import { useState } from "react";
import { ChevronLeft, ChevronRight, Info } from "lucide-react";
import { useWalker } from "../lib/api";
import { fmtHours, money } from "../lib/time";
import { ChartTable, HoursChart } from "./HoursChart";
import { Disclosure, Segmented, Skeleton } from "./ui";

interface Analytics {
  range: "week" | "month" | "year"; title: string; prev: string | null; next: string | null;
  buckets: { key: string; label: string; sub: string }[];
  series: { key: string; label: string; department: string; hours: number[]; gross: number[]; net: number[]; total_hours: number }[];
  scheduled: number[];
  totals: { hours: number; pending_hours: number; scheduled_hours: number; projected_gross: number; gross: number; federal: number; state: number; fica: number; taxes: number; net: number };
  fica_exempt: boolean; has_year: boolean; today: string;
}

/** Hours worked (by job/role) and take-home pay, by week, month or year. */
export function WorkAnalytics() {
  const [metric, setMetric] = useState<"hours" | "pay">("hours");
  const [range, setRange] = useState<"week" | "month" | "year">("week");
  const [anchor, setAnchor] = useState<string | null>(null);
  const { data, error } = useWalker<Analytics>("get_analytics", { range, anchor });
  const pick = (r: "week" | "month" | "year") => { setRange(r); setAnchor(null); };
  const t = data?.totals;
  const hours = metric === "hours";
  const fmt = hours ? (v: number) => `${fmtHours(Math.round(v * 10) / 10)}h` : (v: number) => money(v, v < 100 && v % 1 !== 0);
  const series = (data?.series ?? []).map((s) => ({ key: s.key, label: s.label, values: hours ? s.hours : s.net }));
  const options = [{ value: "week", label: "Week" }, { value: "month", label: "Month" }, ...(data?.has_year || range === "year" ? [{ value: "year", label: "Year" }] : [])];

  return (
    <section className="card stack g16">
      <div className="row between wrap g8">
        <h2 className="t-card" style={{ fontSize: 17 }}>Your work</h2>
        <Segmented label="Show" value={metric} onChange={setMetric} options={[{ value: "hours", label: "Hours" }, { value: "pay", label: "Pay" }]} />
      </div>
      <div className="row between wrap g8">
        <Segmented label="Period" value={range} onChange={(v) => pick(v as any)} options={options as any} />
        <div className="row g4">
          <button className="btn icon sm ghost" aria-label="Previous period" disabled={!data?.prev} onClick={() => data?.prev && setAnchor(data.prev)}><ChevronLeft size={16} /></button>
          <span className="mono t-small ink-2" style={{ minWidth: 104, textAlign: "center" }}>{data?.title ?? "…"}</span>
          <button className="btn icon sm ghost" aria-label="Next period" disabled={!data?.next} onClick={() => data?.next && setAnchor(data.next)}><ChevronRight size={16} /></button>
        </div>
      </div>
      {error && <div className="c-block">{error}</div>}
      {!data ? <Skeleton h={220} /> : (
        <>
          <div className="row g12 wrap" style={{ alignItems: "baseline" }}>
            <span className="hero-num">{hours ? fmtHours(Math.round(t!.hours * 10) / 10) : money(t!.net)}</span>
            <span className="ink-2" style={{ fontSize: 15 }}>{hours ? "hrs worked" : "estimated take-home"}</span>
          </div>
          {hours ? (
            <span className="ink-2 t-small">
              {[t!.pending_hours > 0 ? `${fmtHours(t!.pending_hours)} hrs waiting for your approval` : "",
                t!.scheduled_hours > 0 ? `${fmtHours(t!.scheduled_hours)} hrs still scheduled` : ""].filter(Boolean).join(" · ")
                || (data.series.length ? "Every hour here is approved" : "")}
            </span>
          ) : (
            <div className="pay-lines">
              <div><span>Gross pay</span><span className="num">{money(t!.gross)}</span></div>
              <div><span>Federal income tax</span><span className="num">−{money(t!.federal)}</span></div>
              <div><span>State income tax</span><span className="num">−{money(t!.state)}</span></div>
              <div><span>Social Security + Medicare</span><span className="num">{data.fica_exempt ? "Exempt" : `−${money(t!.fica)}`}</span></div>
              <div className="total"><span>Take-home</span><span className="num">{money(t!.net)}</span></div>
              {t!.projected_gross > 0 && <div className="ink-3"><span>Still scheduled this period</span><span className="num">+{money(t!.projected_gross)} gross</span></div>}
            </div>
          )}
          <HoursChart buckets={data.buckets} series={series} scheduled={hours ? data.scheduled : undefined} format={fmt} unit={hours ? "Hours" : "Take-home pay"}
                      height={range === "month" ? 190 : 200} allKeys={data.series.map((s) => s.key)} />
          <Disclosure summary="Show as a table"><ChartTable buckets={data.buckets} series={series} format={fmt} /></Disclosure>
          {!hours && (
            <div className="helper row g8" style={{ alignItems: "flex-start" }}><Info size={14} style={{ marginTop: 3 }} />
              <span>Estimate: 2026 federal brackets with the standard deduction, your employer's state rate{data.fica_exempt ? ", and no FICA — international students on F-1/J-1 visas are generally exempt" : ", and 7.65% FICA"}. Your pay stub is the final word.</span></div>
          )}
        </>
      )}
    </section>
  );
}
