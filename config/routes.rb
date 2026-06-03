# frozen_string_literal: true

DiscourseNpnCritiqueReply::Engine.routes.draw do
  post "/npn-critique-reply/topics/:topic_id/replies" =>
         "critique_replies#create"

  # Reopen + edit an existing critique reply. Updates the post's raw
  # via PostRevisor and replaces the npn_visual_notes custom field.
  put "/npn-critique-reply/posts/:post_id/critique" =>
        "critique_replies#update"

  # Per-user/per-topic critique workspace draft. Used by the modal to
  # autosave/restore in-progress critiques across browsers and devices.
  scope "/npn-critique-reply/topics/:topic_id" do
    get "/draft" => "drafts#show"
    put "/draft" => "drafts#update"
    delete "/draft" => "drafts#destroy"
  end
end
