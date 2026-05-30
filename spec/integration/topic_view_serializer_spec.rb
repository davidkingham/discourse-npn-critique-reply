# frozen_string_literal: true

require "rails_helper"

describe TopicViewSerializer do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post) { Fabricate(:post, topic: topic, user: user) }

  let(:guardian) { Guardian.new(user) }
  let(:topic_view) { TopicView.new(topic.id, user) }

  def serialized
    described_class.new(topic_view, scope: guardian, root: false).as_json
  end

  context "when the plugin is enabled" do
    before { SiteSetting.npn_critique_reply_enabled = true }

    it "omits the attribute (returns nil) for non-submission topics" do
      expect(serialized[:npn_critique_reply]).to be_nil
    end

    it "exposes critique_style + feedback_focus for current-schema topics" do
      topic.upsert_custom_fields(
        "npn_submission_schema_version" => 1,
        "npn_submission_type" => "image_critique",
        "npn_critique_style" => "in_depth",
        "npn_feedback_focus" => "technical_help",
      )

      data = serialized[:npn_critique_reply]
      expect(data).to include(
        submission_type: "image_critique",
        critique_style: "in_depth",
        feedback_focus: "technical_help",
        schema_version: 1,
      )
      # Future-schema fields stay defaulted until upstream writes them.
      expect(data[:critique_type]).to be_nil
      expect(data[:requested_feedback_areas]).to eq([])
      expect(data[:visual_examples_allowed]).to eq(false)
    end

    it "exposes weekly-challenge fields when present" do
      topic.upsert_custom_fields(
        "npn_submission_type" => "weekly_challenge",
        "npn_critique_style" => "standard",
        "npn_feedback_focus" => "artistic_expressive",
        "npn_wordpress_challenge_id" => 1241,
        "npn_weekly_challenge_title" => "Celebrating Biodiversity",
        "npn_weekly_challenge_dates" => "5/24/26 - 5/30/26",
        "npn_wordpress_challenge_url" =>
          "https://www.naturephotographers.network/weekly-challenge/1241/",
      )

      data = serialized[:npn_critique_reply]
      expect(data).to include(
        submission_type: "weekly_challenge",
        critique_style: "standard",
        feedback_focus: "artistic_expressive",
        wordpress_challenge_id: 1241,
        weekly_challenge_title: "Celebrating Biodiversity",
        weekly_challenge_dates: "5/24/26 - 5/30/26",
        wordpress_challenge_url:
          "https://www.naturephotographers.network/weekly-challenge/1241/",
      )
    end

    it "exposes the future schema (critique_type, areas, questions, booleans)" do
      topic.upsert_custom_fields(
        "npn_submission_schema_version" => 2,
        "npn_submission_type" => "image_critique",
        "npn_critique_type" => "artistic_expressive",
        "npn_requested_feedback_areas" => %w[composition processing],
        "npn_specific_critique_questions" => ["Does the darker treatment support the mood?"],
        "npn_visual_examples_allowed" => true,
        "npn_image_reworks_allowed" => false,
        "npn_image_count" => 1,
      )

      data = serialized[:npn_critique_reply]
      expect(data).to include(
        submission_type: "image_critique",
        critique_type: "artistic_expressive",
        requested_feedback_areas: %w[composition processing],
        specific_critique_questions: ["Does the darker treatment support the mood?"],
        visual_examples_allowed: true,
        image_reworks_allowed: false,
        schema_version: 2,
        image_count: 1,
      )
    end
  end

  context "with image_versions" do
    fab!(:original_upload) { Fabricate(:upload, user: user) }
    fab!(:revision_upload) { Fabricate(:upload, user: user) }

    before { SiteSetting.npn_critique_reply_enabled = true }

    it "emits image_versions with the original + latest revision and the right default" do
      topic.upsert_custom_fields(
        "npn_submission_type" => "image_critique",
        "npn_critique_style" => "in_depth",
        "npn_original_primary_image_upload_id" => original_upload.id,
        "npn_revision_images" => [
          {
            "revision_number" => 1,
            "upload_id" => revision_upload.id,
            "created_at" => "2026-05-27T20:15:00Z",
          },
        ],
      )

      data = serialized[:npn_critique_reply][:image_versions]
      expect(data[:default_key]).to eq("revision_1")
      expect(data[:versions].map { |v| v[:key] }).to eq(%w[original revision_1])
      expect(data[:versions].first).to include(
        kind: "original",
        upload_id: original_upload.id,
        url: original_upload.url,
      )
      expect(data[:versions].last).to include(
        kind: "revision",
        upload_id: revision_upload.id,
        url: revision_upload.url,
        revision_number: 1,
      )
    end

    it "emits an empty versions array when no image metadata is present" do
      topic.upsert_custom_fields("npn_submission_type" => "image_critique")
      data = serialized[:npn_critique_reply][:image_versions]
      expect(data).to eq(default_key: nil, versions: [])
    end
  end

  context "when the plugin is disabled" do
    before { SiteSetting.npn_critique_reply_enabled = false }

    it "does not emit the attribute at all" do
      topic.upsert_custom_fields("npn_submission_type" => "image_critique")
      expect(serialized.key?(:npn_critique_reply)).to eq(false)
    end
  end
end
