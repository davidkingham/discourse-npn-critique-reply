# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Creates a normal Discourse reply on behalf of the critique workspace
  # modal. We go through PostCreator unchanged — no skip_guardian, no
  # skip_validations — so the reply is indistinguishable from one posted
  # via the standard composer (same cooking, same rate limits, same
  # MessageBus events, same notifications).
  #
  # The endpoint is intentionally small: validate the topic + permission +
  # raw text, hand off to PostCreator, translate its errors into a JSON
  # response. The client is the only thing that knows about prompts /
  # revision prefixes / modal state — the server just sees raw text.
  class CritiqueRepliesController < ::ApplicationController
    requires_plugin DiscourseNpnCritiqueReply::PLUGIN_NAME
    requires_login

    # POST /npn-critique-reply/topics/:topic_id/replies
    def create
      topic_id = params.require(:topic_id).to_i
      raw = params[:raw].to_s.strip

      if raw.blank?
        render_json_error I18n.t("npn_critique_reply.errors.empty_raw"), status: 422
        return
      end

      topic = Topic.find_by(id: topic_id)
      raise Discourse::NotFound unless topic

      # Explicit Guardian check gives a clean 403 with a friendly message;
      # PostCreator would also refuse, but with a less specific error.
      unless guardian.can_create_post_on_topic?(topic)
        render_json_error I18n.t("npn_critique_reply.errors.cannot_reply"), status: 403
        return
      end

      creator = PostCreator.new(current_user, raw: raw, topic_id: topic.id)
      post = creator.create

      if creator.errors.present?
        render_json_error creator.errors.full_messages.join(". "), status: 422
        return
      end

      unless post
        # PostCreator can return nil without populating errors in odd
        # edge cases (e.g. a model callback aborts silently). Surface a
        # generic message so the modal never gets a 200 with no post.
        render_json_error I18n.t("npn_critique_reply.errors.create_failed"), status: 422
        return
      end

      render json: {
        success: true,
        post: {
          id: post.id,
          post_number: post.post_number,
          topic_id: topic.id,
          url: post.url,
        },
      }
    end
  end
end
