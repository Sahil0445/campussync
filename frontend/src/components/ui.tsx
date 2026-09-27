import { createContext, ReactNode, useCallback, useContext, useEffect, useRef, useState } from "react";
import { Check, ChevronRight, Clock, Lock, Minus, OctagonX, Plus, Search, X } from "lucide-react";

/* ---------------- toasts ---------------- */
type ToastItem = { id: number; text: string; ok: boolean };
const ToastCtx = createContext<(text: string, ok?: boolean) => void>(() => {});
export const useToast = () => useContext(ToastCtx);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const push = useCallback((text: string, ok = true) => {
    const id = Date.now() + Math.random();
    setItems((xs) => [...xs, { id, text, ok }]);
    window.setTimeout(() => setItems((xs) => xs.filter((x) => x.id !== id)), ok ? 4000 : 7000);
  }, []);
  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div className="toast-host" role="status" aria-live="polite">
        {items.map((t) => (
          <div key={t.id} className={`toast ${t.ok ? "" : "bad"}`} role={t.ok ? undefined : "alert"}>{t.ok ? <Check size={16} strokeWidth={2} /> : <OctagonX size={16} strokeWidth={1.8} className="c-block" />}{t.text}</div>
        ))}
      </div>
    </ToastCtx.Provider>
  );
}

/* ---------------- status: always color + icon + word ---------------- */
export type ChipKind = "ok" | "wait" | "block" | "neutral" | "accent";
export function StatusChip({ kind, children }: { kind: ChipKind; children: ReactNode }) {
  const Icon = kind === "ok" ? Check : kind === "wait" ? Clock : kind === "block" ? X : null;
  return <span className={`chip ${kind}`}>{Icon && <Icon size={12} strokeWidth={2.2} />}{children}</span>;
}

