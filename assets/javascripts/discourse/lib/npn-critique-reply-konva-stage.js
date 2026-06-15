import { getURLWithCDN } from "discourse/lib/get-url";
import loadScript from "discourse/lib/load-script";
import {
  ANNOTATION_BLUE,
  ANNOTATION_HALO,
  ANNOTATION_HALO_SHADOW,
  AREA_FILL_OPACITY_SELECTED,
  AREA_FILL_OPACITY_UNSELECTED,
  ATTENTION_PULL_OCHRE,
  CROP_DIM_FILL,
  CROP_EDITOR_BLUE_GRAY,
  DIRECTION_ARROW_INDIGO,
  EYE_PATH_PALE_CYAN,
  NOTE_BLUE,
  RELATIONSHIP_TAUPE,
  STRONG_AREA_SAGE,
} from "./npn-critique-reply-colors";

// Outer-shadow geometry for halo lines. Tuned to add a soft 2-3px
// dark edge on snow/fog images without becoming visible noise on
// dark scenes. Drawn via Konva's shadow* + shadowForStrokeEnabled
// in the editor, and via ctx.shadowColor / shadowBlur in the
// canvas export path. Kept here so the two paths can't drift.
const ANNOTATION_HALO_SHADOW_BLUR = 4;
const ANNOTATION_HALO_SHADOW_OPACITY = 1;
// Smaller, calmer drop shadow used by badge backgrounds (Konva.Tag).
// Badges are smaller than line halos so a 2px blur is enough to give
// the box an outer dark edge on high-key backgrounds; full opacity
// would darken the surrounding image too much.
const ANNOTATION_BADGE_SHADOW_BLUR = 2;
const ANNOTATION_BADGE_SHADOW_OPACITY = 0.6;

// Konva-backed annotation stage.
// =================================================================
//
// Lazy-loads the vendored Konva browser build via Discourse's standard
// `loadScript` helper, then mounts a Konva.Stage as an overlay on top
// of the existing reference image. The stage handles:
//
//   • rendering pins from the NPN visual annotation schema
//     (positions are stored as percentages and converted to stage
//     pixel coords at render time)
//   • click/tap to add a pin (only while note mode is active)
//   • click/tap on an existing pin to select it
//   • re-flowing pins on image resize (window resize, modal width
//     change, viewport rotation)
//
// What this module DOES NOT do:
//   • persist any state (the NPN schema in the modal is canonical)
//   • serialize Konva's native JSON (forbidden by architecture)
//   • flatten / export — the existing vanilla canvas pipeline in
//     `npn-critique-reply-visual-notes.js` still handles export.
//     Migrating export to `stage.toCanvas()` is a follow-up only if
//     this spike succeeds.
//
// Vendored Konva location:
//   plugins/discourse-npn-critique-reply/public/javascripts/konva-9.3.20.min.js
// Served as:
//   /plugins/discourse-npn-critique-reply/javascripts/konva-9.3.20.min.js
//
// The file MUST be added by the operator running the spike (it is not
// in this repository). See the README-style note at the bottom of
// the spike-report message for the exact `curl` command.

const KONVA_URL = getURLWithCDN(
  "/plugins/discourse-npn-critique-reply/javascripts/konva-9.3.20.min.js"
);

// Shared promise so concurrent callers don't double-load. `loadScript`
// itself deduplicates by URL, but caching the resolved window.Konva
// reference avoids a second `getComputedStyle` lookup later.
let _konvaPromise = null;

async function ensureKonva() {
  if (typeof window !== "undefined" && window.Konva) {
    return window.Konva;
  }
  if (_konvaPromise) {
    return _konvaPromise;
  }
  _konvaPromise = loadScript(KONVA_URL).then(() => {
    if (!window.Konva) {
      // loadScript resolved but the global never appeared — file is
      // corrupt, missing, or served as HTML 404. Reset so a retry can
      // try again on next user interaction.
      _konvaPromise = null;
      throw new Error("Konva loaded but window.Konva is not defined");
    }
    return window.Konva;
  });
  return _konvaPromise;
}


// Pin radius scales with the displayed stage size so the pin reads
// proportionally on both a 600px modal and a 1600px export. Floored
// at MIN_PIN_RADIUS so tiny displays still get a tappable circle.
// 2.1% (down from 2.5%) keeps the badge legible but a touch softer.
const MIN_PIN_RADIUS = 12;
const PIN_RADIUS_RATIO = 0.021;

function computePinRadius(width, height) {
  const shortEdge = Math.min(width, height);
  return Math.max(MIN_PIN_RADIUS, Math.round(shortEdge * PIN_RADIUS_RATIO));
}

// Defensive deep-ish clone for the eye_path state. The closure
// shouldn't share point objects with the modal — a stage-side
// mutation would silently corrupt the modal's tracked array.
function cloneEyePath(eyePath) {
  if (!eyePath || !Array.isArray(eyePath.points)) {
    return null;
  }
  return {
    id: eyePath.id ?? null,
    // Preserve label — renderEyePath reads this to draw the E1 badge
    // near the start dot. Dropping it (the original shape did) made
    // the badge silently disappear after the first state sync.
    label: eyePath.label ?? null,
    // Mode drives Stroke vs Points rendering — must round-trip
    // through the clone or the renderer falls back to the default.
    mode: eyePath.mode ?? null,
    points: eyePath.points.map((p) => ({
      number: p.number,
      xPct: p.xPct,
      yPct: p.yPct,
    })),
  };
}

// Used by update() to skip re-rendering when the modal sends the
// same eye_path back. Comparing by x/y/count + label catches both
// geometry changes and a late-arriving label.
function sameEyePath(a, b) {
  if (a === b) {
    return true;
  }
  if (!a || !b) {
    return false;
  }
  if ((a.id ?? null) !== (b.id ?? null)) {
    return false;
  }
  if ((a.label ?? null) !== (b.label ?? null)) {
    return false;
  }
  if ((a.mode ?? null) !== (b.mode ?? null)) {
    return false;
  }
  const ap = a.points ?? [];
  const bp = b.points ?? [];
  if (ap.length !== bp.length) {
    return false;
  }
  for (let i = 0; i < ap.length; i++) {
    if (ap[i].xPct !== bp[i].xPct || ap[i].yPct !== bp[i].yPct) {
      return false;
    }
  }
  return true;
}

// Multi-path equivalents. Clone produces a fresh array of cloned
// paths; same compares two arrays slot-by-slot (order matters,
// matching the modal's authoritative ordering).
function cloneEyePaths(eyePaths) {
  if (!Array.isArray(eyePaths)) {
    return [];
  }
  const out = [];
  for (const p of eyePaths) {
    const cloned = cloneEyePath(p);
    if (cloned) {
      out.push(cloned);
    }
  }
  return out;
}

function sameEyePaths(a, b) {
  if (a === b) {
    return true;
  }
  const al = Array.isArray(a) ? a : [];
  const bl = Array.isArray(b) ? b : [];
  if (al.length !== bl.length) {
    return false;
  }
  for (let i = 0; i < al.length; i++) {
    if (!sameEyePath(al[i], bl[i])) {
      return false;
    }
  }
  return true;
}

// Defensive clone so closure-side mutations can't leak into the
// modal's tracked array. Carries both shape variants — ellipse
// (xPct/yPct/widthPct/heightPct) and path (shape: "path" + points[]).
function cloneAreaPoints(points) {
  if (!Array.isArray(points)) {
    return null;
  }
  return points.map((pt) => ({ xPct: pt.xPct, yPct: pt.yPct }));
}

function cloneAttentionPulls(pulls) {
  if (!Array.isArray(pulls)) {
    return [];
  }
  return pulls.map((p) => ({
    id: p.id,
    // Preserve label — renderAttentionPulls reads this to draw the
    // A1 badge. Dropping it (the original shape did) silently
    // suppressed the badge after the first state sync.
    label: p.label,
    shape: p.shape,
    points: cloneAreaPoints(p.points),
    xPct: p.xPct,
    yPct: p.yPct,
    widthPct: p.widthPct,
    heightPct: p.heightPct,
  }));
}

function sameAreaPoints(a, b) {
  if (a === b) {
    return true;
  }
  if (!Array.isArray(a) || !Array.isArray(b)) {
    return false;
  }
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i].xPct !== b[i].xPct || a[i].yPct !== b[i].yPct) {
      return false;
    }
  }
  return true;
}

// Cheap structural equality — skip re-render when the modal sends
// back the same set of attention pulls.
function sameAttentionPulls(a, b) {
  if (a === b) {
    return true;
  }
  if (!Array.isArray(a) || !Array.isArray(b)) {
    return false;
  }
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    const x = a[i];
    const y = b[i];
    if (
      x.id !== y.id ||
      x.xPct !== y.xPct ||
      x.yPct !== y.yPct ||
      x.widthPct !== y.widthPct ||
      x.heightPct !== y.heightPct ||
      (x.label ?? null) !== (y.label ?? null) ||
      (x.shape ?? null) !== (y.shape ?? null) ||
      !sameAreaPoints(x.points, y.points)
    ) {
      return false;
    }
  }
  return true;
}

// Strong areas use the same shape as attention pulls — twin clone /
// equality helpers so dragmove + sync paths stay parallel.
function cloneStrongAreas(areas) {
  if (!Array.isArray(areas)) {
    return [];
  }
  return areas.map((p) => ({
    id: p.id,
    label: p.label,
    shape: p.shape,
    points: cloneAreaPoints(p.points),
    xPct: p.xPct,
    yPct: p.yPct,
    widthPct: p.widthPct,
    heightPct: p.heightPct,
  }));
}

function sameStrongAreas(a, b) {
  if (a === b) {
    return true;
  }
  if (!Array.isArray(a) || !Array.isArray(b)) {
    return false;
  }
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    const x = a[i];
    const y = b[i];
    if (
      x.id !== y.id ||
      x.xPct !== y.xPct ||
      x.yPct !== y.yPct ||
      x.widthPct !== y.widthPct ||
      x.heightPct !== y.heightPct ||
      (x.label ?? null) !== (y.label ?? null) ||
      (x.shape ?? null) !== (y.shape ?? null) ||
      !sameAreaPoints(x.points, y.points)
    ) {
      return false;
    }
  }
  return true;
}

// Arrow clone + equality — shared shape between direction_arrow and
// relationship_arrow (both are two-endpoint annotations). The clone
// keeps the kind-specific label so the renderer can distinguish them
// without re-checking the source array.
function cloneArrows(arrows) {
  if (!Array.isArray(arrows)) {
    return [];
  }
  return arrows.map((a) => ({
    id: a.id,
    label: a.label,
    x1Pct: a.x1Pct,
    y1Pct: a.y1Pct,
    x2Pct: a.x2Pct,
    y2Pct: a.y2Pct,
    noteText: a.noteText ?? null,
  }));
}

function sameArrows(a, b) {
  if (a === b) {
    return true;
  }
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    const x = a[i];
    const y = b[i];
    if (
      x.id !== y.id ||
      x.label !== y.label ||
      x.x1Pct !== y.x1Pct ||
      x.y1Pct !== y.y1Pct ||
      x.x2Pct !== y.x2Pct ||
      x.y2Pct !== y.y2Pct
    ) {
      return false;
    }
  }
  return true;
}

// Cheap structural equality check used to skip re-render when the pin
// list hasn't actually changed.
function samePins(a, b) {
  if (a === b) {
    return true;
  }
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    const x = a[i];
    const y = b[i];
    if (
      x.number !== y.number ||
      x.xPct !== y.xPct ||
      x.yPct !== y.yPct
    ) {
      return false;
    }
  }
  return true;
}

// Minimum drag distance (in percent of stage) before a crop is
// considered intentional. Mirrors MIN_CROP_DIMENSION_PCT in the schema
// — we drop the same tiny drags here so the modal action layer never
// sees an accidental crop event.
const MIN_CROP_DRAG_PCT = 3;

// Attention-pull minimum drag — same 3% floor as crop, mirrors
// MIN_ATTENTION_PULL_DIMENSION_PCT in the schema.
const MIN_ATTENTION_PULL_DRAG_PCT = 3;
// Strong-area minimum drag — twin of attention pull.
const MIN_STRONG_AREA_DRAG_PCT = 3;
// Arrow minimum drag — distance (Pythagorean) between endpoints
// rather than per-axis. Mirrors MIN_ARROW_DISTANCE_PCT in the schema.
const MIN_ARROW_DRAG_PCT = 3;

// Eye-path smoothing experiment. When true:
//   • the polyline renders as a Catmull-Rom curve through every point
//     (via Konva.Line `tension`), softening the sharp angles you get
//     from a hand-clicked path;
//   • the chord-spaced in-segment arrows are omitted — they'd float
//     off the curve and read as detached. The terminal arrow at the
//     last point + start dot at the first still anchor direction.
//
// Flip both this AND the same-named constant in
// `npn-critique-reply-visual-notes.js` back to false to fall back to
// the straight-segment + chord-spaced-arrows version. Single touch
// per file; no other changes needed.
const EYE_PATH_SMOOTH = true;
const EYE_PATH_SMOOTH_TENSION = 0.4;

// Aspect-ratio values as width / height. `null` means free — no
// constraint. Keys match the schema's reserved aspect_ratio set.
//
// These ratios apply to PIXEL space, which is what feels right to the
// user: "1:1" means a visually square crop on the displayed image,
// regardless of the image's own aspect ratio. The stage owns the
// pixel→percent conversion so this stays an implementation detail.
const ASPECT_RATIO_VALUES = Object.freeze({
  free: null,
  "1:1": 1,
  "2:3": 2 / 3,
  "3:2": 3 / 2,
  "4:5": 4 / 5,
  "5:4": 5 / 4,
  "16:9": 16 / 9,
});

function ratioValueFor(name) {
  if (name == null) {
    return null;
  }
  return Object.prototype.hasOwnProperty.call(ASPECT_RATIO_VALUES, name)
    ? ASPECT_RATIO_VALUES[name]
    : null;
}

// Given a drag start + end in pixel space and a target ratio (or null
// for free), return the constrained end point. The dominant drag axis
// wins — drag mostly horizontally and the height shrinks to the ratio;
// drag mostly vertically and the width shrinks. This matches how the
// crop tool in Photoshop / Lightroom behaves with a ratio lock.
function constrainDragToRatio(startX, startY, endX, endY, ratioValue) {
  if (ratioValue == null) {
    return { endX, endY };
  }
  const dx = endX - startX;
  const dy = endY - startY;
  const absDx = Math.abs(dx);
  const absDy = Math.abs(dy);
  const signX = dx >= 0 ? 1 : -1;
  const signY = dy >= 0 ? 1 : -1;

  let width;
  let height;
  if (absDx >= ratioValue * absDy) {
    width = absDx;
    height = width / ratioValue;
  } else {
    height = absDy;
    width = height * ratioValue;
  }

  return {
    endX: startX + signX * width,
    endY: startY + signY * height,
  };
}

/**
 * Create a Konva annotation stage and mount it inside `container`.
 *
 * Returns a handle with `update(...)` and `destroy()` methods. The
 * stage starts in whatever state was passed; subsequent UI changes
 * flow through `update`.
 *
 * `visualMode` controls interaction:
 *   • null               — nothing interactive on stage; pins/crop
 *                          still render but clicks do nothing. Crop
 *                          remains selectable via click (preserves
 *                          the "click thing, see what to do" reflex).
 *   • "numbered_notes"   — click empty area → onAddPin. Crop becomes
 *                          non-listening so clicks inside the crop
 *                          region pass through to add pins.
 *   • "crop_suggestion"  — drag on empty area (no crop yet) →
 *                          onAddCrop; click existing crop → onSelectCrop;
 *                          when selected: drag rect to move,
 *                          drag handles to resize. Both emit
 *                          onUpdateCrop on release.
 *
 * @param {Object}  opts
 * @param {HTMLElement} opts.container         DOM node to mount into
 * @param {HTMLImageElement} opts.imageElement Already-loaded reference image
 * @param {Array}   opts.pins                  Initial pins (modal model: { number, xPct, yPct })
 * @param {?Object} opts.crop                  Initial crop (modal model: { xPct, yPct, widthPct, heightPct })
 * @param {?number} opts.selectedPinNumber
 * @param {boolean} opts.cropSelected
 * @param {?string} opts.visualMode            null | "numbered_notes" | "crop_suggestion"
 * @param {Function} opts.onAddPin             (xPct, yPct) => void
 * @param {Function} opts.onSelectPin          (pin) => void
 * @param {Function} opts.onAddCrop            (xPct, yPct, widthPct, heightPct) => void
 * @param {Function} opts.onSelectCrop         () => void
 * @param {Function} opts.onUpdateCrop         (xPct, yPct, widthPct, heightPct) => void
 *                                              Fired on dragend / transformend.
 *
 * @returns {Promise<{ update, destroy }>}
 */
