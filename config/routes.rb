# frozen_string_literal: true

DiscourseNpnCritiqueReply::Engine.routes.draw do
  post "/npn-critique-reply/topics/:topic_id/replies" =>
         "critique_replies#create"

  # Per-user/per-topic critique workspace draft. Used by the modal to
  # autosave/restore in-progress critiques across browsers and devices.
  scope "/npn-critique-reply/topics/:topic_id" do
    get "/draft" => "drafts#show"
    put "/draft" => "drafts#update"
    delete "/draft" => "drafts#destroy"
  end
end
