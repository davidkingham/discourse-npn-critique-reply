import { ajax } from "discourse/lib/ajax";
import {
  ANNOTATION_BLUE,
  ANNOTATION_HALO,
  AREA_FILL_OPACITY_UNSELECTED,
  ATTENTION_PULL_OCHRE,
  CROP_DIM_FILL,
  STRONG_AREA_SAGE,
} from "./npn-critique-reply-colors";

// Visual Notes export/upload helpers. Used by the Critique Helper modal
// when the critic has placed pins and is about to Post Critique or Edit
// in Composer. Pipeline:
//
//   1. loadImageForExport      — fetch the selected version's image with
//                                CORS so canvas export isn't tainted.
//   2. buildVisualNotesCanvas  — composite image + numbered pins onto a
//                                fresh canvas, capped at MAX_DIMENSION.
//   3. exportCanvasToBlob      — JPEG blob (smaller than PNG for photos).
//   4. uploadVisualNotesBlob   — POST /uploads.json synchronous=true so
//                                the response carries the short_url we
//                                need before posting.
//
// Each helper is independently testable. The modal is the only caller
// today; keeping the pipeline pure-functional means we can move it into
// a worker later if export ever blocks the main thread noticeably.

export const MAX_DIMENSION = 1600;
export const JPEG_QUALITY = 0.9;

// Pin geometry constants — derived at draw time from the export
// dimensions so pins stay readable on 800px and 1600px images alike.
// Keep in sync with npn-critique-reply-konva-stage.js so the modal
// preview and the posted JPEG render at the same proportional size.
const PIN_RADIUS_RATIO = 0.021; // 2.1% of the short edge (was 2.5%)
const MIN_PIN_RADIUS = 17; // px — protects sub-800px exports
const HALO_RATIO = 0.18; // halo thickness as fraction of pin radius
const MIN_HALO = 3; // px


// Eye-path smoothing — must match the same-named constant in
// `npn-critique-reply-konva-stage.js` so the editor and exported
// image render the same curve. When true, the export uses a
// Catmull-Rom curve through every point (approximated via cubic
// bezier) and omits the chord-spaced in-segment arrows. Flip BOTH
// constants back to false for the straight-segment fallback.
const EYE_PATH_SMOOTH = true;
const EYE_PATH_SMOOTH_TENSION = 0.4;

// Same-origin or CORS-headered images load fine; opaque cross-origin
// images will resolve `onload` but later taint the canvas, which we
// surface through exportCanvasToBlob's reject path.
export function loadImageForExport(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = () =>
      reject(new Error(`visual_notes: image load failed (${url})`));
    img.src = url;
  });
}

// Composite the image + pins into a new canvas. Aspect ratio is
// preserved; the longer edge is capped at `maxDimension`.
export function buildVisualNotesCanvas({
  image,
  pins,
  crop,
  eyePath,
  attentionPulls,
  strongAreas,
  maxDimension = MAX_DIMENSION,
}) {
  const sourceWidth = image.naturalWidth || image.width;
  const sourceHeight = image.naturalHeight || image.height;
  if (!sourceWidth || !sourceHeight) {
    throw new Error("visual_notes: image has no dimensions");
  }

  let targetWidth, targetHeight;
  if (sourceWidth >= sourceHeight) {
    targetWidth = Math.min(sourceWidth, maxDimension);
    targetHeight = Math.round((targetWidth / sourceWidth) * sourceHeight);
  } else {
    targetHeight = Math.min(sourceHeight, maxDimension);
    targetWidth = Math.round((targetHeight / sourceHeight) * sourceWidth);
  }

  const canvas = document.createElement("canvas");
  canvas.width = targetWidth;
  canvas.height = targetHeight;
  const ctx = canvas.getContext("2d");
  if (!ctx) {
    throw new Error("visual_notes: 2D context unavailable");
  }

  // Render order (per spec): full image first, then crop overlay
  // (dim + border), then attention-pull markers (so they read above
  // the crop dim — useful when explaining why something was cropped
  // out), then eye path (polyline + arrows + start/terminal cues),
  // then pins on top so they stay readable when overlapping anything.
  ctx.drawImage(image, 0, 0, targetWidth, targetHeight);
  drawCropOnCanvas(ctx, crop, targetWidth, targetHeight);
  drawAttentionPullsOnCanvas(
    ctx,
    attentionPulls,
    targetWidth,
    targetHeight
  );
  drawStrongAreasOnCanvas(ctx, strongAreas, targetWidth, targetHeight);
  drawEyePathOnCanvas(ctx, eyePath, targetWidth, targetHeight);
  drawPinsOnCanvas(ctx, pins, targetWidth, targetHeight);

  return canvas;
}

