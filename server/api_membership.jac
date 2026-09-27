"""Sign-up, join codes and employers (public + employee endpoints).

Sign-up is three calls from the web client: `check_signup` (validates everything first, so no half-made
account can exist), the platform's /user/register + /user/login (Jac's built-in auth), then
`register_employer` / `register_employee`, which create the profile for the signed-in login.
"""

import re;
import from zoneinfo { ZoneInfo }
import from server.clock { now_s }
import from server.config {
    TIMEZONE,
    DEFAULT_PAY_RATE,
    INTERNATIONAL_WEEKLY_CAP,
    WORKER_WEEKLY_LIMIT
}
import from server.notify { log_event }
import from server.models {
    Account,
    Employer,
    Employee,
    Employment,
    Position,
    University,
    hub,
    put,
    employer_of,
    university_of,
    position_of
}
import from server.membership {
    JoinError,
    normalize_code,
    employer_by_code,
    new_join_code,
    university_named,
    org_card,
    can_join,
    add_member,
    leave_team
}
import from server.api_common {
    ApiError,
    guarded,
    me,
    me_student,
    check_email,
    check_password,
    account_by_email,
    session_payload
}

def _tz(value: str) -> str {
    name = str(value or "").strip();
    try {
        ZoneInfo(name);
        return name;
    } except Exception {
        return TIMEZONE;
    }
}

def _clean_name(v: str, n: int) -> str {
    return re.sub(r"\s+", " ", str(v or "").strip())[:n];
}

# ------------------------------------------------------------------ public
@guarded
def:pub lookup_join_code(code: str = "") -> dict[str, any] {
    d = employer_by_code(str(code or ""));
    if d is None {
        raise ApiError("No employer uses that code. Check it with your manager.");
    }
    return org_card(d);
}

@guarded
def:pub list_universities(query: str = "") -> dict[str, any] {
    q = str(query or "").strip().lower();
    rows = sorted(
        [u for u in [hub() --> [?:University]] if not q or q in u.name.lower()],
        key=lambda (u: University) -> str { return u.name; }
    )[:20];
    return {"universities": [{"id": jid(u), "name": u.name} for u in rows]};
}

"""Validate a sign-up before the login is created (so a failed sign-up never leaves an account behind)."""
@guarded
def:pub check_signup(
    role: str = "",
    email: str = "",
    password: str = "",
    name: str = "",
    organization: str = "",
    kind: str = "",
    university: str = "",
    code: str = "",
    status: str = ""
) -> dict[str, any] {
    if role == "department" {
        org = _clean_name(organization, 120);
        if len(org) < 2 {
            raise ApiError("Enter your organization's name.");
        }
        if not str(name or "").strip() {
            raise ApiError("Missing name.");
        }
        check_email(email);
        check_password(password);
        if kind == "campus" and not _clean_name(university, 160) {
            raise ApiError("Enter your university's name.");
        }
    } else {
        nm = _clean_name(name, 120);
        if len(nm) < 2 {
            raise ApiError("Enter your full name.");
        }
        d = employer_by_code(str(code or ""));
        if d is None {
            raise ApiError("No employer uses that join code. Check it with your manager.");
        }
        check_email(email);
        check_password(password);
        k = "worker" if kind == "worker" else "student";
        probe = Employee(name=nm, kind=k, school=d.university if k == "student" else "", status="domestic");
        reason = can_join(probe, d);
        if reason {
            raise ApiError(reason);
        }
    }
    e = check_email(email);
    if account_by_email(e) is not None {
        raise ApiError("An account with this email already exists. Try signing in.");
    }
    return {"ok": True};
}

def _new_account(email: str, role: str, name: str, ref: str) -> Account {
    e = email.strip().lower();
    if account_by_email(e) is not None {
        raise ApiError("An account with this email already exists. Try signing in.");
    }
    acc = Account(email=e, role=role, name=name, root_id=jid(root), ref=ref, created=now_s());
    put(hub(), acc);
    return acc;
}

def _no_profile_yet() {
    rid = jid(root);
    if [hub() --> [?:Account, root_id == rid]] {
        raise ApiError("This login already has a CampusSync profile. Sign in instead.");
    }
}

