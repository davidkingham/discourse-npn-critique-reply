// Image-transform helpers for the Critique Workspace.
//
// Three concerns split across small pure functions:
//
//   1. `composeTransform` — accumulate a sequence of rotate/flip
//      actions into a single canonical `{ rotation, flipH, flipV }`
//      state. Rotation is always one of 0/90/180/270 and combines
//      modulo 360. Flips toggle. Composition order matters:
//      conceptually each action is applied AFTER all previously
//      composed ones, in the user-visible coordinate space.
//
//   2. `applyTransformToImage` — given an `HTMLImageElement` and a
//      canonical transform, return a fresh `HTMLImageElement` whose
//      bitmap is the source rebaked through a canvas with the
//      requested rotation + flip applied. Always rebakes from the
//      ORIGINAL source (callers must keep a reference) so repeated
//      transforms don't compound JPEG artifacts.
//
//   3. `transformAnnotationPercentages` — pure coordinate transform
//      applied to the modal's in-memory annotation arrays. Mirrors the
//      annotation kinds in npn-critique-reply-annotation-schema.js:
//      pins, crop, eyePaths, attentionPulls, strongAreas,
//      directionArrows, relationshipArrows. Each action transforms
//      the 0..100% coordinate space in one step; chained user actions
//      chain through this helper one at a time.
//
// All coordinate math operates in 0..100 percent space, matching the
// annotation schema. A point `(x, y)` under an incremental action:
//
//   rotate_cw:  (x, y) → (100 - y, x)
//   rotate_ccw: (x, y) → (y, 100 - x)
//   flip_h:     (x, y) → (100 - x, y)
//   flip_v:     (x, y) → (x, 100 - y)
//
// Rect-shaped annotations (crop + ellipse area markers) carry
// (x, y, width, height) where (x, y) is the top-left corner. Rotation
// moves the corner, so we transform the four corners and take
// (min-x, min-y, abs-width, abs-height) afterwards. Flips invert one
// axis of the origin so the rect's anchor still sits at top-left.
//
// Crop `aspectRatio` is left as-is — it's a display hint, not a
// constraint enforced at render time. The stored width/height
// percentages remain authoritative after rotation.

export const ACTIONS = Object.freeze({
  ROTATE_CW: "rotate_cw",
  ROTATE_CCW: "rotate_ccw",
  FLIP_H: "flip_h",
  FLIP_V: "flip_v",
  RESET: "reset",
});

export const IDENTITY_TRANSFORM = Object.freeze({
  rotation: 0,
  flipH: false,
  flipV: false,
});

const VALID_ROTATIONS = new Set([0, 90, 180, 270]);

export function isIdentityTransform(transform) {
  if (!transform) {
    return true;
  }
  return (
    (transform.rotation ?? 0) === 0 &&
    !transform.flipH &&
    !transform.flipV
  );
}

// Coerce arbitrary input to a canonical transform. Accepts both the
// modal's camelCase keys (`flipH`, `flipV`) and the persisted
// snake_case keys (`flip_h`, `flip_v`) so the same helper covers
// restore-from-payload and in-modal state.
export function normalizeTransform(value) {
  if (!value || typeof value !== "object") {
    return { ...IDENTITY_TRANSFORM };
  }
  const rotationRaw = Number(value.rotation);
  const rotation = VALID_ROTATIONS.has(rotationRaw) ? rotationRaw : 0;
  const flipH = value.flipH === true || value.flip_h === true;
  const flipV = value.flipV === true || value.flip_v === true;
  return { rotation, flipH, flipV };
}

// Compose the current accumulated transform with a single incremental
// action. Returns a NEW transform object — never mutates input.
//
// Rotation/flip composition rules:
//   • rotate_cw: rotation = (rotation + 90) mod 360
//   • rotate_ccw: rotation = (rotation + 270) mod 360
//   • flip_h: when current rotation is 90 or 270, swapping horizontal
//     and vertical happens naturally; we toggle flipH unconditionally
//     and let `applyTransformToImage`'s canvas pipeline handle the
//     order-of-operations. Same for flip_v.
//   • reset: returns identity.
//
// The chosen composition order is "current transform first, then
// new action applied in user-visible space" — i.e. clicking flip-h
// after a 90° rotation flips left/right of what the user sees on
// screen, not of the underlying source. Coordinate-wise this matches
// applying `flip_h` to the already-rotated annotation positions,
// which is exactly what `transformAnnotationPercentages` does when
// the caller passes the incremental action.
export function composeTransform(current, action) {
  const base = normalizeTransform(current);
  switch (action) {
    case ACTIONS.RESET:
      return { ...IDENTITY_TRANSFORM };
    case ACTIONS.ROTATE_CW:
      return { ...base, rotation: (base.rotation + 90) % 360 };
    case ACTIONS.ROTATE_CCW:
      return { ...base, rotation: (base.rotation + 270) % 360 };
    case ACTIONS.FLIP_H:
      // Flip in user-visible space. When the image has been rotated
      // 90° or 270°, a "horizontal" flip from the user's perspective
      // is equivalent to a vertical flip of the underlying pre-
      // rotation source. Track this so the canvas pipeline draws the
      // bitmap correctly.
      if (base.rotation === 90 || base.rotation === 270) {
        return { ...base, flipV: !base.flipV };
      }
      return { ...base, flipH: !base.flipH };
    case ACTIONS.FLIP_V:
      if (base.rotation === 90 || base.rotation === 270) {
        return { ...base, flipH: !base.flipH };
      }
      return { ...base, flipV: !base.flipV };
    default:
      return base;
  }
}

