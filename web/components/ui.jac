"""Shared UI building blocks: toasts, status chips, inputs, overlays, loading states, brand, numbers."""

import from react { createContext, useCallback, useContext, useEffect, useRef, useState }
import from "lucide-react" { Check, ChevronRight, Clock, Lock, Minus, OctagonX, Plus, Search, X }

glob:pub JS: any = globalThis;

# ---------------- toasts ----------------
glob:pub ToastCtx: any = createContext(lambda (text: str, ok: bool) {});

"""toast(text) for good news, toast(text, False) for problems."""
def:pub useToast() -> any {
    push: any = useContext(ToastCtx);
    return push;
}

def:pub ToastProvider(children: any = None) -> JsxElement {
    st: any = useState([]);
    items: any = st[0];
    setItems: any = st[1];
    push: any = useCallback(
        lambda (text: str, ok: any) {
            good: bool = ok != False;
            tid: float = JS.Date.now() + JS.Math.random();
            setItems(lambda (xs: any) -> any { return JS.Array.prototype.concat.call(xs, [{"id": tid, "text": text, "ok": good}]); });
            JS.window.setTimeout(
                lambda { setItems(lambda (xs: any) -> any { return xs.filter(lambda (x: any) -> bool { return x.id != tid; }); }); },
                4000 if good else 7000
            );
        },
        []
    );
    <ToastCtx.Provider value={push}>
        {children}
        <div className="toast-host" role="status" aria-live="polite">
            {for t in items {
                <div key={t.id} className={"toast " + ("" if t.ok else "bad")} role={JS.undefined if t.ok else "alert"}>
                    {<Check size={16} strokeWidth={2} /> if t.ok else <OctagonX size={16} strokeWidth={1.8} className="c-block" />}
                    {t.text}
                </div>
            }}
        </div>
    </ToastCtx.Provider>
}

# ---------------- status: always color + icon + word ----------------
def:pub StatusChip(kind: str, children: any = None) -> JsxElement {
    icon: any = None;
    if kind == "ok" {
        icon = <Check size={12} strokeWidth={2.2} />;
    } elif kind == "wait" {
        icon = <Clock size={12} strokeWidth={2.2} />;
    } elif kind == "block" {
        icon = <X size={12} strokeWidth={2.2} />;
    }
    <span className={"chip " + kind}>{icon}{children}</span>
}

def:pub Privacy(children: any = None, className: str = "") -> JsxElement {
    <div className={"privacy " + className}><Lock size={14} strokeWidth={1.6} aria-label="Private" /><span>{children}</span></div>
}

def:pub Note(kind: str = "neutral", icon: any = None, children: any = None) -> JsxElement {
    fallback: any = None;
    if kind == "block" {
        fallback = <OctagonX size={16} strokeWidth={1.6} />;
    } elif kind == "wait" {
        fallback = <Clock size={16} strokeWidth={1.6} />;
    } elif kind == "ok" {
        fallback = <Check size={16} strokeWidth={2} />;
    }
    <div className={"note " + kind}>{icon if icon else fallback}<div>{children}</div></div>
}

# ---------------- inputs ----------------
"""options: [{value, label}]"""
def:pub Segmented(value: any, options: any, onChange: any, full: bool = False, label: str = "") -> JsxElement {
    <div className={"segmented " + ("full" if full else "")} role="group" aria-label={label or None}>
        {for o in options {
            <button key={o.value} type="button" aria-pressed={value == o.value} onClick={lambda (e: MouseEvent) { onChange(o.value); }}>{o.label}</button>
        }}
    </div>
}

def:pub Stepper(value: int, onChange: any, min: int = 1, max: int = 99, label: str = "") -> JsxElement {
    lo = min;
    hi = max;
    <div className="stepper" role="group" aria-label={label or None}>
        <button type="button" aria-label="Decrease" onClick={lambda (e: MouseEvent) { onChange(JS.Math.max(lo, value - 1)); }}><Minus size={14} /></button>
        <span aria-live="polite">{value}</span>
        <button type="button" aria-label="Increase" onClick={lambda (e: MouseEvent) { onChange(JS.Math.min(hi, value + 1)); }}><Plus size={14} /></button>
    </div>
}

def:pub Switch(checked: bool, onChange: any, label: str) -> JsxElement {
    <button type="button" role="switch" aria-checked={checked} aria-label={label} className="switch" onClick={lambda (e: MouseEvent) { onChange(not checked); }} />
}

def:pub Field(label: str, children: any = None, helper: any = None, htmlFor: str = "") -> JsxElement {
    <div className="field"><label htmlFor={htmlFor or None}>{label}</label>{children}{helper and <div className="helper">{helper}</div>}</div>
}

# jac:ignore[W5015]
def:pub SearchInput(props: dict[str, any]) -> JsxElement {
    <div className="input-icon"><Search size={16} strokeWidth={1.6} /><input className="input" type="search" {**props} /></div>
}

# ---------------- overlays ----------------
def:pub useEscape(onClose: any) -> None {
    useEffect(
        lambda -> any {
            h: any = lambda (e: any) {
                if e.key == "Escape" {
                    onClose();
                }
            };
            JS.window.addEventListener("keydown", h);
            return lambda { JS.window.removeEventListener("keydown", h); };
        },
        [onClose]
    );
}