@guarded
def:protect register_employer(
    organization: str = "",
    name: str = "",
    email: str = "",
    kind: str = "business",
    university: str = "",
    timezone: str = "",
    description: str = ""
) -> dict[str, any] {
    _no_profile_yet();
    org = _clean_name(organization, 120);
    person = str(name or "").strip()[:120];
    if len(org) < 2 {
        raise ApiError("Enter your organization's name.");
    }
    if not person {
        raise ApiError("Missing name.");
    }
    e = check_email(email);
    k = "campus" if kind == "campus" else "business";
    uni: University | None = None;
    if k == "campus" {
        uni = university_named(str(university or ""));
        if uni is None {
            raise ApiError("Enter your university's name.");
        }
    }
    code = "";
    try {
        code = new_join_code(org);
    } except JoinError as je {
        raise ApiError(str(je));
    }
    dept = Employer(
        name=org,
        kind=k,
        type="department" if k == "campus" else "vendor",
        university=jid(uni) if uni is not None else "",
        join_code=code,
        timezone=_tz(timezone),
        default_pay_rate=DEFAULT_PAY_RATE,
        default_weekly_hours=20 if k == "campus" else 40,
        description=str(description or "").strip()[:500],
        auto_recruit=k == "campus",
        created=now_s()
    );
    put(hub(), dept);
    acc = _new_account(e, "department", person, jid(dept));
    log_event(
        "Coordinator", f"Welcome to CampusSync · share join code {dept.join_code} with your team", employer=dept, level="done"
    );
    out = session_payload(acc);
    out["department_id"] = jid(dept);
    out["join_code"] = dept.join_code;
    return out;
}

@guarded
def:protect register_employee(
    name: str = "",
    email: str = "",
    code: str = "",
    kind: str = "student",
    status: str = "domestic",
    student_number: str = ""
) -> dict[str, any] {
    _no_profile_yet();
    nm = _clean_name(name, 120);
    if len(nm) < 2 {
        raise ApiError("Enter your full name.");
    }
    dept = employer_by_code(str(code or ""));
    if dept is None {
        raise ApiError("No employer uses that join code. Check it with your manager.");
    }
    e = check_email(email);
    k = "worker" if kind == "worker" else "student";
    st: Employee | None = None;
    if k == "student" {
        stat = "international" if status == "international" else "domestic";
        limit = INTERNATIONAL_WEEKLY_CAP if stat == "international" else 20;
        st = Employee(
            name=nm, email=e, kind="student", school=dept.university, status=stat, weekly_limit=limit,
            student_number=str(student_number or "").strip()[:40], desired_hours=0, preferences=[],
            open_swap_days=[], created=now_s()
        );
    } else {
        st = Employee(
            name=nm, email=e, kind="worker", status="domestic", weekly_limit=WORKER_WEEKLY_LIMIT, desired_hours=0,
            preferences=[], open_swap_days=[], created=now_s()
        );
    }
    person: Employee = st;
    reason = can_join(person, dept);
    if reason {
        raise ApiError(reason);
    }
    put(hub(), person);
    acc = _new_account(e, "student", nm, jid(person));
    add_member(person, dept);
    out = session_payload(acc);
    out["student_id"] = jid(person);
    out["employer"] = org_card(dept);
    return out;
}

# ------------------------------------------------------------------ employee
@guarded
def:protect join_employer(code: str = "") -> dict[str, any] {
    st = me_student();
    dept = employer_by_code(str(code or ""));
    if dept is None {
        raise ApiError("No employer uses that join code. Check it with your manager.");
    }
    reason = can_join(st, dept);
    if reason {
        raise ApiError(reason);
    }
    if st.kind == "student" and not st.school {
        st.school = dept.university;
    }
    add_member(st, dept);
    return {"ok": True, "employer": org_card(dept)};
}

@guarded
def:protect leave_employer(department_id: str = "") -> dict[str, any] {
    st = me_student();
    dept = employer_of(str(department_id or ""));
    if dept is None {
        raise ApiError("Employer not found.");
    }
    released = 0;
    try {
        released = leave_team(st, dept);
    } except JoinError as je {
        raise ApiError(str(je));
    }
    return {"ok": True, "released": released};
}

@guarded
def:protect get_my_employers() -> dict[str, any] {
    st = me_student();
    rows = sorted(
        [e for e in [st --> [?:Employment]] if e.state in ("active", "invited")],
        key=lambda (e: Employment) -> str { return e.created; }
    );
    out: list[dict[str, any]] = [];
    for e in rows {
        d = employer_of(e.employer);
        if d is None {
            continue;
        }
        roles: list[str] = [];
        for pid in (e.positions or []) {
            p = position_of(pid);
            if p is not None {
                roles.append(p.name);
            }
        }
        card = org_card(d);
        card["state"] = e.state;
        card["hours"] = e.hours;
        card["pay_rate"] = e.pay_rate;
        card["roles"] = roles;
        out.append(card);
    }
    uni = university_of(st.school);
    return {
        "employers": out,
        "kind": st.kind,
        "university": uni.name if uni is not None else None,
        "can_join_more": st.kind == "student" or not any([e.state == "active" for e in rows])
    };
}
