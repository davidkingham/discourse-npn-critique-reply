// NPN Visual Annotation Schema (v1)
// =================================================================
//
// Library-agnostic JSON shape for visual annotations on critique reply
// images. Whatever renderer/editor we adopt later (Konva, Fabric, vanilla
// canvas, or anything else) MUST normalize through this schema for
// storage — never persist a renderer's native serialization (e.g.
// Konva.toJSON output). The on-disk format is owned by this module.
//
// Why this matters:
//   • Renderer swaps don't break old posts.
//   • Schema can be validated server-side independently of the renderer.
//   • Coordinates are normalized to image-relative percentages so the
//     payload survives image resizes, retina rendering, and re-viewing
//     in cooked HTML.
//
// Top-level shape (v1):
//
//   {
//     "schema_version": 1,
//     "source": {
//       "topic_id": 123,
//       "image_version_key": "revision_2",
//       "image_version_label": "Revision 2",
//       "source_upload_id": 456,
//       "source_url": "/uploads/default/original/1X/source.jpg"
//     },
//     "visual_output": {
//       "upload_id": 789,
//       "url": "/uploads/default/original/1X/visual-notes.jpg",
//       "short_url": "upload://abc.jpg"
//     },
//     "annotations": [ … ]
//   }
//
// Annotations are a single flat array — no separate top-level
// `pins`/`shapes` arrays. Each entry has at minimum `id` and `kind`.
//
// Coordinates (`x_pct`, `y_pct`, `width_pct`, `height_pct`) are
// percentages [0, 100] of the FULL source image's dimensions, regardless
// of whether a crop annotation is present. Crop is a visual overlay, not
// a destructive transform — pins outside a future crop region are valid
// and meaningful.
//
// Future-reserved kinds (NOT active in v1):
//
//   crop:
//     { id, kind: "crop",
//       x_pct, y_pct, width_pct, height_pct }
//     Renderer dims the area outside the rect; export composites the
//     full image, then the dim mask, then any annotations on top.
//
//   arrow / circle / rectangle / text / eye_path:
//     Shapes will gain their own fields when implemented. Until then,
//     the normalizer DROPS any entry with these kinds — we don't want
//     half-implemented data sneaking into v1 storage.
//
// Manual self-check (paste into the browser console):
//
//   import("discourse/plugins/discourse-npn-critique-reply/discourse/lib/npn-critique-reply-annotation-schema")
//     .then((m) => console.log(m.runSelfCheck()));
//
//   → returns { passed, failed, results: [...] }

// ----- Constants --------------------------------------------------

export const VISUAL_ANNOTATION_SCHEMA_VERSION = 1;

export const ANNOTATION_KINDS = Object.freeze({
  PIN: "pin",
  CROP: "crop",
  EYE_PATH: "eye_path",
  ATTENTION_PULL: "attention_pull",
  STRONG_AREA: "strong_area",
  // Reserved-but-inactive — see notes above. Normalizer drops these.
  ARROW: "arrow",
  CIRCLE: "circle",
  RECTANGLE: "rectangle",
  TEXT: "text",
});

// Active kinds for v1. Entries with any other kind are dropped during
// normalization (see normalizeAnnotationsArray).
const ACTIVE_KINDS_V1 = Object.freeze(
  new Set([
    ANNOTATION_KINDS.PIN,
    ANNOTATION_KINDS.CROP,
    ANNOTATION_KINDS.EYE_PATH,
    ANNOTATION_KINDS.ATTENTION_PULL,
    ANNOTATION_KINDS.STRONG_AREA,
  ])
);

// Caps. Sanity limits, not policy — the modal's existing pin UX already
// makes 50 pins absurd, 1 crop is the v1 hard cap (a single crop
// suggestion per critique), and 100 total annotations covers the
// foreseeable crop + arrows + circles + text + eye-path use cases.
export const MAX_PIN_COUNT = 50;
export const MAX_CROP_COUNT = 1;
export const MAX_ANNOTATION_COUNT = 100;

// Tiny accidental crops should be discarded. 3% width OR height is
// roughly the threshold below which the rect looks like a misclick.
export const MIN_CROP_DIMENSION_PCT = 3;

// Eye-path caps. Up to 4 paths per critique — the eye path is the
// most visually heavy annotation kind (curves crossing the image),
// so the cap is tighter than the 8 used for attention pulls and
// strong areas. 10 points per path is a generous ceiling — past ~6
// it becomes hard to read on the export at standard sizes, but a
// hard floor keeps the UX simple. The "minimum useful" path is 2
// points (so there's a direction); the schema accepts 1-point paths
// so an in-progress save round-trips without dropping the user's
// first click. The modal renders a hint to add a second.
export const MAX_EYE_PATH_POINTS = 10;
export const MAX_EYE_PATH_COUNT = 4;
export const MIN_EYE_PATH_POINTS_FOR_EXPORT = 2;

// Eye-path label pattern + default. Each path gets a stable "E<N>"
// label that the popover writes into the textarea (e.g. "[E1]
// description"). Labels are generated max-suffix+1 so deleting one
// path doesn't shift the numbers of the others — same convention
// as attention pulls and strong areas.
export const EYE_PATH_LABEL_PATTERN = /^E\d+$/;
export const DEFAULT_EYE_PATH_LABEL = "E1";

export function nextEyePathLabel(existingLabels) {
  let max = 0;
  if (Array.isArray(existingLabels)) {
    for (const lbl of existingLabels) {
      if (typeof lbl !== "string") {
        continue;
      }
      const m = EYE_PATH_LABEL_PATTERN.exec(lbl);
      if (m) {
        const n = parseInt(lbl.slice(1), 10);
        if (Number.isFinite(n) && n > max) {
          max = n;
        }
      }
    }
  }
  return `E${max + 1}`;
}

// Eye-path id generator, mirroring the label generator above. The
// "eye_path_<N>" pattern is the in-payload form (snake_case); each
// new path gets max-suffix+1 so ids stay unique even after deletes
// (and stable when one is removed). The modal uses these when
// starting a new path session.
export const EYE_PATH_ID_PATTERN = /^eye_path_(\d+)$/;

export function nextEyePathId(existingIds) {
  let max = 0;
  if (Array.isArray(existingIds)) {
    for (const id of existingIds) {
      if (typeof id !== "string") {
        continue;
      }
      const m = EYE_PATH_ID_PATTERN.exec(id);
      if (m) {
        const n = parseInt(m[1], 10);
        if (Number.isFinite(n) && n > max) {
          max = n;
        }
      }
    }
  }
  return `eye_path_${max + 1}`;
}

// Attention-pull caps. Up to 8 markers per critique — past that the
// image gets crowded and the observational tone is lost. The 3% min
// dimension matches crop's tiny-accident floor; ellipses below it
// look like misclicks rather than intentional areas.
export const MAX_ATTENTION_PULL_COUNT = 8;
export const MIN_ATTENTION_PULL_DIMENSION_PCT = 3;

// Strong-area caps. Same shape + cap as attention pull — Strong Area
// is its positive counterpart and the UI workload (8 markers max) is
// the same.
export const MAX_STRONG_AREA_COUNT = 8;
export const MIN_STRONG_AREA_DIMENSION_PCT = 3;

// Attention-pull labels are short "A<N>" tags — visible on the image
// as a small pill and embedded in the critique text as `[A<N>]`. The
// pattern is strict so any garbage in a hand-edited payload gets
// regenerated rather than rendered.
export const ATTENTION_PULL_LABEL_PATTERN = /^A\d+$/;

// Strong-area labels follow the same shape but with the "S" prefix
// so the two kinds are unambiguous in both the image badge and the
// textarea references.
export const STRONG_AREA_LABEL_PATTERN = /^S\d+$/;

