"""The AI layer: every judgment call is a typed `by llm()` function (Gemini through byLLM).

Rules are code. Judgment is AI. Nothing here decides what is allowed -- every answer is re-checked by
the Ledger -- and every caller has a deterministic fallback, so the product never depends on the
network:
  * no GEMINI_API_KEY          -> built-in heuristics
  * the model is busy / down   -> ModelPool tries the next Gemini model, then heuristics, and AI is
                                  skipped for a short cool-down so screens stay instant
"""

import time;
import logging;
import from jaclang.byllm.lib { Model, ModelPool }
import from server.config {
    GEMINI_API_KEY,
    GEMINI_MODEL,
    GEMINI_FALLBACK_MODELS,
    AI_TIMEOUT_SECONDS
}

glob log = logging.getLogger("campussync.ai");

def _model_names() -> list[str] {
    names: list[str] = [];
    for m in [GEMINI_MODEL] + GEMINI_FALLBACK_MODELS.split(",") {
        m = m.strip();
        if m and m not in names {
            names.append(m);
        }
    }
    return names;
}

glob gemini = ModelPool(
    models=[
        Model(model_name="gemini/" + m, api_key=GEMINI_API_KEY or "unset")
        for m in _model_names()
    ],
    strategy="fallback",
    num_retries=1,
    timeout=AI_TIMEOUT_SECONDS
);

glob _cooldown_until: float = 0.0,
     last_error: str = "",
     last_model: str = "";

def enabled() -> bool {
    return bool(GEMINI_API_KEY);
}

"""True when a model call is worth trying right now."""
def ready() -> bool {
    return enabled() and time.time() >= _cooldown_until;
}

def models() -> list[str] {
    return _model_names() if enabled() else [];
}

def succeeded {
    last_error = "";
    last_model = GEMINI_MODEL;
}

def failed(e: Exception) {
    text = f"{type(e).__name__}: {str(e)}"[-400:];
    last_error = text;
    auth = "401" in text or "403" in text or "API key" in text or "Authentication" in text;
    _cooldown_until = time.time() + (300 if auth else 45);
    log.warning(
        "Gemini unavailable (%s) - using built-in heuristics for a while", text
    );
}

# ------------------------------------------------------------------ Scheduling Agent
obj SlotAsk {
    has slot: str,
        label: str,
        hours: float,
        need: int,
        eligible: list[str];
}

obj PersonAsk {
    has id: str,
        name: str,
        hours_with_you: float,
        can_take_more: float,
        assigned_hours: int,
        weekend_shifts: int;
}

obj SlotPick {
    has slot: str,
        people: list[str];
}

obj PersonNote {
    has id: str,
        note: str;
}

obj WeekPlan {
    has assignments: list[SlotPick],
        notes: list[PersonNote];
}

sem WeekPlan.assignments = "For each open slot id, the ids of the people you pick (never more than the slot's need; only eligible ids).";
sem WeekPlan.notes = "One short reason per person you scheduled or skipped, max 12 words, e.g. 'Fewest hours so far; prefers afternoons'.";

def plan_week(open_slots: list[SlotAsk], people: list[PersonAsk]) -> WeekPlan by gemini(temperature=0.2);
sem plan_week = """You are the Scheduling Agent for an employer. Fill open shift slots with employees.
Hard rules are enforced by separate code, so focus on judgment: spread unpopular slots (weekends,
early mornings, nights) fairly, give hours to people furthest below the hours their employer assigned
them, and avoid giving one person every weekend. Only pick people listed as eligible for a slot,
never exceed a slot's need, and never give anyone more hours than their can_take_more.""";
sem plan_week.open_slots = "Open slots: id, label, length in hours, how many people it still needs, and the ids eligible for it.";
sem plan_week.people = "The team: hours already with this employer, hours they can still take, their assigned weekly hours, weekend shifts so far.";

# ------------------------------------------------------------------ Swap Agent / Explainer
obj MoveInfo {
    has name: str,
        gives: str,
        gets: str;
}

def explain_swap(
    requester: str,
    requester_wants: str,
    moves: list[MoveInfo],
    hours_change: str,
    previous_declines: list[str]
) -> str by gemini(temperature=0.2);
sem explain_swap = """You are the Explainer for a shift-swap agent. Write 2-3 plain sentences a busy
manager can read in five seconds: why this circle of trades works and what each person gives up. Use
first names only. Mention that nobody's hours change if that is true, and that coverage is unchanged.
If a previous option was declined, say briefly how this one avoids that. No bullet points.""";

