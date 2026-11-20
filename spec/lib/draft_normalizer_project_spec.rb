# frozen_string_literal: true

require "rails_helper"

# Project-critique draft fields: the left-pane view (wall / focus) and the
# critic's keep/cut tags keyed by project number.
describe DiscourseNpnCritiqueReply::DraftNormalizer do
  def normalize(payload)
    described_class.normalize(payload, topic_id: 1, user_id: 2)
  end

  it "keeps valid edit tags and normalizes key case" do
    out =
      normalize(
        "project_edit_tags" => {
          "4" => "strongest",
          "1" => "keep",
          "7" => "unsure",
          "9" => "cut",
          "a1" => "bring_in"
        }
      )
    expect(out["project_edit_tags"]).to eq(
      "4" => "strongest",
      "1" => "keep",
      "7" => "unsure",
      "9" => "cut",
      "A1" => "bring_in"
    )
  end

  it "drops tags that don't fit the image kind, unknown tags and bad keys" do
    out =
      normalize(
        "project_edit_tags" => {
          "2" => "bring_in",
          "A2" => "keep",
          "3" => "maybe",
          "0" => "keep",
          "image 5" => "keep",
          "B1" => "keep"
        }
      )
    expect(out["project_edit_tags"]).to eq({})
  end

  it "defaults edit tags to an empty hash" do
    expect(normalize({})["project_edit_tags"]).to eq({})
    expect(normalize("project_edit_tags" => "nope")["project_edit_tags"]).to eq(
      {}
    )
  end

  it "keeps a valid suggest-a-hang work in progress" do
    out =
      normalize(
        "project_suggestion" => {
          "label" => "Option A\nmore",
          "order" => %w[9 8 a1 9 bogus 0],
          "ranks" => {
            "9" => "strongest",
            "8" => "cut",
            "3" => "keep",
            "a1" => "keep"
          },
          "hang" => {
            "layout" => "lead",
            "wall" => "charcoal",
            "mat" => "nope",
            "mat_width" => 3,
            "frame" => "wood",
            "sizes" => {
              "42" => 36,
              "43" => 17,
              "x" => 20
            }
          }
        }
      )
    expect(out["project_suggestion"]).to eq(
      "label" => "Option A more",
      "order" => %w[9 8 A1],
      "ranks" => {
        "9" => "strongest",
        "A1" => "keep"
      },
      "hang" => {
        "layout" => "lead",
        "wall" => "charcoal",
        "frame" => "wood",
        "mat_width" => 3,
        "sizes" => {
          "42" => 36
        }
      }
    )
  end

  it "keeps a suggested book's spreads and a salon hang's positions" do
    out =
      normalize(
        "project_suggestion" => {
          "order" => %w[2 1 3],
          "hang" => {
            "layout" => "free",
            "book_format" => "square",
            "cover" => 99,
            "spreads" => [
              { "ids" => [11, 10], "side" => "full" },
              { "ids" => [12], "side" => "sideways" },
              { "ids" => [] },
              "nope"
            ],
            "positions" => {
              "10" => [44.26, "58.5"],
              "11" => [-3, 57],
              "x" => [1, 2]
            }
          }
        }
      )
    expect(out["project_suggestion"]["hang"]).to eq(
      "layout" => "free",
      "book_format" => "square",
      "cover" => 99,
      "spreads" => [
        { "ids" => [11, 10] },
        { "ids" => [12], "side" => "right" }
      ],
      "positions" => {
        "10" => [44.3, 58.5]
      }
    )
  end

  it "drops an empty or malformed suggestion" do
    expect(normalize({})["project_suggestion"]).to be_nil
    expect(
      normalize("project_suggestion" => { "order" => [] })["project_suggestion"]
    ).to be_nil
    expect(
      normalize("project_suggestion" => "x")["project_suggestion"]
    ).to be_nil
  end

  it "keeps a valid project view and defaults to the wall" do
    expect(normalize("project_view" => "focus")["project_view"]).to eq("focus")
    expect(normalize("project_view" => "sideways")["project_view"]).to eq(
      "wall"
    )
    expect(normalize({})["project_view"]).to eq("wall")
  end
end
