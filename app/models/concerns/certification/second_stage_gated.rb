module Certification
  # Holds a hardware submission's payout back until a T2 reviewer clears it.
  #
  # Mixed into the two T1 review models (Certification::FundingRequest and
  # Certification::Ship). A T1 approval used to be terminal: it advanced the
  # project and issued the grant straight out of its own callbacks. With the
  # second stage on, the approval instead opens a Certification::SecondStageReview
  # and every payout effect is deferred until that record is approved.
  #
  # The host model supplies:
  #   run_deferred_approval_effects!  -> fire the payout effects held back at T1
  #
  # and guards its own approval-side callbacks on `second_stage_cleared?`.
  module SecondStageGated
    extend ActiveSupport::Concern

    included do
      has_one :second_stage_review,
              class_name: "Certification::SecondStageReview",
              as: :reviewable,
              dependent: :destroy

      # Set while the second stage is releasing or returning this review, so the
      # host's own callbacks can tell a T2-driven save from a fresh T1 verdict
      # and don't re-award the T1 reviewer's bounty for it.
      attr_accessor :releasing_second_stage

      after_save_commit :open_second_stage_review!,
                        if: -> { saved_change_to_status? && approved? && second_stage_required? && !releasing_second_stage }

      # An undone T1 approval must not leave a live second stage pointing at a
      # review that is back to pending or returned - it would sit in the T2
      # queue forever, and approving it would pay out a verdict nobody holds.
      # Hardware only: a software ship never opens a second stage, so there is
      # nothing to void and no reason to query for one on every verdict.
      after_save :void_second_stage_review!,
                 if: -> { saved_change_to_status? && !approved? && !releasing_second_stage && project&.hardware? }
    end

    # Hardware only, and only while the flag is on. Deliberately a global
    # Flipper check rather than a per-actor one: this decides whether money
    # moves, and an actor-scoped flag would mean one reviewer's approval issues
    # a grant while another's doesn't.
    def second_stage_required?
      return false unless Flipper.enabled?(:hardware_t2_review)

      project&.hardware?
    end

    # True when the payout may run: either the second stage doesn't apply, or a
    # T2 reviewer has approved it. Every deferred effect keys off this.
    def second_stage_cleared?
      return true unless second_stage_required?

      second_stage_review&.approved? || false
    end

    # True while an approved T1 verdict is parked in the T2 queue.
    def awaiting_second_stage?
      approved? && second_stage_required? && !second_stage_review&.approved?
    end

    # Called by the second stage on approval. Re-runs the payout effects that
    # were held back at T1. `latest_for_project?` is re-checked by the host's
    # own guards, because a resubmit may have superseded this request while it
    # sat in the T2 queue.
    def release_second_stage!
      # Re-read, never trust the cache: the association is polymorphic, so Rails
      # can't link it back to the record being approved, and a copy loaded while
      # it was still pending would read as uncleared and pay nothing out.
      reload_second_stage_review
      self.releasing_second_stage = true
      run_deferred_approval_effects!
    ensure
      self.releasing_second_stage = false
    end

    # A T2 reviewer sending the submission back. Recorded on the T1 review as an
    # ordinary return so the builder gets the normal return experience - one
    # verdict, not an internal-sounding second one - carrying the T2 reviewer's
    # feedback. reviewer_id is left alone: reviewer payouts are summed by it, so
    # overwriting it would move the T1 reviewer's bounty to the T2 reviewer. Who
    # returned it is on the second stage record.
    def return_from_second_stage!(feedback:)
      self.releasing_second_stage = true
      update!(status: :returned, decided_at: Time.current, feedback: feedback)
    ensure
      self.releasing_second_stage = false
    end

    private

    def open_second_stage_review!
      Certification::SecondStageReview.open_for!(self)
    rescue StandardError => e
      Rails.logger.error("#{self.class.name} ##{id} open_second_stage_review! failed: #{e.message}")
    end

    # Only a second stage still waiting in the queue is voided. A decided one is
    # the record of who signed off on a payout that has already gone out, so
    # rewinding the T1 verdict must not erase it.
    def void_second_stage_review!
      second_stage_review&.destroy if second_stage_review&.pending?
    end
  end
end
