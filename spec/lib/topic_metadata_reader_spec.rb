# frozen_string_literal: true

require "rails_helper"

describe DiscourseNpnCritiqueReply::TopicMetadataReader do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }

  # `upsert_custom_fields` writes raw values to the DB without going
  # through the field-type descriptor's serialize step, so Array/Hash
  # values would be stored as `Array#to_s` output (not JSON) and the
  # reader would fail to parse them. Pre-encode them here to match how
  # production writes arrive (sibling plugins register the keys as
  # `:json`, so `save_custom_fields` JSON-encodes them on the way in).
  def with_fields(fields)
    encoded =
      fields.transform_values { |v| v.is_a?(Array) || v.is_a?(Hash) ? v.to_json : v }
    topic.upsert_custom_fields(encoded)
    topic.reload
  end

  # ----- Request schema coverage (unchanged from prior step) ---------------

  describe ".read (request fields)" do
    it "returns nil for a topic with no recognised critique fields" do
      expect(described_class.read(topic)).to be_nil
    end

    it "returns nil for a blank topic argument" do
      expect(described_class.read(nil)).to be_nil
    end

    it "serializes the current upstream schema (style + focus)" do
      with_fields(
        "npn_submission_schema_version" => 1,
        "npn_submission_type" => "image_critique",
        "npn_critique_style" => "in_depth",
        "npn_feedback_focus" => "technical_help",
      )

      result = described_class.read(topic)
      expect(result).to include(
        submission_type: "image_critique",
        critique_style: "in_depth",
        feedback_focus: "technical_help",
        schema_version: 1,
      )
    end

    it "treats presence of npn_critique_style alone as a submission topic" do
      with_fields("npn_critique_style" => "in_depth")
      expect(described_class.read(topic)).not_to be_nil
    end

    it "serializes weekly-challenge identity fields when present" do
      with_fields(
        "npn_submission_type" => "weekly_challenge",
        "npn_critique_style" => "standard",
        "npn_feedback_focus" => "artistic_expressive",
        "npn_wordpress_challenge_id" => 1241,
        "npn_weekly_challenge_title" => "Celebrating Biodiversity",
        "npn_weekly_challenge_dates" => "5/24/26 - 5/30/26",
        "npn_wordpress_challenge_url" =>
          "https://www.naturephotographers.network/weekly-challenge/1241/",
      )

      expect(described_class.read(topic)).to include(
        wordpress_challenge_id: 1241,
        weekly_challenge_title: "Celebrating Biodiversity",
        weekly_challenge_dates: "5/24/26 - 5/30/26",
        wordpress_challenge_url:
          "https://www.naturephotographers.network/weekly-challenge/1241/",
      )
    end

    it "ignores topics that only have unrelated custom fields" do
      with_fields("some_other_plugin_field" => "value")
      expect(described_class.read(topic)).to be_nil
    end
  end

  # ----- Image-version coverage --------------------------------------------

  describe "image_versions" do
    fab!(:original_upload) { Fabricate(:upload, user: user) }
    fab!(:revision1_upload) { Fabricate(:upload, user: user) }
    fab!(:revision2_upload) { Fabricate(:upload, user: user) }

    def image_versions(fields)
      with_fields(fields)
      described_class.read(topic)[:image_versions]
    end

    it "emits an empty versions array and nil default when no image metadata is present" do
      with_fields("npn_submission_type" => "image_critique")
      result = described_class.read(topic)[:image_versions]
      expect(result).to eq(default_key: nil, versions: [])
    end

    # -- Original only -----------------------------------------------------

    it "builds a single original version from upload_id (resolves via Upload)" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_original_primary_image_upload_id" => original_upload.id,
        "npn_original_primary_image_url" => "/should/be/ignored.jpg",
      )

      expect(data[:default_key]).to eq("original")
      expect(data[:versions].size).to eq(1)
      original = data[:versions].first
      expect(original).to include(
        key: "original",
        kind: "original",
        label: "Original",
        upload_id: original_upload.id,
        url: original_upload.url,
        revision_number: nil,
        note: nil,
      )
    end

    it "falls back to the stored URL when the Upload no longer exists" do
      missing_id = original_upload.id + 9999
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_original_primary_image_upload_id" => missing_id,
        "npn_original_primary_image_url" => "/uploads/default/original/1X/orig.jpg",
      )

      expect(data[:default_key]).to eq("original")
      expect(data[:versions].first).to include(
        upload_id: missing_id,
        url: "/uploads/default/original/1X/orig.jpg",
      )
    end

    it "uses only the stored URL when no upload_id is set" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_original_primary_image_url" => "/uploads/default/original/1X/orig.jpg",
      )

      expect(data[:default_key]).to eq("original")
      expect(data[:versions].first).to include(
        upload_id: nil,
        url: "/uploads/default/original/1X/orig.jpg",
      )
    end

    it "skips the original version entirely when neither upload nor URL resolves" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_original_primary_image_upload_id" => 9_999_999,
        "npn_original_primary_image_url" => nil,
      )
      expect(data).to eq(default_key: nil, versions: [])
    end

    # -- Original + revisions ----------------------------------------------

    it "appends revisions after the original and defaults to the latest revision" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_original_primary_image_upload_id" => original_upload.id,
        "npn_revision_images" => [
          {
            "revision_number" => 1,
            "upload_id" => revision1_upload.id,
            "image_url" => "/should/be/ignored.jpg",
            "created_at" => "2026-05-27T20:15:00Z",
            "post_id" => 789,
            "user_id" => user.id,
          },
          {
            "revision_number" => 2,
            "upload_id" => revision2_upload.id,
            "image_url" => "/should/be/ignored.jpg",
            "created_at" => "2026-05-28T20:15:00Z",
            "post_id" => 790,
            "user_id" => user.id,
            "note" => "Tried softer mids",
          },
        ],
      )

      expect(data[:default_key]).to eq("revision_2")
      expect(data[:versions].map { |v| v[:key] }).to eq(%w[original revision_1 revision_2])

      r1, r2 = data[:versions][1], data[:versions][2]
      expect(r1).to include(
        kind: "revision",
        label: "Revision 1",
        upload_id: revision1_upload.id,
        url: revision1_upload.url,
        revision_number: 1,
        created_at: "2026-05-27T20:15:00Z",
        post_id: 789,
        user_id: user.id,
        note: nil,
      )
      expect(r2).to include(
        label: "Revision 2",
        upload_id: revision2_upload.id,
        url: revision2_upload.url,
        revision_number: 2,
        note: "Tried softer mids",
      )
    end

    # -- Revisions without original ----------------------------------------

    it "works when revisions exist without an original" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_revision_images" => [
          { "revision_number" => 1, "upload_id" => revision1_upload.id },
          { "revision_number" => 2, "upload_id" => revision2_upload.id },
        ],
      )

      expect(data[:default_key]).to eq("revision_2")
      expect(data[:versions].size).to eq(2)
      expect(data[:versions].first[:key]).to eq("revision_1")
    end

    # -- Malformed JSON ----------------------------------------------------

    it "falls back to no revisions when npn_revision_images is malformed JSON" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_original_primary_image_upload_id" => original_upload.id,
        "npn_revision_images" => "[broken",
      )

      expect(data[:default_key]).to eq("original")
      expect(data[:versions].size).to eq(1)
    end

    it "accepts a JSON-encoded revision string" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_revision_images" =>
          %([{"revision_number":1,"upload_id":#{revision1_upload.id}}]),
      )
      expect(data[:default_key]).to eq("revision_1")
      expect(data[:versions].size).to eq(1)
    end

    # -- Dedup + skip rules -------------------------------------------------

    it "dedupes revisions by upload_id, keeping the first occurrence" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_revision_images" => [
          {
            "revision_number" => 1,
            "upload_id" => revision1_upload.id,
            "note" => "first",
          },
          {
            "revision_number" => 1,
            "upload_id" => revision1_upload.id,
            "note" => "duplicate — should be skipped",
          },
        ],
      )

      expect(data[:versions].size).to eq(1)
      expect(data[:versions].first[:note]).to eq("first")
    end

    it "skips revisions without a usable upload_id and without a usable URL" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_revision_images" => [
          { "revision_number" => 1 },
          { "revision_number" => 2, "upload_id" => revision2_upload.id },
        ],
      )

      expect(data[:default_key]).to eq("revision_2")
      expect(data[:versions].size).to eq(1)
    end

    it "preserves insertion order even when revision_number is missing" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_revision_images" => [
          { "upload_id" => revision1_upload.id }, # no revision_number
          { "upload_id" => revision2_upload.id, "revision_number" => 5 },
        ],
      )

      expect(data[:versions].map { |v| v[:upload_id] }).to eq(
        [revision1_upload.id, revision2_upload.id],
      )
    end

    # -- Latest revision tiebreak ------------------------------------------

    it "uses revision_number as the latest-revision tiebreaker (not array order)" do
      data = image_versions(
        "npn_submission_type" => "image_critique",
        "npn_revision_images" => [
          { "revision_number" => 3, "upload_id" => revision1_upload.id },
          { "revision_number" => 1, "upload_id" => revision2_upload.id },
        ],
      )

      expect(data[:default_key]).to eq("revision_3")
    end
  end
end
