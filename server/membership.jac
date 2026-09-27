"""Employers, employees and join codes.

* An EMPLOYER registers its organization and gets a unique join code (e.g. DINE-7K2Q).
  A campus employer belongs to a university; a business stands alone.
* An EMPLOYEE signs up with that code and lands on the right team.
    - kind "student": a campus student employee. Can join several employers, all at the same
      university (the 20 h international cap then spans all of them).
    - kind "worker": a regular employee (e.g. a security guard). One employer at a time.
"""

import re;
import secrets;
import from datetime { date, timedelta }
import from server.clock { now_s, today_local }
import from server.notify { log_event, to_student, to_employer }
import from server.models {
    Employer,
    Employee,
    Employment,
    Shift,
    University,
    put,
    also,
    set_holder,
    hub,
    employers,
    universities,
    university_of,
    employer_of,
    employment_between
}

glob CODE_ALPHABET: str = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

class JoinError(Exception) {}

# ------------------------------------------------------------------ codes
def normalize_code(code: str) -> str {
    c = re.sub(r"[^A-Za-z0-9]", "", code or "").upper();
    if len(c) > 4 {
        c = f"{c[:-4]}-{c[-4:]}";
    }
    return c;
}

def employer_by_code(code: str) -> Employer | None {
    norm = normalize_code(code);
    if not norm {
        return None;
    }
    rows = [hub() --> [?:Employer, join_code == norm]];
    return rows[0] if rows else None;
}

def new_join_code(name: str) -> str {
    words = re.findall(r"[A-Z0-9]+", name.upper());
    prefix = "".join([w[0] for w in words])[:4] if len(words) > 1 else (words[0][:4] if words else "");
    if len(prefix) < 2 {
        prefix = "TEAM";
    }
    for _i in range(50) {
        code = f"{prefix}-{''.join([secrets.choice(CODE_ALPHABET) for _j in range(4)])}";
        if employer_by_code(code) is None {
            return code;
        }
    }
    raise JoinError("Couldn't make a join code — try again.");
}

def university_named(name: str, create: bool = True) -> University | None {
    clean = re.sub(r"\s+", " ", (name or "").strip())[:160];
    if not clean {
        return None;
    }
    low = clean.lower();
    for u in universities() {
        if u.name.lower() == low {
            return u;
        }
    }
    if not create {
        return None;
    }
    uni = University(name=clean, created=now_s());
    put(hub(), uni);
    return uni;
}

def org_card(d: Employer) -> dict[str, any] {
    uni = university_of(d.university);
    return {"id": jid(d), "name": d.name, "kind": d.kind, "university": uni.name if uni is not None else None};
}

# ------------------------------------------------------------------ rules
"""None if the employee may join this employer, otherwise the reason (shown to the user)."""
def can_join(st: Employee, dept: Employer, ignore_invite: str = "") -> str | None {
    here = employment_between(st, dept);
    if here is not None and here.state == "active" {
        return f"You're already on the {dept.name} team.";
    }
    if st.kind == "student" {
        if dept.kind != "campus" {
            return (
                f"{dept.name} is a business, not a campus employer. Student accounts join employers at their university — "
                + "sign up as a regular employee for other jobs."
            );
        }
        if st.school and dept.university and dept.university != st.school {
            other = university_of(dept.university);
            mine = university_of(st.school);
            return (
                f"{dept.name} is at {other.name if other is not None else 'another university'}. "
                + f"You can only join employers at {mine.name if mine is not None else 'your university'}."
            );
        }
        return None;
    }
    did = jid(dept);
    active = sorted(
        [
            e for e in [_q for _q in [st --> [?:Employment]] if _q.state == "active"]
            if e.employer != did and jid(e) != ignore_invite
        ],
        key=lambda (e: Employment) -> str { return e.created; }
    );
    if active {
        current = employer_of(active[0].employer);
        cname = current.name if current is not None else "another employer";
        return (
            f"You already work for {cname}. Regular employees can belong to one employer at a time — "
            + f"leave {cname} first."
        );
    }
    return None;
}

def add_member(st: Employee, dept: Employer, via: str = "code") -> Employment {
    emp = employment_between(st, dept);
    hours = min(dept.default_weekly_hours or 20, st.cap());
    if emp is not None {
        emp.state = "active";
        emp.hours = emp.hours or hours;
        emp.pay_rate = emp.pay_rate or dept.default_pay_rate;
    } else {
        emp = Employment(
            student=jid(st), employer=jid(dept), hours=hours, state="active", positions=[],
            pay_rate=dept.default_pay_rate, created=now_s()
        );
        put(dept, emp);
        also(st, emp);
    }
    to_employer(
        dept, f"{st.name} joined {dept.name} with your join code. Give them a role.", "/d/team",
        title="New team member"
    );
    log_event(
        "Coordinator",
        f"{st.first_name()} joined the team" + (" with your join code" if via == "code" else ""),
        employer=dept,
        level="done",
        link="/d/team"
    );
    log_event("Coordinator", f"You joined {dept.name}", student=st, level="done");
    return emp;
}

"""When someone leaves: their upcoming shifts become open shifts (drafts are dropped)."""
def release_future_shifts(st: Employee, dept: Employer) -> int {
    today = today_local(dept.timezone);
    sid = jid(st);
    did = jid(dept);
    n = 0;
    rows = [s for s in [st --> [?:Shift]] if s.employer == did and s.student == sid];
    for sh in rows {
        d = date.fromisoformat(sh.week) + timedelta(days=sh.day);
        if d < today {
            continue;
        }
        if sh.status == "draft" {
            del sh;
            continue;
        }
        set_holder(sh, "");
        sh.state = "open";
        n += 1;
    }
    return n;
}

def leave_team(st: Employee, dept: Employer, by_employer: bool = False) -> int {
    emp = employment_between(st, dept);
    if emp is None or emp.state not in ("active", "invited") {
        raise JoinError("Not on this team.");
    }
    emp.state = "left";
    released = release_future_shifts(st, dept);
    if by_employer {
        to_student(
            st, f"{dept.name} removed you from the team." + (" Your upcoming shifts were released." if released else ""),
            "/s"
        );
        log_event(
            "Coordinator",
            f"Removed {st.first_name()} from the team"
                + (f" · {released} upcoming shift{'s' if released != 1 else ''} now open" if released else ""),
            employer=dept,
            kind="human",
            level="info"
        );
    } else {
        to_employer(
            dept,
            f"{st.name} left {dept.name}."
                + (f" {released} upcoming shift{'s are' if released != 1 else ' is'} open again." if released else ""),
            "/d/schedule"
        );
        log_event(
            "Coordinator",
            f"{st.first_name()} left the team"
                + (f" · {released} upcoming shift{'s' if released != 1 else ''} now open" if released else ""),
            employer=dept,
            level="alert"
        );
    }
    return released;
}
