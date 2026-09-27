"""The coordination graph.

Naming: the code keeps its original campus names so the Jac port stays 1:1.
    Department  = an EMPLOYER (a campus department or any business, e.g. a security firm)
    Student     = an EMPLOYEE (kind "student" on a campus, or kind "worker" at a business)
    role "department" = employer login, role "student" = employee login

Each class maps to a Jac node or edge (see docs/JAC_PORT.md):

    (Student) --WORKS_FOR(Employment)--> (Department) --REQUIRES--> (StaffingRequirement)
        |                                      |
        +--HAS--> (BusyBlock)                  +--HAS--> (Shift)
        +--ASSIGNED_TO--> (Shift)
        +--REQUESTED--> (SwapRequest) --PART_OF--> (SwapLoop) --OFFERS--> (SwapOffer)

Everything lives centrally. Privacy is enforced by what the walkers return, not by what is stored.
"""
from __future__ import annotations

from datetime import datetime

from datetime import date

from sqlalchemy import JSON, Boolean, Date, DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from . import clock
from .db import Base


def utcnow() -> datetime:
    return clock.utcnow()


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(200), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(300))
    role: Mapped[str] = mapped_column(String(20))  # student | department
    name: Mapped[str] = mapped_column(String(120))
    student_id: Mapped[int | None] = mapped_column(ForeignKey("students.id"), nullable=True)
    department_id: Mapped[int | None] = mapped_column(ForeignKey("departments.id"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class University(Base):
    """Groups campus employers. A student can work for several employers inside one university."""

    __tablename__ = "universities"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(160), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Department(Base):
    """An employer (organization). Employees join it with its join code."""

    __tablename__ = "departments"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    type: Mapped[str] = mapped_column(String(20), default="department")  # legacy: department | vendor
    kind: Mapped[str] = mapped_column(String(20), default="business")  # campus | business
    university_id: Mapped[int | None] = mapped_column(ForeignKey("universities.id", ondelete="SET NULL"), nullable=True, index=True)
    join_code: Mapped[str] = mapped_column(String(16), unique=True, index=True)
    timezone: Mapped[str] = mapped_column(String(60), default="America/New_York")
    default_pay_rate: Mapped[float] = mapped_column(Float, default=15.0)
    default_weekly_hours: Mapped[int] = mapped_column(Integer, default=20)
    state_tax_pct: Mapped[float] = mapped_column(Float, default=4.25)
    description: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    # Autopilot policy. Humans stay in the loop only for approvals.
    auto_generate: Mapped[bool] = mapped_column(Boolean, default=True)  # draft every week automatically
    auto_recruit: Mapped[bool] = mapped_column(Boolean, default=True)  # propose students for gaps
    auto_approve_swaps: Mapped[bool] = mapped_column(Boolean, default=False)  # low-risk swaps skip the manager
    requirements: Mapped[list["StaffingRequirement"]] = relationship(back_populates="department", cascade="all, delete-orphan")


class Position(Base):
    """A role inside an employer (Cashier, Line cook, Night patrol…). Shifts and needs can require one."""

    __tablename__ = "positions"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    color: Mapped[str] = mapped_column(String(9), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Student(Base):
    __tablename__ = "students"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    email: Mapped[str] = mapped_column(String(200), unique=True, index=True)
    university_id: Mapped[str] = mapped_column(String(40), default="")  # student ID number (optional)
    kind: Mapped[str] = mapped_column(String(20), default="student")  # student (campus, many employers) | worker (one employer)
    school_id: Mapped[int | None] = mapped_column(ForeignKey("universities.id", ondelete="SET NULL"), nullable=True, index=True)
    status: Mapped[str] = mapped_column(String(20), default="domestic")  # domestic | international
    weekly_limit: Mapped[int] = mapped_column(Integer, default=20)
    desired_hours: Mapped[int] = mapped_column(Integer, default=12)
    preferences: Mapped[list] = mapped_column(JSON, default=list)  # Mornings, Afternoons, Evenings, Weekends
    open_swap_days: Mapped[list] = mapped_column(JSON, default=list)  # days (0-6) the student is open to swapping into
    # Autopilot: accept swaps into open days and job invites within desired hours without asking.
    autopilot: Mapped[bool] = mapped_column(Boolean, default=True)
    note: Mapped[str] = mapped_column(Text, default="")
    # Calendar connection: "" | google | ics_url | upload | demo
    calendar_source: Mapped[str] = mapped_column(String(20), default="")
    calendar_url: Mapped[str] = mapped_column(Text, default="")
    google_refresh_token: Mapped[str] = mapped_column(Text, default="")
    google_email: Mapped[str] = mapped_column(String(200), default="")
    google_calendar_id: Mapped[str] = mapped_column(Text, default="")  # the "CampusSync shifts" calendar we write to
    shifts_signature: Mapped[str] = mapped_column(String(64), default="")  # what we last wrote to that calendar
    calendar_synced_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    calendar_error: Mapped[str] = mapped_column(Text, default="")
    demo_events: Mapped[list] = mapped_column(JSON, default=list)  # demo calendar feed (stands in for Google)

    @property
    def first_name(self) -> str:
        return self.name.split(" ")[0]

    @property
    def is_international(self) -> bool:
        return self.kind == "student" and self.status == "international"

    @property
    def cap(self) -> int:
        from .config import INTERNATIONAL_WEEKLY_CAP

        if self.is_international:
            return min(self.weekly_limit or INTERNATIONAL_WEEKLY_CAP, INTERNATIONAL_WEEKLY_CAP)
        return self.weekly_limit

    @property
    def daily_max(self) -> int:
        from .config import MAX_DAILY_HOURS, MAX_DAILY_HOURS_WORKER

        return MAX_DAILY_HOURS if self.kind == "student" else MAX_DAILY_HOURS_WORKER


class BusyBlock(Base):
    """Recurring weekly unavailability: classes from .ics, or rules from the Availability Agent."""

    __tablename__ = "busy_blocks"
    id: Mapped[int] = mapped_column(primary_key=True)
    student_id: Mapped[int] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"), index=True)
    day: Mapped[int] = mapped_column(Integer)
    start: Mapped[int] = mapped_column(Integer)
    end: Mapped[int] = mapped_column(Integer)
    title: Mapped[str] = mapped_column(String(120), default="Busy")
    source: Mapped[str] = mapped_column(String(20), default="calendar")  # calendar | note
    week: Mapped[str | None] = mapped_column(String(10), nullable=True)  # None = every week


class Employment(Base):
    """WORKS_FOR edge between Student and Department."""

    __tablename__ = "employments"
    id: Mapped[int] = mapped_column(primary_key=True)
    student_id: Mapped[int] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"), index=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    hours: Mapped[int] = mapped_column(Integer, default=10)  # weekly hours the employer may schedule
    state: Mapped[str] = mapped_column(String(20), default="invited")  # invited | active | declined | left
    positions: Mapped[list] = mapped_column(JSON, default=list)  # Position ids this employee can work
    pay_rate: Mapped[float] = mapped_column(Float, default=15.0)  # USD per hour
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class StaffingRequirement(Base):
    __tablename__ = "staffing_requirements"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    day: Mapped[int] = mapped_column(Integer)
    start: Mapped[int] = mapped_column(Integer)
    end: Mapped[int] = mapped_column(Integer)
    headcount: Mapped[int] = mapped_column(Integer, default=1)
    position_id: Mapped[int | None] = mapped_column(ForeignKey("positions.id", ondelete="SET NULL"), nullable=True)
    department: Mapped[Department] = relationship(back_populates="requirements")


class ScheduleDraft(Base):
    __tablename__ = "schedule_drafts"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    week: Mapped[str] = mapped_column(String(10))
    state: Mapped[str] = mapped_column(String(20), default="draft")  # draft | published | discarded
    origin: Mapped[str] = mapped_column(String(20), default="autopilot")  # autopilot | manual
    trace: Mapped[list] = mapped_column(JSON, default=list)
    summary: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Shift(Base):
    __tablename__ = "shifts"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    week: Mapped[str] = mapped_column(String(10), index=True)
    day: Mapped[int] = mapped_column(Integer)
    start: Mapped[int] = mapped_column(Integer)
    end: Mapped[int] = mapped_column(Integer)
    student_id: Mapped[int | None] = mapped_column(ForeignKey("students.id", ondelete="SET NULL"), nullable=True, index=True)
    state: Mapped[str] = mapped_column(String(20), default="assigned")  # open | assigned | pending_swap
    status: Mapped[str] = mapped_column(String(20), default="published")  # draft | published
    draft_id: Mapped[int | None] = mapped_column(ForeignKey("schedule_drafts.id", ondelete="CASCADE"), nullable=True)
    reason: Mapped[str] = mapped_column(Text, default="")
    source: Mapped[str] = mapped_column(String(20), default="generated")  # generated | swap | recruit | open | manual
    position_id: Mapped[int | None] = mapped_column(ForeignKey("positions.id", ondelete="SET NULL"), nullable=True)

    @property
    def hours(self) -> float:
        return (self.end - self.start) / 60


class SwapRequest(Base):
    __tablename__ = "swap_requests"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    requester_id: Mapped[int] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"))
    shift_id: Mapped[int] = mapped_column(ForeignKey("shifts.id", ondelete="CASCADE"))
    want_kind: Mapped[str] = mapped_column(String(20), default="days")  # days | any | give_up
    want_days: Mapped[list] = mapped_column(JSON, default=list)
    reason: Mapped[str] = mapped_column(Text, default="")
    origin: Mapped[str] = mapped_column(String(20), default="student")  # student | calendar | copilot
    # searching | awaiting_manager | offered | completed | rejected | no_option | cancelled
    state: Mapped[str] = mapped_column(String(20), default="searching")
    excluded_student_ids: Mapped[list] = mapped_column(JSON, default=list)
    feedback: Mapped[list] = mapped_column(JSON, default=list)
    trace: Mapped[list] = mapped_column(JSON, default=list)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class SwapLoop(Base):
    __tablename__ = "swap_loops"
    id: Mapped[int] = mapped_column(primary_key=True)
    request_id: Mapped[int] = mapped_column(ForeignKey("swap_requests.id", ondelete="CASCADE"), index=True)
    # [{"student_id", "gives_shift_id", "gets_shift_id"|None}]
    moves: Mapped[list] = mapped_column(JSON, default=list)
    size: Mapped[int] = mapped_column(Integer)
    kind: Mapped[str] = mapped_column(String(20), default="loop")  # direct | loop | handoff
    score: Mapped[float] = mapped_column(Float, default=0)
    rationale: Mapped[str] = mapped_column(Text, default="")
    alternatives: Mapped[list] = mapped_column(JSON, default=list)
    trace: Mapped[list] = mapped_column(JSON, default=list)
    # proposed | approved | declined | committed | rejected | invalidated
    state: Mapped[str] = mapped_column(String(20), default="proposed")
    declined_by: Mapped[int | None] = mapped_column(Integer, nullable=True)
    decline_reason: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class SwapOffer(Base):
    __tablename__ = "swap_offers"
    id: Mapped[int] = mapped_column(primary_key=True)
    loop_id: Mapped[int] = mapped_column(ForeignKey("swap_loops.id", ondelete="CASCADE"), index=True)
    student_id: Mapped[int] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"), index=True)
    state: Mapped[str] = mapped_column(String(20), default="waiting")  # waiting | accepted | declined | expired | cancelled
    auto: Mapped[str] = mapped_column(String(20), default="")  # "" | carried | auto_accept | requester
    reason_chip: Mapped[str] = mapped_column(String(60), default="")
    reason_text: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    responded_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime)


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[int] = mapped_column(primary_key=True)
    student_id: Mapped[int | None] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"), nullable=True, index=True)
    department_id: Mapped[int | None] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), nullable=True, index=True)
    text: Mapped[str] = mapped_column(Text)
    title: Mapped[str] = mapped_column(String(120), default="")
    link: Mapped[str] = mapped_column(String(200), default="")
    kind: Mapped[str] = mapped_column(String(30), default="general")  # general | shift_24h | shift_1h | timesheet_am | timesheet_pm | ...
    dedupe_key: Mapped[str | None] = mapped_column(String(120), unique=True, nullable=True)  # an alert is sent once
    push: Mapped[bool] = mapped_column(Boolean, default=False)  # also deliver as a phone push notification
    pushed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    read: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class TimeEntry(Base):
    """Automated time reporting: one row per worked shift, created when the shift ends.

    reported  -> the employee checks it (Friday) -> approved
              -> the employee proposes a correction -> disputed -> employer accepts/keeps -> approved | void
    """

    __tablename__ = "time_entries"
    id: Mapped[int] = mapped_column(primary_key=True)
    student_id: Mapped[int] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"), index=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    shift_id: Mapped[int | None] = mapped_column(ForeignKey("shifts.id", ondelete="SET NULL"), nullable=True, unique=True)
    position_id: Mapped[int | None] = mapped_column(Integer, nullable=True)
    work_date: Mapped[date] = mapped_column(Date, index=True)
    week: Mapped[str] = mapped_column(String(10), index=True)
    start: Mapped[int] = mapped_column(Integer)
    end: Mapped[int] = mapped_column(Integer)
    break_minutes: Mapped[int] = mapped_column(Integer, default=0)
    pay_rate: Mapped[float] = mapped_column(Float, default=15.0)
    status: Mapped[str] = mapped_column(String(20), default="reported")  # reported | approved | disputed | void
    source: Mapped[str] = mapped_column(String(20), default="auto")  # auto | manual
    proposed_start: Mapped[int | None] = mapped_column(Integer, nullable=True)
    proposed_end: Mapped[int | None] = mapped_column(Integer, nullable=True)
    proposed_absent: Mapped[bool] = mapped_column(Boolean, default=False)
    note: Mapped[str] = mapped_column(Text, default="")  # employee's note on a correction
    employer_note: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    @property
    def hours(self) -> float:
        if self.status == "void":
            return 0.0
        return max(0, self.end - self.start - (self.break_minutes or 0)) / 60


