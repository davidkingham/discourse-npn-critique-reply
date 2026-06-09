# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Reads the topic custom fields written by discourse-npn-submissions and
  # discourse-revised-critique-image, then returns a compact, normalized hash
  # suitable for the frontend topic serializer. Read-only adapter — must
  # never raise, mutate the topic, or expose anything outside the
  # critique-helper contract.
  #
  # The reader spans three schemas at once:
  #
  #   * Critique request (submissions plugin, current):
  #     npn_critique_style, npn_feedback_focus, weekly-challenge fields
  #   * Critique request (future):
  #     npn_critique_type, npn_requested_feedback_areas,
  #     npn_specific_critique_questions, npn_visual_examples_allowed,
  #     npn_image_reworks_allowed, npn_project_id, npn_image_count
  #   * Image versions (submissions + revised-critique-image):
  #     original primary upload + URL, full upload-id list, count,
  #     revision images JSON, latest-revision pointer fields
  #
  # Field-level normalization rules (see #read for the public contract):
  #   - strings  : nil/blank → nil; otherwise stripped string
  #   - arrays   : missing → []; JSON strings parsed; bad JSON → []; non-array
  #                values → []; blank entries dropped; entries coerced to
  #                stripped strings
  #   - booleans : missing → false (never nil)
  #   - integers : missing/unparseable → nil; otherwise Integer
  module TopicMetadataReader
    # --- Submission request keys (current upstream schema) ---------------
    SUBMISSION_TYPE_KEY = "npn_submission_type"
    SCHEMA_VERSION_KEY = "npn_submission_schema_version"
    CRITIQUE_STYLE_KEY = "npn_critique_style"
    FEEDBACK_FOCUS_KEY = "npn_feedback_focus"
    WORDPRESS_CHALLENGE_ID_KEY = "npn_wordpress_challenge_id"
    WEEKLY_CHALLENGE_TITLE_KEY = "npn_weekly_challenge_title"
    WEEKLY_CHALLENGE_DATES_KEY = "npn_weekly_challenge_dates"
    WORDPRESS_CHALLENGE_URL_KEY = "npn_wordpress_challenge_url"

    # --- Submission request keys (future/richer schema) ------------------
    CRITIQUE_TYPE_KEY = "npn_critique_type"
    REQUESTED_FEEDBACK_AREAS_KEY = "npn_requested_feedback_areas"
    SPECIFIC_CRITIQUE_QUESTIONS_KEY = "npn_specific_critique_questions"
    VISUAL_EXAMPLES_ALLOWED_KEY = "npn_visual_examples_allowed"
    IMAGE_REWORKS_ALLOWED_KEY = "npn_image_reworks_allowed"
    # Per-topic opt-in/out for processing examples. Written by the
    # submissions plugin (in progress). Missing → treated as allowed,
    # so legacy topics created before the field existed still permit
    # the workflow by default (NPN cultural norm). Explicit false is
    # the only signal that disables the section.
    PROCESSING_EXAMPLES_ALLOWED_KEY = "npn_processing_examples_allowed"
    PROJECT_ID_KEY = "npn_project_id"
    WEEKLY_CHALLENGE_ID_KEY = "npn_weekly_challenge_id"
    IMAGE_COUNT_KEY = "npn_image_count"

    # --- Image-version keys (submissions + revised-critique-image) -------
    IMAGE_VERSION_SCHEMA_KEY = "npn_critique_image_version_schema"
    ORIGINAL_PRIMARY_IMAGE_UPLOAD_ID_KEY = "npn_original_primary_image_upload_id"
    ORIGINAL_PRIMARY_IMAGE_URL_KEY = "npn_original_primary_image_url"
    ORIGINAL_IMAGE_UPLOAD_IDS_KEY = "npn_original_image_upload_ids"
    ORIGINAL_IMAGE_COUNT_KEY = "npn_original_image_count"
    REVISION_COUNT_KEY = "npn_revision_count"
    LATEST_REVISION_UPLOAD_ID_KEY = "npn_latest_revision_upload_id"
    LATEST_REVISION_IMAGE_URL_KEY = "npn_latest_revision_image_url"
    REVISION_IMAGES_KEY = "npn_revision_images"

    # Any of these being present marks the topic as a "submission topic" and
    # triggers full serialization. Includes image-version markers so a topic
    # that has only revision metadata (e.g. a critique reply got revised but
    # the original submission predates the submissions-plugin fields) still
    # surfaces a payload.
    PRESENCE_KEYS = [
      SCHEMA_VERSION_KEY,
      SUBMISSION_TYPE_KEY,
      CRITIQUE_STYLE_KEY,
      ORIGINAL_PRIMARY_IMAGE_UPLOAD_ID_KEY,
      REVISION_IMAGES_KEY,
    ].freeze

    module_function

    # Returns the compact metadata hash for `topic`, or `nil` when the topic
    # has no recognised critique-reply fields. Never raises.
    def read(topic)
      return nil if topic.blank?

      fields = topic.custom_fields
      return nil unless submission_topic?(fields)

      {
        submission_type: normalize_string(fields[SUBMISSION_TYPE_KEY]),
        # Current upstream request fields ----------------------------------
        critique_style: normalize_string(fields[CRITIQUE_STYLE_KEY]),
        feedback_focus: normalize_string(fields[FEEDBACK_FOCUS_KEY]),
        # Future/richer request fields -------------------------------------
        critique_type: normalize_string(fields[CRITIQUE_TYPE_KEY]),
        requested_feedback_areas: normalize_array(fields[REQUESTED_FEEDBACK_AREAS_KEY]),
        specific_critique_questions:
          normalize_array(fields[SPECIFIC_CRITIQUE_QUESTIONS_KEY]),
        visual_examples_allowed: normalize_boolean(fields[VISUAL_EXAMPLES_ALLOWED_KEY]),
        image_reworks_allowed: normalize_boolean(fields[IMAGE_REWORKS_ALLOWED_KEY]),
        # Backward-compatible: missing field → allowed (true). Only an
        # explicit-false topic custom field hides the workflow. See
        # `normalize_optional_boolean_default_true`.
        processing_examples_allowed:
          normalize_optional_boolean_default_true(fields[PROCESSING_EXAMPLES_ALLOWED_KEY]),
        # Shared metadata --------------------------------------------------
        schema_version: normalize_integer(fields[SCHEMA_VERSION_KEY]),
        project_id: normalize_integer(fields[PROJECT_ID_KEY]),
        weekly_challenge_id: normalize_integer(fields[WEEKLY_CHALLENGE_ID_KEY]),
        wordpress_challenge_id: normalize_integer(fields[WORDPRESS_CHALLENGE_ID_KEY]),
        weekly_challenge_title: normalize_string(fields[WEEKLY_CHALLENGE_TITLE_KEY]),
        weekly_challenge_dates: normalize_string(fields[WEEKLY_CHALLENGE_DATES_KEY]),
        wordpress_challenge_url: normalize_string(fields[WORDPRESS_CHALLENGE_URL_KEY]),
        image_count: normalize_integer(fields[IMAGE_COUNT_KEY]),
        # Image versions ---------------------------------------------------
        image_versions: build_image_versions(fields),
      }
    rescue => e
      Discourse.warn_exception(
        e,
        message:
          "[discourse-npn-critique-reply] failed to read topic metadata for topic=#{topic&.id}",
      )
      nil
    end

    def submission_topic?(fields)
      PRESENCE_KEYS.any? { |k| fields[k].present? }
    end

    # ----- Image versions ---------------------------------------------------
    #
    # Returns a hash `{ default_key:, versions: [...] }`. `versions` is
    # always an array (empty when no image metadata is present); the
    # frontend uses an empty array as the signal to fall back to its
    # legacy `topic.image_url` / `topic.thumbnails` detection.
    #
    # Versions are emitted in this order: original first (when present),
    # then revisions in the order they appear in `npn_revision_images`.
    # `default_key` points at the latest revision (highest revision_number,
    # last-in-array as tiebreaker), or `"original"` when no revisions,
    # or `nil` when the topic has no image metadata at all.

    def build_image_versions(fields)
      original = build_original_version(fields)
      revisions = build_revision_versions(fields)
      versions = []
      versions << original if original
      versions.concat(revisions)

      { default_key: pick_default_key(versions, revisions, original), versions: versions }
    rescue => e
      Discourse.warn_exception(
        e,
        message: "[discourse-npn-critique-reply] failed to build image versions",
      )
      { default_key: nil, versions: [] }
    end

    # Returns the original version hash, or nil when neither a usable
    # upload nor a stored URL can be resolved.
    def build_original_version(fields)
      upload_id = normalize_integer(fields[ORIGINAL_PRIMARY_IMAGE_UPLOAD_ID_KEY])
      stored_url = normalize_string(fields[ORIGINAL_PRIMARY_IMAGE_URL_KEY])
      url = resolve_url(upload_id, stored_url)
      return nil if url.blank?

      {
        key: "original",
        kind: "original",
        label: "Original",
        upload_id: upload_id,
        url: url,
        revision_number: nil,
        created_at: nil,
        post_id: nil,
        user_id: nil,
        note: nil,
      }
    end

    # Parses `npn_revision_images` (Array-of-Hash or JSON-encoded string),
    # resolves each revision's URL, dedupes by upload_id (preserving first
    # occurrence), and emits one hash per usable revision.
    #
    # Revisions with neither a resolvable upload_id nor a stored image_url
    # are skipped entirely. Insertion order is preserved.
    def build_revision_versions(fields)
      raw = parse_revision_data(fields[REVISION_IMAGES_KEY])
      return [] unless raw.is_a?(Array)

      seen_upload_ids = Set.new
      used_keys = Set.new
      out = []

      raw.each_with_index do |entry, idx|
        next unless entry.is_a?(Hash)

        upload_id = normalize_integer(fetch_either(entry, "upload_id"))

        # Dedup: skip when this upload_id has already been emitted.
        if upload_id && seen_upload_ids.include?(upload_id)
          next
        end

        stored_url = normalize_string(fetch_either(entry, "image_url"))
        url = resolve_url(upload_id, stored_url)
        next if url.blank?

        seen_upload_ids << upload_id if upload_id

        revision_number = normalize_integer(fetch_either(entry, "revision_number"))
        # Stable, human-meaningful key when revision_number is present;
        # fall back to a positional key otherwise. If the chosen key has
        # already been used (unusual — duplicate revision_number with
        # distinct upload_id), force a positional key to keep uniqueness.
        key =
          if revision_number
            candidate = "revision_#{revision_number}"
            used_keys.include?(candidate) ? "revision_idx_#{idx + 1}" : candidate
          else
            "revision_idx_#{idx + 1}"
          end
        used_keys << key

        out << {
          key: key,
          kind: "revision",
          label: revision_number ? "Revision #{revision_number}" : "Revision",
          upload_id: upload_id,
          url: url,
          revision_number: revision_number,
          created_at: normalize_string(fetch_either(entry, "created_at")),
          post_id: normalize_integer(fetch_either(entry, "post_id")),
          user_id: normalize_integer(fetch_either(entry, "user_id")),
          note: normalize_string(fetch_either(entry, "note")),
        }
      end

      out
    end

    # Highest revision_number wins; insertion order is the tiebreaker for
    # revisions without a revision_number. Falls back to `"original"`,
    # then `nil`.
    def pick_default_key(_versions, revisions, original)
      if revisions.any?
        latest = revisions.each_with_index.max_by { |r, idx| [r[:revision_number] || 0, idx] }[0]
        return latest[:key]
      end
      return original[:key] if original
      nil
    end

    # Resolve an image URL. Prefer the live Upload record (durable, picks up
    # CDN-config changes) and fall back to the stored URL string. The
    # returned URL is always RELATIVE-or-absolute as Discourse stores it —
    # the frontend prepends the CDN host via `getURLWithCDN`.
    def resolve_url(upload_id, stored_url)
      if upload_id
        upload = ::Upload.find_by(id: upload_id)
        url = upload&.url
        return url if url.present?
      end
      stored_url
    end

    # `npn_revision_images` may be stored as a Ruby array (when registered
    # as :json), a JSON string, or nothing. We tolerate all three and any
    # parser error.
    def parse_revision_data(value)
      return value if value.is_a?(Array)
      return [] if value.nil? || value.is_a?(Hash)

      if value.is_a?(String)
        begin
          JSON.parse(value)
        rescue JSON::ParserError
          []
        end
      else
        []
      end
    end

    # Custom-field values arrive with either string or symbol keys depending
    # on how the upstream plugin wrote them. Accept both.
    def fetch_either(hash, name)
      hash[name] || hash[name.to_sym]
    end

    # ----- Normalizers ------------------------------------------------------

    def normalize_string(value)
      return nil if value.nil?
      s = value.to_s.strip
      s.empty? ? nil : s
    end

    # Accepts: nil, Array, JSON-encoded array string, or anything else.
    # Always returns an Array of non-blank stripped strings. Parsing failures
    # and non-array values fall back to []. Never raises.
    def normalize_array(value)
      return [] if value.nil?

      parsed =
        if value.is_a?(Array)
          value
        elsif value.is_a?(String)
          begin
            JSON.parse(value)
          rescue JSON::ParserError
            return []
          end
        else
          return []
        end

      return [] unless parsed.is_a?(Array)

      parsed.filter_map do |entry|
        s = entry.to_s.strip
        s.empty? ? nil : s
      end
    end

    # Booleans normalize to true/false. Missing/unrecognised → false rather
    # than nil so the frontend can treat the field as a guaranteed boolean.
    def normalize_boolean(value)
      return value if value == true || value == false
      return false if value.nil?

      case value.to_s.strip.downcase
      when "true", "t", "1", "yes", "y"
        true
      when "false", "f", "0", "no", "n", ""
        false
      else
        false
      end
    end

    def normalize_integer(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)
      Integer(value.to_s.strip, 10)
    rescue ArgumentError, TypeError
      nil
    end

    # Booleans where ABSENCE means "allowed" (true). Used by features
    # added after the submissions plugin shipped: a topic that predates
    # the field shouldn't be silently opted out of a new affordance.
    # Only an explicit-false signal disables.
    def normalize_optional_boolean_default_true(value)
      return true if value.nil?
      return value if value == true || value == false

      case value.to_s.strip.downcase
      when "false", "f", "0", "no", "n"
        false
      when "", "true", "t", "1", "yes", "y"
        true
      else
        true
      end
    end
  end
end