// Draws the crop-suggestion overlay: a semi-transparent dim covering
// the area OUTSIDE the crop rectangle, plus a visible border around
// the rectangle itself. The full image stays visible — the dim is a
// visual cue, not a destructive crop. Pins are drawn on top of this
// by the caller.
function drawCropOnCanvas(ctx, crop, width, height) {
  if (!crop) {
    return;
  }
  const cx = (crop.xPct / 100) * width;
  const cy = (crop.yPct / 100) * height;
  const cw = (crop.widthPct / 100) * width;
  const ch = (crop.heightPct / 100) * height;
  if (cw <= 0 || ch <= 0) {
    return;
  }

  // Muted blue matches the editor's crop perimeter — see
  // npn-critique-reply-colors.js.
  const borderColor = ANNOTATION_BLUE;
  const borderWidth = Math.max(
    2,
    Math.round(Math.min(width, height) * 0.0035)
  );

  ctx.save();

  // Dim — 4 rects around the crop. Slightly less opaque than 0.5
  // so the area outside the crop stays readable (matches the
  // editor's CROP_DIM_FILL).
  ctx.fillStyle = CROP_DIM_FILL;
  // Top band
  if (cy > 0) {
    ctx.fillRect(0, 0, width, cy);
  }
  // Bottom band
  if (cy + ch < height) {
    ctx.fillRect(0, cy + ch, width, height - cy - ch);
  }
  // Left band (between the top and bottom bands)
  if (cx > 0) {
    ctx.fillRect(0, cy, cx, ch);
  }
  // Right band
  if (cx + cw < width) {
    ctx.fillRect(cx + cw, cy, width - cx - cw, ch);
  }

  // Border around the crop rectangle.
  ctx.strokeStyle = borderColor;
  ctx.lineWidth = borderWidth;
  // Inset by half the line width so the stroke sits inside the rect
  // and the dim/border edges align perfectly.
  const inset = borderWidth / 2;
  ctx.strokeRect(cx + inset, cy + inset, cw - borderWidth, ch - borderWidth);

  ctx.restore();
}

// Draws the eye-path overlay. Mirrors the Konva editor so the
// flattened JPEG looks like what the critic saw.
//
// The path is purely a directional line — no waypoint markers, no
// numerals. Direction is carried by repeated small arrowheads
// spaced along each segment. The white halo beneath the tertiary
// stroke keeps the path readable over dark image areas.
// Draws the attention-pull overlay. Mirrors the Konva renderer:
//   • white halo ellipse for contrast
//   • translucent amber fill (≈14% alpha)
//   • dashed amber stroke for an observational, non-corrective feel
// Selected markers aren't styled differently in export (selection is
// a UI concept that doesn't persist past flatten).
function drawAttentionPullsOnCanvas(ctx, pulls, width, height) {
  if (!Array.isArray(pulls) || pulls.length === 0) {
    return;
  }
  // Muted ochre matches the editor's attention-pull ellipse —
  // see npn-critique-reply-colors.js.
  const amber = ATTENTION_PULL_OCHRE;
  const secondary = ANNOTATION_HALO;
  const shortEdge = Math.min(width, height);
  // Halo widened (0.55% → 0.75%) to match the editor — gives the
  // muted ochre enough contrast on similarly-toned backgrounds.
  const haloWidth = Math.max(5, Math.round(shortEdge * 0.0075));
  const strokeWidth = Math.max(2, Math.round(shortEdge * 0.0035));
  // Slightly larger dash gap so the dashed stroke reads calmer on
  // small markers (previously the dashes packed tight and felt
  // "buzzy" against detailed photographs).
  const dashOn = Math.max(8, Math.round(shortEdge * 0.013));
  const dashOff = Math.max(7, Math.round(shortEdge * 0.011));

  const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
  const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
  const badgeOffset = Math.max(3, Math.round(shortEdge * 0.004));
  const badgeCornerRadius = 3;

  ctx.save();
  for (const pull of pulls) {
    const cx = ((pull.xPct + pull.widthPct / 2) / 100) * width;
    const cy = ((pull.yPct + pull.heightPct / 2) / 100) * height;
    const rx = (pull.widthPct / 200) * width;
    const ry = (pull.heightPct / 200) * height;
    if (rx <= 0 || ry <= 0) {
      continue;
    }

    // White halo stroke (under everything).
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
    ctx.setLineDash([]);
    ctx.strokeStyle = secondary;
    ctx.lineWidth = haloWidth;
    ctx.globalAlpha = 0.85;
    ctx.stroke();

    // Translucent amber fill.
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
    ctx.fillStyle = amber;
    // Matches AREA_FILL_OPACITY_UNSELECTED in the editor so the
    // exported translucent fill reads the same as the modal preview.
    ctx.globalAlpha = AREA_FILL_OPACITY_UNSELECTED;
    ctx.fill();

    // Dashed amber stroke on top.
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
    ctx.setLineDash([dashOn, dashOff]);
    ctx.strokeStyle = amber;
    ctx.lineWidth = strokeWidth;
    ctx.globalAlpha = 1;
    ctx.stroke();

    // Label badge at the upper-left corner of the bounding box.
    if (pull.label) {
      ctx.setLineDash([]);
      ctx.font = `bold ${badgeFontSize}px sans-serif`;
      ctx.textBaseline = "top";
      const metrics = ctx.measureText(pull.label);
      const badgeWidth = Math.ceil(metrics.width) + badgePadding * 2;
      const badgeHeight = badgeFontSize + badgePadding * 2;
      const bx = cx - rx + badgeOffset;
      const by = cy - ry + badgeOffset;
      tracePillRect(
        ctx,
        bx,
        by,
        badgeWidth,
        badgeHeight,
        badgeCornerRadius
      );
      ctx.fillStyle = amber;
      ctx.globalAlpha = 1;
      ctx.fill();
      ctx.strokeStyle = secondary;
      ctx.lineWidth = 1.5;
      ctx.stroke();
      ctx.fillStyle = secondary;
      ctx.fillText(pull.label, bx + badgePadding, by + badgePadding);
    }
  }
  // Reset dash so subsequent shapes (eye path, pins) aren't dashed.
  ctx.setLineDash([]);
  ctx.globalAlpha = 1;
  ctx.restore();
}