def:pub Modal(onClose: any, label: str, children: any = None, wide: bool = False, sheet: bool = False) -> JsxElement {
    useEscape(onClose);
    <div className={"modal-wrap " + ("sheet-mobile" if sheet else "")} onMouseDown={lambda (e: MouseEvent) { if e.target is e.currentTarget { onClose(); } }}>
        <div className={"modal " + ("wide" if wide else "")} role="dialog" aria-modal="true" aria-label={label}>{children}</div>
    </div>
}

def:pub Drawer(onClose: any, label: str, children: any = None) -> JsxElement {
    useEscape(onClose);
    <div className="drawer-wrap" onMouseDown={lambda (e: MouseEvent) { if e.target is e.currentTarget { onClose(); } }}>
        <aside className="drawer" role="dialog" aria-modal="true" aria-label={label}>{children}</aside>
    </div>
}

def:pub CloseButton(onClick: any) -> JsxElement {
    <button className="btn icon sm ghost" onClick={lambda (e: MouseEvent) { onClick(); }} aria-label="Close" style={{"borderColor": "transparent"}}><X size={16} /></button>
}

# ---------------- states ----------------
def:pub Skeleton(h: any = 16, w: any = "100%", style: any = None) -> JsxElement {
    <div className="skel" style={JS.Object.assign({"height": h, "width": w}, style or {})} />
}

def:pub PageSkeleton() -> JsxElement {
    <div className="stack g24" aria-busy="true" aria-label="Loading">
        <Skeleton h={34} w="42%" />
        <div className="kpis">{for i in [0, 1, 2, 3] { <Skeleton key={i} h={118} /> }}</div>
        <Skeleton h={300} />
    </div>
}

def:pub ErrorBlock(onRetry: any = None, message: any = None) -> JsxElement {
    text = message if message and message != "Something went wrong. Your data is safe." else "Something went wrong loading this. Your data is safe.";
    <div className="card error-inline" role="alert">
        <span>{text}</span>
        {onRetry and <button className="btn sm" onClick={lambda (e: MouseEvent) { onRetry(); }}>Try again</button>}
    </div>
}

def:pub Disclosure(summary: any, children: any = None, open: bool = False) -> JsxElement {
    <details className="disclosure" open={open}><summary><ChevronRight size={14} />{summary}</summary><div className="mt8">{children}</div></details>
}

# ---------------- brand ----------------
"""Calendar tile + sync loop: schedules across campus, kept in sync."""
def:pub Logo(size: int = 26) -> JsxElement {
    <span className="logo" aria-hidden={True}>
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
}

def:pub Wordmark(size: int = 26) -> JsxElement {
    <span className="wordmark"><Logo size={size} />CampusSync</span>
}

# ---------------- numbers ----------------
def:pub CountUp(value: float, duration: int = 900, decimals: int = 0) -> JsxElement {
    st: any = useState(value);
    v: any = st[0];
    setV: any = st[1];
    fromRef: any = useRef(0);
    useEffect(
        lambda -> any {
            mm: any = JS.window.matchMedia;
            reduced: bool = False;
            if mm {
                reduced = JS.window.matchMedia("(prefers-reduced-motion: reduce)").matches;
            }
            if reduced {
                setV(value);
                fromRef.current = value;
                return JS.undefined;
            }
            start: float = JS.performance.now();
            a: float = fromRef.current;
            b: float = value;
            raf: any = {"id": 0};
            step: any = None;
            step = lambda (t: float) {
                p: float = JS.Math.min(1, (t - start) / duration);
                ease: float = 1 - JS.Math.pow(1 - p, 3);
                setV(a + (b - a) * ease);
                if p < 1 {
                    raf["id"] = JS.requestAnimationFrame(step);
                } else {
                    fromRef.current = b;
                }
            };
            raf["id"] = JS.requestAnimationFrame(step);
            return lambda { JS.cancelAnimationFrame(raf["id"]); };
        },
        [value, duration]
    );
    shown: any = v;
    <>{shown.toFixed(decimals)}</>
}

def:pub Ring(value: float, max: float, size: int = 120, stroke: int = 9, children: any = None) -> JsxElement {
    r: float = (size - stroke) / 2;
    c: float = 2 * JS.Math.PI * r;
    pct: float = JS.Math.min(1, value / max) if max > 0 else 0;
    rnd: any = JS.Math.random().toString(36);
    idRef: any = useRef("rg" + rnd.slice(2, 8));
    gid: str = idRef.current;
    <div className="ring-wrap" style={{"width": size, "height": size}}>
        <svg width={size} height={size} viewBox={"0 0 " + str(size) + " " + str(size)} style={{"transform": "rotate(-90deg)"}} aria-hidden={True}>
            <defs><linearGradient id={gid} x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#a18bff" /><stop offset="0.5" stopColor="#6c8cff" /><stop offset="1" stopColor="#3dd8f5" /></linearGradient></defs>
            <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="rgba(255,255,255,0.07)" strokeWidth={stroke} />
            <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={"url(#" + gid + ")"} strokeWidth={stroke} strokeLinecap="round"
                strokeDasharray={c} strokeDashoffset={c * (1 - pct)} style={{"transition": "stroke-dashoffset 1s cubic-bezier(.2,.7,.2,1)", "filter": "drop-shadow(0 0 6px rgba(108,140,255,.6))"}} />
        </svg>
        <div className="center-label">{children}</div>
    </div>
}

def:pub Aurora() -> JsxElement {
    <div className="aurora" aria-hidden={True}><div className="grid" /></div>
}
