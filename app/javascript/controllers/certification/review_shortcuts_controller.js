import { Controller } from "@hotwired/stimulus";

// Keyboard layer for the review cockpit, adapted from the YSWS review hotkeys.
// One document keydown keeps a "current devlog" cursor over the left rail and
// dispatches to controls that already exist — it only clicks buttons, so the
// verdict logic stays in the decision controller and can't drift.
//
//   j / k        next / previous devlog (clamped)
//   t            open the current devlog's timelapses
//   i            open the current devlog's first photo
//   c            collapse / expand the current devlog
//   a / r        approve / return
//   s            skip to the next project
//   ctrl+space   focus the feedback box
//   ctrl+enter   record the verdict (press twice to confirm)
//   ?            toggle the shortcut help (Escape closes)
//
// The rail is its own scroll container, so navigation scrolls the rail rather
// than the window and the cursor is tracked against the rail as root.

// Per-control hint badges: [selector, key label].
const HINTS = [
  ["[data-shortcut='approve']", "A"],
  ["[data-shortcut='return']", "R"],
  ["[data-shortcut='skip']", "S"],
];

const SHORTCUTS = [
  ["J / K", "Prev / next devlog"],
  ["T", "Open timelapses"],
  ["I", "Open first photo"],
  ["C", "Collapse / expand devlog"],
  ["A / R", "Approve / return"],
  ["S", "Skip to next project"],
  ["⌃ Space", "Focus feedback"],
  ["⌃ ⏎ ×2", "Record verdict (twice)"],
  ["?", "Show this help"],
];

export default class extends Controller {
  static targets = ["rail", "feedback", "legend"];