// Twin of drawAttentionPullsOnCanvas — same shape, swapped color
// (`--success` green) and SOLID stroke (no dashes). Same badge style
// so attention-pull and strong-area markers read as a paired family.
function drawStrongAreasOnCanvas(ctx, areas, width, height) {
  if (!Array.isArray(areas) || areas.length === 0) {
    return;
  }
  // Muted sage matches the editor's strong-area ellipse — see
  // npn-critique-reply-colors.js.
  const green = STRONG_AREA_SAGE;
  const secondary = ANNOTATION_HALO;
  const shortEdge = Math.min(width, height);
  // Halo widened to match the editor — sage can blend into greenery
  // in the photograph; the wider halo gives the stroke more contrast.
  const haloWidth = Math.max(5, Math.round(shortEdge * 0.0075));
  const strokeWidth = Math.max(2, Math.round(shortEdge * 0.0035));
  const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
  const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
  const badgeOffset = Math.max(3, Math.round(shortEdge * 0.004));
  const badgeCornerRadius = 3;

  ctx.save();
  for (const area of areas) {
    const cx = ((area.xPct + area.widthPct / 2) / 100) * width;
    const cy = ((area.yPct + area.heightPct / 2) / 100) * height;
    const rx = (area.widthPct / 200) * width;
    const ry = (area.heightPct / 200) * height;
    if (rx <= 0 || ry <= 0) {
      continue;
    }

    // White halo stroke.
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
    ctx.setLineDash([]);
    ctx.strokeStyle = secondary;
    ctx.lineWidth = haloWidth;
    ctx.globalAlpha = 0.85;
    ctx.stroke();

    // Translucent green fill.
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
    ctx.fillStyle = green;
    // Matches AREA_FILL_OPACITY_UNSELECTED in the editor so the
    // exported translucent fill reads the same as the modal preview.
    ctx.globalAlpha = AREA_FILL_OPACITY_UNSELECTED;
    ctx.fill();

    // Solid green stroke (no dash) on top.
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
    ctx.strokeStyle = green;
    ctx.lineWidth = strokeWidth;
    ctx.globalAlpha = 1;
    ctx.stroke();

    if (area.label) {
      ctx.font = `bold ${badgeFontSize}px sans-serif`;
      ctx.textBaseline = "top";
      const metrics = ctx.measureText(area.label);
      const badgeWidth = Math.ceil(metrics.width) + badgePadding * 2;
      const badgeHeight = badgeFontSize + badgePadding * 2;
      const bx = cx - rx + badgeOffset;
      const by = cy - ry + badgeOffset;
      tracePillRect(
        ctx,
        bx,
        by,
        badgeWidth,
        badgeHeight,
        badgeCornerRadius
      );
      ctx.fillStyle = green;
      ctx.globalAlpha = 1;
      ctx.fill();
      ctx.strokeStyle = secondary;
      ctx.lineWidth = 1.5;
      ctx.stroke();
      ctx.fillStyle = secondary;
      ctx.fillText(area.label, bx + badgePadding, by + badgePadding);
    }
  }
  ctx.globalAlpha = 1;
  ctx.restore();
}