class PushSubscription(Base):
    """A browser/phone that asked for push notifications (Web Push, VAPID)."""

    __tablename__ = "push_subscriptions"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    endpoint: Mapped[str] = mapped_column(Text)
    endpoint_hash: Mapped[str] = mapped_column(String(64), unique=True)
    p256dh: Mapped[str] = mapped_column(String(200))
    auth: Mapped[str] = mapped_column(String(100))
    user_agent: Mapped[str] = mapped_column(String(300), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_ok_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    failures: Mapped[int] = mapped_column(Integer, default=0)


class CalendarEventLink(Base):
    """A shift we wrote into the employee's Google Calendar (so we can update or remove it)."""

    __tablename__ = "calendar_event_links"
    id: Mapped[int] = mapped_column(primary_key=True)
    student_id: Mapped[int] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"), index=True)
    shift_id: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)
    event_id: Mapped[str] = mapped_column(String(200))
    signature: Mapped[str] = mapped_column(String(200), default="")  # what the event currently says


class ProbeLog(Base):
    __tablename__ = "probe_log"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int] = mapped_column(Integer, index=True)
    student_id: Mapped[int] = mapped_column(Integer, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class RecruitProposal(Base):
    """Recruiting Agent: a student from the campus pool who can cover this department's gaps."""

    __tablename__ = "recruit_proposals"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int] = mapped_column(ForeignKey("departments.id", ondelete="CASCADE"), index=True)
    student_id: Mapped[int] = mapped_column(ForeignKey("students.id", ondelete="CASCADE"), index=True)
    week: Mapped[str] = mapped_column(String(10))
    hours: Mapped[int] = mapped_column(Integer, default=8)
    covers: Mapped[list] = mapped_column(JSON, default=list)  # [{day, start, end}]
    reason: Mapped[str] = mapped_column(Text, default="")
    # proposed | invited | filled | rejected | declined
    state: Mapped[str] = mapped_column(String(20), default="proposed")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class AgentEvent(Base):
    """The live agent feed. Department events never mention another department."""

    __tablename__ = "agent_events"
    id: Mapped[int] = mapped_column(primary_key=True)
    department_id: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)
    student_id: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)
    agent: Mapped[str] = mapped_column(String(40))
    kind: Mapped[str] = mapped_column(String(10), default="agent")  # agent | rules | human
    text: Mapped[str] = mapped_column(Text)
    level: Mapped[str] = mapped_column(String(10), default="info")  # info | action | alert | done
    link: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Meta(Base):
    __tablename__ = "meta"
    key: Mapped[str] = mapped_column(String(40), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="")
