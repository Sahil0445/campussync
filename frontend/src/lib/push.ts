// Phone/desktop notifications (Web Push). The server holds the VAPID keys; we just subscribe.
import { walker } from "./api";

export type PushState =
  | "unsupported"      // browser has no Push API
  | "ios-install"      // iPhone/iPad Safari: must Add to Home Screen first (Apple rule)
  | "denied"           // user blocked notifications in browser settings
  | "off"              // supported, not subscribed on this device
  | "on";              // subscribed on this device

export const isIOS = () => /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
export const isStandalone = () => window.matchMedia?.("(display-mode: standalone)").matches || (navigator as any).standalone === true;

export async function registerServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (!("serviceWorker" in navigator)) return null;
  try { return await navigator.serviceWorker.register("/sw.js", { scope: "/" }); } catch { return null; }
}

function urlB64ToUint8Array(b64: string) {
  const pad = "=".repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

async function registration() {
  const existing = await navigator.serviceWorker.getRegistration("/");
  const reg = existing ?? (await registerServiceWorker());
  if (!reg) throw new Error("Couldn't start the notification service on this browser.");
  return navigator.serviceWorker.ready;
}

export async function pushState(): Promise<PushState> {
  const supported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  if (!supported) return isIOS() && !isStandalone() ? "ios-install" : "unsupported";
  if (Notification.permission === "denied") return "denied";
  try {
    const reg = await navigator.serviceWorker.getRegistration("/");
    const sub = reg ? await reg.pushManager.getSubscription() : null;
    if (!sub) return "off";
    const cfg = await walker<{ this_device: boolean }>("get_push_config", { endpoint: sub.endpoint });
    if (!cfg.this_device) {  // signed into a different account on this phone — re-link it to this one
      await walker("save_push_subscription", { subscription: sub.toJSON(), user_agent: navigator.userAgent });
    }
    return "on";
  } catch { return "off"; }
}

export async function enablePush(): Promise<PushState> {
  if (isIOS() && !isStandalone()) return "ios-install";
  if (!("Notification" in window) || !("PushManager" in window)) return "unsupported";
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return permission === "denied" ? "denied" : "off";
  const reg = await registration();
  const { public_key } = await walker<{ public_key: string }>("get_push_config");
  let sub = await reg.pushManager.getSubscription();
  const key = urlB64ToUint8Array(public_key);
  if (sub) {
    // Keys rotated on the server? Re-subscribe with the current one.
    const current = sub.options?.applicationServerKey ? new Uint8Array(sub.options.applicationServerKey as ArrayBuffer) : null;
    if (current && (current.length !== key.length || current.some((b, i) => b !== key[i]))) { await sub.unsubscribe(); sub = null; }
  }
  if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  await walker("save_push_subscription", { subscription: sub.toJSON(), user_agent: navigator.userAgent });
  return "on";
}

export async function disablePush(): Promise<PushState> {
  const reg = await navigator.serviceWorker.getRegistration("/");
  const sub = reg ? await reg.pushManager.getSubscription() : null;
  if (sub) {
    try { await walker("delete_push_subscription", { endpoint: sub.endpoint }); } catch { /* ignore */ }
    await sub.unsubscribe();
  }
  return "off";
}

/** Unlink this device on sign-out so the next person on this phone doesn't get the previous user's alerts. */
export async function unlinkDeviceOnSignOut() {
  try {
    const reg = await navigator.serviceWorker?.getRegistration("/");
    const sub = reg ? await reg.pushManager.getSubscription() : null;
    if (sub) await walker("delete_push_subscription", { endpoint: sub.endpoint });
  } catch { /* offline — the server drops dead subscriptions on its own */ }
}