  connect() {
    this.currentIndex = 0;
    this.onKeydown = this.onKeydown.bind(this);
    document.addEventListener("keydown", this.onKeydown);
    this.decorateHints();
    this.buildLegend();
    this.observeRail();
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown);
    this.observer?.disconnect();
    this.disarmVerdict();
    this.undecorateHints();
    if (this.hasLegendTarget) this.legendTarget.innerHTML = "";
    this.dialog?.remove();
  }

  onKeydown(event) {
    // The photo lightbox is modal and owns the keyboard while open.
    if (document.querySelector(".review-cockpit__lightbox[open]")) return;

    // The help overlay is modal: Escape closes it and nothing else fires.
    if (this.dialog?.open) {
      if (event.key === "Escape")
        return this.consume(event, () => this.dialog.close());
      return;
    }

    // Chords first: they never insert text, so they work while typing.
    if ((event.ctrlKey || event.metaKey) && !event.altKey) {
      if (event.code === "Space")
        return this.consume(event, () => this.focusFeedback());
      if (event.key === "Enter")
        return this.consume(event, () => this.recordVerdict());
      return;
    }

    // Escape drops focus out of a field so the single-key shortcuts work again.
    if (event.key === "Escape") {
      const el = document.activeElement;
      if (el && el !== document.body && this.isTyping(el)) {
        return this.consume(event, () => el.blur());
      }
      return;
    }

    if (event.altKey) return;
    if (this.isTyping(event.target)) return;

    switch (event.key) {
      case "j":
        return this.consume(event, () => this.stepDevlog(1));
      case "k":
        return this.consume(event, () => this.stepDevlog(-1));
      case "t":
        return this.consume(event, () => this.openTimelapses());
      case "i":
        return this.consume(event, () => this.openPhoto());
      case "c":
        return this.consume(event, () => this.toggleDevlog());
      case "a":
        return this.consume(event, () => this.click("[data-shortcut='approve']"));
      case "r":
        return this.consume(event, () => this.click("[data-shortcut='return']"));
      case "s":
        return this.consume(event, () => this.click("[data-shortcut='skip']"));
      case "?":
        return this.consume(event, () => this.toggleHelp());
    }
  }

  consume(event, fn) {
    event.preventDefault();
    fn();
  }

  isTyping(el) {
    if (!el) return false;
    return (
      ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) || el.isContentEditable
    );
  }

  // ── Devlog navigation ───────────────────────────────────────────────────
  devlogEls() {
    return Array.from(this.element.querySelectorAll(".review-cockpit__devlog"));
  }

  currentDevlog() {
    return this.devlogEls()[this.currentIndex] || null;
  }

  stepDevlog(delta) {
    const els = this.devlogEls();
    if (!els.length) return;

    this.markCurrent(this.currentIndex + delta);
    this.navScrolling = true;
    this.currentDevlog()?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    clearTimeout(this.navTimer);
    this.navTimer = setTimeout(() => {
      this.navScrolling = false;
    }, 400);
  }

  // The cursor is marked on screen here, unlike the YSWS original: the rail is a
  // narrow column and without a marker there is no way to tell which devlog the
  // next keypress will act on.
  markCurrent(index) {
    const els = this.devlogEls();
    if (!els.length) return;

    this.currentIndex = Math.max(0, Math.min(index, els.length - 1));
    els.forEach((el, i) =>
      el.classList.toggle("review-cockpit__devlog--current", i === this.currentIndex),
    );
  }

  // The current devlog follows whichever card is showing most of itself in the
  // rail, so scrolling by mouse and stepping by keyboard agree.
  observeRail() {
    const els = this.devlogEls();
    if (!els.length || typeof IntersectionObserver === "undefined") return;

    const root = this.hasRailTarget ? this.railTarget : null;
    this.area = new Map();
    this.observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const rect = entry.intersectionRect;
          this.area.set(entry.target, entry.isIntersecting ? rect.width * rect.height : 0);
        }
        if (this.navScrolling) return;

        let best = null;
        let bestArea = 0;
        for (const [el, area] of this.area) {
          if (area > bestArea) {
            bestArea = area;
            best = el;
          }
        }
        if (best && bestArea > 0) {
          const i = this.devlogEls().indexOf(best);
          if (i !== -1 && i !== this.currentIndex) this.markCurrent(i);
        }
      },
      { root, threshold: Array.from({ length: 11 }, (_, i) => i / 10) },
    );
    els.forEach((el) => this.observer.observe(el));
    this.markCurrent(0);
  }

  // ── Actions on the current devlog ───────────────────────────────────────
  openTimelapses() {
    const details = this.currentDevlog()?.querySelector(
      ".review-cockpit__devlog-recordings",
    );
    if (!details) return;

    details.open = !details.open;
    if (details.open) details.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  openPhoto() {
    this.currentDevlog()?.querySelector(".review-cockpit__gallery-link")?.click();
  }

  toggleDevlog() {
    this.currentDevlog()?.querySelector("[data-action*='toggleDevlog']")?.click();
  }

  click(selector) {
    const btn = this.element.querySelector(selector);
    if (btn && !btn.disabled) btn.click();
  }

  focusFeedback() {
    if (!this.hasFeedbackTarget) return;

    this.feedbackTarget.scrollIntoView({ block: "nearest", behavior: "smooth" });
    this.feedbackTarget.focus();
  }

  // Recording a verdict moves money, so the chord arms on the first press and
  // only fires on the second — a keyboard "are you sure?" ahead of the dialog's.
  recordVerdict() {
    const btn = this.element.querySelector("[data-shortcut='record']");
    if (!btn || btn.disabled) return;

    if (this.verdictArmed) {
      this.disarmVerdict();
      btn.click();
      return;
    }
    this.verdictArmed = true;
    btn.classList.add("is-armed");
    clearTimeout(this.armTimer);
    this.armTimer = setTimeout(() => this.disarmVerdict(), 1500);
  }

  disarmVerdict() {
    this.verdictArmed = false;
    clearTimeout(this.armTimer);
    this.element.querySelector("[data-shortcut='record']")?.classList.remove("is-armed");
  }

  // ── Help overlay ────────────────────────────────────────────────────────
  toggleHelp() {
    if (!this.dialog) this.buildDialog();
    if (this.dialog.open) this.dialog.close();
    else this.dialog.showModal();
  }

  buildDialog() {
    const dialog = document.createElement("dialog");
    dialog.className = "kbd-help";
    dialog.addEventListener("click", (e) => {
      if (e.target === dialog) dialog.close();
    });

    const rows = SHORTCUTS.map(
      ([key, desc]) =>
        `<div class="kbd-help__row"><kbd class="kbd-help__key">${key}</kbd><span class="kbd-help__desc">${desc}</span></div>`,
    ).join("");

    dialog.innerHTML =
      `<div class="kbd-help__content">` +
      `<h2 class="kbd-help__title">Keyboard shortcuts</h2>` +
      rows +
      `</div>`;

    document.body.appendChild(dialog);
    this.dialog = dialog;
  }

  // ── On-screen hints ─────────────────────────────────────────────────────
  decorateHints() {
    HINTS.forEach(([selector, label]) => {
      const el = this.element.querySelector(selector);
      if (el) this.addHint(el, label);
    });
  }

  addHint(el, label) {
    if (el.querySelector(":scope > .kbd-hint")) return;

    const kbd = document.createElement("kbd");
    kbd.className = "kbd-hint";
    kbd.textContent = label;
    el.appendChild(kbd);
  }

  undecorateHints() {
    this.element.querySelectorAll(".kbd-hint").forEach((el) => el.remove());
  }

  // Rendered into the cockpit's top bar rather than floated over a corner: the
  // decision pane's buttons live in the bottom-right, and a floating legend sat
  // on top of Approve and Return at ordinary zoom levels.
  buildLegend() {
    if (!this.hasLegendTarget) return;

    this.legendTarget.innerHTML =
      `<span class="kbd-legend__title">Shortcuts</span>` +
      [
        ["J / K", "devlogs"],
        ["T", "timelapses"],
        ["?", "more"],
      ]
        .map(
          ([key, desc]) =>
            `<span class="kbd-legend__item"><kbd class="kbd-hint">${key}</kbd>${desc}</span>`,
        )
        .join("");
  }
}
