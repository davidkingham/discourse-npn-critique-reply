# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # PluginStore wrapper for the per-user/per-topic critique workspace
  # draft. One active draft per (user_id, topic_id); save overwrites,
  # delete removes, and load returns nil for missing or expired drafts.
  #
  # We deliberately use PluginStore rather than a new table — drafts are
  # small (≤ a few KB), short-lived, low-volume, and we want zero
  # migration risk. If draft volume ever grows beyond what PluginStore
  # comfortably supports, swap this module's internals for a table
  # without touching callers.
  module DraftStore
    PLUGIN_NAME = "discourse-npn-critique-reply"

    module_function

    def key_for(user_id:, topic_id:)
      "draft:user:#{user_id.to_i}:topic:#{topic_id.to_i}"
    end

    # Returns the stored draft hash, or nil when no draft exists or the
    # draft is older than the configured TTL (in which case it is also
    # deleted as a side-effect).
    def load(user_id:, topic_id:)
      key = key_for(user_id: user_id, topic_id: topic_id)
      raw = PluginStore.get(PLUGIN_NAME, key)
      return nil unless raw.is_a?(Hash)

      if expired?(raw)
        PluginStore.remove(PLUGIN_NAME, key)
        return nil
      end

      raw
    end

    # Stores the already-normalized payload. Callers MUST run the
    # payload through DraftNormalizer first — we don't re-normalize here
    # so the controller has a single source of validation truth.
    def save(user_id:, topic_id:, payload:)
      key = key_for(user_id: user_id, topic_id: topic_id)
      PluginStore.set(PLUGIN_NAME, key, payload)
      payload
    end

    def delete(user_id:, topic_id:)
      key = key_for(user_id: user_id, topic_id: topic_id)
      PluginStore.remove(PLUGIN_NAME, key)
      true
    end

    def expired?(payload)
      ttl_days = SiteSetting.npn_critique_reply_draft_ttl_days.to_i
      return false if ttl_days <= 0

      updated_at = payload["updated_at"] || payload[:updated_at]
      return false if updated_at.blank?

      cutoff = Time.now.utc - (ttl_days * 24 * 60 * 60)
      Time.iso8601(updated_at.to_s) < cutoff
    rescue ArgumentError
      # Unparseable timestamp — treat as expired so we don't keep junk
      # around forever.
      true
    end
  end
end
