/* PrimeZ · notifications : ce petit fichier tourne en fond dans le navigateur et affiche les notifications,
   même quand le site est fermé. Un clic ouvre PrimeZ sur le bon onglet. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: "PrimeZ", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "PrimeZ", {
    body: d.body || "",
    icon: "/logo.png",
    badge: "/logo.png",
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { link: d.link || "" }
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const link = (e.notification.data && e.notification.data.link) || "";
  const url = "/" + (link ? "?tab=" + encodeURIComponent(link) : "");
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) {
      if (new URL(c.url).origin === self.location.origin) {
        await c.focus();
        c.postMessage({ pz: "tab", tab: link });
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
