# frozen_string_literal: true

# The T2 hardware queue: submissions a project_certifier has already approved at
# T1, waiting on a second pair of eyes before anything is paid out. Visible only
# to t2_reviewer (and admins) - see Admin::Certification::SecondStageReviewPolicy.
#
# The verdict is recorded on the Certification::SecondStageReview; the payout
# (HCB grant, ship certification cascade) is fired by that model, not here, so
# PaperTrail and the deferred callbacks stay attached to the review records.
class Admin::Certification::SecondStageReviewsController < Admin::Certification::ApplicationController
  before_action -> { head :not_found unless Flipper.enabled?(:hardware_t2_review) }
  before_action :set_review, only: [ :show, :update, :claim ]
  before_action :set_body_class

  QUEUE_PAGE_SIZE = 25

  def index
    authorize ::Certification::SecondStageReview
    redirect_to design_admin_certification_second_stage_reviews_path(
      params.permit(:status, :sort, :search).to_h.compact_blank
    )
  end

  def design
    load_queue(:design)
    render :queue
  end

  def build
    load_queue(:build)
    render :queue
  end

  # Hands the reviewer the oldest unclaimed second stage in the queue they
  # started from, claiming it so two T2 reviewers don't land on the same one.
  def next
    authorize ::Certification::SecondStageReview
    release_other_claims

    stage = stage_param
    candidate = ::Certification::SecondStageReview.for_stage(stage).next_eligible(current_user)
    if candidate.nil?
      redirect_to queue_path_for(stage), notice: "The #{stage} T2 queue is empty." and return
    end

    claimed = ::Certification::SecondStageReview.atomic_claim!(candidate.id, current_user)
    if claimed
      redirect_to admin_certification_second_stage_review_path(claimed)
    else
      redirect_to next_admin_certification_second_stage_reviews_path(stage: stage)
    end
  end

  # Taking the review, so two T2 reviewers don't decide the same one. Mirrors
  # the T1 claim (Admin::Certification::FundingRequests::ClaimsController):
  # opening a review is browsing, claiming it is committing to decide it.
  def claim
    authorize @review

    ::Certification::SecondStageReview.release_all_for(current_user)
    claimed = ::Certification::SecondStageReview.atomic_claim!(@review.id, current_user)
    if claimed
      redirect_to admin_certification_second_stage_review_path(@review)
    else
      redirect_to admin_certification_second_stage_review_path(@review),
                  alert: "Couldn't claim that review, someone else got it."
    end
  end

  def show
    authorize @review
    @reviewable = @review.reviewable
    @project = @reviewable.project
    @owner = @review.owner
    @first_stage_reviewer = @review.first_stage_reviewer
    @review_notes = @project.review_notes.includes(:author).newest_first
    @devlog_count = @project.devlog_posts.count

    # Everything this project has already been through, newest first: earlier
    # funding requests and ship certifications, including the returns that sent
    # the builder back. The T2 reviewer is checking a verdict in context, so a
    # project that has been round this loop before is the single most useful
    # thing to surface.
    @prior_reviews = (@project.certification_funding_requests.includes(:reviewer).to_a +
                      @project.ship_reviews.includes(:reviewer).to_a)
      .reject { |r| r == @reviewable }
      .select { |r| r.decided? || r.reversed_at.present? }
      .sort_by(&:created_at)
      .reverse
  end

  def update
    authorize @review

    verdict = params.dig(:certification_second_stage_review, :verdict).to_s
    unless ::Certification::SecondStageReview::VERDICTS.include?(verdict)
      redirect_to admin_certification_second_stage_review_path(@review),
                  alert: "Pick approve or return." and return
    end

    @review.assign_attributes(
      verdict: verdict,
      feedback: params.dig(:certification_second_stage_review, :feedback),
      internal_reason: params.dig(:certification_second_stage_review, :internal_reason)
    )

    if @review.save
      redirect_to queue_path_for(@review.stage), notice: verdict_notice(@review)
    else
      redirect_to admin_certification_second_stage_review_path(@review),
                  alert: @review.errors.full_messages.to_sentence
    end
  end

  private

  def set_review
    @review = ::Certification::SecondStageReview.find(params[:id])
  end

  def stage_param
    params[:stage].presence_in(%w[design build]) || "design"
  end

  def queue_path_for(stage)
    stage.to_s == "design" ?
      design_admin_certification_second_stage_reviews_path :
      build_admin_certification_second_stage_reviews_path
  end
  helper_method :queue_path_for

  def load_queue(stage)
    authorize ::Certification::SecondStageReview

    @stage = stage.to_s
    @status = params[:status].presence_in(%w[pending approved returned all]) || "pending"
    @sort = params[:sort] == "newest" ? "newest" : "oldest"
    @search = params[:search].to_s.strip

    scope = policy_scope(::Certification::SecondStageReview).for_stage(@stage)
    scope = scope.where(status: @status) unless @status == "all"
    scope = apply_search(scope)
    scope = scope.order(created_at: @sort == "newest" ? :desc : :asc)

    @pagy, @reviews = pagy(scope, limit: QUEUE_PAGE_SIZE)
    @tab_counts = tab_counts
  end

  # Searching by project title. Filtered in SQL rather than in Ruby after
  # paginating: narrowing the page's own array would leave pagy counting rows it
  # had already dropped, so the page links would be wrong.
  #
  # The project sits behind a polymorphic association, so this joins each
  # concrete review table to projects and matches ids, rather than trying to
  # join `reviewable` directly.
  def apply_search(scope)
    return scope if @search.blank?

    like = "%#{@search}%"
    funding_ids = ::Certification::FundingRequest.joins(:project)
      .where("projects.title ILIKE ?", like).select(:id)
    ship_ids = ::Certification::Ship.joins(:project)
      .where("projects.title ILIKE ?", like).select(:id)

    scope.where(
      "(reviewable_type = 'Certification::FundingRequest' AND reviewable_id IN (:funding)) OR " \
      "(reviewable_type = 'Certification::Ship' AND reviewable_id IN (:ships))",
      funding: funding_ids, ships: ship_ids
    )
  end

  def tab_counts
    scope = policy_scope(::Certification::SecondStageReview)
    {
      "design" => scope.design_stage.pending.count,
      "build" => scope.build_stage.pending.count
    }
  end

  # Asking for the next review hands the current one back, so a T2 reviewer who
  # wanders off doesn't hold a claim for the full CLAIM_TTL.
  def release_other_claims
    return if current_user.blank?

    ::Certification::SecondStageReview.release_all_for(current_user)
  end

  def verdict_notice(review)
    if review.approved?
      review.stage == "design" ?
        "Cleared. The grant is on its way and the project has moved to the build stage." :
        "Cleared. The build is certified."
    else
      "Returned to the builder."
    end
  end

  # The .app-layout wrapper reserves the sidebar gutter itself; this body class
  # zeroes the body's own sidebar margin so the two don't stack into a huge gap.
  def set_body_class
    @body_class = "app-layout-page"
  end
end
