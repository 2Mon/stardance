import { Controller } from "@hotwired/stimulus";

// The verdict flow for the review cockpit: picking approve or return, then
// confirming it.
//
// Confirmation is a <dialog>, never window.confirm — a native modal blocks the
// whole page and cannot be styled to say what the verdict actually costs.
//
// The keyboard layer lives in review_shortcuts_controller and drives this by
// clicking the same buttons a mouse would, so there is one path to a verdict.
export default class extends Controller {
  static targets = ["feedback", "approve", "return", "confirm", "confirmText"];
  static values = { approveText: String, returnText: String };

  approve(event) {
    event.preventDefault();
    this.choose("approved");
  }

  // A return replaces the builder-facing feedback, so it can't go out blank.
  returnIt(event) {
    event.preventDefault();
    if (this.hasFeedbackTarget && this.feedbackTarget.value.trim() === "") {
      this.feedbackTarget.setCustomValidity("Tell the builder why this is being returned.");
      this.feedbackTarget.reportValidity();
      this.feedbackTarget.addEventListener("input", () => this.feedbackTarget.setCustomValidity(""), {
        once: true,
      });
      return;
    }
    this.choose("returned");
  }

  choose(verdict) {
    const radio = verdict === "approved" ? this.approveTarget : this.returnTarget;
    radio.checked = true;

    if (this.hasConfirmTextTarget) {
      this.confirmTextTarget.textContent =
        verdict === "approved" ? this.approveTextValue : this.returnTextValue;
    }
    if (this.hasConfirmTarget) this.confirmTarget.showModal();
  }

  cancel() {
    if (this.hasConfirmTarget) this.confirmTarget.close();
  }

  // The dialog's confirm button submits the real form, so the verdict, the
  // feedback and any attached photos all travel together.
  submit() {
    if (this.hasConfirmTarget) this.confirmTarget.close();
    this.element.requestSubmit();
  }
}
