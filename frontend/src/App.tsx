import { useEffect } from "react";
import { BrowserRouter, Navigate, Route, Routes, useNavigate, useParams } from "react-router-dom";
import { DeptShell, StudentShell } from "./components/shell";
import { Aurora, ToastProvider } from "./components/ui";
import { EmployeeSignup, EmployerSignup, SignIn, SignupChooser } from "./pages/auth";
import { DemoPage } from "./pages/demo";
import { ApprovalsPage, DraftReview, MissionControl, SchedulePage, SettingsPage, SwapApproval, TeamPage } from "./pages/department";
import { TimesheetsPage } from "./pages/employer";
import { Landing } from "./pages/landing";
import { CampusAI, RequestChange, RequestStatus, StudentHome, StudentProfile, StudentRequests, SwapOffer, UpdateAvailability } from "./pages/student";
import { TimePage } from "./pages/time";
import { getSession } from "./lib/api";

/** Home-screen app entry: straight to the right place for whoever is signed in. */
function Start() {
  const nav = useNavigate();
  useEffect(() => {
    const s = getSession();
    nav(!s ? "/signin" : s.role === "department" ? "/d" : "/s", { replace: true });
  }, [nav]);
  return null;
}

function JoinLink() {
  const { code } = useParams();
  return <Navigate to={`/signup/employee?code=${encodeURIComponent(code ?? "")}`} replace />;
}

export default function App() {
  return (
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
          <Route path="/signup/student" element={<Navigate to="/signup/employee" replace />} />
          <Route path="/signup/department" element={<Navigate to="/signup/employer" replace />} />
          <Route path="/join/:code" element={<JoinLink />} />
          <Route path="/demo" element={<DemoPage />} />
          <Route path="/s" element={<StudentShell />}>
            <Route index element={<StudentHome />} />
            <Route path="ai" element={<CampusAI />} />
            <Route path="time" element={<TimePage />} />
            <Route path="requests" element={<StudentRequests />} />
            <Route path="request" element={<RequestStatus />} />
            <Route path="request/new" element={<RequestChange />} />
            <Route path="offer/:id" element={<SwapOffer />} />
            <Route path="availability" element={<UpdateAvailability />} />
            <Route path="activity" element={<Navigate to="/s/requests" replace />} />
            <Route path="profile" element={<StudentProfile />} />
          </Route>
          <Route path="/d" element={<DeptShell />}>
            <Route index element={<MissionControl />} />
            <Route path="approvals" element={<ApprovalsPage />} />
            <Route path="schedule" element={<SchedulePage />} />
            <Route path="timesheets" element={<TimesheetsPage />} />
            <Route path="drafts/:id" element={<DraftReview />} />
            <Route path="requests/:id" element={<SwapApproval />} />
            <Route path="team" element={<TeamPage />} />
            <Route path="agents" element={<Navigate to="/d" replace />} />
            <Route path="settings" element={<SettingsPage />} />
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </ToastProvider>
  );
}
