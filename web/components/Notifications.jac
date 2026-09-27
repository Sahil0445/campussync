"""Turn phone notifications on/off for this device, and preview every alert."""

import from "lucide-react" { BellOff, BellRing, Send, Share, SquarePlus }
import from web.lib.api { api, errMsg }
import from web.lib.push { disablePush, enablePush, isIOS, pushState }
import from web.components.ui { StatusChip, useToast }

glob:pub PREVIEWS: list[dict[str, str]] = [
    {"kind": "shift_24h", "label": "24 h before a shift"},
    {"kind": "shift_1h", "label": "1 h before a shift"},
    {"kind": "timesheet_am", "label": "Friday 9 AM · approve hours"},
    {"kind": "timesheet_pm", "label": "Friday 6 PM · reminder"}
];

def:pub NotificationSettings(compact: bool = False, employer: bool = False) -> JsxElement {
    has state: str = "";
    has busy: bool = False;
    toast: any = useToast();

    async can with entry {
        state = await pushState();
    }

    async def turnOn() -> None {
        busy = True;
        try {
            s: str = await enablePush();
            state = s;
            if s == "on" {
                toast("Notifications are on for this device.");
            } elif s == "denied" {
                toast("Notifications are blocked. Allow them in your browser's site settings.", False);
            }
        } except Exception as e {
            m: str = errMsg(e);
            toast(m if m else "Couldn't turn on notifications.", False);
        }
        busy = False;
    }

    async def turnOff() -> None {
        busy = True;
        state = await disablePush();
        busy = False;
        toast("Notifications are off for this device.");
    }

    async def sendTest(kind: str) -> None {
        busy = True;
        try {
            r: any = None;
            if kind {
                r = await api("send_test_alert", {"kind": kind});
            } else {
                r = await api("send_test_push");
            }
            if r.pushed == 0 and r.devices == 0 {
                toast("Saved to your notifications. Turn on phone alerts to get it as a push.");
            } elif r.ok == False or r.pushed == 0 or r.sent == 0 {
                toast("The push service didn't accept it. Turn notifications off and on again.", False);
            } else {
                toast("Sent — check your notifications.");
            }
        } except Exception as e {
            toast(errMsg(e), False);
        }
        busy = False;
    }

    def previewClick(kind: str) -> any {
        return lambda (e: MouseEvent) { sendTest(kind); };
    }

    async def recheck() -> None {
        state = await pushState();
    }

    if not state {
        return <div className="ink-3 t-small">Checking this device…</div>;
    }
    <div className="stack g12">
        <div className="row g12">
            <span className="icon-tile">{<BellRing size={18} /> if state == "on" else <BellOff size={18} />}</span>
            <div className="grow stack">
                <span className="w600">Phone alerts</span>
                <span className="ink-2 t-small">{"Approvals, flagged hours and new team members." if employer else "Shift reminders 24 h and 1 h before, and your Friday timesheet check."}</span>
            </div>
            {state == "on" and <StatusChip kind="ok">On</StatusChip>}
        </div>

        {state == "ios-install" and <div className="note neutral" style={{"flexDirection": "column", "gap": 8}}>
            <b style={{"color": "var(--ink)"}}>On iPhone, add CampusSync to your Home Screen first</b>
            <span className="row g8"><Share size={15} />Tap <b>Share</b> in Safari's toolbar</span>
            <span className="row g8"><SquarePlus size={15} />Choose <b>Add to Home Screen</b>, then open CampusSync from there</span>
            <span className="t-small">Apple only allows web app notifications from the Home Screen (iOS 16.4 or later).</span>
        </div>}
        {state == "unsupported" and <div className="note neutral">This browser can't show notifications. Use Chrome on Android or a computer, or Safari from the Home Screen on iPhone.</div>}
        {state == "denied" and <div className="note block">Notifications are blocked for this site. Open your browser's site settings, allow notifications, then come back.</div>}

        <div className="row g8 wrap">
            {state == "off" and <button type="button" className="btn primary" disabled={busy} onClick={lambda (e: MouseEvent) { turnOn(); }}><BellRing size={15} />Turn on alerts</button>}
            {state == "on" and <button type="button" className="btn" disabled={busy} onClick={lambda (e: MouseEvent) { sendTest(""); }}><Send size={15} />Send a test</button>}
            {state == "on" and not compact and <button type="button" className="btn text" disabled={busy} onClick={lambda (e: MouseEvent) { turnOff(); }}>Turn off on this device</button>}
            {state == "denied" and <button type="button" className="btn" disabled={busy} onClick={lambda (e: MouseEvent) { recheck(); }}>I allowed them</button>}
        </div>
        {not compact and not employer and <div className="stack g8 hairline-top" style={{"paddingTop": 12}}>
            <span className="label">Preview an alert on this phone</span>
            <div className="row g8 wrap">
                {for p in PREVIEWS {
                    <button key={p["kind"]} type="button" className="choice" disabled={busy} onClick={previewClick(p["kind"])}>{p["label"]}</button>
                }}
            </div>
            {isIOS() and state != "on" and <span className="helper">Previews also land in the bell at the top.</span>}
        </div>}
    </div>
}
