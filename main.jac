"""CampusSync -- scheduling, automated time reporting and pay for shift-based teams.

Rules are code. Judgment is AI. Humans just approve.

Server: the coordination graph (server/models.jac), the rules engine (server/rules.jac), the agents
(scheduling, swaps, recruiting, needs, availability, copilot -- `by llm` with deterministic fallbacks),
time reporting, pay, alerts, web push, Google Calendar and the autopilot scheduled task.
Web: every screen is a Jac client component in web/.
"""

import server.api_common;
import server.api_membership;
import server.api_org;
import server.api_time;
import server.api_department;
import server.api_student;
import server.api_autopilot;
import server.web_routes;
import server.autopilot;

# The autopilot is a scheduled task; the server finds schedules on the entry module.
import from server.autopilot { autopilot_cycle, keepalive }


# The web app (every screen is a Jac client component in web/).
import from web.App { CampusSyncApp }

def:pub app -> JsxElement {
    <CampusSyncApp />
}
