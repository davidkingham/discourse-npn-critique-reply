// Mark-color contrast probe (feasibility prototype).
// =================================================================
//
// Goal: investigate whether the Critique Workspace can pick a useful
// annotation-color hint ("light-mark" vs "dark-mark") automatically
// based on the reference image's brightness — to address visibility
// complaints on extreme images (dark forests, snow scenes, fog, etc.).
//
// NOT wired into the UI. Callers can opt in (e.g. when
// npn_critique_reply_debug_enabled is on) and log the result; the
// existing annotation pipeline keeps doing exactly what it does
// today.
//
// Design notes:
//
//   * Sampling uses a downscaled offscreen canvas (64x64 default) so
//     the cost is constant regardless of the source image's
//     resolution. Computed once per image — overall-brightness mode
//     only. Per-annotation local sampling is sketched in
//     `sampleLocalLuminance` but kept opt-in; see the feasibility
//     report below for why local sampling is NOT recommended for the
//     first pass.
//
//   * `drawImage` from an unsafe cross-origin <img> will taint the
//     canvas and throw `SecurityError` on `getImageData`. We catch
//     and return `{ recommendation: "fallback", ... }` so callers
//     never see an exception. The existing visual-notes export
//     already requires a non-tainted canvas (it reads the canvas
//     out via toBlob), so the typical-case taint risk is the same
//     class of failure the export already handles — most Discourse
//     uploads are same-origin and safe.
//
//   * Luminance follows BT.709 (Rec. 709 perceptual weights):
//         L = 0.2126*R + 0.7152*G + 0.0722*B
//     Then averaged over the downscaled sample. R/G/B are sRGB
//     (0..255) — we don't gamma-correct because we're choosing a
//     coarse "light vs dark" hint, not measuring a colorimetric
//     property. Adding a gamma step adds CPU without changing the
//     recommendation.
//
//   * Thresholds use a small dead-zone around the middle so
//     borderline images don't oscillate between recommendations on
//     reload. Below 96/255 → image is dark → mark should be light.
//     Above 160/255 → image is bright → mark should be dark.
//     Inside the dead-zone → "fallback" (caller should use a
//     halo-stroked default that works on either background).

const DEFAULT_SAMPLE_SIZE = 64;
const DARK_THRESHOLD = 96; // <- average luminance below this → "light-mark"
const LIGHT_THRESHOLD = 160; // <- average luminance above this → "dark-mark"

// Convenience constants the caller can switch on. Strings (not enums)
// so they show up cleanly in console logs and in any future stored
// metadata.
export const MARK_CONTRAST = Object.freeze({
  LIGHT: "light-mark",
  DARK: "dark-mark",
  FALLBACK: "fallback",
});

// Probe the average luminance of an HTMLImageElement and return a
// recommendation. Synchronous — assumes the caller has already
// awaited image load (img.complete && naturalWidth > 0). Failures
// (tainted canvas, no naturalWidth) collapse to "fallback".
//
// Returns: { recommendation, luminance, sampledWidth, sampledHeight, error }
//   - recommendation: "light-mark" | "dark-mark" | "fallback"
//   - luminance: 0..255 (or null on failure)
//   - sampledWidth/Height: downscaled canvas dims actually used
//   - error: string when something blocked sampling, null otherwise
export function probeImageContrast(
  image,
  { sampleSize = DEFAULT_SAMPLE_SIZE } = {}
) {
  if (!image || !image.complete || !image.naturalWidth) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: 0,
      sampledHeight: 0,
      error: "image-not-ready",
    };
  }

  // Maintain aspect ratio so super-wide / super-tall images don't get
  // squashed in a way that biases the luminance toward one edge.
  const w = image.naturalWidth;
  const h = image.naturalHeight;
  const longEdge = Math.max(w, h);
  const scale = longEdge > sampleSize ? sampleSize / longEdge : 1;
  const sw = Math.max(1, Math.round(w * scale));
  const sh = Math.max(1, Math.round(h * scale));

  const canvas = document.createElement("canvas");
  canvas.width = sw;
  canvas.height = sh;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: sw,
      sampledHeight: sh,
      error: "no-2d-context",
    };
  }

  try {
    ctx.drawImage(image, 0, 0, sw, sh);
  } catch (e) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: sw,
      sampledHeight: sh,
      error: `drawImage:${e?.name ?? "Error"}`,
    };
  }

  let pixels;
  try {
    pixels = ctx.getImageData(0, 0, sw, sh).data;
  } catch (e) {
    // Most common failure: canvas tainted because the <img> was
    // loaded without crossOrigin and the host isn't the same origin.
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: sw,
      sampledHeight: sh,
      error: `getImageData:${e?.name ?? "Error"}`,
    };
  }

  const luminance = averageLuminance(pixels);
  return {
    recommendation: recommendationForLuminance(luminance),
    luminance,
    sampledWidth: sw,
    sampledHeight: sh,
    error: null,
  };
}

