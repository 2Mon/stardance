# frozen_string_literal: true

# Authorizes the T2 (second stage) hardware review queue. Deliberately a
# narrower bar than the T1 queues: holding project_certifier is not enough, the
# whole point of the stage is that a different pair of eyes clears the payout.
class Admin::Certification::SecondStageReviewPolicy < ApplicationPolicy
  def index? = second_stage_reviewer?

  def design? = index?
  def build? = index?
  def next? = index?

  def show? = second_stage_reviewer? && not_own_project?

  # Taking the review to decide it. Same bar as deciding, minus the claim: the
  # T1 reviewer whose call this checks can't hold it, or they'd block everyone
  # else from it until the claim expired.
  def claim? = second_stage_reviewer? && not_own_project? && not_own_first_stage?

  # Recording the T2 verdict: the reviewer must hold the claim, must not be the
  # T1 reviewer whose call they're checking, and must not be on the project.
  # Pending only - a decided review keeps its claim fields, and re-deciding one
  # would return a submission whose payout has already gone out.
  def update?
    return false unless record.pending? && claim?

    record.claim_held_by?(user) || (record.reviewer_id == user.id && record.claim_expired?)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user&.has_role?(:t2_reviewer) || user&.admin?

      scope.for_reviewer(user)
    end
  end

  private

  def second_stage_reviewer?
    user.present? && (user.has_role?(:t2_reviewer) || user.admin?)
  end

  # Approving your own T1 verdict at T2 collapses the two stages into one.
  def not_own_first_stage?
    record.reviewable&.reviewer_id != user.id
  end

  def not_own_project?
    project_id = record.reviewable&.project_id
    return true if project_id.blank?

    !user.memberships.where(project_id: project_id).exists?
  end
end