// Apply an incremental coordinate transform to a single (x, y) point
// in 0..100 percent space. Returns `{ xPct, yPct }`.
function transformPoint(xPct, yPct, action) {
  switch (action) {
    case ACTIONS.ROTATE_CW:
      return { xPct: 100 - yPct, yPct: xPct };
    case ACTIONS.ROTATE_CCW:
      return { xPct: yPct, yPct: 100 - xPct };
    case ACTIONS.FLIP_H:
      return { xPct: 100 - xPct, yPct };
    case ACTIONS.FLIP_V:
      return { xPct, yPct: 100 - yPct };
    default:
      return { xPct, yPct };
  }
}

// Transform a rect under an incremental action. Rotates the four
// corners, takes the new bounding box. Flips invert the origin axis.
// Returns `{ xPct, yPct, widthPct, heightPct }`.
function transformRect(xPct, yPct, widthPct, heightPct, action) {
  if (action === ACTIONS.FLIP_H) {
    return { xPct: 100 - xPct - widthPct, yPct, widthPct, heightPct };
  }
  if (action === ACTIONS.FLIP_V) {
    return { xPct, yPct: 100 - yPct - heightPct, widthPct, heightPct };
  }
  if (action === ACTIONS.ROTATE_CW) {
    return {
      xPct: 100 - yPct - heightPct,
      yPct: xPct,
      widthPct: heightPct,
      heightPct: widthPct,
    };
  }
  if (action === ACTIONS.ROTATE_CCW) {
    return {
      xPct: yPct,
      yPct: 100 - xPct - widthPct,
      widthPct: heightPct,
      heightPct: widthPct,
    };
  }
  return { xPct, yPct, widthPct, heightPct };
}

function transformPin(pin, action) {
  const { xPct, yPct } = transformPoint(pin.xPct, pin.yPct, action);
  return { ...pin, xPct, yPct };
}

function transformCrop(crop, action) {
  if (!crop) {
    return crop;
  }
  const { xPct, yPct, widthPct, heightPct } = transformRect(
    crop.xPct,
    crop.yPct,
    crop.widthPct,
    crop.heightPct,
    action
  );
  return { ...crop, xPct, yPct, widthPct, heightPct };
}

function transformEyePath(path, action) {
  if (!path || !Array.isArray(path.points)) {
    return path;
  }
  return {
    ...path,
    points: path.points.map((p) => {
      const { xPct, yPct } = transformPoint(p.xPct, p.yPct, action);
      return { ...p, xPct, yPct };
    }),
  };
}

function transformAreaMarker(marker, action) {
  if (!marker) {
    return marker;
  }
  if (marker.shape === "path" && Array.isArray(marker.points)) {
    return {
      ...marker,
      points: marker.points.map((p) => {
        const { xPct, yPct } = transformPoint(p.xPct, p.yPct, action);
        return { ...p, xPct, yPct };
      }),
    };
  }
  const { xPct, yPct, widthPct, heightPct } = transformRect(
    marker.xPct,
    marker.yPct,
    marker.widthPct,
    marker.heightPct,
    action
  );
  return { ...marker, xPct, yPct, widthPct, heightPct };
}

function transformArrow(arrow, action) {
  if (!arrow) {
    return arrow;
  }
  const start = transformPoint(arrow.x1Pct, arrow.y1Pct, action);
  const end = transformPoint(arrow.x2Pct, arrow.y2Pct, action);
  return {
    ...arrow,
    x1Pct: start.xPct,
    y1Pct: start.yPct,
    x2Pct: end.xPct,
    y2Pct: end.yPct,
  };
}

