// Pinch-zoom / pan for the game board SVG.
//
// The hook owns a client-side view transform (scale + center) and renders it
// by rewriting the SVG viewBox. The viewBox always matches the CONTAINER's
// aspect ratio (preserveAspectRatio=none), so a zoomed view fills the whole
// board area instead of letterboxing to the board's own aspect. LiveView
// re-renders the SVG on every game update; `updated()` re-applies the view.
//
// Gestures & controls:
//   * one-finger drag / mouse drag ... pan (taps still click hexes; clicks
//     are suppressed only after movement beyond a small threshold)
//   * two-finger pinch ............... zoom around the pinch midpoint
//   * mouse wheel / trackpad ......... zoom around the cursor
//   * double-tap / double-click ...... toggle fit <-> 2.5x at that point
//   * overlay buttons ................ [+] [-] and fit-to-board reset
//
// scale=1 means "whole board fits"; max zoom is 6x.

const MAX_SCALE = 6;
const DRAG_THRESHOLD = 8; // px of movement before a tap becomes a pan
const BUTTON_STEP = 1.5;

export const BoardZoom = {
  mounted() {
    this.svg = this.el.querySelector("svg");
    const [x, y, w, h] = this.svg.getAttribute("viewBox").split(" ").map(Number);
    this.base = { x, y, w, h };
    this.scale = 1;
    this.cx = x + w / 2;
    this.cy = y + h / 2;

    this.pointers = new Map();
    this.dragged = false;
    this.lastTap = 0;

    this.el.style.touchAction = "none";

    this.el.addEventListener("pointerdown", (e) => this.onDown(e));
    this.el.addEventListener("pointermove", (e) => this.onMove(e));
    this.el.addEventListener("pointerup", (e) => this.onUp(e));
    this.el.addEventListener("pointercancel", (e) => this.onUp(e));
    this.el.addEventListener("wheel", (e) => this.onWheel(e), { passive: false });
    this.el.addEventListener("dblclick", (e) => {
      if (!e.target.closest("[data-zoom]")) this.toggleZoom(e);
    });

    // Zoom control buttons (delegated: the buttons live inside LV-patched DOM)
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-zoom]");
      if (!btn) return;
      e.stopPropagation();
      const rect = this.el.getBoundingClientRect();
      const center = { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };

      if (btn.dataset.zoom === "in") this.zoomAt(center, this.scale * BUTTON_STEP);
      if (btn.dataset.zoom === "out") this.zoomAt(center, this.scale / BUTTON_STEP);
      if (btn.dataset.zoom === "reset") this.reset();
    });

    // Swallow the click that follows a drag so panning never moves an army.
    this.el.addEventListener(
      "click",
      (e) => {
        if (this.dragged && !e.target.closest("[data-zoom]")) {
          e.stopPropagation();
          e.preventDefault();
        }
      },
      { capture: true }
    );

    // Re-fit when the container changes size (rotation, window resize).
    this.resizeObserver = new ResizeObserver(() => this.apply());
    this.resizeObserver.observe(this.el);

    this.apply();
  },

  updated() {
    // LiveView patched the SVG (new game state) — re-apply our transform.
    this.svg = this.el.querySelector("svg");
    this.apply();
  },

  destroyed() {
    if (this.resizeObserver) this.resizeObserver.disconnect();
  },

  // --- gesture handling -----------------------------------------------------

  onDown(e) {
    if (e.target.closest("[data-zoom]")) return;
    this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (this.pointers.size === 1) {
      this.dragged = false;
      this.downAt = { x: e.clientX, y: e.clientY };
    }
    if (this.pointers.size === 2) {
      const [a, b] = [...this.pointers.values()];
      this.pinchDist = Math.hypot(a.x - b.x, a.y - b.y);
    }
  },

  onMove(e) {
    if (!this.pointers.has(e.pointerId)) return;
    const prev = this.pointers.get(e.pointerId);
    this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

    if (this.pointers.size === 1) {
      const dx = e.clientX - this.downAt.x;
      const dy = e.clientY - this.downAt.y;
      if (!this.dragged && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
      this.dragged = true;

      const k = this.unitsPerPixel();
      this.cx -= (e.clientX - prev.x) * k;
      this.cy -= (e.clientY - prev.y) * k;
      this.apply();
    } else if (this.pointers.size === 2) {
      const [a, b] = [...this.pointers.values()];
      const dist = Math.hypot(a.x - b.x, a.y - b.y);

      if (this.pinchDist > 0) {
        const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
        this.zoomAt(mid, this.scale * (dist / this.pinchDist));
      }

      this.pinchDist = dist;
      this.dragged = true;
    }
  },

  onUp(e) {
    this.pointers.delete(e.pointerId);
    this.pinchDist = 0;

    // Double-tap toggles zoom (touch; desktop uses dblclick).
    if (!this.dragged && e.pointerType === "touch" && !e.target.closest("[data-zoom]")) {
      const now = Date.now();
      if (now - this.lastTap < 300) {
        this.toggleZoom(e);
        this.dragged = true; // swallow the click of the second tap
      }
      this.lastTap = now;
    }
  },

  onWheel(e) {
    e.preventDefault();
    const factor = Math.exp(-e.deltaY * 0.002);
    this.zoomAt({ x: e.clientX, y: e.clientY }, this.scale * factor);
  },

  toggleZoom(e) {
    const target = this.scale > 1.4 ? 1 : 2.5;
    this.zoomAt({ x: e.clientX, y: e.clientY }, target);
  },

  reset() {
    this.scale = 1;
    this.cx = this.base.x + this.base.w / 2;
    this.cy = this.base.y + this.base.h / 2;
    this.apply();
  },

  // --- view math ------------------------------------------------------------

  // View dimensions in board units: container aspect, sized so that at
  // scale=1 the entire board fits (with margin on one axis at most).
  viewDims() {
    const rect = this.el.getBoundingClientRect();
    const aspect = rect.width > 0 ? rect.height / rect.width : this.base.h / this.base.w;
    // width that fits the whole board at scale 1 for this aspect
    const fitW = Math.max(this.base.w, this.base.h / aspect);
    const vw = fitW / this.scale;
    return { vw, vh: vw * aspect };
  },

  unitsPerPixel() {
    const rect = this.el.getBoundingClientRect();
    return this.viewDims().vw / rect.width;
  },

  // Zoom so that the board point under `client` stays under the finger/cursor.
  zoomAt(client, newScale) {
    newScale = Math.min(MAX_SCALE, Math.max(1, newScale));
    const rect = this.el.getBoundingClientRect();
    const { vw, vh } = this.viewDims();
    const bx = this.cx - vw / 2 + ((client.x - rect.left) / rect.width) * vw;
    const by = this.cy - vh / 2 + ((client.y - rect.top) / rect.height) * vh;

    this.scale = newScale;
    const dims = this.viewDims();
    const fx = (client.x - rect.left) / rect.width;
    const fy = (client.y - rect.top) / rect.height;
    this.cx = bx + (0.5 - fx) * dims.vw;
    this.cy = by + (0.5 - fy) * dims.vh;
    this.apply();
  },

  apply() {
    if (!this.svg) return;
    const { vw, vh } = this.viewDims();

    // Clamp: keep the view inside the board; when the view is larger than the
    // board on an axis (fit margin), lock that axis to the board center.
    this.cx = clampCenter(this.cx, this.base.x, this.base.w, vw);
    this.cy = clampCenter(this.cy, this.base.y, this.base.h, vh);

    this.svg.setAttribute("preserveAspectRatio", "none");
    this.svg.setAttribute(
      "viewBox",
      `${this.cx - vw / 2} ${this.cy - vh / 2} ${vw} ${vh}`
    );

    // Reflect zoom state on the container (shows/hides the reset affordance).
    this.el.classList.toggle("he-zoomed", this.scale > 1.01);
  },
};

function clampCenter(c, min, extent, view) {
  if (view >= extent) return min + extent / 2;
  const lo = min + view / 2;
  const hi = min + extent - view / 2;
  return Math.min(hi, Math.max(lo, c));
}
