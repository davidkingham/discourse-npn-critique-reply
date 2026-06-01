import { getURLWithCDN } from "discourse/lib/get-url";
import loadScript from "discourse/lib/load-script";
import {
  ANNOTATION_BLUE,
  ANNOTATION_HALO,
  AREA_FILL_OPACITY_SELECTED,
  AREA_FILL_OPACITY_UNSELECTED,
  ATTENTION_PULL_OCHRE,
  CROP_DIM_FILL,
  STRONG_AREA_SAGE,
} from "./npn-critique-reply-colors";

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
  if ((a.label ?? null) !== (b.label ?? null)) {
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

// Defensive clone so closure-side mutations can't leak into the
// modal's tracked array.
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
    xPct: p.xPct,
    yPct: p.yPct,
    widthPct: p.widthPct,
    heightPct: p.heightPct,
  }));
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
      (x.label ?? null) !== (y.label ?? null)
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
      (x.label ?? null) !== (y.label ?? null)
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
  eyePath = null,
  attentionPulls = [],
  strongAreas = [],
  selectedPinNumber = null,
  cropSelected = false,
  eyePathSelected = false,
  selectedAttentionPullId = null,
  selectedStrongAreaId = null,
  visualMode = null,
  aspectRatio = "free",
  pinMoveEnabled = true,
  attentionPullEditEnabled = true,
  strongAreaEditEnabled = true,
  onAddPin,
  onSelectPin,
  onMovePin,
  onAddCrop,
  onSelectCrop,
  onUpdateCrop,
  onAddEyePathPoint,
  onSelectEyePath,
  onMoveEyePathPoint,
  onAddAttentionPull,
  onSelectAttentionPull,
  onUpdateAttentionPull,
  onAddStrongArea,
  onSelectStrongArea,
  onUpdateStrongArea,
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
  const cropLayer = new Konva.Layer();
  const attentionPullLayer = new Konva.Layer();
  const strongAreaLayer = new Konva.Layer();
  const eyePathLayer = new Konva.Layer();
  const pinLayer = new Konva.Layer();
  stage.add(cropLayer);
  stage.add(attentionPullLayer);
  stage.add(strongAreaLayer);
  stage.add(eyePathLayer);
  stage.add(pinLayer);

  // Drawing-preview layer reused for the live drag-to-crop rectangle.
  // Sits above crop layer so the preview is unambiguous.
  const previewLayer = new Konva.Layer();
  stage.add(previewLayer);

  // Mutable state held in closure. Each update() call mutates this
  // and re-renders. We avoid Konva.fromObject / toObject so the schema
  // owned by the modal stays the only source of truth.
  const state = {
    pins: [...pins],
    crop: crop ? { ...crop } : null,
    eyePath: cloneEyePath(eyePath),
    attentionPulls: cloneAttentionPulls(attentionPulls),
    strongAreas: cloneStrongAreas(strongAreas),
    selectedPinNumber,
    cropSelected,
    eyePathSelected,
    selectedAttentionPullId,
    selectedStrongAreaId,
    visualMode,
    aspectRatio,
    pinMoveEnabled,
    attentionPullEditEnabled,
    strongAreaEditEnabled,
  };

  // Drag-to-create attention-pull state — set on mousedown over empty
  // stage in attention_pull mode, cleared on mouseup.
  let attentionDrag = null;
  // Drag-to-create strong-area state — same pattern.
  let strongDrag = null;

  // Drag-to-crop in-flight state. Set when the user starts dragging
  // on empty stage in crop mode; cleared on pointerup.
  let cropDrag = null;

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
    // badge is the primary critique anchor.
    const tertiary = ANNOTATION_BLUE;
    const secondary = ANNOTATION_HALO;
    const tertiaryHover = ANNOTATION_BLUE;

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

    if (canMove) {
      // Cursor affordance: "move" while hovering a draggable pin,
      // revert to the mode-default on leave.
      group.on("mouseenter", () => {
        container.style.cursor = "move";
      });
      group.on("mouseleave", () => {
        applyContainerCursor();
      });

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
      attentionPullLayer.batchDraw();
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      attentionPullLayer.batchDraw();
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
      const haloWidth = Math.max(4, Math.round(shortEdge * 0.0055));
      const strokeWidth = isSelected
        ? Math.max(3, Math.round(shortEdge * 0.005))
        : Math.max(2, Math.round(shortEdge * 0.0035));
      const dashOn = Math.max(7, Math.round(shortEdge * 0.012));
      const dashOff = Math.max(5, Math.round(shortEdge * 0.008));
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
      });
      attentionPullLayer.add(haloRef);

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
        listening: true,
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
      fillBody.on("click tap", (e) => {
        e.cancelBubble = true;
        onSelectAttentionPull?.(id);
      });
      attentionPullLayer.add(fillBody);

      const strokeRef = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        stroke: amber,
        strokeWidth,
        dash: isSelected ? [] : [dashOn, dashOff],
        fillEnabled: false,
        listening: false,
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
          attentionPullLayer.batchDraw();
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
    attentionPullLayer.batchDraw();
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
      strongAreaLayer.batchDraw();
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      strongAreaLayer.batchDraw();
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

      const haloWidth = Math.max(4, Math.round(shortEdge * 0.0055));
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
      });
      strongAreaLayer.add(haloRef);

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
        listening: true,
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
      strongAreaLayer.add(fillBody);

      // SOLID stroke (no dash) — visual contrast with attention pull's
      // dashed outline. The supportive intent reads as confident
      // rather than tentative.
      const strokeRef = new Konva.Ellipse({
        x: cx,
        y: cy,
        radiusX: rx,
        radiusY: ry,
        stroke: green,
        strokeWidth,
        fillEnabled: false,
        listening: false,
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
          strongAreaLayer.batchDraw();
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
    strongAreaLayer.batchDraw();
  }

  function renderPins() {
    pinLayer.destroyChildren();
    for (const pin of state.pins) {
      pinLayer.add(buildPinGroup(pin));
    }
    pinLayer.batchDraw();
  }

  // Eye-path renderer. The path reads as direction-from-start-to-end:
  //   • small dot at the first point — "begin here"
  //   • halo polyline + tertiary line (slightly translucent)
  //   • small arrowheads spaced along each segment for in-flight
  //     directional cues
  //   • slightly emphatic terminal arrowhead at the last point —
  //     "ends here, attention lands"
  //
  // No per-point waypoint markers or numerals — the line carries the
  // path, and the start/end cues anchor its direction. Points still
  // exist in state.eyePath for interaction (Remove last / Clear).
  function renderEyePath() {
    eyePathLayer.destroyChildren();

    const path = state.eyePath;
    if (!path || !Array.isArray(path.points) || path.points.length === 0) {
      eyePathLayer.batchDraw();
      return;
    }
    const sw = stage.width();
    const sh = stage.height();
    if (sw === 0 || sh === 0) {
      eyePathLayer.batchDraw();
      return;
    }

    // Eye path shares the muted blue family with pins and crop —
    // "elegant and directional, not loud" per the palette refinement.
    const tertiary = ANNOTATION_BLUE;
    const secondary = ANNOTATION_HALO;
    const tertiaryHover = ANNOTATION_BLUE;
    const shortEdge = Math.min(sw, sh);

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

    function buildDecorations(pts) {
      decorationsGroup.destroyChildren();

      if (pts.length >= 2) {
        const flat = [];
        for (const p of pts) {
          flat.push(p.x, p.y);
        }
        const haloWidth = Math.max(5, Math.round(shortEdge * 0.0075));
        const lineWidth = Math.max(2, Math.round(shortEdge * 0.004));

        // White halo for readability over dark image areas.
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
          })
        );
        // Main tertiary line. Slim + slightly translucent so the
        // photo reads through. Tints to tertiaryHover when selected.
        decorationsGroup.add(
          new Konva.Line({
            points: flat,
            stroke: state.eyePathSelected ? tertiaryHover : tertiary,
            strokeWidth: lineWidth,
            lineCap: "round",
            lineJoin: "round",
            opacity: 0.9,
            tension: EYE_PATH_SMOOTH ? EYE_PATH_SMOOTH_TENSION : 0,
            listening: false,
          })
        );

        // In-segment chevrons. Positioned and oriented along the
        // exact Konva-tension curve via getKonvaSegment + samplePos /
        // sampleTangent. Cap 2 per segment, ~250% spacing. Elongated
        // triangle shape (taller than wide) so the direction reads
        // clearly even at modest sizes.
        const arrowSize = Math.max(10, Math.round(shortEdge * 0.015));
        const targetSpacing = Math.max(160, Math.round(shortEdge * 0.25));
        const ARROWS_PER_SEGMENT_CAP = 2;
        for (let i = 0; i < pts.length - 1; i++) {
          const p1 = pts[i];
          const p2 = pts[i + 1];
          const chord = Math.hypot(p2.x - p1.x, p2.y - p1.y);
          if (chord < arrowSize * 2.5) {
            continue;
          }
          const seg = getKonvaSegment(pts, i);
          const arrowCount = Math.min(
            ARROWS_PER_SEGMENT_CAP,
            Math.max(1, Math.round(chord / targetSpacing))
          );
          for (let k = 1; k <= arrowCount; k++) {
            const tParam = k / (arrowCount + 1);
            const center = samplePos(seg, tParam);
            const tang = sampleTangent(seg, tParam);
            const dlen = Math.hypot(tang.x, tang.y);
            if (dlen === 0) {
              continue;
            }
            const ux = tang.x / dlen;
            const uy = tang.y / dlen;
            const perpX = -uy;
            const perpY = ux;
            // Elongated arrow head: tip well forward, base close to
            // center, base half-width narrow. 1.0:0.7 aspect makes
            // the direction read clearly at any size.
            const tipX = center.x + ux * arrowSize * 0.7;
            const tipY = center.y + uy * arrowSize * 0.7;
            const baseCx = center.x - ux * arrowSize * 0.3;
            const baseCy = center.y - uy * arrowSize * 0.3;
            const baseHalf = arrowSize * 0.35;
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
                listening: false,
              })
            );
          }
        }
      }

      // Interior waypoint markers — editor-only visual cue so the
      // critic can see exactly where the draggable handles are
      // without hovering to find the "move" cursor. Skipped for the
      // start (already has its own dot) and end (already has its
      // own arrowhead). NOT drawn in the exported JPEG —
      // `drawEyePathOnCanvas` in npn-critique-reply-visual-notes.js
      // is a separate code path that intentionally renders only
      // line + arrows + start dot + terminal arrow, so the posted
      // image stays free of editing UI.
      if (pts.length >= 3) {
        const waypointR = Math.max(3, Math.round(shortEdge * 0.0045));
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
              fill: state.eyePathSelected ? tertiaryHover : tertiary,
              listening: false,
            })
          );
        }
      }

      // Start dot.
      if (pts.length >= 1) {
        const startR = Math.max(4, Math.round(shortEdge * 0.0065));
        const startHaloR = startR + Math.max(2, Math.round(startR * 0.4));
        const start = pts[0];
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
            fill: state.eyePathSelected ? tertiaryHover : tertiary,
            listening: false,
          })
        );

        // Label badge — small tertiary pill near the start dot.
        // Uses the same Konva.Label pattern as attention pulls but
        // tinted to the eye-path tertiary so the two badges are
        // visually distinguishable on the same image.
        const label = path.label;
        if (label) {
          const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
          const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
          const badgeHeight = badgeFontSize + 2 * badgePadding;
          const badgeOffset = Math.max(6, Math.round(shortEdge * 0.006));
          const labelNode = new Konva.Label({
            // Above-right of the start dot — leaves the dot itself
            // visually unobstructed and reads as a tag on the path.
            x: start.x + badgeOffset,
            y: start.y - badgeHeight - badgeOffset,
            listening: false,
          });
          labelNode.add(
            new Konva.Tag({
              fill: state.eyePathSelected ? tertiaryHover : tertiary,
              cornerRadius: 3,
              stroke: secondary,
              strokeWidth: 1.5,
              opacity: state.eyePathSelected ? 1 : 0.95,
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
              fill: state.eyePathSelected ? tertiaryHover : tertiary,
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
    const handleHitR = Math.max(10, Math.round(shortEdge * 0.014));
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
        draggable: true,
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
        eyePathLayer.batchDraw();
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
        // state.eyePath.
        livePts[pointIndex] = { x: handle.x(), y: handle.y() };
        // Update closure state BEFORE the callback so the next sync
        // (driven by the modal updating its tracked eyePath) sees
        // identical coords and skips a redundant re-render.
        state.eyePath = {
          ...state.eyePath,
          points: state.eyePath.points.map((pt, idx) =>
            idx === pointIndex
              ? { ...pt, xPct: newXPct, yPct: newYPct }
              : pt
          ),
        };
        // Final decoration redraw so everything lands at the exact
        // dragend coords (defensive — dragmove already ran on the
        // same coords, but this guards against any rounding drift).
        buildDecorations(livePts);
        eyePathLayer.batchDraw();
        onMoveEyePathPoint?.(pointNumber, newXPct, newYPct);
      });

      // Plain click without movement → select the path.
      handle.on("click tap", (e) => {
        e.cancelBubble = true;
        onSelectEyePath?.();
      });

      eyePathLayer.add(handle);
    }

    eyePathLayer.batchDraw();
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
      cropLayer.batchDraw();
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

    // Crop shares the muted blue family with pins and eye path, but
    // it's the quietest large annotation (thinner stroke / lower
    // dim opacity) so it doesn't overpower the photograph.
    const tertiary = ANNOTATION_BLUE;
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
      // and strong_area (drag-to-create on empty stage). The crop rect
      // is selectable on click only in modes that don't add anything
      // on click — i.e. when no tool is active, or in crop mode itself.
      listening:
        state.visualMode !== "numbered_notes" &&
        state.visualMode !== "eye_path" &&
        state.visualMode !== "attention_pull" &&
        state.visualMode !== "strong_area",
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

    cropLayer.batchDraw();
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

    cropLayer.batchDraw();
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
    // Crop decoration uses the same muted blue as the perimeter
    // (see npn-critique-reply-colors.js). Bracket / bar thickness
    // pushed to 8px so the corner / edge handles read as solidly
    // editable affordances on top of the photograph.
    const stageColor = ANNOTATION_BLUE;
    const bracketArm = 22;
    const bracketThick = 8;
    const edgeBarLen = 28;
    const edgeBarThick = 8;

    const group = new Konva.Group({ listening: false });

    // Thin 1px perimeter connecting the brackets.
    group.add(
      new Konva.Rect({
        x,
        y,
        width: w,
        height: h,
        stroke: stageColor,
        strokeWidth: 1,
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

    // 4 edge midpoint bars — only when free-ratio. Hidden in
    // ratio-locked mode because edge anchors are disabled then
    // (showing the bar would promise an interaction the user
    // can't actually do).
    if (!isRatioLocked) {
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
    // in-flight rect reads as a draft of the kind being placed.
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
    previewLayer.batchDraw();
  }

  // Click / tap on empty area handler. Behavior depends on mode:
  //   • numbered_notes → add pin
  //   • crop_suggestion → no-op on click (handled by drag below)
  //   • null → no-op (canvas is read-only)
  // Pin / crop clicks set cancelBubble in their own handlers, so the
  // stage handler only fires for clicks on truly empty area.
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
    } else if (state.visualMode === "eye_path") {
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
      onAddEyePathPoint?.(xPct, yPct);
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
      attentionDrag = { startX: pos.x, startY: pos.y };
      return;
    }
    if (state.visualMode === "strong_area") {
      strongDrag = { startX: pos.x, startY: pos.y };
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
      renderEyePath();
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
  renderEyePath();
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
      eyePath,
      attentionPulls,
      strongAreas,
      selectedPinNumber,
      cropSelected,
      eyePathSelected,
      selectedAttentionPullId,
      selectedStrongAreaId,
      visualMode,
      aspectRatio,
      pinMoveEnabled,
      attentionPullEditEnabled,
      strongAreaEditEnabled,
    } = {}) {
      let pinsChanged = false;
      let cropChanged = false;
      let eyePathChanged = false;
      let attentionPullsChanged = false;
      let strongAreasChanged = false;

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
      if (eyePath !== undefined && !sameEyePath(eyePath, state.eyePath)) {
        state.eyePath = cloneEyePath(eyePath);
        eyePathChanged = true;
      }
      if (
        eyePathSelected !== undefined &&
        eyePathSelected !== state.eyePathSelected
      ) {
        state.eyePathSelected = eyePathSelected;
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
        renderEyePath();
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
