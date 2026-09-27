"""App shells: the employer's desktop rail layout and the employee's phone layout, plus the bell and `useMe`."""

import from react { createContext, useContext, useEffect, useRef, useState }
import from "react-router-dom" { NavLink, Outlet, useLocation, useNavigate }
import from "lucide-react" { ArrowLeftRight, Bell, CalendarRange, Clock3, Gauge, Inbox, LogOut, Menu, Settings2, Sparkles, User, Users }
import from web.lib.api { api, setSession, useWalker }
import from web.lib.push { unlinkDeviceOnSignOut }
import from web.lib.time { ago }
import from web.components.CommandBar { CommandBar }
import from web.components.ui { ErrorBlock, PageSkeleton, Wordmark }

glob:pub JS: any = globalThis;
glob:pub MeCtx: any = createContext(None);

"""Who is signed in: {role, name, email, department?: {...}, student?: {...}}"""
def:pub useMe() -> any {
    me: any = useContext(MeCtx);
    return me;
}

async def:pub signOut(nav: any) -> None {
    await unlinkDeviceOnSignOut();
    setSession(None);
    nav("/signin");
}

def _active(st: any) -> str {
    return "active" if st.isActive else "";
}

def:pub NotificationBell() -> JsxElement {
    q: any = useWalker("get_notifications", {}, 5000);
    data: any = q["data"];
    reload: any = q["reload"];
    has open: bool = False;
    ref: any = useRef(None);
    nav: any = useNavigate();
    useEffect(
        lambda -> any {
            h: any = lambda (e: any) {
                if ref.current and not ref.current.contains(e.target) {
                    open = False;
                }
            };
            JS.document.addEventListener("mousedown", h);
            return lambda { JS.document.removeEventListener("mousedown", h); };
        },
        []
    );
    async def toggle() -> None {
        nxt: bool = not open;
        open = nxt;
        if nxt and data and data.unread {
            await api("mark_notifications_read");
            reload(True);
        }
    }
    def openLink(link: str) -> any {
        return lambda (e: MouseEvent) {
            e.preventDefault();
            open = False;
            if link {
                nav(link);
            }
        };
    }
    unread: int = data.unread if data else 0;
    items: any = data.items if data else [];
    <div className="bell" ref={ref}>
        <button className="btn icon ghost" style={{"borderColor": "transparent"}} aria-label={"Notifications" + ((", " + str(unread) + " unread") if unread else "")} onClick={lambda (e: MouseEvent) { toggle(); }}>
            <Bell size={17} strokeWidth={1.7} />
        </button>
        {unread > 0 and <span className="bell-dot" aria-hidden={True} />}
        {open and <div className="dropdown">
            {not items.length and <div className="item ink-2">You're all caught up.</div>}
            {for n in items {
                <a key={n.id} href={n.link or "#"} className={"item " + ("read" if n.read else "unread")}
                    onClick={openLink(n.link)}>
                    <div className="grow">{n.title and <div className="w600">{n.title}</div>}<div>{n.text}</div><div className="t-small ink-3 mt4">{ago(n.seconds_ago)}</div></div>
                </a>
            }}
        </div>}
    </div>
}

def useMeLoader(role: str) -> any {
    q: any = useWalker("whoami");
    nav: any = useNavigate();
    data: any = q["data"];
    useEffect(
        lambda -> any {
            if data and data.role != role {
                nav("/d" if data.role == "department" else "/s", {"replace": True});
            }
            return JS.undefined;
        },
        [data, role, nav]
    );
    return q;
}

# ---------------- employer shell ----------------
def:pub DeptShell() -> JsxElement {
    me: any = useMeLoader("department");
    approvals: any = useWalker("get_approvals", {}, 4000);
    has open: bool = False;
    nav: any = useNavigate();
    loc: any = useLocation();
    useEffect(lambda -> any { open = False; return JS.undefined; }, [loc.pathname]);
    if me["error"] {
        return <div className="dcontent"><ErrorBlock onRetry={me["reload"]} message={me["error"]} /></div>;
    }
    md: any = me["data"];
    if not md or md.role != "department" {
        return <div className="dcontent"><PageSkeleton /></div>;
    }
    ad: any = approvals["data"];
    pending: int = ad.items.length if ad else 0;
    links: list[dict[str, any]] = [
        {"to": "/d", "label": "Dashboard", "icon": Gauge, "end": True, "badge": 0},
        {"to": "/d/approvals", "label": "Approvals", "icon": Inbox, "end": False, "badge": pending},
        {"to": "/d/schedule", "label": "Schedule", "icon": CalendarRange, "end": False, "badge": 0},
        {"to": "/d/timesheets", "label": "Timesheets", "icon": Clock3, "end": False, "badge": 0},
        {"to": "/d/team", "label": "Team & roles", "icon": Users, "end": False, "badge": 0},
        {"to": "/d/settings", "label": "Settings", "icon": Settings2, "end": False, "badge": 0}
    ];
    dept: any = md.department;
    <MeCtx.Provider value={md}>
        <div className="dshell">
            {open and <div className="scrim" onClick={lambda (e: MouseEvent) { open = False; }} />}
            <aside className={"rail " + ("open" if open else "")}>
                <div className="brand stack g4"><Wordmark /><span className="ink-3 t-small" style={{"paddingLeft": 36}}>{dept.name if dept else ""}</span>
                    <NavLink to="/d/team" className="join-chip" style={{"marginLeft": 36}} title="Employees sign up with this code">Join code <b className="mono">{dept.join_code if dept else ""}</b></NavLink></div>
                <nav className="nav" aria-label="Department">
                    {for l in links {
                        <NavLink key={l["to"]} to={l["to"]} end={l["end"]} className={_active}>
                            <@{l["icon"]} size={16} strokeWidth={1.7} />{l["label"]}
                            {l["badge"] > 0 and <span className="badge" aria-label={str(l["badge"]) + " waiting"}>{l["badge"]}</span>}
                        </NavLink>
                    }}
                </nav>
                <div className="rail-foot">
                    <div className="pill" style={{"justifyContent": "flex-start"}}><span className="live" />Autopilot <b>on</b></div>
                    <div className="row between mt8"><span className="w500">{md.name}</span>
                        <button className="btn icon sm ghost" style={{"borderColor": "transparent"}} aria-label="Sign out" onClick={lambda (e: MouseEvent) { signOut(nav); }}><LogOut size={15} /></button>
                    </div>
                </div>
            </aside>
            <div className="dmain">
                <header className="dtopbar">
                    <button className="btn icon ghost menu-btn" aria-label="Menu" onClick={lambda (e: MouseEvent) { open = True; }}><Menu size={18} /></button>
                    <CommandBar />
                    <div className="row g8" style={{"marginLeft": "auto"}}>
                        <NotificationBell />
                    </div>
                </header>
                <main className="dcontent"><Outlet /></main>
            </div>
        </div>
    </MeCtx.Provider>
}

# ---------------- employee shell (mobile-first; phone frame on large screens) ----------------
def:pub StudentShell() -> JsxElement {
    me: any = useMeLoader("student");
    nav: any = useNavigate();
    loc: any = useLocation();
    scroller: any = useRef(None);
    useEffect(
        lambda -> any {
            if scroller.current {
                scroller.current.scrollTo(0, 0);
            }
            JS.window.scrollTo(0, 0);
            return JS.undefined;
        },
        [loc.pathname]
    );
    md: any = me["data"];
    worker: bool = bool(md and md.student and md.student.kind == "worker");
    tabs: list[dict[str, any]] = [
        {"to": "/s", "label": "Home", "icon": Gauge, "end": True},
        {"to": "/s/ai", "label": "Assistant" if worker else "Campus AI", "icon": Sparkles, "end": False},
        {"to": "/s/time", "label": "Time & pay", "icon": Clock3, "end": False},
        {"to": "/s/requests", "label": "Requests", "icon": ArrowLeftRight, "end": False},
        {"to": "/s/profile", "label": "Profile", "icon": User, "end": False}
    ];
    body: any = None;
    if me["error"] {
        body = <ErrorBlock onRetry={me["reload"]} message={me["error"]} />;
    } elif not md or md.role != "student" {
        body = <PageSkeleton />;
    } else {
        body = <Outlet />;
    }
    <MeCtx.Provider value={md or None}>
        <div className="device-stage">
            <div className="device">
                <div className="device-screen">
                    <header className="stop">
                        <div className="stop-inner">
                            <a href="/s" onClick={lambda (e: MouseEvent) { e.preventDefault(); nav("/s"); }}><Wordmark size={24} /></a>
                            <NotificationBell />
                        </div>
                    </header>
                    <div className="device-scroll" ref={scroller}><main className="scontent">{body}</main></div>
                    <nav className="tabbar" aria-label="Employee">
                        <div className="tabbar-inner">
                            {for t in tabs {
                                <NavLink key={t["to"]} to={t["to"]} end={t["end"]} className={_active}><@{t["icon"]} size={20} strokeWidth={1.7} />{t["label"]}</NavLink>
                            }}
                        </div>
                    </nav>
                </div>
            </div>
            <div className="device-caption">Employee app · built for phones — open this address on your phone and add it to your home screen for alerts</div>
        </div>
    </MeCtx.Provider>
}