// Next-label generator. Walks the existing labels, finds the maximum
// numeric suffix, returns `A<max+1>`. Matches the pin-numbering
// "max-last+1" convention so labels stay stable when one is removed
// (A1, A2, A3 with A2 removed → next is A4, never A2). After all are
// cleared the counter resets to A1 — same way pins reset after
// clearAll.
export function nextAttentionPullLabel(existingLabels) {
  let max = 0;
  if (Array.isArray(existingLabels)) {
    for (const lbl of existingLabels) {
      if (typeof lbl !== "string") {
        continue;
      }
      const m = ATTENTION_PULL_LABEL_PATTERN.exec(lbl);
      if (m) {
        const n = parseInt(lbl.slice(1), 10);
        if (Number.isFinite(n) && n > max) {
          max = n;
        }
      }
    }
  }
  return `A${max + 1}`;
}

// Reserved aspect-ratio values. Documenting in the schema keeps the
// field stable across UI iterations — adding a new ratio is two
// touchpoints: this set + the stage's ASPECT_RATIO_VALUES map.
export const ASPECT_RATIOS = Object.freeze(
  new Set(["free", "1:1", "2:3", "3:2", "4:5", "5:4", "16:9"])
);
const DEFAULT_ASPECT_RATIO = "free";

// ----- Coordinate helpers -----------------------------------------

// Returns the clamped value in [0, 100], or null for anything that
// isn't a finite number. We intentionally do NOT coerce strings — the
// caller (typically a modal action or a server-fed payload) should
// already have parsed types. Returning null lets validators drop the
// whole annotation rather than silently round bogus input to 0.
export function clampPct(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  if (value < 0) {
    return 0;
  }
  if (value > 100) {
    return 100;
  }
  return value;
}

function pinId(number) {
  return `pin_${number}`;
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

// ----- Pin normalizer ---------------------------------------------

// Validates + normalizes a single pin entry. Accepts both the modal's
// in-memory shape (`{ number, xPct, yPct }`) and the canonical schema
// shape (`{ id, kind, number, x_pct, y_pct }`). Returns null when the
// entry is missing required fields.
//
// Required:
//   - number  (integer ≥ 1)  — stable; numbering gaps are preserved by
//                              upstream removal logic
//   - x_pct / y_pct (or xPct / yPct) — numeric, clamped to [0, 100]
//
// Optional:
//   - id      — preserved if non-empty string, otherwise generated as
//               `pin_<number>` so the same number always produces the
//               same id (round-trip-stable)
export function normalizePinAnnotation(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }

  const number = Number.isInteger(raw.number) ? raw.number : null;
  if (number == null || number < 1) {
    return null;
  }

  const xPct = clampPct(raw.x_pct ?? raw.xPct);
  const yPct = clampPct(raw.y_pct ?? raw.yPct);
  if (xPct == null || yPct == null) {
    return null;
  }

  const id = isNonEmptyString(raw.id) ? raw.id : pinId(number);

  return {
    id,
    kind: ANNOTATION_KINDS.PIN,
    number,
    x_pct: xPct,
    y_pct: yPct,
  };
}

// ----- Crop normalizer + conversions ------------------------------

// Validates + normalizes a crop annotation. Accepts both modal-shape
// (`{ xPct, yPct, widthPct, heightPct, aspectRatio }`) and schema-shape
// (`{ id, kind, x_pct, ... }`). Returns null when the entry is invalid
// or below the minimum dimension threshold.
//
// Coordinate normalization:
//   • All four percentages clamped to [0, 100].
//   • The crop is clamped to stay inside the [0, 100] bounding box —
//     if (x + width) exceeds 100 we shrink width, never move x.
//   • width and height must each be ≥ MIN_CROP_DIMENSION_PCT after
//     clamping. Tiny accidental drags become null.
//   • aspect_ratio defaults to "free"; unknown values become "free".
export function normalizeCropAnnotation(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }

  const xPct = clampPct(raw.x_pct ?? raw.xPct);
  const yPct = clampPct(raw.y_pct ?? raw.yPct);
  const rawWidth = clampPct(raw.width_pct ?? raw.widthPct);
  const rawHeight = clampPct(raw.height_pct ?? raw.heightPct);
  if (xPct == null || yPct == null || rawWidth == null || rawHeight == null) {
    return null;
  }

  // Keep the crop inside the image. Width/height shrink rather than
  // moving the top-left, so the user-intended origin is preserved.
  const widthPct = Math.min(rawWidth, 100 - xPct);
  const heightPct = Math.min(rawHeight, 100 - yPct);

  if (widthPct < MIN_CROP_DIMENSION_PCT || heightPct < MIN_CROP_DIMENSION_PCT) {
    return null;
  }

  const rawAspect = raw.aspect_ratio ?? raw.aspectRatio;
  const aspect_ratio = ASPECT_RATIOS.has(rawAspect)
    ? rawAspect
    : DEFAULT_ASPECT_RATIO;

  const id = isNonEmptyString(raw.id) ? raw.id : "crop_1";

  return {
    id,
    kind: ANNOTATION_KINDS.CROP,
    x_pct: xPct,
    y_pct: yPct,
    width_pct: widthPct,
    height_pct: heightPct,
    aspect_ratio,
  };
}

// ----- Eye-path normalizer + conversions --------------------------

// Validates + normalizes an eye-path annotation. Accepts both modal-
// shape (`{ id, points: [{ number, xPct, yPct }] }`) and schema-shape
// (`{ id, kind, points: [{ number, x_pct, y_pct }] }`). Returns null
// when the entry has no valid points.
//
// Coordinate normalization:
//   • Each point's x/y clamped to [0, 100]; invalid points dropped.
//   • Points re-numbered sequentially after filtering, so callers
//     don't have to repair gaps introduced by upstream removal.
//   • Excess points beyond MAX_EYE_PATH_POINTS truncated from the end
//     (oldest survives; matches how the modal builds the path).
export function normalizeEyePathAnnotation(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const rawPoints = Array.isArray(raw.points) ? raw.points : [];
  const valid = [];
  for (const p of rawPoints) {
    if (valid.length >= MAX_EYE_PATH_POINTS) {
      break;
    }
    if (!p || typeof p !== "object") {
      continue;
    }
    const xPct = clampPct(p.x_pct ?? p.xPct);
    const yPct = clampPct(p.y_pct ?? p.yPct);
    if (xPct == null || yPct == null) {
      continue;
    }
    valid.push({ x_pct: xPct, y_pct: yPct });
  }
  if (valid.length === 0) {
    return null;
  }
  // Renumber 1..N — keeps the rendered point labels stable even
  // after invalid points were dropped or the input was reordered.
  const points = valid.map((p, idx) => ({
    number: idx + 1,
    x_pct: p.x_pct,
    y_pct: p.y_pct,
  }));
  // id/label may be null on output — the annotations-array normalizer
  // assigns position-based defaults + dedupes against any earlier
  // entries in the same payload. This keeps multiple eye-paths in a
  // single payload from all defaulting to "eye_path_1" / "E1".
  const id = isNonEmptyString(raw.id) ? raw.id : null;
  const rawLabel = raw.label;
  const label =
    typeof rawLabel === "string" && EYE_PATH_LABEL_PATTERN.test(rawLabel)
      ? rawLabel
      : null;
  return {
    id,
    kind: ANNOTATION_KINDS.EYE_PATH,
    label,
    points,
  };
}

// Modal eye-path model:
//   { id, points: [{ number, xPct, yPct }] }
// Schema eye-path is the same fields snake_case + kind.

export function eyePathToAnnotation(eyePath) {
  if (!eyePath || !Array.isArray(eyePath.points)) {
    return null;
  }
  // id/label preserved as-supplied (typically the modal generates
  // unique values per path); normalizeAnnotationsArray dedupes if
  // anything slips through without a unique id/label.
  return normalizeEyePathAnnotation({
    id: eyePath.id ?? null,
    label: eyePath.label ?? null,
    kind: ANNOTATION_KINDS.EYE_PATH,
    points: eyePath.points.map((p) => ({
      number: p.number,
      x_pct: p.xPct,
      y_pct: p.yPct,
    })),
  });
}

