// Pinch-zoom / pan for the game board SVG.
//
// The hook owns a client-side view transform (scale + center) and applies it
// by rewriting the SVG's viewBox. LiveView re-renders the SVG on every game
// update, so `updated()` re-applies the transform after each patch.
//
// Gestures:
//   * one-finger drag / mouse drag ... pan (a real tap still clicks a hex:
//     clicks are suppressed only after movement beyond a small threshold)
//   * two-finger pinch ............... zoom around the pinch midpoint
//   * mouse wheel / trackpad ......... zoom around the cursor
//   * double-tap / double-click ...... toggle 1x <-> 2.5x at that point
//
// Scale is clamped to [1, 5]; panning is clamped to the board bounds.

const MIN_SCALE = 1;
const MAX_SCALE = 5;
const DRAG_THRESHOLD = 8; // px of movement before a tap becomes a pan

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
    // Swallow the click that follows a drag so panning never moves an army.
    this.el.addEventListener(
      "click",
      (e) => {
        if (this.dragged) {
          e.stopPropagation();
          e.preventDefault();
        }
      },
      { capture: true }
    );

    this.apply();
  },

  updated() {
    // LiveView patched the SVG (new game state) — re-apply our transform.
    this.svg = this.el.querySelector("svg");
    this.apply();
  },

  // --- gesture handling -----------------------------------------------------

  onDown(e) {
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

    // Double-tap toggles zoom (touch only; desktop gets dblclick via wheel).
    if (!this.dragged && e.pointerType === "touch") {
      const now = Date.now();
      if (now - this.lastTap < 300) {
        const target = this.scale > 1.5 ? 1 : 2.5;
        this.zoomAt({ x: e.clientX, y: e.clientY }, target);
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

  // --- view math ------------------------------------------------------------

  unitsPerPixel() {
    const rect = this.el.getBoundingClientRect();
    return this.base.w / this.scale / rect.width;
  },

  // Zoom so that the board point under `client` stays under the finger/cursor.
  zoomAt(client, newScale) {
    newScale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, newScale));
    const rect = this.svg.getBoundingClientRect();
    // board coords of the screen point at the current view
    const vw = this.base.w / this.scale;
    const vh = this.base.h / this.scale;
    const bx = this.cx - vw / 2 + ((client.x - rect.left) / rect.width) * vw;
    const by = this.cy - vh / 2 + ((client.y - rect.top) / rect.height) * vh;

    const nvw = this.base.w / newScale;
    const nvh = this.base.h / newScale;
    const fx = (client.x - rect.left) / rect.width;
    const fy = (client.y - rect.top) / rect.height;
    this.cx = bx + (0.5 - fx) * nvw;
    this.cy = by + (0.5 - fy) * nvh;
    this.scale = newScale;
    this.apply();
  },

  apply() {
    const vw = this.base.w / this.scale;
    const vh = this.base.h / this.scale;
    // clamp the view inside the board
    const minX = this.base.x + vw / 2;
    const maxX = this.base.x + this.base.w - vw / 2;
    const minY = this.base.y + vh / 2;
    const maxY = this.base.y + this.base.h - vh / 2;
    this.cx = Math.min(maxX, Math.max(minX, this.cx));
    this.cy = Math.min(maxY, Math.max(minY, this.cy));

    this.svg.setAttribute(
      "viewBox",
      `${this.cx - vw / 2} ${this.cy - vh / 2} ${vw} ${vh}`
    );
  },
};
