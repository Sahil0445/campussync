/* CampusSync service worker: phone/desktop notifications (Web Push). No offline caching —
   schedules must always be live. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { body: event.data ? event.data.text() : "" }; }
  const title = data.title || "CampusSync";
  const options = {
    body: data.body || "",
    icon: "/icons/icon-192.png",
    badge: "/icons/badge-96.png",
    data: { url: data.url || "/start" },
    tag: data.tag || undefined,
    renotify: Boolean(data.tag),
    timestamp: Date.now(),
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || "/start", self.location.origin).href;
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.location.origin) && "focus" in w) {
        try { await w.navigate(url); } catch (e) { /* cross-origin or not controlled */ }
        return w.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});

self.addEventListener("pushsubscriptionchange", (event) => {
  // The browser rotated the subscription; the app re-registers it on next open.
  event.waitUntil(Promise.resolve());
});
