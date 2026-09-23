import { Controller } from "@hotwired/stimulus";

// Draggable dividers between the review cockpit's three panes. A reviewer working
// through a photo-heavy rail wants it wide; one reading a README wants the
// middle wide. The split is remembered per viewer so it survives moving to the
// next review in the queue.
const STORAGE_KEY = "review-cockpit-panes";
const MIN_FRACTION = 0.15;

export default class extends Controller {
  static targets = ["panes"];

  connect() {
    this.restore();
  }

  // Both handles share this: which one is being dragged is read off the
  // element, so there is one drag implementation rather than two.
  start(event) {
    event.preventDefault();
    this.dragging = event.currentTarget.dataset.handle;
    this.onMove = this.move.bind(this);
    this.onUp = this.stop.bind(this);
    document.addEventListener("pointermove", this.onMove);
    document.addEventListener("pointerup", this.onUp);
    document.body.classList.add("is-resizing-panes");
  }

  move(event) {
    if (!this.dragging || !this.hasPanesTarget) return;

    const box = this.panesTarget.getBoundingClientRect();
    const fraction = (event.clientX - box.left) / box.width;

    if (this.dragging === "left") {
      this.left = this.clamp(fraction, MIN_FRACTION, this.right - MIN_FRACTION);
    } else {
      this.right = this.clamp(fraction, this.left + MIN_FRACTION, 1 - MIN_FRACTION);
    }
    this.apply();
  }

  stop() {
    this.dragging = null;
    document.removeEventListener("pointermove", this.onMove);
    document.removeEventListener("pointerup", this.onUp);
    document.body.classList.remove("is-resizing-panes");
    this.persist();
  }

  clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  apply() {
    if (!this.hasPanesTarget) return;

    const left = `${this.left * 100}%`;
    const middle = `${(this.right - this.left) * 100}%`;
    this.panesTarget.style.gridTemplateColumns = `${left} 6px ${middle} 6px 1fr`;
  }

  // Browser storage is a per-viewer convenience here, so a private window or
  // blocked site data just means the default split.
  restore() {
    this.left = 0.26;
    this.right = 0.68;

    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
      if (saved && typeof saved.left === "number" && typeof saved.right === "number") {
        this.left = saved.left;
        this.right = saved.right;
      }
    } catch {
      // Fall through to the defaults.
    }
    this.apply();
  }

  persist() {
    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({ left: this.left, right: this.right })
      );
    } catch {
      // Not being able to remember the split is not worth surfacing.
    }
  }
}
