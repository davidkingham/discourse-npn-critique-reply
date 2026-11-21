// Voice note (experimental spike): pure helpers shared by the recorder
// component and the Critique Workspace modal. No DOM, no Ember — the
// browser-facing parts (getUserMedia / MediaRecorder / upload) live in
// components/npn-critique-voice-recorder.gjs.

// Recording formats in preference order. Browsers disagree on what
// MediaRecorder can produce:
//   • Safari records MP4/AAC only.
//   • Chrome records WebM/Opus, and MP4 in recent versions.
//   • Firefox records WebM/Opus and Ogg/Opus.
// MP4/AAC comes first because every current browser can PLAY it and
// core Discourse classes `.m4a` as audio. `.webm` is last: it records
// fine but core treats that extension as video, and older Safari can't
// play Opus.
export const VOICE_NOTE_FORMATS = Object.freeze([
  { mimeType: "audio/mp4;codecs=mp4a.40.2", extension: "m4a" },
  { mimeType: "audio/mp4", extension: "m4a" },
  { mimeType: "audio/ogg;codecs=opus", extension: "ogg" },
  { mimeType: "audio/webm;codecs=opus", extension: "webm" },
  { mimeType: "audio/webm", extension: "webm" },
]);

// Speech is intelligible well below music bitrates; 64 kbps keeps a
// three-minute note under ~1.5 MB.
export const VOICE_NOTE_BITS_PER_SECOND = 64000;

// First format this browser's MediaRecorder accepts, or null when it
// can't record audio at all. `isTypeSupported` is injectable for tests.
export function pickRecordingFormat(isTypeSupported) {
  const supports =
    isTypeSupported ??
    (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported
      ? (type) => MediaRecorder.isTypeSupported(type)
      : null);
  if (!supports) {
    return null;
  }
  return VOICE_NOTE_FORMATS.find((format) => supports(format.mimeType)) ?? null;
}

// Whether the site's upload whitelist accepts this extension for this
// user. Mirrors core: `authorized_extensions` is a pipe-separated list,
// `*` allows everything, and staff additionally get
// `authorized_extensions_for_staff`.
export function isExtensionAuthorized(extension, siteSettings, currentUser) {
  const lists = [siteSettings?.authorized_extensions];
  if (currentUser?.staff) {
    lists.push(siteSettings?.authorized_extensions_for_staff);
  }
  const wanted = String(extension ?? "").toLowerCase();
  return lists.some((list) =>
    String(list ?? "")
      .split("|")
      .map((entry) => entry.trim().toLowerCase().replace(/^\./, ""))
      .some((entry) => entry === "*" || entry === wanted)
  );
}

// m:ss for the recording timer.
export function formatVoiceNoteTime(totalSeconds) {
  const seconds = Math.max(0, Math.floor(Number(totalSeconds) || 0));
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
}

export function voiceNoteFilename(topicId, extension) {
  return `npn-voice-critique-topic-${topicId ?? "unknown"}.${extension}`;
}

// Markdown that core cooks into an <audio controls> player. The
// `|audio` suffix forces the audio player whatever the extension, so a
// `.webm` recording doesn't come out as a video box.
export function voiceNoteMarkdown(voiceNote, label) {
  const src = voiceNote?.shortUrl ?? voiceNote?.url ?? "";
  if (!src) {
    return "";
  }
  const safeLabel = String(label ?? "")
    .replace(/[\[\]|\r\n]/g, " ")
    .trim();
  return `![${safeLabel}|audio](${src})`;
}

const VOICE_NOTE_EMBED_PATTERN = /!\[[^\]\n]*\|audio\]\(([^)\s]+)\)/;

// Find a previously posted voice note in a reply's raw markdown so that
// reopening the critique for editing carries it over. Returns the same
// shape the recorder emits (minus fields the raw can't tell us), or null.
export function parseVoiceNoteFromRaw(raw) {
  const match = String(raw ?? "").match(VOICE_NOTE_EMBED_PATTERN);
  if (!match) {
    return null;
  }
  const src = match[1];
  const isShortUrl = src.startsWith("upload://");
  return {
    uploadId: null,
    shortUrl: isShortUrl ? src : null,
    url: isShortUrl ? null : src,
    durationSeconds: null,
  };
}

