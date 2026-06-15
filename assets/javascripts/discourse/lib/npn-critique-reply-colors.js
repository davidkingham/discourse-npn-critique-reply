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

// Legacy umbrella token. Still exported as a fallback default for
// caller signatures (drawArrowOnCanvas, buildArrowGroup) that take
// `tertiary` as an option — the modal always passes an explicit
// per-kind colour now, so this default is rarely reached in
// practice. Prefer the kind-specific tokens below for new code.
export const ANNOTATION_BLUE = "#3e7ea3";

// Notes / pins — deeper muted teal-blue. The clearest, most
// prominent annotation marker (filled circle with a white number).
// Distinct from the eye-path pale cyan so the two no longer read
// as variants of the same idea.
export const NOTE_BLUE = "#2d728f";

// Eye Path — pale glacial cyan. Reads as a soft, organic flow line
// rather than a "read this note" marker. Lighter than Notes and
// distinct from the muted indigo used by Direction Arrow so the
// three flow-adjacent tools (eye path, direction, relationship)
// all sit in different colour families.
export const EYE_PATH_PALE_CYAN = "#8fd3e8";

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

// Attention Pull — muted ochre/amber. Observational, not warning-
// like. Slightly lighter than the original saturated ochre so the
// area marker stays subtle alongside the photograph.
export const ATTENTION_PULL_OCHRE = "#c2a15a";

// Strong Area — muted sage-teal. Reads as supportive without
// competing with the photograph's own greens. Lightened so it
// remains visible over green foliage where the previous deeper
// sage tended to blend in.
export const STRONG_AREA_SAGE = "#8fb9a7";

// Direction Arrow — muted blue-violet / periwinkle. Distinct from
// the eye-path pale cyan so the two flow-related kinds read as
// siblings rather than duplicates. "Clear but not loud" per the
// design intent: solid, direct, with a stronger badge weight than
// Relationship but less prominent than a pin's filled badge.
export const DIRECTION_ARROW_INDIGO = "#7478ad";

// Relationship — warm stone / taupe. Distinct from BOTH the eye-
// path cyan AND the direction-arrow periwinkle. Reads as a
// relational connector — a soft tie between two areas — rather
// than as movement or attention. Warm-neutral on purpose so the
// line never competes for attention with the actual subject of
// the photograph; lightened from the previous deeper taupe so the
// marker sits comfortably in the "quieter than Arrow" hierarchy
// slot.
export const RELATIONSHIP_TAUPE = "#bdb49f";

// Shared white halo that wraps strokes for contrast against dark
// imagery. Plain white reads as a clean cue without picking up the
// theme's secondary tint.
export const ANNOTATION_HALO = "#ffffff";

// Subtle dark outer drop-shadow applied to the white halo. The white
// halo alone is invisible on snow / fog / high-key images; a thin
// dark blur radiating outward from the halo gives marks a soft dark
// edge that reads on those backgrounds while staying invisible on
// dark imagery (where the white halo and colored stroke are doing
// all the work). Both the live Konva editor and the exported JPEG
// apply this shadow to every halo, so editor and export match.
export const ANNOTATION_HALO_SHADOW = "rgba(0, 0, 0, 0.32)";

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