// Convert an array of modal-shape eye paths to schema annotation
// entries. Mirrors `attentionPullsToAnnotations`. Filters out paths
// that normalize to null (e.g. all points invalid).
export function eyePathsToAnnotations(eyePaths) {
  if (!Array.isArray(eyePaths)) {
    return [];
  }
  const out = [];
  for (const path of eyePaths) {
    const annotation = eyePathToAnnotation(path);
    if (annotation) {
      out.push(annotation);
    }
  }
  return out;
}

export function annotationToEyePath(annotation) {
  if (!annotation || annotation.kind !== ANNOTATION_KINDS.EYE_PATH) {
    return null;
  }
  return {
    id: annotation.id,
    label: annotation.label,
    points: annotation.points.map((p) => ({
      number: p.number,
      xPct: p.x_pct,
      yPct: p.y_pct,
    })),
  };
}

// ----- Attention-pull normalizer + conversions --------------------

// Validates + normalizes an attention-pull annotation. Accepts modal-
// shape (`{ id, xPct, yPct, widthPct, heightPct }`) and schema-shape
// (`{ id, kind, shape, x_pct, ... }`). Returns null when the entry is
// invalid or below the minimum dimension threshold (~misclick).
//
// Coordinate normalization mirrors the crop logic:
//   • All four percentages clamped to [0, 100].
//   • Bounding box stays inside the image — overflow shrinks
//     width/height rather than moving x/y, preserving the user's
//     intended top-left.
//   • Width and height must each be ≥ MIN_ATTENTION_PULL_DIMENSION_PCT
//     after clamping.
//   • `shape` defaults to "ellipse" — the only shape we render for v1.
export function normalizeAttentionPullAnnotation(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const xPct = clampPct(raw.x_pct ?? raw.xPct);
  const yPct = clampPct(raw.y_pct ?? raw.yPct);
  const rawWidth = clampPct(raw.width_pct ?? raw.widthPct);
  const rawHeight = clampPct(raw.height_pct ?? raw.heightPct);
  if (xPct == null || yPct == null || rawWidth == null || rawHeight == null) {
    return null;
  }
  const widthPct = Math.min(rawWidth, 100 - xPct);
  const heightPct = Math.min(rawHeight, 100 - yPct);
  if (
    widthPct < MIN_ATTENTION_PULL_DIMENSION_PCT ||
    heightPct < MIN_ATTENTION_PULL_DIMENSION_PCT
  ) {
    return null;
  }
  const id = isNonEmptyString(raw.id) ? raw.id : null;
  // Label is preserved when it matches the strict A<N> pattern; the
  // caller (attentionPullsToAnnotations / normalizeAnnotationsArray)
  // assigns one via nextAttentionPullLabel if missing or invalid.
  const rawLabel = raw.label;
  const label =
    typeof rawLabel === "string" && ATTENTION_PULL_LABEL_PATTERN.test(rawLabel)
      ? rawLabel
      : null;
  return {
    id,
    kind: ANNOTATION_KINDS.ATTENTION_PULL,
    shape: "ellipse",
    label,
    x_pct: xPct,
    y_pct: yPct,
    width_pct: widthPct,
    height_pct: heightPct,
  };
}

// Modal attention-pull model shape:
//   { id, xPct, yPct, widthPct, heightPct }
// Schema attention-pull is the same fields snake_case + kind + shape.

export function attentionPullsToAnnotations(pulls) {
  if (!Array.isArray(pulls)) {
    return [];
  }
  const out = [];
  let idCounter = 1;
  // Labels assigned/preserved here are used by the renderer and the
  // exported image. Track ones we've already emitted to detect dupes.
  const usedLabels = new Set();
  for (const pull of pulls) {
    if (out.length >= MAX_ATTENTION_PULL_COUNT) {
      break;
    }
    const normalized = normalizeAttentionPullAnnotation({
      id: pull.id ?? `attention_pull_${idCounter}`,
      label: pull.label,
      x_pct: pull.xPct,
      y_pct: pull.yPct,
      width_pct: pull.widthPct,
      height_pct: pull.heightPct,
    });
    if (normalized) {
      if (!normalized.id) {
        normalized.id = `attention_pull_${idCounter}`;
      }
      // Preserve valid + unique labels; regenerate via max-suffix+1
      // when missing OR colliding with an already-emitted label.
      if (!normalized.label || usedLabels.has(normalized.label)) {
        normalized.label = nextAttentionPullLabel(Array.from(usedLabels));
      }
      usedLabels.add(normalized.label);
      out.push(normalized);
      idCounter += 1;
    }
  }
  return out;
}

export function annotationsToAttentionPulls(payload) {
  if (!payload || !Array.isArray(payload.annotations)) {
    return [];
  }
  const out = [];
  for (const a of payload.annotations) {
    if (a?.kind !== ANNOTATION_KINDS.ATTENTION_PULL) {
      continue;
    }
    out.push({
      id: a.id,
      label: a.label,
      xPct: a.x_pct,
      yPct: a.y_pct,
      widthPct: a.width_pct,
      heightPct: a.height_pct,
    });
  }
  return out;
}

// ----- Strong-area normalizer + conversions ------------------------

// Strong area is the positive counterpart to Attention Pull — same
// geometry shape and same validation rules; the kind, label prefix,
// and renderer styling are what differ.
export function nextStrongAreaLabel(existingLabels) {
  let max = 0;
  if (Array.isArray(existingLabels)) {
    for (const lbl of existingLabels) {
      if (typeof lbl !== "string") {
        continue;
      }
      const m = STRONG_AREA_LABEL_PATTERN.exec(lbl);
      if (m) {
        const n = parseInt(lbl.slice(1), 10);
        if (Number.isFinite(n) && n > max) {
          max = n;
        }
      }
    }
  }
  return `S${max + 1}`;
}

export function normalizeStrongAreaAnnotation(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const xPct = clampPct(raw.x_pct ?? raw.xPct);
  const yPct = clampPct(raw.y_pct ?? raw.yPct);
  const rawWidth = clampPct(raw.width_pct ?? raw.widthPct);
  const rawHeight = clampPct(raw.height_pct ?? raw.heightPct);
  if (xPct == null || yPct == null || rawWidth == null || rawHeight == null) {
    return null;
  }
  const widthPct = Math.min(rawWidth, 100 - xPct);
  const heightPct = Math.min(rawHeight, 100 - yPct);
  if (
    widthPct < MIN_STRONG_AREA_DIMENSION_PCT ||
    heightPct < MIN_STRONG_AREA_DIMENSION_PCT
  ) {
    return null;
  }
  const id = isNonEmptyString(raw.id) ? raw.id : null;
  const rawLabel = raw.label;
  const label =
    typeof rawLabel === "string" && STRONG_AREA_LABEL_PATTERN.test(rawLabel)
      ? rawLabel
      : null;
  return {
    id,
    kind: ANNOTATION_KINDS.STRONG_AREA,
    shape: "ellipse",
    label,
    x_pct: xPct,
    y_pct: yPct,
    width_pct: widthPct,
    height_pct: heightPct,
  };
}

export function strongAreasToAnnotations(areas) {
  if (!Array.isArray(areas)) {
    return [];
  }
  const out = [];
  let idCounter = 1;
  const usedLabels = new Set();
  for (const area of areas) {
    if (out.length >= MAX_STRONG_AREA_COUNT) {
      break;
    }
    const normalized = normalizeStrongAreaAnnotation({
      id: area.id ?? `strong_area_${idCounter}`,
      label: area.label,
      x_pct: area.xPct,
      y_pct: area.yPct,
      width_pct: area.widthPct,
      height_pct: area.heightPct,
    });
    if (normalized) {
      if (!normalized.id) {
        normalized.id = `strong_area_${idCounter}`;
      }
      if (!normalized.label || usedLabels.has(normalized.label)) {
        normalized.label = nextStrongAreaLabel(Array.from(usedLabels));
      }
      usedLabels.add(normalized.label);
      out.push(normalized);
      idCounter += 1;
    }
  }
  return out;
}

