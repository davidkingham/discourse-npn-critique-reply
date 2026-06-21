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

// v2 adds explicit written-text fields so overall critique prose and
// per-image visual-note commentary are stored separately instead of
// being inferred from a single body by annotation-token position:
//   - top-level `overall_critique_text`
//   - per-`sources[]` entry `notes`
// v1 payloads (no text fields) still parse cleanly; readers default
// the new fields to empty.
export const VISUAL_ANNOTATION_SCHEMA_VERSION = 2;

// Upper bound for the separated written-text fields. Mirrors the
// server-side DraftNormalizer::MAX_CRITIQUE_TEXT_LENGTH. The server
// normalizer is authoritative; this is a client-side backstop so we
// never ship an absurd payload.
const MAX_NOTES_TEXT_LENGTH = 50_000;

// Coerce a written-text field to a clean string or null. Whitespace-
// only collapses to null so we don't persist empty note blocks, but
// meaningful internal whitespace/newlines are preserved verbatim — we
// never reflow or trim the body itself.
function cleanNotesText(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    return null;
  }
  return value.length > MAX_NOTES_TEXT_LENGTH
    ? value.slice(0, MAX_NOTES_TEXT_LENGTH)
    : value;
}

export const ANNOTATION_KINDS = Object.freeze({
  PIN: "pin",
  CROP: "crop",
  EYE_PATH: "eye_path",
  // Unified area marker (the toolbar's "Area" tool). New annotations
  // are written as area_note. Renders with the same color family,
  // A<N> labels, and ellipse/path shapes as the legacy attention_pull.
  AREA_NOTE: "area_note",
  // Legacy — superseded by AREA_NOTE. Existing posts and drafts that
  // contain attention_pull entries still deserialize correctly; on
  // next save they're re-emitted as area_note.
  ATTENTION_PULL: "attention_pull",
  // Direction arrow — one-way (single arrowhead), labeled "D<N>".
  // For "this leads my eye toward..." / "this gesture points toward
  // the subject..." use cases. Distinct from eye_path: eye_path is
  // a curve through 2+ points capturing the eye's journey; an arrow
  // is a single straight directional cue.
  DIRECTION_ARROW: "direction_arrow",
  // Relationship arrow — two-way (arrowheads on both ends), labeled
  // "R<N>". For "these areas echo each other" / "these compete with
  // each other" / "this balances that" use cases. Renders with a
  // slightly lighter / dashed stroke so it reads as a relationship
  // line rather than a measurement tool.
  RELATIONSHIP_ARROW: "relationship_arrow",
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
    ANNOTATION_KINDS.AREA_NOTE,
    ANNOTATION_KINDS.ATTENTION_PULL,
    ANNOTATION_KINDS.DIRECTION_ARROW,
    ANNOTATION_KINDS.RELATIONSHIP_ARROW,
  ])
);

// Caps. Sanity limits, not policy — the modal's existing pin UX already
// makes 50 pins absurd, 1 crop is the v1 hard cap (a single crop
// suggestion per critique), and 100 total annotations covers the
// foreseeable crop + arrows + circles + text + eye-path use cases.
export const MAX_PIN_COUNT = 50;
// One crop per submission image — submissions can carry up to 5
// images, and the multi-image picker lets the critic add a crop
// suggestion on each. Was 1 before the multi-image rollout; the
// server-side cap in DraftNormalizer matches.
export const MAX_CROP_COUNT = 5;
export const MAX_ANNOTATION_COUNT = 100;

// Tiny accidental crops should be discarded. 3% width OR height is
// roughly the threshold below which the rect looks like a misclick.
export const MIN_CROP_DIMENSION_PCT = 3;

// Eye-path caps. Up to 4 paths per critique — the eye path is the
// most visually heavy annotation kind (curves crossing the image),
// so the cap is tighter than the 8 used for attention pulls.
// 10 points per path is a generous ceiling — past ~6
// it becomes hard to read on the export at standard sizes, but a
// hard floor keeps the UX simple. The "minimum useful" path is 2
// points (so there's a direction); the schema accepts 1-point paths
// so an in-progress save round-trips without dropping the user's
// first click. The modal renders a hint to add a second.
// Eye Path supports drag-to-trace as well as click-to-drop, so a
// single path can be a continuous freehand-style line. 40 points
// is enough for smooth-looking curves at typical image sizes while
// keeping the per-annotation payload small (≈600 bytes uncompressed
// for a full 40-point path).
export const MAX_EYE_PATH_POINTS = 40;
export const MAX_EYE_PATH_COUNT = 4;

// Closed-area "Draw Area" path variant for Attention Pull.
// Client samples the drag, runs Douglas-Peucker simplification on
// release, and submits a trimmed polyline (typically 6-12 control
// points). MAX caps a defensive hard ceiling; MIN enforces enough
// structure to render a shape; MIN_DIM filters accidental taps.
export const MAX_AREA_PATH_POINTS = 50;
export const MIN_AREA_PATH_POINTS = 4;
export const MIN_AREA_PATH_DIMENSION_PCT = 3;
export const MIN_EYE_PATH_POINTS_FOR_EXPORT = 2;

