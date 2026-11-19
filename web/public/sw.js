/* Minimal service worker.
 *
 * Deliberately does NOT cache the app shell aggressively: this is a live
 * monitoring tool, and serving a stale UI while the rig is in trouble would
 * be worse than a slightly slower load. It exists so the app is installable
 * and so notifications have a registration to attach to.
 */
const VERSION = "xhome-v1";

self.addEventListener("install", e => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

// Network-first for everything; fall back to cache only when offline.
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  // Never cache media or live data.
  if (url.pathname.endsWith(".ts") || url.pathname.endsWith(".m3u8") ||
      url.pathname.endsWith(".json") || url.pathname.endsWith(".jsonl")) return;

  e.respondWith(
    fetch(req).then(res => {
      const copy = res.clone();
      caches.open(VERSION).then(c => c.put(req, copy)).catch(() => {});
      return res;
    }).catch(() => caches.match(req))
  );
});

// Allow the page to raise a notification through the SW (required on iOS).
self.addEventListener("message", e => {
  const d = e.data || {};
  if (d.type === "notify") {
    self.registration.showNotification(d.title || "xhome", {
      body: d.body || "",
      icon: "icon-192.png",
      badge: "icon-192.png",
      tag: d.tag || "xhome-stream",
      renotify: true
    });
  }
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(clients.matchAll({ type: "window" }).then(list => {
    for (const c of list) if ("focus" in c) return c.focus();
    if (clients.openWindow) return clients.openWindow("./");
  }));
});