export function annotationsToStrongAreas(payload) {
  if (!payload || !Array.isArray(payload.annotations)) {
    return [];
  }
  const out = [];
  for (const a of payload.annotations) {
    if (a?.kind !== ANNOTATION_KINDS.STRONG_AREA) {
      continue;
    }
    out.push({
      id: a.id,
      label: a.label,
      xPct: a.x_pct,
      yPct: a.y_pct,
      widthPct: a.width_pct,
      heightPct: a.height_pct,
    });
  }
  return out;
}

// Modal crop model shape:
//   { xPct, yPct, widthPct, heightPct, aspectRatio }
// Schema crop is the same fields snake_case + id + kind.

export function cropToAnnotation(crop) {
  if (!crop) {
    return null;
  }
  return normalizeCropAnnotation({
    id: crop.id ?? "crop_1",
    kind: ANNOTATION_KINDS.CROP,
    x_pct: crop.xPct,
    y_pct: crop.yPct,
    width_pct: crop.widthPct,
    height_pct: crop.heightPct,
    aspect_ratio: crop.aspectRatio ?? DEFAULT_ASPECT_RATIO,
  });
}

export function annotationToCrop(annotation) {
  if (!annotation || annotation.kind !== ANNOTATION_KINDS.CROP) {
    return null;
  }
  return {
    id: annotation.id,
    xPct: annotation.x_pct,
    yPct: annotation.y_pct,
    widthPct: annotation.width_pct,
    heightPct: annotation.height_pct,
    aspectRatio: annotation.aspect_ratio ?? DEFAULT_ASPECT_RATIO,
  };
}

// ----- Modal pin model ↔ schema annotation conversion -------------

// Today's modal pin model uses camelCase + an `imageVersionKey`. The
// schema uses snake_case + carries `image_version_key` once at the
// payload level (under `source`). Both directions intentionally lose
// the per-pin version key — it isn't a per-pin attribute, the whole
// annotation set is tied to a single image version.

export function pinsToAnnotations(pins) {
  if (!Array.isArray(pins)) {
    return [];
  }
  const out = [];
  for (const pin of pins) {
    if (out.length >= MAX_PIN_COUNT) {
      break;
    }
    const normalized = normalizePinAnnotation(pin);
    if (normalized) {
      out.push(normalized);
    }
  }
  return out;
}

// Reverse direction — useful when re-opening a previously-posted
// critique for editing (a future step). Pulls the version key from
// `source` so the caller can apply it back onto the modal model.
export function annotationsToPins(payload) {
  if (!payload || !Array.isArray(payload.annotations)) {
    return [];
  }
  const versionKey = payload.source?.image_version_key ?? null;
  const out = [];
  for (const a of payload.annotations) {
    if (a?.kind !== ANNOTATION_KINDS.PIN) {
      continue;
    }
    out.push({
      number: a.number,
      xPct: a.x_pct,
      yPct: a.y_pct,
      imageVersionKey: versionKey,
    });
  }
  return out;
}

// ----- Source / visual-output normalizers -------------------------
//
// `source` describes the image the annotations were placed on. We
// snapshot the version's upload_id + URL at annotation time so future
// readers don't have to re-resolve through the topic's metadata.
//
// `visual_output` describes the flattened JPEG that was uploaded and
// included in the post body. When pins were placed but the
// export/upload step was skipped via the "Post without visual notes"
// fallback, this is null.

function normalizeSourceFromInputs({ topic, selectedVersion }) {
  if (!topic && !selectedVersion) {
    return null;
  }
  return {
    topic_id: Number.isInteger(topic?.id) ? topic.id : null,
    image_version_key: isNonEmptyString(selectedVersion?.key)
      ? selectedVersion.key
      : null,
    image_version_label: isNonEmptyString(selectedVersion?.label)
      ? selectedVersion.label
      : null,
    source_upload_id: Number.isInteger(selectedVersion?.upload_id)
      ? selectedVersion.upload_id
      : null,
    source_url: isNonEmptyString(selectedVersion?.url)
      ? selectedVersion.url
      : null,
  };
}

function normalizeSourceFromRaw(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  return {
    topic_id: Number.isInteger(raw.topic_id) ? raw.topic_id : null,
    image_version_key: isNonEmptyString(raw.image_version_key)
      ? raw.image_version_key
      : null,
    image_version_label: isNonEmptyString(raw.image_version_label)
      ? raw.image_version_label
      : null,
    source_upload_id: Number.isInteger(raw.source_upload_id)
      ? raw.source_upload_id
      : null,
    source_url: isNonEmptyString(raw.source_url) ? raw.source_url : null,
  };
}

function normalizeVisualOutputFromInput(upload) {
  if (!upload || typeof upload !== "object") {
    return null;
  }
  // Discourse's /uploads.json returns `id` (not `upload_id`); we accept
  // either so callers don't have to remap before calling.
  const uploadId = Number.isInteger(upload.id)
    ? upload.id
    : Number.isInteger(upload.upload_id)
      ? upload.upload_id
      : null;
  const url = isNonEmptyString(upload.url) ? upload.url : null;
  const shortUrl = isNonEmptyString(upload.short_url)
    ? upload.short_url
    : null;
  if (uploadId == null && url == null && shortUrl == null) {
    return null;
  }
  return { upload_id: uploadId, url, short_url: shortUrl };
}

function normalizeVisualOutputFromRaw(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const uploadId = Number.isInteger(raw.upload_id) ? raw.upload_id : null;
  const url = isNonEmptyString(raw.url) ? raw.url : null;
  const shortUrl = isNonEmptyString(raw.short_url) ? raw.short_url : null;
  if (uploadId == null && url == null && shortUrl == null) {
    return null;
  }
  return { upload_id: uploadId, url, short_url: shortUrl };
}

// ----- Builder (modal-side) ---------------------------------------

// Used by the critique modal to produce a fresh payload from the
// current in-memory state. `pins` is the modal's `notes` array.
// `visualUpload` is the response from /uploads.json (or null when the
// "Post without visual notes" fallback was taken).
//
// The resulting payload is already normalized — callers don't need to
// run it through normalizeVisualAnnotationPayload before using it.
export function buildVisualAnnotationPayload({
  topic,
  selectedVersion,
  visualUpload,
  pins,
  crop,
  eyePaths,
  attentionPulls,
  strongAreas,
} = {}) {
  const annotations = pinsToAnnotations(pins ?? []);
  if (crop) {
    const cropAnnotation = cropToAnnotation(crop);
    if (cropAnnotation) {
      annotations.push(cropAnnotation);
    }
  }
  if (Array.isArray(eyePaths) && eyePaths.length > 0) {
    for (const eyePathAnnotation of eyePathsToAnnotations(eyePaths)) {
      annotations.push(eyePathAnnotation);
    }
  }
  if (Array.isArray(attentionPulls) && attentionPulls.length > 0) {
    for (const pullAnnotation of attentionPullsToAnnotations(attentionPulls)) {
      annotations.push(pullAnnotation);
    }
  }
  if (Array.isArray(strongAreas) && strongAreas.length > 0) {
    for (const areaAnnotation of strongAreasToAnnotations(strongAreas)) {
      annotations.push(areaAnnotation);
    }
  }
  return {
    schema_version: VISUAL_ANNOTATION_SCHEMA_VERSION,
    source: normalizeSourceFromInputs({ topic, selectedVersion }),
    visual_output: normalizeVisualOutputFromInput(visualUpload),
    annotations,
  };
}

