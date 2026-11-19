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

  it "keeps a valid project view and defaults to the wall" do
    expect(normalize("project_view" => "focus")["project_view"]).to eq("focus")
    expect(normalize("project_view" => "sideways")["project_view"]).to eq(
      "wall"
    )
    expect(normalize({})["project_view"]).to eq("wall")
  end
end
