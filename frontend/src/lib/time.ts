export const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
export const DAYS_LONG = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
export const DEFAULT_WEEK = "2026-09-28";

/** Monday (ISO date) of the week containing `d`, in the viewer's local time. */
export function mondayOf(d = new Date()) {
  const x = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  x.setDate(x.getDate() - ((x.getDay() + 6) % 7));
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}`;
}

/** "Mon, Sep 28" from an ISO date. */
export function dateLabel(iso: string, opts: Intl.DateTimeFormatOptions = { weekday: "short", month: "short", day: "numeric" }) {
  return new Date(iso + "T12:00:00").toLocaleDateString("en-US", opts);
}

const money0 = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
const money2 = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const money = (n: number, cents = true) => (cents ? money2 : money0).format(n || 0);

export function relTime(seconds: number) {
  if (seconds <= 0) return "now";
  const m = Math.round(seconds / 60);
  if (m < 60) return `in ${m} min`;
  const h = Math.floor(m / 60), mm = m % 60;
  if (h < 24) return `in ${h} h${mm ? ` ${mm} min` : ""}`;
  const d = Math.round(h / 24);
  return `in ${d} day${d === 1 ? "" : "s"}`;
}

export function downloadText(filename: string, text: string, type = "text/csv") {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement("a");
  a.href = url; a.download = filename; document.body.appendChild(a); a.click(); a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export const hm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
/** 12-hour range for people: "11 AM – 3 PM". */
export const range12 = (s: number, e: number) => `${h12(s)} – ${h12(e)}`;
export const range = (s: number, e: number) => `${hm(s)}–${hm(e)}`;
export const slot = (d: number, s: number, e: number) => `${DAYS[d]} ${range(s, e)}`;

/** 12-hour format for sentences: "10 AM", "3:30 PM". */
export function h12(m: number) {
  const h = Math.floor(m / 60) % 24;
  const mm = m % 60;
  const suffix = h >= 12 ? "PM" : "AM";
  const hh = h % 12 === 0 ? 12 : h % 12;
  return mm ? `${hh}:${String(mm).padStart(2, "0")} ${suffix}` : `${hh} ${suffix}`;
}

export const fmtHours = (h: number) => (Number.isInteger(h) ? String(h) : h.toFixed(1));

export function parseHm(t: string) {
  const [h, m] = t.split(":").map(Number);
  return h * 60 + (m || 0);
}

/** "Wed 15:00-18:00" -> {day, start, end} */
export function parseSlot(label: string) {
  const m = label.match(/^(\w{3})\s+(\d{2}:\d{2})\s*[-–]\s*(\d{2}:\d{2})$/);
  if (!m) return null;
  return { day: DAYS.indexOf(m[1]), start: parseHm(m[2]), end: parseHm(m[3]) };
}

export function weekLabel(iso: string) {
  const d = new Date(iso + "T12:00:00");
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export function shiftWeek(iso: string, delta: number) {
  const d = new Date(iso + "T12:00:00");
  d.setDate(d.getDate() + delta * 7);
  return d.toISOString().slice(0, 10);
}

export function ago(seconds: number) {
  if (seconds < 45) return "just now";
  const m = Math.round(seconds / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

export function greeting(d = new Date()) {
  const h = d.getHours();
  return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
}

export function countdown(seconds: number) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${h}h ${String(m).padStart(2, "0")}m`;
}

export const TIME_OPTIONS = Array.from({ length: 49 }, (_, i) => i * 30); // 00:00 → 24:00
