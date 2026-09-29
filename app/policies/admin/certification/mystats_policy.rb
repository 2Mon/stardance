# frozen_string_literal: true

class Admin::Certification::MystatsPolicy < ApplicationPolicy
  def show? = user&.can_review? || user&.has_role?(:t2_reviewer)
  def create_payout_request? = show?
end
