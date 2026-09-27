"""Demo seed. Deterministic: both swap loops and the Saturday gap are guaranteed.

Week: Mon Sep 28 - Sun Oct 4, 2026. Every shift is 4 hours, so swaps never change anyone's totals.

Employers
  * Northfield University (fictional) -- two campus employers: Campus Dining (join code DINE-2026) and
    CSE Research (CSE-2026, exists to hide Priya's other job). Students can hold several jobs here.
  * Shieldpoint Security (SHLD-2026) -- a business with regular employees (one employer each), roles
    (Site guard, Night patrol) and 12-hour shifts.
History: 12 weeks of worked shifts with time entries (approved), the week before the demo week
"reported" (waiting for Friday approval), plus one flagged line for the employer to resolve.
"""

import logging;
import random;
import from datetime { date, timedelta }
import from server.clock { now_s, iso, utcnow, slot_datetime, to_utc_naive }
import from server.config { DEFAULT_WEEK, SCHEMA_VERSION }
import from server.availability { parse_note_fallback }
import from server.notify { log_event }
import from server.models {
    Hub,
    Meta,
    Account,
    University,
    Employer,
    Position,
    Employee,
    BusyBlock,
    Employment,
    Requirement,
    Shift,
    TimeEntry,
    hub,
    put,
    also,
    add_shift,
    employee_of
}

glob log = logging.getLogger("campussync.seed"),
     PASSWORD: str = "demo1234",
     H: int = 60,
     MID: tuple[int, int] = (11 * 60, 15 * 60),
     EVE: tuple[int, int] = (15 * 60, 19 * 60);

obj StudentSeed {
    has name: str,
        email: str,
        status: str,
        uid: str,
        desired: int,
        prefs: list[str],
        open_days: list[int],
        auto: bool,
        classes: list[tuple[list[int], int, int, str]],
        note: str = "";
}

# Autopilot: on for everyone except Marcus -- he's the one who gets asked (and declines) on stage.
glob STUDENTS: list[StudentSeed] = [
    StudentSeed(name="Priya Nair", email="priya@demo.edu", status="international", uid="U1001", desired=20,
        prefs=["Afternoons"], open_days=[2], auto=True,
        classes=[([1, 3], 9 * 60, 10 * 60 + 15, "CSE 5243"), ([0], 16 * 60, 17 * 60 + 15, "STAT 5301")]),
    StudentSeed(name="Marcus Lee", email="marcus@demo.edu", status="domestic", uid="U1002", desired=12,
        prefs=["Afternoons"], open_days=[3], auto=False,
        classes=[([0, 2, 4], 9 * 60, 10 * 60 + 15, "ECON 2001")]),
    StudentSeed(name="Sam Ortiz", email="sam@demo.edu", status="domestic", uid="U1003", desired=12,
        prefs=["Evenings", "Weekends"], open_days=[5], auto=True,
        classes=[([1, 3], 8 * 60, 9 * 60 + 15, "PHYS 1250")]),
    StudentSeed(name="Dana Kim", email="dana@demo.edu", status="domestic", uid="U1004", desired=12,
        prefs=["Evenings"], open_days=[4], auto=True,
        classes=[([0, 2], 10 * 60, 11 * 60 + 15, "BIO 2100")]),
    StudentSeed(name="Leo Chen", email="leo@demo.edu", status="international", uid="U1005", desired=12,
        prefs=["Afternoons"], open_days=[3], auto=True,
        classes=[([2, 4], 9 * 60, 10 * 60 + 15, "MATH 2568")]),
    StudentSeed(name="Ana Silva", email="ana@demo.edu", status="domestic", uid="U1006", desired=12,
        prefs=["Afternoons"], open_days=[], auto=True,
        classes=[([0, 2], 9 * 60, 10 * 60 + 15, "HIST 1010")], note="No weekends — I go home."),
    StudentSeed(name="Ben Carter", email="ben@demo.edu", status="domestic", uid="U1007", desired=12,
        prefs=["Evenings"], open_days=[], auto=True,
        classes=[([1, 3], 13 * 60, 14 * 60 + 15, "ENG 1110")], note="Saturdays I go home."),
    StudentSeed(name="Chloe Martin", email="chloe@demo.edu", status="domestic", uid="U1008", desired=8,
        prefs=["Mornings", "Weekends"], open_days=[], auto=True,
        classes=[([2], 11 * 60, 12 * 60 + 15, "ART 2200")], note="Can't work Saturdays after 3 PM."),
    StudentSeed(name="Omar Haddad", email="omar@demo.edu", status="international", uid="U1009", desired=12,
        prefs=["Afternoons"], open_days=[], auto=True,
        classes=[([4], 9 * 60, 11 * 60 + 30, "CHEM 1210")], note="No weekends."),
    StudentSeed(name="Zoe Wright", email="zoe@demo.edu", status="international", uid="U1010", desired=12,
        prefs=[], open_days=[], auto=True,
        classes=[([1, 3], 16 * 60, 17 * 60 + 15, "PSYC 1100")], note="No weekends."),
    # Not on any team yet -- shows up in "Add student" search.
    StudentSeed(name="Ravi Patel", email="ravi@demo.edu", status="international", uid="U1011", desired=10,
        prefs=["Mornings"], open_days=[], auto=True,
        classes=[([0, 2, 4], 13 * 60, 14 * 60 + 15, "CSE 2221")]),
    StudentSeed(name="Mia Johnson", email="mia@demo.edu", status="domestic", uid="U1012", desired=15,
        prefs=["Evenings"], open_days=[], auto=True,
        classes=[([1, 3], 10 * 60, 11 * 60 + 15, "SOC 1100")])
];

