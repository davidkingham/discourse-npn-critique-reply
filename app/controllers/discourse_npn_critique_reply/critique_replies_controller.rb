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

      attach_visual_notes(post, params[:visual_notes], topic_id: topic.id)

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

    private

    # Persists the structured visual-annotation metadata onto the
    # just-created reply as a JSON post custom field. Never raises:
    # the flattened JPEG + critique text are already valid in the post
    # body, so if storing the metadata fails we log and move on
    # rather than failing the reply the user already posted.
    def attach_visual_notes(post, raw, topic_id:)
      debug = SiteSetting.npn_critique_reply_debug_enabled
      if debug
        Rails.logger.info(
          "[npn-critique-reply] attach_visual_notes: " \
            "raw_class=#{raw.class.name} raw_blank=#{raw.blank?} " \
            "post=#{post&.id}",
        )
      end

      return if raw.blank?

      payload = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      normalized = VisualNotesNormalizer.normalize(payload, topic_id: topic_id)

      if debug
        Rails.logger.info(
          "[npn-critique-reply] attach_visual_notes: normalized " \
            "annotations=#{normalized["annotations"]&.length} " \
            "visual_output_present=#{normalized["visual_output"].present?}",
        )
      end

      # Skip storage when normalisation produced nothing meaningful
      # (e.g. annotations all dropped + no visual_output). Saving an
      # empty wrapper would just be noise for future readers.
      if blank_visual_notes?(normalized)
        Rails.logger.info(
          "[npn-critique-reply] attach_visual_notes: skipping blank payload",
        ) if debug
        return
      end

      post.custom_fields["npn_visual_notes"] = normalized
      post.save_custom_fields

      Rails.logger.info(
        "[npn-critique-reply] attach_visual_notes: saved (post=#{post.id})",
      ) if debug
    rescue => e
      Discourse.warn_exception(
        e,
        message: "[discourse-npn-critique-reply] failed to attach " \
          "npn_visual_notes (post=#{post&.id})",
      )
    end

    def blank_visual_notes?(payload)
      return true unless payload.is_a?(Hash)
      annotations = payload["annotations"]
      visual_output = payload["visual_output"]
      annotations.blank? && visual_output.blank?
    end
  end
end
