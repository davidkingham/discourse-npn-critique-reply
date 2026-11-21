# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Server-side normalizer for the voice-note payload attached to a
  # posted critique reply (stored in the `npn_voice_note` post custom
  # field). Experimental — see `npn_critique_reply_voice_note_experiment`.
  #
  # The audio itself is an ordinary upload embedded in the post body.
  # This payload carries what the body can't: the pointer timeline the
  # critic recorded while talking (where their cursor was over the
  # image, and when they pressed), so the post can replay it in sync
  # with the audio.
  #
  # Coordinates are integers in 0..1000 (tenths of a percent of the
  # image), times are integer milliseconds from the start of the
  # recording. `points` is a flat `[t, x, y, t, x, y, ...]` array to
  # keep the stored JSON small; x = y = -1 means "pointer left the
  # image" (the player hides the cursor until the next sample).
  #
  # Never raises. Returns nil when there is no usable audio reference,
  # so callers don't persist an empty wrapper.
  module VoiceNoteNormalizer
    SCHEMA_VERSION = 1
    MAX_URL_LENGTH = 2000
    # Generous ceiling over the setting's 600s maximum.
    MAX_DURATION_MS = 660_000
    # 4000 samples x (t, x, y). The client samples at ~15/s and skips
    # samples where the pointer hasn't moved, so a three-minute note is
    # normally far below this.
    MAX_POINT_VALUES = 12_000
    MAX_PRESSES = 500
    COORD_MAX = 1000
    POINTER_GONE = -1

    SHORT_URL_PATTERN = %r{\Aupload://[A-Za-z0-9]+(\.[A-Za-z0-9]+)?\z}
    # Relative, protocol-relative or http(s) only — this ends up in an
    # <img src> on the client.
    IMAGE_URL_PATTERN = %r{\A(/|https?://)[^\s"'<>]*\z}

    module_function

    # For a posted reply. `raw` is the post body being saved: the audio
    # must actually be embedded in it — otherwise the metadata would
    # describe a recording the post doesn't contain.
    def normalize(payload, raw:)
      out = normalize_audio(payload)
      return nil if out.nil?
      return nil unless raw.to_s.include?(out["upload"]["short_url"])

      # A timeline is only useful with an image to replay it over.
      stage_image_url = normalize_url(payload["stage_image_url"] || payload[:stage_image_url])
      return out if stage_image_url.nil?
      return out unless add_timeline(out, payload)

      out["stage_image_url"] = stage_image_url
      out
    end

    # For the workspace draft: the recording is not in any post yet and
    # the replay image is only chosen at post time, so neither is
    # required here. Returns nil when there is no recording.
    def normalize_for_draft(payload)
      out = normalize_audio(payload)
      return nil if out.nil?
      add_timeline(out, payload)
      out
    end

    def normalize_audio(payload)
      return nil unless payload.is_a?(Hash)
      payload = payload.deep_stringify_keys

      upload = payload["upload"].is_a?(Hash) ? payload["upload"] : {}
      short_url = upload["short_url"].to_s
      return nil unless short_url.match?(SHORT_URL_PATTERN)

      out = {
        "schema_version" => SCHEMA_VERSION,
        "upload" => { "short_url" => short_url },
        "duration_ms" => clamp_int(payload["duration_ms"], 0, MAX_DURATION_MS),
      }
      upload_url = normalize_url(upload["url"])
      out["upload"]["url"] = upload_url if upload_url
      out
    end

    # Adds the pointer timeline (and the image it belongs to) to `out`.
    # Returns false, leaving `out` untouched, when there is none.
    def add_timeline(out, payload)
      payload = payload.deep_stringify_keys
      points = normalize_points(payload.dig("timeline", "points"))
      return false if points.empty?

      out["image_index"] = clamp_int(payload["image_index"], 0, 999)
      transform = DraftNormalizer.normalize_image_transform(payload["image_transform"])
      out["image_transform"] = transform if transform
      out["timeline"] = {
        "points" => points,
        "presses" => normalize_presses(payload.dig("timeline", "presses")),
      }
      true
    end

    def normalize_url(value)
      str = value.to_s.strip
      return nil if str.empty? || str.length > MAX_URL_LENGTH
      str.match?(IMAGE_URL_PATTERN) ? str : nil
    end

    def clamp_int(value, min, max)
      int = Integer(value, exception: false) || value.to_f.round
      int.clamp(min, max)
    rescue StandardError
      min
    end

    # Keeps well-formed, time-ordered (t, x, y) triples and drops the
    # rest. A sample is either fully on the image or the "gone" marker.
    def normalize_points(value)
      return [] unless value.is_a?(Array)
      out = []
      last_t = -1
      value
        .first(MAX_POINT_VALUES)
        .each_slice(3) do |t, x, y|
          next unless [t, x, y].all? { |n| n.is_a?(Numeric) }
          t = t.round
          next if t < last_t || t > MAX_DURATION_MS
          x = x.round
          y = y.round
          if x == POINTER_GONE || y == POINTER_GONE
            x = y = POINTER_GONE
          elsif x.negative? || y.negative? || x > COORD_MAX || y > COORD_MAX
            next
          end
          out.push(t, x, y)
          last_t = t
        end
      out
    end

    def normalize_presses(value)
      return [] unless value.is_a?(Array)
      value
        .first(MAX_PRESSES)
        .select { |t| t.is_a?(Numeric) && t >= 0 && t <= MAX_DURATION_MS }
        .map(&:round)
        .sort
    end
  end
end
