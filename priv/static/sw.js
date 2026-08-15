// Hex Empire service worker: Web Push turn notifications.
// Payload: {"title": ..., "body": ..., "url": "/m/<id>"}

self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_e) {
    data = { title: "Hex Empire", body: event.data && event.data.text() };
  }

  event.waitUntil(
    self.registration.showNotification(data.title || "Hex Empire", {
      body: data.body || "",
      icon: "/images/icon-192.png",
      badge: "/images/icon-192.png",
      tag: data.url || "hexempire",
      renotify: true,
      data: { url: data.url || "/" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "/";

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
      for (const win of wins) {
        if (win.url.includes(url) && "focus" in win) return win.focus();
      }
      return clients.openWindow(url);
    })
  );
});
