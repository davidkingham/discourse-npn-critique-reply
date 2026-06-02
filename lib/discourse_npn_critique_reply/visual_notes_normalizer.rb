# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Server-side normalizer for the visual-notes payload attached to a
  # posted critique reply (stored in the `npn_visual_notes` post custom
  # field).
  #
  # The shape mirrors the client-side `buildVisualAnnotationPayload`
  # helper in assets/javascripts/.../npn-critique-reply-annotation-
  # schema.js — `schema_version`, `source`, `visual_output`, and
  # `annotations`. Annotation entries reuse DraftNormalizer's per-kind
  # cleaners so storage rules stay in lockstep with the drafts feature.
  #
  # Never raises. Callers can pass anything; the worst case is a
  # near-empty payload with valid schema_version + server-stamped
  # source.topic_id.
  module VisualNotesNormalizer
    SCHEMA_VERSION = 1
    MAX_STRING_LENGTH = 500

    SOURCE_STRING_KEYS = %w[image_version_key image_version_label source_url].freeze
    VISUAL_OUTPUT_STRING_KEYS = %w[url short_url].freeze

    module_function

    # Returns the canonical payload ready for storage.
    #
    # `topic_id` is taken from the route — we never trust the client to
    # tell us which topic the payload belongs to. The client's
    # source.topic_id is overwritten unconditionally.
    def normalize(payload, topic_id:)
      payload = {} unless payload.is_a?(Hash)
      payload = payload.deep_stringify_keys

      {
        "schema_version" => SCHEMA_VERSION,
        "source" => normalize_source(payload["source"], topic_id: topic_id),
        "visual_output" => normalize_visual_output(payload["visual_output"]),
        "annotations" =>
          DraftNormalizer.normalize_annotations(payload["annotations"]),
      }
    end

    def normalize_source(raw, topic_id:)
      raw = {} unless raw.is_a?(Hash)
      out = {
        "topic_id" => topic_id.to_i,
        "image_version_key" => clean_string(raw["image_version_key"]),
        "image_version_label" => clean_string(raw["image_version_label"]),
        "source_upload_id" => clean_integer(raw["source_upload_id"]),
        "source_url" => clean_string(raw["source_url"]),
      }
      out
    end

    def normalize_visual_output(raw)
      return nil unless raw.is_a?(Hash)
      upload_id = clean_integer(raw["upload_id"])
      url = clean_string(raw["url"])
      short_url = clean_string(raw["short_url"])
      return nil if upload_id.nil? && url.nil? && short_url.nil?
      { "upload_id" => upload_id, "url" => url, "short_url" => short_url }
    end

    def clean_string(value)
      return nil if value.nil?
      s = value.to_s.strip
      return nil if s.empty?
      s.length > MAX_STRING_LENGTH ? s[0, MAX_STRING_LENGTH] : s
    end

    def clean_integer(value)
      return nil if value.nil?
      i = Integer(value)
      i.positive? ? i : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
