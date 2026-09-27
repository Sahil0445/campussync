# Porting CampusSync to Jac / JacHammer

This version is written in Python so it can be built and tested fast. It is also shaped so the move to Jac is mostly mechanical:

- **The frontend doesn't change.** It already calls `POST /user/login` and `POST /walker/<name>`, and reads `{"reports": [result]}`, which is the same contract `jac serve` exposes. Point `VITE_API_BASE` at the Jac server and rebuild.
- **Every model is a node or an edge**, and every API function is a walker with the same name.
- **The rules stay as plain code.** In Jac they become ordinary functions or walker abilities, never `by llm`.

> Syntax below follows the current Jac reference (`node … { has … }`, `walker … { can … with X entry }`, `def … by llm(...)`). Verify the exact APIs for shared roots and access grants (`root.shared`, `grant()`) against the JacHammer docs for your Jac version before relying on them. They are named here as the plan describes them, not as tested code.

---

## 1. Graph: models → nodes and edges

| Python (`backend/app/models.py`) | Jac |
|---|---|
| `Department` | `node Department { has name: str, type: str; }` |
| `Student` | `node Student { has name: str, email: str, status: str, weekly_limit: int, desired_hours: int, preferences: list[str], open_swap_days: list[int], auto_accept_swaps: bool; }` |
| `BusyBlock` | `node Availability { has day: int, start: int, end: int, title: str, source: str; }` — `Student --HAS--> Availability` |
| `Employment` | `edge WorksFor { has hours: int, state: str; }` — `Student +>:WorksFor:+> Department` |
| `StaffingRequirement` | `node StaffingRequirement {…}` — `Department --REQUIRES--> StaffingRequirement` |
| `Shift` | `node Shift { has week: str, day: int, start: int, end: int, state: str, status: str; }` — `Department --HAS--> Shift`, `Student --ASSIGNED_TO--> Shift` |
| `SwapRequest`, `SwapLoop`, `SwapOffer` | nodes; `Student --REQUESTED--> SwapRequest --PART_OF--> SwapLoop` |
| `Notification` | node hanging off each user's root |
| `User` | the built-in `jac serve` user and root, so there's no custom auth code |

```jac
node Student {
    has name: str,
        email: str,
        status: str = "domestic",
        weekly_limit: int = 20;

    def cap() -> int {
        return 20 if self.status == "international" else self.weekly_limit;
    }
}

edge WorksFor {
    has hours: int = 10,
        state: str = "invited";
}

node Shift {
    has week: str, day: int, start: int, end: int,
        state: str = "assigned", status: str = "published";
}
```

The coordination graph lives on a shared root that departments can't read directly. Each department's walker runs with access only to its own subgraph plus the minimal-answer walkers below. **Permissions become the product feature, not plumbing.**

## 2. Rules (code, never AI)

Port `agents/rules.py` (`Ledger`) one to one. The Conflict Agent is literally a walker that starts at a student and follows **every** `WorksFor` edge. That's trivial in a graph and painful in SQL:

```jac
walker ConflictCheck {
    has day: int, start: int, end: int;
    has blocked: bool = False;

    can start_at with Student entry {
        # classes and typed rules
        for a in [here ->:Has:->](?day == self.day) {
            if a.start < self.end and self.start < a.end { self.blocked = True; }
        }
        # shifts in EVERY department
        for s in [here ->:AssignedTo:->](?day == self.day) {
            if s.start < self.end and self.start < s.end { self.blocked = True; }
        }
        # It knows everything; it says almost nothing.
        report {"available": not self.blocked};
    }
}
```

Keep `Ledger.compliance` and `Ledger.violations` as plain `def` functions. The Swap Agent's loop validation calls them on a copy of the week.

## 3. AI agents with byLLM (Gemini)

The Python prompts in `llm.py` callers map to typed `by llm` functions. The model returns structured data, and the rules re-validate everything afterwards, exactly as they do now.