// ----- Annotations array normalizer -------------------------------

function normalizeAnnotationsArray(raw) {
  if (!Array.isArray(raw)) {
    return [];
  }
  const seenIds = new Set();
  let cropCount = 0;
  let eyePathCount = 0;
  let eyePathIdCounter = 1;
  const usedEyePathLabels = new Set();
  let attentionPullCount = 0;
  let attentionPullIdCounter = 1;
  const usedAttentionPullLabels = new Set();
  let strongAreaCount = 0;
  let strongAreaIdCounter = 1;
  const usedStrongAreaLabels = new Set();
  const out = [];
  for (const entry of raw) {
    if (out.length >= MAX_ANNOTATION_COUNT) {
      break;
    }
    const kind = entry?.kind;
    // Reserved-but-inactive kinds are intentionally dropped in v1.
    if (!ACTIVE_KINDS_V1.has(kind)) {
      continue;
    }

    let normalized = null;
    switch (kind) {
      case ANNOTATION_KINDS.PIN:
        normalized = normalizePinAnnotation(entry);
        break;
      case ANNOTATION_KINDS.CROP:
        // Enforce MAX_CROP_COUNT — first valid crop wins. Multiple
        // crops in the same payload signal a bug upstream; safer to
        // drop the extras than to surface them.
        if (cropCount >= MAX_CROP_COUNT) {
          continue;
        }
        normalized = normalizeCropAnnotation(entry);
        if (normalized) {
          cropCount += 1;
        }
        break;
      case ANNOTATION_KINDS.EYE_PATH:
        // Up to MAX_EYE_PATH_COUNT paths per payload. Each gets a
        // unique id + label; after-cap entries are silently dropped
        // (matches the cap-enforcing behavior on the modal side).
        // Same pattern as attention_pull / strong_area below.
        if (eyePathCount >= MAX_EYE_PATH_COUNT) {
          continue;
        }
        normalized = normalizeEyePathAnnotation(entry);
        if (normalized) {
          if (!normalized.id) {
            normalized.id = `eye_path_${eyePathIdCounter}`;
          }
          if (!normalized.label || usedEyePathLabels.has(normalized.label)) {
            normalized.label = nextEyePathLabel(
              Array.from(usedEyePathLabels)
            );
          }
          usedEyePathLabels.add(normalized.label);
          eyePathCount += 1;
          eyePathIdCounter += 1;
        }
        break;
      case ANNOTATION_KINDS.ATTENTION_PULL:
        // Multiple allowed up to the cap. After-cap entries are
        // silently dropped to mirror the modal's cap-enforcing
        // addAttentionPull action.
        if (attentionPullCount >= MAX_ATTENTION_PULL_COUNT) {
          continue;
        }
        normalized = normalizeAttentionPullAnnotation(entry);
        if (normalized) {
          if (!normalized.id) {
            normalized.id = `attention_pull_${attentionPullIdCounter}`;
          }
          // Preserve valid + unique labels; regenerate via max-suffix+1
          // when missing OR colliding with an already-emitted label.
          if (
            !normalized.label ||
            usedAttentionPullLabels.has(normalized.label)
          ) {
            normalized.label = nextAttentionPullLabel(
              Array.from(usedAttentionPullLabels)
            );
          }
          usedAttentionPullLabels.add(normalized.label);
          attentionPullCount += 1;
          attentionPullIdCounter += 1;
        }
        break;
      case ANNOTATION_KINDS.STRONG_AREA:
        // Same cap + label semantics as attention pull, with "S<N>"
        // prefix instead of "A<N>".
        if (strongAreaCount >= MAX_STRONG_AREA_COUNT) {
          continue;
        }
        normalized = normalizeStrongAreaAnnotation(entry);
        if (normalized) {
          if (!normalized.id) {
            normalized.id = `strong_area_${strongAreaIdCounter}`;
          }
          if (
            !normalized.label ||
            usedStrongAreaLabels.has(normalized.label)
          ) {
            normalized.label = nextStrongAreaLabel(
              Array.from(usedStrongAreaLabels)
            );
          }
          usedStrongAreaLabels.add(normalized.label);
          strongAreaCount += 1;
          strongAreaIdCounter += 1;
        }
        break;
      default:
        normalized = null;
    }
    if (!normalized) {
      continue;
    }

    if (seenIds.has(normalized.id)) {
      continue;
    }
    seenIds.add(normalized.id);
    out.push(normalized);
  }
  return out;
}

// ----- Top-level normalizer (server-side / round-trip) ------------

// Accepts ANY input — server-fed payload, hand-edited JSON, an older
// schema version — and produces a v1-shaped payload with sane
// fallbacks. Never throws. Used by:
//   • the modal's reader (if/when we open existing critique posts for
//     editing in a later step),
//   • any future server-side validator that wants to round-trip a
//     payload before storing it.
export function normalizeVisualAnnotationPayload(input) {
  if (!input || typeof input !== "object") {
    return emptyPayload();
  }
  return {
    schema_version: VISUAL_ANNOTATION_SCHEMA_VERSION,
    source: normalizeSourceFromRaw(input.source),
    visual_output: normalizeVisualOutputFromRaw(input.visual_output),
    annotations: normalizeAnnotationsArray(input.annotations),
  };
}

function emptyPayload() {
  return {
    schema_version: VISUAL_ANNOTATION_SCHEMA_VERSION,
    source: null,
    visual_output: null,
    annotations: [],
  };
}

// ----- Self-check (developer aid; no test harness yet) ------------