// Sample a small region of the image under an annotation point.
// Returns the same shape as probeImageContrast. This is a
// per-annotation probe — call ONLY at annotation-commit time, not
// during drag.
//
// `xPct` / `yPct` are 0..100 (the existing annotation coord space).
// `radiusPx` is the sample radius in source-image pixels (defaulted
// to ~5% of the short edge so we get enough context but stay local).
//
// Caveat: only useful for point-like annotations (numbered notes,
// arrow tail/head). Lines/curves/areas cover varied luminance and
// would need an aggregate per-sub-region — significantly more
// complex and unlikely to produce a meaningfully different
// recommendation than overall brightness in the common case. See
// the report below.
export function sampleLocalLuminance(
  image,
  xPct,
  yPct,
  { radiusPx } = {}
) {
  if (!image || !image.complete || !image.naturalWidth) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: 0,
      sampledHeight: 0,
      error: "image-not-ready",
    };
  }

  const w = image.naturalWidth;
  const h = image.naturalHeight;
  const r = Math.max(8, Math.round(radiusPx ?? Math.min(w, h) * 0.05));
  const cx = Math.round((xPct / 100) * w);
  const cy = Math.round((yPct / 100) * h);
  const sx = Math.max(0, cx - r);
  const sy = Math.max(0, cy - r);
  const sw = Math.min(w - sx, r * 2);
  const sh = Math.min(h - sy, r * 2);
  if (sw <= 0 || sh <= 0) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: 0,
      sampledHeight: 0,
      error: "empty-region",
    };
  }

  const canvas = document.createElement("canvas");
  // We further downscale the sampled region so per-annotation cost
  // is still a tiny fixed amount even on a 4000px image.
  const localSampleSize = 32;
  const longEdge = Math.max(sw, sh);
  const scale = longEdge > localSampleSize ? localSampleSize / longEdge : 1;
  const cw = Math.max(1, Math.round(sw * scale));
  const ch = Math.max(1, Math.round(sh * scale));
  canvas.width = cw;
  canvas.height = ch;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: cw,
      sampledHeight: ch,
      error: "no-2d-context",
    };
  }
  try {
    ctx.drawImage(image, sx, sy, sw, sh, 0, 0, cw, ch);
  } catch (e) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: cw,
      sampledHeight: ch,
      error: `drawImage:${e?.name ?? "Error"}`,
    };
  }
  let pixels;
  try {
    pixels = ctx.getImageData(0, 0, cw, ch).data;
  } catch (e) {
    return {
      recommendation: MARK_CONTRAST.FALLBACK,
      luminance: null,
      sampledWidth: cw,
      sampledHeight: ch,
      error: `getImageData:${e?.name ?? "Error"}`,
    };
  }

  const luminance = averageLuminance(pixels);
  return {
    recommendation: recommendationForLuminance(luminance),
    luminance,
    sampledWidth: cw,
    sampledHeight: ch,
    error: null,
  };
}

function averageLuminance(rgbaPixels) {
  // BT.709 weights. Skip alpha because all pixels from drawImage
  // are opaque for typical JPEG / PNG sources (and any partially
  // transparent stamp won't meaningfully shift the average over
  // thousands of samples).
  let total = 0;
  const count = rgbaPixels.length / 4;
  for (let i = 0; i < rgbaPixels.length; i += 4) {
    total +=
      0.2126 * rgbaPixels[i] +
      0.7152 * rgbaPixels[i + 1] +
      0.0722 * rgbaPixels[i + 2];
  }
  return total / count;
}

function recommendationForLuminance(luminance) {
  if (luminance < DARK_THRESHOLD) {
    return MARK_CONTRAST.LIGHT;
  }
  if (luminance > LIGHT_THRESHOLD) {
    return MARK_CONTRAST.DARK;
  }
  return MARK_CONTRAST.FALLBACK;
}

// Dev-only one-shot logger. Call once when the workspace image
// finishes loading. Returns the probe result so the caller can
// also tuck it into a tracked field if it wants to render a
// future Auto pill.
export function logImageContrastProbe(image, label = "reference") {
  const result = probeImageContrast(image);
  // eslint-disable-next-line no-console
  console.info("[npn-critique-reply] mark-contrast probe", {
    label,
    recommendation: result.recommendation,
    luminance:
      result.luminance == null ? null : Math.round(result.luminance),
    sampledWidth: result.sampledWidth,
    sampledHeight: result.sampledHeight,
    error: result.error,
  });
  return result;
}