```jac
obj Rule { has days: list[int], start: str, end: str; }

"""Convert a student's note into weekly times they CANNOT work. 0=Mon..6=Sun, 24h HH:MM."""
def parse_availability_note(note: str) -> list[Rule] by llm(model_name="gemini/gemini-3.5-flash");

"""Explain in 2–3 sentences why this circle of trades works. First names only."""
def explain_swap(requester: str, wants: str, moves: list[dict]) -> str by llm(model_name="gemini/gemini-3.5-flash");
```

Keep the fallbacks (`parse_note_fallback`, the greedy scheduler, `_fallback_rationale`) wrapped around each call, so a quota error on stage never breaks the demo.

## 4. Walkers (the API)

Every function in `backend/app/walkers/*.py` becomes a walker with the **same name and the same request/response shape**:

| Walker | Role | Python source |
|---|---|---|
| `register_student`, `register_department` | public | `walkers/common.py` (in Jac: `jac serve` user registration + a profile walker) |
| `whoami`, `get_notifications`, `mark_notifications_read` | any | `walkers/common.py` |
| `get_availability`, `import_calendar`, `parse_availability_note`, `remove_availability_rule`, `update_profile` | student | `walkers/student.py` |
| `get_student_home`, `respond_invite`, `get_open_shifts`, `claim_open_shift` | student | `walkers/student.py` |
| `request_swap`, `get_my_request`, `list_my_requests`, `cancel_request`, `get_offer`, `respond_offer` | student | `walkers/student.py` |
| `get_coverage`, `get_slot`, `get_staffing_needs`, `set_staffing_needs` | department | `walkers/department.py` |
| `get_people`, `search_students`, `invite_student` | department | `walkers/department.py` |
| `check_assignment`, `assign_shift`, `find_someone_else` | department | `walkers/department.py` |
| `generate_schedule`, `get_draft`, `publish_schedule`, `discard_draft`, `post_open_shift` | department | `walkers/department.py` |
| `get_requests`, `get_swap_request`, `approve_swap`, `reject_swap` | department | `walkers/department.py` |

**Privacy is enforced in what walkers `report`, not in the frontend.** Carry over the exact response shapes from section 17 of the plan. Also port `backend/tests/test_demo.py::test_full_demo_in_order_and_no_cse_leak` as your acceptance test: it signs in as Campus Dining, calls every department walker, and fails if "CSE" appears anywhere.

## 5. Suggested order on JacHammer

1. Nodes and edges + a seed walker that builds the demo graph (copy the values from `backend/app/seed.py`).
2. `ConflictCheck` + compliance functions → `check_assignment`, then run Act 1.
3. `generate_schedule` (greedy first, then `by llm` for the judgment step), then run Act 2.
4. Swap search + commit + re-plan, then run Act 3.
5. Point the existing frontend at the Jac server (`VITE_API_BASE=https://<your-jachammer-app>`) and run `npm run build`.

## 6. Autopilot additions (v2)

| Walker / service | Jac shape |
|---|---|
| `get_dashboard`, `get_approvals`, `decide`, `get_agent_feed`, `set_policy`, `run_autopilot`, `generate_needs`, `copilot_command` | department walkers |
| `student_command`, `connect_calendar`, `sync_calendar`, `disconnect_calendar`, `get_open_shifts`, `claim_open_shift`, `list_my_requests` | student walkers |
| `services/autopilot.tick` | a scheduled walker spawned on the shared root every N seconds (or a JacHammer cron) |
| `services/calendar.sync_student` | walker on `Student` that replaces its `Availability` nodes, then spawns `DetectDisruptions` |
| `AgentEvent` | node attached to the department's or student's root. The feed is a walker that reports the newest N |
| `RecruitProposal` | node `Department --PROPOSES--> RecruitProposal --FOR--> Student` |
| Copilot / Needs / Recruiting reasoning | `by llm()` functions with the existing regex fallbacks wrapped around them |