export function Privacy({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <div className={`privacy ${className}`}><Lock size={14} strokeWidth={1.6} aria-label="Private" /><span>{children}</span></div>;
}

export function Note({ kind = "neutral", icon, children }: { kind?: "neutral" | "wait" | "block" | "ok"; icon?: ReactNode; children: ReactNode }) {
  const fallback = kind === "block" ? <OctagonX size={16} strokeWidth={1.6} /> : kind === "wait" ? <Clock size={16} strokeWidth={1.6} /> : kind === "ok" ? <Check size={16} strokeWidth={2} /> : null;
  return <div className={`note ${kind}`}>{icon ?? fallback}<div>{children}</div></div>;
}

/* ---------------- inputs ---------------- */
export function Segmented<T extends string>({ value, options, onChange, full, label }: {
  value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; full?: boolean; label?: string;
}) {
  return (
    <div className={`segmented ${full ? "full" : ""}`} role="group" aria-label={label}>
      {options.map((o) => <button key={o.value} type="button" aria-pressed={value === o.value} onClick={() => onChange(o.value)}>{o.label}</button>)}
    </div>
  );
}

export function Stepper({ value, onChange, min = 1, max = 99, label }: { value: number; onChange: (n: number) => void; min?: number; max?: number; label?: string }) {
  return (
    <div className="stepper" role="group" aria-label={label}>
      <button type="button" aria-label="Decrease" onClick={() => onChange(Math.max(min, value - 1))}><Minus size={14} /></button>
      <span aria-live="polite">{value}</span>
      <button type="button" aria-label="Increase" onClick={() => onChange(Math.min(max, value + 1))}><Plus size={14} /></button>
    </div>
  );
}

export function Switch({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return <button type="button" role="switch" aria-checked={checked} aria-label={label} className="switch" onClick={() => onChange(!checked)} />;
}

export function Field({ label, helper, children, htmlFor }: { label: string; helper?: ReactNode; children: ReactNode; htmlFor?: string }) {
  return <div className="field"><label htmlFor={htmlFor}>{label}</label>{children}{helper && <div className="helper">{helper}</div>}</div>;
}

export function SearchInput(props: React.InputHTMLAttributes<HTMLInputElement>) {
  return <div className="input-icon"><Search size={16} strokeWidth={1.6} /><input className="input" type="search" {...props} /></div>;
}

/* ---------------- overlays ---------------- */
function useEscape(onClose: () => void) {
  useEffect(() => {
    const h = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [onClose]);
}

export function Modal({ onClose, children, wide, sheet, label }: { onClose: () => void; children: ReactNode; wide?: boolean; sheet?: boolean; label: string }) {
  useEscape(onClose);
  return (
    <div className={`modal-wrap ${sheet ? "sheet-mobile" : ""}`} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal ${wide ? "wide" : ""}`} role="dialog" aria-modal="true" aria-label={label}>{children}</div>
    </div>
  );
}

export function Drawer({ onClose, children, label }: { onClose: () => void; children: ReactNode; label: string }) {
  useEscape(onClose);
  return (
    <div className="drawer-wrap" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <aside className="drawer" role="dialog" aria-modal="true" aria-label={label}>{children}</aside>
    </div>
  );
}

export function CloseButton({ onClick }: { onClick: () => void }) {
  return <button className="btn icon sm ghost" onClick={onClick} aria-label="Close" style={{ borderColor: "transparent" }}><X size={16} /></button>;
}

/* ---------------- states ---------------- */
export function Skeleton({ h = 16, w = "100%", style }: { h?: number; w?: number | string; style?: React.CSSProperties }) {
  return <div className="skel" style={{ height: h, width: w, ...style }} />;
}

export function PageSkeleton() {
  return (
    <div className="stack g24" aria-busy="true" aria-label="Loading">
      <Skeleton h={34} w="42%" />
      <div className="kpis">{[0, 1, 2, 3].map((i) => <Skeleton key={i} h={118} />)}</div>
      <Skeleton h={300} />
    </div>
  );
}

export function ErrorBlock({ onRetry, message }: { onRetry?: () => void; message?: string }) {
  return (
    <div className="card error-inline" role="alert">
      <span>{message && message !== "Something went wrong. Your data is safe." ? message : "Something went wrong loading this. Your data is safe."}</span>
      {onRetry && <button className="btn sm" onClick={() => onRetry()}>Try again</button>}
    </div>
  );
}

export function Disclosure({ summary, children, open }: { summary: ReactNode; children: ReactNode; open?: boolean }) {
  return <details className="disclosure" open={open}><summary><ChevronRight size={14} />{summary}</summary><div className="mt8">{children}</div></details>;
}

/* ---------------- brand ---------------- */
/** Calendar tile + sync loop: schedules across campus, kept in sync. */
export function Logo({ size = 26 }: { size?: number }) {
  return (
    <span className="logo" aria-hidden>
      <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <defs><linearGradient id="csLogo" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#A18BFF" /><stop offset="0.5" stopColor="#6C8CFF" /><stop offset="1" stopColor="#3DD8F5" /></linearGradient></defs>
        <rect x="0.5" y="0.5" width="23" height="23" rx="4" fill="url(#csLogo)" />
        <path d="M8 3.6v3.2M16 3.6v3.2" stroke="#070812" strokeWidth="1.8" strokeLinecap="round" />
        <path d="M4.8 8.6h14.4" stroke="#070812" strokeWidth="1.4" strokeLinecap="round" opacity="0.55" />
        <path d="M8.2 15.4a3.8 3.8 0 0 1 6.6-2.6" stroke="#070812" strokeWidth="1.8" strokeLinecap="round" />
        <path d="M15.1 10.6v2.4h-2.4" stroke="#070812" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
        <path d="M15.8 15.4a3.8 3.8 0 0 1-6.6 2.6" stroke="#070812" strokeWidth="1.8" strokeLinecap="round" />
        <path d="M8.9 20.2v-2.4h2.4" stroke="#070812" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </span>
  );
}

export function Wordmark({ size = 26 }: { size?: number }) {
  return <span className="wordmark"><Logo size={size} />CampusSync</span>;
}

/* ---------------- numbers ---------------- */
export function CountUp({ value, duration = 900, decimals = 0 }: { value: number; duration?: number; decimals?: number }) {
  const [v, setV] = useState(value);
  const from = useRef(0);
  useEffect(() => {
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduced) { setV(value); from.current = value; return; }
    const start = performance.now(), a = from.current, b = value;
    let raf = 0;
    const step = (t: number) => {
      const p = Math.min(1, (t - start) / duration);
      const e = 1 - Math.pow(1 - p, 3);
      setV(a + (b - a) * e);
      if (p < 1) raf = requestAnimationFrame(step); else from.current = b;
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [value, duration]);
  return <>{v.toFixed(decimals)}</>;
}

export function Ring({ value, max, size = 120, stroke = 9, children }: { value: number; max: number; size?: number; stroke?: number; children?: ReactNode }) {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r;
  const pct = max > 0 ? Math.min(1, value / max) : 0;
  const id = useRef(`rg${Math.random().toString(36).slice(2, 8)}`).current;
  return (
    <div className="ring-wrap" style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ transform: "rotate(-90deg)" }} aria-hidden>
        <defs><linearGradient id={id} x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#a18bff" /><stop offset="0.5" stopColor="#6c8cff" /><stop offset="1" stopColor="#3dd8f5" /></linearGradient></defs>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="rgba(255,255,255,0.07)" strokeWidth={stroke} />
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={`url(#${id})`} strokeWidth={stroke} strokeLinecap="round"
                strokeDasharray={c} strokeDashoffset={c * (1 - pct)} style={{ transition: "stroke-dashoffset 1s cubic-bezier(.2,.7,.2,1)", filter: "drop-shadow(0 0 6px rgba(108,140,255,.6))" }} />
      </svg>
      <div className="center-label">{children}</div>
    </div>
  );
}

export function Aurora() {
  return <div className="aurora" aria-hidden><div className="grid" /></div>;
}
