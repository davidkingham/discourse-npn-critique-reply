# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Server-side mirror of the client-side annotation normalizer in
  # `assets/javascripts/discourse/lib/npn-critique-reply-annotation-schema.js`.
  # Accepts arbitrary client payloads, drops anything malformed, enforces
  # caps, and returns the canonical v1 draft shape.
  #
  # The frontend's normalizer is the source-of-truth visual layer; this
  # module exists so the server can refuse to store junk (or worse,
  # one user's renderer-specific payload that no other browser can read).
  # Never raises — callers can pass anything.
  module DraftNormalizer
    SCHEMA_VERSION = 1

    # Caps mirror the client-side constants. Keep in sync with
    # npn-critique-reply-annotation-schema.js.
    MAX_CRITIQUE_TEXT_LENGTH = 50_000
    MAX_ANNOTATION_COUNT = 100
    MAX_PIN_COUNT = 50
    MAX_CROP_COUNT = 1
    MAX_EYE_PATH_COUNT = 4
    MAX_EYE_PATH_POINTS = 10
    MAX_ATTENTION_PULL_COUNT = 8
    MAX_STRONG_AREA_COUNT = 8
    MAX_DIRECTION_ARROW_COUNT = 8
    MAX_RELATIONSHIP_ARROW_COUNT = 8
    MIN_ARROW_DISTANCE_PCT = 3.0

    ACTIVE_KINDS = %w[
      pin
      crop
      eye_path
      attention_pull
      strong_area
      direction_arrow
      relationship_arrow
    ].freeze

    UI_ALLOWED_KEYS = %w[prompts_hidden prompts_expanded].freeze

    # Allowed values for the persisted large-image-view selection.
    # Any other string is normalised to nil and the client falls
    # back to the auto-switch default on restore. Kept in sync with
    # `LARGE_IMAGE_VIEWS` in the modal component.
    LARGE_IMAGE_VIEWS = %w[reference processing_example].freeze

    module_function

    # Returns a fully-normalized draft hash ready for PluginStore. The
    # caller must supply `topic_id` and `user_id` separately — we never
    # trust them off the client payload.
    def normalize(payload, topic_id:, user_id:)
      payload = {} unless payload.is_a?(Hash)
      payload = payload.deep_stringify_keys

      {
        "schema_version" => SCHEMA_VERSION,
        "topic_id" => topic_id.to_i,
        "user_id" => user_id.to_i,
        "updated_at" => Time.now.utc.iso8601,
        "selected_image_version_key" =>
          normalize_string(payload["selected_image_version_key"]),
        "critique_text" => normalize_text(payload["critique_text"]),
        "annotations" => normalize_annotations(payload["annotations"]),
        # Processing example draft entry — flat shape, see
        # ProcessingExampleNormalizer.normalize_for_draft. May be nil
        # when the user has no upload pending; the client treats both
        # missing and nil as "no example".
        "processing_example" =>
          ProcessingExampleNormalizer.normalize_for_draft(payload["processing_example"]),
        # Persisted large-image view selection. Null when missing or
        # when the value isn't in the whitelist; client restore falls
        # back to its auto-switch default in that case.
        "large_image_view" => normalize_large_image_view(payload["large_image_view"]),
        "ui" => normalize_ui(payload["ui"]),
      }
    end

    def normalize_large_image_view(value)
      return nil if value.nil?
      str = value.to_s.strip
      LARGE_IMAGE_VIEWS.include?(str) ? str : nil
    end

    def normalize_text(value)
      return "" if value.nil?
      str = value.to_s
      str.length > MAX_CRITIQUE_TEXT_LENGTH ? str[0, MAX_CRITIQUE_TEXT_LENGTH] : str
    end

    def normalize_string(value)
      return nil if value.nil?
      str = value.to_s.strip
      str.empty? ? nil : str
    end

    def normalize_ui(value)
      out = {}
      return out unless value.is_a?(Hash)
      value.each do |k, v|
        next if UI_ALLOWED_KEYS.exclude?(k.to_s)
        out[k.to_s] = !!v
      end
      out
    end

    def normalize_annotations(raw)
      return [] unless raw.is_a?(Array)

      pin_count = 0
      crop_count = 0
      eye_path_count = 0
      attention_pull_count = 0
      strong_area_count = 0
      direction_arrow_count = 0
      relationship_arrow_count = 0
      seen_ids = {}
      out = []

      raw.each do |entry|
        break if out.length >= MAX_ANNOTATION_COUNT
        next unless entry.is_a?(Hash)
        kind = entry["kind"] || entry[:kind]
        next if ACTIVE_KINDS.exclude?(kind.to_s)

        normalized =
          case kind.to_s
          when "pin"
            next if pin_count >= MAX_PIN_COUNT
            normalize_pin(entry).tap { |n| pin_count += 1 if n }
          when "crop"
            next if crop_count >= MAX_CROP_COUNT
            normalize_rect(entry, kind: "crop").tap do |n|
              if n
                ar = (entry["aspect_ratio"] || entry[:aspect_ratio]).to_s
                n["aspect_ratio"] = ar.empty? ? "free" : ar
                crop_count += 1
              end
            end
          when "eye_path"
            next if eye_path_count >= MAX_EYE_PATH_COUNT
            normalize_eye_path(entry).tap { |n| eye_path_count += 1 if n }
          when "attention_pull"
            next if attention_pull_count >= MAX_ATTENTION_PULL_COUNT
            normalize_shape(entry, kind: "attention_pull").tap do |n|
              attention_pull_count += 1 if n
            end
          when "strong_area"
            next if strong_area_count >= MAX_STRONG_AREA_COUNT
            normalize_shape(entry, kind: "strong_area").tap do |n|
              strong_area_count += 1 if n
            end
          when "direction_arrow"
            next if direction_arrow_count >= MAX_DIRECTION_ARROW_COUNT
            normalize_arrow(entry, kind: "direction_arrow").tap do |n|
              direction_arrow_count += 1 if n
            end
          when "relationship_arrow"
            next if relationship_arrow_count >= MAX_RELATIONSHIP_ARROW_COUNT
            normalize_arrow(entry, kind: "relationship_arrow").tap do |n|
              relationship_arrow_count += 1 if n
            end
          end

        next unless normalized
        id = normalized["id"]
        next if seen_ids.key?(id)
        seen_ids[id] = true
        out << normalized
      end

      out
    end

    # --- per-kind normalizers ---------------------------------------

    def normalize_pin(entry)
      x = clamp_pct(entry["x_pct"] || entry[:x_pct])
      y = clamp_pct(entry["y_pct"] || entry[:y_pct])
      number = positive_integer(entry["number"] || entry[:number])
      id = normalize_string(entry["id"] || entry[:id]) || "pin_#{number || rand(1_000_000)}"
      return nil if x.nil? || y.nil? || number.nil?
      out = { "id" => id, "kind" => "pin", "number" => number, "x_pct" => x, "y_pct" => y }
      note = normalize_string(entry["note"] || entry[:note])
      out["note"] = note if note
      out
    end

    def normalize_rect(entry, kind:)
      x = clamp_pct(entry["x_pct"] || entry[:x_pct])
      y = clamp_pct(entry["y_pct"] || entry[:y_pct])
      w = clamp_pct(entry["width_pct"] || entry[:width_pct])
      h = clamp_pct(entry["height_pct"] || entry[:height_pct])
      id = normalize_string(entry["id"] || entry[:id]) || "#{kind}_#{rand(1_000_000)}"
      return nil if x.nil? || y.nil? || w.nil? || h.nil?
      return nil if w <= 0 || h <= 0
      { "id" => id, "kind" => kind, "x_pct" => x, "y_pct" => y, "width_pct" => w, "height_pct" => h }
    end

    def normalize_shape(entry, kind:)
      base = normalize_rect(entry, kind: kind)
      return nil unless base
      shape = (entry["shape"] || entry[:shape]).to_s
      base["shape"] = %w[ellipse rectangle].include?(shape) ? shape : "ellipse"
      label = normalize_string(entry["label"] || entry[:label])
      base["label"] = label if label
      note = normalize_string(entry["note"] || entry[:note])
      base["note"] = note if note
      base
    end

    def normalize_eye_path(entry)
      raw_points = entry["points"] || entry[:points]
      return nil unless raw_points.is_a?(Array)

      points = []
      raw_points.each do |p|
        break if points.length >= MAX_EYE_PATH_POINTS
        next unless p.is_a?(Hash)
        x = clamp_pct(p["x_pct"] || p[:x_pct])
        y = clamp_pct(p["y_pct"] || p[:y_pct])
        number = positive_integer(p["number"] || p[:number]) || (points.length + 1)
        next if x.nil? || y.nil?
        points << { "number" => number, "x_pct" => x, "y_pct" => y }
      end
      return nil if points.length < 2

      # Position-aware fallback id when the client didn't supply one.
      # MAX_EYE_PATH_COUNT lets multiple paths coexist in a single
      # payload, so a static default like "eye_path_1" would collide
      # via the seen_ids dedup. Random suffix mirrors the pattern
      # used by normalize_rect for crop / attention_pull / strong_area.
      id = normalize_string(entry["id"] || entry[:id]) || "eye_path_#{rand(1_000_000)}"
      out = { "id" => id, "kind" => "eye_path", "points" => points }
      label = normalize_string(entry["label"] || entry[:label])
      out["label"] = label if label
      note = normalize_string(entry["note"] || entry[:note])
      out["note"] = note if note
      out
    end

    # Two-endpoint arrow normalizer — used for both direction_arrow
    # and relationship_arrow. The kinds share their coordinate shape
    # and only differ in how they render in the editor and which
    # label pattern (D vs R) they use. Tiny drags (below
    # MIN_ARROW_DISTANCE_PCT) are dropped as misclicks, matching the
    # tiny-rect filter on attention pulls.
    def normalize_arrow(entry, kind:)
      x1 = clamp_pct(entry["x1_pct"] || entry[:x1_pct])
      y1 = clamp_pct(entry["y1_pct"] || entry[:y1_pct])
      x2 = clamp_pct(entry["x2_pct"] || entry[:x2_pct])
      y2 = clamp_pct(entry["y2_pct"] || entry[:y2_pct])
      return nil if x1.nil? || y1.nil? || x2.nil? || y2.nil?
      dx = x2 - x1
      dy = y2 - y1
      return nil if Math.sqrt((dx * dx) + (dy * dy)) < MIN_ARROW_DISTANCE_PCT

      id = normalize_string(entry["id"] || entry[:id]) || "#{kind}_#{rand(1_000_000)}"
      out = {
        "id" => id,
        "kind" => kind,
        "x1_pct" => x1,
        "y1_pct" => y1,
        "x2_pct" => x2,
        "y2_pct" => y2,
      }
      label = normalize_string(entry["label"] || entry[:label])
      out["label"] = label if label
      note = normalize_string(entry["note"] || entry[:note])
      out["note"] = note if note
      out
    end

    # --- low-level coercions ----------------------------------------

    def clamp_pct(value)
      return nil if value.nil?
      f = Float(value)
      return 0.0 if f < 0
      return 100.0 if f > 100
      f
    rescue ArgumentError, TypeError
      nil
    end

    def positive_integer(value)
      return nil if value.nil?
      i = Integer(value)
      i.positive? ? i : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