glob DINING_HOURS: list[tuple[str, int]] = [
         ("Priya", 8), ("Marcus", 12), ("Sam", 12), ("Dana", 12), ("Leo", 12),
         ("Ana", 12), ("Ben", 12), ("Chloe", 8), ("Omar", 12), ("Zoe", 8)
     ],
     DINING_SHIFTS: list[tuple[str, int, tuple[int, int]]] = [
         ("Priya", 1, (15 * 60, 19 * 60)), ("Priya", 5, (11 * 60, 15 * 60)),
         ("Marcus", 0, (11 * 60, 15 * 60)), ("Marcus", 1, (11 * 60, 15 * 60)), ("Marcus", 2, (15 * 60, 19 * 60)),
         ("Sam", 0, (15 * 60, 19 * 60)), ("Sam", 1, (15 * 60, 19 * 60)), ("Sam", 3, (11 * 60, 15 * 60)),
         ("Dana", 0, (15 * 60, 19 * 60)), ("Dana", 2, (15 * 60, 19 * 60)), ("Dana", 3, (15 * 60, 19 * 60)),
         ("Leo", 0, (11 * 60, 15 * 60)), ("Leo", 1, (11 * 60, 15 * 60)), ("Leo", 4, (15 * 60, 19 * 60))
     ],
     CSE_SHIFTS: list[tuple[str, int, tuple[int, int]]] = [
         ("Priya", 0, (10 * 60, 14 * 60)), ("Priya", 2, (10 * 60, 14 * 60)), ("Priya", 4, (10 * 60, 14 * 60))
     ],
     GUARDS: list[tuple[str, str, list[str], int, list[int]]] = [
         ("Tom Alvarez", "tom@demo.com", ["guard"], 48, [5, 6]),
         ("Aisha Khan", "aisha@demo.com", ["guard", "patrol"], 40, [0, 1]),
         ("Diego Santos", "diego@demo.com", ["patrol"], 36, [3]),
         ("Grace Liu", "grace@demo.com", ["guard", "patrol"], 40, [2])
     ];

# ------------------------------------------------------------------ accounts
"""Create (or find) the platform login for an email and return its root id."""
def platform_user(email: str, password: str) -> str {
    import from jaclang.server.identity.user_manager { UserManager }
    um = UserManager();
    found = um.find_user_by_identity(email);
    if not found {
        created = um.create_user_with_identities(
            identities=[{"type": "email", "value": email}],
            credential={"type": "password", "password": password}
        );
        if created.get("root_id") {
            return str(created["root_id"]).replace("-", "");
        }
        found = um.find_user_by_identity(email);
    }
    if found and found.get("root_id") {
        return str(found["root_id"]).replace("-", "");
    }
    if found and found.get("user_id") {
        rid = um.get_root_id(str(found["user_id"]));
        return str(rid or "").replace("-", "");
    }
    return "";
}

