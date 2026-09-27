"""Endpoint plumbing shared by every API module: who is calling, error handling, session payloads,
notifications and the agent feed.

Privacy is enforced HERE, in what endpoints return -- never in the web client.
"""

import re;
import logging;
import functools;
import inspect;
import copy;
import traceback;
import from datetime { date }
import from server.clock { utcnow, today_local, monday, default_week, seconds_since }
import from server.timeutil { week_key }
import from server.models {
    Account,
    Employer,
    Employee,
    Employment,
    Notification,
    AgentEvent,
    University,
    hub,
    account_of,
    employer_of,
    employee_of,
    university_of
}

glob log = logging.getLogger("campussync.api"),
     EMAIL_RE: any = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$"),
     _acct_cache: dict[str, str] = {};

"""Optional endpoint parameters default to UNSET (a missing JSON key must not arrive as the text "None")."""
glob UNSET: str = "__unset__";

def opt(v: any) -> any {
    return None if v is None or v == UNSET else v;
}

"""A message the person should see (the web client shows it as-is)."""
class ApiError(Exception) {}

def _is_conflict(e: BaseException) -> bool {
    cur: BaseException | None = e;
    seen = 0;
    while cur is not None and seen < 8 {
        c: BaseException = cur;
        for arg in getattr(c, "args", ()) {
            if isinstance(arg, dict) and arg.get("C") in ("40001", "40P01", "55P03", "08006") {
                return True;
            }
        }
        if "SessionConflict" in type(c).__name__ {
            return True;
        }
        cur = c.__cause__ or c.__context__;
        seen += 1;
    }
    return False;
}

"""Never leak internals (they could name another employer): unexpected errors become one safe line."""
def guarded(fn: any) -> any {
    sig = inspect.signature(fn);
    @functools.wraps(fn)
    def wrapper(*args: any, **kwargs: any) -> any {
        try {
            # A parameter the caller left out can arrive as the text of its default ("False", "0", "[]");
            # put the real default back.
            bound = sig.bind_partial(*args, **kwargs);
            for (pname, val) in list(bound.arguments.items()) {
                dflt = sig.parameters[pname].default;
                if dflt is not inspect.Parameter.empty and not isinstance(dflt, str) and isinstance(val, str)
                    and (val == str(dflt) or val == repr(dflt)) {
                    bound.arguments[pname] = copy.copy(dflt);
                }
            }
            return fn(*bound.args, **bound.kwargs);
        } except ApiError as ae {
            raise ae;
        } except Exception as ex {
            if _is_conflict(ex) {
                raise ex;
            }
            log.error("endpoint %s failed: %s\n%s", getattr(fn, "__name__", "?"), str(ex), traceback.format_exc());
            raise ApiError("Something went wrong. Your data is safe.");
        }
    }
    return wrapper;
}

# ------------------------------------------------------------------ identity
"""The signed-in person's account (their platform root is linked to one Account on the hub)."""
def me() -> Account {
    rid = jid(root);
    if rid in _acct_cache {
        a = account_of(_acct_cache[rid]);
        if a is not None and a.root_id == rid {
            return a;
        }
    }
    rows = [hub() --> [?:Account, root_id == rid]];
    if not rows {
        raise ApiError("Please sign in again.");
    }
    _acct_cache[rid] = jid(rows[0]);
    return rows[0];
}

def me_student() -> Employee {
    a = me();
    if a.role != "student" {
        raise ApiError("Employees only.");
    }
    st = employee_of(a.ref);
    if st is None {
        raise ApiError("Employees only.");
    }
    return st;
}

def me_employer() -> Employer {
    a = me();
    if a.role != "department" {
        raise ApiError("Employers only.");
    }
    d = employer_of(a.ref);
    if d is None {
        raise ApiError("Employers only.");
    }
    return d;
}

def check_email(email: str) -> str {
    e = (email or "").strip().lower();
    if not EMAIL_RE.match(e) or len(e) > 200 {
        raise ApiError("Enter a valid email address.");
    }
    return e;
}

def check_password(password: str) {
    if len(password or "") < 8 {
        raise ApiError("Use at least 8 characters for your password.");
    }
    if len(password) > 200 {
        raise ApiError("That password is too long.");
    }
}

def account_by_email(email: str) -> Account | None {
    e = email.strip().lower();
    rows = [hub() --> [?:Account, email == e]];
    return rows[0] if rows else None;
}

def session_payload(a: Account) -> dict[str, any] {
    return {"role": a.role, "name": a.name};
}

"""The week a screen asks for (any date in it), else the default week."""
def week_arg(week: str) -> str {
    if not week {
        return default_week();
    }
    try {
        return week_key(str(week), monday(today_local()));
    } except ValueError {
        raise ApiError("That week isn't a valid date.");
    }
}

# ------------------------------------------------------------------ who am I
@guarded
def:protect whoami() -> dict[str, any] {
    a = me();
    out: dict[str, any] = {"role": a.role, "name": a.name, "email": a.email};
    if a.role == "department" {
        d = me_employer();
        uni = university_of(d.university);
        out["department"] = {
            "id": jid(d), "name": d.name, "type": d.type, "kind": d.kind, "join_code": d.join_code,
            "university": uni.name if uni is not None else None, "timezone": d.timezone
        };
    } else {
        s = me_student();
        uni = university_of(s.school);
        jobs = len([e for e in [s --> [?:Employment]] if e.state == "active"]);
        out["student"] = {
            "id": jid(s), "name": s.name, "first_name": s.first_name(), "status": s.status, "kind": s.kind,
            "international": s.is_international(), "cap": s.cap(),
            "university": uni.name if uni is not None else None, "jobs": jobs
        };
    }
    return out;
}

# ------------------------------------------------------------------ notifications
def _owner() -> any {
    a = me();
    if a.role == "department" {
        return me_employer();
    }
    return me_student();
}

@guarded
def:protect get_notifications() -> dict[str, any] {
    owner = _owner();
    rows = sorted(
        list([owner --> [?:Notification]]),
        key=lambda (n: Notification) -> str { return n.created; },
        reverse=True
    )[:30];
    return {
        "unread": len([n for n in rows if not n.read]),
        "items": [
            {
                "id": jid(n), "title": n.title, "text": n.text, "link": n.link, "read": n.read, "kind": n.kind,
                "seconds_ago": seconds_since(n.created)
            }
            for n in rows
        ]
    };
}

@guarded
def:protect mark_notifications_read() -> dict[str, any] {
    owner = _owner();
    for n in [_q for _q in [owner --> [?:Notification]] if _q.read == False] {
        n.read = True;
    }
    return {"ok": True};
}

# ------------------------------------------------------------------ feed
def events_for(owner: any, since: str = "", limit: int = 40) -> list[dict[str, any]] {
    rows = sorted(
        [e for e in [owner --> [?:AgentEvent]] if not since or e.created > since],
        key=lambda (e: AgentEvent) -> str { return e.created; },
        reverse=True
    )[:limit];
    return [
        {
            "id": e.created, "agent": e.agent, "kind": e.kind, "text": e.text, "level": e.level, "link": e.link,
            "seconds_ago": seconds_since(e.created)
        }
        for e in rows
    ];
}

@guarded
def:protect get_agent_feed(since: str = "", limit: int = 40) -> dict[str, any] {
    return {"events": events_for(_owner(), str(since or ""), int(limit or 40))};
}
