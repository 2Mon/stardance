# frozen_string_literal: true

# T2 hardware queue: T1-approved submissions awaiting a second review before payout.
# The payout fires from Certification::SecondStageReview, so PaperTrail stays on the records.
class Admin::Certification::SecondStageReviewsController < Admin::Certification::ApplicationController
  include HardwareReviewRecordings

  # Existing rounds remain accessible even when enrollment is disabled.
  before_action :set_review, only: [ :show, :update, :claim, :skip, :retry_release, :devlogs, :files ]
  before_action :set_body_class

  rescue_from ActionController::ParameterMissing do
    render plain: "This request is missing review details. Reload the review and try again.", status: :bad_request
  end
  rescue_from ActiveRecord::StaleObjectError do
    render plain: "This review changed in another tab. Reload it before deciding.", status: :conflict
  end
  rescue_from ::Certification::SecondStageReview::ReleaseFailed do
    redirect_to second_stage_path, alert: "The decision was saved, but release did not finish. Retry release from this review."
  end

  QUEUE_PAGE_SIZE = 25

  DEVLOG_GALLERY_LIMIT = 12

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

  def next
    authorize ::Certification::SecondStageReview
    release_other_claims

    stage = stage_param
    candidate = ::Certification::SecondStageReview.for_stage(stage).next_eligible(current_user)
    if candidate.nil?
      redirect_to queue_path_for(stage), notice: "The #{stage} T2 queue is empty." and return
    end

    claimed = ::Certification::SecondStageReview.available_for(current_user).atomic_claim!(candidate.id, current_user)
    if claimed
      redirect_to second_stage_path(claimed)
    else
      redirect_to next_admin_certification_second_stage_reviews_path(stage: stage)
    end
  end

  def claim
    claimed = with_versioned_review do
      ::Certification::SecondStageReview.where.not(id: @review.id).release_all_for(current_user)
      ::Certification::SecondStageReview.available_for(current_user).atomic_claim!(@review.id, current_user)
    end
    if claimed
      redirect_to second_stage_path
    else
      redirect_to second_stage_path,
                  alert: "Couldn't claim that review, someone else got it."
    end
  end

  # Hides it from this reviewer for the cooldown; "next" releases the claim for others.
  def skip
    with_versioned_review do
      ::Certification::ReviewSkip.record!(user: current_user, reviewable: @review)
    end
    redirect_to next_admin_certification_second_stage_reviews_path(stage: @review.stage)
  end

  def show
    authorize @review
    load_show_context
  end

  def retry_release
    @review.reviewable.with_review_lock do
      @review.reload
      authorize @review, :show?
      verify_version!
      authorize @review
      @review.release!
    end
    redirect_to second_stage_path, notice: "Release completed."
  end

  def load_show_context
    @reviewable = @review.reviewable
    @project = @reviewable.project
    @owner = @review.owner
    @first_stage_reviewer = @review.first_stage_reviewer
    @review_notes = @project.review_notes.includes(:author).newest_first
    @devlog_count = visible_devlog_posts.count
    load_undo_context

    @prior_reviews = (@project.certification_funding_requests.includes(:reviewer).to_a +
                      @project.ship_reviews.includes(:reviewer).to_a)
      .reject { |r| r == @reviewable }
      .select { |r| r.decided? || r.reversed_at.present? }
      .sort_by(&:created_at)
      .reverse
  end

  # Its own lazy frame: the recording services are network calls the verdict form mustn't wait on.
  def devlogs
    authorize @review, :show?

    @project = @review.reviewable.project
    @owner = @review.owner
    @order = params[:order] == "oldest" ? "oldest" : "newest"
    @devlog_count = visible_devlog_posts.count
    @devlogs = ordered_devlogs

    @lapse_owner_uid = @owner&.hackatime_identity&.uid
    @lapse_timelapses = lapse_timelapses_for(@project, @owner)
    @lookout_recordings = lookout_recordings_for(@project)

    windows = devlog_windows
    @devlog_lapses = ::Certification::DevlogRecordingBucketer.call(
      recordings: @lapse_timelapses, windows: windows
    )
    @devlog_lookouts = ::Certification::DevlogRecordingBucketer.call(
      recordings: @lookout_recordings, windows: windows
    )

    render :devlogs, layout: false
  end

  # Its own lazy frame too: two GitHub calls that mustn't delay the verdict form.
  def files
    authorize @review, :show?

    @project = @review.reviewable.project
    @filenames, @selected_path, @file_body = fetch_repo_files

    @file_tree = build_file_tree(@filenames)
    @open_dirs = @selected_path.to_s.split("/")[0..-2].each_with_object([]) do |segment, dirs|
      dirs << [ dirs.last, segment ].compact.join("/")
    end

    render :files, layout: false
  end

  def update
    saved = with_versioned_review do
      fields = params.require(:certification_second_stage_review)
      verdict = fields[:verdict].to_s
      @review.assign_attributes(feedback: fields[:feedback], internal_reason: fields[:internal_reason])
      unless ::Certification::SecondStageReview::VERDICTS.include?(verdict)
        @review.errors.add(:verdict, "must be approve or return")
        next false
      end
      @review.verdict = verdict
      if verdict == "approved" && @review.stage == "design" && @review.reviewable.issues_grant?
        @review.approved_amount_dollars = fields[:approved_amount_dollars]
      end
      images = fields[:feedback_images]&.compact_blank
      @review.feedback_images.attach(images) if images.present?
      @review.save
    end

    if saved
      redirect_to queue_path_for(@review.stage), notice: verdict_notice(@review)
    else
      flash.now[:alert] = @review.errors.full_messages.to_sentence
      load_show_context
      render :show, status: :unprocessable_entity
    end
  end

  private
  private :load_show_context

  # Never substitute a newer round for the one the reviewer actually saw.
  def set_review
    @review = ::Certification::SecondStageReview.for_project(params[:project_id]).find(params.require(:review_id))
  end

  def verify_version!
    version = Integer(params[:lock_version].to_s, exception: false)
    raise ActiveRecord::StaleObjectError.new(@review, "update") unless version == @review.lock_version
  end

  def with_versioned_review
    @review.reviewable.with_review_lock do
      @review.reviewable.with_lock do
        @review.reload
        authorize @review, :show?
        verify_version!
        authorize @review
        yield
      end
    end
  end

  def visible_devlog_posts
    @project.devlog_posts.joins("INNER JOIN post_devlogs ON post_devlogs.id = posts.postable_id")
      .where(post_devlogs: { deleted_at: nil })
  end

  def ordered_devlogs
    direction = @order == "newest" ? :desc : :asc
    visible_devlog_posts.includes(postable: { attachments_attachments: :blob })
      .reorder(created_at: direction, id: direction).limit(DEVLOG_GALLERY_LIMIT).map(&:postable)
  end

  # Each devlog covers the time since the previous one (half-open, as DevlogRecordingBucketer expects).
  def devlog_windows
    posts = visible_devlog_posts.reorder("posts.created_at ASC, posts.id ASC").to_a
    posts.each_with_index.with_object({}) do |(post, idx), windows|
      since = idx.zero? ? @project.created_at : posts[idx - 1].created_at
      windows[post.postable_id] = { since: since.iso8601, before: post.created_at.iso8601 }
    end
  end

  # The preflight can call HCB, so it only runs for someone allowed to undo.
  def load_undo_context
    return unless Flipper.enabled?(:hardware_review_undo, current_user)
    return unless @reviewable.decided?

    policy_class = @reviewable.is_a?(::Certification::FundingRequest) ?
      Admin::Certification::FundingRequestPolicy : Admin::Certification::ShipPolicy
    return unless policy_class.new(current_user, @reviewable).undo?

    @undo_review = @reviewable
    @undo_preflight = ::Certification::ReviewUndoer.new(@reviewable).preflight
  end

  def undo_review_path(review)
    if review.is_a?(::Certification::FundingRequest)
      undo_admin_certification_funding_request_path(review)
    else
      undo_admin_certification_ship_path(review)
    end
  end
  helper_method :undo_review_path

  # Flat blob paths -> nested hashes (dirs) and full paths (files), folders first.
  def build_file_tree(paths)
    root = {}
    paths.each do |path|
      *dirs, name = path.split("/")
      node = dirs.reduce(root) { |current, dir| current[dir] ||= {} }
      node[name] = path
    end
    sort_file_tree(root)
  end

  def sort_file_tree(node)
    node.sort_by { |name, child| [ child.is_a?(Hash) ? 0 : 1, name.downcase ] }
        .to_h { |name, child| [ name, child.is_a?(Hash) ? sort_file_tree(child) : child ] }
  end

  # Only the GitHub calls are rescued: wrapping the whole action would swallow Pundit's denial.
  def fetch_repo_files
    @file_preview_status = :unavailable
    @file_url = helpers.safe_external_url(@project.repo_url)
    return [ [], nil, nil ] if @project.repo_url.blank?

    host = ::GitHost::Base.for(@project.repo_url)
    unless host.is_a?(::GitHost::Github)
      @file_preview_status = :unsupported_host
      return [ [], nil, nil ]
    end

    names = Rails.cache.fetch([ "t2-repo-files", @project.repo_url ], expires_in: 1.minute) do
      host.fetch_filenames
    end.to_a.sort
    @filenames = names
    selected = params[:path].presence_in(names) || default_readme
    body = selected ? host.fetch_file(selected) : nil
    if selected
      path = selected.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
      @file_url = "https://github.com/#{host.owner}/#{host.repo}/blob/HEAD/#{path}"
    end
    @file_preview_status = :text unless body.nil?
    [ names, selected, body ]
  rescue StandardError => e
    Rails.logger.error("T2 file browser failed for project #{@project&.id}: #{e.message}")
    [ [], nil, nil ]
  end

  # Prefers a root README over a deeper one.
  def default_readme
    @filenames
      .select { |name| File.basename(name).match?(/\Areadme(\.|\z)/i) }
      .min_by { |name| [ name.count("/"), name.length ] }
  end

  def second_stage_path(review = @review)
    admin_certification_second_stage_review_path(review.reviewable.project_id, review_id: review.id)
  end
  helper_method :second_stage_path

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
    scope = scope.current if @status == "pending"
    scope = scope.where(status: @status) unless @status == "all"
    scope = apply_search(scope)
    scope = scope.order(created_at: @sort == "newest" ? :desc : :asc)

    @pagy, @reviews = pagy(scope.preload(:reviewer, reviewable: { project: { memberships: :user } }), limit: QUEUE_PAGE_SIZE)
    ActiveRecord::Associations::Preloader.new(records: @reviews.map(&:first_stage_review), associations: :reviewer).call
    @tab_counts = tab_counts
  end

  # In SQL so pagy's counts stay right; matched per concrete table since reviewable is polymorphic.
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
    scope = policy_scope(::Certification::SecondStageReview).current
    {
      "design" => scope.design_stage.pending.count,
      "build" => scope.build_stage.pending.count
    }
  end

  def release_other_claims
    return if current_user.blank?

    ::Certification::SecondStageReview.release_all_for(current_user)
  end

  def verdict_notice(review)
    if review.approved?
      if review.stage == "build"
        "Cleared. The build is certified."
      elsif review.reviewable.awards_design_kit?
        "Cleared. The builder can claim the kit and start building."
      elsif review.reviewable.issues_grant?
        "Cleared. The grant is on its way and the project has moved to the build stage."
      else
        "Cleared without funding. The project has moved to the build stage."
      end
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
