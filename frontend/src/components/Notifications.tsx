import { useEffect, useState } from "react";
import { BellOff, BellRing, Send, Share, SquarePlus } from "lucide-react";
import { walker } from "../lib/api";
import { disablePush, enablePush, isIOS, pushState, PushState } from "../lib/push";
import { StatusChip, useToast } from "./ui";

const PREVIEWS: { kind: string; label: string }[] = [
  { kind: "shift_24h", label: "24 h before a shift" },
  { kind: "shift_1h", label: "1 h before a shift" },
  { kind: "timesheet_am", label: "Friday 9 AM · approve hours" },
  { kind: "timesheet_pm", label: "Friday 6 PM · reminder" },
];

/** Turn phone notifications on/off for this device, and preview every alert. */
export function NotificationSettings({ compact = false, employer = false }: { compact?: boolean; employer?: boolean }) {
  const [state, setState] = useState<PushState | null>(null);
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  useEffect(() => { pushState().then(setState); }, []);

  const turnOn = async () => {
    setBusy(true);
    try {
      const s = await enablePush();
      setState(s);
      if (s === "on") toast("Notifications are on for this device.");
      else if (s === "denied") toast("Notifications are blocked. Allow them in your browser's site settings.", false);
    } catch (e: any) { toast(e.message || "Couldn't turn on notifications.", false); }
    setBusy(false);
  };
  const turnOff = async () => { setBusy(true); setState(await disablePush()); setBusy(false); toast("Notifications are off for this device."); };
  const test = async (kind?: string) => {
    setBusy(true);
    try {
      const r = kind ? await walker<any>("send_test_alert", { kind }) : await walker<any>("send_test_push");
      if (r.pushed === 0 && r.devices === 0) toast("Saved to your notifications. Turn on phone alerts to get it as a push.");
      else if (r.ok === false || r.pushed === 0 || r.sent === 0) toast("The push service didn't accept it. Turn notifications off and on again.", false);
      else toast("Sent — check your notifications.");
    } catch (e: any) { toast(e.message, false); }
    setBusy(false);
  };

  if (!state) return <div className="ink-3 t-small">Checking this device…</div>;
  return (
    <div className="stack g12">
      <div className="row g12">
        <span className="icon-tile">{state === "on" ? <BellRing size={18} /> : <BellOff size={18} />}</span>
        <div className="grow stack">
          <span className="w600">Phone alerts</span>
          <span className="ink-2 t-small">{employer ? "Approvals, flagged hours and new team members." : "Shift reminders 24 h and 1 h before, and your Friday timesheet check."}</span>
        </div>
        {state === "on" && <StatusChip kind="ok">On</StatusChip>}
      </div>

      {state === "ios-install" && (
        <div className="note neutral" style={{ flexDirection: "column", gap: 8 }}>
          <b style={{ color: "var(--ink)" }}>On iPhone, add CampusSync to your Home Screen first</b>
          <span className="row g8"><Share size={15} />Tap <b>Share</b> in Safari's toolbar</span>
          <span className="row g8"><SquarePlus size={15} />Choose <b>Add to Home Screen</b>, then open CampusSync from there</span>
          <span className="t-small">Apple only allows web app notifications from the Home Screen (iOS 16.4 or later).</span>
        </div>
      )}
      {state === "unsupported" && <div className="note neutral">This browser can't show notifications. Use Chrome on Android or a computer, or Safari from the Home Screen on iPhone.</div>}
      {state === "denied" && <div className="note block">Notifications are blocked for this site. Open your browser's site settings, allow notifications, then come back.</div>}

      <div className="row g8 wrap">
        {state === "off" && <button type="button" className="btn primary" disabled={busy} onClick={turnOn}><BellRing size={15} />Turn on alerts</button>}
        {state === "on" && <button type="button" className="btn" disabled={busy} onClick={() => test()}><Send size={15} />Send a test</button>}
        {state === "on" && !compact && <button type="button" className="btn text" disabled={busy} onClick={turnOff}>Turn off on this device</button>}
        {state === "denied" && <button type="button" className="btn" disabled={busy} onClick={() => pushState().then(setState)}>I allowed them</button>}
      </div>
      {!compact && !employer && (
        <div className="stack g8 hairline-top" style={{ paddingTop: 12 }}>
          <span className="label">Preview an alert on this phone</span>
          <div className="row g8 wrap">{PREVIEWS.map((p) => <button key={p.kind} type="button" className="choice" disabled={busy} onClick={() => test(p.kind)}>{p.label}</button>)}</div>
          {isIOS() && state !== "on" && <span className="helper">Previews also land in the bell at the top.</span>}
        </div>
      )}
    </div>
  );
}