# ------------------------------------------------------------------ Needs Agent
obj NeedBlock {
    has days: list[int],
        start: str,
        end: str,
        headcount: int,
        role: str | None = None;
}

obj NeedsPlan {
    has needs: list[NeedBlock],
        summary: str;
}

sem NeedBlock.days = "Days this block repeats on: 0=Mon .. 6=Sun.";
sem NeedBlock.start = "24h HH:MM.";
sem NeedBlock.end = "24h HH:MM; use 24:00 for midnight at the end of a day.";
sem NeedBlock.headcount = "People needed at the same time, 1-20.";
sem NeedBlock.role = "The best matching role name from the employer's roles, or null for anyone.";
sem NeedsPlan.summary = "One sentence describing the plan.";

def plan_needs(description: str, roles: list[str]) -> NeedsPlan by gemini(temperature=0.2);
sem plan_needs = """You are the Needs Agent for an employer. From a manager's description, produce
weekly staffing requirements. Keep the shift lengths the manager describes (e.g. a 12-hour guard post
stays one 7:00-19:00 block); if they only give opening hours, split into blocks of 3-5 hours and put
more people at the busy times they mention. If the employer has roles, set role to the best matching
role name for each block, or null for anyone.""";
sem plan_needs.description = "The manager's description of a normal week.";
sem plan_needs.roles = "Roles at this employer (may be empty).";

# ------------------------------------------------------------------ Availability Agent
obj NoteRule {
    has days: list[int],
        start: str,
        end: str;
}

obj NoteRules {
    has rules: list[NoteRule];
}

sem NoteRule.days = "0=Monday ... 6=Sunday.";
sem NoteRule.start = "24h HH:MM; use 00:00 for 'before X' rules.";
sem NoteRule.end = "24h HH:MM; use 24:00 for 'after X' rules.";

def read_note(note: str) -> NoteRules by gemini(temperature=0.2);
sem read_note = """You are the Availability Agent for a campus job scheduler. Convert a student's
free-text note into weekly unavailability rules. Only include times the student says they CANNOT
work. If the note contains no availability constraint, return an empty list.""";
sem read_note.note = "The student's note.";

# ------------------------------------------------------------------ Copilot (manager)
obj DeptIntent {
    has intent: str,
        student: str | None = None,
        day: int | None = None,
        start: str | None = None,
        end: str | None = None,
        hours: float | None = None,
        count: int | None = None;
}

sem DeptIntent.intent = "One of: check (is a person free?), assign (put a person on a shift), find (who can cover a slot), need (change how many people a slot needs), invite (bring a student onto the team), generate (build the schedule), status (how is coverage), help.";
sem DeptIntent.student = "The person's name as written, or null.";
sem DeptIntent.day = "0=Mon..6=Sun, or null.";
sem DeptIntent.start = "24h HH:MM or null.";
sem DeptIntent.end = "24h HH:MM or null.";

def read_manager_command(command: str, people: list[str]) -> DeptIntent by gemini(temperature=0.1);
sem read_manager_command = "You parse an employer's manager command into a structured intent.";
sem read_manager_command.command = "What the manager typed.";
sem read_manager_command.people = "Names of people the manager may mean.";

# ------------------------------------------------------------------ Copilot (employee)
obj Unavail {
    has day: int,
        start: str = "00:00",
        end: str = "24:00",
        recurring: bool = False,
        label: str = "Busy";
}

obj StudentIntent {
    has intent: str,
        unavailable: list[Unavail] = [],
        want_days: list[int] = [],
        give_up_day: int | None = None;
}

sem StudentIntent.intent = "One of: unavailable | swap | hours | status | help.";
sem StudentIntent.unavailable = "Times they can't work (recurring=true only if they say every/always or use a plural like 'Saturdays'); whole day = 00:00-24:00.";
sem StudentIntent.want_days = "Days they'd like instead (0=Mon..6=Sun).";
sem StudentIntent.give_up_day = "The day of a shift they want to give up or swap, or null.";

def read_employee_message(message: str) -> StudentIntent by gemini(temperature=0.1);
sem read_employee_message = "You parse an employee's message to their job scheduler into a structured intent. Days 0=Mon..6=Sun, times 24h HH:MM.";
sem read_employee_message.message = "What the employee typed.";
