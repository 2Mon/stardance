class RetainSecondStageReviewRounds < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :certification_second_stage_reviews, :superseded_at, :datetime
    add_column :certification_second_stage_reviews, :released_at, :datetime
    add_column :certification_second_stage_reviews, :first_stage_snapshot, :jsonb

    add_index :certification_second_stage_reviews,
              [ :reviewable_type, :reviewable_id ],
              name: "index_second_stage_reviews_unique_current",
              unique: true, where: "superseded_at IS NULL", algorithm: :concurrently
    remove_index :certification_second_stage_reviews,
                 [ :reviewable_type, :reviewable_id ],
                 name: "index_second_stage_reviews_unique_reviewable", unique: true,
                 algorithm: :concurrently
    # Keep the full reviewable index: history also reads superseded rounds.
  end
end
