# frozen_string_literal: true

require "rails_helper"

describe "discourse-npn-critique-reply site settings" do
  it "registers npn_critique_reply_enabled (default: true)" do
    expect(SiteSetting.respond_to?(:npn_critique_reply_enabled)).to eq(true)
    expect(SiteSetting.defaults[:npn_critique_reply_enabled]).to eq(true)
  end

  it "registers npn_critique_reply_enabled_category_ids" do
    expect(SiteSetting.respond_to?(:npn_critique_reply_enabled_category_ids)).to eq(true)
  end

  it "registers npn_critique_reply_allowed_group_ids" do
    expect(SiteSetting.respond_to?(:npn_critique_reply_allowed_group_ids)).to eq(true)
  end

  it "registers npn_critique_reply_debug_enabled (default: false)" do
    expect(SiteSetting.respond_to?(:npn_critique_reply_debug_enabled)).to eq(true)
    expect(SiteSetting.defaults[:npn_critique_reply_debug_enabled]).to eq(false)
  end

  it "registers npn_critique_reply_show_below_op (default: true)" do
    expect(SiteSetting.respond_to?(:npn_critique_reply_show_below_op)).to eq(true)
    expect(SiteSetting.defaults[:npn_critique_reply_show_below_op]).to eq(true)
  end

  it "registers npn_critique_reply_button_label" do
    expect(SiteSetting.respond_to?(:npn_critique_reply_button_label)).to eq(true)
    expect(SiteSetting.defaults[:npn_critique_reply_button_label]).to eq("Start a Critique")
  end

  it "registers npn_critique_reply_visual_notes_enabled (default: false)" do
    expect(SiteSetting.respond_to?(:npn_critique_reply_visual_notes_enabled)).to eq(true)
    expect(SiteSetting.defaults[:npn_critique_reply_visual_notes_enabled]).to eq(false)
  end

  it "registers npn_critique_reply_visual_notes_allowed_group_ids" do
    expect(
      SiteSetting.respond_to?(:npn_critique_reply_visual_notes_allowed_group_ids),
    ).to eq(true)
  end
end
