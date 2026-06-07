# frozen_string_literal: true

require "rails_helper"

describe DiscourseNpnCritiqueReply::DraftStore do
  fab!(:user)
  fab!(:topic)

  let(:store) { described_class }
  let(:normalizer) { DiscourseNpnCritiqueReply::DraftNormalizer }

  def normalized_payload(overrides = {})
    normalizer.normalize(
      { "critique_text" => "hello" }.merge(overrides),
      topic_id: topic.id,
      user_id: user.id,
    )
  end

  describe ".key_for" do
    it "produces a stable per-user/per-topic key" do
      expect(store.key_for(user_id: 42, topic_id: 7)).to eq("draft:user:42:topic:7")
    end
  end

  describe ".save / .fetch round-trip" do
    it "stores and reads back a normalized draft" do
      payload = normalized_payload("critique_text" => "round trip")
      store.save(user_id: user.id, topic_id: topic.id, payload: payload)
      loaded = store.fetch(user_id: user.id, topic_id: topic.id)
      expect(loaded["critique_text"]).to eq("round trip")
      expect(loaded["topic_id"]).to eq(topic.id)
      expect(loaded["user_id"]).to eq(user.id)
    end

    it "overwrites on subsequent save" do
      store.save(
        user_id: user.id,
        topic_id: topic.id,
        payload: normalized_payload("critique_text" => "first"),
      )
      store.save(
        user_id: user.id,
        topic_id: topic.id,
        payload: normalized_payload("critique_text" => "second"),
      )
      loaded = store.fetch(user_id: user.id, topic_id: topic.id)
      expect(loaded["critique_text"]).to eq("second")
    end

    it "scopes per user" do
      other_user = Fabricate(:user)
      store.save(
        user_id: user.id,
        topic_id: topic.id,
        payload: normalized_payload("critique_text" => "user a"),
      )
      expect(store.fetch(user_id: other_user.id, topic_id: topic.id)).to be_nil
    end
  end

  describe ".delete" do
    it "removes the stored draft" do
      store.save(user_id: user.id, topic_id: topic.id, payload: normalized_payload)
      store.delete(user_id: user.id, topic_id: topic.id)
      expect(store.fetch(user_id: user.id, topic_id: topic.id)).to be_nil
    end

    it "is idempotent when no draft exists" do
      expect { store.delete(user_id: user.id, topic_id: topic.id) }.not_to raise_error
    end
  end

  describe ".exists?" do
    it "returns true when a non-expired draft is stored" do
      store.save(user_id: user.id, topic_id: topic.id, payload: normalized_payload)
      expect(store.exists?(user_id: user.id, topic_id: topic.id)).to eq(true)
    end

    it "returns false when no draft is stored" do
      expect(store.exists?(user_id: user.id, topic_id: topic.id)).to eq(false)
    end

    it "returns false (and prunes) when the stored draft is expired" do
      SiteSetting.npn_critique_reply_draft_ttl_days = 30
      stale = normalized_payload
      stale["updated_at"] = (Time.now.utc - (60 * 24 * 60 * 60)).iso8601
      store.save(user_id: user.id, topic_id: topic.id, payload: stale)
      expect(store.exists?(user_id: user.id, topic_id: topic.id)).to eq(false)
    end

    it "is scoped per user" do
      other_user = Fabricate(:user)
      store.save(user_id: user.id, topic_id: topic.id, payload: normalized_payload)
      expect(store.exists?(user_id: other_user.id, topic_id: topic.id)).to eq(false)
    end
  end

  describe "TTL expiry" do
    it "returns nil and prunes drafts older than the TTL" do
      SiteSetting.npn_critique_reply_draft_ttl_days = 30
      stale = normalized_payload
      stale["updated_at"] = (Time.now.utc - (31 * 24 * 60 * 60)).iso8601
      store.save(user_id: user.id, topic_id: topic.id, payload: stale)
      expect(store.fetch(user_id: user.id, topic_id: topic.id)).to be_nil
      # Confirm prune side-effect: re-saving + reloading inside TTL works.
      store.save(user_id: user.id, topic_id: topic.id, payload: normalized_payload)
      expect(store.fetch(user_id: user.id, topic_id: topic.id)).not_to be_nil
    end

    it "keeps drafts within the TTL window" do
      SiteSetting.npn_critique_reply_draft_ttl_days = 30
      fresh = normalized_payload
      fresh["updated_at"] = (Time.now.utc - (5 * 24 * 60 * 60)).iso8601
      store.save(user_id: user.id, topic_id: topic.id, payload: fresh)
      expect(store.fetch(user_id: user.id, topic_id: topic.id)).not_to be_nil
    end

    it "disables expiry when TTL is 0" do
      SiteSetting.npn_critique_reply_draft_ttl_days = 0
      ancient = normalized_payload
      ancient["updated_at"] = (Time.now.utc - (365 * 24 * 60 * 60)).iso8601
      store.save(user_id: user.id, topic_id: topic.id, payload: ancient)
      expect(store.fetch(user_id: user.id, topic_id: topic.id)).not_to be_nil
    end

    it "is inactivity-based — a new save resets the expiry window" do
      SiteSetting.npn_critique_reply_draft_ttl_days = 30

      # First save: backdate so the draft is on the verge of expiring.
      stale = normalized_payload("critique_text" => "first")
      stale["updated_at"] = (Time.now.utc - (25 * 24 * 60 * 60)).iso8601
      store.save(user_id: user.id, topic_id: topic.id, payload: stale)

      # A second save (modeled on the controller path — re-normalize
      # to stamp a fresh updated_at) should reset the clock.
      refreshed = normalized_payload("critique_text" => "second")
      store.save(user_id: user.id, topic_id: topic.id, payload: refreshed)

      # Advance time by another 25 days. The original draft would now
      # be 50 days old, but because the second save bumped updated_at,
      # the effective age is only 25 days — still within TTL.
      freeze_time((Time.now.utc + (25 * 24 * 60 * 60))) do
        loaded = store.fetch(user_id: user.id, topic_id: topic.id)
        expect(loaded).not_to be_nil
        expect(loaded["critique_text"]).to eq("second")
      end
    end
  end