// ---- Pointer timeline ----------------------------------------------------
//
// While a voice note records, the workspace also records where the
// critic's pointer is over the reference image. The posted reply replays
// that pointer over the image in sync with the audio.
//
// Storage format (mirrors VoiceNoteNormalizer on the server):
//   points  — flat [t, x, y, t, x, y, …]; t = ms from recording start,
//             x / y = 0..1000 (tenths of a percent of the image).
//             x = y = -1 marks "pointer left the image".
//   presses — [t, …] moments the critic pressed on the image.

export const POINTER_GONE = -1;
export const POINTER_COORD_MAX = 1000;
export const MAX_POINTER_VALUES = 12000;
const MAX_PRESSES = 500;
// ~15 samples/s while moving; nothing while the pointer rests.
const MIN_SAMPLE_INTERVAL_MS = 66;
const MIN_SAMPLE_DISTANCE = 2;
// Samples closer together than this are joined by a straight glide on
// playback; a longer gap means the pointer was resting, so it holds.
const GLIDE_WINDOW_MS = 250;

// Records pointer samples relative to a target element.
//
// `resolveTarget()` is asked on every event for the element whose box IS
// the image (it can change or disappear mid-recording — layout switch,
// image switch — in which case it returns null and the pointer is
// recorded as gone). Listeners sit on `document` in the capture phase so
// the canvas's own handlers can't swallow the events.
export class PointerTimelineCapture {
  #resolveTarget;
  #now;
  #doc;
  #startedAt = 0;
  #points = [];
  #presses = [];
  #lastT = -Infinity;
  #lastX = POINTER_GONE;
  #lastY = POINTER_GONE;
  #running = false;

  #onMove = (event) => {
    this.#record(event, false);
  };

#onDown = (event) => {
    const t = this.#record(event, true);
    if (t !== null && this.#presses.length < MAX_PRESSES) {
      this.#presses.push(t);
    }
  };

