# frozen_string_literal: true

require "rails_helper"

describe DiscourseNpnCritiqueReply::VoiceNoteNormalizer do
  let(:short_url) { "upload://abc123XYZ.m4a" }
  let(:raw) { "Some thoughts.\n\n![Voice critique|audio](#{short_url})" }

  def normalize(payload, body: raw)
    described_class.normalize(payload, raw: body)
  end

  it "returns nil without a usable audio reference" do
    expect(normalize(nil)).to be_nil
    expect(normalize("nope")).to be_nil
    expect(normalize({ "upload" => { "short_url" => "https://example.com/a.m4a" } })).to be_nil
  end

  it "returns nil when the audio is not embedded in the post body" do
    expect(normalize({ "upload" => { "short_url" => short_url } }, body: "no audio here")).to be_nil
  end

  it "keeps audio-only metadata when there is no pointer timeline" do
    out = normalize({ "upload" => { "short_url" => short_url }, "duration_ms" => "5000" })
    expect(out).to eq(
      "schema_version" => 1,
      "upload" => {
        "short_url" => short_url,
      },
      "duration_ms" => 5000,
    )
  end

  it "keeps well-formed, time-ordered samples and drops the rest" do
    out =
      normalize(
        {
          "upload" => {
            "short_url" => short_url,
            "url" => "/uploads/default/original/1X/a.m4a",
          },
          "stage_image_url" => "/uploads/default/original/1X/b.jpeg",
          "image_index" => 1,
          "timeline" => {
            # ok, gone marker, out of order, off-image, non-numeric,
            # rounded, incomplete trailing sample
            "points" => [0, 10, 20, 50, -1, 5, 40, 1, 1, 60, 1001, 3, 70, "a", 1, 80, 500.4, 999.6, 90, 1],
            "presses" => [30, -1, 5, "x"],
          },
        },
      )

    expect(out["timeline"]["points"]).to eq([0, 10, 20, 50, -1, -1, 80, 500, 1000])
    expect(out["timeline"]["presses"]).to eq([5, 30])
    expect(out["stage_image_url"]).to eq("/uploads/default/original/1X/b.jpeg")
    expect(out["image_index"]).to eq(1)
  end

  it "drops the timeline when the replay image URL is not a plain web URL" do
    out =
      normalize(
        {
          "upload" => {
            "short_url" => short_url,
          },
          "stage_image_url" => "javascript:alert(1)",
          "timeline" => {
            "points" => [0, 1, 1],
          },
        },
      )
    expect(out).not_to have_key("timeline")
    expect(out).not_to have_key("stage_image_url")
  end

  it "caps the number of stored samples" do
    points = (0...5000).flat_map { |i| [i, 1, 1] }
    out =
      normalize(
        {
          "upload" => {
            "short_url" => short_url,
          },
          "stage_image_url" => "/s.jpg",
          "timeline" => {
            "points" => points,
          },
        },
      )
    expect(out["timeline"]["points"].length).to eq(described_class::MAX_POINT_VALUES)
  end

  describe ".normalize_for_draft" do
    it "keeps the recording and timeline without a post body or replay image" do
      out =
        described_class.normalize_for_draft(
          {
            "upload" => {
              "short_url" => short_url,
            },
            "duration_ms" => 4000,
            "image_index" => 2,
            "timeline" => {
              "points" => [0, 1, 1, 100, 2, 2],
              "presses" => [50],
            },
          },
        )
      expect(out["upload"]["short_url"]).to eq(short_url)
      expect(out["image_index"]).to eq(2)
      expect(out["timeline"]).to eq("points" => [0, 1, 1, 100, 2, 2], "presses" => [50])
      expect(out).not_to have_key("stage_image_url")
    end

    it "returns nil when there is no recording" do
      expect(described_class.normalize_for_draft(nil)).to be_nil
      expect(described_class.normalize_for_draft({ "timeline" => { "points" => [0, 1, 1] } })).to be_nil
    end
  end
end