// Lightweight assertion runner so the module can be sanity-checked
// from the browser console while there's no QUnit harness in this
// plugin. Returns `{ passed, failed, results }`. Pure — no DOM, no
// side effects. Safe to call in production builds.
export function runSelfCheck() {
  const results = [];
  const t = (name, fn) => {
    try {
      const ok = fn() === true;
      results.push({ name, ok });
    } catch (e) {
      results.push({ name, ok: false, error: e?.message ?? String(e) });
    }
  };

  // 1. Current pins convert to schema annotations.
  t("pinsToAnnotations: modal pin model converts", () => {
    const pins = [{ number: 1, xPct: 42.3, yPct: 57.8, imageVersionKey: "x" }];
    const out = pinsToAnnotations(pins);
    return (
      out.length === 1 &&
      out[0].id === "pin_1" &&
      out[0].kind === "pin" &&
      out[0].number === 1 &&
      out[0].x_pct === 42.3 &&
      out[0].y_pct === 57.8
    );
  });

  // 2. Coordinates clamp to 0..100.
  t("clampPct: clamps low/high/finite", () => {
    return (
      clampPct(-12) === 0 &&
      clampPct(0) === 0 &&
      clampPct(42.7) === 42.7 &&
      clampPct(100) === 100 &&
      clampPct(157) === 100 &&
      clampPct(Number.NaN) === null &&
      clampPct("42") === null
    );
  });

  // 3. Invalid pins are dropped.
  t("pinsToAnnotations: invalid pins dropped", () => {
    const pins = [
      { number: 1, xPct: 10, yPct: 20 }, // valid
      { xPct: 10, yPct: 20 }, // no number
      { number: 0, xPct: 10, yPct: 20 }, // number < 1
      { number: 2, xPct: "10", yPct: 20 }, // string coord
      { number: 3, xPct: 10 }, // missing y
      null,
      "not a pin",
      { number: 4, xPct: 10, yPct: 20 }, // valid
    ];
    const out = pinsToAnnotations(pins);
    return (
      out.length === 2 &&
      out[0].number === 1 &&
      out[1].number === 4
    );
  });

  // 4. Stable pin numbers preserved, including gaps.
  t("pinsToAnnotations: number gaps preserved", () => {
    const pins = [
      { number: 1, xPct: 10, yPct: 20 },
      { number: 3, xPct: 30, yPct: 40 }, // [2] was removed
      { number: 4, xPct: 50, yPct: 60 },
    ];
    const out = pinsToAnnotations(pins);
    return (
      out.length === 3 &&
      out.map((a) => a.number).join(",") === "1,3,4" &&
      out.map((a) => a.id).join(",") === "pin_1,pin_3,pin_4"
    );
  });

  // 5. Pin + crop are active; unknown/reserved kinds are dropped.
  t("normalizeVisualAnnotationPayload: pin+crop active, others dropped", () => {
    const payload = normalizeVisualAnnotationPayload({
      schema_version: 1,
      annotations: [
        { id: "pin_1", kind: "pin", number: 1, x_pct: 10, y_pct: 20 },
        { id: "crop_1", kind: "crop", x_pct: 5, y_pct: 5, width_pct: 80, height_pct: 60 },
        { id: "x", kind: "unknown_future_kind" },
        { id: "arrow_1", kind: "arrow" },
      ],
    });
    const kinds = payload.annotations.map((a) => a.kind);
    return (
      payload.annotations.length === 2 &&
      kinds.includes("pin") &&
      kinds.includes("crop")
    );
  });

  // 5b. Only first crop is kept (MAX_CROP_COUNT = 1).
  t("normalizeVisualAnnotationPayload: enforces MAX_CROP_COUNT", () => {
    const payload = normalizeVisualAnnotationPayload({
      annotations: [
        { id: "crop_a", kind: "crop", x_pct: 0, y_pct: 0, width_pct: 50, height_pct: 50 },
        { id: "crop_b", kind: "crop", x_pct: 50, y_pct: 50, width_pct: 30, height_pct: 30 },
      ],
    });
    return (
      payload.annotations.length === 1 &&
      payload.annotations[0].id === "crop_a"
    );
  });

  // 5c. Tiny crop drops out.
  t("normalizeCropAnnotation: drops below MIN_CROP_DIMENSION_PCT", () => {
    const tooNarrow = normalizeCropAnnotation({
      x_pct: 10, y_pct: 10, width_pct: 2, height_pct: 50,
    });
    const tooShort = normalizeCropAnnotation({
      x_pct: 10, y_pct: 10, width_pct: 50, height_pct: 2.5,
    });
    return tooNarrow === null && tooShort === null;
  });

  // 5d. Crop dimensions clamped inside the 0..100 box.
  t("normalizeCropAnnotation: clamps to image bounds", () => {
    const overflow = normalizeCropAnnotation({
      x_pct: 80, y_pct: 70, width_pct: 80, height_pct: 50,
    });
    return (
      overflow !== null &&
      overflow.x_pct === 80 &&
      overflow.y_pct === 70 &&
      overflow.width_pct === 20 &&
      overflow.height_pct === 30
    );
  });

  // 5e. Crop survives the build payload pipeline.
  t("buildVisualAnnotationPayload: crop lands as an annotation", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      crop: {
        xPct: 10, yPct: 12, widthPct: 60, heightPct: 50, aspectRatio: "free",
      },
    });
    return (
      payload.annotations.length === 1 &&
      payload.annotations[0].kind === "crop" &&
      payload.annotations[0].x_pct === 10 &&
      payload.annotations[0].aspect_ratio === "free"
    );
  });

  // 6. Payload includes source image version key/label.
  t("buildVisualAnnotationPayload: source carries version info", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 49 },
      selectedVersion: {
        key: "revision_2",
        label: "Revision 2",
        upload_id: 789,
        url: "/uploads/default/original/1X/source.jpg",
      },
      visualUpload: null,
      pins: [],
    });
    const s = payload.source;
    return (
      s.topic_id === 49 &&
      s.image_version_key === "revision_2" &&
      s.image_version_label === "Revision 2" &&
      s.source_upload_id === 789 &&
      s.source_url === "/uploads/default/original/1X/source.jpg"
    );
  });

  // 7. Payload includes visual upload id/url/short_url when available.
  t("buildVisualAnnotationPayload: visual_output reflects upload response", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 49 },
      selectedVersion: { key: "original", label: "Original" },
      visualUpload: {
        id: 999,
        url: "/uploads/default/original/1X/visual.jpg",
        short_url: "upload://abc.jpg",
      },
      pins: [],
    });
    const v = payload.visual_output;
    return (
      v.upload_id === 999 &&
      v.url === "/uploads/default/original/1X/visual.jpg" &&
      v.short_url === "upload://abc.jpg"
    );
  });

  // 8. Empty pins produce empty annotations array.
  t("buildVisualAnnotationPayload: no pins → []", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 49 },
      selectedVersion: { key: "original" },
      visualUpload: null,
      pins: [],
    });
    return (
      Array.isArray(payload.annotations) && payload.annotations.length === 0
    );
  });

  // 9. normalizeVisualAnnotationPayload tolerates garbage input.
  t("normalizeVisualAnnotationPayload: tolerates garbage", () => {
    const a = normalizeVisualAnnotationPayload(null);
    const b = normalizeVisualAnnotationPayload("oops");
    const c = normalizeVisualAnnotationPayload({});
    return (
      a.schema_version === 1 &&
      a.annotations.length === 0 &&
      b.schema_version === 1 &&
      c.source === null
    );
  });

  // 10. annotationsToPins reverses pinsToAnnotations.
  t("annotationsToPins: round-trip", () => {
    const pins = [
      { number: 1, xPct: 42.3, yPct: 57.8 },
      { number: 3, xPct: 10, yPct: 90 },
    ];
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "revision_2" },
      visualUpload: null,
      pins,
    });
    const back = annotationsToPins(payload);
    return (
      back.length === 2 &&
      back[0].number === 1 &&
      back[0].xPct === 42.3 &&
      back[0].imageVersionKey === "revision_2" &&
      back[1].number === 3
    );
  });

  // 11. Cap enforced.
  t("pinsToAnnotations: enforces MAX_PIN_COUNT", () => {
    const pins = Array.from({ length: 80 }, (_, i) => ({
      number: i + 1,
      xPct: 1,
      yPct: 1,
    }));
    return pinsToAnnotations(pins).length === MAX_PIN_COUNT;
  });

  // 12. MAX_ANNOTATION_COUNT enforced on raw normalize path.
  t("normalizeAnnotationsArray: enforces MAX_ANNOTATION_COUNT", () => {
    const pins = Array.from({ length: 150 }, (_, i) => ({
      id: `pin_${i + 1}`,
      kind: "pin",
      number: i + 1,
      x_pct: 1,
      y_pct: 1,
    }));
    const out = normalizeVisualAnnotationPayload({ annotations: pins });
    return out.annotations.length === MAX_ANNOTATION_COUNT;
  });

  // 14. Eye-path round-trip through builder + normalizer.
  t("eyePathToAnnotation: round-trip through build/normalize", () => {
    const eyePaths = [
      {
        id: "eye_path_1",
        label: "E1",
        points: [
          { number: 1, xPct: 10, yPct: 20 },
          { number: 2, xPct: 30, yPct: 40 },
          { number: 3, xPct: 50, yPct: 60 },
        ],
      },
    ];
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      eyePaths,
    });
    const annotation = payload.annotations[0];
    return (
      payload.annotations.length === 1 &&
      annotation.kind === "eye_path" &&
      annotation.id === "eye_path_1" &&
      annotation.points.length === 3 &&
      annotation.points[0].number === 1 &&
      annotation.points[2].x_pct === 50 &&
      annotation.points[2].y_pct === 60
    );
  });

  // 15. Invalid eye-path points dropped; valid ones renumbered.
  t("normalizeEyePathAnnotation: drops invalid + renumbers", () => {
    const out = normalizeEyePathAnnotation({
      id: "eye_path_1",
      points: [
        { number: 1, x_pct: 10, y_pct: 20 }, // valid
        { number: 2, x_pct: "x", y_pct: 30 }, // bad x
        { number: 3, x_pct: 40, y_pct: 50 }, // valid
        null,
        { number: 5, x_pct: 70, y_pct: 80 }, // valid
      ],
    });
    return (
      out !== null &&
      out.points.length === 3 &&
      out.points.map((p) => p.number).join(",") === "1,2,3"
    );
  });

  // 16. MAX_EYE_PATH_POINTS truncates the tail.
  t("normalizeEyePathAnnotation: truncates beyond MAX_EYE_PATH_POINTS", () => {
    const points = Array.from({ length: 15 }, (_, i) => ({
      number: i + 1,
      x_pct: i,
      y_pct: i,
    }));
    const out = normalizeEyePathAnnotation({ points });
    return out.points.length === MAX_EYE_PATH_POINTS;
  });

  // 17. Empty eye-path becomes null.
  t("normalizeEyePathAnnotation: empty → null", () => {
    return (
      normalizeEyePathAnnotation({ points: [] }) === null &&
      normalizeEyePathAnnotation({ points: [null, { x_pct: "x" }] }) === null
    );
  });

  // 18. After-cap eye_paths dropped (MAX_EYE_PATH_COUNT).
  t("normalizeVisualAnnotationPayload: enforces MAX_EYE_PATH_COUNT", () => {
    const tooMany = Array.from({ length: MAX_EYE_PATH_COUNT + 3 }, (_, i) => ({
      id: `eye_path_${i + 1}`,
      kind: "eye_path",
      points: [{ x_pct: 10 + i, y_pct: 10 + i }],
    }));
    const payload = normalizeVisualAnnotationPayload({ annotations: tooMany });
    const paths = payload.annotations.filter((a) => a.kind === "eye_path");
    return paths.length === MAX_EYE_PATH_COUNT;
  });

  // 18b. Multiple eye_paths under the cap all survive with unique ids/labels.
  t("normalizeVisualAnnotationPayload: keeps multiple paths under cap", () => {
    const payload = normalizeVisualAnnotationPayload({
      annotations: [
        { kind: "eye_path", points: [{ x_pct: 10, y_pct: 10 }] },
        { kind: "eye_path", points: [{ x_pct: 50, y_pct: 50 }] },
      ],
    });
    const paths = payload.annotations.filter((a) => a.kind === "eye_path");
    const ids = new Set(paths.map((p) => p.id));
    const labels = new Set(paths.map((p) => p.label));
    return paths.length === 2 && ids.size === 2 && labels.size === 2;
  });

  // 19. Pin + crop + eye_path all coexist in one payload.
  t("buildVisualAnnotationPayload: pin + crop + eye_path coexist", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [{ number: 1, xPct: 10, yPct: 20 }],
      crop: { xPct: 5, yPct: 5, widthPct: 80, heightPct: 60, aspectRatio: "free" },
      eyePaths: [
        {
          id: "eye_path_1",
          label: "E1",
          points: [
            { number: 1, xPct: 30, yPct: 30 },
            { number: 2, xPct: 60, yPct: 60 },
          ],
        },
      ],
    });
    const kinds = payload.annotations.map((a) => a.kind).sort();
    return (
      payload.annotations.length === 3 &&
      kinds.join(",") === "crop,eye_path,pin"
    );
  });

  // 19b. buildVisualAnnotationPayload accepts multiple eye paths.
  t("buildVisualAnnotationPayload: multiple eye paths", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      eyePaths: [
        {
          id: "eye_path_1",
          label: "E1",
          points: [
            { number: 1, xPct: 10, yPct: 10 },
            { number: 2, xPct: 20, yPct: 20 },
          ],
        },
        {
          id: "eye_path_2",
          label: "E2",
          points: [
            { number: 1, xPct: 60, yPct: 60 },
            { number: 2, xPct: 80, yPct: 80 },
          ],
        },
      ],
    });
    const paths = payload.annotations.filter((a) => a.kind === "eye_path");
    return (
      paths.length === 2 &&
      paths[0].id === "eye_path_1" &&
      paths[1].id === "eye_path_2"
    );
  });

  // 20. annotationToEyePath reverses eyePathToAnnotation.
  t("annotationToEyePath: round-trip", () => {
    const eyePath = {
      id: "eye_path_1",
      label: "E1",
      points: [
        { number: 1, xPct: 10, yPct: 20 },
        { number: 2, xPct: 30, yPct: 40 },
      ],
    };
    const annotation = eyePathToAnnotation(eyePath);
    const back = annotationToEyePath(annotation);
    return (
      back.id === "eye_path_1" &&
      back.points.length === 2 &&
      back.points[0].xPct === 10 &&
      back.points[1].yPct === 40
    );
  });

  // 21. Attention-pull round-trip through builder + normalizer.
  t("attentionPullsToAnnotations: round-trip + id assignment", () => {
    const pulls = [
      { xPct: 10, yPct: 20, widthPct: 15, heightPct: 12 },
      { id: "custom_id", xPct: 50, yPct: 60, widthPct: 20, heightPct: 18 },
    ];
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      attentionPulls: pulls,
    });
    return (
      payload.annotations.length === 2 &&
      payload.annotations[0].kind === "attention_pull" &&
      payload.annotations[0].shape === "ellipse" &&
      payload.annotations[0].id === "attention_pull_1" &&
      payload.annotations[1].id === "custom_id" &&
      payload.annotations[1].x_pct === 50
    );
  });

  // 22. Tiny attention pull dropped (below MIN_ATTENTION_PULL_DIMENSION_PCT).
  t("normalizeAttentionPullAnnotation: drops tiny markers", () => {
    const tooNarrow = normalizeAttentionPullAnnotation({
      x_pct: 10,
      y_pct: 10,
      width_pct: 2,
      height_pct: 12,
    });
    const tooShort = normalizeAttentionPullAnnotation({
      x_pct: 10,
      y_pct: 10,
      width_pct: 12,
      height_pct: 2.5,
    });
    return tooNarrow === null && tooShort === null;
  });

  // 23. Attention-pull bounding box clamped to image.
  t("normalizeAttentionPullAnnotation: clamps to image bounds", () => {
    const overflow = normalizeAttentionPullAnnotation({
      x_pct: 75,
      y_pct: 80,
      width_pct: 40,
      height_pct: 30,
    });
    return (
      overflow !== null &&
      overflow.x_pct === 75 &&
      overflow.y_pct === 80 &&
      overflow.width_pct === 25 &&
      overflow.height_pct === 20
    );
  });

  // 24. MAX_ATTENTION_PULL_COUNT enforced on raw normalize path.
  t("normalizeAnnotationsArray: enforces MAX_ATTENTION_PULL_COUNT", () => {
    const many = Array.from({ length: 15 }, (_, i) => ({
      id: `ap_${i}`,
      kind: "attention_pull",
      x_pct: 5 + i,
      y_pct: 5,
      width_pct: 10,
      height_pct: 10,
    }));
    const payload = normalizeVisualAnnotationPayload({ annotations: many });
    const pulls = payload.annotations.filter(
      (a) => a.kind === "attention_pull"
    );
    return pulls.length === MAX_ATTENTION_PULL_COUNT;
  });

  // 25. Pin + crop + eye_path + attention_pull all coexist.
  t("buildVisualAnnotationPayload: all four kinds coexist", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [{ number: 1, xPct: 10, yPct: 20 }],
      crop: { xPct: 5, yPct: 5, widthPct: 80, heightPct: 60, aspectRatio: "free" },
      eyePaths: [
        {
          id: "eye_path_1",
          label: "E1",
          points: [
            { number: 1, xPct: 30, yPct: 30 },
            { number: 2, xPct: 60, yPct: 60 },
          ],
        },
      ],
      attentionPulls: [
        { xPct: 40, yPct: 50, widthPct: 15, heightPct: 12 },
      ],
    });
    const kinds = payload.annotations.map((a) => a.kind).sort();
    return (
      payload.annotations.length === 4 &&
      kinds.join(",") === "attention_pull,crop,eye_path,pin"
    );
  });

  // 26. annotationsToAttentionPulls reverses attentionPullsToAnnotations.
  t("annotationsToAttentionPulls: round-trip", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      attentionPulls: [
        { xPct: 10, yPct: 20, widthPct: 15, heightPct: 12 },
        { xPct: 60, yPct: 70, widthPct: 20, heightPct: 18 },
      ],
    });
    const back = annotationsToAttentionPulls(payload);
    return (
      back.length === 2 &&
      back[0].xPct === 10 &&
      back[0].widthPct === 15 &&
      back[1].yPct === 70
    );
  });

  // 27. Attention-pull labels are sequential A1, A2, A3 when none
  // are supplied.
  t("attentionPullsToAnnotations: generates sequential A-labels", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      attentionPulls: [
        { xPct: 10, yPct: 10, widthPct: 10, heightPct: 10 },
        { xPct: 30, yPct: 30, widthPct: 10, heightPct: 10 },
        { xPct: 60, yPct: 60, widthPct: 10, heightPct: 10 },
      ],
    });
    const labels = payload.annotations.map((a) => a.label);
    return labels.join(",") === "A1,A2,A3";
  });

  // 28. Valid input labels are preserved.
  t("attentionPullsToAnnotations: preserves valid input labels", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      attentionPulls: [
        { label: "A1", xPct: 10, yPct: 10, widthPct: 10, heightPct: 10 },
        { label: "A5", xPct: 30, yPct: 30, widthPct: 10, heightPct: 10 },
      ],
    });
    const labels = payload.annotations.map((a) => a.label);
    return labels.join(",") === "A1,A5";
  });

  // 29. Garbage labels get regenerated using max-suffix+1.
  t("attentionPullsToAnnotations: regenerates invalid labels", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      attentionPulls: [
        { label: "A1", xPct: 10, yPct: 10, widthPct: 10, heightPct: 10 },
        { label: "garbage", xPct: 30, yPct: 30, widthPct: 10, heightPct: 10 },
        { label: "AP3", xPct: 60, yPct: 60, widthPct: 10, heightPct: 10 },
      ],
    });
    const labels = payload.annotations.map((a) => a.label);
    return labels.join(",") === "A1,A2,A3";
  });

  // 30. Duplicate labels deduped via regeneration.
  t("attentionPullsToAnnotations: regenerates duplicate labels", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      attentionPulls: [
        { label: "A1", xPct: 10, yPct: 10, widthPct: 10, heightPct: 10 },
        { label: "A1", xPct: 30, yPct: 30, widthPct: 10, heightPct: 10 },
        { label: "A1", xPct: 60, yPct: 60, widthPct: 10, heightPct: 10 },
      ],
    });
    const labels = payload.annotations.map((a) => a.label);
    return labels.join(",") === "A1,A2,A3";
  });

  // 31. nextAttentionPullLabel computes max-suffix+1 correctly.
  t("nextAttentionPullLabel: max-suffix+1 + handles gaps", () => {
    return (
      nextAttentionPullLabel([]) === "A1" &&
      nextAttentionPullLabel(["A1"]) === "A2" &&
      nextAttentionPullLabel(["A1", "A2", "A3"]) === "A4" &&
      // gap: A1, A3 → max 3, next A4 (not A2)
      nextAttentionPullLabel(["A1", "A3"]) === "A4" &&
      // garbage ignored
      nextAttentionPullLabel(["A1", "garbage", "AP2", "B3"]) === "A2" &&
      // already-removed A2 doesn't reduce the max
      nextAttentionPullLabel(["A1", "A4"]) === "A5"
    );
  });

  // 32. Eye-path label defaults to E1 when missing, preserves valid.
  t("normalizeEyePathAnnotation: label defaults + preserves valid", () => {
    const noLabel = normalizeEyePathAnnotation({
      points: [{ x_pct: 10, y_pct: 10 }],
    });
    const validLabel = normalizeEyePathAnnotation({
      label: "E5",
      points: [{ x_pct: 10, y_pct: 10 }],
    });
    const garbage = normalizeEyePathAnnotation({
      label: "garbage",
      points: [{ x_pct: 10, y_pct: 10 }],
    });
    return (
      noLabel.label === "E1" &&
      validLabel.label === "E5" &&
      garbage.label === "E1"
    );
  });

  // 33. Strong-area sequential S-labels.
  t("strongAreasToAnnotations: generates sequential S-labels", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      strongAreas: [
        { xPct: 10, yPct: 10, widthPct: 10, heightPct: 10 },
        { xPct: 30, yPct: 30, widthPct: 10, heightPct: 10 },
      ],
    });
    const labels = payload.annotations
      .filter((a) => a.kind === "strong_area")
      .map((a) => a.label);
    return labels.join(",") === "S1,S2";
  });

  // 34. Garbage / duplicate strong-area labels regenerated.
  t("strongAreasToAnnotations: regenerates garbage + duplicates", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      strongAreas: [
        { label: "S1", xPct: 10, yPct: 10, widthPct: 10, heightPct: 10 },
        { label: "S1", xPct: 30, yPct: 30, widthPct: 10, heightPct: 10 },
        { label: "garbage", xPct: 50, yPct: 50, widthPct: 10, heightPct: 10 },
      ],
    });
    const labels = payload.annotations
      .filter((a) => a.kind === "strong_area")
      .map((a) => a.label);
    return labels.join(",") === "S1,S2,S3";
  });

  // 35. nextStrongAreaLabel max-suffix+1 with gaps.
  t("nextStrongAreaLabel: max-suffix+1 + handles gaps", () => {
    return (
      nextStrongAreaLabel([]) === "S1" &&
      nextStrongAreaLabel(["S1"]) === "S2" &&
      nextStrongAreaLabel(["S1", "S2", "S3"]) === "S4" &&
      nextStrongAreaLabel(["S1", "S3"]) === "S4" &&
      nextStrongAreaLabel(["S1", "garbage", "A2"]) === "S2"
    );
  });

  // 36. All five active kinds coexist in a single payload.
  t("buildVisualAnnotationPayload: five-kind payload", () => {
    const payload = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [{ number: 1, xPct: 10, yPct: 10 }],
      crop: {
        xPct: 5,
        yPct: 5,
        widthPct: 80,
        heightPct: 60,
        aspectRatio: "free",
      },
      eyePaths: [
        {
          id: "eye_path_1",
          label: "E1",
          points: [
            { number: 1, xPct: 30, yPct: 30 },
            { number: 2, xPct: 60, yPct: 60 },
          ],
        },
      ],
      attentionPulls: [
        { xPct: 40, yPct: 50, widthPct: 15, heightPct: 12 },
      ],
      strongAreas: [
        { xPct: 70, yPct: 30, widthPct: 12, heightPct: 14 },
      ],
    });
    const kinds = payload.annotations.map((a) => a.kind).sort();
    return (
      payload.annotations.length === 5 &&
      kinds.join(",") ===
        "attention_pull,crop,eye_path,pin,strong_area"
    );
  });

  // 13. Duplicate ids deduped.
  t("normalizeAnnotationsArray: dedupes by id", () => {
    const payload = normalizeVisualAnnotationPayload({
      annotations: [
        { id: "pin_1", kind: "pin", number: 1, x_pct: 1, y_pct: 1 },
        { id: "pin_1", kind: "pin", number: 1, x_pct: 99, y_pct: 99 },
      ],
    });
    return (
      payload.annotations.length === 1 &&
      payload.annotations[0].x_pct === 1 // first occurrence wins
    );
  });

  const passed = results.filter((r) => r.ok).length;
  const failed = results.length - passed;
  return { passed, failed, results };
}
