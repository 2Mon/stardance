# Development-only sample data for demoing the T2 (second stage) hardware review
# cockpit. The cockpit has a lot of states worth showing at once - an over-tier
# T1 approval, an unverified recipient, a fraud flag, a project that has been
# round the loop before - and ordinary dev data has none of them. Everything is
# tagged with TAG so `t2_demo:unseed` removes exactly what this added.

namespace :t2_demo do
  desc "Create hardware projects sitting in the T2 review queue, one per demo state"
  task seed: :environment do
    abort "Refusing to seed outside development." unless Rails.env.development?

    # Required here rather than at the top: rake loads every task file, so a
    # top-level require would pull libvips into every rake run in production.
    require "vips"
    seeder = T2DemoSeeder.new
    seeder.run
    puts seeder.report
  end

  desc "Remove everything t2_demo:seed created"
  task unseed: :environment do
    abort "Refusing to unseed outside development." unless Rails.env.development?

    puts T2DemoSeeder.new.destroy_all
  end
end

class T2DemoSeeder
  TAG = "t2-demo-seed".freeze
  DOMAIN = "t2demo.seed".freeze
  SLACK_PREFIX = "UT2DEMO".freeze

  # One project per state the cockpit can be in. :stage picks which T2 queue it
  # lands in; the rest drive the panels a reviewer is meant to notice.
  #
  # The repos are real public hardware projects, matched to each title, so the
  # cockpit's file browser renders a genuine tree and README rather than a dead
  # link. All six were checked for an untruncated tree: GitHost::Github falls
  # back to cloning when GitHub truncates one, which a demo has no business
  # doing.
  SCENARIOS = [
    {
      key: "clean",
      title: "Split-Flap Departure Board",
      stage: :design,
      tier: 2,
      requested: 9_500,
      approved: 9_500,
      note: "Six split-flap modules, a custom driver PCB and a 3D printed frame. " \
            "Full BOM and schematic are in the repo under /hardware.",
      feedback: "Scope and costing look right, BOM checks out. Approving at A Tier.",
      repo: "https://github.com/scottbez1/splitflap",
      verified: true
    },
    {
      key: "over-tier",
      title: "Hexapod Walking Robot",
      stage: :design,
      tier: 1,
      requested: 2_400,
      # Approved well over the B Tier ceiling: the exact T1 slip the second
      # stage is staffed to catch, so the tier-max pill goes salmon.
      approved: 7_500,
      note: "Eighteen servos, a custom power distribution board and machined brackets.",
      feedback: "Bumped the amount, the servo quote came in higher than they budgeted.",
      repo: "https://github.com/SmallpTsai/hexapod-v2-7697",
      verified: true
    },
    {
      key: "unverified",
      title: "Nixie Tube Desk Clock",
      stage: :design,
      tier: 2,
      requested: 11_000,
      approved: 11_000,
      note: "Four IN-14 tubes, a boost converter for the 170V rail, walnut case.",
      feedback: "Nice build plan. Watch the high-voltage section.",
      repo: "https://github.com/drkmsmithjr/ETANixieClock",
      # The grant would go to someone who has not cleared identity.
      verified: false
    },
    {
      key: "fraud-flagged",
      title: "Desktop CNC Mill",
      stage: :design,
      tier: 3,
      requested: 19_000,
      approved: 19_000,
      note: "Steel frame, three NEMA 23 steppers, GRBL controller.",
      feedback: "Big ask but the tier fits. Approving.",
      repo: "https://github.com/gnea/grbl",
      verified: true,
      fraud: "Same BOM and photos as two other submissions this week. " \
             "Worth a second look before the grant goes out."
    },
    {
      key: "repeat",
      title: "LoRa Mesh Tracker",
      stage: :design,
      tier: 1,
      requested: 2_200,
      approved: 2_200,
      note: "Third attempt. Trimmed the scope to one board and one enclosure.",
      feedback: "Much tighter than last time. Approving.",
      repo: "https://github.com/richonguzman/LoRa_APRS_Tracker",
      verified: true,
      # Earlier returns, so the "Earlier reviews" panel and the notes ledger
      # both have something in them.
      returns: [
        "Scope is three projects in a trench coat. Pick one and re-submit.",
        "Still no BOM. I can't cost this without one."
      ],
      notes: [
        "Second return. If the next one is still unscoped, send them to #hardware for help.",
        "They rewrote the whole proposal after the last return, much better."
      ]
    },
    {
      key: "build",
      title: "Macro Pad with OLED",
      stage: :build,
      tier: 1,
      requested: 2_000,
      approved: 2_000,
      note: "Twelve keys, rotary encoder, small OLED.",
      feedback: "Build matches the design. Looks good.",
      repo: "https://github.com/manelto/MacroPad-keybow2040-",
      verified: true
    }
  ].freeze

  # Devlog bodies, each with a generated stand-in photo so the rail's strip and
  # its lightbox have something distinguishable to open. Colours come from the
  # Stardance palette; two per devlog, so the horizontal strip is worth
  # scrolling and the carousel has more than one frame.
  DEVLOGS = [
    [ "Parts arrived. Laid everything out and checked it against the BOM before " \
      "touching a soldering iron.", %w[#81FFFF #95DBFF], 2.5 ],
    [ "First board populated. Two bridged pins on the regulator, found them with " \
      "a continuity check rather than the magic smoke.", %w[#EBB7FF #FF8D9D], 3.0 ],
    [ "Enclosure printed at 0.2mm. Fits, but the standoffs are a millimetre short " \
      "so the lid bows. Reprinting tonight.", %w[#FFE564 #FFD598], 1.75 ],
    [ "It works end to end. Firmware is rough but everything talks to everything.",
      %w[#FFF8D5 #81FFFF #EBB7FF], 4.25 ]
  ].freeze

  def initialize(now: Time.current)
    @now = now
    @counts = Hash.new(0)
    @after_commit = []
  end

  def run
    ActiveRecord::Base.transaction do
      build_reviewers
      SCENARIOS.each { |scenario| build_scenario(scenario) }
    end
    # A funding request opens its second stage from after_save_commit, so inside
    # the transaction above there is nothing yet to clear. The build scenario's
    # design stage is therefore cleared out here, once those callbacks have run.
    @after_commit.each(&:call)
    self
  end

  def report
    lines = [ "Seeded:" ] + @counts.sort.map { |name, count| format("  %-26s %s", name, count) }
    lines += [
      "",
      "Sign in as the demo T2 reviewer: /dev_login/#{@t2_reviewer.id}",
      "Design queue: /admin/certification/t2/design",
      "Build queue:  /admin/certification/t2/build"
    ]
    lines.join("\n")
  end

  def destroy_all
    removed = Hash.new(0)
    ActiveRecord::Base.transaction do
      users = User.where("email LIKE ?", "%@#{DOMAIN}")
      projects = Project.where("projects.description LIKE ?", "%#{TAG}%")
      project_ids = projects.select(:id)
      # Materialised now, not as a subquery: the posts that name these devlogs
      # are deleted below, and a lazy relation would then match nothing and
      # leave the devlog rows orphaned.
      devlog_ids = Post.where(project_id: project_ids, postable_type: "Post::Devlog").pluck(:postable_id)
      funding = Certification::FundingRequest.where(project_id: project_ids)
      ships = Certification::Ship.where(project_id: project_ids)

      removed["second_stage_reviews"] =
        Certification::SecondStageReview
          .where(reviewable_type: "Certification::FundingRequest", reviewable_id: funding.select(:id))
          .delete_all +
        Certification::SecondStageReview
          .where(reviewable_type: "Certification::Ship", reviewable_id: ships.select(:id))
          .delete_all
      removed["review_notes"] = Certification::ReviewNote.where(project_id: project_ids).delete_all
      removed["reports"] = Project::Report.where(project_id: project_ids).delete_all
      removed["funding_requests"] = funding.delete_all
      removed["ship_certifications"] = ships.delete_all
      removed["memberships"] = Project::Membership.where(project_id: project_ids).delete_all
      # Opening a demo project's page records a view, whose foreign key would
      # otherwise block the post delete below.
      removed["post_views"] = PostView.where(post_id: Post.where(project_id: project_ids).select(:id)).delete_all
      removed["posts"] = Post.where(project_id: project_ids).delete_all
      # purge_later would outlive the transaction, so the attached demo images
      # go with their devlogs here.
      Post::Devlog.where(id: devlog_ids).find_each { |devlog| devlog.attachments.each(&:purge) }
      removed["devlogs"] = Post::Devlog.where(id: devlog_ids).delete_all
      removed["projects"] = projects.destroy_all.size
      # destroy_all rather than delete_all: creating a user spins up dependent
      # records holding foreign keys back to it.
      removed["users"] = users.destroy_all.size
    end

    ([ "Removed:" ] + removed.sort.map { |name, count| format("  %-26s %s", name, count) }).join("\n")
  end

  private

  def track(name, count = 1) = @counts[name] += count

  # The T1 reviewer whose call the demo T2 reviewer is checking. Deliberately
  # not the person doing the demo: SecondStageReviewPolicy#update? refuses to
  # let anyone clear their own T1 verdict.
  def build_reviewers
    @t1_reviewer = find_or_create_user("t1-reviewer", "t2demo_t1_reviewer",
                                       roles: [ "project_certifier" ])
    @t2_reviewer = find_or_create_user("t2-reviewer", "t2demo_t2_reviewer",
                                       roles: [ "t2_reviewer" ])
    @fraud_reporter = find_or_create_user("fraud-reporter", "t2demo_fraud_reporter",
                                          roles: [ "project_certifier" ])
  end

  def find_or_create_user(slug, display_name, roles: [], verified: true)
    User.find_by(email: "#{slug}@#{DOMAIN}") || begin
      track("users")
      User.create!(
        email: "#{slug}@#{DOMAIN}",
        display_name: display_name,
        slack_id: "#{SLACK_PREFIX}#{slug.upcase.delete('-').first(8)}",
        granted_roles: roles,
        verification_status: verified ? "verified" : "needs_submission"
      )
    end
  end

  def build_scenario(scenario)
    owner = find_or_create_user("builder-#{scenario[:key]}", "t2demo_#{scenario[:key]}",
                                verified: scenario[:verified])
    project = create_project(scenario, owner)
    create_devlogs(project, owner)

    Array(scenario[:notes]).each do |body|
      Certification::ReviewNote.create!(project: project, author: @t1_reviewer, body: body)
      track("review_notes")
    end

    if scenario[:fraud]
      Project::Report.create!(project: project, reporter: @fraud_reporter,
                              reason: "fraud", details: scenario[:fraud], status: :pending)
      track("fraud_reports")
    end

    # The returns that came before the approval, so the cockpit's history panel
    # has a loop to show rather than a single verdict.
    Array(scenario[:returns]).each_with_index do |feedback, i|
      returned_funding_request(scenario, project, owner, feedback, i)
    end

    approved = approved_funding_request(scenario, project, owner)
    scenario[:stage] == :build ? certify_build(scenario, project, approved) : approved
    track("scenarios")
  end

  def create_project(scenario, owner)
    project = Project.create!(
      title: scenario[:title],
      description: "#{TAG} — #{scenario[:title]}. Sample hardware project for demoing the T2 review cockpit.",
      repo_url: scenario[:repo],
      hardware_stage: scenario[:stage] == :build ? "build" : "design"
    )
    Project::Membership.create!(project: project, user: owner, role: :owner)
    track("projects")
    project
  end

  # Spread backwards from now so each devlog covers a distinct window - that is
  # what the rail buckets recordings into, and what its per-devlog hours read.
  def create_devlogs(project, owner)
    DEVLOGS.each_with_index do |(body, colours, hours), i|
      posted_at = @now - (DEVLOGS.size - i).days

      devlog = Post::Devlog.new(body: body, duration_seconds: (hours * 3600).to_i)
      devlog.save!(validate: false)
      colours.each_with_index { |colour, n| attach_swatch(devlog, colour, "#{i}-#{n}") }

      post = Post.new(project: project, user: owner, postable: devlog)
      post.save!(validate: false)
      post.update_columns(created_at: posted_at, updated_at: posted_at)
      track("devlogs")
    end
  end

  # A flat colour plate, generated rather than shipped: the repo's own art is
  # mostly transparent and reads as an empty square in the rail, and committing
  # sample photos for a dev-only task isn't worth the repo weight.
  def attach_swatch(devlog, hex, suffix)
    rgb = hex.delete("#").scan(/../).map { |pair| pair.to_i(16) }
    image = Vips::Image.black(640, 480).add(rgb).cast("uchar").copy(interpretation: :srgb)

    devlog.attachments.attach(
      io: StringIO.new(image.write_to_buffer(".png")),
      filename: "#{TAG}-#{suffix}.png",
      content_type: "image/png"
    )
    track("devlog_images")
  end

  def returned_funding_request(scenario, project, owner, feedback, index)
    at = @now - (6 - index).weeks
    request = Certification::FundingRequest.new(
      project: project, user: owner, complexity_tier: scenario[:tier],
      requested_amount_cents: scenario[:requested],
      submitter_note: scenario[:note]
    )
    request.save!(validate: false)
    # update_columns rather than a verdict: a returned request must not re-run
    # the notify/Slack callbacks every time the demo data is rebuilt.
    request.update_columns(status: Certification::FundingRequest.statuses[:returned],
                           reviewer_id: @t1_reviewer.id, feedback: feedback,
                           decided_at: at, created_at: at - 3.days, updated_at: at)
    track("returned_requests")
    request
  end

  # The approval that opens the second stage. Saved with callbacks so the
  # model's own after_save_commit opens the T2 review exactly as production
  # does, rather than this task inventing one.
  #
  # Validation is skipped on purpose. FundingRequest rejects an approved amount
  # over the tier ceiling, so the "over-tier" scenario can only be built by
  # going round it - which is the point: the cockpit's tier-max warning is the
  # backstop for a figure that reached the database some other way (a tier
  # edited after approval, a backfill, a console fix), and the demo needs that
  # state on screen.
  def approved_funding_request(scenario, project, owner)
    request = Certification::FundingRequest.new(
      project: project, user: owner, complexity_tier: scenario[:tier],
      requested_amount_cents: scenario[:requested],
      submitter_note: scenario[:note]
    )
    request.save!(validate: false)
    request.assign_attributes(status: :approved, reviewer: @t1_reviewer,
                              approved_amount_cents: scenario[:approved],
                              feedback: scenario[:feedback], decided_at: @now - 2.days)
    request.save!(validate: false)
    track("approved_requests")
    request
  end

  # A build-stage demo needs its design stage already cleared, otherwise the
  # project shows up in both queues at once.
  def certify_build(scenario, project, funding_request)
    @after_commit << lambda do
      cleared = funding_request.reload.second_stage_review
      next if cleared.nil? || cleared.decided?

      cleared.assign_attributes(reviewer: @t2_reviewer, verdict: "approved",
                                feedback: "Design cleared at T2. On to the build.")
      cleared.save!(validate: false)
      track("cleared_design_stages")
    end

    ship = Certification::Ship.new(project: project)
    ship.save!(validate: false)
    ship.assign_attributes(status: :approved, reviewer: @t1_reviewer,
                           feedback: scenario[:feedback], decided_at: @now - 1.day)
    ship.save!(validate: false)
    track("ship_certifications")
    ship
  end
end