// Walk the modal's in-memory annotation arrays for ONE image and
// transform every coordinate under the given incremental action.
// Returns a fresh annotations object with the same shape. Untouched
// fields (id, label, mode, aspectRatio, noteText, etc.) pass through.
//
// `bundle` shape (matches what the modal stores per image):
//   {
//     pins: [{ number, xPct, yPct, ... }],
//     crop: { xPct, yPct, widthPct, heightPct, aspectRatio, label? } | null,
//     eyePaths: [{ id, label, mode, points: [{ number, xPct, yPct }] }],
//     attentionPulls: [{ id, label, shape, xPct, yPct, widthPct, heightPct } | { id, label, shape: "path", points }],
//     strongAreas: same shape as attentionPulls,
//     directionArrows: [{ id, label, x1Pct, y1Pct, x2Pct, y2Pct, noteText? }],
//     relationshipArrows: same shape as directionArrows,
//   }
export function transformAnnotationPercentages(bundle, action) {
  if (!bundle || action === ACTIONS.RESET) {
    return bundle;
  }
  return {
    ...bundle,
    pins: Array.isArray(bundle.pins)
      ? bundle.pins.map((p) => transformPin(p, action))
      : bundle.pins,
    crop: bundle.crop ? transformCrop(bundle.crop, action) : bundle.crop,
    eyePaths: Array.isArray(bundle.eyePaths)
      ? bundle.eyePaths.map((p) => transformEyePath(p, action))
      : bundle.eyePaths,
    attentionPulls: Array.isArray(bundle.attentionPulls)
      ? bundle.attentionPulls.map((m) => transformAreaMarker(m, action))
      : bundle.attentionPulls,
    strongAreas: Array.isArray(bundle.strongAreas)
      ? bundle.strongAreas.map((m) => transformAreaMarker(m, action))
      : bundle.strongAreas,
    directionArrows: Array.isArray(bundle.directionArrows)
      ? bundle.directionArrows.map((a) => transformArrow(a, action))
      : bundle.directionArrows,
    relationshipArrows: Array.isArray(bundle.relationshipArrows)
      ? bundle.relationshipArrows.map((a) => transformArrow(a, action))
      : bundle.relationshipArrows,
  };
}

// Rebake the source image through a canvas with the canonical
// transform applied. Returns a Promise resolving to a fresh
// `HTMLImageElement` whose `src` is a data URL of the transformed
// bitmap. The original element is never mutated.
//
// The pipeline is order-sensitive:
//   1. translate to the center of the OUTPUT canvas (post-rotation
//      dimensions if rotated 90/270°)
//   2. rotate by `rotation` degrees
//   3. scale by ±1 on each axis to apply flips
//   4. drawImage centered on origin
//
// Flips are applied before drawImage but conceptually represent the
// user-visible flip — `composeTransform` already swapped flipH/flipV
// when the rotation made them user-visible-different, so the pipeline
// here can apply them naively.
export function applyTransformToImage(htmlImage, transform) {
  return new Promise((resolve, reject) => {
    if (!htmlImage || !htmlImage.naturalWidth || !htmlImage.naturalHeight) {
      reject(new Error("applyTransformToImage: source image not loaded"));
      return;
    }
    const t = normalizeTransform(transform);
    if (isIdentityTransform(t)) {
      // No-op transform: hand back a clone of the original to keep
      // callers' "always get a fresh element" assumption uniform.
      const clone = new Image();
      clone.onload = () => resolve(clone);
      clone.onerror = (e) => reject(e);
      clone.src = htmlImage.src;
      return;
    }
    const srcW = htmlImage.naturalWidth;
    const srcH = htmlImage.naturalHeight;
    const rotated = t.rotation === 90 || t.rotation === 270;
    const outW = rotated ? srcH : srcW;
    const outH = rotated ? srcW : srcH;
    const canvas = document.createElement("canvas");
    canvas.width = outW;
    canvas.height = outH;
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      reject(new Error("applyTransformToImage: 2D context unavailable"));
      return;
    }
    ctx.save();
    ctx.translate(outW / 2, outH / 2);
    if (t.rotation) {
      ctx.rotate((t.rotation * Math.PI) / 180);
    }
    if (t.flipH || t.flipV) {
      ctx.scale(t.flipH ? -1 : 1, t.flipV ? -1 : 1);
    }
    ctx.drawImage(htmlImage, -srcW / 2, -srcH / 2, srcW, srcH);
    ctx.restore();
    // Use JPEG at high quality — matches the existing flatten
    // pipeline's output format and keeps the data URL small enough
    // for in-DOM use during the editing session. Quality 0.95 is the
    // sweet spot used elsewhere in this plugin.
    let dataUrl;
    try {
      dataUrl = canvas.toDataURL("image/jpeg", 0.95);
    } catch (e) {
      reject(e);
      return;
    }
    const out = new Image();
    out.onload = () => resolve(out);
    out.onerror = (e) => reject(e);
    out.src = dataUrl;
  });
}
