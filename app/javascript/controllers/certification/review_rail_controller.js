import { Controller } from "@hotwired/stimulus";

// The T2 evidence rail: collapsing individual devlogs down to their header, and
// opening a devlog photo full screen. One controller for the whole rail rather
// than one per devlog, so the lightbox is a single <dialog> the entire list
// shares instead of one per thumbnail.
export default class extends Controller {
  static targets = ["lightbox", "lightboxImage"];

  toggleDevlog(event) {
    const devlog = event.currentTarget.closest(".review-cockpit__devlog");
    const content = devlog?.querySelector(".review-cockpit__devlog-content");
    if (!content) return;

    const collapsed = devlog.classList.toggle("review-cockpit__devlog--collapsed");
    event.currentTarget.textContent = collapsed ? "Expand" : "Collapse";
  }

  // Esc closes a <dialog> natively, without going through closeImage, so the
  // source is dropped on the dialog's own close event rather than only in the
  // button handler.
  lightboxTargetConnected(dialog) {
    dialog.addEventListener("close", () => {
      this.lightboxImageTarget.src = "";
    });
  }

  openImage(event) {
    const src = event.currentTarget.dataset.fullSrc;
    if (!src || !this.hasLightboxTarget) return;

    this.lightboxImageTarget.src = src;
    this.lightboxTarget.showModal();
  }

  // Dropping the source is handled by the close listener above, so a photo is
  // never left loaded behind a closed dialog however it was dismissed.
  closeImage() {
    if (this.hasLightboxTarget) this.lightboxTarget.close();
  }
}
