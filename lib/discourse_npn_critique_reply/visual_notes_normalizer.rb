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
    # v2 adds the separated written-text fields so overall critique
    # prose and per-image visual-note commentary are stored explicitly
    # instead of being inferred from the posted body by annotation-token
    # position: a top-level `overall_critique_text` plus a `notes` string
    # on each `sources` entry. v1 payloads (no text fields) normalize
    # unchanged — the new fields are simply absent.
    SCHEMA_VERSION = 2
    MAX_STRING_LENGTH = 500
    # Written-text fields (overall critique + per-image notes) get a much
    # larger ceiling than the short metadata strings above. Mirrors the
    # client's MAX_NOTES_TEXT_LENGTH and DraftNormalizer's critique cap.
    MAX_TEXT_LENGTH = 50_000

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

      out = {
        "schema_version" => SCHEMA_VERSION,
        "source" => normalize_source(payload["source"], topic_id: topic_id),
        "visual_output" => normalize_visual_output(payload["visual_output"]),
        "annotations" =>
          DraftNormalizer.normalize_annotations(payload["annotations"]),
      }
      # Optional rotate/flip applied to the primary image during
      # annotation. Only persisted when non-identity, so legacy
      # single-image / un-rotated posts stay byte-identical to before.
      primary_transform =
        DraftNormalizer.normalize_image_transform(payload["image_transform"])
      out["image_transform"] = primary_transform if primary_transform
      # Per-image `sources` array (multi-image critiques). Preserve
      # `image_transform` on each entry alongside `source` +
      # `visual_output`. The flat top-level `image_transform` above
      # mirrors the primary image's entry for legacy single-image
      # readers.
      sources = normalize_sources(payload["sources"], topic_id: topic_id)
      out["sources"] = sources if sources.any?
      # v2 overall critique text — the critic's response to the work as
      # a whole, independent of any image. Persisted only when present
      # so v1-style annotation-only posts stay byte-identical.
      overall = clean_text(payload["overall_critique_text"])
      out["overall_critique_text"] = overall if overall
      out
    end

    def normalize_sources(raw, topic_id:)
      return [] unless raw.is_a?(Array)
      out = []
      raw.each do |entry|
        next unless entry.is_a?(Hash)
        idx = entry["image_index"].to_i
        next if idx.negative?
        source = normalize_source(entry["source"], topic_id: topic_id)
        visual_output = normalize_visual_output(entry["visual_output"])
        transform =
          DraftNormalizer.normalize_image_transform(entry["image_transform"])
        sub = {
          "image_index" => idx,
          "source" => source,
          "visual_output" => visual_output,
        }
        sub["image_transform"] = transform if transform
        # v2 per-image commentary tied to this image's visual notes.
        # Stays attached to the image's block in the final post; absent
        # for v1 payloads and images with no written commentary.
        notes = clean_text(entry["notes"])
        sub["notes"] = notes if notes
        out << sub
      end
      out
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

    # Written-text fields (overall critique + per-image notes). Unlike
    # clean_string, the body is preserved verbatim — internal newlines
    # and meaningful whitespace are kept — but a whitespace-only value
    # collapses to nil so we never store an empty note block. Capped at
    # MAX_TEXT_LENGTH (the long-text ceiling, not the metadata one).
    def clean_text(value)
      return nil if value.nil?
      s = value.to_s
      return nil if s.strip.empty?
      s.length > MAX_TEXT_LENGTH ? s[0, MAX_TEXT_LENGTH] : s
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
