"""Phone/desktop notifications (Web Push). The server holds the VAPID keys; we just subscribe.

Push states: unsupported | ios-install (iPhone Safari: Add to Home Screen first) | denied | off | on
"""

import from web.lib.api { api, apiError }

glob:pub JS: any = globalThis;

def:pub isIOS() -> bool {
    nav: any = JS.navigator;
    rx: any = new(JS.RegExp, "iPad|iPhone|iPod");
    return rx.test(nav.userAgent) or (nav.platform == "MacIntel" and nav.maxTouchPoints > 1);
}

def:pub isStandalone() -> bool {
    w: any = JS.window;
    mq: bool = False;
    if w.matchMedia {
        mq = w.matchMedia("(display-mode: standalone)").matches;
    }
    return mq or JS.navigator.standalone == True;
}

def _has_sw() -> bool {
    return JS.Reflect.has(JS.navigator, "serviceWorker");
}

async def:pub registerServiceWorker() -> any {
    if not _has_sw() {
        return None;
    }
    try {
        reg: any = await JS.navigator.serviceWorker.register("/sw.js", {"scope": "/"});
        return reg;
    } except Exception {
        return None;
    }
}

def _b64_to_bytes(b64: str) -> any {
    n = (4 - (len(b64) % 4)) % 4;
    padded = b64 + "==="[0:n];
    std: any = padded;
    raw: str = JS.atob(std.replaceAll("-", "+").replaceAll("_", "/"));
    out: any = new(JS.Uint8Array, len(raw));
    r: any = raw;
    for i in range(len(raw)) {
        out[i] = r.charCodeAt(i);
    }
    return out;
}

async def _registration() -> any {
    existing: any = await JS.navigator.serviceWorker.getRegistration("/");
    reg: any = existing;
    if not reg {
        reg = await registerServiceWorker();
    }
    if not reg {
        raise apiError("Couldn't start the notification service on this browser.", 0);
    }
    ready: any = await JS.navigator.serviceWorker.ready;
    return ready;
}

def _supported() -> bool {
    return _has_sw() and JS.Reflect.has(JS.window, "PushManager") and JS.Reflect.has(JS.window, "Notification");
}

async def:pub pushState() -> str {
    if not _supported() {
        return "ios-install" if isIOS() and not isStandalone() else "unsupported";
    }
    if JS.Notification.permission == "denied" {
        return "denied";
    }
    try {
        reg: any = await JS.navigator.serviceWorker.getRegistration("/");
        sub: any = None;
        if reg {
            sub = await reg.pushManager.getSubscription();
        }
        if not sub {
            return "off";
        }
        cfg: any = await api("get_push_config", {"endpoint": sub.endpoint});
        if not cfg.this_device {
            # Signed into a different account on this phone: re-link it to this one.
            await api("save_push_subscription", {"subscription": sub.toJSON(), "user_agent": JS.navigator.userAgent});
        }
        return "on";
    } except Exception {
        return "off";
    }
}

def _same_key(current: any, key: any) -> bool {
    if current.length != key.length {
        return False;
    }
    for i in range(key.length) {
        if current[i] != key[i] {
            return False;
        }
    }
    return True;
}

async def:pub enablePush() -> str {
    if isIOS() and not isStandalone() {
        return "ios-install";
    }
    if not JS.Reflect.has(JS.window, "Notification") or not JS.Reflect.has(JS.window, "PushManager") {
        return "unsupported";
    }
    permission: str = await JS.Notification.requestPermission();
    if permission != "granted" {
        return "denied" if permission == "denied" else "off";
    }
    reg: any = await _registration();
    cfg: any = await api("get_push_config");
    sub: any = await reg.pushManager.getSubscription();
    key: any = _b64_to_bytes(cfg.public_key);
    if sub {
        # Keys rotated on the server? Re-subscribe with the current one.
        current: any = None;
        if sub.options and sub.options.applicationServerKey {
            current = new(JS.Uint8Array, sub.options.applicationServerKey);
        }
        if current and not _same_key(current, key) {
            await sub.unsubscribe();
            sub = None;
        }
    }
    if not sub {
        sub = await reg.pushManager.subscribe({"userVisibleOnly": True, "applicationServerKey": key});
    }
    await api("save_push_subscription", {"subscription": sub.toJSON(), "user_agent": JS.navigator.userAgent});
    return "on";
}

async def:pub disablePush() -> str {
    reg: any = await JS.navigator.serviceWorker.getRegistration("/");
    sub: any = None;
    if reg {
        sub = await reg.pushManager.getSubscription();
    }
    if sub {
        try {
            await api("delete_push_subscription", {"endpoint": sub.endpoint});
        } except Exception {
            sub = sub;
        }
        await sub.unsubscribe();
    }
    return "off";
}

"""Unlink this device on sign-out so the next person on this phone doesn't get the previous user's alerts."""
async def:pub unlinkDeviceOnSignOut() -> None {
    try {
        if not _has_sw() {
            return;
        }
        reg: any = await JS.navigator.serviceWorker.getRegistration("/");
        sub: any = None;
        if reg {
            sub = await reg.pushManager.getSubscription();
        }
        if sub {
            await api("delete_push_subscription", {"endpoint": sub.endpoint});
        }
    } except Exception {
        return;
    }
}
