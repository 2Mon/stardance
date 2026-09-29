# == Schema Information
#
# Table name: certification_second_stage_reviews
#
#  id                    :bigint           not null, primary key
#  approved_amount_cents :integer
#  claim_expires_at      :datetime
#  claimed_at            :datetime
#  decided_at            :datetime
#  feedback              :text
#  internal_reason       :text
#  lock_version          :integer          default(0), not null
#  reviewable_type       :string           not null
#  stardust_earned       :integer
#  status                :integer          default(0), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  reviewable_id         :bigint           not null
#  reviewer_id           :bigint
#
# Indexes
#
#  idx_second_stage_reviews_on_status_claim_expires         (status,claim_expires_at)
#  index_certification_second_stage_reviews_on_decided_at   (decided_at)
#  index_certification_second_stage_reviews_on_reviewable   (reviewable_type,reviewable_id)
#  index_certification_second_stage_reviews_on_reviewer_id  (reviewer_id)
#  index_second_stage_reviews_unique_reviewable             (reviewable_type,reviewable_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (reviewer_id => users.id)
#
module Certification
  # The second (T2) stage of a hardware review. A T1 approval opens one; only
  # approving it here runs the payout. Its own record, not a T1 status, so the
  # T1 enum (stats, undo, decision API) stays untouched.
  class SecondStageReview < ApplicationRecord
    self.table_name = "certification_second_stage_reviews"

    class ReleaseFailed < StandardError; end

    include Certification::Reviewable

    belongs_to :reviewable, polymorphic: true
    belongs_to :reviewer, class_name: "User", optional: true

    has_paper_trail
    attr_readonly :first_stage_snapshot

    enum :status, {
      pending: 0,
      approved: 1,
      returned: 2
    }, default: :pending

    REVIEW_BOUNTY = 1

    SLA_DAYS = 3

    VERDICTS = %w[approved returned].freeze

    has_many_attached :feedback_images do |attachable|
      attachable.variant :thumb, resize_to_limit: [ 320, 320 ], format: :webp
      attachable.variant :medium, resize_to_limit: [ 800, 800 ], format: :webp
      attachable.variant :large, resize_to_limit: [ 1600, 1600 ], format: :webp
    end

    validates :feedback_images,
              content_type: { in: FundingRequest::FEEDBACK_IMAGE_CONTENT_TYPES, spoofing_protection: true },
              size: { less_than: 15.megabytes, message: "is too large (max 15 MB)" },
              processable_file: true,
              limit: { max: FundingRequest::MAX_FEEDBACK_IMAGES }
    validates :feedback, length: { maximum: 10_000 }, allow_blank: true
    # A return replaces the T1 feedback the builder sees, so it must say why.
    validates :feedback, presence: true, if: :returned?
    validates :reviewable_type, inclusion: { in: %w[Certification::FundingRequest Certification::Ship] }

    # T2 override of the grant; nil pays the T1 figure (FundingRequest#payable_amount_cents).
    validates :approved_amount_cents,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              allow_nil: true
    validate :amount_only_on_design_stage
    validate :amount_within_tier_max
    validate :amount_in_whole_dollars

    delegate :project, :owner, to: :reviewable

    # Not `build`: that's already an Active Record class method.
    scope :design_stage, -> { where(reviewable_type: "Certification::FundingRequest") }
    scope :build_stage, -> { where(reviewable_type: "Certification::Ship") }

    scope :for_stage, ->(stage) { stage.to_s == "design" ? design_stage : build_stage }
    scope :current, -> { where(superseded_at: nil) }
    scope :on_active_projects, -> { for_project(Project.select(:id)) }

    scope :for_project, ->(project_id) {
      where(
        "(reviewable_type = 'Certification::FundingRequest' AND reviewable_id IN (:funding)) OR " \
        "(reviewable_type = 'Certification::Ship' AND reviewable_id IN (:ships))",
        funding: Certification::FundingRequest.where(project_id: project_id).select(:id),
        ships: Certification::Ship.where(project_id: project_id).select(:id)
      )
    }

    # A T2 reviewer never clears their own T1 verdict or their own project. This
    # table's reviewer_id is the claim holder, so it's deliberately not excluded.
    scope :for_reviewer, ->(user) {
      on_active_projects
        .where.not(id: reviewed_at_t1_by(user))
        .where.not(id: for_project(user.memberships.select(:project_id)))
    }

    def self.reviewed_at_t1_by(user)
      funding = where(reviewable_type: "Certification::FundingRequest")
        .joins("INNER JOIN certification_funding_requests ON certification_funding_requests.id = certification_second_stage_reviews.reviewable_id")
        .where(certification_funding_requests: { reviewer_id: user.id })
      ships = where(reviewable_type: "Certification::Ship")
        .joins("INNER JOIN certification_ship_reviews ON certification_ship_reviews.id = certification_second_stage_reviews.reviewable_id")
        .where(certification_ship_reviews: { reviewer_id: user.id })

      where(id: funding.select(:id)).or(where(id: ships.select(:id))).select(:id)
    end

    # Fraud-flagged projects stay out of "next", same as the T1 queues.
    def self.available_for(user)
      super.current.merge(for_reviewer(user))
        .where.not(id: for_project(fraud_flagged_project_ids).select(:id))
    end

    def self.next_eligible_scope(user)
      available_for(user).not_skipped_by(user)
    end

    # Each T1 approval has a new round; earlier decisions remain auditable and
    # keep their earned bounty. Called inside the T1 transaction.
    def self.open_for!(reviewable)
      current.where(reviewable: reviewable).each { |round| round.update!(superseded_at: Time.current) }
      create!(reviewable: reviewable, first_stage_snapshot: reviewable.attributes_for_database)
    end

    def current? = superseded_at.nil?
    def released? = released_at.present?
    def release_pending? = current? && approved? && !released?

    # T2 returns copy feedback to T1 for the existing resubmission contract.
    # Capture the approval itself: version timestamps may tie and versions may
    # be pruned. Only pre-migration rounds need the best-effort legacy fallback.
    def first_stage_review
      @first_stage_review ||= begin
        attributes = first_stage_snapshot || (reviewable.paper_trail.version_at(created_at) || reviewable).attributes_for_database
        reviewable.class.instantiate(attributes).tap(&:readonly!)
      end
    end

    def release!
      reviewable.release_second_stage!(self)
    rescue StandardError => e
      Rails.logger.error("T2 release ##{id} failed: #{e.class}: #{e.message}")
      raise ReleaseFailed, "Release did not finish"
    end

    def stage = reviewable.is_a?(Certification::FundingRequest) ? "design" : "build"
    def stage_label = stage == "design" ? "Design" : "Build"

    def first_stage_reviewer = first_stage_review.reviewer

    def approved_amount_dollars
      return @approved_amount_dollars if defined?(@approved_amount_dollars)
      return if approved_amount_cents.nil?

      approved_amount_cents % 100 == 0 ? approved_amount_cents / 100 : approved_amount_cents / 100.0
    end

    def approved_amount_dollars=(value)
      @approved_amount_dollars = value.presence
      dollars = Integer(value.to_s, 10, exception: false)
      self.approved_amount_cents = dollars && dollars * 100
    end

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
    around_update :lock_reviewable_for_decision, if: :will_save_change_to_status?
    # A return applies inside the transaction; the release calls HCB, so it waits
    # for the commit or a rollback could lose the grant id and pay twice.
    after_save :return_reviewable!, if: -> { saved_change_to_status? && returned? }
    after_save_commit :release_reviewable!, if: -> { saved_change_to_status? && approved? }

    def notification_locals = reviewable.notification_locals

    def queue_mismatch_flagged_label = "#{stage} second stage"
    def queue_mismatch_suggested_label = "first stage"

    private

    # Match undo's T1 -> T2 lock order and reject an old round even when someone
    # saved a previously loaded model outside the controller.
    def lock_reviewable_for_decision
      reviewable.with_lock do
        unless status_in_database == "pending" && current? && reviewable.approved? && project && !project.deleted?
          errors.add(:base, "This review is no longer awaiting a decision.")
          throw :abort
        end
        yield
      end
    end

    def amount_only_on_design_stage
      return if approved_amount_cents.blank? || stage == "design"

      errors.add(:approved_amount_cents, "only applies to a design review")
    end

    def amount_in_whole_dollars
      invalid_input = @approved_amount_dollars.present? && !@approved_amount_dollars.to_s.match?(/\A\d+\z/)
      fractional_cents = will_save_change_to_approved_amount_cents? && approved_amount_cents && approved_amount_cents % 100 != 0
      if invalid_input || fractional_cents
        errors.add(:approved_amount_dollars, "must be a whole number of dollars (received #{@approved_amount_dollars.to_s.truncate(80).inspect})")
      end
    end

    # The override can't be a way around T1's tier cap.
    def amount_within_tier_max
      return if approved_amount_cents.blank? || stage != "design"

      max = reviewable.tier_max_cents
      return if max.nil? || approved_amount_cents <= max

      errors.add(:approved_amount_cents, "exceeds the #{reviewable.tier_label} maximum of $#{reviewable.tier_max_dollars}")
    end

    def stamp_claimed_at
      self.claimed_at = Time.current
    end

    def stamp_decided_at
      self.decided_at = Time.current
    end

    def assign_stardust_earned
      self.stardust_earned = REVIEW_BOUNTY
    end

    def release_reviewable!
      release!
    end

    def return_reviewable!
      reviewable.return_from_second_stage!(feedback: feedback)
    end
  end
end