def make_account(email: str, role: str, name: str, ref: str) -> Account {
    rid = platform_user(email, PASSWORD);
    acc = Account(email=email, role=role, name=name, root_id=rid, ref=ref, created=now_s());
    put(hub(), acc);
    return acc;
}

# ------------------------------------------------------------------ seed
def ensure_seeded() {
    h = hub();
    if h.seeded {
        return;
    }
    seed();
}

def seed() {
    h = hub();
    week = DEFAULT_WEEK.isoformat();
    uni = put(h, University(name="Northfield University", created=now_s()));
    dining = put(
        h,
        Employer(
            name="Campus Dining", type="vendor", kind="campus", university=jid(uni), join_code="DINE-2026",
            description="Campus dining hall. Two shifts a day, Monday to Saturday, busiest at lunch.", created=now_s()
        )
    );
    cse = put(
        h,
        Employer(
            name="CSE Research", type="department", kind="campus", university=jid(uni), join_code="CSE-2026",
            description="Research lab assistants.", created=now_s()
        )
    );
    cashier = put(dining, Position(employer=jid(dining), name="Cashier", color="#a18bff", created=now_s()));
    cook = put(dining, Position(employer=jid(dining), name="Line cook", color="#3dd8f5", created=now_s()));
    lab = put(cse, Position(employer=jid(cse), name="Lab assistant", color="#6c8cff", created=now_s()));
    make_account("dining@demo.edu", "department", "Jordan Avery", jid(dining));
    make_account("cse@demo.edu", "department", "Helen Park", jid(cse));

    by_first: dict[str, Employee] = {};
    for s in STUDENTS {
        events: list[dict[str, any]] = [];
        for (days, start, end, title) in s.classes {
            for d in days {
                events.append({"day": d, "start": start, "end": end, "title": title, "week": ""});
            }
        }
        st = put(
            h,
            Employee(
                name=s.name, email=s.email, status=s.status, student_number=s.uid, weekly_limit=20, kind="student",
                school=jid(uni), desired_hours=s.desired, preferences=s.prefs, open_swap_days=s.open_days,
                autopilot=s.auto, note=s.note, calendar_source="demo", demo_events=events,
                calendar_synced_at=now_s(), created=now_s()
            )
        );
        by_first[s.name.split(" ")[0]] = st;
        make_account(s.email, "student", s.name, jid(st));
        for e in events {
            put(st, BusyBlock(day=e["day"], start=e["start"], end=e["end"], title=e["title"], source="calendar"));
        }
        for rule in parse_note_fallback(s.note) {
            put(st, BusyBlock(day=rule["day"], start=rule["start"], end=rule["end"], title=rule["label"], source="note"));
        }
    }
    for (i, pair) in enumerate(DINING_HOURS) {
        (first, hours) = pair;
        roles = [jid(cashier)] if i % 2 == 0 else [jid(cook)];
        if first in ("Marcus", "Sam") {
            roles = [jid(cashier), jid(cook)];
        }
        _employ(by_first[first], dining, hours, roles);
    }
    _employ(by_first["Priya"], cse, 12, [jid(lab)]);

    for day in range(6) {
        for (start, end) in [MID, EVE] {
            put(dining, Requirement(employer=jid(dining), day=day, start=start, end=end, headcount=2));
        }
    }
    for day in [0, 2, 4] {
        put(cse, Requirement(employer=jid(cse), day=day, start=10 * 60, end=14 * 60, headcount=1, position=jid(lab)));
    }
    for (first, day, span) in DINING_SHIFTS {
        add_shift(
            dining,
            Shift(week=week, day=day, start=span[0], end=span[1], student=jid(by_first[first]), state="assigned", status="published")
        );
    }
    for (first, day, span) in CSE_SHIFTS {
        add_shift(
            cse,
            Shift(
                week=week, day=day, start=span[0], end=span[1], position=jid(lab), student=jid(by_first[first]),
                state="assigned", status="published"
            )
        );
    }
    shield = _seed_business();
    _seed_history([dining, cse, shield]);
    log_event("Availability Agent", "Synced 10 team calendars · autopilot is on", employer=dining, level="info");
    for st in by_first.values() {
        log_event("Availability Agent", "Synced your demo calendar", student=st);
    }
    h.seeded = True;
    h.schema = SCHEMA_VERSION;
    log.info("CampusSync demo data seeded");
}

