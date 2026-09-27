"""CampusSync web app: routes, toasts and the service worker (phone alerts)."""

import "./styles.css";
import from react { useEffect }
import from "react-router-dom" { BrowserRouter, Navigate, Route, Routes, useNavigate, useParams }
import from web.components.shell { DeptShell, StudentShell }
import from web.components.ui { Aurora, ToastProvider }
import from web.pages.auth { EmployeeSignup, EmployerSignup, SignIn, SignupChooser }
import from web.pages.demo { DemoPage }
import from web.pages.department { ApprovalsPage, DraftReview, MissionControl, SchedulePage, SettingsPage, SwapApproval, TeamPage }
import from web.pages.employer { TimesheetsPage }
import from web.pages.landing { Landing }
import from web.pages.student { CampusAI, RequestChange, RequestStatus, StudentHome, StudentProfile, StudentRequests, SwapOffer, UpdateAvailability }
import from web.pages.time { TimePage }
import from web.lib.api { getSession }
import from web.lib.push { registerServiceWorker }

glob:pub JS: any = globalThis;

"""Home-screen app entry: straight to the right place for whoever is signed in."""
def:pub Start() -> JsxElement {
    nav: any = useNavigate();
    useEffect(
        lambda -> any {
            s: any = getSession();
            nav("/signin" if not s else ("/d" if s.role == "department" else "/s"), {"replace": True});
            return JS.undefined;
        },
        [nav]
    );
    <></>
}

def:pub JoinLink() -> JsxElement {
    p: any = useParams();
    code: str = p["code"] or "";
    <Navigate to={"/signup/employee?code=" + JS.encodeURIComponent(code)} replace={True} />
}

def:pub CampusSyncApp() -> JsxElement {
    can with entry {
        registerServiceWorker();
    }
    <ToastProvider>
        <Aurora />
        <BrowserRouter>
            <Routes>
                <Route path="/" element={<Landing />} />
                <Route path="/start" element={<Start />} />
                <Route path="/signin" element={<SignIn />} />
                <Route path="/signup" element={<SignupChooser />} />
                <Route path="/signup/employee" element={<EmployeeSignup />} />
                <Route path="/signup/employer" element={<EmployerSignup />} />
                <Route path="/signup/student" element={<Navigate to="/signup/employee" replace={True} />} />
                <Route path="/signup/department" element={<Navigate to="/signup/employer" replace={True} />} />
                <Route path="/join/:code" element={<JoinLink />} />
                <Route path="/demo" element={<DemoPage />} />
                <Route path="/s" element={<StudentShell />}>
                    <Route index={True} element={<StudentHome />} />
                    <Route path="ai" element={<CampusAI />} />
                    <Route path="time" element={<TimePage />} />
                    <Route path="requests" element={<StudentRequests />} />
                    <Route path="request" element={<RequestStatus />} />
                    <Route path="request/new" element={<RequestChange />} />
                    <Route path="offer/:id" element={<SwapOffer />} />
                    <Route path="availability" element={<UpdateAvailability />} />
                    <Route path="activity" element={<Navigate to="/s/requests" replace={True} />} />
                    <Route path="profile" element={<StudentProfile />} />
                </Route>
                <Route path="/d" element={<DeptShell />}>
                    <Route index={True} element={<MissionControl />} />
                    <Route path="approvals" element={<ApprovalsPage />} />
                    <Route path="schedule" element={<SchedulePage />} />
                    <Route path="timesheets" element={<TimesheetsPage />} />
                    <Route path="drafts/:id" element={<DraftReview />} />
                    <Route path="requests/:id" element={<SwapApproval />} />
                    <Route path="team" element={<TeamPage />} />
                    <Route path="agents" element={<Navigate to="/d" replace={True} />} />
                    <Route path="settings" element={<SettingsPage />} />
                </Route>
                <Route path="*" element={<Navigate to="/" replace={True} />} />
            </Routes>
        </BrowserRouter>
    </ToastProvider>
}
