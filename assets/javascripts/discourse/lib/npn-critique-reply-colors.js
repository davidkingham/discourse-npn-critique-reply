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

// Pins and eye path share the cyan-blue family. Pins are the most
// prominent (solid filled badge); eye path is "elegant and
// directional". Crop has its own pair (see CROP_EDITOR_* and
// CROP_EXPORT_* below) — it switches between an active blue-gray
// in the editor and a quieter neutral gray in the finished JPEG.
export const ANNOTATION_BLUE = "#3e7ea3";

// Crop — editor styling. Muted blue-gray so the perimeter still
// reads as an active editable tool inside the modal, but pulled a
// touch away from the eye-path cyan-blue so the two don't trade
// identity. Avoids the brighter cyan that read as "highlight" /
// "selection" rather than "crop frame."
export const CROP_EDITOR_BLUE_GRAY = "#4a8fa6";

// Crop — exported JPEG styling. Neutral medium gray so the crop
// boundary reads as a finished framing suggestion, not as an
// active editing tool. Distinct from EVERY other annotation
// colour so the crop fades back into the photograph while the
// notes / arrows / areas remain the focal annotations.
export const CROP_EXPORT_GRAY = "#9a9a9a";

// Crop — exported JPEG corner markers (the L-brackets) + midpoint
// edge bars. A lighter gray than the boundary so the corner /
// midpoint markers read as "frame furniture" sitting on top of
// the boundary rather than as a competing element. Mirrors the
// editor's bracket-on-perimeter relationship: brackets are the
// salient visual element, perimeter is the supporting connector.
export const CROP_EXPORT_LIGHT_GRAY = "#d4d4d4";

// Attention Pull — muted ochre. Distinct from the pin/eye/crop blue
// and not as alarm-bell-bright as a saturated orange.
export const ATTENTION_PULL_OCHRE = "#b8852f";

// Strong Area — muted sage. Distinct from attention pull and reads
// as supportive without competing with the photograph's own greens.
export const STRONG_AREA_SAGE = "#6e9c81";

// Direction Arrow — muted indigo / blue-violet. Distinct from the
// eye-path cyan-blue so the two flow-related kinds read as siblings
// rather than duplicates. "Clear but not loud" per the design intent:
// solid, direct, with a stronger badge weight than Relationship but
// less prominent than a pin's filled badge.
export const DIRECTION_ARROW_INDIGO = "#5f63a7";

// Relationship — warm gray / taupe. Distinct from BOTH the eye-path
// cyan-blue AND the direction-arrow indigo. Reads as a relational
// connector — a soft tie between two areas — rather than as movement
// or attention. Picked warm-neutral on purpose so the line never
// competes for attention with the actual subject of the photograph.
export const RELATIONSHIP_TAUPE = "#8a7866";

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
