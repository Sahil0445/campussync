"""The coordination graph.

    (Hub on root.shared)
       ├──> University
       ├──> Employer ──> Position · Requirement · Draft · Shift · SwapRequest ──> SwapLoop ──> SwapOffer
       │        │         RecruitProposal · Probe · Employment · TimeEntry · Notification · AgentEvent
       ├──> Employee ──> BusyBlock · Employment · Shift (held) · TimeEntry · Notification · AgentEvent
       │                 SwapRequest (asked) · SwapOffer (offered)
       ├──> Account ──> PushSub
       └──> Meta

Naming follows the product: an Employer is a campus department or any business; an Employee is a
student (campus, many employers at one university) or a worker (one employer). Everything lives on
one shared graph; privacy is enforced by what the endpoints return, never by what is stored.
Records reference each other by jid (string ids), which is also what the web client sees.
"""

import from server.clock { now_s }
import from server.config {
    INTERNATIONAL_WEEKLY_CAP,
    MAX_DAILY_HOURS,
    MAX_DAILY_HOURS_WORKER
}

# ------------------------------------------------------------------ nodes
node Hub {
    has name: str = "campussync",
        seeded: bool = False,
        schema: str = "";
}

node Meta {
    has key: str = "",
        value: str = "";
}

node Account {
    has email: str = "",
        role: str = "",
        name: str = "",
        root_id: str = "",
        ref: str = "",
        created: str = "";
}

node University {
    has name: str = "",
        created: str = "";
}

"""An employer (organization). Employees join it with its join code."""
node Employer {
    has name: str = "",
        type: str = "department",
        kind: str = "business",
        university: str = "",
        join_code: str = "",
        timezone: str = "America/New_York",
        default_pay_rate: float = 15.0,
        default_weekly_hours: int = 20,
        state_tax_pct: float = 4.25,
        description: str = "",
        created: str = "",
        auto_generate: bool = True,
        auto_recruit: bool = True,
        auto_approve_swaps: bool = False;
}

"""A role inside an employer (Cashier, Line cook, Night patrol...)."""
node Position {
    has employer: str = "",
        name: str = "",
        color: str = "",
        created: str = "";
}

"""An employee: kind "student" (campus) or "worker" (one employer at a time)."""
node Employee {
    has name: str = "",
        email: str = "",
        student_number: str = "",
        kind: str = "student",
        school: str = "",
        status: str = "domestic",
        weekly_limit: int = 20,
        desired_hours: int = 12,
        preferences: list[str] = [],
        open_swap_days: list[int] = [],
        autopilot: bool = True,
        note: str = "",
        calendar_source: str = "",
        calendar_url: str = "",
        google_refresh_token: str = "",
        google_email: str = "",
        google_calendar_id: str = "",
        shifts_signature: str = "",
        calendar_synced_at: str = "",
        calendar_error: str = "",
        demo_events: list[dict[str, any]] = [],
        created: str = "";

    def first_name -> str {
        return self.name.split(" ")[0];
    }

    def is_international -> bool {
        return self.kind == "student" and self.status == "international";
    }

    def cap -> int {
        if self.is_international() {
            return min(self.weekly_limit or INTERNATIONAL_WEEKLY_CAP, INTERNATIONAL_WEEKLY_CAP);
        }
        return self.weekly_limit;
    }

    def daily_max -> int {
        return MAX_DAILY_HOURS if self.kind == "student" else MAX_DAILY_HOURS_WORKER;
    }
}

"""Recurring weekly unavailability (week == "" means every week)."""
node BusyBlock {
    has day: int = 0,
        start: int = 0,
        end: int = 0,
        title: str = "Busy",
        source: str = "calendar",
        week: str = "";
}

"""WORKS_FOR: an employee's job with an employer."""
node Employment {
    has student: str = "",
        employer: str = "",
        hours: int = 10,
        state: str = "invited",
        positions: list[str] = [],
        pay_rate: float = 15.0,
        created: str = "";
}

node Requirement {
    has employer: str = "",
        day: int = 0,
        start: int = 0,
        end: int = 0,
        headcount: int = 1,
        position: str = "";
}