// Trace a rounded rectangle path (used for the attention-pull label
// badge). Manual fallback because ctx.roundRect isn't universally
// available in the Discourse-supported browser matrix.
function tracePillRect(ctx, x, y, w, h, r) {
  const rr = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + rr, y);
  ctx.lineTo(x + w - rr, y);
  ctx.arcTo(x + w, y, x + w, y + rr, rr);
  ctx.lineTo(x + w, y + h - rr);
  ctx.arcTo(x + w, y + h, x + w - rr, y + h, rr);
  ctx.lineTo(x + rr, y + h);
  ctx.arcTo(x, y + h, x, y + h - rr, rr);
  ctx.lineTo(x, y + rr);
  ctx.arcTo(x, y, x + rr, y, rr);
  ctx.closePath();
}

// Matches Konva.Line's `tension` formula: chord-length-weighted
// Catmull-Rom, with a quadratic first segment, cubic middle segments,
// and a quadratic last segment. Mirror of getKonvaSegment in
// npn-critique-reply-konva-stage.js. Keeping these in sync is what
// keeps the editor and the flattened JPEG visually identical.
function getKonvaSegment(points, i) {
  const p1 = points[i];
  const p2 = points[i + 1];
  if (!EYE_PATH_SMOOTH || points.length < 3) {
    return { type: "linear", p1, p2 };
  }
  const isFirst = i === 0;
  const isLast = i === points.length - 2;
  const t = EYE_PATH_SMOOTH_TENSION;
  if (isFirst) {
    const pNext = points[i + 2];
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
    const pPrev = points[i - 1];
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
  const pPrev = points[i - 1];
  const pNext = points[i + 2];
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

// Builds the path on `ctx` from the given points. When
// EYE_PATH_SMOOTH is false, traces straight chords. When true, emits
// a quadratic-first / cubic-middle / quadratic-last sequence that
// matches Konva's tension rendering. Caller owns beginPath / stroke;
// this just writes path commands so it can be reused for halo and
// main stroke.
function traceEyePath(ctx, points) {
  ctx.beginPath();
  if (points.length === 0) {
    return;
  }
  ctx.moveTo(points[0].x, points[0].y);
  if (!EYE_PATH_SMOOTH || points.length < 3) {
    for (let i = 1; i < points.length; i++) {
      ctx.lineTo(points[i].x, points[i].y);
    }
    return;
  }
  for (let i = 0; i < points.length - 1; i++) {
    const seg = getKonvaSegment(points, i);
    if (seg.type === "quad") {
      ctx.quadraticCurveTo(seg.cp.x, seg.cp.y, seg.p2.x, seg.p2.y);
    } else if (seg.type === "cubic") {
      ctx.bezierCurveTo(
        seg.c1.x,
        seg.c1.y,
        seg.c2.x,
        seg.c2.y,
        seg.p2.x,
        seg.p2.y
      );
    } else {
      ctx.lineTo(seg.p2.x, seg.p2.y);
    }
  }
}

function drawEyePathOnCanvas(ctx, eyePath, width, height) {
  if (
    !eyePath ||
    !Array.isArray(eyePath.points) ||
    eyePath.points.length === 0
  ) {
    return;
  }
  const points = eyePath.points
    .map((p) => ({
      x: (p.xPct / 100) * width,
      y: (p.yPct / 100) * height,
      number: p.number,
    }))
    .filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y));
  if (points.length === 0) {
    return;
  }

  // Eye path uses the same muted blue as pins/crop — see
  // npn-critique-reply-colors.js.
  const tertiary = ANNOTATION_BLUE;
  const secondary = ANNOTATION_HALO;
  const shortEdge = Math.min(width, height);

  ctx.save();

  if (points.length >= 2) {
    const haloWidth = Math.max(4, Math.round(shortEdge * 0.0075));
    const lineWidth = Math.max(2, Math.round(shortEdge * 0.004));

    // Trace the path — straight chord-by-chord when smoothing is off,
    // Catmull-Rom curve (via cubic bezier) through every point when
    // on. Used for both the halo and the main stroke so they
    // perfectly overlay.
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    ctx.globalAlpha = 0.9;
    ctx.strokeStyle = secondary;
    ctx.lineWidth = haloWidth;
    traceEyePath(ctx, points);
    ctx.stroke();

    // Main tertiary line. Slim weight + 0.9 opacity so the photo
    // reads through and the path doesn't dominate the composition.
    ctx.globalAlpha = 0.9;
    ctx.strokeStyle = tertiary;
    ctx.lineWidth = lineWidth;
    traceEyePath(ctx, points);
    ctx.stroke();
    ctx.globalAlpha = 1;

    // In-segment chevrons. Sampled along the same Konva-tension curve
    // as the editor — getKonvaSegment + samplePos / sampleTangent
    // shared with the line trace above.
    const arrowSize = Math.max(10, Math.round(shortEdge * 0.015));
    const targetSpacing = Math.max(160, Math.round(shortEdge * 0.25));
    // Pulled in from 2 → 1: one mid-line arrow per segment is enough
    // to convey direction in the static JPEG, and avoids the path
    // feeling arrow-heavy on short segments. The editor doesn't draw
    // these at all (waypoint dots carry the cue there).
    const ARROWS_PER_SEGMENT_CAP = 1;
    ctx.fillStyle = tertiary;
    ctx.strokeStyle = secondary;
    ctx.lineWidth = Math.max(1, lineWidth * 0.6);
    for (let i = 0; i < points.length - 1; i++) {
      const p1 = points[i];
      const p2 = points[i + 1];
      const chord = Math.hypot(p2.x - p1.x, p2.y - p1.y);
      if (chord < arrowSize * 2.5) {
        continue;
      }
      const seg = getKonvaSegment(points, i);
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
        const tipX = center.x + ux * arrowSize * 0.7;
        const tipY = center.y + uy * arrowSize * 0.7;
        const baseCx = center.x - ux * arrowSize * 0.3;
        const baseCy = center.y - uy * arrowSize * 0.3;
        const baseHalf = arrowSize * 0.35;
        ctx.beginPath();
        ctx.moveTo(tipX, tipY);
        ctx.lineTo(baseCx + perpX * baseHalf, baseCy + perpY * baseHalf);
        ctx.lineTo(baseCx - perpX * baseHalf, baseCy - perpY * baseHalf);
        ctx.closePath();
        ctx.fill();
        ctx.stroke();
      }
    }
  }

  // Start dot at the first point — small tertiary dot with a white
  // halo. Anchors "begin here" without reading as a numbered pin.
  // Also handles the single-point case where no line has formed.
  if (points.length >= 1) {
    const startR = Math.max(4, Math.round(shortEdge * 0.0065));
    const startHaloR = startR + Math.max(2, Math.round(startR * 0.4));
    const start = points[0];

    ctx.globalAlpha = 0.9;
    ctx.fillStyle = secondary;
    ctx.beginPath();
    ctx.arc(start.x, start.y, startHaloR, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.fillStyle = tertiary;
    ctx.beginPath();
    ctx.arc(start.x, start.y, startR, 0, Math.PI * 2);
    ctx.fill();

    // Label badge — small tertiary pill above-right of the start
    // dot. Matches the editor (renderEyePath in the Konva stage).
    const label = eyePath.label;
    if (label) {
      const badgeFontSize = Math.max(11, Math.round(shortEdge * 0.018));
      const badgePadding = Math.max(3, Math.round(badgeFontSize * 0.3));
      const badgeOffset = Math.max(6, Math.round(shortEdge * 0.006));
      ctx.font = `bold ${badgeFontSize}px sans-serif`;
      ctx.textBaseline = "top";
      const metrics = ctx.measureText(label);
      const badgeWidth = Math.ceil(metrics.width) + badgePadding * 2;
      const badgeHeight = badgeFontSize + badgePadding * 2;
      const bx = start.x + badgeOffset;
      const by = start.y - badgeHeight - badgeOffset;
      tracePillRect(ctx, bx, by, badgeWidth, badgeHeight, 3);
      ctx.fillStyle = tertiary;
      ctx.globalAlpha = 1;
      ctx.fill();
      ctx.strokeStyle = secondary;
      ctx.lineWidth = 1.5;
      ctx.stroke();
      ctx.fillStyle = secondary;
      ctx.fillText(label, bx + badgePadding, by + badgePadding);
    }
  }

  // Terminal arrowhead at the last point — slightly larger than the
  // in-segment chevrons so the path's end reads as a landing point.
  if (points.length >= 2) {
    const terminalSize = Math.max(10, Math.round(shortEdge * 0.0175));
    const a = points[points.length - 2];
    const b = points[points.length - 1];
    // Match the editor: sample the last Konva-tension segment near
    // its endpoint so the arrow direction follows the curve's actual
    // local tangent.
    let dirX = b.x - a.x;
    let dirY = b.y - a.y;
    if (EYE_PATH_SMOOTH && points.length >= 3) {
      const lastSeg = getKonvaSegment(points, points.length - 2);
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
      ctx.fillStyle = tertiary;
      ctx.strokeStyle = secondary;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(b.x, b.y);
      ctx.lineTo(baseCx + perpX * baseHalf, baseCy + perpY * baseHalf);
      ctx.lineTo(baseCx - perpX * baseHalf, baseCy - perpY * baseHalf);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
    }
  }

  ctx.restore();
}

