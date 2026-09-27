"""Agent feed + notifier.

log_event: the live feed on Mission Control and in the employee app. Employer events never name
another employer; employee events are shown to that employee only.

Notifications are in-app and also delivered as phone push (see push.jac). `dedupe_key` makes an
alert idempotent: the alert scheduler runs every few seconds and each reminder still goes out once.
"""

import from server.clock { now_s }
import from server.models {
    Employer,
    Employee,
    AgentEvent,
    Notification,
    put
}

def log_event(
    agent: str,
    text: str,
    kind: str = "agent",
    employer: Employer | None = None,
    student: Employee | None = None,
    level: str = "info",
    link: str = ""
) {
    ev = AgentEvent(
        agent=agent,
        kind=kind,
        text=text[:400],
        level=level,
        link=link,
        created=now_s(),
        employer=jid(employer) if employer is not None else "",
        student=jid(student) if student is not None else ""
    );
    if employer is not None {
        put(employer, ev);
    } elif student is not None {
        put(student, ev);
    }
}

def _add(
    owner: any,
    student_id: str,
    employer_id: str,
    text: str,
    link: str,
    title: str,
    kind: str,
    dedupe_key: str,
    push: bool
) -> Notification | None {
    if dedupe_key {
        k = dedupe_key;
        if [owner --> [?:Notification, dedupe_key == k]] {
            return None;
        }
    }
    n = Notification(
        student=student_id,
        employer=employer_id,
        text=text[:1000],
        link=link[:200],
        title=title[:120],
        kind=kind,
        dedupe_key=dedupe_key,
        push=push,
        created=now_s()
    );
    put(owner, n);
    return n;
}

def to_student(
    st: Employee,
    text: str,
    link: str = "",
    title: str = "",
    kind: str = "general",
    dedupe_key: str = "",
    push: bool = True
) -> Notification | None {
    return _add(st, jid(st), "", text, link, title, kind, dedupe_key, push);
}

def to_employer(
    e: Employer,
    text: str,
    link: str = "",
    title: str = "",
    kind: str = "general",
    dedupe_key: str = "",
    push: bool = True
) -> Notification | None {
    return _add(e, "", jid(e), text, link, title, kind, dedupe_key, push);
}