node Draft {
    has employer: str = "",
        week: str = "",
        state: str = "draft",
        origin: str = "autopilot",
        trace: list[dict[str, any]] = [],
        summary: dict[str, any] = {},
        created: str = "";
}

node Shift {
    has employer: str = "",
        week: str = "",
        day: int = 0,
        start: int = 0,
        end: int = 0,
        student: str = "",
        state: str = "assigned",
        status: str = "published",
        draft: str = "",
        reason: str = "",
        source: str = "generated",
        position: str = "",
        created: str = "";

    def hours -> float {
        return (self.end - self.start) / 60;
    }
}

node SwapRequest {
    has employer: str = "",
        requester: str = "",
        shift: str = "",
        want_kind: str = "days",
        want_days: list[int] = [],
        reason: str = "",
        origin: str = "student",
        state: str = "searching",
        excluded: list[str] = [],
        feedback: list[dict[str, any]] = [],
        trace: list[dict[str, any]] = [],
        created: str = "";
}

node SwapLoop {
    has request: str = "",
        moves: list[dict[str, any]] = [],
        size: int = 2,
        kind: str = "loop",
        score: float = 0.0,
        rationale: str = "",
        alternatives: list[dict[str, any]] = [],
        trace: list[dict[str, any]] = [],
        state: str = "proposed",
        declined_by: str = "",
        decline_reason: str = "",
        created: str = "";
}

node SwapOffer {
    has loop: str = "",
        student: str = "",
        state: str = "waiting",
        auto: str = "",
        reason_chip: str = "",
        reason_text: str = "",
        created: str = "",
        responded_at: str = "",
        expires_at: str = "";
}

node Notification {
    has student: str = "",
        employer: str = "",
        text: str = "",
        title: str = "",
        link: str = "",
        kind: str = "general",
        dedupe_key: str = "",
        push: bool = False,
        pushed_at: str = "",
        read: bool = False,
        created: str = "";
}

"""Automated time reporting: one per worked shift, created when the shift ends."""
node TimeEntry {
    has student: str = "",
        employer: str = "",
        shift: str = "",
        position: str = "",
        work_date: str = "",
        week: str = "",
        start: int = 0,
        end: int = 0,
        break_minutes: int = 0,
        pay_rate: float = 15.0,
        status: str = "reported",
        source: str = "auto",
        proposed_start: int | None = None,
        proposed_end: int | None = None,
        proposed_absent: bool = False,
        note: str = "",
        employer_note: str = "",
        created: str = "",
        approved_at: str = "";

    def hours -> float {
        if self.status == "void" {
            return 0.0;
        }
        return max(0, self.end - self.start - (self.break_minutes or 0)) / 60;
    }
}

"""A browser/phone that asked for push notifications (Web Push, VAPID)."""
node PushSub {
    has account: str = "",
        endpoint: str = "",
        endpoint_hash: str = "",
        p256dh: str = "",
        auth: str = "",
        user_agent: str = "",
        created: str = "",
        last_ok_at: str = "",
        failures: int = 0;
}

node Probe {
    has employer: str = "",
        student: str = "",
        created: str = "";
}

"""Recruiting Agent: a student from the campus pool who can cover this employer's gaps."""
node RecruitProposal {
    has employer: str = "",
        student: str = "",
        week: str = "",
        hours: int = 8,
        covers: list[dict[str, any]] = [],
        reason: str = "",
        state: str = "proposed",
        created: str = "";
}

"""The live agent feed. Employer events never mention another employer."""
node AgentEvent {
    has employer: str = "",
        student: str = "",
        agent: str = "",
        kind: str = "agent",
        text: str = "",
        level: str = "info",
        link: str = "",
        created: str = "";
}

# ------------------------------------------------------------------ edges (semantic links)
edge HubLink: Hub --> any {}
edge Owns: any --> any {}

# ------------------------------------------------------------------ graph helpers
glob _hub_id: str = "";

