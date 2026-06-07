# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Server-side critique workspace drafts. One draft per (current_user,
  # topic). Storage is PluginStore (see DraftStore); validation/shape
  # comes from DraftNormalizer.
  #
  # Auth/permission flow:
  #   • requires_login — drafts are always tied to current_user
  #   • topic must exist and the user must be able to see it
  #   • update/destroy additionally require can_create_post_on_topic? so
  #     a user can't accumulate drafts against a topic they can't reply
  #     to (we still allow #show on a now-closed topic so the user can
  #     read what they already saved)
  class DraftsController < ::ApplicationController
    requires_plugin DiscourseNpnCritiqueReply::PLUGIN_NAME
    requires_login

    before_action :find_topic
    before_action :ensure_drafts_enabled
    before_action :ensure_can_see_topic
    before_action :ensure_can_reply, only: %i[update destroy]

    # GET /npn-critique-reply/topics/:topic_id/draft
    def show
      draft = DraftStore.fetch(user_id: current_user.id, topic_id: @topic.id)
      if draft
        render json: { draft: draft }
      else
        render json: { draft: nil }
      end
    end

    # PUT /npn-critique-reply/topics/:topic_id/draft
    def update
      payload = params[:draft]
      payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
      normalized =
        DraftNormalizer.normalize(payload, topic_id: @topic.id, user_id: current_user.id)
      saved = DraftStore.save(user_id: current_user.id, topic_id: @topic.id, payload: normalized)
      render json: { draft: saved }
    end

    # DELETE /npn-critique-reply/topics/:topic_id/draft
    def destroy
      DraftStore.delete(user_id: current_user.id, topic_id: @topic.id)
      render json: { success: true }
    end

    private

    def find_topic
      @topic = Topic.find_by(id: params[:topic_id].to_i)
      raise Discourse::NotFound unless @topic
    end

    def ensure_drafts_enabled
      return if SiteSetting.npn_critique_reply_server_drafts_enabled
      raise Discourse::NotFound
    end

    def ensure_can_see_topic
      raise Discourse::InvalidAccess unless guardian.can_see?(@topic)
    end

    def ensure_can_reply
      return if guardian.can_create_post_on_topic?(@topic)
      raise Discourse::InvalidAccess
    end
  end
end
