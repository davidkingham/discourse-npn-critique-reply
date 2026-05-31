// Softened visual-annotation palette.
// =================================================================
//
// Tuned for NPN's quieter critique style. Distinct hues per
// annotation kind but pulled back from the bright theme defaults so
// the photograph stays the focal point. Both the live Konva editor
// (npn-critique-reply-konva-stage.js) and the exported JPEG
// (npn-critique-reply-visual-notes.js) read from this module, so the
// posted image matches what the user saw while annotating.
//
// Hex values are fixed (not pulled from Discourse CSS variables) so
// the annotation look stays consistent across themes — themes will
// vary `--tertiary`, `--bookmark`, `--success` widely, and we want
// critiques to read the same regardless of the host theme.

// Pins, eye path, and crop all share the cyan-blue family. Pins are
// the most prominent of the three (solid filled badge); eye path is
// "elegant and directional"; crop is the quietest large annotation.
export const ANNOTATION_BLUE = "#3e7ea3";

// Attention Pull — muted ochre. Distinct from the pin/eye/crop blue
// and not as alarm-bell-bright as a saturated orange.
export const ATTENTION_PULL_OCHRE = "#b8852f";

// Strong Area — muted sage. Distinct from attention pull and reads
// as supportive without competing with the photograph's own greens.
export const STRONG_AREA_SAGE = "#6e9c81";

// Shared white halo that wraps strokes for contrast against dark
// imagery. Plain white reads as a clean cue without picking up the
// theme's secondary tint.
export const ANNOTATION_HALO = "#ffffff";

// Dim overlay color for the area outside an active crop. Slightly
// less opaque than full 0.5 so the surrounding image remains
// readable while still clearly de-emphasised.
export const CROP_DIM_FILL = "rgba(0, 0, 0, 0.42)";

// Translucent fill opacity for the area-style annotations
// (attention pull, strong area). The shape has the same fill colour
// in both states; only the opacity changes so selection reads as
// "more present" without changing colour.
export const AREA_FILL_OPACITY_UNSELECTED = 0.12;
export const AREA_FILL_OPACITY_SELECTED = 0.2;

// Badge fill alpha — applied to the same hue so the A1 / S1 / pin
// number reads as part of the marker family. Solid for pins (the
// number is the marker), slightly translucent for AP / SA badges
// where the badge sits beside a larger shape.
export const PIN_BADGE_OPACITY = 1.0;
export const AREA_BADGE_OPACITY = 0.92;