"""The app's hub node on the shared graph (created once)."""
def hub() -> Hub {
    if _hub_id {
        h = jobj(_hub_id);
        if isinstance(h, Hub) {
            return h;
        }
    }
    found = [root.shared --> [?:Hub]];
    if found {
        _hub_id = jid(found[0]);
        return found[0];
    }
    h = Hub();
    root.shared ++> h;
    grant(h, level=AccessLevel.WRITE);
    _hub_id = jid(h);
    return h;
}

"""Attach a new record under a parent and open it to the app's users."""
def put(parent: any, child: any) -> any {
    parent ++> child;
    grant(child, level=AccessLevel.WRITE);
    return child;
}

"""Link an existing record to a second parent (for traversal from both sides)."""
def also(parent: any, child: any) {
    parent ++> child;
}

def unlink(parent: any, child: any) {
    parent del --> child;
}

def employer_of(id: str) -> Employer | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, Employer) else None;
}

def employee_of(id: str) -> Employee | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, Employee) else None;
}

def university_of(id: str) -> University | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, University) else None;
}

def position_of(id: str) -> Position | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, Position) else None;
}

def shift_of(id: str) -> Shift | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, Shift) else None;
}

def employment_of(id: str) -> Employment | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, Employment) else None;
}

def draft_of(id: str) -> Draft | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, Draft) else None;
}

def request_of(id: str) -> SwapRequest | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, SwapRequest) else None;
}

def loop_of(id: str) -> SwapLoop | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, SwapLoop) else None;
}

def offer_of(id: str) -> SwapOffer | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, SwapOffer) else None;
}

def entry_of(id: str) -> TimeEntry | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, TimeEntry) else None;
}

def proposal_of(id: str) -> RecruitProposal | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, RecruitProposal) else None;
}

def account_of(id: str) -> Account | None {
    if not id {
        return None;
    }
    n = jobj(id);
    return n if isinstance(n, Account) else None;
}

# ------------------------------------------------------------------ common queries
def employers() -> list[Employer] {
    return [hub() --> [?:Employer]];
}

def employees() -> list[Employee] {
    return [hub() --> [?:Employee]];
}

def universities() -> list[University] {
    return [hub() --> [?:University]];
}

def positions_of(e: Employer) -> list[Position] {
    return [e --> [?:Position]];
}

def requirements_of(e: Employer) -> list[Requirement] {
    return [e --> [?:Requirement]];
}

def employments_of_employer(e: Employer) -> list[Employment] {
    return [e --> [?:Employment]];
}

def employments_of_student(s: Employee) -> list[Employment] {
    return [s --> [?:Employment]];
}

def employment_between(s: Employee, e: Employer) -> Employment | None {
    eid = jid(e);
    rows = [s --> [?:Employment, employer == eid]];
    return rows[0] if rows else None;
}

"""Shifts an employee holds for a week (every employer)."""
def held_shifts(s: Employee, wk: str, want: str = "published") -> list[Shift] {
    return [_q for _q in [s --> [?:Shift, week == wk]] if _q.status == want];
}

def employer_shifts(e: Employer, wk: str) -> list[Shift] {
    return [e --> [?:Shift, week == wk]];
}

"""Store a new shift under its employer, linked from its holder."""
def add_shift(e: Employer, sh: Shift) -> Shift {
    sh.employer = jid(e);
    if not sh.created {
        sh.created = now_s();
    }
    put(e, sh);
    st = employee_of(sh.student);
    if st is not None {
        also(st, sh);
    }
    return sh;
}

"""Move a shift to a new holder (or to nobody), keeping the employee->shift links in step."""
def set_holder(sh: Shift, sid: str) {
    if sh.student == sid {
        return;
    }
    old = employee_of(sh.student);
    if old is not None {
        unlink(old, sh);
    }
    sh.student = sid;
    new = employee_of(sid);
    if new is not None {
        also(new, sh);
    }
}

def meta_get(k: str) -> str {
    rows = [hub() --> [?:Meta, key == k]];
    return rows[0].value if rows else "";
}

def meta_set(k: str, v: str) {
    rows = [hub() --> [?:Meta, key == k]];
    if rows {
        rows[0].value = v;
    } else {
        put(hub(), Meta(key=k, value=v));
    }
}