export async function createAnnotationStage({
  container,
  imageElement,
  pins = [],
  crop = null,
  eyePaths = [],
  attentionPulls = [],
  strongAreas = [],
  directionArrows = [],
  relationshipArrows = [],
  selectedPinNumber = null,
  cropSelected = false,
  selectedEyePathId = null,
  selectedAttentionPullId = null,
  selectedStrongAreaId = null,
  selectedDirectionArrowId = null,
  selectedRelationshipArrowId = null,
  visualMode = null,
  aspectRatio = "free",
  pinMoveEnabled = true,
  attentionPullEditEnabled = true,
  strongAreaEditEnabled = true,
  // "path" (default) or "oval". When "path" + visualMode is
  // attention_pull or strong_area, drag-to-draw is active.
  areaShapeMode = "path",
  // Eye Path interaction mode — "stroke" (default, drag-to-trace)
  // or "points" (click-to-add ordered stops). In stroke mode a
  // short tap is ignored; in points mode a drag is ignored.
  eyePathInteractionMode = "stroke",
  // Retrace targets: when set, the next path-shape drag in the
  // matching tool mode REPLACES that marker's points instead of
  // creating a new marker. Cleared on commit, cancel, or any of the
  // modal-side cancel triggers (selection change, tool switch).
  retracingAttentionPullId = null,
  retracingStrongAreaId = null,
  onAddPin,
  onSelectPin,
  onMovePin,
  onAddCrop,
  onSelectCrop,
  onUpdateCrop,
  onAddEyePathPoint,
  onCommitEyePath,
  onSelectEyePath,
  onMoveEyePathPoint,
  onAddAttentionPull,
  onAddAttentionPullPath,
  onRetraceAttentionPullPath,
  onSelectAttentionPull,
  onUpdateAttentionPull,
  onAddStrongArea,
  onAddStrongAreaPath,
  onRetraceStrongAreaPath,
  onSelectStrongArea,
  onUpdateStrongArea,
  onAddDirectionArrow,
  onSelectDirectionArrow,
  onUpdateDirectionArrow,
  onAddRelationshipArrow,
  onSelectRelationshipArrow,
  onUpdateRelationshipArrow,
} = {}) {
  if (!container) {
    throw new Error("createAnnotationStage: container is required");
  }
  if (!imageElement) {
    throw new Error("createAnnotationStage: imageElement is required");
  }

  const Konva = await ensureKonva();

  // Initial stage size = the image's current displayed size. We resize
  // on every ResizeObserver tick so the stage tracks the image even
  // when CSS or the modal layout changes the rendered dimensions.
  const initialWidth = Math.max(1, imageElement.clientWidth || 1);
  const initialHeight = Math.max(1, imageElement.clientHeight || 1);

  const stage = new Konva.Stage({
    container,
    width: initialWidth,
    height: initialHeight,
  });

  // Six layers, painted in add order. Strong areas sit next to
  // attention pulls (above crop dim, below eye path and pins) so the
  // two area markers share a visual band and read as paired tools.
  // Pins remain on top because their numbered semantics require
  // unobstructed readability.
  // Annotation kinds live in Konva.Group children of a single layer.
  // Konva renders each Layer as its own <canvas>; one canvas with
  // grouped sub-trees is faster than five canvases (the engine's own
  // warning at >5 layers). Group add-order = z-order: crop → attention
  // pull → strong area → eye path → pins (pins always on top for
  // numbered-badge readability).
  const annotationsLayer = new Konva.Layer();
  const cropLayer = new Konva.Group();
  const attentionPullLayer = new Konva.Group();
  const strongAreaLayer = new Konva.Group();
  const eyePathLayer = new Konva.Group();
  // Arrows sit ABOVE eye path so a relationship/direction arrow
  // crossing a curve reads on top of the curve, BELOW pins so
  // numbered notes always stay readable over an arrow.
  const directionArrowLayer = new Konva.Group();
  const relationshipArrowLayer = new Konva.Group();
  const pinLayer = new Konva.Group();
  annotationsLayer.add(cropLayer);
  annotationsLayer.add(attentionPullLayer);
  annotationsLayer.add(strongAreaLayer);
  annotationsLayer.add(eyePathLayer);
  annotationsLayer.add(directionArrowLayer);
  annotationsLayer.add(relationshipArrowLayer);
  annotationsLayer.add(pinLayer);
  stage.add(annotationsLayer);

  // Drawing-preview lives on its own layer so the drag-to-create rect
  // can clear/redraw on every mousemove without re-batching the
  // annotations layer. Sits above the annotations layer so the
  // preview is unambiguous over existing markers.
  const previewLayer = new Konva.Layer();
  stage.add(previewLayer);

  // Mutable state held in closure. Each update() call mutates this
  // and re-renders. We avoid Konva.fromObject / toObject so the schema
  // owned by the modal stays the only source of truth.
  const state = {
    pins: [...pins],
    crop: crop ? { ...crop } : null,
    eyePaths: cloneEyePaths(eyePaths),
    attentionPulls: cloneAttentionPulls(attentionPulls),
    strongAreas: cloneStrongAreas(strongAreas),
    directionArrows: cloneArrows(directionArrows),
    relationshipArrows: cloneArrows(relationshipArrows),
    selectedPinNumber,
    cropSelected,
    selectedEyePathId,
    selectedAttentionPullId,
    selectedStrongAreaId,
    selectedDirectionArrowId,
    selectedRelationshipArrowId,
    visualMode,
    aspectRatio,
    pinMoveEnabled,
    attentionPullEditEnabled,
    strongAreaEditEnabled,
    areaShapeMode,
    eyePathInteractionMode,
    retracingAttentionPullId,
    retracingStrongAreaId,
  };

  // Drag-to-create attention-pull state — set on mousedown over empty
  // stage in attention_pull mode, cleared on mouseup.
  let attentionDrag = null;
  // Drag-to-create strong-area state — same pattern.
  let strongDrag = null;
  // Drag-to-create arrow state — tail at mousedown, head tracks
  // mousemove, released on mouseup as { x1, y1, x2, y2 }. One per
  // arrow kind so the two tools don't share their in-flight state.
  let directionArrowDrag = null;
  let relationshipArrowDrag = null;

  // Drag-to-crop in-flight state. Set when the user starts dragging
  // on empty stage in crop mode; cleared on pointerup.
  let cropDrag = null;

  // Draw Area in-flight state for the path-shape variant of
  // Attention / Strong Area. Mirrors `eyePathDrag` in structure:
  // sampled pixel points + last-sample anchor for distance-based
  // sampling. Mousedown begins the drag; mousemove samples + redraws
  // an OPEN preview line; mouseup applies Douglas-Peucker simplifi-
  // cation, validates min size, and commits via the per-kind path
  // callback. Drag is only started when state.areaShapeMode === "path".
  let attentionPathDrag = null;
  let strongPathDrag = null;
  // Sampling + threshold values tuned for closed-area shapes. Looser
  // than eye_path's 24px because area paths are typically smaller
  // and need a few samples to define a shape; finer than eye_path's
  // smoothing so corners survive simplification.
  const AREA_PATH_SAMPLE_MIN_PX = 12;
  const AREA_PATH_DRAG_THRESHOLD_PX = 10;
  const AREA_PATH_SIMPLIFY_TOLERANCE_PCT = 0.012;
  const AREA_PATH_HARD_CAP = 24;
  // Raw sampling cap during the drag — set above the schema cap so
  // Douglas-Peucker has enough variety to simplify from. The
  // simplification step trims down to AREA_PATH_HARD_CAP / schema
  // cap, whichever is smaller.
  const MAX_AREA_PATH_POINTS_RAW = 60;

  // Drag-to-trace Eye Path in-flight state. Per beta feedback the
  // tool should feel like drawing a path, not dropping discrete
  // pins. mousedown in eye_path mode begins a drag; mousemove
  // samples points by distance threshold; mouseup runs Douglas-
  // Peucker simplification on the samples and commits the trimmed
  // result via onCommitEyePath. A short pointer press that never
  // crosses the distance threshold falls through to the existing
  // click-to-drop behaviour.
  let eyePathDrag = null;
  // Pixel distance the pointer must travel between sample points
  // before another one is recorded. Looser sampling (24px) keeps
  // the raw point count modest even before simplification, which
  // means individual point handles stay draggable after the fact
  // rather than being a dense cloud the user can't grab cleanly.
  const EYE_PATH_SAMPLE_MIN_PX = 24;
  // Pointer must move at least this far from mousedown for the
  // gesture to count as a "drag". Anything shorter falls back to
  // single-point click behaviour so users who just want to tap
  // get the existing pin-style point.
  const EYE_PATH_DRAG_THRESHOLD_PX = 8;
  // Douglas-Peucker tolerance, as a fraction of the smaller stage
  // dimension. A 2 % tolerance on a 700-px stage = 14 px; any
  // sampled point within 14 px of the simplified line gets
  // dropped. Combined with the Konva line tension on render
  // (`EYE_PATH_SMOOTH_TENSION = 0.4`), this produces a smooth
  // curve from typically 4-8 control points — sparse enough to
  // edit each point by drag, dense enough to capture the shape
  // the user traced.
  const EYE_PATH_SIMPLIFY_TOLERANCE_PCT = 0.02;
  // Defensive cap on the simplification output. The schema allows
  // up to MAX_EYE_PATH_POINTS (40), but in practice DP returns
  // well under this for a normal drag. The cap is a backstop
  // against pathological inputs (e.g. a long zig-zagging drag).
  const EYE_PATH_SIMPLIFY_HARD_CAP = 12;

  // Douglas-Peucker line simplification. Given a polyline and a
  // tolerance, returns a subset of the original points that
  // preserves the curve's shape — points within `tolerance` of the
  // simplified line are dropped. Endpoints are always kept.
  function douglasPeucker(points, tolerance) {
    if (points.length <= 2) {
      return points.slice();
    }
    const last = points.length - 1;
    // Find the point farthest from the line connecting first and
    // last. If it's within tolerance, the whole stretch
    // collapses to those two endpoints. If not, recurse on each
    // half split at the farthest point.
    let maxDist = 0;
    let maxIndex = 0;
    for (let i = 1; i < last; i++) {
      const dist = perpendicularDistance(points[i], points[0], points[last]);
      if (dist > maxDist) {
        maxDist = dist;
        maxIndex = i;
      }
    }
    if (maxDist > tolerance) {
      const left = douglasPeucker(points.slice(0, maxIndex + 1), tolerance);
      const right = douglasPeucker(points.slice(maxIndex), tolerance);
      // The shared midpoint appears once in each half — drop the
      // duplicate when concatenating.
      return [...left.slice(0, -1), ...right];
    }
    return [points[0], points[last]];
  }

  function perpendicularDistance(point, lineStart, lineEnd) {
    const dx = lineEnd.x - lineStart.x;
    const dy = lineEnd.y - lineStart.y;
    if (dx === 0 && dy === 0) {
      return Math.hypot(point.x - lineStart.x, point.y - lineStart.y);
    }
    const t =
      ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) /
      (dx * dx + dy * dy);
    const projX = lineStart.x + t * dx;
    const projY = lineStart.y + t * dy;
    return Math.hypot(point.x - projX, point.y - projY);
  }

  // References kept across renders so dim rects can be moved/resized
  // live during drag/transform (without tearing down the whole layer).
  // Repopulated by renderCrop; cleared when no crop exists.
  let cropRectRef = null;
  let cropTransformerRef = null;
  let dimRectsRef = null;
  // Photo-editor-style decoration group around the selected crop:
  // 1px perimeter + 4 L-shaped corner brackets + 4 edge midpoint bars.
  // Editor-only (the exported JPEG draws the simpler stroked rect via
  // npn-critique-reply-visual-notes.js, untouched here). Rebuilt on
  // every dragmove / transform so it tracks the cropRect's effective
  // bounding box without disturbing the underlying Konva.Transformer.
  let cropDecorationsRef = null;

  function applyContainerCursor() {
    if (state.visualMode === "numbered_notes") {
      container.style.cursor = "crosshair";
    } else if (state.visualMode === "crop_suggestion" && !state.crop) {
      container.style.cursor = "crosshair";
    } else if (state.visualMode === "eye_path") {
      container.style.cursor = "crosshair";
    } else if (state.visualMode === "attention_pull") {
      container.style.cursor = "crosshair";
    } else if (state.visualMode === "strong_area") {
      container.style.cursor = "crosshair";
    } else if (state.visualMode === "direction_arrow") {
      container.style.cursor = "crosshair";
    } else if (state.visualMode === "relationship_arrow") {
      container.style.cursor = "crosshair";
    } else {
      container.style.cursor = "default";
    }
  }

  function syncStageSize() {
    const w = Math.max(1, imageElement.clientWidth || 1);
    const h = Math.max(1, imageElement.clientHeight || 1);

    // Pin the Konva container to the image's actual rendered area
    // inside the figure frame. The image is flex-centered, so when
    // its aspect doesn't fill the frame it sits with letterbox gaps
    // on the sides (or top/bottom). The container's CSS uses
    // `inset: 0` which would otherwise leave the canvas pinned to
    // the frame's top-left — creating a "dead zone" wherever the
    // visible image extends past the canvas, and a "phantom zone"
    // wherever the canvas extends past the image. Setting the
    // container's pixel position to match the image element fixes
    // both: the canvas exactly overlays the visible image and
    // every pixel of the image is reachable.
    container.style.left = `${imageElement.offsetLeft}px`;
    container.style.top = `${imageElement.offsetTop}px`;
    container.style.width = `${w}px`;
    container.style.height = `${h}px`;
    container.style.right = "auto";
    container.style.bottom = "auto";

    if (w !== stage.width() || h !== stage.height()) {
      stage.size({ width: w, height: h });
      return true;
    }
    return false;
  }

  function buildPinGroup(pin) {
    const stageWidth = stage.width();
    const stageHeight = stage.height();
    const x = (pin.xPct / 100) * stageWidth;
    const y = (pin.yPct / 100) * stageHeight;
    const pinRadius = computePinRadius(stageWidth, stageHeight);

    // Annotation palette is fixed (not theme-derived) so critiques
    // read the same across themes — see npn-critique-reply-colors.js.
    // Pins are the most prominent of the muted family — the numbered
    // badge is the primary critique anchor. NOTE_BLUE is deeper and
    // more saturated than the eye-path pale cyan so Notes don't
    // visually overlap with the flow line.
    const tertiary = NOTE_BLUE;
    const secondary = ANNOTATION_HALO;
    const tertiaryHover = NOTE_BLUE;

    const isSelected = pin.number === state.selectedPinNumber;
    // Selected pin → draggable, unless the modal explicitly suppresses
    // pin moves (e.g., the note popover is open — dragging the pin
    // while it's anchoring a popover would leave the popover orphaned).
    const canMove = isSelected && state.pinMoveEnabled;

    const group = new Konva.Group({
      x,
      y,
      name: `pin-${pin.number}`,
      draggable: canMove,
      // Clamp drag to stage bounds so pins can't be dragged off-canvas.
      // dragBoundFunc receives the proposed top-left of the group; we
      // clamp to [0, stageWidth] × [0, stageHeight].
      dragBoundFunc(pos) {
        const sw = stage.width();
        const sh = stage.height();
        return {
          x: Math.max(0, Math.min(sw, pos.x)),
          y: Math.max(0, Math.min(sh, pos.y)),
        };
      },
    });

    // Cursor affordance: "move" while hovering a draggable pin
    // (signals drag), "pointer" when the pin is only clickable
    // (signals selectability). Either way revert to the mode-default
    // on leave. Matches the pattern used on the other annotation
    // kinds — every interactive marker now has a hover cursor cue.
    group.on("mouseenter", () => {
      container.style.cursor = canMove ? "move" : "pointer";
    });
    group.on("mouseleave", () => {
      applyContainerCursor();
    });

    if (canMove) {
      group.on("dragend", () => {
        const sw = stage.width();
        const sh = stage.height();
        if (sw === 0 || sh === 0) {
          return;
        }
        const newXPct = Math.max(0, Math.min(100, (group.x() / sw) * 100));
        const newYPct = Math.max(0, Math.min(100, (group.y() / sh) * 100));
        // Update closure state BEFORE notifying the modal so the next
        // sync(...) sees matching coords (samePins returns true) and
        // skips a redundant re-render.
        state.pins = state.pins.map((p) =>
          p.number === pin.number
            ? { ...p, xPct: newXPct, yPct: newYPct }
            : p
        );
        onMovePin?.(pin.number, newXPct, newYPct);
      });
    }

    // White halo (matches CSS box-shadow: 0 0 0 2px var(--secondary))
    group.add(
      new Konva.Circle({
        radius: pinRadius + 2,
        fill: secondary,
        listening: false,
      })
    );

    // Selected: outer tertiary ring + scale; non-color cue retained
    if (isSelected) {
      group.add(
        new Konva.Circle({
          radius: pinRadius + 6,
          stroke: tertiary,
          strokeWidth: 2.5,
          listening: false,
        })
      );
      group.scale({ x: 1.15, y: 1.15 });
    }

    // Main pin body
    group.add(
      new Konva.Circle({
        radius: pinRadius,
        fill: isSelected ? tertiaryHover : tertiary,
        shadowColor: "black",
        shadowBlur: 4,
        shadowOpacity: 0.4,
        shadowOffsetY: 2,
      })
    );

    // Number label
    group.add(
      new Konva.Text({
        text: String(pin.number),
        fontSize: Math.max(11, Math.round(pinRadius * 1.1)),
        fontStyle: "bold",
        fontFamily: "sans-serif",
        fill: secondary,
        align: "center",
        verticalAlign: "middle",
        width: pinRadius * 2,
        height: pinRadius * 2,
        offsetX: pinRadius,
        offsetY: pinRadius,
        listening: false,
      })
    );

    // Click / tap → select. cancelBubble prevents the stage from also
    // interpreting this as a "click empty area, add a new pin".
    group.on("click tap", (e) => {
      e.cancelBubble = true;
      onSelectPin?.(pin);
    });

    return group;
  }

  // Shared path-shape area renderer used by both attention_pull and
  // strong_area's Draw Area variant. Builds the same three-layer
  // stack the ellipse renderer uses (halo / fill / stroke) but with
  // Konva.Line(closed: true) instead of Konva.Ellipse. Label badge
  // anchors at the bounding box's top-left, matching the ellipse
  // marker convention. Editing is select+remove only — no drag /
  // transform — per spec ("Optional if straightforward").
  function renderAreaPath(layer, model, opts) {
    const {
      isSelected,
      tertiary,
      haloColor,
      stageWidth,
      stageHeight,
      shortEdge,
      onSelect,
      modeMatches,
      // When true, the existing shape is hidden so the user can see
      // the underlying image while tracing the replacement. The
      // toolbar's "Cancel retrace" button + hint copy keep retrace
      // context visible.
      isRetracing,
    } = opts;
    const points = Array.isArray(model.points) ? model.points : null;
    if (!points || points.length < 2) {
      return;
    }
    // While retracing, hide the existing shape entirely so the user
    // can see the underlying image as they trace the replacement.
    // The toolbar's active "Cancel retrace" button + hint copy keep
    // the context visible. The shape returns if retrace is cancelled
    // (state.retracingXxxId clears → re-render → isRetracing false).
    if (isRetracing) {
      return;
    }
    const flat = [];
    let minX = Infinity;
    let maxX = -Infinity;
    let minY = Infinity;
    let maxY = -Infinity;
    for (const p of points) {
      const x = (p.xPct / 100) * stageWidth;
      const y = (p.yPct / 100) * stageHeight;
      flat.push(x, y);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    // Stroke / halo widths follow the same percent-of-short-edge
    // formulas as the ellipse variant so paths and ovals read at the
    // same visual weight when both are present in the same image.
    const haloWidth = Math.max(5, Math.round(shortEdge * 0.0075));
    const strokeWidth = isSelected
      ? Math.max(3, Math.round(shortEdge * 0.005))
      : Math.max(2, Math.round(shortEdge * 0.0035));
    const dashOn = Math.max(8, Math.round(shortEdge * 0.013));
    const dashOff = Math.max(7, Math.round(shortEdge * 0.011));
    // Smooth interpolation through the simplified control points —
    // matches the eye-path treatment so the closed curve reads as
    // intentional, not jagged. Konva closes the line via
    // `closed: true`, drawing a final segment from the last point
    // back to the first.
    const tension = 0.4;

    const halo = new Konva.Line({
      points: flat,
      closed: true,
      stroke: haloColor,
      strokeWidth: haloWidth,
      fillEnabled: false,
      tension,
      opacity: 0.85,
      listening: false,
      // Soft dark outer edge so the white halo still reads on
      // high-key images (snow / fog / overexposed sky). Invisible
      // on dark backgrounds — the white halo is doing the work
      // there and the dark blur blends into the photograph.
      shadowColor: ANNOTATION_HALO_SHADOW,
      shadowBlur: ANNOTATION_HALO_SHADOW_BLUR,
      shadowOpacity: ANNOTATION_HALO_SHADOW_OPACITY,
      shadowForStrokeEnabled: true,
    });
    layer.add(halo);

    // Visible fill — pure decoration now. Was previously the click
    // target (entire interior caught selection), which felt
    // imprecise: dragging a stage tool inside an already-placed area
    // accidentally selected it. Made non-listening so only the stroke
    // catches clicks; the interior is visually filled but
    // pass-through.
    const fillBody = new Konva.Line({
      points: flat,
      closed: true,
      fill: tertiary,
      tension,
      opacity: isSelected
        ? AREA_FILL_OPACITY_SELECTED
        : AREA_FILL_OPACITY_UNSELECTED,
      strokeEnabled: false,
      listening: false,
      name: `area-path-${model.id}`,
    });
    layer.add(fillBody);

    // Border stroke — visible AND the hit target. `hitStrokeWidth`
    // widens the invisible hit zone around the stroke so users don't
    // need pixel-perfect aim on the thin dashed line. Sized off the
    // shortEdge so it scales with stage zoom.
    const hitWidth = Math.max(14, strokeWidth * 4);
    const stroke = new Konva.Line({
      points: flat,
      closed: true,
      stroke: tertiary,
      strokeWidth,
      dash: isSelected ? [] : [dashOn, dashOff],
      tension,
      fillEnabled: false,
      listening: true,
      hitStrokeWidth: hitWidth,
      name: `area-path-stroke-${model.id}`,
    });
    stroke.on("click tap", (e) => {
      e.cancelBubble = true;
      onSelect?.();
    });
    stroke.on("mouseenter", () => {
      container.style.cursor = "pointer";
    });
    stroke.on("mouseleave", () => {
      applyContainerCursor();
    });
    layer.add(stroke);

    if (model.label) {
      const badgeOffset = Math.max(3, Math.round(shortEdge * 0.004));
      const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
      const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
      const badge = new Konva.Label({
        x: minX + badgeOffset,
        y: minY + badgeOffset,
        listening: false,
      });
      badge.add(
        new Konva.Tag({
          fill: tertiary,
          cornerRadius: 3,
          stroke: haloColor,
          strokeWidth: 1.5,
          opacity: isSelected ? 1 : 0.95,
          shadowColor: ANNOTATION_HALO_SHADOW,
          shadowBlur: ANNOTATION_BADGE_SHADOW_BLUR,
          shadowOpacity: ANNOTATION_BADGE_SHADOW_OPACITY,
        })
      );
      badge.add(
        new Konva.Text({
          text: model.label,
          fontSize: badgeFontSize,
          fontStyle: "600",
          fill: "#ffffff",
          padding: badgePadding,
          listening: false,
        })
      );
      layer.add(badge);
    }

    // Ignore unused params from the destructure so linters stay quiet
    // — they're part of the shared signature with the ellipse path
    // and may be wired up later for transform handles.
    void stageWidth;
    void stageHeight;
    void modeMatches;
    return { minX, maxX, minY, maxY };
  }

  // Attention-pull renderer. Each marker is a soft ellipse:
  //   • white halo ellipse underneath for contrast over any image
  //   • warm amber fill at low opacity (~12%)
  //   • dashed amber stroke (solid when selected) so the marker reads
  //     as observational rather than corrective
  // No numbers, no shadows — keeps the tone observational vs. the
  // numbered-notes pins.
  function renderAttentionPulls() {
    attentionPullLayer.destroyChildren();
    const pulls = state.attentionPulls;
    if (!Array.isArray(pulls) || pulls.length === 0) {
      annotationsLayer.batchDraw();
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      annotationsLayer.batchDraw();
      return;
    }
    // Muted ochre — see npn-critique-reply-colors.js. Distinct hue
    // from the pin/eye/crop blue family but pulled back from the
    // alarm-bell-bright theme amber.
    const amber = ATTENTION_PULL_OCHRE;
    const secondary = ANNOTATION_HALO;
    const shortEdge = Math.min(sw, sh);

    const minSizePx = Math.max(
      10,
      Math.round((MIN_ATTENTION_PULL_DRAG_PCT / 100) * shortEdge)
    );

    for (const pull of pulls) {
      // Draw Area variant — closed polyline marker instead of an
      // ellipse. Same colour family, same label badge; just a
      // different shape primitive. We continue past the ellipse
      // code after rendering so the two paths don't collide.
      if (pull.shape === "path") {
        renderAreaPath(attentionPullLayer, pull, {
          isSelected: pull.id === state.selectedAttentionPullId,
          tertiary: ATTENTION_PULL_OCHRE,
          haloColor: secondary,
          stageWidth: sw,
          stageHeight: sh,
          shortEdge,
          onSelect: () => onSelectAttentionPull?.(pull.id),
          modeMatches: state.visualMode === "attention_pull",
          isRetracing: pull.id === state.retracingAttentionPullId,
        });
        continue;
      }
      const cx = ((pull.xPct + pull.widthPct / 2) / 100) * sw;
      const cy = ((pull.yPct + pull.heightPct / 2) / 100) * sh;
      const rx = (pull.widthPct / 200) * sw;
      const ry = (pull.heightPct / 200) * sh;
      if (rx <= 0 || ry <= 0) {
        continue;
      }
      const isSelected = pull.id === state.selectedAttentionPullId;
      const canEdit =
        isSelected &&
        state.visualMode === "attention_pull" &&
        state.attentionPullEditEnabled;

      // Three stacked ellipses so fill opacity, stroke opacity, and
      // halo don't fight each other (Konva applies node-level opacity
      // to both fill AND stroke). Layering inside the layer:
      //   1. white halo stroke (under everything)
      //   2. translucent amber fill (hit target + transform target —
      //      captures clicks anywhere inside the ellipse and is the
      //      single Konva node the Transformer scales/drags)
      //   3. opaque amber dashed/solid stroke (on top)
      // Widened from 0.55% → 0.75% of short edge so the white halo
      // gives the muted ochre / sage stroke enough contrast on
      // foliage / sky / similarly-toned backgrounds.
      const haloWidth = Math.max(5, Math.round(shortEdge * 0.0075));
      const strokeWidth = isSelected
        ? Math.max(3, Math.round(shortEdge * 0.005))
        : Math.max(2, Math.round(shortEdge * 0.0035));
      // Slightly larger gap between dashes so the dashed stroke
      // reads calmer on small markers (kept in sync with the export
      // in npn-critique-reply-visual-notes.js).
      const dashOn = Math.max(8, Math.round(shortEdge * 0.013));
      const dashOff = Math.max(7, Math.round(shortEdge * 0.011));
      const id = pull.id;

      const haloRef = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        stroke: secondary,
        strokeWidth: haloWidth,
        fillEnabled: false,
        opacity: 0.85,
        listening: false,
        shadowColor: ANNOTATION_HALO_SHADOW,
        shadowBlur: ANNOTATION_HALO_SHADOW_BLUR,
        shadowOpacity: ANNOTATION_HALO_SHADOW_OPACITY,
        shadowForStrokeEnabled: true,
      });
      attentionPullLayer.add(haloRef);

      // Fill body — listening + draggable ONLY when the marker is
      // selected AND editable. When unselected, the interior is
      // pass-through (the border below catches selection clicks).
      // After selection the body becomes the drag-to-move target so
      // the user can grab anywhere inside to reposition.
      const fillBody = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        fill: amber,
        opacity: isSelected
          ? AREA_FILL_OPACITY_SELECTED
          : AREA_FILL_OPACITY_UNSELECTED,
        strokeEnabled: false,
        name: `attention-pull-${id}`,
        listening: canEdit,
        draggable: canEdit,
        // Clamp the ellipse's CENTER such that the bounding box stays
        // inside the stage. radii are the current radii (pre-scale).
        dragBoundFunc(pos) {
          const w = fillBody.radiusX() * fillBody.scaleX();
          const h = fillBody.radiusY() * fillBody.scaleY();
          const stageW = stage.width();
          const stageH = stage.height();
          return {
            x: Math.max(w, Math.min(stageW - w, pos.x)),
            y: Math.max(h, Math.min(stageH - h, pos.y)),
          };
        },
      });
      // Click on the body only matters in the selected+editable state
      // — it's a no-op vs. selection (already selected) but keeps
      // event bubbling contained.
      fillBody.on("click tap", (e) => {
        e.cancelBubble = true;
        onSelectAttentionPull?.(id);
      });
      fillBody.on("mouseenter", () => {
        container.style.cursor = canEdit ? "move" : "pointer";
      });
      fillBody.on("mouseleave", () => {
        applyContainerCursor();
      });
      attentionPullLayer.add(fillBody);

      // Border stroke — the click target for SELECTION. `hitStrokeWidth`
      // widens the hit zone around the dashed/solid stroke so users
      // don't need pixel-perfect aim on the thin line. Always
      // listening so unselected markers can be picked by their border.
      const hitWidth = Math.max(14, strokeWidth * 4);
      const strokeRef = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        stroke: amber,
        strokeWidth,
        dash: isSelected ? [] : [dashOn, dashOff],
        fillEnabled: false,
        listening: true,
        hitStrokeWidth: hitWidth,
        name: `attention-pull-stroke-${id}`,
      });
      strokeRef.on("click tap", (e) => {
        e.cancelBubble = true;
        onSelectAttentionPull?.(id);
      });
      strokeRef.on("mouseenter", () => {
        container.style.cursor = "pointer";
      });
      strokeRef.on("mouseleave", () => {
        applyContainerCursor();
      });
      attentionPullLayer.add(strokeRef);

      // Label badge — small amber pill at the upper-left of the
      // bounding box, just inside the corner so it reads as attached
      // to the marker without obscuring the marked area. Uses
      // Konva.Label which auto-sizes the tag to the text.
      const badgeOffset = Math.max(3, Math.round(shortEdge * 0.004));
      let labelRef = null;
      if (pull.label) {
        const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
        const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
        labelRef = new Konva.Label({
          x: cx - rx + badgeOffset,
          y: cy - ry + badgeOffset,
          listening: false,
        });
        labelRef.add(
          new Konva.Tag({
            fill: amber,
            cornerRadius: 3,
            stroke: secondary,
            strokeWidth: 1.5,
            opacity: isSelected ? 1 : 0.95,
            shadowColor: ANNOTATION_HALO_SHADOW,
            shadowBlur: ANNOTATION_BADGE_SHADOW_BLUR,
            shadowOpacity: ANNOTATION_BADGE_SHADOW_OPACITY,
          })
        );
        labelRef.add(
          new Konva.Text({
            text: pull.label,
            fontSize: badgeFontSize,
            fontFamily: "sans-serif",
            fontStyle: "bold",
            fill: secondary,
            padding: badgePadding,
          })
        );
        attentionPullLayer.add(labelRef);
      }

      if (canEdit) {
        // Live-mirror halo, stroke, and label badge to the fill body
        // during interaction so the visual stays coherent across all
        // four nodes.
        const syncDecorations = () => {
          const ex = fillBody.x();
          const ey = fillBody.y();
          const erx = fillBody.radiusX() * fillBody.scaleX();
          const ery = fillBody.radiusY() * fillBody.scaleY();
          haloRef.position({ x: ex, y: ey });
          haloRef.radiusX(erx);
          haloRef.radiusY(ery);
          strokeRef.position({ x: ex, y: ey });
          strokeRef.radiusX(erx);
          strokeRef.radiusY(ery);
          if (labelRef) {
            labelRef.position({
              x: ex - erx + badgeOffset,
              y: ey - ery + badgeOffset,
            });
          }
          annotationsLayer.batchDraw();
        };

        const emitUpdate = () => {
          const stageW = stage.width();
          const stageH = stage.height();
          if (stageW === 0 || stageH === 0) {
            return;
          }
          const erx = fillBody.radiusX();
          const ery = fillBody.radiusY();
          const ex = fillBody.x();
          const ey = fillBody.y();
          const xPct = Math.max(
            0,
            Math.min(100, ((ex - erx) / stageW) * 100)
          );
          const yPct = Math.max(
            0,
            Math.min(100, ((ey - ery) / stageH) * 100)
          );
          const widthPct = Math.max(
            0,
            Math.min(100 - xPct, ((2 * erx) / stageW) * 100)
          );
          const heightPct = Math.max(
            0,
            Math.min(100 - yPct, ((2 * ery) / stageH) * 100)
          );
          // Update closure state BEFORE the callback so the next sync
          // (driven by modal updating its tracked attentionPulls)
          // sees identical values and skips a redundant re-render.
          state.attentionPulls = state.attentionPulls.map((p) =>
            p.id === id
              ? { ...p, xPct, yPct, widthPct, heightPct }
              : p
          );
          onUpdateAttentionPull?.(id, xPct, yPct, widthPct, heightPct);
        };

        fillBody.on("dragmove", syncDecorations);
        fillBody.on("dragend", emitUpdate);
        fillBody.on("transform", syncDecorations);
        fillBody.on("transformend", () => {
          // Bake the transform's scale into the radii so the next
          // interaction starts from scale 1.
          const sx = fillBody.scaleX();
          const sy = fillBody.scaleY();
          fillBody.scaleX(1);
          fillBody.scaleY(1);
          fillBody.radiusX(Math.max(1, fillBody.radiusX() * sx));
          fillBody.radiusY(Math.max(1, fillBody.radiusY() * sy));
          haloRef.radiusX(fillBody.radiusX());
          haloRef.radiusY(fillBody.radiusY());
          strokeRef.radiusX(fillBody.radiusX());
          strokeRef.radiusY(fillBody.radiusY());
          emitUpdate();
        });

        const transformer = new Konva.Transformer({
          nodes: [fillBody],
          rotateEnabled: false,
          keepRatio: false,
          enabledAnchors: [
            "top-left",
            "top-center",
            "top-right",
            "middle-left",
            "middle-right",
            "bottom-left",
            "bottom-center",
            "bottom-right",
          ],
          borderEnabled: false,
          anchorSize: 10,
          anchorCornerRadius: 2,
          anchorStroke: amber,
          anchorFill: secondary,
          anchorStrokeWidth: 1.5,
          // Reject transforms that shrink below the minimum-dimension
          // floor or leave the stage. Konva passes us oldBox/newBox in
          // the ellipse's local bounding-box coordinates (already
          // scale-applied), so we just clamp against stage dimensions.
          boundBoxFunc(oldBox, newBox) {
            if (
              newBox.width < minSizePx ||
              newBox.height < minSizePx
            ) {
              return oldBox;
            }
            if (newBox.x < 0 || newBox.y < 0) {
              return oldBox;
            }
            if (
              newBox.x + newBox.width > sw ||
              newBox.y + newBox.height > sh
            ) {
              return oldBox;
            }
            return newBox;
          },
        });
        attentionPullLayer.add(transformer);
      }
    }
    annotationsLayer.batchDraw();
  }

  // Strong-area renderer. Twin of attention-pull renderer with two
  // visual distinctions so A1 and S1 stay easy to tell apart on the
  // same image:
  //   • color: --success (green) with a teal-ish hex fallback
  //   • stroke: SOLID (attention pulls are dashed)
  // Badge style mirrors attention pull (small rounded pill with white
  // halo) so the two area tools read as a paired family while the
  // color/stroke difference keeps them legible side by side.
  function renderStrongAreas() {
    strongAreaLayer.destroyChildren();
    const areas = state.strongAreas;
    if (!Array.isArray(areas) || areas.length === 0) {
      annotationsLayer.batchDraw();
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      annotationsLayer.batchDraw();
      return;
    }
    // Muted sage — see npn-critique-reply-colors.js. Supportive
    // counterpart to Attention Pull's ochre, soft enough not to
    // compete with greens already present in the photograph.
    const green = STRONG_AREA_SAGE;
    const secondary = ANNOTATION_HALO;
    const shortEdge = Math.min(sw, sh);
    const minSizePx = Math.max(
      10,
      Math.round((MIN_STRONG_AREA_DRAG_PCT / 100) * shortEdge)
    );

    for (const area of areas) {
      if (area.shape === "path") {
        renderAreaPath(strongAreaLayer, area, {
          isSelected: area.id === state.selectedStrongAreaId,
          tertiary: STRONG_AREA_SAGE,
          haloColor: secondary,
          stageWidth: sw,
          stageHeight: sh,
          shortEdge,
          onSelect: () => onSelectStrongArea?.(area.id),
          modeMatches: state.visualMode === "strong_area",
          isRetracing: area.id === state.retracingStrongAreaId,
        });
        continue;
      }
      const cx = ((area.xPct + area.widthPct / 2) / 100) * sw;
      const cy = ((area.yPct + area.heightPct / 2) / 100) * sh;
      const rx = (area.widthPct / 200) * sw;
      const ry = (area.heightPct / 200) * sh;
      if (rx <= 0 || ry <= 0) {
        continue;
      }
      const isSelected = area.id === state.selectedStrongAreaId;
      const canEdit =
        isSelected &&
        state.visualMode === "strong_area" &&
        state.strongAreaEditEnabled;

      // Widened from 0.55% → 0.75% of short edge so the white halo
      // gives the muted ochre / sage stroke enough contrast on
      // foliage / sky / similarly-toned backgrounds.
      const haloWidth = Math.max(5, Math.round(shortEdge * 0.0075));
      const strokeWidth = isSelected
        ? Math.max(3, Math.round(shortEdge * 0.005))
        : Math.max(2, Math.round(shortEdge * 0.0035));
      const id = area.id;

      const haloRef = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        stroke: secondary,
        strokeWidth: haloWidth,
        fillEnabled: false,
        opacity: 0.85,
        listening: false,
        shadowColor: ANNOTATION_HALO_SHADOW,
        shadowBlur: ANNOTATION_HALO_SHADOW_BLUR,
        shadowOpacity: ANNOTATION_HALO_SHADOW_OPACITY,
        shadowForStrokeEnabled: true,
      });
      strongAreaLayer.add(haloRef);

      // Fill body — listening + draggable only when the marker is
      // selected and editable. Mirrors the attention-pull pattern:
      // interior is pass-through for unselected markers, then becomes
      // the drag-to-move target after selection.
      const fillBody = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        fill: green,
        opacity: isSelected
          ? AREA_FILL_OPACITY_SELECTED
          : AREA_FILL_OPACITY_UNSELECTED,
        strokeEnabled: false,
        name: `strong-area-${id}`,
        listening: canEdit,
        draggable: canEdit,
        dragBoundFunc(pos) {
          const w = fillBody.radiusX() * fillBody.scaleX();
          const h = fillBody.radiusY() * fillBody.scaleY();
          const stageW = stage.width();
          const stageH = stage.height();
          return {
            x: Math.max(w, Math.min(stageW - w, pos.x)),
            y: Math.max(h, Math.min(stageH - h, pos.y)),
          };
        },
      });
      fillBody.on("click tap", (e) => {
        e.cancelBubble = true;
        onSelectStrongArea?.(id);
      });
      // Cursor cue matching attention pulls — "move" when draggable,
      // "pointer" when only clickable.
      fillBody.on("mouseenter", () => {
        container.style.cursor = canEdit ? "move" : "pointer";
      });
      fillBody.on("mouseleave", () => {
        applyContainerCursor();
      });
      strongAreaLayer.add(fillBody);

      // SOLID stroke (no dash) — visual contrast with attention pull's
      // dashed outline. The border is the click target for selection;
      // hitStrokeWidth widens the hit zone so the user doesn't need
      // pixel-perfect aim.
      const strokeHitWidth = Math.max(14, strokeWidth * 4);
      const strokeRef = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        stroke: green,
        strokeWidth,
        fillEnabled: false,
        listening: true,
        hitStrokeWidth: strokeHitWidth,
        name: `strong-area-stroke-${id}`,
      });
      strokeRef.on("click tap", (e) => {
        e.cancelBubble = true;
        onSelectStrongArea?.(id);
      });
      strokeRef.on("mouseenter", () => {
        container.style.cursor = "pointer";
      });
      strokeRef.on("mouseleave", () => {
        applyContainerCursor();
      });
      strongAreaLayer.add(strokeRef);

      // Label badge (S1, S2, …) at the upper-left corner.
      const badgeOffset = Math.max(3, Math.round(shortEdge * 0.004));
      let labelRef = null;
      if (area.label) {
        const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
        const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
        labelRef = new Konva.Label({
          x: cx - rx + badgeOffset,
          y: cy - ry + badgeOffset,
          listening: false,
        });
        labelRef.add(
          new Konva.Tag({
            fill: green,
            cornerRadius: 3,
            stroke: secondary,
            strokeWidth: 1.5,
            opacity: isSelected ? 1 : 0.95,
            shadowColor: ANNOTATION_HALO_SHADOW,
            shadowBlur: ANNOTATION_BADGE_SHADOW_BLUR,
            shadowOpacity: ANNOTATION_BADGE_SHADOW_OPACITY,
          })
        );
        labelRef.add(
          new Konva.Text({
            text: area.label,
            fontSize: badgeFontSize,
            fontFamily: "sans-serif",
            fontStyle: "bold",
            fill: secondary,
            padding: badgePadding,
          })
        );
        strongAreaLayer.add(labelRef);
      }

      if (canEdit) {
        const syncDecorations = () => {
          const ex = fillBody.x();
          const ey = fillBody.y();
          const erx = fillBody.radiusX() * fillBody.scaleX();
          const ery = fillBody.radiusY() * fillBody.scaleY();
          haloRef.position({ x: ex, y: ey });
          haloRef.radiusX(erx);
          haloRef.radiusY(ery);
          strokeRef.position({ x: ex, y: ey });
          strokeRef.radiusX(erx);
          strokeRef.radiusY(ery);
          if (labelRef) {
            labelRef.position({
              x: ex - erx + badgeOffset,
              y: ey - ery + badgeOffset,
            });
          }
          annotationsLayer.batchDraw();
        };

        const emitUpdate = () => {
          const stageW = stage.width();
          const stageH = stage.height();
          if (stageW === 0 || stageH === 0) {
            return;
          }
          const erx = fillBody.radiusX();
          const ery = fillBody.radiusY();
          const ex = fillBody.x();
          const ey = fillBody.y();
          const xPct = Math.max(
            0,
            Math.min(100, ((ex - erx) / stageW) * 100)
          );
          const yPct = Math.max(
            0,
            Math.min(100, ((ey - ery) / stageH) * 100)
          );
          const widthPct = Math.max(
            0,
            Math.min(100 - xPct, ((2 * erx) / stageW) * 100)
          );
          const heightPct = Math.max(
            0,
            Math.min(100 - yPct, ((2 * ery) / stageH) * 100)
          );
          state.strongAreas = state.strongAreas.map((p) =>
            p.id === id
              ? { ...p, xPct, yPct, widthPct, heightPct }
              : p
          );
          onUpdateStrongArea?.(id, xPct, yPct, widthPct, heightPct);
        };

        fillBody.on("dragmove", syncDecorations);
        fillBody.on("dragend", emitUpdate);
        fillBody.on("transform", syncDecorations);
        fillBody.on("transformend", () => {
          const sx = fillBody.scaleX();
          const sy = fillBody.scaleY();
          fillBody.scaleX(1);
          fillBody.scaleY(1);
          fillBody.radiusX(Math.max(1, fillBody.radiusX() * sx));
          fillBody.radiusY(Math.max(1, fillBody.radiusY() * sy));
          haloRef.radiusX(fillBody.radiusX());
          haloRef.radiusY(fillBody.radiusY());
          strokeRef.radiusX(fillBody.radiusX());
          strokeRef.radiusY(fillBody.radiusY());
          emitUpdate();
        });

        const transformer = new Konva.Transformer({
          nodes: [fillBody],
          rotateEnabled: false,
          keepRatio: false,
          enabledAnchors: [
            "top-left",
            "top-center",
            "top-right",
            "middle-left",
            "middle-right",
            "bottom-left",
            "bottom-center",
            "bottom-right",
          ],
          borderEnabled: false,
          anchorSize: 10,
          anchorCornerRadius: 2,
          anchorStroke: green,
          anchorFill: secondary,
          anchorStrokeWidth: 1.5,
          boundBoxFunc(oldBox, newBox) {
            if (
              newBox.width < minSizePx ||
              newBox.height < minSizePx
            ) {
              return oldBox;
            }
            if (newBox.x < 0 || newBox.y < 0) {
              return oldBox;
            }
            if (
              newBox.x + newBox.width > sw ||
              newBox.y + newBox.height > sh
            ) {
              return oldBox;
            }
            return newBox;
          },
        });
        strongAreaLayer.add(transformer);
      }
    }
    annotationsLayer.batchDraw();
  }

  function renderPins() {
    pinLayer.destroyChildren();
    for (const pin of state.pins) {
      pinLayer.add(buildPinGroup(pin));
    }
    annotationsLayer.batchDraw();
  }

  // Eye-paths renderer. Iterates over state.eyePaths and renders
  // each path's decoration + hit-zone + handles. Each path reads as
  // direction-from-start-to-end:
  //   • small dot at the first point — "begin here"
  //   • halo polyline + tertiary line (slightly translucent)
  //   • interior waypoint dots when selected (the selected-state cue)
  //   • slightly emphatic terminal arrowhead at the last point —
  //     "ends here, attention lands"
  function renderEyePaths() {
    eyePathLayer.destroyChildren();

    const paths = Array.isArray(state.eyePaths) ? state.eyePaths : [];
    if (paths.length === 0) {
      annotationsLayer.batchDraw();
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      annotationsLayer.batchDraw();
      return;
    }

    // Eye path uses a pale glacial cyan — distinct from the deeper
    // Notes blue so the two no longer read as variants of the same
    // marker. The white halo on the polyline provides contrast on
    // dark backgrounds; against bright skies the pale tertiary will
    // sit quieter (intentional — eye path should feel like organic
    // flow, not a "read this note" stamp).
    const tertiary = EYE_PATH_PALE_CYAN;
    const secondary = ANNOTATION_HALO;
    const tertiaryHover = EYE_PATH_PALE_CYAN;
    const shortEdge = Math.min(sw, sh);

    for (const path of paths) {
      if (!path || !Array.isArray(path.points) || path.points.length === 0) {
        continue;
      }
      renderOneEyePath(path);
    }
    annotationsLayer.batchDraw();

    // Per-path render function — closure over sw/sh/colors above. All
    // the geometry, decoration, hit-zone, and handle logic lives here
    // so each path gets its own independent sub-tree (decorations
    // group, hit group, handles) parented to eyePathLayer.
    function renderOneEyePath(path) {
      const isSelected = state.selectedEyePathId === path.id;

    // Convert percentage points → stage pixel coords. Mutable so
    // dragend can update one entry without re-running the whole
    // mapping; subsequent dragmoves on OTHER handles then read the
    // up-to-date geometry.
    const livePts = path.points.map((p) => ({
      x: (p.xPct / 100) * sw,
      y: (p.yPct / 100) * sh,
    }));

    // Decorations live in their own sub-group so dragmove can
    // destroy + rebuild them every frame without disturbing the
    // persistent handles. Layer hit-test still works because the
    // handles are added to the layer AFTER this group.
    const decorationsGroup = new Konva.Group({ listening: false });
    eyePathLayer.add(decorationsGroup);

    // Hit-zone group — a transparent fat-stroke line that mirrors
    // the visible curve geometry (same points, same tension) so
    // clicks anywhere ON the curve select the eye path. Without
    // this, the only hit targets are the small waypoint handles;
    // users had to know to click a point dot rather than the curve
    // itself, which made selection finicky. We use a separate
    // listening sub-group rather than flipping `listening: true` on
    // decorationsGroup so the visible polyline + halo + arrowheads
    // stay non-listening (they cover large areas and would
    // intercept clicks meant for the underlying image or other
    // annotations).
    //
    // Z-order inside eyePathLayer (back → front):
    //   1. decorationsGroup   (visual, listening: false)
    //   2. hitGroup           (invisible, listening: true)
    //   3. handles (added after this function)
    // Konva hit-tests front-to-back, so a click on a waypoint
    // hits the handle first (correct — drag/select that point);
    // a click on the curve away from any waypoint falls to the
    // hitGroup and selects the path; clicks fully off the curve
    // pass through to the stage.
    const hitGroup = new Konva.Group({ listening: true });
    eyePathLayer.add(hitGroup);

    // Konva-tension geometry helpers. Konva.Line's `tension` uses a
    // chord-length-weighted Catmull-Rom + splits the path into a
    // quadratic first segment, cubic middle segments, and a quadratic
    // last segment. Chevron sampling has to match this exactly or it
    // floats off the rendered curve. See Konva.Util._calcCP for the
    // reference implementation.
    function getKonvaSegment(pts, i) {
      const p1 = pts[i];
      const p2 = pts[i + 1];
      if (!EYE_PATH_SMOOTH || pts.length < 3) {
        return { type: "linear", p1, p2 };
      }
      const isFirst = i === 0;
      const isLast = i === pts.length - 2;
      const t = EYE_PATH_SMOOTH_TENSION;
      if (isFirst) {
        // First segment uses a quadratic with the INCOMING control
        // point of pts[1] = p2 − fa·(pts[2] − p1).
        const pNext = pts[i + 2];
        const d01 = Math.hypot(p2.x - p1.x, p2.y - p1.y);
        const d12 = Math.hypot(pNext.x - p2.x, pNext.y - p2.y);
        const denom = d01 + d12 || 1;
        const fa = (t * d01) / denom;
        return {
          type: "quad",
          p1,
          p2,
          cp: {
            x: p2.x - fa * (pNext.x - p1.x),
            y: p2.y - fa * (pNext.y - p1.y),
          },
        };
      }
      if (isLast) {
        // Last segment uses a quadratic with the OUTGOING control
        // point of p1 = p1 + fb·(p2 − pts[i−1]).
        const pPrev = pts[i - 1];
        const d01 = Math.hypot(p1.x - pPrev.x, p1.y - pPrev.y);
        const d12 = Math.hypot(p2.x - p1.x, p2.y - p1.y);
        const denom = d01 + d12 || 1;
        const fb = (t * d12) / denom;
        return {
          type: "quad",
          p1,
          p2,
          cp: {
            x: p1.x + fb * (p2.x - pPrev.x),
            y: p1.y + fb * (p2.y - pPrev.y),
          },
        };
      }
      // Middle segment: cubic. Outgoing CP at p1, incoming CP at p2.
      const pPrev = pts[i - 1];
      const pNext = pts[i + 2];
      const d01_p1 = Math.hypot(p1.x - pPrev.x, p1.y - pPrev.y);
      const d12_p1 = Math.hypot(p2.x - p1.x, p2.y - p1.y);
      const denom1 = d01_p1 + d12_p1 || 1;
      const fb_p1 = (t * d12_p1) / denom1;
      const d01_p2 = Math.hypot(p2.x - p1.x, p2.y - p1.y);
      const d12_p2 = Math.hypot(pNext.x - p2.x, pNext.y - p2.y);
      const denom2 = d01_p2 + d12_p2 || 1;
      const fa_p2 = (t * d01_p2) / denom2;
      return {
        type: "cubic",
        p1,
        p2,
        c1: {
          x: p1.x + fb_p1 * (p2.x - pPrev.x),
          y: p1.y + fb_p1 * (p2.y - pPrev.y),
        },
        c2: {
          x: p2.x - fa_p2 * (pNext.x - p1.x),
          y: p2.y - fa_p2 * (pNext.y - p1.y),
        },
      };
    }
    function samplePos(seg, t) {
      if (seg.type === "linear") {
        return {
          x: seg.p1.x + (seg.p2.x - seg.p1.x) * t,
          y: seg.p1.y + (seg.p2.y - seg.p1.y) * t,
        };
      }
      if (seg.type === "quad") {
        const it = 1 - t;
        return {
          x: it * it * seg.p1.x + 2 * it * t * seg.cp.x + t * t * seg.p2.x,
          y: it * it * seg.p1.y + 2 * it * t * seg.cp.y + t * t * seg.p2.y,
        };
      }
      const it = 1 - t;
      const it2 = it * it;
      const it3 = it2 * it;
      const t2 = t * t;
      const t3 = t2 * t;
      return {
        x:
          it3 * seg.p1.x +
          3 * it2 * t * seg.c1.x +
          3 * it * t2 * seg.c2.x +
          t3 * seg.p2.x,
        y:
          it3 * seg.p1.y +
          3 * it2 * t * seg.c1.y +
          3 * it * t2 * seg.c2.y +
          t3 * seg.p2.y,
      };
    }
    function sampleTangent(seg, t) {
      if (seg.type === "linear") {
        return { x: seg.p2.x - seg.p1.x, y: seg.p2.y - seg.p1.y };
      }
      if (seg.type === "quad") {
        const it = 1 - t;
        return {
          x: 2 * it * (seg.cp.x - seg.p1.x) + 2 * t * (seg.p2.x - seg.cp.x),
          y: 2 * it * (seg.cp.y - seg.p1.y) + 2 * t * (seg.p2.y - seg.cp.y),
        };
      }
      const it = 1 - t;
      return {
        x:
          3 * it * it * (seg.c1.x - seg.p1.x) +
          6 * it * t * (seg.c2.x - seg.c1.x) +
          3 * t * t * (seg.p2.x - seg.c2.x),
        y:
          3 * it * it * (seg.c1.y - seg.p1.y) +
          6 * it * t * (seg.c2.y - seg.c1.y) +
          3 * t * t * (seg.p2.y - seg.c2.y),
      };
    }

    // Click-anywhere-on-curve selection. Sized generously so the
    // hit zone is comfortable on touch screens too — roughly 2.5×
    // the visible line width. Pulled out as a const so the click +
    // cursor handlers below and the hit-line construction inside
    // buildDecorations stay in sync on width.
    const curveHitWidth = Math.max(18, Math.round(shortEdge * 0.025));

    function buildDecorations(pts) {
      decorationsGroup.destroyChildren();
      hitGroup.destroyChildren();

      if (pts.length >= 2) {
        const flat = [];
        for (const p of pts) {
          flat.push(p.x, p.y);
        }
        const haloWidth = Math.max(5, Math.round(shortEdge * 0.0075));
        const lineWidth = Math.max(2, Math.round(shortEdge * 0.004));

        // Invisible fat-stroke hit-zone line. Same `points` and
        // `tension` as the visible polyline below so the hit area
        // tracks the actual rendered curve (not a straight-segment
        // approximation). `opacity: 0` hides it visually while
        // Konva still rasterises it to the hit graph — the same
        // pattern this file already uses for the waypoint handles.
        // Listening must be enabled because the parent group has
        // it on by default and we want this node to receive clicks.
        // In eye_path mode the user is CREATING — every click/drag
        // should be free to start a new path even if it lands within
        // an existing path's wide invisible hit-zone. Setting
        // listening: false there lets the gesture fall through to the
        // stage's mousedown/up handlers (which begin a stroke drag or
        // add a Points-mode point). Outside eye_path mode the hit-
        // zone is the primary way to click-to-select an existing path.
        const hitLineListening = state.visualMode !== "eye_path";
        const hitLine = new Konva.Line({
          points: flat,
          stroke: "black",
          strokeWidth: curveHitWidth,
          opacity: 0,
          lineCap: "round",
          lineJoin: "round",
          tension: EYE_PATH_SMOOTH ? EYE_PATH_SMOOTH_TENSION : 0,
          listening: hitLineListening,
          name: "eye-path-curve-hit",
        });
        if (hitLineListening) {
          hitLine.on("mouseenter", () => {
            container.style.cursor = "pointer";
          });
          hitLine.on("mouseleave", () => {
            applyContainerCursor();
          });
          hitLine.on("click tap", (e) => {
            e.cancelBubble = true;
            onSelectEyePath?.(path.id);
          });
        }
        hitGroup.add(hitLine);

        // White halo for readability over dark image areas, plus a
        // soft dark outer edge so the path also reads on high-key
        // backgrounds (snow / fog / overexposed sky).
        decorationsGroup.add(
          new Konva.Line({
            points: flat,
            stroke: secondary,
            strokeWidth: haloWidth,
            lineCap: "round",
            lineJoin: "round",
            opacity: 0.9,
            // tension > 0 softens sharp click-to-click angles into a
            // Catmull-Rom curve through every point. 0 = straight.
            tension: EYE_PATH_SMOOTH ? EYE_PATH_SMOOTH_TENSION : 0,
            listening: false,
            shadowColor: ANNOTATION_HALO_SHADOW,
            shadowBlur: ANNOTATION_HALO_SHADOW_BLUR,
            shadowOpacity: ANNOTATION_HALO_SHADOW_OPACITY,
            shadowForStrokeEnabled: true,
          })
        );
        // Main tertiary line. Slim + slightly translucent so the
        // photo reads through. Tints to tertiaryHover when selected.
        decorationsGroup.add(
          new Konva.Line({
            points: flat,
            stroke: isSelected ? tertiaryHover : tertiary,
            strokeWidth: lineWidth,
            lineCap: "round",
            lineJoin: "round",
            opacity: 0.9,
            tension: EYE_PATH_SMOOTH ? EYE_PATH_SMOOTH_TENSION : 0,
            listening: false,
          })
        );

        // Mid-line directional arrows are EXPORT-ONLY. In the editor
        // the waypoint dots (rendered below) already convey both
        // direction and editability — stacking arrows on top makes
        // the path read busy. The exported JPEG has no waypoint dots
        // (`drawEyePathOnCanvas` in npn-critique-reply-visual-notes.js
        // draws line + start dot + mid arrows + terminal arrow), so
        // arrows still carry the directional cue there.
      }

      // Points mode: always render small numbered badges at every
      // clicked stop (1..N). The numbers are sequence cues for the
      // critic; they do NOT become inline post badges (the textarea
      // reference remains [E1] regardless). Stroke mode falls back
      // to the legacy interior waypoint dots — visible only when
      // selected — so its "editor handles" cue stays unobtrusive.
      const isPointsMode = path.mode === "points";
      if (isPointsMode && pts.length >= 1) {
        const stopFontSize = Math.max(10, Math.round(shortEdge * 0.014));
        const stopPadding = Math.max(2, Math.round(stopFontSize * 0.28));
        const stopR = Math.max(8, Math.round(shortEdge * 0.0085));
        const stopHaloR = stopR + Math.max(2, Math.round(stopR * 0.35));
        // Number every stop EXCEPT the last one — the terminal
        // arrowhead drawn later already marks the path's end, so a
        // numbered badge there would compete with it. Single-point
        // paths still get "1" since there's no arrowhead in that
        // case.
        const lastNumbered = pts.length === 1 ? 0 : pts.length - 2;
        for (let i = 0; i <= lastNumbered; i++) {
          const wp = pts[i];
          // Halo + filled circle so the digit reads on light AND
          // dark backgrounds. Halo carries the same soft dark drop-
          // shadow as the path's line halo so the stop stays visible
          // on high-key backgrounds.
          decorationsGroup.add(
            new Konva.Circle({
              x: wp.x,
              y: wp.y,
              radius: stopHaloR,
              fill: secondary,
              opacity: 0.92,
              listening: false,
              shadowColor: ANNOTATION_HALO_SHADOW,
              shadowBlur: ANNOTATION_BADGE_SHADOW_BLUR,
              shadowOpacity: ANNOTATION_BADGE_SHADOW_OPACITY,
            })
          );
          decorationsGroup.add(
            new Konva.Circle({
              x: wp.x,
              y: wp.y,
              radius: stopR,
              fill: isSelected ? tertiaryHover : tertiary,
              listening: false,
            })
          );
          // Number text. We sample the text dimensions from Konva via
          // a fresh Text node so the centering is exact regardless of
          // glyph metrics.
          const numberText = new Konva.Text({
            text: String(i + 1),
            fontSize: stopFontSize,
            fontStyle: "600",
            fill: "#ffffff",
            padding: stopPadding,
            listening: false,
          });
          numberText.x(wp.x - numberText.width() / 2);
          numberText.y(wp.y - numberText.height() / 2);
          decorationsGroup.add(numberText);
        }
      } else if (pts.length >= 3 && isSelected) {
        // Stroke-mode legacy behavior: interior waypoint dots only
        // when selected — these signal the draggable editing handles.
        const waypointR = Math.max(4, Math.round(shortEdge * 0.0045));
        const waypointHaloR =
          waypointR + Math.max(2, Math.round(waypointR * 0.5));
        for (let i = 1; i < pts.length - 1; i++) {
          const wp = pts[i];
          decorationsGroup.add(
            new Konva.Circle({
              x: wp.x,
              y: wp.y,
              radius: waypointHaloR,
              fill: secondary,
              opacity: 0.9,
              listening: false,
            })
          );
          decorationsGroup.add(
            new Konva.Circle({
              x: wp.x,
              y: wp.y,
              radius: waypointR,
              fill: isSelected ? tertiaryHover : tertiary,
              listening: false,
            })
          );
        }
      }

      // Start dot — the "begin here" anchor, always visible so the
      // path's direction reads at a glance regardless of selection
      // state. Interior waypoint dots above are the selected-state
      // cue (they appear when the user clicks the curve and vanish
      // when selection clears); the start dot stays put as the
      // permanent direction anchor and matches the exported JPEG.
      //
      // In Points mode the numbered "1" badge above already marks
      // the start, so we skip the start dot to avoid stacking two
      // circles. The label badge still anchors to `start` below.
      if (pts.length >= 1) {
        const startR = Math.max(4, Math.round(shortEdge * 0.0065));
        const startHaloR = startR + Math.max(2, Math.round(startR * 0.4));
        const start = pts[0];
        if (!isPointsMode) {
          decorationsGroup.add(
            new Konva.Circle({
              x: start.x,
              y: start.y,
              radius: startHaloR,
              fill: secondary,
              opacity: 0.9,
              listening: false,
            })
          );
          decorationsGroup.add(
            new Konva.Circle({
              x: start.x,
              y: start.y,
              radius: startR,
              fill: isSelected ? tertiaryHover : tertiary,
              listening: false,
            })
          );
        }

        // Label badge — small tertiary pill near the start dot.
        // The eye-path badge is intentionally quieter than the D/R
        // arrow badges and much quieter than the filled Notes pins:
        // smaller font (~12% smaller) and lower unselected opacity
        // (0.7 vs the other tools' 0.95). Eye Path is meant to read
        // as organic flow, not as a labeled callout; the badge is
        // here for "which path is which" identification when 2+
        // paths exist, not as the primary visual element.
        const label = path.label;
        if (label) {
          const badgeFontSize = Math.max(10, Math.round(shortEdge * 0.016));
          const badgePadding = Math.max(2, Math.round(badgeFontSize * 0.25));
          const badgeHeight = badgeFontSize + 2 * badgePadding;
          const badgeOffset = Math.max(6, Math.round(shortEdge * 0.006));
          // Estimated badge width — Konva won't tell us the rendered
          // width until after the Text node is measured, so we
          // estimate from font size × character count. Good enough to
          // bounds-flip; the visible offset is tiny if we over-shoot.
          const estimatedBadgeW =
            badgeFontSize * 0.65 * label.length + 2 * badgePadding;
          // Prefer above-right of the start dot. Flip to above-left
          // if the right edge would overflow the stage, and flip to
          // below if the top edge would overflow.
          let labelX = start.x + badgeOffset;
          let labelY = start.y - badgeHeight - badgeOffset;
          if (labelX + estimatedBadgeW > sw) {
            labelX = start.x - estimatedBadgeW - badgeOffset;
          }
          if (labelY < 0) {
            labelY = start.y + badgeOffset;
          }
          const labelNode = new Konva.Label({
            x: labelX,
            y: labelY,
            listening: false,
          });
          labelNode.add(
            new Konva.Tag({
              fill: isSelected ? tertiaryHover : tertiary,
              cornerRadius: 3,
              stroke: secondary,
              strokeWidth: 1,
              opacity: isSelected ? 1 : 0.7,
              shadowColor: ANNOTATION_HALO_SHADOW,
              shadowBlur: ANNOTATION_BADGE_SHADOW_BLUR,
              shadowOpacity: ANNOTATION_BADGE_SHADOW_OPACITY,
            })
          );
          labelNode.add(
            new Konva.Text({
              text: label,
              fontSize: badgeFontSize,
              fontFamily: "sans-serif",
              fontStyle: "bold",
              fill: secondary,
              padding: badgePadding,
            })
          );
          decorationsGroup.add(labelNode);
        }
      }

      // Terminal arrowhead.
      if (pts.length >= 2) {
        const terminalSize = Math.max(10, Math.round(shortEdge * 0.0175));
        const a = pts[pts.length - 2];
        const b = pts[pts.length - 1];
        // Sample the last rendered segment near its endpoint so the
        // arrow direction matches the curve's actual local tangent.
        // getKonvaSegment returns the right segment type (quadratic
        // for last-of-3+, linear for 2-point or smoothing-off).
        let dirX = b.x - a.x;
        let dirY = b.y - a.y;
        if (EYE_PATH_SMOOTH && pts.length >= 3) {
          const lastSeg = getKonvaSegment(pts, pts.length - 2);
          const chord = Math.hypot(b.x - a.x, b.y - a.y);
          const sampleT =
            chord > 0
              ? Math.max(0.5, Math.min(0.95, 1 - terminalSize / chord))
              : 0.85;
          const sampled = samplePos(lastSeg, sampleT);
          dirX = b.x - sampled.x;
          dirY = b.y - sampled.y;
        }
        const len = Math.hypot(dirX, dirY);
        if (len > 0) {
          const ux = dirX / len;
          const uy = dirY / len;
          const perpX = -uy;
          const perpY = ux;
          const baseCx = b.x - ux * terminalSize;
          const baseCy = b.y - uy * terminalSize;
          const baseHalf = terminalSize * 0.55;
          decorationsGroup.add(
            new Konva.Line({
              points: [
                b.x,
                b.y,
                baseCx + perpX * baseHalf,
                baseCy + perpY * baseHalf,
                baseCx - perpX * baseHalf,
                baseCy - perpY * baseHalf,
              ],
              closed: true,
              fill: isSelected ? tertiaryHover : tertiary,
              stroke: secondary,
              strokeWidth: 1.5,
              listening: false,
            })
          );
        }
      }
    }

    // Initial decoration draw with the current geometry.
    buildDecorations(livePts);

    // Invisible drag handles at each point — large hit-targets so
    // touch users can grab the path without precision. Visible
    // waypoint dots above (in decorationsGroup) tell the critic
    // where the handles ARE; these are the underlying hit areas.
    // Handles are added AFTER the decorations group so they sit on
    // top in the hit canvas.
    // Handles are inert during eye_path creation mode for the same
    // reason the curve hit-line is — a click/drag starting near an
    // existing waypoint should begin a new path or point, not get
    // captured by Konva's drag-to-reshape. Reshape stays available
    // whenever the user is in any non-eye_path mode.
    const handleHitR = Math.max(10, Math.round(shortEdge * 0.014));
    const handlesListening = state.visualMode !== "eye_path";
    for (let i = 0; i < livePts.length; i++) {
      const p = livePts[i];
      const pointNumber = path.points[i].number ?? i + 1;
      const pointIndex = i;
      const handle = new Konva.Circle({
        x: p.x,
        y: p.y,
        radius: handleHitR,
        fill: tertiary,
        opacity: 0,
        draggable: handlesListening,
        listening: handlesListening,
        name: `eye-path-handle-${pointNumber}`,
        dragBoundFunc(pos) {
          const stageW = stage.width();
          const stageH = stage.height();
          return {
            x: Math.max(0, Math.min(stageW, pos.x)),
            y: Math.max(0, Math.min(stageH, pos.y)),
          };
        },
      });

      if (!handlesListening) {
        eyePathLayer.add(handle);
        continue;
      }

      handle.on("mouseenter", () => {
        container.style.cursor = "move";
      });
      handle.on("mouseleave", () => {
        applyContainerCursor();
      });

      // Live re-render of decorations so line + arrows + start dot
      // + terminal arrow all follow the dragged point in real time.
      // Other handles are unaffected (they live outside this group).
      handle.on("dragmove", () => {
        const updated = livePts.map((pt, j) =>
          j === pointIndex ? { x: handle.x(), y: handle.y() } : pt
        );
        buildDecorations(updated);
        annotationsLayer.batchDraw();
      });

      handle.on("dragend", () => {
        const curW = stage.width();
        const curH = stage.height();
        if (curW === 0 || curH === 0) {
          return;
        }
        const newXPct = Math.max(0, Math.min(100, (handle.x() / curW) * 100));
        const newYPct = Math.max(0, Math.min(100, (handle.y() / curH) * 100));
        // Keep livePts in sync so subsequent drags of OTHER handles
        // compute against the new geometry without rebuilding from
        // the closure state.
        livePts[pointIndex] = { x: handle.x(), y: handle.y() };
        // Update closure state BEFORE the callback so the next sync
        // (driven by the modal updating its tracked eyePaths) sees
        // identical coords and skips a redundant re-render. We
        // mutate ONLY the entry whose id matches this path so the
        // other paths' points aren't disturbed.
        state.eyePaths = state.eyePaths.map((p) =>
          p.id === path.id
            ? {
                ...p,
                points: (p.points ?? []).map((pt, idx) =>
                  idx === pointIndex
                    ? { ...pt, xPct: newXPct, yPct: newYPct }
                    : pt
                ),
              }
            : p
        );
        // Final decoration redraw so everything lands at the exact
        // dragend coords (defensive — dragmove already ran on the
        // same coords, but this guards against any rounding drift).
        buildDecorations(livePts);
        annotationsLayer.batchDraw();
        onMoveEyePathPoint?.(path.id, pointNumber, newXPct, newYPct);
      });

      // Plain click without movement → select the path. (This branch
      // only runs when handlesListening is true — see the early
      // continue above for the eye_path-mode inert case.)
      handle.on("click tap", (e) => {
        e.cancelBubble = true;
        onSelectEyePath?.(path.id);
      });

      eyePathLayer.add(handle);
    }
    } // end renderOneEyePath
  } // end renderEyePaths

  // ----- Arrow renderers (direction + relationship) -----------------
  //
  // Both arrow kinds share the same drawing primitives — a stroke
  // line, a halo behind it for contrast, an arrowhead, an invisible
  // fat-stroke hit-zone for selection clicks, and a label badge near
  // the midpoint. The only differences:
  //   • direction_arrow → one arrowhead (at head/x2,y2)
  //   • relationship_arrow → two arrowheads (one at each end), and a
  //     lighter dashed line to read as "non-directional"
  // Pulled into a single helper so the layering / hit-zone / badge
  // logic stays in one place; per-kind options are passed in.
  function buildArrowGroup({
    arrow,
    sw,
    sh,
    layer,
    isSelected,
    onClickSelect,
    onUpdate,
    bothEnds,
    dashed,
    // Per-kind palette + weight. Direction arrows use the slightly
    // more prominent indigo + standard stroke weight; relationship
    // arrows use the warmer taupe with a slightly thinner stroke and
    // lower base opacity so they read as "quieter" relational ties
    // rather than as a competing directional pull.
    tertiary = ANNOTATION_BLUE,
    strokeWeight = 1,
    baseOpacity = 0.9,
  }) {
    const shortEdge = Math.min(sw, sh);
    const secondary = ANNOTATION_HALO;
    const lineWidth = Math.max(
      2,
      Math.round(shortEdge * 0.004 * strokeWeight)
    );
    const haloWidth = Math.max(
      5,
      Math.round(shortEdge * 0.0075 * strokeWeight)
    );
    const arrowheadLen = Math.max(10, Math.round(shortEdge * 0.018));
    const dash = dashed
      ? [
          Math.max(6, Math.round(shortEdge * 0.012)),
          Math.max(4, Math.round(shortEdge * 0.008)),
        ]
      : undefined;

    // Live endpoint coords. Mutated during handle dragmove so a
    // subsequent drag on the OTHER endpoint reads up-to-date geometry
    // without rebuilding from `arrow`. Same pattern the eye-path
    // renderer uses for its waypoint handles.
    const live = {
      x1: (arrow.x1Pct / 100) * sw,
      y1: (arrow.y1Pct / 100) * sh,
      x2: (arrow.x2Pct / 100) * sw,
      y2: (arrow.y2Pct / 100) * sh,
    };

    // Per-arrow decoration sub-group. Halo + line + arrowheads + label
    // + hit-zone all live here so dragmove can destroyChildren on this
    // group and rebuild without disturbing the endpoint handle nodes
    // (which sit on the parent layer, outside the sub-group). Listening
    // is on because the hit-zone needs to fire click events.
    const decorationsGroup = new Konva.Group({ listening: true });
    layer.add(decorationsGroup);

    function rebuildDecorations() {
      decorationsGroup.destroyChildren();
      const dx = live.x2 - live.x1;
      const dy = live.y2 - live.y1;
      const len = Math.hypot(dx, dy);
      if (len <= 0) {
        return;
      }
      const ux = dx / len;
      const uy = dy / len;

      // Trim the line near arrowheads so the head's solid fill
      // doesn't peek beyond the line's stroke.
      const trim = arrowheadLen * 0.55;
      const lineStartX = bothEnds ? live.x1 + ux * trim : live.x1;
      const lineStartY = bothEnds ? live.y1 + uy * trim : live.y1;
      const lineEndX = live.x2 - ux * trim;
      const lineEndY = live.y2 - uy * trim;

      // Halo first (sits behind the visible line for readability).
      // Outer dark shadow on the halo keeps the arrow visible on
      // high-key backgrounds where a pure white halo would
      // disappear into the photograph.
      decorationsGroup.add(
        new Konva.Line({
          points: [lineStartX, lineStartY, lineEndX, lineEndY],
          stroke: secondary,
          strokeWidth: haloWidth,
          lineCap: "round",
          lineJoin: "round",
          opacity: 0.9,
          listening: false,
          shadowColor: ANNOTATION_HALO_SHADOW,
          shadowBlur: ANNOTATION_HALO_SHADOW_BLUR,
          shadowOpacity: ANNOTATION_HALO_SHADOW_OPACITY,
          shadowForStrokeEnabled: true,
        })
      );
      decorationsGroup.add(
        new Konva.Line({
          points: [lineStartX, lineStartY, lineEndX, lineEndY],
          stroke: tertiary,
          strokeWidth: lineWidth,
          lineCap: "round",
          lineJoin: "round",
          opacity: isSelected ? 1 : baseOpacity,
          dash,
          listening: false,
        })
      );

      function drawArrowhead(tipX, tipY, uxLocal, uyLocal) {
        const perpX = -uyLocal;
        const perpY = uxLocal;
        const baseCx = tipX - uxLocal * arrowheadLen;
        const baseCy = tipY - uyLocal * arrowheadLen;
        const baseHalf = arrowheadLen * 0.55;
        decorationsGroup.add(
          new Konva.Line({
            points: [
              tipX,
              tipY,
              baseCx + perpX * baseHalf,
              baseCy + perpY * baseHalf,
              baseCx - perpX * baseHalf,
              baseCy - perpY * baseHalf,
            ],
            closed: true,
            fill: tertiary,
            stroke: secondary,
            strokeWidth: 1.5,
            opacity: isSelected ? 1 : 0.95,
            listening: false,
          })
        );
      }
      drawArrowhead(live.x2, live.y2, ux, uy);
      if (bothEnds) {
        drawArrowhead(live.x1, live.y1, -ux, -uy);
      }

      // Endpoint dots — only visible when this arrow is selected.
      // Match the eye-path start dot's sizing/style so the
      // "draggable handle here" affordance reads the same across
      // tools. Drawn AFTER the arrowheads so the dot sits on top
      // of the head's solid fill; halo extends slightly past the
      // arrowhead's edges, giving the endpoint a clear "grab me"
      // marker.
      if (isSelected) {
        const dotR = Math.max(4, Math.round(shortEdge * 0.0065));
        const dotHaloR = dotR + Math.max(2, Math.round(dotR * 0.4));
        for (const [px, py] of [
          [live.x1, live.y1],
          [live.x2, live.y2],
        ]) {
          decorationsGroup.add(
            new Konva.Circle({
              x: px,
              y: py,
              radius: dotHaloR,
              fill: secondary,
              opacity: 0.9,
              listening: false,
            })
          );
          decorationsGroup.add(
            new Konva.Circle({
              x: px,
              y: py,
              radius: dotR,
              fill: tertiary,
              listening: false,
            })
          );
        }
      }

      // Label badge near midpoint.
      if (arrow.label) {
        const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
        const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
        const badgeHeight = badgeFontSize + 2 * badgePadding;
        const badgeOffset = Math.max(6, Math.round(shortEdge * 0.006));
        const estimatedBadgeW =
          badgeFontSize * 0.65 * arrow.label.length + 2 * badgePadding;
        const midX = (live.x1 + live.x2) / 2;
        const midY = (live.y1 + live.y2) / 2;
        let perpX = -uy;
        let perpY = ux;
        let labelX = midX + perpX * badgeOffset;
        let labelY = midY + perpY * badgeOffset - badgeHeight / 2;
        if (
          labelX < 0 ||
          labelX + estimatedBadgeW > sw ||
          labelY < 0 ||
          labelY + badgeHeight > sh
        ) {
          perpX = uy;
          perpY = -ux;
          labelX = midX + perpX * badgeOffset;
          labelY = midY + perpY * badgeOffset - badgeHeight / 2;
        }
        const labelNode = new Konva.Label({
          x: labelX,
          y: labelY,
          listening: false,
        });
        labelNode.add(
          new Konva.Tag({
            fill: tertiary,
            cornerRadius: 3,
            stroke: secondary,
            strokeWidth: 1.5,
            opacity: isSelected ? 1 : 0.95,
            shadowColor: ANNOTATION_HALO_SHADOW,
            shadowBlur: ANNOTATION_BADGE_SHADOW_BLUR,
            shadowOpacity: ANNOTATION_BADGE_SHADOW_OPACITY,
          })
        );
        labelNode.add(
          new Konva.Text({
            text: arrow.label,
            fontSize: badgeFontSize,
            fontFamily: "sans-serif",
            fontStyle: "bold",
            fill: secondary,
            padding: badgePadding,
          })
        );
        decorationsGroup.add(labelNode);
      }

      // Invisible fat-stroke hit-zone for click-to-select.
      const hitWidth = Math.max(18, Math.round(shortEdge * 0.025));
      const hitLine = new Konva.Line({
        points: [live.x1, live.y1, live.x2, live.y2],
        stroke: "black",
        strokeWidth: hitWidth,
        opacity: 0,
        lineCap: "round",
        lineJoin: "round",
        listening: true,
        name: `${arrow.id}-hit`,
      });
      hitLine.on("mouseenter", () => {
        container.style.cursor = "pointer";
      });
      hitLine.on("mouseleave", () => {
        applyContainerCursor();
      });
      hitLine.on("click tap", (e) => {
        e.cancelBubble = true;
        onClickSelect?.(arrow.id);
      });
      decorationsGroup.add(hitLine);
    }

    rebuildDecorations();

    // Endpoint handles for resize/reshape — visible only when this
    // arrow is the currently-selected one. Sit on the parent LAYER
    // (not the decoration sub-group) so dragmove's destroyChildren
    // doesn't tear them down mid-drag. Each handle:
    //   • updates `live` on dragmove so subsequent rebuilds use the
    //     latest geometry;
    //   • emits onUpdate(id, ...percent coords...) on dragend so the
    //     modal's tracked state stays canonical;
    //   • clamps to stage bounds via dragBoundFunc.
    if (isSelected && onUpdate) {
      const handleR = Math.max(10, Math.round(shortEdge * 0.014));
      function addHandle(getX, getY, setLive) {
        const handle = new Konva.Circle({
          x: getX(),
          y: getY(),
          radius: handleR,
          fill: tertiary,
          opacity: 0,
          draggable: true,
          dragBoundFunc(pos) {
            return {
              x: Math.max(0, Math.min(sw, pos.x)),
              y: Math.max(0, Math.min(sh, pos.y)),
            };
          },
        });
        handle.on("mouseenter", () => {
          container.style.cursor = "move";
        });
        handle.on("mouseleave", () => {
          applyContainerCursor();
        });
        handle.on("dragmove", () => {
          setLive(handle.x(), handle.y());
          rebuildDecorations();
          annotationsLayer.batchDraw();
        });
        handle.on("dragend", () => {
          const curW = stage.width();
          const curH = stage.height();
          if (curW === 0 || curH === 0) {
            return;
          }
          const newX1Pct = Math.max(0, Math.min(100, (live.x1 / curW) * 100));
          const newY1Pct = Math.max(0, Math.min(100, (live.y1 / curH) * 100));
          const newX2Pct = Math.max(0, Math.min(100, (live.x2 / curW) * 100));
          const newY2Pct = Math.max(0, Math.min(100, (live.y2 / curH) * 100));
          // Defensive: drop a sub-threshold drag so a barely-moved
          // endpoint doesn't normalize the arrow off-screen on save.
          // The modal-side onUpdate will also re-clamp, but this
          // keeps the local closure state coherent.
          const distance = Math.hypot(
            newX2Pct - newX1Pct,
            newY2Pct - newY1Pct
          );
          if (distance < MIN_ARROW_DRAG_PCT) {
            // Snap back to the previous valid geometry.
            live.x1 = (arrow.x1Pct / 100) * curW;
            live.y1 = (arrow.y1Pct / 100) * curH;
            live.x2 = (arrow.x2Pct / 100) * curW;
            live.y2 = (arrow.y2Pct / 100) * curH;
            handle.x(getX());
            handle.y(getY());
            rebuildDecorations();
            annotationsLayer.batchDraw();
            return;
          }
          onUpdate(arrow.id, newX1Pct, newY1Pct, newX2Pct, newY2Pct);
        });
        layer.add(handle);
      }
      // Tail handle (x1/y1).
      addHandle(
        () => live.x1,
        () => live.y1,
        (x, y) => {
          live.x1 = x;
          live.y1 = y;
        }
      );
      // Head handle (x2/y2).
      addHandle(
        () => live.x2,
        () => live.y2,
        (x, y) => {
          live.x2 = x;
          live.y2 = y;
        }
      );
    }
  }

  function renderDirectionArrows() {
    directionArrowLayer.destroyChildren();
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      annotationsLayer.batchDraw();
      return;
    }
    for (const arrow of state.directionArrows) {
      buildArrowGroup({
        arrow,
        sw,
        sh,
        layer: directionArrowLayer,
        isSelected: state.selectedDirectionArrowId === arrow.id,
        onClickSelect: (id) => onSelectDirectionArrow?.(id),
        onUpdate: (id, x1Pct, y1Pct, x2Pct, y2Pct) => {
          // Update closure state BEFORE notifying the modal so the
          // next sync sees identical values and skips a redundant
          // re-render (parallel to the eye-path handle dragend).
          state.directionArrows = state.directionArrows.map((a) =>
            a.id === id
              ? { ...a, x1Pct, y1Pct, x2Pct, y2Pct }
              : a
          );
          onUpdateDirectionArrow?.(id, x1Pct, y1Pct, x2Pct, y2Pct);
        },
        bothEnds: false,
        dashed: false,
        // Indigo — distinct from the eye-path cyan-blue so the two
        // direction/flow tools don't read as duplicates.
        tertiary: DIRECTION_ARROW_INDIGO,
        // Default weight + opacity — direction arrows are the
        // primary "this leads my eye" markers and should read
        // clearly without being loud.
        strokeWeight: 1,
        baseOpacity: 0.9,
      });
    }
    annotationsLayer.batchDraw();
  }

  function renderRelationshipArrows() {
    relationshipArrowLayer.destroyChildren();
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      annotationsLayer.batchDraw();
      return;
    }
    for (const arrow of state.relationshipArrows) {
      buildArrowGroup({
        arrow,
        sw,
        sh,
        layer: relationshipArrowLayer,
        isSelected: state.selectedRelationshipArrowId === arrow.id,
        onClickSelect: (id) => onSelectRelationshipArrow?.(id),
        onUpdate: (id, x1Pct, y1Pct, x2Pct, y2Pct) => {
          state.relationshipArrows = state.relationshipArrows.map((a) =>
            a.id === id
              ? { ...a, x1Pct, y1Pct, x2Pct, y2Pct }
              : a
          );
          onUpdateRelationshipArrow?.(id, x1Pct, y1Pct, x2Pct, y2Pct);
        },
        bothEnds: true,
        // Dashed stroke for relationship arrows — visually distinct
        // from direction arrows, reads as "soft connection" rather
        // than "measurement / hard pointer."
        dashed: true,
        // Warm taupe — distinct from both eye-path cyan-blue and the
        // direction-arrow indigo. Reads as a relational tie rather
        // than movement.
        tertiary: RELATIONSHIP_TAUPE,
        // Slightly thinner stroke (0.85×) and lower base opacity so
        // relationship arrows read quieter than direction arrows
        // (per the hierarchy spec — "readable but quieter than
        // Direction Arrow").
        strokeWeight: 0.85,
        baseOpacity: 0.8,
      });
    }
    annotationsLayer.batchDraw();
  }

  // Crop layer = 4 dim rects + bordered rect (+ Konva.Transformer
  // when the crop is selected in crop_suggestion mode). The bordered
  // rect is draggable for move; the transformer handles resize.
  // Both gestures clamp to image bounds.
  function renderCrop() {
    cropLayer.destroyChildren();
    cropRectRef = null;
    cropTransformerRef = null;
    dimRectsRef = null;
    cropDecorationsRef = null;

    const sw = stage.width();
    const sh = stage.height();

    if (!state.crop || sw === 0 || sh === 0) {
      annotationsLayer.batchDraw();
      return;
    }

    const cx = (state.crop.xPct / 100) * sw;
    const cy = (state.crop.yPct / 100) * sh;
    const cw = (state.crop.widthPct / 100) * sw;
    const ch = (state.crop.heightPct / 100) * sh;

    // Slightly less opaque than 0.5 so the area outside the crop
    // stays readable while still clearly de-emphasised. See
    // npn-critique-reply-colors.js.
    const dimFill = CROP_DIM_FILL;
    const dimTop = new Konva.Rect({
      x: 0,
      y: 0,
      width: sw,
      height: cy,
      fill: dimFill,
      listening: false,
    });
    const dimBottom = new Konva.Rect({
      x: 0,
      y: cy + ch,
      width: sw,
      height: Math.max(0, sh - cy - ch),
      fill: dimFill,
      listening: false,
    });
    const dimLeft = new Konva.Rect({
      x: 0,
      y: cy,
      width: cx,
      height: ch,
      fill: dimFill,
      listening: false,
    });
    const dimRight = new Konva.Rect({
      x: cx + cw,
      y: cy,
      width: Math.max(0, sw - cx - cw),
      height: ch,
      fill: dimFill,
      listening: false,
    });

    // Crop has its own blue-gray tone (CROP_EDITOR_BLUE_GRAY) that
    // sits between the eye-path cyan-blue and a neutral gray —
    // distinct enough from eye-path that the two don't trade
    // identity, blue enough that the crop still reads as an active
    // editable tool inside the workspace. The exported JPEG uses a
    // different (neutral gray) tone — see drawCropOnCanvas in
    // npn-critique-reply-visual-notes.js. Same dim opacity, lower
    // stroke prominence than pins.
    const tertiary = CROP_EDITOR_BLUE_GRAY;
    const secondary = ANNOTATION_HALO;
    const canEdit =
      state.visualMode === "crop_suggestion" && state.cropSelected;

    const cropRect = new Konva.Rect({
      x: cx,
      y: cy,
      width: cw,
      height: ch,
      // When selected we hide cropRect's own stroke and let the photo-
      // editor-style decoration group below carry the perimeter line,
      // corner brackets, and edge midpoint bars. When unselected we
      // keep the lighter dashed look as a "there's a crop here, click
      // to interact" affordance.
      strokeEnabled: !state.cropSelected,
      stroke: tertiary,
      strokeWidth: 2,
      dash: [6, 4],
      name: "crop-rect",
      // Mode-aware listening. The crop rect must pass clicks through
      // for any "click image to add something" mode, otherwise an
      // existing crop blocks placement of new annotations inside its
      // bounds. Modes that need pass-through: numbered_notes (click
      // to add pin), eye_path (click to add path point), attention_pull
      // / strong_area (drag-to-create on empty stage), and
      // direction_arrow / relationship_arrow (drag-to-create across
      // the image, may legitimately start inside the crop). The crop
      // rect is selectable on click only in modes that don't add
      // anything on click — i.e. when no tool is active, or in crop
      // mode itself.
      listening:
        state.visualMode !== "numbered_notes" &&
        state.visualMode !== "eye_path" &&
        state.visualMode !== "attention_pull" &&
        state.visualMode !== "strong_area" &&
        state.visualMode !== "direction_arrow" &&
        state.visualMode !== "relationship_arrow",
      // Draggable only when the crop is the active edit target.
      draggable: canEdit,
      // Clamp drag within image bounds. `this` inside dragBoundFunc
      // is the Konva node — read its own width/height so we don't
      // close over stale state.
      dragBoundFunc(pos) {
        const stageW = stage.width();
        const stageH = stage.height();
        const w = this.width() * this.scaleX();
        const h = this.height() * this.scaleY();
        return {
          x: Math.max(0, Math.min(stageW - w, pos.x)),
          y: Math.max(0, Math.min(stageH - h, pos.y)),
        };
      },
    });

    cropRect.on("click tap", (e) => {
      e.cancelBubble = true;
      onSelectCrop?.();
    });

    // Cursor cue — "move" while the rect is the active edit target
    // (draggable), "pointer" when only clickable. Matches the pin
    // and area-marker pattern. The transformer handles draw their
    // own resize cursors via Konva's built-in anchor styling.
    cropRect.on("mouseenter", () => {
      container.style.cursor = canEdit ? "move" : "pointer";
    });
    cropRect.on("mouseleave", () => {
      applyContainerCursor();
    });

    // Drag (move) handlers — dim rects follow the crop in real time
    // so the visual stays coherent. Final percentages emitted on end.
    cropRect.on("dragmove", () => updateDimDuringInteraction());
    cropRect.on("dragend", () => emitCropUpdate());

    // Transform (resize) handlers. Konva applies scaleX/scaleY during
    // transform; on end we bake the scale back into width/height so
    // the next interaction starts from scale 1.
    cropRect.on("transform", () => updateDimDuringInteraction());
    cropRect.on("transformend", () => {
      const sx = cropRect.scaleX();
      const sy = cropRect.scaleY();
      cropRect.scaleX(1);
      cropRect.scaleY(1);
      cropRect.width(Math.max(1, cropRect.width() * sx));
      cropRect.height(Math.max(1, cropRect.height() * sy));
      emitCropUpdate();
    });

    cropLayer.add(dimTop);
    cropLayer.add(dimBottom);
    cropLayer.add(dimLeft);
    cropLayer.add(dimRight);
    cropLayer.add(cropRect);

    // Perimeter-only hit zone for cross-mode crop selection.
    //
    // The cropRect above is mode-conditionally non-listening (see its
    // `listening` block) so a click anywhere INSIDE the crop area
    // passes through to the stage and adds the active tool's
    // annotation. That made the crop the only marker that couldn't
    // be picked up by clicking it from another tool's mode — pins,
    // attention pulls, and strong areas can all be selected at any
    // time because they're small enough that you can click them
    // intentionally, but the crop's bounded interior had to stay
    // pass-through so users could place annotations inside it.
    //
    // This hit zone is a closed polyline tracing the crop perimeter
    // with a fat invisible stroke. Hit-testable only on the BORDER
    // (not the fill) so clicking the visible dashed frame selects
    // the crop and switches to crop mode, while clicks well inside
    // the crop area still pass through to the stage. Active only in
    // the tool modes that disable cropRect's own listening; in crop
    // mode (or no mode) cropRect handles its own clicks so the hit
    // zone stays out of the way of drag/transform interactions.
    const inToolMode =
      state.visualMode === "numbered_notes" ||
      state.visualMode === "eye_path" ||
      state.visualMode === "attention_pull" ||
      state.visualMode === "strong_area" ||
      state.visualMode === "direction_arrow" ||
      state.visualMode === "relationship_arrow";
    if (inToolMode) {
      const hitStrokeWidth = Math.max(
        14,
        Math.round(Math.min(sw, sh) * 0.02)
      );
      const cropHitBorder = new Konva.Line({
        points: [cx, cy, cx + cw, cy, cx + cw, cy + ch, cx, cy + ch],
        closed: true,
        // Opacity 0 hides it visually; Konva still rasterises it to
        // the hit graph (the same pattern this file already uses for
        // the eye-path curve hit and the waypoint handles).
        stroke: "black",
        strokeWidth: hitStrokeWidth,
        // No fill, no fill hit — only the stroke contributes to hit
        // testing, so the interior of the rect stays pass-through.
        fillEnabled: false,
        opacity: 0,
        listening: true,
        lineCap: "round",
        lineJoin: "round",
        name: "crop-hit-border",
      });
      cropHitBorder.on("mouseenter", () => {
        container.style.cursor = "pointer";
      });
      cropHitBorder.on("mouseleave", () => {
        applyContainerCursor();
      });
      cropHitBorder.on("click tap", (e) => {
        // cancelBubble stops the stage-level click handler from also
        // firing — otherwise the click would BOTH select the crop
        // AND add a tool annotation at the click location.
        e.cancelBubble = true;
        onSelectCrop?.();
      });
      cropLayer.add(cropHitBorder);
    }

    if (canEdit) {
      const minW = (MIN_CROP_DRAG_PCT / 100) * sw;
      const minH = (MIN_CROP_DRAG_PCT / 100) * sh;
      const lockedRatio = ratioValueFor(state.aspectRatio);
      const isRatioLocked = lockedRatio != null;

      // Photo-editor-style decoration (perimeter + brackets + edge
      // bars). Built BEFORE the Transformer so the Transformer's
      // (invisible) anchors render on top and own the hit areas. Edge
      // bars are only drawn when free-ratio — see comment on
      // enabledAnchors below.
      buildCropDecorations(cx, cy, cw, ch, isRatioLocked);

      const transformer = new Konva.Transformer({
        nodes: [cropRect],
        rotateEnabled: false,
        // keepRatio on Konva.Transformer maintains the rect's CURRENT
        // aspect ratio during transform. Because renderCrop is called
        // after the ratio change re-snaps the rect to the target
        // ratio (see the aspectChanged handling in update()),
        // "current" is already correct by the time the transformer
        // mounts.
        keepRatio: isRatioLocked,
        // Edge anchors can only resize one axis, which would break
        // the ratio. Disable them when the ratio is locked; restore
        // all 8 when free. (Lightroom-style "drag edge → expand
        // perpendicular from centre" was attempted but Konva's
        // boundBoxFunc doesn't reliably apply perpendicular-axis
        // changes for edge anchors — left as a follow-up.)
        enabledAnchors: isRatioLocked
          ? ["top-left", "top-right", "bottom-left", "bottom-right"]
          : [
              "top-left",
              "top-center",
              "top-right",
              "middle-left",
              "middle-right",
              "bottom-left",
              "bottom-center",
              "bottom-right",
            ],
        // The decoration group renders its own perimeter — turn off
        // the transformer's border.
        borderEnabled: false,
        // Hide the default square anchors. The visible affordance is
        // the bracket/bar decoration; the Transformer's anchors still
        // own the hit areas, so we keep `anchorSize` large enough to
        // cover those visuals (~24px). Transparent fill/stroke keeps
        // the anchors hit-testable but invisible.
        anchorSize: 24,
        anchorStroke: "rgba(0,0,0,0)",
        anchorFill: "rgba(0,0,0,0)",
        anchorStrokeWidth: 0,
        boundBoxFunc(oldBox, newBox) {
          if (newBox.width < minW || newBox.height < minH) {
            return oldBox;
          }
          if (newBox.x < 0 || newBox.y < 0) {
            return oldBox;
          }
          if (
            newBox.x + newBox.width > sw ||
            newBox.y + newBox.height > sh
          ) {
            return oldBox;
          }
          return newBox;
        },
      });
      cropLayer.add(transformer);
      cropTransformerRef = transformer;
    }

    cropRectRef = cropRect;
    dimRectsRef = {
      top: dimTop,
      bottom: dimBottom,
      left: dimLeft,
      right: dimRight,
    };

    annotationsLayer.batchDraw();
  }

  // Live-resync the 4 dim rects to the crop rect's CURRENT pixel
  // position while the user is dragging or resizing. We mutate the
  // existing rect nodes rather than re-rendering the whole layer so
  // the drag gesture stays uninterrupted. The bracket / edge-bar
  // decoration group is rebuilt from the new bounding box on each
  // tick (cheaper than per-shape position mutation for this many
  // shapes, and renders cleanly).
  function updateDimDuringInteraction() {
    if (!cropRectRef || !dimRectsRef) {
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    const x = cropRectRef.x();
    const y = cropRectRef.y();
    const w = cropRectRef.width() * cropRectRef.scaleX();
    const h = cropRectRef.height() * cropRectRef.scaleY();

    dimRectsRef.top.position({ x: 0, y: 0 });
    dimRectsRef.top.size({ width: sw, height: Math.max(0, y) });

    dimRectsRef.bottom.position({ x: 0, y: y + h });
    dimRectsRef.bottom.size({
      width: sw,
      height: Math.max(0, sh - y - h),
    });

    dimRectsRef.left.position({ x: 0, y });
    dimRectsRef.left.size({
      width: Math.max(0, x),
      height: Math.max(0, h),
    });

    dimRectsRef.right.position({ x: x + w, y });
    dimRectsRef.right.size({
      width: Math.max(0, sw - x - w),
      height: Math.max(0, h),
    });

    // Re-sync the decoration group when it's mounted (selected crop).
    if (cropDecorationsRef) {
      const isRatioLocked = ratioValueFor(state.aspectRatio) != null;
      buildCropDecorations(x, y, w, h, isRatioLocked);
      // Keep the Transformer (invisible-anchor hit areas) on top so
      // its anchors continue to capture mouse events at the corners
      // and edges.
      cropTransformerRef?.moveToTop();
    }

    annotationsLayer.batchDraw();
  }

  // Build (or rebuild) the photo-editor-style crop decoration group:
  //   • 1px solid perimeter along all 4 edges
  //   • 4 L-shaped corner brackets, ~22px arms, 4px thick
  //   • 4 edge midpoint bars, ~28px × 4px (free-ratio mode only)
  //
  // Edge bars are HIDDEN when the aspect ratio is locked because
  // edge anchors are disabled in that mode (Konva's edge-resize +
  // keepRatio combination doesn't reliably produce a stable rect).
  // Showing a bar without behind-it functionality would mis-promise
  // an interaction.
  //
  // Editor-only — never reaches the exported JPEG. The export pipeline
  // (npn-critique-reply-visual-notes.js#drawCropOnCanvas) is a
  // completely separate code path that keeps the simpler stroked
  // rectangle look.
  function buildCropDecorations(x, y, w, h, isRatioLocked) {
    if (cropDecorationsRef) {
      cropDecorationsRef.destroy();
      cropDecorationsRef = null;
    }
    // Crop decoration uses the same editor blue-gray as the
    // perimeter (CROP_EDITOR_BLUE_GRAY) so the brackets/edge bars
    // read as part of the same active tool. Bracket arm length +
    // thickness are TUNED FOR LARGE STAGES (~30/8 px), where the
    // L-shaped brackets need to read solidly even on busy
    // photographs. On smaller laptop modals / narrow rendered
    // images, the same fixed sizes would cover too much of the
    // crop edge and make the crop hard to judge.
    //
    // We scale all decoration metrics against
    // min(stage.width, stage.height) — the smaller dimension drives
    // the perceived "tightness" of the handles relative to the
    // image, so it's the safer axis to drive sizing.
    //
    //   bracketArm / bracketThick / edgeBarLen / edgeBarThick:
    //     scaled per spec — clamp(base * factor, MIN, MAX).
    //   perimeterStroke:
    //     barely scales (1.5 → 2 px); the perimeter is supportive,
    //     not a primary handle.
    //
    // Hit-test geometry (the Transformer's invisible anchors at
    // size 24 set further up) is unchanged so touch/click usability
    // is preserved on every viewport.
    const stageColor = CROP_EDITOR_BLUE_GRAY;
    const clamp = (v, min, max) => Math.max(min, Math.min(max, v));
    const stageBase = Math.min(stage.width(), stage.height());
    const bracketArm = clamp(stageBase * 0.055, 14, 30);
    const bracketThick = clamp(stageBase * 0.014, 4, 8);
    const edgeBarLen = clamp(stageBase * 0.05, 12, 28);
    const edgeBarThick = clamp(stageBase * 0.014, 4, 8);
    const perimeterStroke = clamp(stageBase * 0.0035, 1.5, 2);
    // Drop midpoint bars on very narrow stages — even at their
    // minimum size they cover meaningful image edge when the stage
    // is small, and the corner brackets alone are enough to anchor
    // the crop visually. Free-ratio resize via the midpoints is
    // still available via the (invisible) Transformer anchors when
    // it's needed; the only thing missing is the on-screen affordance.
    const showMidpointBars = !isRatioLocked && stageBase >= 380;

    const group = new Konva.Group({ listening: false });

    // Perimeter connecting the brackets. Lightly scaled with the
    // stage (1.5 → 2 px) so the supporting line stays proportional
    // to the rest of the decoration; 0.7 opacity keeps it quieter
    // than the brackets but visible on busy photographs.
    group.add(
      new Konva.Rect({
        x,
        y,
        width: w,
        height: h,
        stroke: stageColor,
        strokeWidth: perimeterStroke,
        opacity: 0.7,
        listening: false,
      })
    );

    // 4 L-shaped corner brackets. Each is a 3-point Line: the elbow
    // sits ON the corner, the two arms reach `bracketArm` along the
    // adjacent edges inward.
    const bracket = (cornerX, cornerY, dx, dy) =>
      new Konva.Line({
        points: [
          cornerX + dx * bracketArm,
          cornerY,
          cornerX,
          cornerY,
          cornerX,
          cornerY + dy * bracketArm,
        ],
        stroke: stageColor,
        strokeWidth: bracketThick,
        listening: false,
        lineCap: "square",
        lineJoin: "miter",
      });
    group.add(bracket(x, y, 1, 1)); // top-left
    group.add(bracket(x + w, y, -1, 1)); // top-right
    group.add(bracket(x, y + h, 1, -1)); // bottom-left
    group.add(bracket(x + w, y + h, -1, -1)); // bottom-right

    // 4 edge midpoint bars — only when free-ratio AND the stage
    // has room to show them without overpowering the image. Hidden
    // in ratio-locked mode because edge anchors are disabled then
    // (showing the bar would promise an interaction the user can't
    // actually do) and hidden on very narrow stages even at the
    // smallest size (see `showMidpointBars` for the threshold).
    if (showMidpointBars) {
      // Top
      group.add(
        new Konva.Rect({
          x: x + w / 2 - edgeBarLen / 2,
          y: y - edgeBarThick / 2,
          width: edgeBarLen,
          height: edgeBarThick,
          fill: stageColor,
          listening: false,
        })
      );
      // Bottom
      group.add(
        new Konva.Rect({
          x: x + w / 2 - edgeBarLen / 2,
          y: y + h - edgeBarThick / 2,
          width: edgeBarLen,
          height: edgeBarThick,
          fill: stageColor,
          listening: false,
        })
      );
      // Left
      group.add(
        new Konva.Rect({
          x: x - edgeBarThick / 2,
          y: y + h / 2 - edgeBarLen / 2,
          width: edgeBarThick,
          height: edgeBarLen,
          fill: stageColor,
          listening: false,
        })
      );
      // Right
      group.add(
        new Konva.Rect({
          x: x + w - edgeBarThick / 2,
          y: y + h / 2 - edgeBarLen / 2,
          width: edgeBarThick,
          height: edgeBarLen,
          fill: stageColor,
          listening: false,
        })
      );
    }

    cropDecorationsRef = group;
    cropLayer.add(group);
    return group;
  }

  // Read the crop rect's pixel position back into percentages and
  // notify the modal. Closure state is updated first so the next
  // `update()` call sees these values as the current state (the
  // sameCrop comparison then skips a redundant re-render).
  function emitCropUpdate() {
    if (!cropRectRef) {
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      return;
    }
    const x = cropRectRef.x();
    const y = cropRectRef.y();
    const w = cropRectRef.width() * cropRectRef.scaleX();
    const h = cropRectRef.height() * cropRectRef.scaleY();

    const xPct = Math.max(0, Math.min(100, (x / sw) * 100));
    const yPct = Math.max(0, Math.min(100, (y / sh) * 100));
    const widthPct = Math.max(0, Math.min(100 - xPct, (w / sw) * 100));
    const heightPct = Math.max(
      0,
      Math.min(100 - yPct, (h / sh) * 100)
    );

    state.crop = {
      ...state.crop,
      xPct,
      yPct,
      widthPct,
      heightPct,
    };

    onUpdateCrop?.(xPct, yPct, widthPct, heightPct);
  }

  function clearPreview() {
    previewLayer.destroyChildren();
    previewLayer.batchDraw();
  }

  function renderPreview(x1, y1, x2, y2) {
    previewLayer.destroyChildren();
    // Drag-to-create preview colour follows the active tool so the
    // in-flight shape reads as a draft of the kind being placed.
    let tertiary = ANNOTATION_BLUE;
    if (state.visualMode === "attention_pull") {
      tertiary = ATTENTION_PULL_OCHRE;
    } else if (state.visualMode === "strong_area") {
      tertiary = STRONG_AREA_SAGE;
    }
    const rx = Math.min(x1, x2);
    const ry = Math.min(y1, y2);
    const rw = Math.abs(x2 - x1);
    const rh = Math.abs(y2 - y1);

    // Attention / Strong Area finalize as ellipses, so the preview
    // also draws an ellipse — previously the rect preview gave
    // users a "drew a rectangle, got an oval" surprise on release.
    // Crop_suggestion stays as a rectangle (final crop IS a rect).
    const isAreaTool =
      state.visualMode === "attention_pull" ||
      state.visualMode === "strong_area";

    if (isAreaTool) {
      previewLayer.add(
        new Konva.Ellipse({
          x: rx + rw / 2,
          y: ry + rh / 2,
          radiusX: Math.max(0, rw / 2),
          radiusY: Math.max(0, rh / 2),
          stroke: tertiary,
          strokeWidth: 2,
          dash: [4, 3],
          fill: "rgba(0, 0, 0, 0.12)",
          listening: false,
        })
      );
    } else {
      previewLayer.add(
        new Konva.Rect({
          x: rx,
          y: ry,
          width: rw,
          height: rh,
          stroke: tertiary,
          strokeWidth: 2,
          dash: [4, 3],
          fill: "rgba(0, 0, 0, 0.15)",
          listening: false,
        })
      );
    }
    previewLayer.batchDraw();
  }

  // Area-path drag helpers. Sampling + preview render + commit
  // share the same pattern as eye_path; the differences are: (1)
  // the in-flight line is CLOSED for visual feedback (looks like
  // the final shape during the drag), (2) Douglas-Peucker tolerance
  // is tighter so the closed corners survive simplification, and
  // (3) the bounding-box minimum-size gate filters accidental taps.
  function sampleAreaPathPoint(drag, pos) {
    const dx = pos.x - drag.lastSampleX;
    const dy = pos.y - drag.lastSampleY;
    const dist = Math.sqrt(dx * dx + dy * dy);
    if (
      dist >= AREA_PATH_SAMPLE_MIN_PX &&
      drag.points.length < MAX_AREA_PATH_POINTS_RAW
    ) {
      drag.points.push({ x: pos.x, y: pos.y });
      drag.lastSampleX = pos.x;
      drag.lastSampleY = pos.y;
    }
  }

  function renderAreaPathPreview(sampledPoints, liveX, liveY, tertiary) {
    previewLayer.destroyChildren();
    if (!sampledPoints || sampledPoints.length === 0) {
      previewLayer.batchDraw();
      return;
    }
    const flat = [];
    for (const p of sampledPoints) {
      flat.push(p.x, p.y);
    }
    flat.push(liveX, liveY);
    // Closed: true so the user sees the final-shape footprint
    // forming under the cursor — including the auto-close segment
    // from the live pointer back to the start.
    previewLayer.add(
      new Konva.Line({
        points: flat,
        closed: true,
        stroke: tertiary,
        strokeWidth: 2.5,
        dash: [5, 4],
        fill: "rgba(0, 0, 0, 0.10)",
        tension: 0.35,
        listening: false,
      })
    );
    previewLayer.batchDraw();
  }

  function finishAreaPathDrag(drag, pos, sw, sh, commit) {
    if (!pos || sw === 0 || sh === 0 || !commit) {
      return;
    }
    const dx = pos.x - drag.startX;
    const dy = pos.y - drag.startY;
    const totalDist = Math.sqrt(dx * dx + dy * dy);
    // Accidental tap or too-tiny scribble — drop the drag, do
    // nothing. We deliberately do NOT fall back to a rect-shape
    // commit (the user explicitly chose Draw Area).
    if (
      totalDist < AREA_PATH_DRAG_THRESHOLD_PX ||
      drag.points.length < 3
    ) {
      return;
    }
    // Capture the final pointer position so the path actually
    // closes at the user's release point, not at the last sample.
    const lastSample = drag.points[drag.points.length - 1];
    if (Math.hypot(pos.x - lastSample.x, pos.y - lastSample.y) > 1) {
      drag.points.push({ x: pos.x, y: pos.y });
    }
    // Douglas-Peucker (reused from eye_path) — tighter tolerance
    // so the corner samples survive. The hard cap then
    // walk-and-drops alternates if the result is still too dense.
    const stageMin = Math.min(sw, sh);
    const tolerance = stageMin * AREA_PATH_SIMPLIFY_TOLERANCE_PCT;
    let simplified = douglasPeucker(drag.points, tolerance);
    if (simplified.length > AREA_PATH_HARD_CAP) {
      while (simplified.length > AREA_PATH_HARD_CAP) {
        const out = [simplified[0]];
        for (let i = 1; i < simplified.length - 1; i += 2) {
          out.push(simplified[i]);
        }
        out.push(simplified[simplified.length - 1]);
        simplified = out;
      }
    }
    if (simplified.length < 4) {
      return;
    }
    // Bounding-box check against percent threshold — matches what
    // the server normalizer enforces.
    const xs = simplified.map((p) => p.x);
    const ys = simplified.map((p) => p.y);
    const widthPct = ((Math.max(...xs) - Math.min(...xs)) / sw) * 100;
    const heightPct = ((Math.max(...ys) - Math.min(...ys)) / sh) * 100;
    if (widthPct < 3 && heightPct < 3) {
      return;
    }
    const asPct = simplified.map((p) => ({
      xPct: Math.max(0, Math.min(100, (p.x / sw) * 100)),
      yPct: Math.max(0, Math.min(100, (p.y / sh) * 100)),
    }));
    commit(asPct);
  }

  // Drag-to-trace Eye Path preview. Renders the accumulated sampled
  // points PLUS the current live pointer position as a Konva.Line
  // with the same tension the finished path uses, so the in-flight
  // shape matches what the user will see on release. Colour matches
  // EYE_PATH_PALE_CYAN. Skipping the dashed treatment (other
  // drag-previews use dashes) because the user is literally drawing
  // and a solid in-flight line reads more like a pencil.
  function renderEyePathPreview(sampledPoints, liveX, liveY) {
    previewLayer.destroyChildren();
    if (!sampledPoints || sampledPoints.length === 0) {
      previewLayer.batchDraw();
      return;
    }
    const flat = [];
    for (const p of sampledPoints) {
      flat.push(p.x, p.y);
    }
    flat.push(liveX, liveY);
    previewLayer.add(
      new Konva.Line({
        points: flat,
        stroke: EYE_PATH_PALE_CYAN,
        strokeWidth: 3,
        lineCap: "round",
        lineJoin: "round",
        tension: EYE_PATH_SMOOTH ? EYE_PATH_SMOOTH_TENSION : 0,
        listening: false,
      })
    );
    previewLayer.batchDraw();
  }

  // Arrow-shape drag preview — a dashed line with a tip mark. Used
  // for both direction_arrow and relationship_arrow during the
  // mousedown→mouseup drag; the rect-shaped preview above wouldn't
  // make sense for an arrow. Caller passes the per-kind colour so
  // the in-flight preview matches the colour the finished marker
  // will end up.
  function renderArrowPreview(
    x1,
    y1,
    x2,
    y2,
    { dashed = false, tertiary = ANNOTATION_BLUE } = {}
  ) {
    previewLayer.destroyChildren();
    previewLayer.add(
      new Konva.Line({
        points: [x1, y1, x2, y2],
        stroke: tertiary,
        strokeWidth: 2,
        dash: dashed ? [6, 4] : [4, 3],
        listening: false,
        lineCap: "round",
      })
    );
    previewLayer.batchDraw();
  }

  // Click / tap on empty area handler.
  //   • numbered_notes → add pin
  //   • crop_suggestion → no-op on click (handled by drag below)
  //   • eye_path → handled by mousedown/move/up below (drag-to-trace).
  //                A tap that doesn't cross EYE_PATH_DRAG_THRESHOLD_PX
  //                falls through to single-point behaviour inside the
  //                mouseup handler — we deliberately don't double-fire
  //                via this click event.
  //   • null → no-op (canvas is read-only)
  stage.on("click tap", (e) => {
    if (e.target !== stage) {
      return;
    }
    if (state.visualMode === "numbered_notes") {
      const pos = stage.getPointerPosition();
      if (!pos) {
        return;
      }
      const sw = stage.width();
      const sh = stage.height();
      if (sw === 0 || sh === 0) {
        return;
      }
      const xPct = Math.max(0, Math.min(100, (pos.x / sw) * 100));
      const yPct = Math.max(0, Math.min(100, (pos.y / sh) * 100));
      onAddPin?.(xPct, yPct);
    }
  });

  // Drag-to-crop. Only active in crop_suggestion mode AND when no crop
  // exists yet (the modal exposes "Clear crop" → "draw a new one"; we
  // don't allow drawing over an existing crop here).
  stage.on("mousedown touchstart", (e) => {
    if (e.target !== stage) {
      return;
    }
    const pos = stage.getPointerPosition();
    if (!pos) {
      return;
    }
    if (state.visualMode === "crop_suggestion" && !state.crop) {
      cropDrag = { startX: pos.x, startY: pos.y };
      return;
    }
    if (state.visualMode === "attention_pull") {
      // Retrace overrides the regular area-shape branch — drawing
      // over an existing path-shape marker replaces its points
      // regardless of the current areaShapeMode setting.
      if (state.retracingAttentionPullId) {
        attentionPathDrag = {
          startX: pos.x,
          startY: pos.y,
          points: [{ x: pos.x, y: pos.y }],
          lastSampleX: pos.x,
          lastSampleY: pos.y,
          retraceId: state.retracingAttentionPullId,
        };
      } else if (state.areaShapeMode === "path") {
        attentionPathDrag = {
          startX: pos.x,
          startY: pos.y,
          points: [{ x: pos.x, y: pos.y }],
          lastSampleX: pos.x,
          lastSampleY: pos.y,
        };
      } else {
        attentionDrag = { startX: pos.x, startY: pos.y };
      }
      return;
    }
    if (state.visualMode === "strong_area") {
      if (state.retracingStrongAreaId) {
        strongPathDrag = {
          startX: pos.x,
          startY: pos.y,
          points: [{ x: pos.x, y: pos.y }],
          lastSampleX: pos.x,
          lastSampleY: pos.y,
          retraceId: state.retracingStrongAreaId,
        };
      } else if (state.areaShapeMode === "path") {
        strongPathDrag = {
          startX: pos.x,
          startY: pos.y,
          points: [{ x: pos.x, y: pos.y }],
          lastSampleX: pos.x,
          lastSampleY: pos.y,
        };
      } else {
        strongDrag = { startX: pos.x, startY: pos.y };
      }
      return;
    }
    if (state.visualMode === "direction_arrow") {
      directionArrowDrag = { startX: pos.x, startY: pos.y };
      return;
    }
    if (state.visualMode === "relationship_arrow") {
      relationshipArrowDrag = { startX: pos.x, startY: pos.y };
      return;
    }
    if (state.visualMode === "eye_path") {
      eyePathDrag = {
        startX: pos.x,
        startY: pos.y,
        // Sampled pixel-space points. The first sample is the
        // pointer-down position. Subsequent samples are added in
        // the mousemove handler when the pointer travels more
        // than EYE_PATH_SAMPLE_MIN_PX from the previous sample.
        points: [{ x: pos.x, y: pos.y }],
        lastSampleX: pos.x,
        lastSampleY: pos.y,
      };
      return;
    }
  });

  stage.on("mousemove touchmove", () => {
    const pos = stage.getPointerPosition();
    if (!pos) {
      return;
    }
    if (cropDrag) {
      const ratioValue = ratioValueFor(state.aspectRatio);
      const { endX, endY } = constrainDragToRatio(
        cropDrag.startX,
        cropDrag.startY,
        pos.x,
        pos.y,
        ratioValue
      );
      renderPreview(cropDrag.startX, cropDrag.startY, endX, endY);
      return;
    }
    if (attentionDrag) {
      renderPreview(attentionDrag.startX, attentionDrag.startY, pos.x, pos.y);
      return;
    }
    if (strongDrag) {
      renderPreview(strongDrag.startX, strongDrag.startY, pos.x, pos.y);
      return;
    }
    if (directionArrowDrag) {
      renderArrowPreview(
        directionArrowDrag.startX,
        directionArrowDrag.startY,
        pos.x,
        pos.y,
        { dashed: false, tertiary: DIRECTION_ARROW_INDIGO }
      );
      return;
    }
    if (relationshipArrowDrag) {
      renderArrowPreview(
        relationshipArrowDrag.startX,
        relationshipArrowDrag.startY,
        pos.x,
        pos.y,
        { dashed: true, tertiary: RELATIONSHIP_TAUPE }
      );
      return;
    }
    if (attentionPathDrag) {
      sampleAreaPathPoint(attentionPathDrag, pos);
      renderAreaPathPreview(
        attentionPathDrag.points,
        pos.x,
        pos.y,
        ATTENTION_PULL_OCHRE
      );
      return;
    }
    if (strongPathDrag) {
      sampleAreaPathPoint(strongPathDrag, pos);
      renderAreaPathPreview(
        strongPathDrag.points,
        pos.x,
        pos.y,
        STRONG_AREA_SAGE
      );
      return;
    }
    if (eyePathDrag) {
      const dx = pos.x - eyePathDrag.lastSampleX;
      const dy = pos.y - eyePathDrag.lastSampleY;
      const dist = Math.sqrt(dx * dx + dy * dy);
      // Sample-by-distance: drop tiny moves so the path doesn't
      // burn its 40-point cap on pen tremor at the start of a
      // drag. Also enforce the upper cap defensively here even
      // though the modal action also truncates.
      if (
        dist >= EYE_PATH_SAMPLE_MIN_PX &&
        eyePathDrag.points.length < 40
      ) {
        eyePathDrag.points.push({ x: pos.x, y: pos.y });
        eyePathDrag.lastSampleX = pos.x;
        eyePathDrag.lastSampleY = pos.y;
      }
      // Always redraw the preview against the live pointer
      // position so the line "draws" smoothly under the cursor
      // even between sample points.
      renderEyePathPreview(eyePathDrag.points, pos.x, pos.y);
    }
  });

  stage.on("mouseup touchend", () => {
    const pos = stage.getPointerPosition();
    const sw = stage.width();
    const sh = stage.height();

    if (cropDrag) {
      const start = cropDrag;
      cropDrag = null;
      clearPreview();
      if (!pos || sw === 0 || sh === 0) {
        return;
      }
      const ratioValue = ratioValueFor(state.aspectRatio);
      const { endX, endY } = constrainDragToRatio(
        start.startX,
        start.startY,
        pos.x,
        pos.y,
        ratioValue
      );
      const x1 = Math.min(start.startX, endX);
      const y1 = Math.min(start.startY, endY);
      const x2 = Math.max(start.startX, endX);
      const y2 = Math.max(start.startY, endY);
      const xPct = Math.max(0, Math.min(100, (x1 / sw) * 100));
      const yPct = Math.max(0, Math.min(100, (y1 / sh) * 100));
      const widthPct = Math.max(
        0,
        Math.min(100 - xPct, ((x2 - x1) / sw) * 100)
      );
      const heightPct = Math.max(
        0,
        Math.min(100 - yPct, ((y2 - y1) / sh) * 100)
      );
      if (
        widthPct < MIN_CROP_DRAG_PCT ||
        heightPct < MIN_CROP_DRAG_PCT
      ) {
        return;
      }
      onAddCrop?.(xPct, yPct, widthPct, heightPct);
      return;
    }

    if (attentionDrag) {
      const start = attentionDrag;
      attentionDrag = null;
      clearPreview();
      if (!pos || sw === 0 || sh === 0) {
        return;
      }
      const x1 = Math.min(start.startX, pos.x);
      const y1 = Math.min(start.startY, pos.y);
      const x2 = Math.max(start.startX, pos.x);
      const y2 = Math.max(start.startY, pos.y);
      const xPct = Math.max(0, Math.min(100, (x1 / sw) * 100));
      const yPct = Math.max(0, Math.min(100, (y1 / sh) * 100));
      const widthPct = Math.max(
        0,
        Math.min(100 - xPct, ((x2 - x1) / sw) * 100)
      );
      const heightPct = Math.max(
        0,
        Math.min(100 - yPct, ((y2 - y1) / sh) * 100)
      );
      // Discard tiny drags (mirrors MIN_ATTENTION_PULL_DIMENSION_PCT).
      if (
        widthPct < MIN_ATTENTION_PULL_DRAG_PCT ||
        heightPct < MIN_ATTENTION_PULL_DRAG_PCT
      ) {
        return;
      }
      onAddAttentionPull?.(xPct, yPct, widthPct, heightPct);
      return;
    }

    if (strongDrag) {
      const start = strongDrag;
      strongDrag = null;
      clearPreview();
      if (!pos || sw === 0 || sh === 0) {
        return;
      }
      const x1 = Math.min(start.startX, pos.x);
      const y1 = Math.min(start.startY, pos.y);
      const x2 = Math.max(start.startX, pos.x);
      const y2 = Math.max(start.startY, pos.y);
      const xPct = Math.max(0, Math.min(100, (x1 / sw) * 100));
      const yPct = Math.max(0, Math.min(100, (y1 / sh) * 100));
      const widthPct = Math.max(
        0,
        Math.min(100 - xPct, ((x2 - x1) / sw) * 100)
      );
      const heightPct = Math.max(
        0,
        Math.min(100 - yPct, ((y2 - y1) / sh) * 100)
      );
      if (
        widthPct < MIN_STRONG_AREA_DRAG_PCT ||
        heightPct < MIN_STRONG_AREA_DRAG_PCT
      ) {
        return;
      }
      onAddStrongArea?.(xPct, yPct, widthPct, heightPct);
      return;
    }

    if (directionArrowDrag) {
      const start = directionArrowDrag;
      directionArrowDrag = null;
      clearPreview();
      if (!pos || sw === 0 || sh === 0) {
        return;
      }
      // Arrows preserve direction — tail is mousedown, head is
      // mouseup (no min/max sorting). Clamp endpoints to stage and
      // drop the drag if the resulting length is below threshold.
      const x1Pct = Math.max(0, Math.min(100, (start.startX / sw) * 100));
      const y1Pct = Math.max(0, Math.min(100, (start.startY / sh) * 100));
      const x2Pct = Math.max(0, Math.min(100, (pos.x / sw) * 100));
      const y2Pct = Math.max(0, Math.min(100, (pos.y / sh) * 100));
      const distance = Math.hypot(x2Pct - x1Pct, y2Pct - y1Pct);
      if (distance < MIN_ARROW_DRAG_PCT) {
        return;
      }
      onAddDirectionArrow?.(x1Pct, y1Pct, x2Pct, y2Pct);
      return;
    }

    if (relationshipArrowDrag) {
      const start = relationshipArrowDrag;
      relationshipArrowDrag = null;
      clearPreview();
      if (!pos || sw === 0 || sh === 0) {
        return;
      }
      const x1Pct = Math.max(0, Math.min(100, (start.startX / sw) * 100));
      const y1Pct = Math.max(0, Math.min(100, (start.startY / sh) * 100));
      const x2Pct = Math.max(0, Math.min(100, (pos.x / sw) * 100));
      const y2Pct = Math.max(0, Math.min(100, (pos.y / sh) * 100));
      const distance = Math.hypot(x2Pct - x1Pct, y2Pct - y1Pct);
      if (distance < MIN_ARROW_DRAG_PCT) {
        return;
      }
      onAddRelationshipArrow?.(x1Pct, y1Pct, x2Pct, y2Pct);
      return;
    }

    if (attentionPathDrag) {
      const drag = attentionPathDrag;
      attentionPathDrag = null;
      clearPreview();
      if (drag.retraceId) {
        const targetId = drag.retraceId;
        finishAreaPathDrag(drag, pos, sw, sh, (points) =>
          onRetraceAttentionPullPath?.(targetId, points)
        );
      } else {
        finishAreaPathDrag(drag, pos, sw, sh, onAddAttentionPullPath);
      }
      return;
    }
    if (strongPathDrag) {
      const drag = strongPathDrag;
      strongPathDrag = null;
      clearPreview();
      if (drag.retraceId) {
        const targetId = drag.retraceId;
        finishAreaPathDrag(drag, pos, sw, sh, (points) =>
          onRetraceStrongAreaPath?.(targetId, points)
        );
      } else {
        finishAreaPathDrag(drag, pos, sw, sh, onAddStrongAreaPath);
      }
      return;
    }

    if (eyePathDrag) {
      const drag = eyePathDrag;
      eyePathDrag = null;
      clearPreview();
      if (!pos || sw === 0 || sh === 0) {
        return;
      }
      const dx = pos.x - drag.startX;
      const dy = pos.y - drag.startY;
      const totalDist = Math.sqrt(dx * dx + dy * dy);
      const isShortPress =
        totalDist < EYE_PATH_DRAG_THRESHOLD_PX || drag.points.length < 2;
      // Mode-gated dispatch. In Points mode a short press becomes
      // a click-to-add stop; a longer drag is discarded (the user
      // intended Stroke if they wanted that). In Stroke mode a
      // longer drag commits as a stroke; a short press is ignored
      // so taps near the canvas don't drop accidental stops.
      if (state.eyePathInteractionMode === "points") {
        if (isShortPress) {
          const xPct = Math.max(0, Math.min(100, (drag.startX / sw) * 100));
          const yPct = Math.max(0, Math.min(100, (drag.startY / sh) * 100));
          onAddEyePathPoint?.(xPct, yPct);
        }
        return;
      }
      // Stroke mode: drop short presses; only commit longer drags.
      if (isShortPress) {
        return;
      }
      // Make sure the very last pointer position is captured so
      // the path ends exactly where the user released, not at the
      // last sampled point.
      const lastSample = drag.points[drag.points.length - 1];
      if (
        Math.hypot(pos.x - lastSample.x, pos.y - lastSample.y) > 1
      ) {
        drag.points.push({ x: pos.x, y: pos.y });
      }
      // Run Douglas-Peucker simplification BEFORE converting to
      // percent. Working in pixel space keeps the tolerance
      // meaningful (it represents on-screen distance). After
      // simplification, the path typically lands on 4-8 well-
      // placed control points — sparse enough to be dragged
      // individually after the fact, smooth enough to look like
      // a flowing curve thanks to the Konva line tension.
      const stageMin = Math.min(sw, sh);
      const tolerance = stageMin * EYE_PATH_SIMPLIFY_TOLERANCE_PCT;
      let simplified = douglasPeucker(drag.points, tolerance);
      if (simplified.length > EYE_PATH_SIMPLIFY_HARD_CAP) {
        // Pathological inputs (zig-zags) can still exceed the
        // hard cap. Walk-and-drop alternating intermediate
        // points until we fit, always keeping endpoints.
        while (simplified.length > EYE_PATH_SIMPLIFY_HARD_CAP) {
          const out = [simplified[0]];
          for (let i = 1; i < simplified.length - 1; i += 2) {
            out.push(simplified[i]);
          }
          out.push(simplified[simplified.length - 1]);
          simplified = out;
        }
      }
      const asPct = simplified.map((p) => ({
        xPct: Math.max(0, Math.min(100, (p.x / sw) * 100)),
        yPct: Math.max(0, Math.min(100, (p.y / sh) * 100)),
      }));
      onCommitEyePath?.(asPct);
    }
  });

  // ResizeObserver tracks image AND frame size changes (window resize,
  // modal width change, theme switch, dev tools open/close, etc.).
  // We observe the frame too because a frame resize can change the
  // image's centered offset without changing its clientWidth/Height —
  // syncStageSize repositions the container to follow the image, and
  // the annotation percentages are recomputed against the new stage
  // pixels on re-render.
  const resizeObserver = new ResizeObserver(() => {
    const sizeChanged = syncStageSize();
    if (sizeChanged) {
      renderCrop();
      renderAttentionPulls();
      renderStrongAreas();
      renderEyePaths();
      renderDirectionArrows();
      renderRelationshipArrows();
      renderPins();
    }
  });
  resizeObserver.observe(imageElement);
  const frameElement = container.parentElement;
  if (frameElement) {
    resizeObserver.observe(frameElement);
  }

  // Initial container alignment to the image's rendered position.
  // The stage was created with image-sized dimensions, so this is
  // really about applying the offset CSS — the canvas needs to sit
  // over the image, not the frame's top-left.
  syncStageSize();

  applyContainerCursor();
  renderCrop();
  renderAttentionPulls();
  renderStrongAreas();
  renderEyePaths();
  renderDirectionArrows();
  renderRelationshipArrows();
  renderPins();

  return {
    /**
     * Push new state into the stage. Idempotent — comparing fields to
     * the closure-held state lets repeated calls with identical args
     * skip work.
     */
    update({
      pins,
      crop,
      eyePaths,
      attentionPulls,
      strongAreas,
      directionArrows,
      relationshipArrows,
      selectedPinNumber,
      cropSelected,
      selectedEyePathId,
      selectedAttentionPullId,
      selectedStrongAreaId,
      selectedDirectionArrowId,
      selectedRelationshipArrowId,
      visualMode,
      aspectRatio,
      pinMoveEnabled,
      attentionPullEditEnabled,
      strongAreaEditEnabled,
      areaShapeMode,
      eyePathInteractionMode,
      retracingAttentionPullId,
      retracingStrongAreaId,
    } = {}) {
      let pinsChanged = false;
      let cropChanged = false;
      let eyePathChanged = false;
      let attentionPullsChanged = false;
      let strongAreasChanged = false;
      let directionArrowsChanged = false;
      let relationshipArrowsChanged = false;

      if (pins !== undefined && !samePins(pins, state.pins)) {
        state.pins = [...pins];
        pinsChanged = true;
      }
      if (
        selectedPinNumber !== undefined &&
        selectedPinNumber !== state.selectedPinNumber
      ) {
        state.selectedPinNumber = selectedPinNumber;
        pinsChanged = true;
      }
      if (
        pinMoveEnabled !== undefined &&
        pinMoveEnabled !== state.pinMoveEnabled
      ) {
        state.pinMoveEnabled = pinMoveEnabled;
        // Re-render so the selected pin's `draggable` attribute
        // tracks the new flag.
        pinsChanged = true;
      }
      if (crop !== undefined && !sameCrop(crop, state.crop)) {
        state.crop = crop ? { ...crop } : null;
        cropChanged = true;
      }
      if (
        cropSelected !== undefined &&
        cropSelected !== state.cropSelected
      ) {
        state.cropSelected = cropSelected;
        cropChanged = true;
      }
      if (eyePaths !== undefined && !sameEyePaths(eyePaths, state.eyePaths)) {
        state.eyePaths = cloneEyePaths(eyePaths);
        eyePathChanged = true;
      }
      if (
        selectedEyePathId !== undefined &&
        selectedEyePathId !== state.selectedEyePathId
      ) {
        state.selectedEyePathId = selectedEyePathId;
        eyePathChanged = true;
      }
      if (
        attentionPulls !== undefined &&
        !sameAttentionPulls(attentionPulls, state.attentionPulls)
      ) {
        state.attentionPulls = cloneAttentionPulls(attentionPulls);
        attentionPullsChanged = true;
      }
      if (
        selectedAttentionPullId !== undefined &&
        selectedAttentionPullId !== state.selectedAttentionPullId
      ) {
        state.selectedAttentionPullId = selectedAttentionPullId;
        attentionPullsChanged = true;
      }
      if (
        attentionPullEditEnabled !== undefined &&
        attentionPullEditEnabled !== state.attentionPullEditEnabled
      ) {
        state.attentionPullEditEnabled = attentionPullEditEnabled;
        // Re-render so the selected pull's transformer mounts /
        // unmounts in step with the flag.
        attentionPullsChanged = true;
      }
      if (
        strongAreas !== undefined &&
        !sameStrongAreas(strongAreas, state.strongAreas)
      ) {
        state.strongAreas = cloneStrongAreas(strongAreas);
        strongAreasChanged = true;
      }
      if (
        selectedStrongAreaId !== undefined &&
        selectedStrongAreaId !== state.selectedStrongAreaId
      ) {
        state.selectedStrongAreaId = selectedStrongAreaId;
        strongAreasChanged = true;
      }
      if (
        strongAreaEditEnabled !== undefined &&
        strongAreaEditEnabled !== state.strongAreaEditEnabled
      ) {
        state.strongAreaEditEnabled = strongAreaEditEnabled;
        strongAreasChanged = true;
      }
      if (
        areaShapeMode !== undefined &&
        areaShapeMode !== state.areaShapeMode
      ) {
        state.areaShapeMode = areaShapeMode;
        // A mid-drag sub-mode swap shouldn't leave a stale shape on
        // the preview layer.
        if (attentionDrag || strongDrag || attentionPathDrag || strongPathDrag) {
          attentionDrag = null;
          strongDrag = null;
          attentionPathDrag = null;
          strongPathDrag = null;
          clearPreview();
        }
      }
      if (
        eyePathInteractionMode !== undefined &&
        eyePathInteractionMode !== state.eyePathInteractionMode
      ) {
        state.eyePathInteractionMode = eyePathInteractionMode;
        // Cancel any in-flight eye-path drag so the user doesn't
        // accidentally commit a stroke after switching to points
        // mid-press.
        if (eyePathDrag) {
          eyePathDrag = null;
          clearPreview();
        }
      }
      if (
        retracingAttentionPullId !== undefined &&
        retracingAttentionPullId !== state.retracingAttentionPullId
      ) {
        state.retracingAttentionPullId = retracingAttentionPullId;
        // Re-render so the retrace target's fillBody becomes
        // non-listening (or listening again when retrace is cancelled).
        attentionPullsChanged = true;
        // If a path drag is in flight for a different target (or for
        // a new-shape draw), cancel it so the user doesn't accidentally
        // commit one operation when the toolbar context says another.
        if (attentionPathDrag) {
          attentionPathDrag = null;
          clearPreview();
        }
      }
      if (
        retracingStrongAreaId !== undefined &&
        retracingStrongAreaId !== state.retracingStrongAreaId
      ) {
        state.retracingStrongAreaId = retracingStrongAreaId;
        strongAreasChanged = true;
        if (strongPathDrag) {
          strongPathDrag = null;
          clearPreview();
        }
      }
      if (
        directionArrows !== undefined &&
        !sameArrows(directionArrows, state.directionArrows)
      ) {
        state.directionArrows = cloneArrows(directionArrows);
        directionArrowsChanged = true;
      }
      if (
        selectedDirectionArrowId !== undefined &&
        selectedDirectionArrowId !== state.selectedDirectionArrowId
      ) {
        state.selectedDirectionArrowId = selectedDirectionArrowId;
        directionArrowsChanged = true;
      }
      if (
        relationshipArrows !== undefined &&
        !sameArrows(relationshipArrows, state.relationshipArrows)
      ) {
        state.relationshipArrows = cloneArrows(relationshipArrows);
        relationshipArrowsChanged = true;
      }
      if (
        selectedRelationshipArrowId !== undefined &&
        selectedRelationshipArrowId !== state.selectedRelationshipArrowId
      ) {
        state.selectedRelationshipArrowId = selectedRelationshipArrowId;
        relationshipArrowsChanged = true;
      }
      if (visualMode !== undefined && visualMode !== state.visualMode) {
        state.visualMode = visualMode;
        applyContainerCursor();
        // Mode change can cancel an in-flight drag.
        if (cropDrag) {
          cropDrag = null;
          clearPreview();
        }
        if (attentionDrag) {
          attentionDrag = null;
          clearPreview();
        }
        if (strongDrag) {
          strongDrag = null;
          clearPreview();
        }
        if (directionArrowDrag) {
          directionArrowDrag = null;
          clearPreview();
        }
        if (relationshipArrowDrag) {
          relationshipArrowDrag = null;
          clearPreview();
        }
        // The selected attention pull's transformer is mode-gated, so
        // crossing the attention_pull boundary in either direction
        // requires a re-render to mount/unmount it.
        if (state.selectedAttentionPullId) {
          attentionPullsChanged = true;
        }
        if (state.selectedStrongAreaId) {
          strongAreasChanged = true;
        }
        // The crop rect's `listening` attribute depends on the active
        // mode (see renderCrop). When a crop exists and we cross the
        // numbered-notes boundary in either direction, the existing
        // shape's listening flag is stale — re-render so the new
        // attribute takes effect.
        if (state.crop) {
          cropChanged = true;
        }
        // Existing eye paths' hit-line + waypoint handles flip their
        // listening attribute based on whether the user is in eye_path
        // creation mode. Mark them stale on every mode crossing so the
        // next render picks up the right listen/draggable state.
        if (Array.isArray(state.eyePaths) && state.eyePaths.length > 0) {
          eyePathChanged = true;
        }
      }

      if (
        aspectRatio !== undefined &&
        aspectRatio !== state.aspectRatio
      ) {
        const prevAspectRatio = state.aspectRatio;
        state.aspectRatio = aspectRatio;
        const newRatio = ratioValueFor(state.aspectRatio);
        if (typeof window !== "undefined" && window.console) {
          // Always log this transition during development — it's
          // cheap, fires only on user-driven ratio changes, and lets
          // us verify the recompute branch was taken.
          // eslint-disable-next-line no-console
          console.debug("[npn-critique-reply] aspect-ratio change", {
            from: prevAspectRatio,
            to: state.aspectRatio,
            newRatio,
            hasCrop: !!state.crop,
            stageSize: [stage.width(), stage.height()],
            cropBefore: state.crop
              ? {
                  xPct: state.crop.xPct,
                  yPct: state.crop.yPct,
                  widthPct: state.crop.widthPct,
                  heightPct: state.crop.heightPct,
                }
              : null,
          });
        }
        // When the user switches to a locked ratio with an existing
        // crop, snap the crop's pixel dimensions to match — preserving
        // the origin, shrinking whichever dimension exceeds the new
        // ratio, and clamping the result to image bounds. Then notify
        // the modal so its tracked state stays canonical.
        //
        // Going to "free" (newRatio == null) doesn't change geometry;
        // it just unlocks future resizes. We still flag cropChanged
        // so the transformer rebuilds with all 8 anchors.
        if (state.crop) {
          if (newRatio != null) {
            const sw = stage.width();
            const sh = stage.height();
            if (sw > 0 && sh > 0) {
              const cx = (state.crop.xPct / 100) * sw;
              const cy = (state.crop.yPct / 100) * sh;
              const cw = (state.crop.widthPct / 100) * sw;
              const ch = (state.crop.heightPct / 100) * sh;

              const currentRatio = cw / ch;
              let newW;
              let newH;
              if (currentRatio > newRatio) {
                newH = ch;
                newW = newH * newRatio;
              } else {
                newW = cw;
                newH = newW / newRatio;
              }

              // Clamp to image bounds. Preserve origin; shrink
              // whichever dimension overflows, then re-derive the
              // other from the ratio.
              let newX = cx;
              let newY = cy;
              if (newX + newW > sw) {
                newW = sw - newX;
                newH = newW / newRatio;
              }
              if (newY + newH > sh) {
                newH = sh - newY;
                newW = newH * newRatio;
              }

              const xPct = (newX / sw) * 100;
              const yPct = (newY / sh) * 100;
              const widthPct = (newW / sw) * 100;
              const heightPct = (newH / sh) * 100;

              state.crop = {
                ...state.crop,
                xPct,
                yPct,
                widthPct,
                heightPct,
              };
              // Defer the modal callback to a microtask. update() is
              // invoked synchronously inside a Glimmer DidUpdateModifier
              // computation that has already READ `this.crop`. Writing
              // it back synchronously triggers Ember's
              // "tracked-value-used-then-updated" assertion. Microtask
              // scheduling lets the current render finish first; the
              // modal then updates `this.crop` in the next tick and
              // Glimmer reconciles normally. The synchronous state.crop
              // mutation + renderCrop below still fires, so the visual
              // updates without waiting for the microtask.
              if (onUpdateCrop) {
                queueMicrotask(() =>
                  onUpdateCrop(xPct, yPct, widthPct, heightPct)
                );
              }
            }
          }
          cropChanged = true;
        }
      }

      if (cropChanged) {
        renderCrop();
        applyContainerCursor();
      }
      if (attentionPullsChanged) {
        renderAttentionPulls();
      }
      if (strongAreasChanged) {
        renderStrongAreas();
      }
      if (eyePathChanged) {
        renderEyePaths();
      }
      if (directionArrowsChanged) {
        renderDirectionArrows();
      }
      if (relationshipArrowsChanged) {
        renderRelationshipArrows();
      }
      if (pinsChanged) {
        renderPins();
      }
    },

    destroy() {
      try {
        resizeObserver.disconnect();
      } catch (_e) {
        // Disconnecting a disconnected observer is fine.
      }
      try {
        stage.destroy();
      } catch (_e) {
        // Stage may already be torn down; swallow.
      }
    },
  };
}

function sameCrop(a, b) {
  if (a === b) {
    return true;
  }
  if (!a || !b) {
    return false;
  }
  return (
    a.xPct === b.xPct &&
    a.yPct === b.yPct &&
    a.widthPct === b.widthPct &&
    a.heightPct === b.heightPct &&
    // Include aspectRatio so a pure ratio change (modal sets
    // `{ ...crop, aspectRatio: "3:2" }` with identical xywh) flows
    // through the crop block — the aspectRatio block then sees a
    // fully-synced state.crop when it recomputes.
    (a.aspectRatio ?? null) === (b.aspectRatio ?? null)
  );
}

// Diagnostic helper. Tells callers whether Konva is currently loaded
// without triggering a load. Useful for the spike report.
export function isKonvaLoaded() {
  return typeof window !== "undefined" && !!window.Konva;
}
