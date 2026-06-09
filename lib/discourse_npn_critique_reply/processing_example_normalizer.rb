# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Server-side normalizer for the processing-example payload attached
  # to a posted critique reply (stored in the `npn_processing_example`
  # post custom field) and to in-flight workspace drafts.
  #
  # Two canonical shapes are emitted:
  #
  #   * `normalize_for_post(payload, topic_id:)` — the nested wrapper
  #     persisted on a Post custom field. Mirrors the spec in the
  #     task brief:
  #       {
  #         schema_version: 1,
  #         source: { topic_id, image_version_key, image_version_label,
  #                   source_upload_id, source_url },
  #         example_upload: { upload_id, url, short_url, filename },
  #       }
  #
  #   * `normalize_for_draft(payload)` — a flat shape persisted on the
  #     PluginStore-backed workspace draft. Same field set; no
  #     server-stamped topic_id (drafts already key by topic).
  #
  # `topic_id` for the post path is always taken from the route — we
  # never trust the client to tell us which topic the payload belongs
  # to. The client's `source.topic_id` is overwritten unconditionally.
  # Never raises; callers can pass anything.
  module ProcessingExampleNormalizer
    SCHEMA_VERSION = 1
    MAX_STRING_LENGTH = 500
    # Filename is the only string we'd plausibly let exceed the 500-char
    # safety cap — but even Discourse refuses uploads with super-long
    # filenames upstream, so we keep this conservative too.
    MAX_FILENAME_LENGTH = 255

    module_function

    # Returns the canonical post-shape payload ready for storage on a
    # Post custom field. Returns nil when the payload is structurally
    # blank — there's no point persisting a wrapper that has no upload
    # reference.
    def normalize_for_post(payload, topic_id:)
      payload = {} unless payload.is_a?(Hash)
      payload = payload.deep_stringify_keys

      example_upload = normalize_example_upload(payload["example_upload"])
      return nil if blank_upload?(example_upload)

      {
        "schema_version" => SCHEMA_VERSION,
        "source" => normalize_source(payload["source"], topic_id: topic_id),
        "example_upload" => example_upload,
      }
    end

    # Returns the canonical draft-shape payload. Accepts either the
    # nested post shape (in case a future flow round-trips one through
    # the other) or the flat draft shape — both deliver the same
    # output. Returns nil when there's no upload reference to keep.
    def normalize_for_draft(payload)
      payload = {} unless payload.is_a?(Hash)
      payload = payload.deep_stringify_keys

      # Accept either layout. If nested keys are present, lift them
      # into the flat draft shape; otherwise read flat keys directly.
      source = payload["source"]
      upload = payload["example_upload"]

      version_key =
        if source.is_a?(Hash)
          source["image_version_key"]
        else
          payload["source_image_version_key"]
        end
      version_label =
        if source.is_a?(Hash)
          source["image_version_label"]
        else
          payload["source_image_version_label"]
        end
      upload_id =
        upload.is_a?(Hash) ? upload["upload_id"] : payload["upload_id"]
      url = upload.is_a?(Hash) ? upload["url"] : payload["url"]
      short_url =
        upload.is_a?(Hash) ? upload["short_url"] : payload["short_url"]
      filename =
        upload.is_a?(Hash) ? upload["filename"] : payload["filename"]

      out = {
        "source_image_version_key" => clean_string(version_key),
        "source_image_version_label" => clean_string(version_label),
        "upload_id" => clean_integer(upload_id),
        "url" => clean_string(url),
        "short_url" => clean_string(short_url),
        "filename" => clean_filename(filename),
      }

      # Same "no upload reference → nothing worth saving" gate as the
      # post path. Lets the drafts controller treat an explicit-null
      # processing_example as "clear" without special-casing.
      return nil if out["upload_id"].nil? && out["url"].nil? && out["short_url"].nil?

      out
    end

    # --- internals --------------------------------------------------------

    def normalize_source(raw, topic_id:)
      raw = {} unless raw.is_a?(Hash)
      {
        "topic_id" => topic_id.to_i,
        "image_version_key" => clean_string(raw["image_version_key"]),
        "image_version_label" => clean_string(raw["image_version_label"]),
        "source_upload_id" => clean_integer(raw["source_upload_id"]),
        "source_url" => clean_string(raw["source_url"]),
      }
    end

    def normalize_example_upload(raw)
      return nil unless raw.is_a?(Hash)
      out = {
        "upload_id" => clean_integer(raw["upload_id"]),
        "url" => clean_string(raw["url"]),
        "short_url" => clean_string(raw["short_url"]),
        "filename" => clean_filename(raw["filename"]),
      }
      out
    end

    # An "upload reference" is meaningful only when at least one of
    # upload_id / url / short_url is present. A blob of just a filename
    # tells the post body nothing.
    def blank_upload?(upload)
      return true unless upload.is_a?(Hash)
      upload["upload_id"].nil? && upload["url"].nil? && upload["short_url"].nil?
    end

    def clean_string(value)
      return nil if value.nil?
      s = value.to_s.strip
      return nil if s.empty?
      s.length > MAX_STRING_LENGTH ? s[0, MAX_STRING_LENGTH] : s
    end

    def clean_filename(value)
      return nil if value.nil?
      s = value.to_s.strip
      return nil if s.empty?
      s.length > MAX_FILENAME_LENGTH ? s[0, MAX_FILENAME_LENGTH] : s
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
