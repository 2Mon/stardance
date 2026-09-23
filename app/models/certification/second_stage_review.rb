module Certification
  # The second (T2) stage of a hardware review.
  #
  # A hardware submission is reviewed twice. A project_certifier gives the
  # first verdict (T1) on the ordinary design/build queues; approving there no
  # longer pays anything out, it opens one of these. Only when a t2_reviewer
  # approves *this* record does the payout actually run - the HCB grant for a
  # design request, the ship certification cascade (YSWS review, after-ship
  # prizes, project approval) for a build.
  #
  # Kept as its own record rather than another `status` value on the T1 review:
  # that enum drives decided?, the approval-rate stats, the undo flow, the
  # misfiled/withdrawn correction loop and the external decision API, and
  # threading a "t2_pending" through all of them would quietly restate every
  # existing number.
  #
  # A T2 return doesn't record a separate verdict for the builder - it flips the
  # T1 review to `returned` so the builder is returned exactly as a T1 return
  # would have returned them.
  class SecondStageReview < ApplicationRecord
    self.table_name = "certification_second_stage_reviews"

    include Certification::Reviewable

    belongs_to :reviewable, polymorphic: true
    belongs_to :reviewer, class_name: "User", optional: true

    has_paper_trail

    # Mirrors the T1 enum, minus the queue-routing states: a misfiled submission
    # never reaches the second stage, because only an approval opens one.
    enum :status, {
      pending: 0,
      approved: 1,
      returned: 2
    }, default: :pending

    # Stardust a T2 reviewer earns per completed second-stage review.
    REVIEW_BOUNTY = 1

    # Target turnaround, matching the design queue's.
    SLA_DAYS = 3

    VERDICTS = %w[approved returned].freeze

    # Photos a T2 reviewer attaches to their feedback, the same affordance the
    # T1 funding verdict has.
    has_many_attached :feedback_images do |attachable|
      attachable.variant :thumb, resize_to_limit: [ 320, 320 ], format: :webp
    end

    validates :feedback, length: { maximum: 10_000 }, allow_blank: true
    # A return replaces the T1 feedback the builder sees, so it has to say why:
    # left blank, the builder would get a return carrying T1's approving note.
    validates :feedback, presence: true, if: :returned?
    validates :reviewable_type, inclusion: { in: %w[Certification::FundingRequest Certification::Ship] }

    # Reviewable's claim/queue machinery works off the project and owner behind
    # the submission, so both the policy's own-project guard and the queue joins
    # have something to stand on.
    delegate :project, :owner, to: :reviewable

    # Named *_stage rather than design/build: `build` is already an Active
    # Record class method (the association/relation builder), and defining a
    # scope over it raises on load.
    scope :design_stage, -> { where(reviewable_type: "Certification::FundingRequest") }
    scope :build_stage, -> { where(reviewable_type: "Certification::Ship") }

    scope :for_stage, ->(stage) { stage.to_s == "design" ? design_stage : build_stage }

    # Every second stage opened for a project, across both reviewable types.
    # The reviewable is polymorphic, so this matches ids per concrete table
    # rather than trying to join through the association.
    scope :for_project, ->(project_id) {
      where(
        "(reviewable_type = 'Certification::FundingRequest' AND reviewable_id IN (:funding)) OR " \
        "(reviewable_type = 'Certification::Ship' AND reviewable_id IN (:ships))",
        funding: Certification::FundingRequest.where(project_id: project_id).select(:id),
        ships: Certification::Ship.where(project_id: project_id).select(:id)
      )
    }

    # A T2 reviewer must never clear a submission they gave the first verdict
    # on - that collapses the two stages back into one. Also excludes their own
    # projects, same bar as every other review queue.
    # Deliberately says nothing about this table's own reviewer_id. That column
    # is the *second stage's* reviewer - i.e. whoever currently holds the claim -
    # so excluding it would hide a review from the very person who claimed it,
    # and would contradict available_for, which includes `reviewer_id = user`
    # precisely so a reviewer can resume their own claim.
    #
    # The separation of duties this queue actually needs is about the *first*
    # stage, and that's what reviewed_at_t1_by enforces.
    scope :for_reviewer, ->(user) {
      where.not(id: reviewed_at_t1_by(user))
        .where.not(id: on_projects_of(user))
    }

    # Second stages whose T1 verdict this user gave, via each concrete T1 table.
    def self.reviewed_at_t1_by(user)
      funding = where(reviewable_type: "Certification::FundingRequest")
        .joins("INNER JOIN certification_funding_requests ON certification_funding_requests.id = certification_second_stage_reviews.reviewable_id")
        .where(certification_funding_requests: { reviewer_id: user.id })
      ships = where(reviewable_type: "Certification::Ship")
        .joins("INNER JOIN certification_ship_reviews ON certification_ship_reviews.id = certification_second_stage_reviews.reviewable_id")
        .where(certification_ship_reviews: { reviewer_id: user.id })

      funding.select(:id).to_a.map(&:id) + ships.select(:id).to_a.map(&:id)
    end

    # Second stages sitting on a project this user belongs to.
    def self.on_projects_of(user)
      project_ids = user.memberships.select(:project_id)
      funding = where(reviewable_type: "Certification::FundingRequest")
        .joins("INNER JOIN certification_funding_requests ON certification_funding_requests.id = certification_second_stage_reviews.reviewable_id")
        .where(certification_funding_requests: { project_id: project_ids })
      ships = where(reviewable_type: "Certification::Ship")
        .joins("INNER JOIN certification_ship_reviews ON certification_ship_reviews.id = certification_second_stage_reviews.reviewable_id")
        .where(certification_ship_reviews: { project_id: project_ids })

      funding.select(:id).to_a.map(&:id) + ships.select(:id).to_a.map(&:id)
    end

    # The same fraud hold-back as the T1 queues: a project flagged after its T1
    # approval stays out of "next" until the fraud team clears it.
    def self.available_for(user)
      super.merge(for_reviewer(user))
        .where.not(id: for_project(fraud_flagged_project_ids).select(:id))
    end

    # Opens (or re-opens) the second stage for a T1 review that has just been
    # approved. Idempotent on the unique reviewable index: a re-approval after
    # an undo rewinds the existing row to pending rather than stacking a new
    # one, so the queue never shows the same submission twice. The earlier
    # verdict's notes and bounty are cleared with it, so the fresh review starts
    # clean.
    def self.open_for!(reviewable)
      record = find_or_initialize_by(reviewable: reviewable)
      record.assign_attributes(
        status: :pending,
        reviewer_id: nil,
        claimed_at: nil,
        claim_expires_at: nil,
        decided_at: nil,
        feedback: nil,
        internal_reason: nil,
        stardust_earned: nil
      )
      record.save!
      record
    end

    def stage = reviewable.is_a?(Certification::FundingRequest) ? "design" : "build"
    def stage_label = stage == "design" ? "Design" : "Build"

    # The T1 reviewer whose approval opened this stage, shown on the T2 page so
    # the second reviewer knows whose call they're checking.
    def first_stage_reviewer = reviewable.reviewer

    def verdict = decided? ? status : nil

    def verdict=(value)
      self.status = value if VERDICTS.include?(value.to_s)
    end

    before_save :stamp_claimed_at,
      if: -> { will_save_change_to_reviewer_id? && reviewer_id.present? && claimed_at.nil? }
    before_save :stamp_decided_at,
      if: -> { will_save_change_to_status? && status_change&.last.in?(DECIDED_STATUSES) && decided_at.nil? }
    before_save :assign_stardust_earned,
      if: -> { will_save_change_to_status? && status_change&.last.in?(DECIDED_STATUSES) && reviewer_id.present? }
    # A return is applied inside the transaction, so the T1 review can never be
    # left approved behind a returned second stage. The release waits for the
    # commit: it calls HCB, and a rollback after the grant went out would lose
    # the grant id and let a retry pay twice.
    after_save :return_reviewable!, if: -> { saved_change_to_status? && returned? }
    after_save_commit :release_reviewable!, if: -> { saved_change_to_status? && approved? }

    # Locals for the verdict notification's Slack template, delegated to the
    # underlying submission so the builder sees one coherent story rather than
    # a second, internal-sounding verdict.
    def notification_locals = reviewable.notification_locals

    def queue_mismatch_flagged_label = "#{stage} second stage"
    def queue_mismatch_suggested_label = "first stage"

    private

    def stamp_claimed_at
      self.claimed_at = Time.current
    end

    def stamp_decided_at
      self.decided_at = Time.current
    end

    def assign_stardust_earned
      self.stardust_earned = REVIEW_BOUNTY
    end

    # The payout seam. Approving runs the T1 review's deferred effects - the
    # ones held back while `second_stage_cleared?` was false.
    def release_reviewable!
      reviewable.release_second_stage!
    end

    # Returning flips the T1 verdict to `returned`, which runs the ordinary
    # return path (notify the owner, post the verdict) with the T2 feedback.
    def return_reviewable!
      reviewable.return_from_second_stage!(feedback: feedback)
    end
  end
end
