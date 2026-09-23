# frozen_string_literal: true

# Lapse timelapses + Lookout screen recordings for one hardware project.
#
# Extracted so the T2 second-stage review can show the same evidence the T1 dash
# shows (HardwareReviewQueue still has its own copy). The cache namespace is
# deliberately shared with that copy: the key is the project, so a T2 reviewer
# opening a review right after the T1 page reuses the warm entry rather than
# hitting both services again.
module HardwareReviewRecordings
  extend ActiveSupport::Concern

  RECORDINGS_CACHE_TTL = 1.minute

  private

  # owner is passed in rather than derived: the caller decides whose recordings
  # these are, and the same user must be used for the Telescreen link, or the
  # page would credit one builder's timelapses to another.
  def lapse_timelapses_for(project, owner)
    Rails.cache.fetch([ "hardware_review_recordings", "lapse", project.id ], expires_in: RECORDINGS_CACHE_TTL) do
      LapseService.timelapses_for_project(
        hackatime_user_id: owner&.hackatime_identity&.uid,
        project_keys: project.hackatime_keys
      )
    end
  end

  def lookout_recordings_for(project)
    Rails.cache.fetch([ "hardware_review_recordings", "lookout", project.id ], expires_in: RECORDINGS_CACHE_TTL) do
      LookoutService.recordings_for_project(project)
    end
  end
end
