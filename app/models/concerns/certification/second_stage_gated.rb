module Certification
  # Holds a hardware T1 approval's payout until a T2 reviewer clears it. Hosts
  # define run_deferred_approval_effects! and guard on second_stage_cleared?.
  module SecondStageGated
    extend ActiveSupport::Concern

    included do
      has_many :second_stage_reviews,
              class_name: "Certification::SecondStageReview",
              as: :reviewable,
              dependent: :destroy
      has_one :second_stage_review, -> { current },
              class_name: "Certification::SecondStageReview",
              as: :reviewable

      # Marks a T2-driven save, so the host doesn't re-award the T1 bounty.
      attr_accessor :releasing_second_stage

      # Registered before the host's project/payout callbacks. Failure to create
      # the hold rolls back T1 rather than committing an approval without a gate.
      after_save :open_second_stage_review!,
                 if: -> { saved_change_to_status? && approved? && !releasing_second_stage && project&.hardware? && (Flipper.enabled?(:hardware_t2_review) || second_stage_reviews.exists?) }

      # An undone T1 approval must not leave a live T2 review that could still pay out.
      after_save :void_second_stage_review!,
                 if: -> { saved_change_to_status? && !approved? && !releasing_second_stage && project&.hardware? }
    end

    # The current round is the durable hold. The flag only enrolls new approvals;
    # toggling it must never release held money or gate old flag-off approvals.
    def second_stage_required?
      second_stage_review.present?
    end

    def second_stage_cleared?
      return true unless second_stage_required?

      second_stage_review.approved?
    end

    def awaiting_second_stage?
      approved? && second_stage_required? && !second_stage_review.released?
    end

    # Session-level, so the grant id commits independently of the verdict and
    # cannot be rolled back after HCB succeeds. Undo and grant retries use it too.
    def with_review_lock(&block)
      self.class.with_advisory_lock!("hardware-review:#{self.class.name}:#{id}", disable_query_cache: true, &block)
    end

    def release_second_stage!(round)
      with_review_lock do
        reload
        round.reload
        return false unless approved? && project && !project.deleted? && round.release_pending?
        return false unless second_stage_review == round
        return false if respond_to?(:latest_for_project?) && !latest_for_project?

        self.releasing_second_stage = true
        with_lock { apply_verdict_to_project! }
        run_deferred_approval_effects!
        round.update!(released_at: Time.current)
        true
      ensure
        self.releasing_second_stage = false
      end
    end

    # An ordinary T1 return with T2's feedback. reviewer_id is left alone, or the
    # T1 reviewer's bounty would move to the T2 reviewer.
    def return_from_second_stage!(feedback:)
      self.releasing_second_stage = true
      update!(status: :returned, feedback: feedback)
    ensure
      self.releasing_second_stage = false
    end

    def effective_reviewer
      second_stage_review&.decided? ? second_stage_review.reviewer : reviewer
    end

    def effective_decided_at
      second_stage_review&.decided_at || decided_at
    end

    def effective_feedback_review
      second_stage_review&.decided? ? second_stage_review : self
    end

    private

    def open_second_stage_review!
      Certification::SecondStageReview.open_for!(self)
      reset_second_stage_review
    end

    # Preserve decisions and earned bounties, but invalidate every old clearance.
    def void_second_stage_review!
      second_stage_review&.update!(superseded_at: Time.current)
      reset_second_stage_review
    end
  end
end