// Eye-path label pattern + default. Each path gets a stable "E<N>"
// label that the popover writes into the textarea (e.g. "[E1]
// description"). Labels are generated max-suffix+1 so deleting one
// path doesn't shift the numbers of the others — same convention
// as attention pulls.
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

// Area-note caps. Same cap + minimum as the legacy attention_pull
// since they share an in-memory array and a label namespace.
// AREA_NOTE is what new annotations are SERIALIZED as; the modal
// continues to operate on this.attentionPulls in memory so legacy
// attention_pull payloads round-trip cleanly.
export const MAX_AREA_NOTE_COUNT = 8;
export const MIN_AREA_NOTE_DIMENSION_PCT = 3;

// Attention-pull caps. Up to 8 markers per critique — past that the
// image gets crowded and the observational tone is lost. The 3% min
// dimension matches crop's tiny-accident floor; ellipses below it
// look like misclicks rather than intentional areas.
export const MAX_ATTENTION_PULL_COUNT = 8;
export const MIN_ATTENTION_PULL_DIMENSION_PCT = 3;

// Arrow caps. Two distinct labeled tools sharing the same coordinate
// shape (two endpoints):
//   • direction_arrow — one-way arrowhead. "D<N>" labels.
//   • relationship_arrow — both ends arrowed. "R<N>" labels.
// 8 per kind matches attention pulls. 3% minimum total
// distance between endpoints (Pythagorean across the image) drops
// drags that look like misclicks.
export const MAX_DIRECTION_ARROW_COUNT = 8;
export const MAX_RELATIONSHIP_ARROW_COUNT = 8;
export const MIN_ARROW_DISTANCE_PCT = 3;

// Area-note labels reuse the existing A<N> namespace so legacy
// attention_pull labels round-trip without renumbering. Same strict
// pattern.
export const AREA_NOTE_LABEL_PATTERN = /^A\d+$/;

// Attention-pull labels are short "A<N>" tags — visible on the image
// as a small pill and embedded in the critique text as `[A<N>]`. The
// pattern is strict so any garbage in a hand-edited payload gets
// regenerated rather than rendered.
export const ATTENTION_PULL_LABEL_PATTERN = /^A\d+$/;

// Direction arrows use "D<N>" — deliberately not "A" (taken by
// Attention Pull) to keep the in-text references unambiguous.
export const DIRECTION_ARROW_LABEL_PATTERN = /^D\d+$/;

// Relationship arrows use "R<N>".
export const RELATIONSHIP_ARROW_LABEL_PATTERN = /^R\d+$/;

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

// Direction arrow + Relationship arrow label generators. Both follow
// the max-suffix+1 pattern so deleting a marker doesn't shift the
// surviving labels' numbers (D1, D2, D3 with D2 removed → next is D4).
export function nextDirectionArrowLabel(existingLabels) {
  let max = 0;
  if (Array.isArray(existingLabels)) {
    for (const lbl of existingLabels) {
      if (typeof lbl !== "string") {
        continue;
      }
      const m = DIRECTION_ARROW_LABEL_PATTERN.exec(lbl);
      if (m) {
        const n = parseInt(lbl.slice(1), 10);
        if (Number.isFinite(n) && n > max) {
          max = n;
        }
      }
    }
  }
  return `D${max + 1}`;
}

export function nextRelationshipArrowLabel(existingLabels) {
  let max = 0;
  if (Array.isArray(existingLabels)) {
    for (const lbl of existingLabels) {
      if (typeof lbl !== "string") {
        continue;
      }
      const m = RELATIONSHIP_ARROW_LABEL_PATTERN.exec(lbl);
      if (m) {
        const n = parseInt(lbl.slice(1), 10);
        if (Number.isFinite(n) && n > max) {
          max = n;
        }
      }
    }
  }
  return `R${max + 1}`;
}

// Image-transform metadata — emitted on each `sources` entry so
// edit-reopen can rebuild the same view the user posted with. Stores
// the rotation + flips applied to the source upload during
// annotation. Identity (no transform) returns null so the field stays
// absent on the common single-image / un-rotated case.
const VALID_TRANSFORM_ROTATIONS = new Set([0, 90, 180, 270]);

