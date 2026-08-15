// Turn-alert subscription button (match pages, seated players only).
//
// On click: ask notification permission, register the service worker,
// subscribe to Web Push with the server's VAPID key (data-vapid attribute),
// and hand the subscription to the LiveView, which stores it on the seat.

function urlBase64ToUint8Array(base64) {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const raw = atob((base64 + padding).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}

export const PushSubscribe = {
  mounted() {
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      this.el.style.display = "none";
      return;
    }

    this.el.addEventListener("click", async () => {
      try {
        const permission = await Notification.requestPermission();
        if (permission !== "granted") {
          this.pushEvent("push_denied", {});
          return;
        }

        await navigator.serviceWorker.register("/sw.js");
        // wait for activation — subscribing against an installing worker throws
        const reg = await navigator.serviceWorker.ready;
        const sub = await reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(this.el.dataset.vapid),
        });

        this.pushEvent("push_subscribed", sub.toJSON());
      } catch (e) {
        console.error("push subscribe failed", e);
        this.pushEvent("push_denied", {});
      }
    });
  },
};
