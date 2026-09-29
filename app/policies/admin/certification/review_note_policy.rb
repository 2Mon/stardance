# frozen_string_literal: true

class Admin::Certification::ReviewNotePolicy < ApplicationPolicy
  # Same bar as leaving a verdict: a hardware reviewer may add an internal note,
  # but never on a project they're a member of.
  def create?
    t2_reviewer = user&.has_role?(:t2_reviewer) && record.project&.hardware? &&
      Certification::SecondStageReview.for_project(record.project_id).exists?
    (can_review_hardware? || t2_reviewer) && not_own_project?
  end

  private

  def not_own_project?
    return true unless record.respond_to?(:project_id)
    !user.memberships.where(project_id: record.project_id).exists?
  end
end