function normalizeImageTransformValue(value) {
  if (!value || typeof value !== "object") {
    return null;
  }
  const rotationRaw = Number(value.rotation);
  const rotation = VALID_TRANSFORM_ROTATIONS.has(rotationRaw) ? rotationRaw : 0;
  const flipH = value.flipH === true || value.flip_h === true;
  const flipV = value.flipV === true || value.flip_v === true;
  if (rotation === 0 && !flipH && !flipV) {
    return null;
  }
  return { rotation, flip_h: flipH, flip_v: flipV };
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
  // Crop label is OPTIONAL — single-crop critiques carry no label
  // and render as "[Crop]" in the post body, while multi-image
  // critiques with 2+ crops stamp each one "Crop 1" / "Crop 2" /
  // etc. Both forms are preserved here so the schema round-trips
  // either way.
  const label = isNonEmptyString(raw.label) ? raw.label : null;

  const out = {
    id,
    kind: ANNOTATION_KINDS.CROP,
    x_pct: xPct,
    y_pct: yPct,
    width_pct: widthPct,
    height_pct: heightPct,
    aspect_ratio,
  };
  if (label) {
    out.label = label;
  }
  return out;
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
// Eye-path interaction modes — discriminator on the persisted
// annotation. "stroke" is the drag-to-trace flowing line (the
// long-standing legacy behavior); "points" is the click-to-add
// numbered stops variant. Missing/unknown values fall back to
// "stroke" so any annotation written before the mode field
// existed renders identically to before.
export const EYE_PATH_MODES = Object.freeze(["stroke", "points"]);
export const DEFAULT_EYE_PATH_MODE = "stroke";

function normalizeEyePathMode(raw) {
  if (typeof raw !== "string") {
    return DEFAULT_EYE_PATH_MODE;
  }
  return EYE_PATH_MODES.includes(raw) ? raw : DEFAULT_EYE_PATH_MODE;
}

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
  const mode = normalizeEyePathMode(raw.mode);
  return {
    id,
    kind: ANNOTATION_KINDS.EYE_PATH,
    label,
    mode,
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
  // id/label/mode preserved as-supplied (typically the modal
  // generates unique values per path and tags each new path with
  // the active mode); normalizeAnnotationsArray dedupes if anything
  // slips through without a unique id/label.
  return normalizeEyePathAnnotation({
    id: eyePath.id ?? null,
    label: eyePath.label ?? null,
    kind: ANNOTATION_KINDS.EYE_PATH,
    mode: eyePath.mode,
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
    // Preserve mode when present; missing mode (legacy entries)
    // falls back to the default ("stroke") so old paths render
    // identically to before the mode split.
    mode: normalizeEyePathMode(annotation.mode),
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
// Closed-area "Draw Area" path normalizer. Parameterized by kind +
// label pattern so callers can reuse it across area-marker kinds.
function normalizeAreaPathAnnotation(raw, kind, labelPattern) {
  const rawPoints = Array.isArray(raw.points) ? raw.points : null;
  if (!rawPoints) {
    return null;
  }
  const points = [];
  for (const p of rawPoints) {
    if (points.length >= MAX_AREA_PATH_POINTS) {
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
    points.push({ x_pct: xPct, y_pct: yPct });
  }
  if (points.length < MIN_AREA_PATH_POINTS) {
    return null;
  }
  // Bounding-box check: filter accidental taps.
  const xs = points.map((pt) => pt.x_pct);
  const ys = points.map((pt) => pt.y_pct);
  const widthPct = Math.max(...xs) - Math.min(...xs);
  const heightPct = Math.max(...ys) - Math.min(...ys);
  if (
    widthPct < MIN_AREA_PATH_DIMENSION_PCT &&
    heightPct < MIN_AREA_PATH_DIMENSION_PCT
  ) {
    return null;
  }
  const id = isNonEmptyString(raw.id) ? raw.id : null;
  const rawLabel = raw.label;
  const label =
    typeof rawLabel === "string" && labelPattern.test(rawLabel)
      ? rawLabel
      : null;
  return {
    id,
    kind,
    shape: "path",
    label,
    points,
  };
}

export function normalizeAttentionPullAnnotation(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  if (raw.shape === "path") {
    return normalizeAreaPathAnnotation(
      raw,
      ANNOTATION_KINDS.ATTENTION_PULL,
      ATTENTION_PULL_LABEL_PATTERN
    );
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

// Area-note normalizer. Same geometry validation as attention_pull —
// the in-memory model and label namespace are identical — but emits
// `kind: "area_note"` so new annotations are stored in the canonical
// post-unification shape. Path-shape and ellipse-shape both supported.
export function normalizeAreaNoteAnnotation(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  if (raw.shape === "path") {
    return normalizeAreaPathAnnotation(
      raw,
      ANNOTATION_KINDS.AREA_NOTE,
      AREA_NOTE_LABEL_PATTERN
    );
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
    widthPct < MIN_AREA_NOTE_DIMENSION_PCT ||
    heightPct < MIN_AREA_NOTE_DIMENSION_PCT
  ) {
    return null;
  }
  const id = isNonEmptyString(raw.id) ? raw.id : null;
  const rawLabel = raw.label;
  const label =
    typeof rawLabel === "string" && AREA_NOTE_LABEL_PATTERN.test(rawLabel)
      ? rawLabel
      : null;
  return {
    id,
    kind: ANNOTATION_KINDS.AREA_NOTE,
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

// Serializes the modal's in-memory area markers to wire format. Each
// entry is emitted with `kind: "area_note"` — the canonical post-
// unification kind. Legacy `attention_pull` entries that were
// restored from older drafts/posts still live in the same in-memory
// array (this.attentionPulls) and get re-emitted as area_note here,
// completing the migration on the next save. Function name preserved
// for caller stability; the OUTPUT KIND is what changed.
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
    if (out.length >= MAX_AREA_NOTE_COUNT) {
      break;
    }
    // Build the raw payload to pass into the normalizer. Path-shape
    // pulls (the Draw Area variant) carry a `points` array instead
    // of x/y/width/height; route those through the shape: "path"
    // branch of the normalizer.
    const raw =
      pull.shape === "path"
        ? {
            id: pull.id ?? `area_note_${idCounter}`,
            label: pull.label,
            shape: "path",
            points: Array.isArray(pull.points)
              ? pull.points.map((p) => ({ x_pct: p.xPct, y_pct: p.yPct }))
              : [],
          }
        : {
            id: pull.id ?? `area_note_${idCounter}`,
            label: pull.label,
            x_pct: pull.xPct,
            y_pct: pull.yPct,
            width_pct: pull.widthPct,
            height_pct: pull.heightPct,
          };
    const normalized = normalizeAreaNoteAnnotation(raw);
    if (normalized) {
      if (!normalized.id) {
        normalized.id = `area_note_${idCounter}`;
      }
      // Preserve valid + unique labels; regenerate via max-suffix+1
      // when missing OR colliding with an already-emitted label.
      // Reuses nextAttentionPullLabel since the label namespaces are
      // shared (both A<N>); legacy attention_pull labels round-trip
      // without renumbering.
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

// Deserializes both AREA_NOTE (canonical, post-unification) and
// ATTENTION_PULL (legacy) wire entries into the same in-memory
// shape used by this.attentionPulls in the modal. Saving the draft
// or posting the critique re-emits the entire set as area_note via
// attentionPullsToAnnotations, completing the migration.
export function annotationsToAttentionPulls(payload) {
  if (!payload || !Array.isArray(payload.annotations)) {
    return [];
  }
  const out = [];
  for (const a of payload.annotations) {
    if (
      a?.kind !== ANNOTATION_KINDS.AREA_NOTE &&
      a?.kind !== ANNOTATION_KINDS.ATTENTION_PULL
    ) {
      continue;
    }
    if (a.shape === "path") {
      out.push({
        id: a.id,
        label: a.label,
        shape: "path",
        points: Array.isArray(a.points)
          ? a.points.map((p) => ({ xPct: p.x_pct, yPct: p.y_pct }))
          : [],
      });
    } else {
      out.push({
        id: a.id,
        label: a.label,
        xPct: a.x_pct,
        yPct: a.y_pct,
        widthPct: a.width_pct,
        heightPct: a.height_pct,
      });
    }
  }
  return out;
}

// ----- Direction-arrow + Relationship-arrow normalizers ----------
//
// Both kinds share the same coordinate shape — two endpoints, in
// percent-of-image. They differ only in how they render (single
// arrowhead vs. double) and in their label patterns (D<N> vs R<N>).
// The per-kind helpers below stay separate so the kind/label/pattern
// stays explicit in every code path; the underlying coordinate
// validation is factored into `normalizeArrowCoords`.
//
// Modal in-memory shape:
//   { id, label, x1Pct, y1Pct, x2Pct, y2Pct, noteText? }
// Schema persisted shape: snake_case + kind.

function normalizeArrowCoords(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const x1 = clampPct(raw.x1_pct ?? raw.x1Pct);
  const y1 = clampPct(raw.y1_pct ?? raw.y1Pct);
  const x2 = clampPct(raw.x2_pct ?? raw.x2Pct);
  const y2 = clampPct(raw.y2_pct ?? raw.y2Pct);
  if (x1 == null || y1 == null || x2 == null || y2 == null) {
    return null;
  }
  // Pythagorean distance in percent-of-image. Anything below the
  // floor reads as a misclick and is dropped — same idea as the
  // tiny-rectangle filter on attention pulls.
  const dx = x2 - x1;
  const dy = y2 - y1;
  if (Math.hypot(dx, dy) < MIN_ARROW_DISTANCE_PCT) {
    return null;
  }
  return { x1_pct: x1, y1_pct: y1, x2_pct: x2, y2_pct: y2 };
}

export function normalizeDirectionArrowAnnotation(raw) {
  const coords = normalizeArrowCoords(raw);
  if (!coords) {
    return null;
  }
  const id = isNonEmptyString(raw.id) ? raw.id : null;
  const rawLabel = raw.label;
  const label =
    typeof rawLabel === "string" && DIRECTION_ARROW_LABEL_PATTERN.test(rawLabel)
      ? rawLabel
      : null;
  return {
    id,
    kind: ANNOTATION_KINDS.DIRECTION_ARROW,
    label,
    ...coords,
  };
}

export function normalizeRelationshipArrowAnnotation(raw) {
  const coords = normalizeArrowCoords(raw);
  if (!coords) {
    return null;
  }
  const id = isNonEmptyString(raw.id) ? raw.id : null;
  const rawLabel = raw.label;
  const label =
    typeof rawLabel === "string" &&
    RELATIONSHIP_ARROW_LABEL_PATTERN.test(rawLabel)
      ? rawLabel
      : null;
  return {
    id,
    kind: ANNOTATION_KINDS.RELATIONSHIP_ARROW,
    label,
    ...coords,
  };
}

// Modal-shape array → schema annotations array. Mirrors
// `attentionPullsToAnnotations`.
export function directionArrowsToAnnotations(arrows) {
  if (!Array.isArray(arrows)) {
    return [];
  }
  const out = [];
  let idCounter = 1;
  const usedLabels = new Set();
  for (const arrow of arrows) {
    if (out.length >= MAX_DIRECTION_ARROW_COUNT) {
      break;
    }
    const normalized = normalizeDirectionArrowAnnotation({
      id: arrow.id ?? `direction_arrow_${idCounter}`,
      label: arrow.label,
      x1_pct: arrow.x1Pct,
      y1_pct: arrow.y1Pct,
      x2_pct: arrow.x2Pct,
      y2_pct: arrow.y2Pct,
    });
    if (normalized) {
      if (!normalized.id) {
        normalized.id = `direction_arrow_${idCounter}`;
      }
      if (!normalized.label || usedLabels.has(normalized.label)) {
        normalized.label = nextDirectionArrowLabel(Array.from(usedLabels));
      }
      usedLabels.add(normalized.label);
      out.push(normalized);
      idCounter += 1;
    }
  }
  return out;
}

export function relationshipArrowsToAnnotations(arrows) {
  if (!Array.isArray(arrows)) {
    return [];
  }
  const out = [];
  let idCounter = 1;
  const usedLabels = new Set();
  for (const arrow of arrows) {
    if (out.length >= MAX_RELATIONSHIP_ARROW_COUNT) {
      break;
    }
    const normalized = normalizeRelationshipArrowAnnotation({
      id: arrow.id ?? `relationship_arrow_${idCounter}`,
      label: arrow.label,
      x1_pct: arrow.x1Pct,
      y1_pct: arrow.y1Pct,
      x2_pct: arrow.x2Pct,
      y2_pct: arrow.y2Pct,
    });
    if (normalized) {
      if (!normalized.id) {
        normalized.id = `relationship_arrow_${idCounter}`;
      }
      if (!normalized.label || usedLabels.has(normalized.label)) {
        normalized.label = nextRelationshipArrowLabel(Array.from(usedLabels));
      }
      usedLabels.add(normalized.label);
      out.push(normalized);
      idCounter += 1;
    }
  }
  return out;
}

// Schema → modal-shape array. Used by edit-mode / draft restore.
export function annotationsToDirectionArrows(payload) {
  if (!payload || !Array.isArray(payload.annotations)) {
    return [];
  }
  const out = [];
  for (const a of payload.annotations) {
    if (a?.kind !== ANNOTATION_KINDS.DIRECTION_ARROW) {
      continue;
    }
    out.push({
      id: a.id,
      label: a.label,
      x1Pct: a.x1_pct,
      y1Pct: a.y1_pct,
      x2Pct: a.x2_pct,
      y2Pct: a.y2_pct,
    });
  }
  return out;
}

export function annotationsToRelationshipArrows(payload) {
  if (!payload || !Array.isArray(payload.annotations)) {
    return [];
  }
  const out = [];
  for (const a of payload.annotations) {
    if (a?.kind !== ANNOTATION_KINDS.RELATIONSHIP_ARROW) {
      continue;
    }
    out.push({
      id: a.id,
      label: a.label,
      x1Pct: a.x1_pct,
      y1Pct: a.y1_pct,
      x2Pct: a.x2_pct,
      y2Pct: a.y2_pct,
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
    // Multi-image "Crop N" label, when present. Single-crop
    // critiques omit it (legacy "[Crop]" token).
    label: crop.label ?? null,
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
    label: annotation.label ?? null,
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
  directionArrows,
  relationshipArrows,
  // Optional rotate/flip applied to the primary image during
  // annotation. Shape: { rotation: 0|90|180|270, flipH, flipV }.
  // Annotation coordinates are already in transformed space — this
  // field is metadata for edit-reopen, so the modal can rebake the
  // original upload through the same transform and land the
  // annotations on the right pixels. Identity transforms are
  // emitted as null so payloads stay clean for the common case.
  imageTransform,
  // Submission image index for the primary/head args above. Defaults
  // to 0 (the legacy single-image case). When the only annotated
  // images are non-primary (e.g. critic marked up image 1 but left
  // image 0 untouched), the caller can promote image 1 to be the
  // head — this field then tags the head's annotations + source
  // entry with the right index, so edit-restore buckets them back
  // to image 1 instead of collapsing onto image 0.
  headImageIndex = 0,
  // Multi-image extension: when the submission has 2+ images and the
  // critic marked up more than one, the caller passes the remaining
  // images here (image_index 1+). Each entry mirrors the per-kind
  // arrays plus { index, sourceUrl, sourceUploadId, sourceLabel,
  // visualUpload, imageTransform } describing where its annotations
  // live, what upload was just flattened for it, and any
  // rotate/flip applied to its source. The primary (image_index 0)
  // continues to use the top-level args so existing readers see the
  // same `source` + `visual_output` they did before.
  additionalImages,
  // v2 separated-text fields. `overallCritiqueText` is the critic's
  // overall response to the photograph/series — NOT tied to any image,
  // rendered once at the top of the post. `headNotesText` is the
  // per-image commentary for the head image (the one the top-level
  // annotation args describe); each additionalImages entry carries its
  // own `notesText`. These replace the old behaviour of splitting a
  // single body by annotation-token position.
  overallCritiqueText,
  headNotesText,
} = {}) {
  const primaryAnnotations = collectAnnotationsForImage({
    pins,
    crop,
    eyePaths,
    attentionPulls,
    directionArrows,
    relationshipArrows,
  });
  // Tag head annotations with their real image_index. For the legacy
  // single-image case headImageIndex is 0 and the field is omitted
  // (the server-side normalizer fills in 0 by default), keeping the
  // wire shape byte-identical for un-rotated single-image posts.
  const headIdx = Number.isInteger(headImageIndex) && headImageIndex >= 0
    ? headImageIndex
    : 0;
  const annotations =
    headIdx === 0
      ? [...primaryAnnotations]
      : primaryAnnotations.map((a) => ({ ...a, image_index: headIdx }));
  const sources = [];
  // Always include the head source in `sources`. Readers that only
  // know about the legacy `source` field still see the same value at
  // the top level; new readers can iterate `sources` for full multi-
  // image fidelity. The head's index reflects which submission image
  // the head args actually describe.
  const primaryTransform = normalizeImageTransformValue(imageTransform);
  const primarySourceEntry = {
    image_index: headIdx,
    source: normalizeSourceFromInputs({ topic, selectedVersion }),
    visual_output: normalizeVisualOutputFromInput(visualUpload),
  };
  if (primaryTransform) {
    primarySourceEntry.image_transform = primaryTransform;
  }
  const headNotes = cleanNotesText(headNotesText);
  if (headNotes) {
    primarySourceEntry.notes = headNotes;
  }
  sources.push(primarySourceEntry);

  if (Array.isArray(additionalImages) && additionalImages.length > 0) {
    for (const entry of additionalImages) {
      if (!entry || typeof entry.index !== "number" || entry.index <= 0) {
        continue;
      }
      const entryAnnotations = collectAnnotationsForImage(entry);
      for (const a of entryAnnotations) {
        annotations.push({ ...a, image_index: entry.index });
      }
      const entrySourceObj = {
        image_index: entry.index,
        source: normalizeSourceFromInputs({
          topic,
          selectedVersion: {
            key: `image_${entry.index}`,
            kind: "submission_image",
            label: entry.sourceLabel ?? null,
            upload_id: entry.sourceUploadId ?? null,
            url: entry.sourceUrl ?? null,
          },
        }),
        visual_output: normalizeVisualOutputFromInput(entry.visualUpload),
      };
      const entryTransform = normalizeImageTransformValue(entry.imageTransform);
      if (entryTransform) {
        entrySourceObj.image_transform = entryTransform;
      }
      const entryNotes = cleanNotesText(entry.notesText);
      if (entryNotes) {
        entrySourceObj.notes = entryNotes;
      }
      sources.push(entrySourceObj);
    }
  }

  const out = {
    schema_version: VISUAL_ANNOTATION_SCHEMA_VERSION,
    // Legacy single-image shape — `source` + `visual_output` always
    // describe the PRIMARY image (image_index 0). Back-compat with
    // any reader that only knows about the v1 single-image schema.
    source: sources[0].source,
    visual_output: sources[0].visual_output,
    // New multi-image shape — `sources` is the canonical list when
    // 2+ images participate. Always populated, single-entry for the
    // legacy single-image case.
    sources,
    annotations,
  };
  // v2 overall critique text — the critic's response to the work as a
  // whole, independent of any single image. Omitted when empty so
  // written-only-via-annotations payloads stay compact.
  const overall = cleanNotesText(overallCritiqueText);
  if (overall) {
    out.overall_critique_text = overall;
  }
  // Top-level convenience mirror of the primary image's transform.
  // Legacy single-image readers (and the modal's edit-reopen path
  // for posts that have only one image) read this without diving
  // into the `sources` array. Omitted when identity.
  if (primaryTransform) {
    out.image_transform = primaryTransform;
  }
  return out;
}

// Build the annotations array for ONE image from the per-kind input
// fields. Shared between the primary image (top-level args to
// buildVisualAnnotationPayload) and each entry in additionalImages.
function collectAnnotationsForImage({
  pins,
  crop,
  eyePaths,
  attentionPulls,
  directionArrows,
  relationshipArrows,
}) {
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
  if (Array.isArray(directionArrows) && directionArrows.length > 0) {
    for (const arrowAnnotation of directionArrowsToAnnotations(
      directionArrows
    )) {
      annotations.push(arrowAnnotation);
    }
  }
  if (Array.isArray(relationshipArrows) && relationshipArrows.length > 0) {
    for (const arrowAnnotation of relationshipArrowsToAnnotations(
      relationshipArrows
    )) {
      annotations.push(arrowAnnotation);
    }
  }
  return annotations;
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
  let areaNoteCount = 0;
  let areaNoteIdCounter = 1;
  const usedAreaNoteLabels = new Set();
  let attentionPullCount = 0;
  let attentionPullIdCounter = 1;
  const usedAttentionPullLabels = new Set();
  let directionArrowCount = 0;
  let directionArrowIdCounter = 1;
  const usedDirectionArrowLabels = new Set();
  let relationshipArrowCount = 0;
  let relationshipArrowIdCounter = 1;
  const usedRelationshipArrowLabels = new Set();
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
        // Same pattern as attention_pull below.
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
      case ANNOTATION_KINDS.AREA_NOTE:
        // Canonical area kind post-unification. Same cap + label
        // namespace as the legacy ATTENTION_PULL — both share A<N>
        // labels so a mixed payload (transition state) doesn't
        // double-assign labels.
        if (areaNoteCount >= MAX_AREA_NOTE_COUNT) {
          continue;
        }
        normalized = normalizeAreaNoteAnnotation(entry);
        if (normalized) {
          if (!normalized.id) {
            normalized.id = `area_note_${areaNoteIdCounter}`;
          }
          if (
            !normalized.label ||
            usedAreaNoteLabels.has(normalized.label)
          ) {
            normalized.label = nextAttentionPullLabel(
              Array.from(usedAreaNoteLabels)
            );
          }
          usedAreaNoteLabels.add(normalized.label);
          areaNoteCount += 1;
          areaNoteIdCounter += 1;
        }
        break;
      case ANNOTATION_KINDS.ATTENTION_PULL:
        // Legacy kind. Multiple allowed up to the cap. After-cap
        // entries are silently dropped to mirror the modal's cap-
        // enforcing addAttentionPull action.
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
      case ANNOTATION_KINDS.DIRECTION_ARROW:
        // One-way arrows. Same cap + label-fallback pattern as
        // attention pull, with "D<N>" labels.
        if (directionArrowCount >= MAX_DIRECTION_ARROW_COUNT) {
          continue;
        }
        normalized = normalizeDirectionArrowAnnotation(entry);
        if (normalized) {
          if (!normalized.id) {
            normalized.id = `direction_arrow_${directionArrowIdCounter}`;
          }
          if (
            !normalized.label ||
            usedDirectionArrowLabels.has(normalized.label)
          ) {
            normalized.label = nextDirectionArrowLabel(
              Array.from(usedDirectionArrowLabels)
            );
          }
          usedDirectionArrowLabels.add(normalized.label);
          directionArrowCount += 1;
          directionArrowIdCounter += 1;
        }
        break;
      case ANNOTATION_KINDS.RELATIONSHIP_ARROW:
        // Two-way arrows. "R<N>" labels.
        if (relationshipArrowCount >= MAX_RELATIONSHIP_ARROW_COUNT) {
          continue;
        }
        normalized = normalizeRelationshipArrowAnnotation(entry);
        if (normalized) {
          if (!normalized.id) {
            normalized.id = `relationship_arrow_${relationshipArrowIdCounter}`;
          }
          if (
            !normalized.label ||
            usedRelationshipArrowLabels.has(normalized.label)
          ) {
            normalized.label = nextRelationshipArrowLabel(
              Array.from(usedRelationshipArrowLabels)
            );
          }
          usedRelationshipArrowLabels.add(normalized.label);
          relationshipArrowCount += 1;
          relationshipArrowIdCounter += 1;
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
  const out = {
    schema_version: VISUAL_ANNOTATION_SCHEMA_VERSION,
    source: normalizeSourceFromRaw(input.source),
    visual_output: normalizeVisualOutputFromRaw(input.visual_output),
    annotations: normalizeAnnotationsArray(input.annotations),
  };
  // v2 overall critique text — preserved when present so edit-reopen
  // can restore it directly rather than re-parsing the posted body.
  const overall = cleanNotesText(input.overall_critique_text);
  if (overall) {
    out.overall_critique_text = overall;
  }
  return out;
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
      a.schema_version === 2 &&
      a.annotations.length === 0 &&
      b.schema_version === 2 &&
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

  // 36. All four active kinds coexist in a single payload.
  t("buildVisualAnnotationPayload: four-kind payload", () => {
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
    });
    const kinds = payload.annotations.map((a) => a.kind).sort();
    return (
      payload.annotations.length === 4 &&
      kinds.join(",") === "attention_pull,crop,eye_path,pin"
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

  // ----- Direction-arrow + Relationship-arrow tests ----------------

  t("normalizeDirectionArrowAnnotation: clamps + drops tiny drags", () => {
    const clamped = normalizeDirectionArrowAnnotation({
      x1_pct: -5,
      y1_pct: 110,
      x2_pct: 50,
      y2_pct: 50,
    });
    const tooSmall = normalizeDirectionArrowAnnotation({
      x1_pct: 50,
      y1_pct: 50,
      x2_pct: 51,
      y2_pct: 51,
    });
    return (
      clamped !== null &&
      clamped.x1_pct === 0 &&
      clamped.y1_pct === 100 &&
      tooSmall === null
    );
  });

  t("directionArrowsToAnnotations: assigns sequential D-labels", () => {
    const arrows = [
      { x1Pct: 10, y1Pct: 10, x2Pct: 90, y2Pct: 50 },
      { x1Pct: 5, y1Pct: 80, x2Pct: 60, y2Pct: 20 },
      { x1Pct: 30, y1Pct: 40, x2Pct: 70, y2Pct: 70 },
    ];
    const out = directionArrowsToAnnotations(arrows);
    return (
      out.length === 3 &&
      out.map((a) => a.label).join(",") === "D1,D2,D3" &&
      out.every((a) => a.kind === "direction_arrow")
    );
  });

  t("nextDirectionArrowLabel: max-suffix+1 + handles gaps", () => {
    return (
      nextDirectionArrowLabel(["D1", "D2", "D3"]) === "D4" &&
      nextDirectionArrowLabel(["D1", "D7", "D3"]) === "D8" &&
      nextDirectionArrowLabel([]) === "D1" &&
      nextDirectionArrowLabel(["junk", "X1"]) === "D1"
    );
  });

  t("relationshipArrowsToAnnotations: assigns sequential R-labels", () => {
    const arrows = [
      { x1Pct: 10, y1Pct: 10, x2Pct: 90, y2Pct: 50 },
      { x1Pct: 20, y1Pct: 80, x2Pct: 80, y2Pct: 20 },
    ];
    const out = relationshipArrowsToAnnotations(arrows);
    return (
      out.length === 2 &&
      out.map((a) => a.label).join(",") === "R1,R2" &&
      out.every((a) => a.kind === "relationship_arrow")
    );
  });

  t("nextRelationshipArrowLabel: max-suffix+1", () => {
    return (
      nextRelationshipArrowLabel(["R1", "R2"]) === "R3" &&
      nextRelationshipArrowLabel(["R1", "R5"]) === "R6" &&
      nextRelationshipArrowLabel([]) === "R1"
    );
  });

  t("normalizeAnnotationsArray: enforces per-kind arrow caps", () => {
    const tooMany = Array.from(
      { length: MAX_DIRECTION_ARROW_COUNT + 3 },
      (_, i) => ({
        kind: "direction_arrow",
        x1_pct: 10,
        y1_pct: 10,
        x2_pct: 60 + (i % 30),
        y2_pct: 60,
      })
    );
    const payload = normalizeVisualAnnotationPayload({ annotations: tooMany });
    const directionArrows = payload.annotations.filter(
      (a) => a.kind === "direction_arrow"
    );
    return directionArrows.length === MAX_DIRECTION_ARROW_COUNT;
  });

  t("normalizeAnnotationsArray: regenerates duplicate arrow labels", () => {
    // Two direction arrows with the same label D1 — second should
    // get regenerated to D2 (max-suffix+1 of the already-emitted set).
    const payload = normalizeVisualAnnotationPayload({
      annotations: [
        {
          id: "a",
          kind: "direction_arrow",
          label: "D1",
          x1_pct: 10,
          y1_pct: 10,
          x2_pct: 50,
          y2_pct: 50,
        },
        {
          id: "b",
          kind: "direction_arrow",
          label: "D1",
          x1_pct: 60,
          y1_pct: 60,
          x2_pct: 90,
          y2_pct: 90,
        },
      ],
    });
    const arrows = payload.annotations.filter(
      (a) => a.kind === "direction_arrow"
    );
    return (
      arrows.length === 2 &&
      arrows[0].label === "D1" &&
      arrows[1].label === "D2"
    );
  });

  t("buildVisualAnnotationPayload: arrows coexist with every kind", () => {
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
      attentionPulls: [{ xPct: 40, yPct: 50, widthPct: 15, heightPct: 12 }],
      directionArrows: [
        { x1Pct: 5, y1Pct: 5, x2Pct: 45, y2Pct: 45 },
      ],
      relationshipArrows: [
        { x1Pct: 80, y1Pct: 20, x2Pct: 20, y2Pct: 80 },
      ],
    });
    const kinds = payload.annotations.map((a) => a.kind).sort().join(",");
    return (
      payload.annotations.length === 6 &&
      kinds ===
        "attention_pull,crop,direction_arrow,eye_path,pin,relationship_arrow"
    );
  });

  t("annotationsToDirectionArrows: round-trips through build + normalize", () => {
    const built = buildVisualAnnotationPayload({
      topic: { id: 1 },
      selectedVersion: { key: "original" },
      pins: [],
      directionArrows: [
        { x1Pct: 10, y1Pct: 20, x2Pct: 70, y2Pct: 80 },
      ],
    });
    const back = annotationsToDirectionArrows(built);
    return (
      back.length === 1 &&
      back[0].x1Pct === 10 &&
      back[0].y1Pct === 20 &&
      back[0].x2Pct === 70 &&
      back[0].y2Pct === 80 &&
      back[0].label === "D1"
    );
  });

  const passed = results.filter((r) => r.ok).length;
  const failed = results.length - passed;
  return { passed, failed, results };
}