constructor({ resolveTarget, now, doc } = {}) {
    this.#resolveTarget = resolveTarget;
    this.#now = now ?? (() => performance.now());
    this.#doc = doc ?? document;
  }

  start() {
    if (this.#running) {
      return;
    }
    this.#running = true;
    this.#startedAt = this.#now();
    this.#doc.addEventListener("pointermove", this.#onMove, true);
    this.#doc.addEventListener("pointerdown", this.#onDown, true);
  }

  // Idempotent. Returns the recorded timeline.
  stop() {
    if (this.#running) {
      this.#running = false;
      this.#doc.removeEventListener("pointermove", this.#onMove, true);
      this.#doc.removeEventListener("pointerdown", this.#onDown, true);
    }
    return { points: this.#points, presses: this.#presses };
  }

  #locate(event) {
    const rect = this.#resolveTarget?.()?.getBoundingClientRect?.();
    if (!rect || rect.width <= 0 || rect.height <= 0) {
      return null;
    }
    const fx = (event.clientX - rect.left) / rect.width;
    const fy = (event.clientY - rect.top) / rect.height;
    if (fx < 0 || fx > 1 || fy < 0 || fy > 1) {
      return null;
    }
    return {
      x: Math.round(fx * POINTER_COORD_MAX),
      y: Math.round(fy * POINTER_COORD_MAX),
    };
  }

  #record(event, force) {
    if (this.#points.length + 3 > MAX_POINTER_VALUES) {
      return null;
    }
    const t = Math.max(0, Math.round(this.#now() - this.#startedAt));
    const at = this.#locate(event);
    const x = at ? at.x : POINTER_GONE;
    const y = at ? at.y : POINTER_GONE;
    const wasGone = this.#lastX === POINTER_GONE;

    if (!at) {
      // One "gone" marker is enough until the pointer comes back.
      if (wasGone) {
        return null;
      }
    } else if (!force && !wasGone) {
      const moved =
        Math.abs(x - this.#lastX) + Math.abs(y - this.#lastY) >=
        MIN_SAMPLE_DISTANCE;
      if (!moved || t - this.#lastT < MIN_SAMPLE_INTERVAL_MS) {
        return null;
      }
    }

    this.#points.push(t, x, y);
    this.#lastT = t;
    this.#lastX = x;
    this.#lastY = y;
    return at ? t : null;
  }

  

  
}

// Index of the last sample at or before `tMs` (-1 when none), as a
// position in sample units (multiply by 3 for the flat array).
function sampleIndexAt(points, tMs) {
  let lo = 0;
  let hi = Math.floor(points.length / 3) - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (points[mid * 3] <= tMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

// Where the pointer is at `tMs`: `{ x, y }` in 0..1000, or null when it
// is off the image (or the recording hasn't reached the image yet).
export function pointerAt(points, tMs) {
  if (!Array.isArray(points) || points.length < 3) {
    return null;
  }
  const i = sampleIndexAt(points, tMs);
  if (i < 0) {
    return null;
  }
  const t0 = points[i * 3];
  const x0 = points[i * 3 + 1];
  const y0 = points[i * 3 + 2];
  if (x0 === POINTER_GONE) {
    return null;
  }
  const next = (i + 1) * 3;
  if (next + 2 < points.length && points[next + 1] !== POINTER_GONE) {
    const span = points[next] - t0;
    if (span > 0 && span <= GLIDE_WINDOW_MS) {
      const k = (tMs - t0) / span;
      return {
        x: x0 + (points[next + 1] - x0) * k,
        y: y0 + (points[next + 2] - y0) * k,
      };
    }
  }
  return { x: x0, y: y0 };
}

// True when a press falls in the half-open window (fromMs, toMs].
export function pressBetween(presses, fromMs, toMs) {
  if (!Array.isArray(presses)) {
    return false;
  }
  return presses.some((t) => t > fromMs && t <= toMs);
}

function transformToPayload(transform) {
  if (!transform) {
    return null;
  }
  return {
    rotation: Number(transform.rotation) || 0,
    flip_h: !!(transform.flipH ?? transform.flip_h),
    flip_v: !!(transform.flipV ?? transform.flip_v),
  };
}

// Stable comparison key — null / identity / missing all compare equal.
export function transformKey(transform) {
  const t = transformToPayload(transform);
  return t ? `${t.rotation}|${t.flip_h}|${t.flip_v}` : "0|false|false";
}

// Build the `voice_note` request payload (→ `npn_voice_note` custom
// field). `stageImageUrl` is the image the pointer replays over; pass
// null when there isn't a trustworthy one and the timeline is dropped
// (the audio still posts).
export function buildVoiceNotePayload(voiceNote, { stageImageUrl } = {}) {
  const payload = buildVoiceNoteDraft(voiceNote);
  if (!payload) {
    return null;
  }
  if (payload.timeline && stageImageUrl) {
    payload.stage_image_url = stageImageUrl;
  } else {
    delete payload.timeline;
    delete payload.image_index;
    delete payload.image_transform;
  }
  return payload;
}

// Workspace-draft form of the note: the recording plus its pointer
// timeline. The post payload is this plus the replay image, which is
// only chosen at post time.
export function buildVoiceNoteDraft(voiceNote) {
  if (!voiceNote?.shortUrl) {
    return null;
  }
  const payload = {
    upload: { short_url: voiceNote.shortUrl, url: voiceNote.url ?? null },
    duration_ms: Math.round((voiceNote.durationSeconds ?? 0) * 1000),
  };
  const points = voiceNote.timeline?.points;
  if (Array.isArray(points) && points.length >= 3) {
    payload.image_index = voiceNote.imageIndex ?? 0;
    payload.image_transform = transformToPayload(voiceNote.imageTransform);
    payload.timeline = {
      points,
      presses: voiceNote.timeline.presses ?? [],
    };
  }
  return payload;
}

// Inverse of buildVoiceNotePayload / buildVoiceNoteDraft: workspace
// state from a posted reply's `npn_voice_note` (edit mode) or from a
// saved draft's `voice_note` (resume).
export function voiceNoteFromPayload(payload) {
  const shortUrl = payload?.upload?.short_url;
  if (!shortUrl) {
    return null;
  }
  const points = payload.timeline?.points;
  const hasTimeline = Array.isArray(points) && points.length >= 3;
  return {
    uploadId: null,
    shortUrl,
    url: payload.upload.url ?? null,
    durationSeconds: (Number(payload.duration_ms) || 0) / 1000,
    timeline: hasTimeline
      ? { points, presses: payload.timeline.presses ?? [] }
      : null,
    imageIndex: hasTimeline ? (payload.image_index ?? 0) : null,
    imageTransform: hasTimeline ? (payload.image_transform ?? null) : null,
  };
}

// ---- Annotation moments ----------------------------------------------------
//
// "When did the critic talk about [A1]?" is answered from data the post
// already has: the pointer timeline and the annotation geometry. A mark's
// moment is the first time the critic pressed on it or rested the
// pointer on it. Nothing extra is recorded or stored, so this also works
// for marks that were described by pointing rather than by selecting.

// How long the pointer must stay on a mark to count as "pointing at it"
// rather than passing over it on the way somewhere else.
const MOMENT_DWELL_MS = 400;
// Slack around a mark, in percent of the image. Pointing is imprecise,
// and badges sit beside their shapes.
const MOMENT_TOLERANCE_PCT = 3;
// A pin is a point, so it gets a larger catch radius.
const MOMENT_PIN_RADIUS_PCT = 6;

function distanceToSegment(px, py, x1, y1, x2, y2) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const lengthSquared = dx * dx + dy * dy;
  const k =
    lengthSquared === 0
      ? 0
      : Math.min(
          1,
          Math.max(0, ((px - x1) * dx + (py - y1) * dy) / lengthSquared)
        );
  return Math.hypot(px - (x1 + dx * k), py - (y1 + dy * k));
}

function nearPolyline(px, py, points, tolerance) {
  if (points.length === 1) {
    return (
      Math.hypot(px - points[0].x_pct, py - points[0].y_pct) <= tolerance
    );
  }
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1];
    const b = points[i];
    if (
      distanceToSegment(px, py, a.x_pct, a.y_pct, b.x_pct, b.y_pct) <=
      tolerance
    ) {
      return true;
    }
  }
  return false;
}

