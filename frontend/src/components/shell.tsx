import { createContext, useContext, useEffect, useRef, useState } from "react";
import { NavLink, Outlet, useLocation, useNavigate } from "react-router-dom";
import { ArrowLeftRight, Bell, CalendarRange, Clock3, Gauge, Inbox, LogOut, Menu, Settings2, Sparkles, User, Users } from "lucide-react";
import { setSession, useWalker, walker } from "../lib/api";
import { unlinkDeviceOnSignOut } from "../lib/push";
import { ago } from "../lib/time";
import { CommandBar } from "./CommandBar";
import { ErrorBlock, PageSkeleton, Wordmark } from "./ui";

export interface Me {
  role: "student" | "department"; name: string; email: string;
  department?: { id: number; name: string; type: string; kind: "campus" | "business"; join_code: string; university: string | null; timezone: string };
  student?: { id: number; name: string; first_name: string; status: string; kind: "student" | "worker"; international: boolean; cap: number; university: string | null; jobs: number };
}
const MeCtx = createContext<Me | null>(null);
export const useMe = () => useContext(MeCtx)!;

export async function signOut(nav: (p: string) => void) {
  await unlinkDeviceOnSignOut();
  setSession(null);
  nav("/signin");
}

export function NotificationBell() {
  const { data, reload } = useWalker<{ unread: number; items: { id: number; title: string; text: string; link: string; read: boolean; seconds_ago: number }[] }>(
    "get_notifications", {}, { poll: 5000 });
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const nav = useNavigate();
  useEffect(() => {
    const h = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("mousedown", h);
    return () => document.removeEventListener("mousedown", h);
  }, []);
  const toggle = async () => {
    const next = !open;
    setOpen(next);
    if (next && data?.unread) { await walker("mark_notifications_read"); reload(true); }
  };
  return (
    <div className="bell" ref={ref}>
      <button className="btn icon ghost" style={{ borderColor: "transparent" }} aria-label={`Notifications${data?.unread ? `, ${data.unread} unread` : ""}`} onClick={toggle}>
        <Bell size={17} strokeWidth={1.7} />
      </button>
      {!!data?.unread && <span className="bell-dot" aria-hidden />}
      {open && (
        <div className="dropdown">
          {!data?.items.length && <div className="item ink-2">You're all caught up.</div>}
          {data?.items.map((n) => (
            <a key={n.id} href={n.link || "#"} className={`item ${n.read ? "read" : "unread"}`}
               onClick={(e) => { e.preventDefault(); setOpen(false); if (n.link) nav(n.link); }}>
              <div className="grow">{n.title && <div className="w600">{n.title}</div>}<div>{n.text}</div><div className="t-small ink-3 mt4">{ago(n.seconds_ago)}</div></div>
            </a>
          ))}
        </div>
      )}
    </div>
  );
}

function useMeLoader(role: "student" | "department") {
  const q = useWalker<Me>("whoami");
  const nav = useNavigate();
  useEffect(() => { if (q.data && q.data.role !== role) nav(q.data.role === "department" ? "/d" : "/s", { replace: true }); }, [q.data, role, nav]);
  return q;
}

/* ---------------- department shell ---------------- */
export function DeptShell() {
  const me = useMeLoader("department");
  const approvals = useWalker<{ items: unknown[] }>("get_approvals", {}, { poll: 4000 });
  const [open, setOpen] = useState(false);
  const nav = useNavigate();
  const loc = useLocation();
  useEffect(() => setOpen(false), [loc.pathname]);
  if (me.error) return <div className="dcontent"><ErrorBlock onRetry={me.reload} message={me.error} /></div>;
  if (!me.data || me.data.role !== "department") return <div className="dcontent"><PageSkeleton /></div>;
  const pending = approvals.data?.items.length ?? 0;
  const links = [
    { to: "/d", label: "Dashboard", icon: Gauge, end: true },
    { to: "/d/approvals", label: "Approvals", icon: Inbox, badge: pending },
    { to: "/d/schedule", label: "Schedule", icon: CalendarRange },
    { to: "/d/timesheets", label: "Timesheets", icon: Clock3 },
    { to: "/d/team", label: "Team & roles", icon: Users },
    { to: "/d/settings", label: "Settings", icon: Settings2 },
  ];
  return (
    <MeCtx.Provider value={me.data}>
      <div className="dshell">
        {open && <div className="scrim" onClick={() => setOpen(false)} />}
        <aside className={`rail ${open ? "open" : ""}`}>
          <div className="brand stack g4"><Wordmark /><span className="ink-3 t-small" style={{ paddingLeft: 36 }}>{me.data.department?.name}</span>
            <NavLink to="/d/team" className="join-chip" style={{ marginLeft: 36 }} title="Employees sign up with this code">Join code <b className="mono">{me.data.department?.join_code}</b></NavLink></div>
          <nav className="nav" aria-label="Department">
            {links.map((l) => (
              <NavLink key={l.to} to={l.to} end={l.end} className={({ isActive }) => (isActive ? "active" : "")}>
                <l.icon size={16} strokeWidth={1.7} />{l.label}
                {!!l.badge && <span className="badge" aria-label={`${l.badge} waiting`}>{l.badge}</span>}
              </NavLink>
            ))}
          </nav>
          <div className="rail-foot">
            <div className="pill" style={{ justifyContent: "flex-start" }}><span className="live" />Autopilot <b>on</b></div>
            <div className="row between mt8"><span className="w500">{me.data.name}</span>
              <button className="btn icon sm ghost" style={{ borderColor: "transparent" }} aria-label="Sign out" onClick={() => signOut(nav)}><LogOut size={15} /></button>
            </div>
          </div>
        </aside>
        <div className="dmain">
          <header className="dtopbar">
            <button className="btn icon ghost menu-btn" aria-label="Menu" onClick={() => setOpen(true)}><Menu size={18} /></button>
            <CommandBar />
            <div className="row g8" style={{ marginLeft: "auto" }}>
              <NotificationBell />
            </div>
          </header>
          <main className="dcontent"><Outlet /></main>
        </div>
      </div>
    </MeCtx.Provider>
  );
}

/* ---------------- student shell (mobile-first; phone frame on large screens) ---------------- */
export function StudentShell() {
  const me = useMeLoader("student");
  const nav = useNavigate();
  const loc = useLocation();
  const scroller = useRef<HTMLDivElement>(null);
  useEffect(() => { scroller.current?.scrollTo(0, 0); window.scrollTo(0, 0); }, [loc.pathname]);
  const tabs = [
    { to: "/s", label: "Home", icon: Gauge, end: true },
    { to: "/s/ai", label: me.data?.student?.kind === "worker" ? "Assistant" : "Campus AI", icon: Sparkles },
    { to: "/s/time", label: "Time & pay", icon: Clock3 },
    { to: "/s/requests", label: "Requests", icon: ArrowLeftRight },
    { to: "/s/profile", label: "Profile", icon: User },
  ];
  const body = me.error ? <ErrorBlock onRetry={me.reload} message={me.error} />
    : !me.data || me.data.role !== "student" ? <PageSkeleton /> : <Outlet />;
  return (
    <MeCtx.Provider value={me.data ?? null}>
      <div className="device-stage">
        <div className="device">
          <div className="device-screen">
            <header className="stop">
              <div className="stop-inner">
                <a href="/s" onClick={(e) => { e.preventDefault(); nav("/s"); }}><Wordmark size={24} /></a>
                <NotificationBell />
              </div>
            </header>
            <div className="device-scroll" ref={scroller}><main className="scontent">{body}</main></div>
            <nav className="tabbar" aria-label="Employee">
              <div className="tabbar-inner">
                {tabs.map((t) => (
                  <NavLink key={t.to} to={t.to} end={t.end} className={({ isActive }) => (isActive ? "active" : "")}><t.icon size={20} strokeWidth={1.7} />{t.label}</NavLink>
                ))}
              </div>
            </nav>
          </div>
        </div>
        <div className="device-caption">Employee app · built for phones — open this address on your phone and add it to your home screen for alerts</div>
      </div>
    </MeCtx.Provider>
  );
}