def _employ(st: Employee, e: Employer, hours: int, roles: list[str]) -> Employment {
    emp = Employment(
        student=jid(st), employer=jid(e), hours=hours, state="active", positions=roles, pay_rate=15.0, created=now_s()
    );
    put(e, emp);
    also(st, emp);
    return emp;
}

# ------------------------------------------------------------------ a business: Shieldpoint Security
def _seed_business() -> Employer {
    h = hub();
    shield = put(
        h,
        Employer(
            name="Shieldpoint Security", type="vendor", kind="business", join_code="SHLD-2026",
            default_weekly_hours=40, auto_recruit=False,
            description="Security guards for two office sites. Day posts 7 AM–7 PM, a night patrol 6 PM–midnight.",
            created=now_s()
        )
    );
    guard = put(shield, Position(employer=jid(shield), name="Site guard", color="#7ee0b5", created=now_s()));
    patrol = put(shield, Position(employer=jid(shield), name="Night patrol", color="#ffc46b", created=now_s()));
    ids = {"guard": jid(guard), "patrol": jid(patrol)};
    make_account("shield@demo.com", "department", "Rosa Mendes", jid(shield));
    for (name, email, roles, hours, off) in GUARDS {
        st = put(
            h,
            Employee(
                name=name, email=email, kind="worker", status="domestic", weekly_limit=60, desired_hours=0,
                preferences=[], open_swap_days=[d for d in range(7) if d not in off][:2], autopilot=True,
                calendar_source="demo", calendar_synced_at=now_s(),
                demo_events=[{"day": d, "start": 0, "end": 24 * 60, "title": "Day off", "week": ""} for d in off],
                created=now_s()
            )
        );
        make_account(email, "student", name, jid(st));
        for d in off {
            put(st, BusyBlock(day=d, start=0, end=24 * 60, title="Day off", source="calendar"));
        }
        _employ(st, shield, hours, [ids[r] for r in roles]);
    }
    for day in range(7) {
        put(shield, Requirement(employer=jid(shield), day=day, start=7 * 60, end=19 * 60, headcount=1, position=jid(guard)));
        put(shield, Requirement(employer=jid(shield), day=day, start=18 * 60, end=24 * 60, headcount=1, position=jid(patrol)));
    }
    log_event("Coordinator", "Team of 4 guards · autopilot drafts every week for your approval", employer=shield, level="info");
    return shield;
}