end

describe DiscourseNpnCritiqueReply::DraftNormalizer do
  subject(:normalizer) { described_class }

  let(:topic_id) { 7 }
  let(:user_id) { 42 }

  def normalize(payload = {})
    normalizer.normalize(payload, topic_id: topic_id, user_id: user_id)
  end

  it "stamps schema_version, topic_id, user_id, updated_at server-side" do
    result = normalize("topic_id" => 999, "user_id" => 999)
    expect(result["schema_version"]).to eq(1)
    expect(result["topic_id"]).to eq(topic_id)
    expect(result["user_id"]).to eq(user_id)
    expect(Time.iso8601(result["updated_at"])).to be_within(2).of(Time.now.utc)
  end

  it "truncates critique_text to the configured cap" do
    long = "x" * (described_class::MAX_CRITIQUE_TEXT_LENGTH + 1000)
    expect(normalize("critique_text" => long)["critique_text"].length).to eq(
      described_class::MAX_CRITIQUE_TEXT_LENGTH,
    )
  end

  it "drops annotations of unknown kinds" do
    result =
      normalize(
        "annotations" => [
          { "kind" => "circle", "x_pct" => 10, "y_pct" => 10 },
          { "kind" => "pin", "number" => 1, "x_pct" => 50, "y_pct" => 50 },
        ],
      )
    expect(result["annotations"].map { |a| a["kind"] }).to eq(["pin"])
  end

  it "drops malformed annotations (missing required fields)" do
    result =
      normalize("annotations" => [{ "kind" => "pin", "x_pct" => 50 }, { "kind" => "pin" }])
    expect(result["annotations"]).to be_empty
  end

  it "enforces per-kind caps" do
    pulls =
      (described_class::MAX_ATTENTION_PULL_COUNT + 3).times.map do |i|
        {
          "kind" => "attention_pull",
          "id" => "ap_#{i}",
          "x_pct" => 10,
          "y_pct" => 10,
          "width_pct" => 5,
          "height_pct" => 5,
        }
      end
    result = normalize("annotations" => pulls)
    expect(result["annotations"].length).to eq(described_class::MAX_ATTENTION_PULL_COUNT)
  end

  it "enforces MAX_CROP_COUNT (first valid wins)" do
    result =
      normalize(
        "annotations" => [
          {
            "kind" => "crop",
            "id" => "crop_a",
            "x_pct" => 0,
            "y_pct" => 0,
            "width_pct" => 50,
            "height_pct" => 50,
          },
          {
            "kind" => "crop",
            "id" => "crop_b",
            "x_pct" => 10,
            "y_pct" => 10,
            "width_pct" => 50,
            "height_pct" => 50,
          },
        ],
      )
    expect(result["annotations"].length).to eq(1)
    expect(result["annotations"].first["id"]).to eq("crop_a")
  end

  it "requires >= 2 points for eye_path; drops otherwise" do
    bad = { "kind" => "eye_path", "points" => [{ "x_pct" => 10, "y_pct" => 10 }] }
    good = {
      "kind" => "eye_path",
      "points" => [
        { "x_pct" => 10, "y_pct" => 10 },
        { "x_pct" => 90, "y_pct" => 90 },
      ],
    }
    expect(normalize("annotations" => [bad])["annotations"]).to be_empty
    expect(normalize("annotations" => [good])["annotations"].length).to eq(1)
  end

  it "clamps pct values to [0, 100]" do
    result =
      normalize(
        "annotations" => [
          { "kind" => "pin", "number" => 1, "x_pct" => -10, "y_pct" => 999 },
        ],
      )
    expect(result["annotations"].first.slice("x_pct", "y_pct")).to eq(
      "x_pct" => 0.0,
      "y_pct" => 100.0,
    )
  end

  it "strips ui keys outside the allowlist" do
    result =
      normalize(
        "ui" => {
          "prompts_hidden" => true,
          "prompts_expanded" => false,
          "evil" => "value",
        },
      )
    expect(result["ui"]).to eq("prompts_hidden" => true, "prompts_expanded" => false)
  end
end