function insideBox(px, py, left, top, width, height, tolerance) {
  return (
    px >= left - tolerance &&
    px <= left + width + tolerance &&
    py >= top - tolerance &&
    py <= top + height + tolerance
  );
}

const isNumber = (value) => typeof value === "number" && Number.isFinite(value);

// Returns a `(xPct, yPct) => boolean` hit test for one saved annotation
// (schema shape, 0..100 coordinates), or null for a kind or shape we
// can't place.
function annotationHitTest(annotation) {
  const tolerance = MOMENT_TOLERANCE_PCT;
  const points = Array.isArray(annotation.points)
    ? annotation.points.filter((p) => isNumber(p?.x_pct) && isNumber(p?.y_pct))
    : [];
  const {
    x_pct: x,
    y_pct: y,
    width_pct: width,
    height_pct: height,
  } = annotation;

  switch (annotation.kind) {
    case "pin":
      return isNumber(x) && isNumber(y)
        ? (px, py) => Math.hypot(px - x, py - y) <= MOMENT_PIN_RADIUS_PCT
        : null;
    case "area_note":
    case "attention_pull":
    case "strong_area": {
      if (annotation.shape === "path") {
        if (points.length === 0) {
          return null;
        }
        const xs = points.map((p) => p.x_pct);
        const ys = points.map((p) => p.y_pct);
        const left = Math.min(...xs);
        const top = Math.min(...ys);
        const w = Math.max(...xs) - left;
        const h = Math.max(...ys) - top;
        return (px, py) => insideBox(px, py, left, top, w, h, tolerance);
      }
      return [x, y, width, height].every(isNumber)
        ? (px, py) => insideBox(px, py, x, y, width, height, tolerance)
        : null;
    }
    case "crop":
      // A crop usually covers most of the frame, so "inside it" says
      // nothing. Pointing at a crop means tracing its edge.
      return [x, y, width, height].every(isNumber)
        ? (px, py) =>
            insideBox(px, py, x, y, width, height, tolerance) &&
            !insideBox(
              px,
              py,
              x + tolerance,
              y + tolerance,
              width - 2 * tolerance,
              height - 2 * tolerance,
              0
            )
        : null;
    case "eye_path":
      return points.length > 0
        ? (px, py) => nearPolyline(px, py, points, tolerance)
        : null;
    case "direction_arrow":
    case "relationship_arrow": {
      const { x1_pct: x1, y1_pct: y1, x2_pct: x2, y2_pct: y2 } = annotation;
      return [x1, y1, x2, y2].every(isNumber)
        ? (px, py) =>
            distanceToSegment(px, py, x1, y1, x2, y2) <= tolerance
        : null;
    }
    default:
      return null;
  }
}