function drawPinsOnCanvas(ctx, pins, width, height) {
  if (!Array.isArray(pins) || pins.length === 0) {
    return;
  }

  const shortEdge = Math.min(width, height);
  const pinRadius = Math.max(
    MIN_PIN_RADIUS,
    Math.round(shortEdge * PIN_RADIUS_RATIO)
  );
  const haloThickness = Math.max(MIN_HALO, Math.round(pinRadius * HALO_RATIO));
  const fontSize = Math.round(pinRadius * 1.05);

  // Numbered pins use the muted blue (most prominent of the muted
  // family — the numbered badge is the primary critique anchor).
  // See npn-critique-reply-colors.js.
  const pinFill = ANNOTATION_BLUE;
  const pinText = ANNOTATION_HALO;
  const halo = ANNOTATION_HALO;

  ctx.save();
  ctx.font = `700 ${fontSize}px sans-serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";

  for (const pin of pins) {
    const x = (pin.xPct / 100) * width;
    const y = (pin.yPct / 100) * height;

    // Drop shadow underneath the halo so the pin pops against any
    // background tone. Cleared before drawing the inner circle and text
    // so they render cleanly.
    ctx.shadowColor = "rgba(0, 0, 0, 0.55)";
    ctx.shadowBlur = haloThickness * 2;
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = Math.round(haloThickness / 2);

    ctx.beginPath();
    ctx.arc(x, y, pinRadius + haloThickness, 0, Math.PI * 2);
    ctx.fillStyle = halo;
    ctx.fill();

    ctx.shadowColor = "transparent";
    ctx.shadowBlur = 0;
    ctx.shadowOffsetY = 0;

    ctx.beginPath();
    ctx.arc(x, y, pinRadius, 0, Math.PI * 2);
    ctx.fillStyle = pinFill;
    ctx.fill();

    ctx.fillStyle = pinText;
    ctx.fillText(String(pin.number), x, y);
  }

  ctx.restore();
}

// JPEG by default (smaller files for photos; pins on a photo background
// don't benefit from PNG's lossless encoding). Throws on canvas taint —
// the modal converts that to a friendly export-failed message.
export function exportCanvasToBlob(
  canvas,
  { type = "image/jpeg", quality = JPEG_QUALITY } = {}
) {
  return new Promise((resolve, reject) => {
    try {
      canvas.toBlob(
        (blob) => {
          if (blob) {
            resolve(blob);
          } else {
            reject(new Error("visual_notes: toBlob returned null"));
          }
        },
        type,
        quality
      );
    } catch (e) {
      // SecurityError when the canvas is tainted by a cross-origin image
      // without proper CORS headers.
      reject(e);
    }
  });
}

// Goes through Discourse's standard upload endpoint. `synchronous=true`
// makes the response carry the upload record directly instead of
// requiring a MessageBus subscription. `type=composer` selects the
// composer-style extension whitelist + size limits.
export function uploadVisualNotesBlob(blob, filename) {
  const formData = new FormData();
  formData.append("file", blob, filename);
  formData.append("type", "composer");
  formData.append("synchronous", "true");

  return ajax("/uploads.json", {
    type: "POST",
    data: formData,
    processData: false,
    contentType: false,
  });
}