# ------------------------------------------------------------------ history (worked weeks)
"""Replay each employee's usual week for the past `weeks` weeks as worked shifts + time entries."""
def _seed_history(depts: list[Employer], weeks: int = 12) {
    rng = random.Random(2026);
    demo_week = DEFAULT_WEEK;
    wk_s = demo_week.isoformat();
    templates: dict[str, list[tuple[str, int, int, int, str]]] = {};
    order: list[str] = [];
    for dept in depts {
        rows = sorted(
            [s for s in [dept --> [?:Shift, week == wk_s]] if s.student],
            key=lambda (s: Shift) -> str { return s.created; }
        );
        for sh in rows {
            if sh.student not in templates {
                templates[sh.student] = [];
                order.append(sh.student);
            }
            templates[sh.student].append((sh.employer, sh.day, sh.start, sh.end, sh.position));
        }
    }
    shield: Employer = [d for d in depts if d.kind == "business"][0];
    roles = {p.name: jid(p) for p in [shield --> [?:Position]]};
    guards: dict[str, Employee] = {};
    for emp in [shield --> [?:Employment]] {
        st = employee_of(emp.student);
        if st is not None {
            guards[st.email] = st;
        }
    }
    # Shieldpoint's usual rota (the demo week itself is left for the autopilot to draft)
    rota: list[tuple[str, list[tuple[int, int, int, str]]]] = [
        ("tom@demo.com", [(d, 7 * 60, 19 * 60, roles["Site guard"]) for d in [0, 1, 2, 3]]),
        ("aisha@demo.com", [(d, 7 * 60, 19 * 60, roles["Site guard"]) for d in [4, 5, 6]] + [(2, 18 * 60, 24 * 60, roles["Night patrol"])]),
        ("diego@demo.com", [(d, 18 * 60, 24 * 60, roles["Night patrol"]) for d in [0, 1, 4, 5, 6]]),
        ("grace@demo.com", [(3, 18 * 60, 24 * 60, roles["Night patrol"])])
    ];
    for (email, rows) in rota {
        st = guards[email];
        sid = jid(st);
        templates[sid] = [(jid(shield), d, s, e, pid) for (d, s, e, pid) in rows];
        if sid not in order {
            order.append(sid);
        }
    }
    by_id: dict[str, Employer] = {jid(d): d for d in depts};
    rates: dict[str, float] = {};
    for d in depts {
        for emp in [d --> [?:Employment]] {
            rates[emp.student + "|" + emp.employer] = emp.pay_rate;
        }
    }
    now = utcnow();
    stamp = now_s();
    for back in range(weeks, 0, -1) {
        wk = demo_week - timedelta(days=7 * back);
        last = back == 1;
        for sid in order {
            st = employee_of(sid);
            if st is None {
                continue;
            }
            for (did, day, start, end, pid) in templates[sid] {
                if not last and rng.random() < 0.08 {
                    continue;  # the odd week off
                }
                dept = by_id[did];
                sh = add_shift(
                    dept,
                    Shift(
                        week=wk.isoformat(), day=day, start=start, end=end, student=sid, state="assigned",
                        status="published", position=pid, source="generated"
                    )
                );
                if to_utc_naive(slot_datetime(wk.isoformat(), day, end, dept.timezone)) > now {
                    continue;  # hasn't happened yet -- the Time Agent reports it when it ends
                }
                s2 = start;
                e2 = end;
                if not last and rng.random() < 0.12 {
                    e2 = min(24 * 60, end + rng.choice([15, 30]));  # stayed a little late -- corrected and approved
                }
                te = TimeEntry(
                    student=sid, employer=did, shift=jid(sh), position=pid,
                    work_date=(wk + timedelta(days=day)).isoformat(), week=wk.isoformat(), start=s2, end=e2,
                    pay_rate=rates.get(sid + "|" + did, 15.0), status="reported" if last else "approved",
                    source="auto", approved_at="" if last else stamp, created=stamp
                );
                put(st, te);
                also(dept, te);
            }
        }
    }
    # One flagged line for Campus Dining to resolve: Sam stayed 30 minutes late last Tuesday.
    sam: Employee | None = None;
    for st in [hub() --> [?:Employee, email == "sam@demo.edu"]] {
        sam = st;
    }
    if sam is not None {
        last_wk = (demo_week - timedelta(days=7)).isoformat();
        tue = (demo_week - timedelta(days=6)).isoformat();
        for te in [sam --> [?:TimeEntry, week == last_wk, work_date == tue]] {
            te.status = "disputed";
            te.proposed_start = te.start;
            te.proposed_end = te.end + 30;
            te.note = "Stayed 30 min to close the register.";
            break;
        }
    }
}

"""A plausible class schedule for a new student who picks the demo calendar."""
def sample_demo_events() -> list[dict[str, any]] {
    out: list[dict[str, any]] = [];
    for (days, s, e, t) in [
        ([0, 2, 4], 9 * 60 + 10, 10 * 60 + 30, "CSE 3241"),
        ([1, 3], 12 * 60 + 45, 14 * 60 + 5, "MATH 2568"),
        ([3], 15 * 60 + 30, 17 * 60 + 20, "PHYS 1250 Lab")
    ] {
        for d in days {
            out.append({"day": d, "start": s, "end": e, "title": t, "week": ""});
        }
    }
    return out;
}

"""Stands in for the employee adding an event in Google Calendar."""
def add_demo_event(st: Employee, day: int, start: int, end: int, title: str, week: str) {
    st.demo_events = (st.demo_events or []) + [{"day": day, "start": start, "end": end, "title": title, "week": week}];
}

"""Wipe every record under the hub (demo reset). Platform logins are kept; Accounts are rebuilt."""
def wipe() {
    h = hub();
    seen: set[str] = set();
    stack: list[any] = list([h -->]);
    doomed: list[any] = [];
    while stack {
        n = stack.pop();
        k = jid(n);
        if k in seen {
            continue;
        }
        seen.add(k);
        doomed.append(n);
        stack = stack + list([n -->]);
    }
    for n in doomed {
        del n;
    }
    h.seeded = False;
}
