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

    # PUT /npn-critique-reply/posts/:post_id/critique
    #
    # Reopens a previously-posted critique for editing. Updates the
    # post's raw markdown via the standard PostRevisor (creates a
    # normal Discourse edit revision) and replaces the
    # `npn_visual_notes` custom field with the freshly-normalised
    # payload. Only the post author (or staff) can call this — we
    # require an existing `npn_visual_notes` payload on the post so
    # this endpoint can't be used to retroactively attach
    # metadata to arbitrary posts.
    def update
      post_id = params.require(:post_id).to_i
      raw = params[:raw].to_s.strip

      if raw.blank?
        render_json_error I18n.t("npn_critique_reply.errors.empty_raw"), status: 422
        return
      end

      post = Post.find_by(id: post_id)
      raise Discourse::NotFound unless post

      # Only the author (or staff) — guard against editing someone
      # else's critique even if they happen to have edit permissions
      # through other Discourse mechanisms.
      unless post.user_id == current_user.id || current_user.staff?
        raise Discourse::InvalidAccess
      end

      # Gate the endpoint to existing critique replies. Without this,
      # a user could attach a visual_notes payload to any post they
      # own via this endpoint, bypassing the create path entirely.
      if post.custom_fields["npn_visual_notes"].blank?
        raise Discourse::InvalidAccess
      end

      revisor = PostRevisor.new(post)
      success = revisor.revise!(current_user, raw: raw)

      unless success
        # Failure path returns BEFORE we touch the visual-notes
        # custom field so a 422 leaves the post (raw + custom field)
        # completely unchanged.
        render_json_error post.errors.full_messages.join(". ").presence ||
          I18n.t("npn_critique_reply.errors.create_failed"), status: 422
        return
      end

      sync_visual_notes_for_update(post)

      render json: {
        success: true,
        post: {
          id: post.id,
          post_number: post.post_number,
          topic_id: post.topic_id,
          url: post.url,
        },
      }
    end

    private

    # Edit-mode visual-notes reconciliation. The client always sends a
    # `visual_notes` key in update payloads; the value distinguishes
    # the three cases:
    #
    #   • non-blank payload  → replace the stored npn_visual_notes
    #     custom field with the freshly-normalised wrapper (same
    #     path the create endpoint takes via `attach_visual_notes`).
    #
    #   • explicit null/blank → DELETE the custom field. This is the
    #     signal the modal sends when the user removed every
    #     annotation OR clicked "Continue without visual notes" in
    #     edit mode. Without this branch the post body would become
    #     text-only while the stored payload stayed stale, and the
    #     "Edit Visual Critique" post-menu button (gated on the
    #     custom field's presence via the post serializer) would
    #     keep appearing on a post that no longer has visuals.
    #
    #   • key absent         → no-op. Defensive case for a stale
    #     client (e.g. a browser tab loaded before the deploy that
    #     introduced the always-include-the-key contract). Leaves
    #     the existing field untouched rather than wiping it.
    def sync_visual_notes_for_update(post)
      return unless params.key?(:visual_notes)

      payload = params[:visual_notes]
      if payload.blank?
        clear_visual_notes(post)
        return
      end

      # Non-blank payload: normalize first, then decide. The
      # normaliser may reduce a malformed wrapper (e.g. an empty
      # annotations array with no visual_output) to something
      # effectively blank — in update mode that should ALSO clear,
      # not silently leave a stale field behind. Create mode
      # preserves the older "skip" behavior because there's nothing
      # pre-existing to clear there.
      payload_hash = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload
      normalized =
        VisualNotesNormalizer.normalize(payload_hash, topic_id: post.topic_id)

      if blank_visual_notes?(normalized)
        clear_visual_notes(post)
      else
        post.custom_fields["npn_visual_notes"] = normalized
        post.save_custom_fields
      end
    rescue => e
      Discourse.warn_exception(
        e,
        message: "[discourse-npn-critique-reply] failed to sync " \
          "npn_visual_notes (post=#{post&.id})",
      )
    end

    # Drop the npn_visual_notes post custom field if present. No-op
    # when the field isn't there so a redundant clear doesn't churn
    # the database. Swallowed-and-logged on failure for the same
    # reason `attach_visual_notes` is non-fatal: the user-visible
    # update (the post body) already succeeded, so a custom-field
    # save error shouldn't surface as a 5xx.
    def clear_visual_notes(post)
      return if post.custom_fields["npn_visual_notes"].blank?
      post.custom_fields.delete("npn_visual_notes")
      post.save_custom_fields
    rescue => e
      Discourse.warn_exception(
        e,
        message: "[discourse-npn-critique-reply] failed to clear " \
          "npn_visual_notes (post=#{post&.id})",
      )
    end

    # Persists the structured visual-annotation metadata onto the
    # just-created reply as a JSON post custom field. Never raises:
    # the flattened JPEG + critique text are already valid in the post
    # body, so if storing the metadata fails we log and move on
    # rather than failing the reply the user already posted.
    def attach_visual_notes(post, raw, topic_id:)
      return if raw.blank?

      payload = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      normalized = VisualNotesNormalizer.normalize(payload, topic_id: topic_id)

      # Skip storage when normalisation produced nothing meaningful
      # (e.g. annotations all dropped + no visual_output). Saving an
      # empty wrapper would just be noise for future readers.
      return if blank_visual_notes?(normalized)

      post.custom_fields["npn_visual_notes"] = normalized
      post.save_custom_fields
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
