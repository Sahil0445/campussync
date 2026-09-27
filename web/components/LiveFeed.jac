"""The agent activity log: polls for new rows and streams them in.

An event: {id (its timestamp), agent, kind, text, level, link, seconds_ago, at?}
"""

import from react { useEffect, useRef, useState }
import from "react-router-dom" { useNavigate }
import from web.lib.api { api }
import from web.lib.time { ago, jsSort }

glob:pub JS: any = globalThis;

def _stamp(xs: any) -> any {
    out: list[any] = [];
    for e in xs {
        if e.at {
            out.append(e);
        } else {
            out.append(JS.Object.assign({}, e, {"at": JS.Date.now() - e.seconds_ago * 1000}));
        }
    }
    return out;
}

def _newest(xs: any, cur: str) -> str {
    best = cur;
    for e in xs {
        if str(e.id) > best {
            best = str(e.id);
        }
    }
    return best;
}

def _by_id_desc(a: any, b: any) -> int {
    x = str(a.id);
    y = str(b.id);
    return -1 if x > y else (1 if x < y else 0);
}

"""Polls the agent event log. `onActive` reports agents seen in the last ~20s."""
def:pub useAgentFeed(initial: any = None, poll: int = 2500, onActive: any = None) -> any {
    st: any = useState(_stamp(initial or []));
    events: any = st[0];
    setEvents: any = st[1];
    st_now: any = useState(0);
    setNow: any = st_now[1];
    last: any = useRef("");
    cb: any = useRef(onActive);
    cb.current = onActive;

    useEffect(
        lambda -> any {
            if initial and not events.length {
                setEvents(_stamp(initial));
            }
            return JS.undefined;
        },
        [initial]
    );
    useEffect(
        lambda -> any {
            last.current = _newest(events, last.current);
            return JS.undefined;
        },
        [events]
    );
    useEffect(
        lambda -> any {
            box: any = {"alive": True};
            async def run -> None {
                if JS.document.hidden {
                    return;
                }
                try {
                    r: any = await api("get_agent_feed", {"since": last.current, "limit": 30});
                    if not box["alive"] or not r.events.length {
                        return;
                    }
                    setEvents(
                        lambda (xs: any) -> any {
                            seen: set[str] = set([str(x.id) for x in xs]);
                            fresh: any = _stamp([x for x in r.events if str(x.id) not in seen]);
                            if not fresh.length {
                                return xs;
                            }
                            merged: any = JS.Array.prototype.concat.call(fresh, xs);
                            return jsSort(merged, _by_id_desc).slice(0, 80);
                        }
                    );
                } except Exception {
                    return;
                }
            }
            run();
            iv: any = JS.window.setInterval(lambda { run(); setNow(JS.Date.now()); }, poll);
            return lambda {
                box["alive"] = False;
                JS.window.clearInterval(iv);
            };
        },
        [poll]
    );
    now: float = JS.Date.now();
    recent: list[str] = [e.agent for e in events if now - (e.at or 0) < 20000 and e.kind != "human"];
    names: list[str] = sorted(list(set(recent)));
    key: str = "|".join(names);
    useEffect(
        lambda -> any {
            if cb.current {
                cb.current(key.split("|") if key else []);
            }
            return JS.undefined;
        },
        [key]
    );
    return events;
}

def:pub LiveFeed(events: any, limit: int = 12, empty: str = "Agents are standing by.") -> JsxElement {
    nav: any = useNavigate();
    if not events.length {
        return <div className="ink-3" style={{"padding": "12px 0"}}>{empty}</div>;
    }
    now: float = JS.Date.now();
    def go(link: str) -> any {
        return lambda (ev: MouseEvent) {
            ev.preventDefault();
            nav(link);
        };
    }
    <div className="feed" aria-live="polite">
        {for e in events.slice(0, limit) {
            at: float = e.at or (now - e.seconds_ago * 1000);
            secs: int = JS.Math.max(0, JS.Math.round((now - at) / 1000));
            <div key={e.id} className="feed-row">
                <span className={"feed-dot " + e.level} />
                <div className="stack g4">
                    <div className="feed-meta"><span style={{"color": "#7fdcf0" if e.kind == "rules" else ("#ffe3a3" if e.kind == "human" else "#b9c1ff")}}>{e.agent}</span><span>·</span><span>{ago(secs)}</span></div>
                    {<a href={e.link} className="feed-text" onClick={go(e.link)}>{e.text}</a> if e.link else <span className="feed-text">{e.text}</span>}
                </div>
            </div>
        }}
    </div>
}