// The token(s) a mark is referenced by in the critique text — the same
// labels the badge decorator turns into pills.
function annotationLabels(annotation) {
  if (annotation.kind === "pin") {
    return Number.isInteger(annotation.number)
      ? [String(annotation.number)]
      : [];
  }
  const label =
    typeof annotation.label === "string" && annotation.label.length > 0
      ? annotation.label
      : null;
  if (annotation.kind === "crop") {
    return label ? [label] : ["Crop", "CROP"];
  }
  return label ? [label] : [];
}

// First moment (ms) the pointer pressed on, or rested on, the region.
function firstMomentIn(hit, points, presses, durationMs) {
  const sampleCount = Math.floor(points.length / 3);
  const toPct = 100 / POINTER_COORD_MAX;
  let found = null;
  let runStart = null;

  for (let i = 0; i < sampleCount && found === null; i++) {
    const t = points[i * 3];
    const x = points[i * 3 + 1];
    const y = points[i * 3 + 2];
    const inside = x !== POINTER_GONE && hit(x * toPct, y * toPct);
    if (inside && runStart === null) {
      runStart = t;
    }
    // A run ends at the next sample outside the region; the pointer
    // resting produces no samples, so a rest shows up as a long run.
    const runEnd = inside ? null : t;
    if (runStart !== null && runEnd !== null) {
      if (runEnd - runStart >= MOMENT_DWELL_MS) {
        found = runStart;
      }
      runStart = null;
    }
  }
  if (found === null && runStart !== null) {
    const end = Math.max(durationMs || 0, points[(sampleCount - 1) * 3]);
    if (end - runStart >= MOMENT_DWELL_MS) {
      found = runStart;
    }
  }

  for (const t of presses ?? []) {
    if (found !== null && t >= found) {
      break;
    }
    const at = pointerAt(points, t);
    if (at && hit(at.x * toPct, at.y * toPct)) {
      found = t;
      break;
    }
  }
  return found;
}

// Map of annotation label → the moment (ms into the recording) the
// critic first pointed at that mark. Marks they never pointed at are
// absent. `annotations` is `npn_visual_notes.annotations`; only marks on
// the image the pointer was recorded over (`imageIndex`) are considered.
export function annotationMoments(
  annotations,
  timeline,
  { imageIndex = 0, durationMs = 0 } = {}
) {
  const moments = new Map();
  const points = timeline?.points;
  if (!Array.isArray(annotations) || !Array.isArray(points)) {
    return moments;
  }
  for (const annotation of annotations) {
    if (
      !annotation ||
      typeof annotation !== "object" ||
      (annotation.image_index ?? 0) !== imageIndex
    ) {
      continue;
    }
    const labels = annotationLabels(annotation);
    const hit = labels.length > 0 ? annotationHitTest(annotation) : null;
    if (!hit) {
      continue;
    }
    const moment = firstMomentIn(hit, points, timeline.presses, durationMs);
    if (moment === null) {
      continue;
    }
    for (const label of labels) {
      if (!moments.has(label) || moment < moments.get(label)) {
        moments.set(label, moment);
      }
    }
  }
  return moments;
}
