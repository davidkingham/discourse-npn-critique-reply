import { Textarea } from "@ember/component";
import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { tracked } from "@glimmer/tracking";
import UserAutocompleteResults from "discourse/components/user-autocomplete-results";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { ajax } from "discourse/lib/ajax";
import dAutocomplete from "discourse/ui-kit/modifiers/d-autocomplete";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { getURLWithCDN } from "discourse/lib/get-url";
import TextareaTextManipulation, {
  TextareaAutocompleteHandler,
} from "discourse/lib/textarea-text-manipulation";
import userSearch from "discourse/lib/user-search";
import Composer from "discourse/models/composer";
import Draft from "discourse/models/draft";
import { and, eq, or } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import NpnCritiqueImageReference from "../npn-critique-image-reference";
import {
  critiqueStyleLabel,
  feedbackFocusLabel,
} from "../../lib/npn-critique-reply-labels";
import { getQuestionsToConsider } from "../../lib/npn-critique-reply-prompts";
import {
  NPN_ERROR_EVENT,
  recentPluginErrors,
} from "../../lib/npn-critique-reply-error-bus";
import {
  postCritique as postCritiqueRequest,
  updateCritique as updateCritiqueRequest,
} from "../../lib/npn-critique-reply-api";
import {
  buildVisualNotesCanvas,
  exportCanvasToBlob,
  loadImageForExport,
  uploadVisualNotesBlob,
} from "../../lib/npn-critique-reply-visual-notes";
import {
  buildProcessingExamplePayload,
  composeProcessingExampleRaw,
  normalizeProcessingExampleFromServer,
  processingExampleFilename,
  processingExampleSourceFilename,
  uploadProcessingExampleFile,
  wrapProcessingExampleError,
} from "../../lib/npn-critique-reply-processing-example";
import {
  MAX_ATTENTION_PULL_COUNT,
  MAX_DIRECTION_ARROW_COUNT,
  MAX_EYE_PATH_COUNT,
  MAX_EYE_PATH_POINTS,
  MAX_RELATIONSHIP_ARROW_COUNT,
  MAX_STRONG_AREA_COUNT,
  annotationsToAttentionPulls,
  annotationsToDirectionArrows,
  annotationsToPins,
  annotationsToRelationshipArrows,
  annotationsToStrongAreas,
  annotationToCrop,
  annotationToEyePath,
  attentionPullsToAnnotations,
  directionArrowsToAnnotations,
  nextEyePathId,
  nextEyePathLabel,
  buildVisualAnnotationPayload,
  cropToAnnotation,
  eyePathToAnnotation,
  eyePathsToAnnotations,
  nextAttentionPullLabel,
  nextDirectionArrowLabel,
  nextRelationshipArrowLabel,
  nextStrongAreaLabel,
  pinsToAnnotations,
  relationshipArrowsToAnnotations,
  strongAreasToAnnotations,
} from "../../lib/npn-critique-reply-annotation-schema";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import {
  DRAFT_STATUS,
  DraftAutosaver,
  deleteDraft as deleteServerDraft,
  loadDraft as loadServerDraft,
} from "../../lib/npn-critique-reply-drafts";

// Pipe-separated id lists from Discourse `group_list` settings. Mirrors
// the helper in the start-button component; kept inline so the two
// gating layers stay independent.
function parseIdList(value) {
  if (!value) {
    return [];
  }
  return value
    .toString()
    .split("|")
    .map((s) => parseInt(s, 10))
    .filter((n) => Number.isInteger(n) && n > 0);
}

// localStorage key for the "More ideas" expanded state. The legacy
// `prompts-hidden` / `prompts-expanded` keys are gone — the section
// no longer collapses entirely (it's quiet enough to leave open),
// and the expanded view is now "show More ideas groups" instead of
// "show all 6 prompts vs first 3."
const STORAGE_KEY_MORE_IDEAS = "npn-critique-reply.more-ideas-expanded";

// Large-image view enum. Drives which image the left pane shows at
// full size — the photographer's reference (with annotations) or the
// critic's uploaded processing example (no annotations in v1).
// String values are persisted in drafts so they need to stay stable.
const LARGE_IMAGE_VIEW_REFERENCE = "reference";
const LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE = "processing_example";
const LARGE_IMAGE_VIEWS = Object.freeze([
  LARGE_IMAGE_VIEW_REFERENCE,
  LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE,
]);

// Pull the numeric suffix off an id like "attention_pull_3" → 3. Used
// only during draft restore so newly-created markers don't collide
// with restored ones.
function extractIdSuffix(id) {
  const m = typeof id === "string" ? id.match(/_(\d+)$/) : null;
  return m ? parseInt(m[1], 10) : null;
}

// Safe localStorage helpers — Safari private mode, sandboxed iframes,
// and disabled storage all throw on access. We always fall back rather
// than break the modal.
function readBool(key, fallback) {
  try {
    const raw = window.localStorage?.getItem(key);
    if (raw === null || raw === undefined) {
      return fallback;
    }
    return raw === "true";
  } catch (_e) {
    return fallback;
  }
}

function writeBool(key, value) {
  try {
    window.localStorage?.setItem(key, value ? "true" : "false");
  } catch (_e) {
    // Storage unavailable / quota / disabled — silently skip.
  }
}

// Critique workspace modal. Two-column on desktop, stacked on mobile.
//
// New in this step: "Post Critique" creates a real Discourse reply via a
// plugin endpoint that wraps PostCreator. The composer is no longer the
// destination — the workspace IS the writing surface. We keep an "Open
// normal reply" escape hatch (with a confirmation when the textarea has
// unsaved text) so users can always fall back to the standard composer.
//
// Step boundaries:
//   - No markup tools, no DEditor, no ProseMirror.
//   - No custom post type — the reply is a normal Discourse post.
//   - We never bypass Guardian or PostCreator validations (server checks).
//   - `critiqueText` is modal-local only; we don't autosave anywhere.

// Broadcast on this event whenever a saved server-side draft is created
// or cleared from inside the modal. The footer Start button and the OP
// invitation panel listen and flip their copy to / from "Resume Draft"
// without waiting for a page navigation. Payload: `{ topicId, hasDraft }`.
export const DRAFT_CHANGED_EVENT = "npn-critique-reply:draft-changed";

// Per-image annotation snapshots. Shallow-clone each annotation array
// so a saved snapshot doesn't share refs with the active tracked
// state — otherwise a later push into the active array would mutate
// the snapshot in place and corrupt the per-image cache.
function cloneAnnotationArray(arr) {
  if (!Array.isArray(arr)) {
    return [];
  }
  return arr.map((a) => (a && typeof a === "object" ? { ...a } : a));
}

// Eye paths have a nested `points` array that needs its own clone so
// editing the active path doesn't reach back through the snapshot.
function cloneEyePathsForSnapshot(paths) {
  if (!Array.isArray(paths)) {
    return [];
  }
  return paths.map((p) => ({
    ...p,
    points: Array.isArray(p.points)
      ? p.points.map((pt) => ({ ...pt }))
      : [],
  }));
}

// Used in debug logs only — quick count of annotations across all
// arrays in a snapshot.
function countSnapshotAnnotations(snapshot) {
  if (!snapshot) {
    return 0;
  }
  return (
    (snapshot.notes?.length ?? 0) +
    (snapshot.crop ? 1 : 0) +
    (snapshot.eyePaths?.length ?? 0) +
    (snapshot.attentionPulls?.length ?? 0) +
    (snapshot.strongAreas?.length ?? 0) +
    (snapshot.directionArrows?.length ?? 0) +
    (snapshot.relationshipArrows?.length ?? 0)
  );
}

function snapshotHasAnnotations(snapshot) {
  return countSnapshotAnnotations(snapshot) > 0;
}

// Annotation token shape — mirrors the cooked-post decorator's
// TOKEN_PATTERN so the preview shows references using the same family
// of badge styles. Variants resolve to CSS classes named in
// `npn-critique-reply.scss` (.npn-annotation-badge--{variant}).
// `Crop \d` covers the multi-crop labels stamped by the modal once a
// critique has 2+ crops; the legacy `Crop` / `CROP` forms still
// match for single-crop critiques and posts written before the
// rename.
const PREVIEW_TOKEN_PATTERN =
  /\[([1-9]\d{0,2}|Crop \d{1,2}|Crop|CROP|[ASDRE]\d{1,3})\]/g;

// Same pattern used by the per-image paragraph grouper. Kept as a
// separate constant because matchAll() on a single shared regex
// would clobber the preview parser's lastIndex when both run in the
// same render cycle.
const PARAGRAPH_TOKEN_PATTERN =
  /\[([1-9]\d{0,2}|Crop \d{1,2}|Crop|CROP|[ASDRE]\d{1,3})\]/g;

function badgeVariantForLabel(label) {
  if (/^\d/.test(label)) {
    return "note";
  }
  if (label === "Crop" || label === "CROP" || /^Crop \d/.test(label)) {
    return "crop";
  }
  const prefix = label[0];
  switch (prefix) {
    case "A":
      return "attention";
    case "S":
      return "strong-area";
    case "D":
      return "direction";
    case "R":
      return "relationship";
    case "E":
      return "eye-path";
    default:
      return null;
  }
}

// Build the preview's annotated-text HTML directly so template
// whitespace can't leak into a `pre-wrap` container and visually
// indent badges relative to the surrounding prose. Paragraphs split
// on blank lines (`\n\n+`); single newlines inside a paragraph
// become `<br>`. Badges become styled <span>s with the same .npn-
// annotation-badge classes the cooked-post decorator uses, so the
// preview reads as a faithful approximation of the final post.
function buildPreviewTextHtml(text) {
  const paragraphs = text.split(/\n{2,}/);
  return paragraphs
    .map(buildPreviewParagraphHtml)
    .filter((p) => p && p.length > 0)
    .join("");
}

function buildPreviewParagraphHtml(paragraph) {
  if (!paragraph.trim()) {
    return "";
  }
  PREVIEW_TOKEN_PATTERN.lastIndex = 0;
  const parts = [];
  let cursor = 0;
  for (const match of paragraph.matchAll(PREVIEW_TOKEN_PATTERN)) {
    const variant = badgeVariantForLabel(match[1]);
    if (!variant) {
      continue;
    }
    if (match.index > cursor) {
      parts.push(escapePreviewHtml(paragraph.slice(cursor, match.index)));
    }
    const label = match[1];
    parts.push(
      `<span class="npn-annotation-badge npn-annotation-badge--${variant}"` +
        ` data-label="${escapePreviewAttr(label)}">` +
        `${escapePreviewHtml(label)}</span>`
    );
    cursor = match.index + match[0].length;
  }
  if (cursor < paragraph.length) {
    parts.push(escapePreviewHtml(paragraph.slice(cursor)));
  }
  if (parts.length === 0) {
    parts.push(escapePreviewHtml(paragraph));
  }
  const inner = parts.join("").replace(/\n/g, "<br>");
  return `<p class="npn-critique-reply-modal__preview-paragraph">${inner}</p>`;
}

function escapePreviewHtml(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapePreviewAttr(text) {
  return escapePreviewHtml(text).replace(/"/g, "&quot;");
}

export default class NpnCritiqueReplyModal extends Component {
  @service siteSettings;
  @service currentUser;
  @service toasts;
  @service dialog;
  @service appEvents;

  // Set by the Textarea's {{didInsert}} hook below. `#textManipulation`
  // is the Discourse helper that owns cursor/selection logic for
  // programmatic writes (link insertion); `#textarea` is just the DOM
  // node so we can dispatch a synthetic `input` event after writes
  // and so the autocomplete `afterComplete` callback can refocus.
  #textarea = null;
  #textManipulation = null;

  // Inline Insert-link form state. The form lives INSIDE this modal
  // (it replaces the toolbar row when open) instead of opening a
  // DModal on top — Discourse's modal service replaces the active
  // modal rather than stacking it, so a sub-modal would dismiss the
  // critique workspace and any unflushed state. Keeping the helper
  // inline avoids that entirely.
  //   linkFormOpen     — toggles the form's visibility
  //   linkFormUrl      — bound to the URL input
  //   linkFormText     — bound to the optional link-text input; the
  //                      currently-selected textarea text pre-fills it
  //                      when the form opens
  //   _linkPreservedSelection — { start, end } captured at open time
  //                      so a re-focus of the URL input doesn't lose
  //                      the textarea's selection range
  @tracked linkFormOpen = false;
  @tracked linkFormUrl = "";
  @tracked linkFormText = "";
  _linkPreservedSelection = null;

  // Draft state ----------------------------------------------------------
  @tracked critiqueText = "";

  // Post Critique state. `isPosting` disables the action buttons + close
  // path while the request is in flight; `errorMessage` is shown inline
  // above the textarea on failure so the user's draft is preserved.
  @tracked isPosting = false;
  @tracked errorMessage = null;

  // Preview Critique state. The primary footer action enters this
  // intermediate view before any post / update request fires, so the
  // critic can see the composed result first. `_previewSnapshot` holds
  // the locally-rendered preview payload (flattened visual notes as an
  // object URL, processing example URL, trimmed text) so we don't have
  // to re-export on every render. `previewBuilding` gates the button
  // while the canvas export runs.
  @tracked previewMode = false;
  @tracked previewBuilding = false;
  @tracked _previewSnapshot = null;
  // Inline validation message (shown when user clicks Post Critique with
  // empty textarea — distinct from server errors).
  @tracked validationMessage = null;
  // Async status during multi-stage flows (preparing visual notes,
  // uploading, posting). Drives a separate inline banner so the critic
  // sees progress and can tell why the modal is briefly disabled.
  @tracked statusMessage = null;

  // Version selector state. null means "use the server's default
  // key" — see `selectedVersionKey` getter for the fallback chain.
  // Explicit selectVersion / _restoreDraft / version-aware switches
  // write a concrete key here.
  @tracked _selectedVersionKey = null;

  // Multi-image picker state. Submissions can carry up to 5 images;
  // index 0 is the primary image (and the one the version-selector
  // chain applies to). Each image keeps its own annotations — the
  // active image's state lives in the tracked notes/crop/eyePaths
  // etc. fields, and the per-image snapshot map below holds the
  // others.
  @tracked _selectedImageIndex = 0;

  // Per-image annotation snapshots. Map<number, AnnotationSnapshot>.
  // Plain field (not @tracked) because the active image's tracked
  // fields are what drive the UI; this map is cold storage that
  // gets read/written only during image switches, draft save, draft
  // restore, and Post Critique. AnnotationSnapshot shape matches
  // _snapshotCurrentAnnotations.
  _annotationsByImageIndex = new Map();

  // "More ideas" expansion state for the Questions-to-consider panel.
  // Single dimension now: false (default) → show only the 3 default
  // questions; true → also show the grouped "More ideas" bank below.
  // Persisted to localStorage so the modal remembers the critic's
  // preference across opens. localStorage reads sit inside a try/catch
  // because some browsing contexts (Safari private mode, third-party
  // iframes) throw on access.
  @tracked moreIdeasExpanded = false;

  // Visual Notes / Crop Suggestion state. Modal-local only — never
  // persisted, never sent to the server, never written into the post
  // body. The Konva stage consumes this state and renders.
  //
  //   notes              — pin array { number, xPct, yPct }
  //   selectedPinNumber  — stable; gaps preserved across removals
  //   crop               — single crop object { xPct, yPct, widthPct,
  //                         heightPct, aspectRatio } or null
  //   cropSelected       — true when the crop is the "current" annotation
  //                         for toolbar purposes (mutex with pin select)
  //   visualMode         — null | "numbered_notes" | "crop_suggestion"
  //                         Exactly one tool active at a time per spec.
  @tracked notes = [];
  @tracked selectedPinNumber = null;
  @tracked crop = null;
  @tracked cropSelected = false;
  @tracked visualMode = null;
  // User-chosen aspect ratio for the crop tool. Applies to new crops
  // and to resize operations on the existing crop. "free" means no
  // constraint. The Konva stage owns the geometry snapping; the modal
  // just tracks the user's intent and propagates it.
  @tracked cropAspectRatio = "free";

  // Eye-path / Visual Flow tool state. `eyePaths` is an array of
  // `{ id, label, points: [{ number, xPct, yPct }], noteText? }`.
  // `selectedEyePathId` is null or the id of the currently-selected
  // path (mirrors the attention-pull / strong-area selection pattern
  // since there are multiple paths now). `_activeEyePathId` tracks
  // the path being constructed in the current eye_path mode session
  // — set on the first click that starts a new path, cleared when
  // leaving eye_path mode so a re-entry begins a new session.
  @tracked eyePaths = [];
  @tracked selectedEyePathId = null;
  _activeEyePathId = null;
  // Track that the second-point popover has already opened for the
  // current path session. Reset on each entry into eye_path mode so
  // each new path triggers exactly one description prompt.
  _eyePathStarterInserted = false;

  // Attention Pull state. `attentionPulls` is an array of
  // `{ id, xPct, yPct, widthPct, heightPct }`. `selectedAttentionPullId`
  // is null or the id of the currently-selected marker. The starter
  // text is inserted into the textarea once per modal session on the
  // FIRST attention pull (no per-marker insertion).
  @tracked attentionPulls = [];
  @tracked selectedAttentionPullId = null;
  // Monotonic id counter — never decrements, so removed-then-recreated
  // markers get fresh ids. Labels are independent (max-suffix+1 of
  // current pulls); see `nextAttentionPullLabel` in the schema.
  _attentionPullIdCounter = 0;

  // Strong Area state. Twin of attention pull: same shape, same
  // popover pattern, different kind/label/styling. Markers are
  // observational/supportive — the positive counterpart to attention
  // pull.
  @tracked strongAreas = [];
  @tracked selectedStrongAreaId = null;
  _strongAreaIdCounter = 0;

  // Direction Arrow state. Drag-to-create like attention pull, but
  // the stored shape is two endpoints (x1/y1 → x2/y2) instead of a
  // bounding rect. `D<N>` labels. Same popover-on-create flow as
  // attention pull: open near the head (end) point on placement.
  @tracked directionArrows = [];
  @tracked selectedDirectionArrowId = null;
  _directionArrowIdCounter = 0;

  // Relationship Arrow state. Twin of Direction Arrow but renders
  // with arrowheads on BOTH ends and uses `R<N>` labels — for "these
  // areas relate / echo / balance / compete with each other" instead
  // of one-way direction.
  @tracked relationshipArrows = [];
  @tracked selectedRelationshipArrowId = null;
  _relationshipArrowIdCounter = 0;

  // Note popovers for attention pull and eye path mirror the pin
  // popover pattern: open immediately after the user creates / first
  // commits the annotation, capture optional descriptive text, append
  // to the textarea on Add note, do nothing on Skip. State shape:
  //   { id, anchorXPct, anchorYPct }
  // for attention pull (id matches the pull's), and
  //   { anchorXPct, anchorYPct }
  // for eye path. anchorXPct/anchorYPct are relative to the image and
  // drive the popover's on-image positioning.
  @tracked pendingAttentionPullPopover = null;
  @tracked pendingAttentionPullPopoverText = "";
  @tracked pendingStrongAreaPopover = null;
  @tracked pendingStrongAreaPopoverText = "";
  @tracked pendingEyePathPopover = null;
  @tracked pendingEyePathPopoverText = "";
  // Arrow popovers anchor at the arrowhead (x2/y2 for both kinds —
  // for relationship arrows either end would work, but we pin to
  // the just-released endpoint for consistency with the drag motion).
  @tracked pendingDirectionArrowPopover = null;
  @tracked pendingDirectionArrowPopoverText = "";
  @tracked pendingRelationshipArrowPopover = null;
  @tracked pendingRelationshipArrowPopoverText = "";
  // Crop popover — anchors at the centre of the crop rectangle so the
  // textbox doesn't visually compete with the dimmed area outside it.
  @tracked pendingCropPopover = null;
  @tracked pendingCropPopoverText = "";

  // When set, a pin was just placed and the inline note popover is
  // open near it. Holds { number, xPct, yPct } — the same shape the
  // image-reference uses to position the popover. The pin itself
  // already exists in `this.notes`; this property is purely UI state
  // for the popover. Going null closes the popover.
  @tracked pendingPin = null;
  // Bound to the popover's input field. Cleared whenever pendingPin
  // resets so the next pin starts with an empty input.
  @tracked pendingPinNoteText = "";

  // Set to "post" or "edit" when the last failure came from the visual-
  // notes pipeline (load/export/upload). The error banner shows a
  // matching fallback button only when this is set. Cleared on every
  // new action attempt and on success.
  @tracked visualNotesFailureContext = null;

  // ---- Self-service diagnostics --------------------------------------
  //
  // When the user hits a failure that's hard to diagnose remotely (visual
  // notes upload, post creation, draft restore, …), the modal stashes a
  // structured snapshot here. The error banner exposes a small "Copy
  // diagnostic" button that copies a markdown code block of the whole
  // report — the user pastes it back to us in one click instead of us
  // walking them through opening devtools + reading the console.
  //
  // Snapshot rolls forward as the user works:
  //   • _lastExportDiagnostic   — set by the visual-notes export step
  //   • _lastUploadDiagnostic   — set by the upload step
  //   • _lastFailureReport      — populated when something throws; the
  //                                copy button reads from this
  //   • _errorHistory           — last N recorded errors so chained
  //                                failures (e.g. draft autosave failing
  //                                BEFORE post submit) are all visible
  //                                in the report
  @tracked _lastFailureReport = null;
  _lastExportDiagnostic = null;
  _lastUploadDiagnostic = null;
  _errorHistory = [];
  _unhandledRejectionHandler = null;
  _windowErrorHandler = null;

  // -- Processing Example state ----------------------------------------
  //
  // Workflow: critic downloads the reference image, processes it
  // externally, uploads one example. Stored separately from visual
  // notes — different lifecycle, different validation, no canvas
  // baking. See npn-critique-reply-processing-example.js for the
  // post-body composition + payload helpers.
  //
  //   processingExample          — flat client model:
  //                                 { sourceImageVersionKey, sourceImageVersionLabel,
  //                                   uploadId, url, shortUrl, filename }
  //                                 or null when no example is attached.
  //   processingExampleUploading — true while an upload request is in
  //                                flight (disables the controls).
  //   processingExampleError     — { stage, message } when the last
  //                                upload failed; cleared on retry.
  @tracked processingExample = null;
  @tracked processingExampleUploading = false;
  @tracked processingExampleError = null;

  // -- Mobile disclosure state -----------------------------------------
  //
  // On narrow viewports the workspace collapses two compact areas
  // behind tap-to-expand summaries so the user reaches the writing
  // area sooner. State is shared across viewports — the disclosure
  // BEHAVIOUR is gated entirely by the CSS media query, so toggling
  // these on a wide screen is a no-op while still tracking intent
  // for a later resize.
  //
  //   mobileVisualToolsOpen        — controls the Visual tools panel
  //                                  (toolbar + secondary row). Defaults
  //                                  to false; auto-set to true on
  //                                  restore when annotations exist.
  //   mobileProcessingExampleOpen  — controls the Processing Example
  //                                  panel at the very bottom of the
  //                                  modal. Defaults to false so the
  //                                  workspace lands quietly. Auto-set
  //                                  to true on restore when an upload
  //                                  exists.
  @tracked mobileVisualToolsOpen = false;
  @tracked mobileProcessingExampleOpen = false;

  // -- Visual Focus Mode -----------------------------------------------
  //
  // Optional layout mode that hides the writing pane and lets the
  // image use most of the modal width. Useful on smaller laptops
  // where the default two-pane split leaves the image too small for
  // precise annotation work (per beta feedback). It's a LAYOUT
  // toggle — annotations, text, drafts, processing example, and
  // tool state all persist across enter/exit.
  //
  // The Konva stage tracks its containing `<img>` element via a
  // ResizeObserver, so widening the image-col when this flag flips
  // automatically resizes the stage and re-positions every
  // percent-based annotation. No explicit refit call needed.
  @tracked visualFocusMode = false;

  // -- Area shape sub-mode (Draw Area vs Oval) -------------------------
  //
  // Draw Area is the primary mode — the user loosely outlines the
  // region and the system smooths/closes the shape. Oval is the
  // secondary mode (drag-rectangle → ellipse) for callers who want a
  // clean geometric shape. Shared sub-mode applies to BOTH tools —
  // picking one in Attention keeps it selected when the user toggles
  // to Strong Area and vice versa.
  @tracked areaShapeMode = "path";

  // -- Eye Path interaction mode (Stroke vs Points) --------------------
  //
  // Stroke: drag-to-trace a flowing line through the image (the
  //   long-standing legacy interaction).
  // Points: click-to-add ordered stops connected by a smoothed curve;
  //   each stop renders a small numbered marker.
  // Both modes produce a single `eye_path` annotation; only the
  // serialized `mode` field and the rendered point markers change.
  // Default "stroke" preserves the long-standing behavior so old
  // workflows feel unchanged.
  //
  // Named `eyePathInteractionMode` (not `eyePathMode`) because
  // `get eyePathMode()` already exists and means "is Eye Path the
  // active visual tool?"; an @tracked property of the same name
  // would shadow the getter and break the toolbar toggle.
  @tracked eyePathInteractionMode = "stroke";

  // -- Retrace (path-shape only) ----------------------------------------
  //
  // When the user has a path-shape Attention / Strong Area marker
  // selected, they can click Retrace and draw a fresh outline. The
  // next path drag REPLACES the selected marker's `points` while
  // preserving its id / label / note text. Only one retrace can be
  // in flight at a time, so the two trackeds are mutually exclusive.
  // Tool switches, selection changes, and modal close all cancel.
  @tracked retracingAttentionPullId = null;
  @tracked retracingStrongAreaId = null;

  // -- Photographer's Notes panel state --------------------------------
  //
  // A collapsed-by-default panel between Photographer's Request and
  // Questions to Consider, showing the cooked OP content so critics
  // can refer back to what the photographer wrote without leaving
  // the modal. Fetched lazily on first expand to keep the modal
  // open-cost low; cached in component state for the rest of the
  // session.
  //
  //   _opCookedFetched — true once the GET has resolved (success or
  //                      failure), so we don't refetch on each open.
  //   _opCookedLoading — true while the request is in flight.
  //   _opCookedHtml    — cached cooked HTML or null.
  //   _opCookedError   — true when the fetch failed, so the panel
  //                      can show a fallback instead of nothing.
  @tracked _opCookedLoading = false;
  @tracked _opCookedHtml = null;
  @tracked _opCookedError = false;
  _opCookedFetched = false;
  // Attribution data from /posts/:id.json — populated alongside
  // `_opCookedHtml`. Used to build the `[quote="user, post:N, topic:T"]`
  // attribution line; falls back to the unattributed `[quote]` form
  // when either is missing.
  _opUsername = null;
  _opPostNumber = null;

  // -- Photographer's Notes quote action -------------------------------
  //
  // Floating "Quote" button that appears near a non-empty text
  // selection inside the Photographer's Notes content. Clicking
  // inserts the selected text into the critique textarea wrapped in
  // a Discourse-format `[quote]` block (with attribution when
  // username/post_number are available). Selection detection is
  // scoped to children of `_photographersNotesElement` so selections
  // elsewhere in the modal do not show the button.
  //
  // `_quoteButtonPosition` is null when the button is hidden, or
  // `{ top, left }` (viewport CSS pixels) when visible. Selection
  // text is kept off-tracked in `_quoteSelectionText` so we don't
  // schedule extra renders on every selectionchange tick.
  @tracked _quoteButtonPosition = null;
  _quoteSelectionText = "";
  _photographersNotesElement = null;
  _selectionChangeHandler = null;
  _selectionChangeRaf = null;

  // -- Pane "more below" scroll cue ------------------------------------
  //
  // Each pane (__left-pane, __write-col) flags whether there is more
  // content below the current scroll position. The flag drives a
  // small sticky chevron + fade gradient at the pane's bottom edge
  // so the user notices Optional Visual Notes / Optional Processing
  // Example / Photographer's Notes / Questions when they would
  // otherwise sit below the fold.
  //
  // Detection uses an IntersectionObserver on a sentinel <span>
  // placed at the very end of each pane's scrollable content. The
  // observer's `root` is the pane itself; when the sentinel is
  // intersecting the root viewport, the user is at (or past) the
  // bottom — flag goes false. When it leaves the root viewport
  // (content overflows downward), the flag goes true.
  @tracked _leftPaneHasMore = false;
  @tracked _rightPaneHasMore = false;
  _leftPaneElement = null;
  _rightPaneElement = null;
  _paneSentinelObservers = [];

  // -- Processing Example header popover -------------------------------
  //
  // A small dropdown anchored to the "Processing Example" action in
  // the image-col header. Opens to show Download Reference Image +
  // Upload Processing Example (or Replace/Remove when an upload
  // exists) so the user can reach those actions without scrolling
  // past the image to the section below.
  @tracked processingExampleMenuOpen = false;
  _processingExampleMenuOutsideHandler = null;

  // Which image the LARGE image-area shows. Independent of the
  // visual-annotation selectedVersionKey — switching the large view
  // to "processing_example" doesn't change which reference-image
  // version annotations are anchored to. Annotations always live on
  // the reference image in v1.
  //   • "reference"           — current photographer-supplied version
  //                             (with full Konva annotation layer).
  //   • "processing_example"  — the critic's uploaded example, shown
  //                             as a plain image (no annotation layer).
  // Auto-switches to processing_example on a successful upload and
  // back to reference on remove. Toggleable by the user freely in
  // between. Persisted in drafts so a chosen view survives reopen.
  @tracked largeImageView = LARGE_IMAGE_VIEW_REFERENCE;

  // Tracks component teardown so async tasks (canvas export, upload,
  // post creation) don't try to set tracked properties on a destroyed
  // component when the user closes the modal mid-flight. We can't
  // disable the DModal X button, so this is the safety net.
  _destroyed = false;

  // Server-side critique workspace draft. State + autosaver instance
  // are kept here so the modal can wire load-on-open, debounced save
  // on every meaningful state change, and clear-on-success paths
  // (Post Critique, Edit in Composer, explicit Discard).
  //   draftStatus            — DRAFT_STATUS string driving the small
  //                            "Saving… / Draft saved / Couldn't save"
  //                            text near the modal footer.
  //   draftHasSaved          — true once we've stored at least one
  //                            draft for this modal session (used to
  //                            decide whether to show the Discard
  //                            action — nothing to discard otherwise).
  //   draftRestoreNotice     — null | "restored" | "image_version_missing"
  //                            | { kind: "image_version_outdated", label }
  //   _restoringDraft        — internal flag set during initial state
  //                            restoration so the autosave scheduler
  //                            doesn't immediately re-PUT the payload
  //                            we just received.
  @tracked draftStatus = DRAFT_STATUS.IDLE;
  @tracked draftHasSaved = false;
  @tracked draftRestoreNotice = null;
  _autosaver = null;
  _restoringDraft = false;

  willDestroy() {
    super.willDestroy(...arguments);
    this._destroyed = true;
    this._autosaver?.destroy?.();
    this._autosaver = null;
    // Drop refs so the GC can clear the textarea and the
    // TextareaTextManipulation helper. The dAutocomplete modifier
    // wires its own teardown when the textarea is removed from the
    // DOM (the modal unmounting handles that), so we don't need to
    // manually deregister listeners here.
    this.#textarea = null;
    this.#textManipulation = null;
    // Drop the Processing Example menu click-outside listener if it
    // happens to still be attached when the modal closes.
    if (this._processingExampleMenuOutsideHandler) {
      document.removeEventListener(
        "mousedown",
        this._processingExampleMenuOutsideHandler,
        true
      );
      this._processingExampleMenuOutsideHandler = null;
    }
    // Drop Photographer's Notes selection listener if it's still
    // attached (panel may be open at modal close).
    this.teardownPhotographersNotes();
    // Drop pane scroll-cue observers.
    this._teardownPaneSentinels();
    // Drop window-level error capture.
    this._teardownGlobalErrorCapture();
    // Revoke any in-flight preview snapshot's object URL so we don't
    // leak the flattened-canvas Blob.
    this._teardownPreviewSnapshot();
  }

  // ---- Global error capture ------------------------------------------
  //
  // Browser-wide `error` and `unhandledrejection` listeners so failures
  // in async paths that didn't explicitly catch still leave a
  // breadcrumb in `_errorHistory` (and in the console). Scoped to the
  // modal's lifetime — installed when the modal mounts, torn down in
  // willDestroy — so we don't leak listeners across reopens.
  //
  // The handlers are deliberately conservative: they filter to events
  // whose error chain mentions the plugin (`npn-critique-reply` in
  // either the message OR the stack trace) so we don't capture
  // unrelated errors from other plugins / Discourse core.
  _setupGlobalErrorCapture() {
    if (typeof window === "undefined") {
      return;
    }
    // Pull anything the error bus already recorded BEFORE the modal
    // mounted — e.g. prompt-tree generation errors that fired on the
    // topic page before the user clicked "Start a Critique".
    try {
      for (const entry of recentPluginErrors()) {
        this._appendBusEntry(entry, { backfill: true });
      }
    } catch {
      // ignore — diagnostic only
    }
    // Live subscription. Any plugin code (component, helper, lib)
    // that calls `recordPluginError(...)` from the bus module fires
    // a CustomEvent here and lands in our history without needing a
    // direct handle to the modal.
    this._pluginErrorBusHandler = (event) => {
      this._appendBusEntry(event?.detail, { backfill: false });
    };
    window.addEventListener(NPN_ERROR_EVENT, this._pluginErrorBusHandler);

    this._unhandledRejectionHandler = (event) => {
      const reason = event?.reason ?? event;
      if (!this._errorMentionsPlugin(reason)) {
        return;
      }
      this._recordError(
        "unhandled_rejection",
        reason instanceof Error ? reason : new Error(String(reason)),
        null,
        "warn"
      );
    };
    this._windowErrorHandler = (event) => {
      const err = event?.error ?? event?.message ?? null;
      if (!this._errorMentionsPlugin(err)) {
        return;
      }
      this._recordError(
        "window_error",
        err instanceof Error ? err : new Error(String(err ?? event?.message)),
        {
          filename: event?.filename ?? null,
          lineno: event?.lineno ?? null,
          colno: event?.colno ?? null,
        },
        "warn"
      );
    };
    window.addEventListener(
      "unhandledrejection",
      this._unhandledRejectionHandler
    );
    window.addEventListener("error", this._windowErrorHandler);
  }

  _teardownGlobalErrorCapture() {
    if (typeof window === "undefined") {
      return;
    }
    if (this._unhandledRejectionHandler) {
      window.removeEventListener(
        "unhandledrejection",
        this._unhandledRejectionHandler
      );
      this._unhandledRejectionHandler = null;
    }
    if (this._windowErrorHandler) {
      window.removeEventListener("error", this._windowErrorHandler);
      this._windowErrorHandler = null;
    }
    if (this._pluginErrorBusHandler) {
      window.removeEventListener(
        NPN_ERROR_EVENT,
        this._pluginErrorBusHandler
      );
      this._pluginErrorBusHandler = null;
    }
  }

  // Append a bus-recorded entry into our local history. Mirrors the
  // shape `_recordError` produces so the "Copy diagnostic" report
  // treats backfilled + live entries uniformly. We DON'T promote
  // these to `_lastFailureReport` — bus entries come from collaborator
  // components, and the modal's own user-visible failure banner is
  // what should populate the report. The bus entries enrich
  // `recentErrors` in the report so chained failures are visible.
  _appendBusEntry(entry, { backfill }) {
    if (!entry || typeof entry !== "object") {
      return;
    }
    const normalized = {
      timestamp: entry.timestamp ?? new Date().toISOString(),
      context: entry.context ?? "plugin_error_bus",
      severity: entry.severity ?? "warn",
      error: entry.error ?? {
        name: null,
        message: String(entry),
        stack: null,
      },
      extra: entry.extra ?? null,
      via: backfill ? "bus_backfill" : "bus_live",
    };
    this._errorHistory.push(normalized);
    if (this._errorHistory.length > 20) {
      this._errorHistory.shift();
    }
  }

  _pluginErrorBusHandler = null;

  // Filters global error events to ones that look like they came from
  // this plugin. Checks both the message and the stack trace for the
  // plugin name. Conservative — false negatives are preferred over
  // capturing unrelated noise.
  _errorMentionsPlugin(thing) {
    if (!thing) {
      return false;
    }
    const text =
      typeof thing === "string"
        ? thing
        : `${thing?.message ?? ""}\n${thing?.stack ?? ""}`;
    return text.includes("npn-critique-reply") || text.includes("npn_critique_reply");
  }

  // -- Textarea wiring: @mention autocomplete + Insert link helper -------
  //
  // Mirrors the npn-submissions NpnField pattern so the two plugins'
  // textareas behave the same way and future Discourse upgrades only
  // need a single review pass.
  //
  //   @mention autocomplete uses dAutocomplete + userSearch, gated on
  //   the site setting `enable_mentions` (silently skipped otherwise).
  //   Setup is wrapped in try/catch so a future Discourse API change
  //   cannot break the modal — the worst case is "no popup", typing
  //   still works.
  //
  //   Insert link reveals an inline form panel (NOT a sub-modal —
  //   Discourse's modal service can't stack), pre-filled with any
  //   currently-selected textarea text. On Insert we write
  //   `[text](url)` at the caret via TextareaTextManipulation, then
  //   dispatch a synthetic bubbling `input` event so the existing
  //   `clearValidationOnInput` handler and the draft autosaver see
  //   the change.

  @action
  setupTextarea(element) {
    this.#textarea = element;
    try {
      this.#textManipulation = new TextareaTextManipulation(getOwner(this), {
        textarea: element,
        eventPrefix: "npn-critique-reply",
      });
      if (this.siteSettings.enable_mentions) {
        const handler = new TextareaAutocompleteHandler(element);
        dAutocomplete.setupAutocomplete(
          getOwner(this),
          element,
          handler,
          this.#userAutocompleteOptions(element)
        );
      }
    } catch (e) {
      this._recordError("mention_autocomplete_setup", e, null, "warn");
    }
  }

  @action
  openLinkForm() {
    // Capture the textarea's selection BEFORE the form's first input
    // gets focus — moving focus to a different input collapses
    // selectionStart/selectionEnd on the textarea, and we want the
    // Insert action to write at the originally-selected range.
    if (this.#textarea) {
      this._linkPreservedSelection = {
        start: this.#textarea.selectionStart,
        end: this.#textarea.selectionEnd,
      };
    } else {
      this._linkPreservedSelection = null;
    }
    let defaultText = "";
    try {
      defaultText = this.#textManipulation?.getSelected()?.value ?? "";
    } catch {
      defaultText = "";
    }
    this.linkFormText = defaultText;
    this.linkFormUrl = "";
    this.linkFormOpen = true;
  }

  @action
  closeLinkForm() {
    this.linkFormOpen = false;
    this.linkFormUrl = "";
    this.linkFormText = "";
    this._linkPreservedSelection = null;
    // Return focus to the textarea so keyboard users land back on the
    // writing surface after dismissing the helper.
    this.#textarea?.focus();
  }

  @action
  updateLinkFormUrl(event) {
    this.linkFormUrl = event.target.value;
  }

  @action
  updateLinkFormText(event) {
    this.linkFormText = event.target.value;
  }

  @action
  submitLinkForm(event) {
    event?.preventDefault();
    const url = this.linkFormUrl.trim();
    if (!url) {
      return;
    }
    // Re-apply the captured selection so the insert lands at the
    // original caret/selection range even though focus has been on
    // the URL input. Safe to no-op if the textarea is missing.
    if (this.#textarea && this._linkPreservedSelection) {
      try {
        this.#textarea.focus();
        this.#textarea.setSelectionRange(
          this._linkPreservedSelection.start,
          this._linkPreservedSelection.end
        );
      } catch (_e) {
        // setSelectionRange can throw on hidden/disabled inputs;
        // fall through and let TextareaTextManipulation work from
        // the textarea's current selection state.
      }
    }
    this.#insertLink({ text: this.linkFormText, url });
    // Close + reset only after a successful write so a thrown error
    // (e.g. textManipulation unavailable) leaves the form open.
    this.linkFormOpen = false;
    this.linkFormUrl = "";
    this.linkFormText = "";
    this._linkPreservedSelection = null;
  }

  get linkFormInsertDisabled() {
    return this.linkFormUrl.trim().length === 0;
  }

  // -- private -----------------------------------------------------------

  #userAutocompleteOptions(textarea) {
    return {
      component: UserAutocompleteResults,
      key: UserAutocompleteResults.TRIGGER_KEY,
      width: "100%",
      treatAsTextarea: true,
      fixedTextareaPosition: true,
      autoSelectFirstSuggestion: true,
      transformComplete: (obj) => obj.username || obj.name,
      dataSource: (term) => userSearch({ term, includeGroups: true }),
      afterComplete: (text, event) => {
        event.preventDefault();
        textarea.value = text;
        textarea.focus();
        // Keep the parent's input handler in sync with the
        // programmatic write — see comment on the dispatchEvent
        // call in #insertLink below.
        textarea.dispatchEvent(new Event("input", { bubbles: true }));
      },
    };
  }

  #insertLink({ text, url }) {
    if (!this.#textManipulation || !url) {
      return;
    }
    try {
      const tm = this.#textManipulation;
      const sel = tm.getSelected();
      if (sel.start === sel.end) {
        // Caret with no selection: synthesise [linkText](url) at the
        // caret. Falls back to the bare URL when no link text was
        // typed, matching the composer's behaviour.
        const visible = (text || "").trim() || url;
        tm.insertText(`[${visible}](${url})`);
      } else {
        // With a selection: wrap it as the link text.
        tm.applySurround(sel, "[", `](${url})`, "link_description");
      }
      // `critiqueText` is bound through Ember's two-way Textarea
      // component, which listens to the native `input` event. The
      // helper writes directly to .value, so without this dispatch
      // the tracked property would diverge from the DOM until the
      // user next typed a character.
      this.#textarea?.dispatchEvent(new Event("input", { bubbles: true }));
      this.#textarea?.focus();
    } catch (e) {
      this._recordError("insert_link", e, null, "warn");
    }
  }

  constructor() {
    super(...arguments);
    // Restore prompt visibility preferences from a previous session.
    this.moreIdeasExpanded = readBool(STORAGE_KEY_MORE_IDEAS, false);

    // Set up window-level error capture so async failures that bypass
    // our explicit try/catch sites still leave a breadcrumb in
    // _errorHistory. Scoped to modal lifetime (torn down in
    // willDestroy).
    this._setupGlobalErrorCapture();

    if (this.isEditing) {
      // Edit flow: restore directly from the post's saved metadata
      // and parsed raw — no draft involvement. Drafts are an
      // in-progress concept and don't apply when reopening a
      // posted reply.
      this._initializeFromPost();
    } else {
      // New-critique flow: kick off the server-draft restore +
      // autosaver setup. Async, so the modal renders an empty
      // workspace first and fills it in once the GET resolves (or
      // stays empty if there's no draft).
      this._initializeDraftSync();
    }
  }

  get metadata() {
    return this.args.model?.metadata ?? null;
  }

  get topic() {
    return this.args.model?.topic ?? null;
  }

  // Set by callers that open the modal to EDIT an existing critique
  // reply (rather than create a new one). When present the modal:
  //   • restores annotations from `editingPost.npn_visual_notes`
  //   • restores text by parsing the heading + image markdown out of
  //     `editingPost.raw`
  //   • skips draft load/save/clear entirely (drafts are an
  //     in-progress concept; edits go straight to the post)
  //   • flips the primary footer label to "Update Critique" and
  //     calls the PUT update endpoint instead of POST create
  //   • hides Edit-in-Composer and Reply-Normally (escape hatches
  //     for the new-critique flow don't apply when editing)
  get editingPost() {
    return this.args.model?.editingPost ?? null;
  }

  get isEditing() {
    return !!this.editingPost;
  }

  // Footer primary-action label in PREVIEW mode — the actual post /
  // update gate. Swaps on edit / posting state. In edit mode (non-
  // preview), the primary button instead reads "Preview Critique" via
  // `previewButtonLabel` below — Post / Update only happens after the
  // user confirms from the preview view.
  get postButtonLabel() {
    if (this.isPosting) {
      return this.isEditing
        ? "npn_critique_reply.modal.updating"
        : "npn_critique_reply.modal.posting";
    }
    return this.isEditing
      ? "npn_critique_reply.modal.update_critique"
      : "npn_critique_reply.modal.post_critique";
  }

  // Primary footer label while editing (non-preview). Always "Preview
  // Critique" — Post / Update is the second click, fired from the
  // preview footer. `previewBuilding` swaps in a transient label
  // while the canvas export runs.
  get previewButtonLabel() {
    if (this.previewBuilding) {
      return "npn_critique_reply.modal.preparing_visual_notes";
    }
    return "npn_critique_reply.modal.preview_critique";
  }

  // A preview is allowed any time the workspace has content — text,
  // visual notes, or a processing example. Stays in sync with the
  // existing Post-Critique validation so the gate behaves the same.
  get canPreview() {
    return (
      this.hasUnsavedText ||
      this.hasAnyImageAnnotations ||
      this.hasProcessingExample
    );
  }

  // Title for the Preview button. When the modal has no
  // preview-eligible content the disabled-affordance tooltip
  // surfaces; otherwise undefined so DButton renders without a
  // title. Pulled into a getter because expressing this with
  // `{{unless this.canPreview "..."}}` in the template appears to
  // trip Glimmer's helper-as-component resolution on some Ember
  // versions, surfacing as "Expected a dynamic component
  // definition" mid-render.
  get previewButtonTitle() {
    if (this.canPreview) {
      return null;
    }
    return "npn_critique_reply.modal.preview_critique_disabled_title";
  }

  // Composed CSS class string for the DModal root. Was four inline
  // {{if}} / {{unless}} helper expressions concatenated in the
  // template, which surfaced "Expected a dynamic component
  // definition" errors mid-render — every time one of the gated
  // tracked properties (hasImage, visualFocusMode, cropMode,
  // previewMode) changed, Glimmer re-evaluated the helper chain
  // and tripped its helper-resolution path on some Ember versions.
  // Compute the whole class string here and bind once.
  get modalClassNames() {
    const parts = ["npn-critique-reply-modal", "--workspace"];
    if (!this.hasImage) {
      parts.push("npn-critique-reply-modal--no-image");
    }
    if (this.visualFocusMode) {
      parts.push("npn-critique-reply-modal--visual-focus");
    }
    if (this.cropMode) {
      parts.push("npn-critique-reply-modal--crop-mode");
    }
    if (this.previewMode) {
      parts.push("npn-critique-reply-modal--preview");
    }
    return parts.join(" ");
  }

  // ---- Image versions --------------------------------------------------

  get imageVersions() {
    return this.metadata?.image_versions ?? null;
  }

  get versions() {
    const v = this.imageVersions?.versions;
    return Array.isArray(v) ? v : [];
  }

  get hasVersions() {
    return this.versions.length > 0;
  }

  get hasMultipleVersions() {
    return this.versions.length > 1;
  }

  // Effective version key: explicit user choice (when set via
  // selectVersion / _restoreDraft) wins, otherwise fall back to the
  // server-supplied default. This used to be a lazy-init that wrote
  // back to the tracked `_selectedVersionKey` on first read, but
  // modern Glimmer asserts on tracked writes during a render
  // computation that already read the same field — the lazy-init
  // pattern was a latent bug and started crashing once an unrelated
  // getter (effectiveImageUrl post the multi-image picker) shifted
  // the read order enough to surface it.
  get selectedVersionKey() {
    return this._selectedVersionKey ?? this.imageVersions?.default_key ?? null;
  }

  get selectedVersion() {
    if (!this.hasVersions) {
      return null;
    }
    const key = this.selectedVersionKey;
    return (
      this.versions.find((v) => v.key === key) ??
      this.versions.find((v) => v.key === this.imageVersions?.default_key) ??
      this.versions[0]
    );
  }

  // Submissions plugin lets the OP attach up to 5 images. The server
  // exposes them via `metadata.submission_images` (array of
  // { index, upload_id, url, label }). The primary image is at index
  // 0 and ALSO appears in `image_versions` (alongside any revisions).
  // The picker UI only renders when there are 2+ images here.
  get submissionImages() {
    const list = this.metadata?.submission_images;
    return Array.isArray(list) ? list : [];
  }

  get hasMultipleSubmissionImages() {
    return this.submissionImages.length >= 2;
  }

  get selectedImageIndex() {
    return this._selectedImageIndex;
  }

  get selectedSubmissionImage() {
    if (!this.hasMultipleSubmissionImages) {
      return null;
    }
    return (
      this.submissionImages.find(
        (img) => img.index === this._selectedImageIndex
      ) ?? this.submissionImages[0]
    );
  }

  // Revision/version chain only applies to the PRIMARY image. When the
  // critic has switched to a secondary submission image, the version
  // picker hides and we don't try to splice in revision URLs.
  get versionSelectorAvailable() {
    return this._selectedImageIndex === 0 && this.hasMultipleVersions;
  }

  get isOnFirstSubmissionImage() {
    return this._selectedImageIndex <= 0;
  }

  get isOnLastSubmissionImage() {
    const count = this.submissionImages.length;
    return count === 0 || this._selectedImageIndex >= count - 1;
  }

  get effectiveImageUrl() {
    // Secondary submission images (index >= 1) use their own URL
    // directly — they don't currently have a revision chain.
    if (this._selectedImageIndex > 0) {
      const img = this.selectedSubmissionImage;
      if (img?.url) {
        return getURLWithCDN(img.url);
      }
    }
    const version = this.selectedVersion;
    if (version?.url) {
      return getURLWithCDN(version.url);
    }
    return this._legacyImageUrl;
  }

  get hasImage() {
    return !!this.effectiveImageUrl;
  }

  get _legacyImageUrl() {
    const topic = this.topic;
    if (!topic) {
      return null;
    }
    const raw = topic.thumbnails ?? topic.get?.("thumbnails");
    if (Array.isArray(raw) && raw.length > 0) {
      const usable = raw.filter((t) => t?.url);
      if (usable.length > 0) {
        const sorted = [...usable].sort(
          (a, b) =>
            (a.max_width ?? a.width ?? 0) - (b.max_width ?? b.width ?? 0)
        );
        const target = 1280;
        const fitsTarget = [...sorted]
          .reverse()
          .find((t) => (t.max_width ?? t.width ?? 0) <= target);
        return (fitsTarget ?? sorted[sorted.length - 1]).url;
      }
    }
    return topic.image_url ?? topic.get?.("image_url") ?? null;
  }

  get imageAlt() {
    const version = this.selectedVersion;
    const title = this.topic?.title;
    if (version?.label) {
      return title
        ? i18n("npn_critique_reply.modal.image_alt_versioned_with_title", {
            label: version.label,
            title,
          })
        : i18n("npn_critique_reply.modal.image_alt_versioned", {
            label: version.label,
          });
    }
    return title
      ? i18n("npn_critique_reply.modal.image_alt_with_title", { title })
      : i18n("npn_critique_reply.modal.image_alt");
  }

  get showingVersionLabel() {
    // When the large view is the processing example, the caption
    // describes THAT — not the underlying selected reference
    // version. Annotations + version selector still operate on the
    // reference behind the scenes; this caption tracks what the
    // user is looking at.
    if (this.viewingProcessingExample) {
      return i18n(
        "npn_critique_reply.modal.showing_processing_example"
      );
    }
    const v = this.selectedVersion;
    if (!v) {
      return null;
    }
    return i18n("npn_critique_reply.modal.showing_version", { label: v.label });
  }

  // ---- Large-image view --------------------------------------------------

  get viewingProcessingExample() {
    return (
      this.largeImageView === LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE &&
      this.hasProcessingExample
    );
  }

  get viewingReference() {
    // The view defaults to reference whenever there's no processing
    // example to show — guards against a stale "processing_example"
    // flag (e.g. if state goes through a weird intermediate after
    // remove). Annotations + visual tools are gated on this getter.
    return !this.viewingProcessingExample;
  }

  // Single source of truth for what URL the large image area shows.
  // `effectiveImageUrl` keeps pointing at the reference version so
  // the visual-notes canvas export pipeline (which always bakes
  // annotations onto the reference) is unaffected.
  get largeImageUrl() {
    if (this.viewingProcessingExample) {
      return this.processingExample?.url ?? this.effectiveImageUrl;
    }
    return this.effectiveImageUrl;
  }

  get largeImageAlt() {
    if (this.viewingProcessingExample) {
      return i18n(
        "npn_critique_reply.modal.processing_example.large_alt"
      );
    }
    return this.imageAlt;
  }

  @action
  setLargeImageView(view) {
    // Validate against the known enum so a stale draft or external
    // caller can't push the modal into an unknown state.
    if (!LARGE_IMAGE_VIEWS.includes(view)) {
      return;
    }
    // Can't switch INTO processing_example without an upload.
    if (
      view === LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE &&
      !this.hasProcessingExample
    ) {
      return;
    }
    if (this.largeImageView === view) {
      return;
    }
    this.largeImageView = view;
    this._scheduleDraftSaveAfterProcessingExampleChange();
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] set-large-image-view", {
        topicId: this.topic?.id,
        view,
      });
    }
  }

  get revisionNote() {
    const v = this.selectedVersion;
    return v?.kind === "revision" && v.note ? v.note : null;
  }

  // ---- Request summary -------------------------------------------------

  get critiqueStyleLabel() {
    return critiqueStyleLabel(this.metadata?.critique_style);
  }

  get feedbackFocusLabel() {
    return feedbackFocusLabel(this.metadata?.feedback_focus);
  }

  get weeklyChallengeTitle() {
    return this.metadata?.weekly_challenge_title ?? null;
  }

  get weeklyChallengeDates() {
    return this.metadata?.weekly_challenge_dates ?? null;
  }

  get hasRequestSummary() {
    return !!(
      this.critiqueStyleLabel ||
      this.feedbackFocusLabel ||
      this.weeklyChallengeTitle ||
      this.weeklyChallengeDates
    );
  }

  // ---- Questions to consider ------------------------------------------
  //
  // Thinking aids only. Nothing here ever inserts text into the
  // textarea — the critic's prose stays entirely in their own voice.
  // The default trio adapts to the topic's critique style and feedback
  // focus; the "More ideas" groups are the same expandable bank
  // across every critique, with two conditional groups (visual notes
  // when the visual-tools panel is showing, project sequence for
  // project critiques).

  get _questionsToConsider() {
    return getQuestionsToConsider({
      critiqueStyle: this.metadata?.critique_style,
      feedbackFocus: this.metadata?.feedback_focus,
      submissionType: this.metadata?.submission_type,
      visualToolsEnabled: this.visualNotesAvailable,
    });
  }

  get defaultQuestions() {
    return this._questionsToConsider.defaultQuestions;
  }

  get moreIdeasGroups() {
    return this._questionsToConsider.groups;
  }

  // ---- Reply text preparation -----------------------------------------

  get hasUnsavedText() {
    return this.critiqueText.trim().length > 0;
  }

  // Sync path — used when there are no pins. Adds the "Regarding
  // Revision N:" prefix on revisions; original is returned as-is.
  _textOnlyRaw() {
    const text = this.critiqueText.trim();
    if (!text) {
      return "";
    }
    const v = this.selectedVersion;
    if (v?.kind === "revision" && v.label) {
      return `Regarding ${v.label}:\n\n${text}`;
    }
    return text;
  }

  get hasVisualAnnotations() {
    return (
      this.notes.length > 0 ||
      !!this.crop ||
      this.hasEyePath ||
      this.attentionPulls.length > 0 ||
      this.strongAreas.length > 0 ||
      this.directionArrows.length > 0 ||
      this.relationshipArrows.length > 0
    );
  }

  // True when ANY submission image has annotations — the active one
  // OR any cold-storage snapshot. Used by the post / preview gates
  // so a critic who marked up image 2 and then flipped back to image
  // 1 (which is empty) can still post / preview.
  get hasAnyImageAnnotations() {
    if (this.hasVisualAnnotations) {
      return true;
    }
    for (const [idx, snap] of this._annotationsByImageIndex) {
      if (idx !== this._selectedImageIndex && snapshotHasAnnotations(snap)) {
        return true;
      }
    }
    return false;
  }

  // Walk every image's stored annotation array of the given key
  // (notes / attentionPulls / strongAreas / etc.) and yield each
  // annotation in submission order. Used to compute label uniqueness
  // across the WHOLE critique — A1, D1, E1, [N] should not repeat
  // between images, otherwise the cooked post can't distinguish
  // "D1 on image 1" from "D1 on image 2".
  _allAnnotationsAcrossImages(key) {
    const out = [];
    const indices = new Set([this._selectedImageIndex]);
    for (const i of this._annotationsByImageIndex.keys()) {
      indices.add(i);
    }
    for (const idx of indices) {
      if (idx === this._selectedImageIndex) {
        const live = this[key];
        if (Array.isArray(live)) {
          for (const a of live) {
            out.push(a);
          }
        }
      } else {
        const snap = this._annotationsByImageIndex.get(idx);
        const list = snap?.[key];
        if (Array.isArray(list)) {
          for (const a of list) {
            out.push(a);
          }
        }
      }
    }
    return out;
  }

  _allLabelsAcrossImages(key) {
    return this._allAnnotationsAcrossImages(key)
      .map((a) => a?.label)
      .filter((l) => typeof l === "string" && l.length > 0);
  }

  // Highest pin number used anywhere in the critique. Pin "labels" are
  // the integer number itself, rendered as `[N]` in the post — they
  // need to be unique across images too.
  _maxPinNumberAcrossImages() {
    let max = 0;
    for (const note of this._allAnnotationsAcrossImages("notes")) {
      const n = Number.isInteger(note?.number) ? note.number : 0;
      if (n > max) {
        max = n;
      }
    }
    return max;
  }

  // Count of crops across ALL images. Used by the numbered-crop
  // labeling rule: 1 total → "[Crop]" (unchanged), 2+ total → each
  // crop gets "[Crop N]" with the existing first crop retroactively
  // renamed in the textarea on the 1→2 transition.
  _cropCountAcrossImages() {
    let count = this.crop ? 1 : 0;
    for (const [idx, snap] of this._annotationsByImageIndex) {
      if (idx === this._selectedImageIndex) {
        continue;
      }
      if (snap?.crop) {
        count += 1;
      }
    }
    return count;
  }

  // 1→2 transition: there's exactly one crop in cold storage with no
  // label (the legacy "[Crop]" form). Stamp it as "Crop 1" in the
  // snapshot AND rewrite the textarea so its token shifts from
  // "[Crop]" to "[Crop 1]". The new (second) crop will be labeled
  // "Crop 2" by the caller.
  _retroactivelyLabelFirstCrop() {
    for (const [idx, snap] of this._annotationsByImageIndex) {
      if (idx === this._selectedImageIndex) {
        continue;
      }
      if (snap?.crop && !snap.crop.label) {
        this._annotationsByImageIndex.set(idx, {
          ...snap,
          crop: { ...snap.crop, label: "Crop 1" },
        });
        // Rewrite token in the textarea. The line template was
        // "[Crop] %{text}" or the bare starter "[Crop]"; either way
        // the only "[Crop]" tokens present at this moment came from
        // that first crop. Replace globally so all references shift
        // together.
        if (typeof this.critiqueText === "string") {
          this.critiqueText = this.critiqueText.replace(
            /\[Crop\](?!\s*\d)/g,
            "[Crop 1]"
          );
        }
        return;
      }
    }
  }

  // Token format for the ACTIVE image's crop. Used by the popover
  // confirm path to append the right "[Crop]" / "[Crop N]" token to
  // the textarea.
  _activeCropToken() {
    const label = this.crop?.label;
    return label ? `[${label}]` : "[Crop]";
  }

  get annotationCount() {
    return (
      this.notes.length +
      (this.crop ? 1 : 0) +
      this.eyePathCount +
      this.attentionPulls.length +
      this.strongAreas.length +
      this.directionArrows.length +
      this.relationshipArrows.length
    );
  }

  get selectedAttentionPull() {
    if (!this.selectedAttentionPullId) {
      return null;
    }
    return (
      this.attentionPulls.find(
        (p) => p.id === this.selectedAttentionPullId
      ) ?? null
    );
  }

  get attentionPullsAtMax() {
    return this.attentionPulls.length >= MAX_ATTENTION_PULL_COUNT;
  }

  get selectedStrongArea() {
    if (!this.selectedStrongAreaId) {
      return null;
    }
    return (
      this.strongAreas.find((p) => p.id === this.selectedStrongAreaId) ?? null
    );
  }

  get strongAreasAtMax() {
    return this.strongAreas.length >= MAX_STRONG_AREA_COUNT;
  }

  get selectedDirectionArrow() {
    if (!this.selectedDirectionArrowId) {
      return null;
    }
    return (
      this.directionArrows.find(
        (a) => a.id === this.selectedDirectionArrowId
      ) ?? null
    );
  }

  get directionArrowsAtMax() {
    return this.directionArrows.length >= MAX_DIRECTION_ARROW_COUNT;
  }

  get selectedRelationshipArrow() {
    if (!this.selectedRelationshipArrowId) {
      return null;
    }
    return (
      this.relationshipArrows.find(
        (a) => a.id === this.selectedRelationshipArrowId
      ) ?? null
    );
  }

  get relationshipArrowsAtMax() {
    return this.relationshipArrows.length >= MAX_RELATIONSHIP_ARROW_COUNT;
  }

  // True when at least one eye path with at least one valid point
  // exists. With multi-path support there may be several; the bool
  // here is just "any?". `eyePathCount` is the number of paths;
  // `eyePathPointCount` is the point count of the path that's
  // currently the focus (selected or actively being constructed)
  // — used by the toolbar's per-path UI.
  get hasEyePath() {
    return this.eyePaths.some((p) => (p.points?.length ?? 0) > 0);
  }

  get eyePathCount() {
    return this.eyePaths.filter((p) => (p.points?.length ?? 0) > 0).length;
  }

  // Path currently receiving new points during this eye_path mode
  // session (set on first click that creates a new path; cleared
  // when the user leaves eye_path mode).
  get activeEyePath() {
    if (!this._activeEyePathId) {
      return null;
    }
    return this.eyePaths.find((p) => p.id === this._activeEyePathId) ?? null;
  }

  get selectedEyePath() {
    if (!this.selectedEyePathId) {
      return null;
    }
    return (
      this.eyePaths.find((p) => p.id === this.selectedEyePathId) ?? null
    );
  }

  // The path the toolbar/popover should reference: prefer the
  // actively-constructed path during a session, else fall back to
  // the selected path. Null if neither.
  get focusedEyePath() {
    return this.activeEyePath ?? this.selectedEyePath;
  }

  get eyePathPointCount() {
    return this.focusedEyePath?.points?.length ?? 0;
  }

  get eyePathsAtMax() {
    return this.eyePathCount >= MAX_EYE_PATH_COUNT;
  }

  get hasMultipleEyePaths() {
    return this.eyePathCount > 1;
  }

  // Pin moves are suppressed while the note popover is open — the
  // popover is anchored to the pin's last-known coords, so allowing
  // a drag mid-popover would leave the popover floating in the wrong
  // place. The user dismisses the popover (Add note / Skip / Escape)
  // and can then click-and-drag the still-selected pin freely.
  get pinMoveEnabled() {
    return !this.pendingPin;
  }

  // Attention-pull move/resize is suppressed while its note popover
  // is open — same rationale as pinMoveEnabled.
  get attentionPullEditEnabled() {
    return !this.pendingAttentionPullPopover;
  }

  // Strong-area move/resize is suppressed while its note popover is
  // open — twin of attentionPullEditEnabled.
  get strongAreaEditEnabled() {
    return !this.pendingStrongAreaPopover;
  }

  // First ~60 chars of a pin's note for the accessible list. The
  // textarea remains canonical — this is a screen-reader / keyboard
  // mirror that may drift if the critic edits the textarea later.
  snippetFor = (text) => {
    if (!text) {
      return "";
    }
    const trimmed = String(text).trim();
    return trimmed.length > 60 ? `${trimmed.slice(0, 60)}…` : trimmed;
  };

  // Fired by the Konva stage on pin dragend. Updates the pin's coords
  // without changing identity (number / noteText). The stage updates
  // its own closure-cached pin coords BEFORE invoking this callback,
  // so the next sync sees identical values and skips a redundant
  // re-render (samePins → true).
  @action
  movePin(number, xPct, yPct) {
    if (number == null) {
      return;
    }
    this.notes = this.notes.map((p) =>
      p.number === number ? { ...p, xPct, yPct } : p
    );
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] move-pin", {
        topicId: this.topic?.id,
        number,
        xPct,
        yPct,
      });
    }
  }

  // Direct pin removal by number, used from the accessible list so a
  // keyboard user can remove a specific pin without first selecting it.
  // Behaves like selecting-then-removing — textarea text is preserved.
  @action
  removePinByNumber(number) {
    if (number == null) {
      return;
    }
    this.notes = this.notes.filter((p) => p.number !== number);
    if (this.selectedPinNumber === number) {
      this.selectedPinNumber = null;
    }
    // If the removed pin is the one whose note popover is open,
    // close the popover. The textarea hasn't been touched yet for
    // this pin (we defer the marker until confirm/skip), so removing
    // here cleanly cancels both the pin and any draft note.
    if (this.pendingPin && this.pendingPin.number === number) {
      this.pendingPin = null;
      this.pendingPinNoteText = "";
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-pin-by-number", {
        topicId: this.topic?.id,
        removedNumber: number,
        remainingNumbers: this.notes.map((p) => p.number),
      });
    }
  }

  // Async path — used whenever visual annotations OR a processing
  // example are present. Runs the visual-notes export/upload pipeline
  // when there are annotations (the canvas-baked JPEG), then assembles
  // the final reply body in the canonical order:
  //
  //   visual notes block  → processing example block → critique text
  //
  // Throws errors tagged with a `stage` field so the calling action
  // can show a stage-specific friendly message. The processing
  // example upload happens earlier (on file pick), so this path no
  // longer needs to re-upload — it just reads `this.processingExample`.
  //
  // `skipVisualNotes: true` short-circuits the canvas pipeline so the
  // "Post / Continue without visual notes" fallback button can reuse
  // this same path without re-trying the failed pipeline. A
  // processing example, if present, is still included in the body.
  async _prepareReplyText({ skipVisualNotes = false } = {}) {
    // Snapshot the active image's edits into the per-image map so
    // we compose the post body from a consistent picture across all
    // images (including the one the critic is currently looking at).
    this._annotationsByImageIndex.set(
      this._selectedImageIndex,
      this._snapshotCurrentAnnotations()
    );

    const annotatedImages = skipVisualNotes
      ? []
      : this._gatherAnnotatedImagesInSubmissionOrder();
    const hasExample = this.hasProcessingExample;

    // Flatten + upload each annotated image, in submission order, so
    // the post body and the structured payload both come out in a
    // stable order regardless of which image the critic edited
    // first. Each iteration updates statusMessage so the modal's
    // progress banner reflects how many images are still to go.
    const visualBlocks = [];
    for (let i = 0; i < annotatedImages.length; i++) {
      const entry = annotatedImages[i];
      this.statusMessage = this._preparingStatusMessage(
        i + 1,
        annotatedImages.length
      );
      const block = await this._flattenAndUploadImage(entry);
      visualBlocks.push(block);
    }

    const exampleBlock = hasExample
      ? this._composeProcessingExampleBlock()
      : "";

    // The visual-notes heading + processing-example heading both
    // name the selected image version, so the `_textOnlyRaw`
    // revision prefix would be redundant when either headed block
    // is present. Strip down to the bare textarea body in that case.
    const trimmedText =
      visualBlocks.length > 0 || exampleBlock
        ? this.critiqueText.trim()
        : this._textOnlyRaw();

    // Body composition.
    //
    // Per-image grouping: each paragraph that references annotation
    // tokens belonging to ONE image (e.g. "[A1] sits low and
    // anchors..." when A1 lives on image 2) is routed UNDER that
    // image's section so the prose sits next to the image it
    // describes. Paragraphs without recognised tokens, or that mix
    // tokens from multiple images, stay at the top as "general
    // critique." Single-image submissions get the same treatment so
    // the typed critique reads as written-then-marks both for a
    // single and for multiple images.
    const tokenToImageIndex = this._buildTokenToImageIndexMap();
    const grouped = this._groupTextParagraphsByImage(
      trimmedText,
      tokenToImageIndex
    );

    // Order: general written critique → per-image (submission order)
    // section with its own prose paragraphs and image → processing
    // example. Empty groups + sections collapse cleanly via
    // filter(Boolean).
    const parts = [];
    if (grouped.general.length > 0) {
      parts.push(grouped.general.join("\n\n"));
    }
    for (const block of visualBlocks) {
      parts.push(
        this._composeVisualNotesBlockForImage(
          block,
          grouped.perImage.get(block.index) ?? []
        )
      );
    }
    if (exampleBlock) {
      parts.push(exampleBlock);
    }
    const raw = parts.filter((p) => p && p.length > 0).join("\n\n");

    // Caller uses visualBlocks to build the structured npn_visual_notes
    // payload for the post custom field — see buildVisualAnnotationPayload
    // in the schema module.
    return { raw, visualBlocks };
  }

  // Walk image indices in submission order (0..N-1, plus index 0 for
  // the legacy single-image case). Returns entries for each index
  // whose snapshot has any annotations. Order is the order the
  // images appear in the picker pills.
  _gatherAnnotatedImagesInSubmissionOrder() {
    const out = [];
    const count = Math.max(this.submissionImages.length, 1);
    for (let i = 0; i < count; i++) {
      const snap = this._annotationsByImageIndex.get(i);
      if (snapshotHasAnnotations(snap)) {
        out.push({ index: i, snapshot: snap });
      }
    }
    return out;
  }

  // Flatten one image's annotations into a JPEG, upload it, and
  // return the upload reference + source metadata. Shared by the
  // post-output composer above and (potentially) the preview path.
  async _flattenAndUploadImage(entry) {
    const sourceUrl = this._sourceUrlForImageIndex(entry.index);
    if (!sourceUrl) {
      throw this._wrapVisualNotesError(
        "load",
        new Error(`no image url for index ${entry.index}`)
      );
    }
    let image;
    try {
      image = await loadImageForExport(sourceUrl);
    } catch (e) {
      throw this._wrapVisualNotesError("load", e);
    }

    let canvas;
    let blob;
    try {
      canvas = buildVisualNotesCanvas({
        image,
        pins: entry.snapshot.notes,
        crop: entry.snapshot.crop,
        eyePaths: entry.snapshot.eyePaths,
        attentionPulls: entry.snapshot.attentionPulls,
        strongAreas: entry.snapshot.strongAreas,
        directionArrows: entry.snapshot.directionArrows,
        relationshipArrows: entry.snapshot.relationshipArrows,
      });
      blob = await exportCanvasToBlob(canvas);
    } catch (e) {
      throw this._wrapVisualNotesError("export", e);
    }

    // Diagnostic snapshot per image — same magic-byte sniff that
    // the single-image path used, so the failure-report shape stays
    // consistent. Captured for the LAST flatten (most useful one
    // when the upload fails); the per-image upload status overwrites
    // it as we go.
    let magic = null;
    try {
      if (blob && blob.size >= 8) {
        const head = new Uint8Array(await blob.slice(0, 8).arrayBuffer());
        magic = Array.from(head)
          .map((b) => b.toString(16).padStart(2, "0"))
          .join(" ");
      }
    } catch {
      // ignore — diagnostic only
    }
    this._lastExportDiagnostic = {
      imageIndex: entry.index,
      canvasWidth: canvas?.width ?? null,
      canvasHeight: canvas?.height ?? null,
      blobSize: blob?.size ?? null,
      blobType: blob?.type ?? null,
      blobMagicBytes: magic,
      filename: this._visualNotesFilenameForImageIndex(entry.index),
      imageNaturalWidth: image?.naturalWidth ?? null,
      imageNaturalHeight: image?.naturalHeight ?? null,
      imageSrc: sourceUrl ?? null,
    };

    let upload;
    try {
      upload = await uploadVisualNotesBlob(
        blob,
        this._visualNotesFilenameForImageIndex(entry.index)
      );
      this._lastUploadDiagnostic = {
        imageIndex: entry.index,
        uploadId: upload?.id ?? null,
        shortUrl: upload?.short_url ?? null,
        width: upload?.width ?? null,
        height: upload?.height ?? null,
      };
    } catch (e) {
      this._lastUploadDiagnostic = {
        imageIndex: entry.index,
        status: e?.jqXHR?.status ?? null,
        statusText: e?.jqXHR?.statusText ?? null,
        serverErrors:
          (Array.isArray(e?.jqXHR?.responseJSON?.errors)
            ? e.jqXHR.responseJSON.errors
            : null) ??
          (typeof e?.jqXHR?.responseJSON?.error === "string"
            ? [e.jqXHR.responseJSON.error]
            : null),
      };
      throw this._wrapVisualNotesError("upload", e);
    }

    return {
      index: entry.index,
      snapshot: entry.snapshot,
      sourceUrl,
      sourceUploadId: this._sourceUploadIdForImageIndex(entry.index),
      sourceLabel: this._sourceLabelForImageIndex(entry.index),
      upload,
    };
  }

  // Image 0 routes through the existing version selector so the
  // critic's choice of original-vs-revision still wins. Images 1+
  // pull straight from the submission_images metadata — they don't
  // have a revision chain today.
  _sourceUrlForImageIndex(index) {
    if (index === 0) {
      return this.effectiveImageUrl;
    }
    const img = this.submissionImages.find((i) => i.index === index);
    return img?.url ? getURLWithCDN(img.url) : null;
  }

  _sourceUploadIdForImageIndex(index) {
    if (index === 0) {
      return this.selectedVersion?.upload_id ?? null;
    }
    const img = this.submissionImages.find((i) => i.index === index);
    return img?.upload_id ?? null;
  }

  _sourceLabelForImageIndex(index) {
    if (index === 0) {
      return this.selectedVersion?.label ?? null;
    }
    const img = this.submissionImages.find((i) => i.index === index);
    return img?.label ?? null;
  }

  _visualNotesFilenameForImageIndex(index) {
    const topicId = this.topic?.id ?? "unknown";
    if (index === 0) {
      const key = this.selectedVersionKey ?? "original";
      return `npn-visual-notes-topic-${topicId}-${key}.jpg`;
    }
    return `npn-visual-notes-topic-${topicId}-image-${index + 1}.jpg`;
  }

  _preparingStatusMessage(current, total) {
    if (total <= 1) {
      return i18n("npn_critique_reply.modal.preparing_visual_notes");
    }
    return i18n("npn_critique_reply.modal.preparing_visual_notes_n", {
      current,
      total,
    });
  }

  // Per-image visual-notes markdown section. Uses the source label
  // (e.g. "Revision 2" for image 0 or "Image 3" for a secondary
  // submission image) when available, otherwise the legacy
  // "original" heading. The cooked-post inline image markdown
  // doesn't change shape — Discourse will resolve `short_url` the
  // same way it did before.
  //
  // `paragraphs` is the prose this image owns (paragraphs whose
  // annotation tokens belong to THIS image). When empty the section
  // is just heading + image, same as the v1 visual-notes block.
  // When populated, the prose sits between heading and image so the
  // critic's note reads alongside the marked-up image.
  _composeVisualNotesBlockForImage(
    { index, sourceLabel, upload },
    paragraphs = []
  ) {
    const heading = this._visualNotesHeadingForIndex(index, sourceLabel);
    const altText = i18n("npn_critique_reply.modal.visual_notes_alt");
    const shortUrl = upload?.short_url ?? upload?.url ?? "";
    const imageLine = `![${altText}](${shortUrl})`;
    if (paragraphs.length === 0) {
      return `${heading}\n\n${imageLine}`;
    }
    return `${heading}\n\n${paragraphs.join("\n\n")}\n\n${imageLine}`;
  }

  // Walk every per-image snapshot and assemble a `token → image_index`
  // lookup. Tokens are the exact strings that appear between `[` and
  // `]` in the textarea (so the same key the cooked-post badge
  // decorator's TOKEN_PATTERN captures).
  _buildTokenToImageIndexMap() {
    const map = new Map();
    const visit = (idx, snap) => {
      if (!snap) {
        return;
      }
      for (const n of snap.notes ?? []) {
        if (Number.isInteger(n?.number)) {
          map.set(String(n.number), idx);
        }
      }
      if (snap.crop) {
        // Single-crop critiques omit the label and use [Crop]; multi-
        // crop critiques carry "Crop 1" / "Crop 2" / etc. Register
        // the actual label when present, otherwise the bare "Crop"
        // form so the single-crop case still routes correctly.
        map.set(snap.crop.label ?? "Crop", idx);
      }
      for (const arr of [
        snap.attentionPulls,
        snap.strongAreas,
        snap.eyePaths,
        snap.directionArrows,
        snap.relationshipArrows,
      ]) {
        for (const a of arr ?? []) {
          if (a?.label && typeof a.label === "string") {
            map.set(a.label, idx);
          }
        }
      }
    };
    for (const [idx, snap] of this._annotationsByImageIndex) {
      visit(idx, snap);
    }
    return map;
  }

  // Split the critique text into paragraphs (blank-line separated)
  // and classify each one: a paragraph whose annotation tokens all
  // belong to ONE image goes into perImage[that index]; everything
  // else (no tokens, or tokens from multiple images) stays in
  // `general`. Preserves original order within each bucket. Mixed-
  // token paragraphs intentionally stay at the top so a critic
  // writing about how Crop 2 relates to A1 doesn't get sliced
  // between two sections.
  _groupTextParagraphsByImage(text, tokenToImageIndex) {
    const general = [];
    const perImage = new Map();
    if (!text) {
      return { general, perImage };
    }
    const paragraphs = text.split(/\n{2,}/);
    for (const p of paragraphs) {
      if (!p.trim()) {
        continue;
      }
      PARAGRAPH_TOKEN_PATTERN.lastIndex = 0;
      const indices = new Set();
      let recognisedTokenCount = 0;
      for (const match of p.matchAll(PARAGRAPH_TOKEN_PATTERN)) {
        const idx = tokenToImageIndex.get(match[1]);
        if (idx != null) {
          indices.add(idx);
          recognisedTokenCount += 1;
        }
      }
      if (recognisedTokenCount > 0 && indices.size === 1) {
        const idx = [...indices][0];
        if (!perImage.has(idx)) {
          perImage.set(idx, []);
        }
        perImage.get(idx).push(p);
      } else {
        general.push(p);
      }
    }
    return { general, perImage };
  }

  // Bridge between the per-image `visualBlocks` returned by
  // _prepareReplyText and the schema-level buildVisualAnnotationPayload
  // call. Hides the "primary image is special" logic from the caller:
  // image_index 0 (if present) flows into the legacy top-level args,
  // everything else goes into `additionalImages`. Returns null when
  // there's nothing to send (no annotated images at all).
  _buildVisualNotesPayload(visualBlocks) {
    if (!Array.isArray(visualBlocks) || visualBlocks.length === 0) {
      return null;
    }
    const primary = visualBlocks.find((b) => b.index === 0) ?? null;
    const additional = visualBlocks
      .filter((b) => b.index > 0)
      .map((b) => ({
        index: b.index,
        sourceUrl: b.sourceUrl,
        sourceUploadId: b.sourceUploadId,
        sourceLabel: b.sourceLabel,
        visualUpload: b.upload,
        pins: b.snapshot?.notes ?? [],
        crop: b.snapshot?.crop ?? null,
        eyePaths: b.snapshot?.eyePaths ?? [],
        attentionPulls: b.snapshot?.attentionPulls ?? [],
        strongAreas: b.snapshot?.strongAreas ?? [],
        directionArrows: b.snapshot?.directionArrows ?? [],
        relationshipArrows: b.snapshot?.relationshipArrows ?? [],
      }));

    // When the only annotated images are non-primary, fall back to
    // passing the FIRST entry as the "primary" so the legacy `source`
    // field is non-empty. That entry's image_index is still > 0 in
    // the per-annotation tag; readers that consult `sources` will see
    // it; readers that only consult the legacy `source` get its
    // metadata rather than null.
    const head = primary ?? additional.shift();
    if (!head) {
      return null;
    }
    return buildVisualAnnotationPayload({
      topic: this.topic,
      selectedVersion:
        head.index === 0
          ? this.selectedVersion
          : {
              key: `image_${head.index}`,
              kind: "submission_image",
              label: head.sourceLabel ?? null,
              upload_id: head.sourceUploadId ?? null,
              url: head.sourceUrl ?? null,
            },
      visualUpload: head.upload ?? head.visualUpload,
      pins: head.snapshot?.notes ?? head.pins ?? [],
      crop: head.snapshot?.crop ?? head.crop ?? null,
      eyePaths: head.snapshot?.eyePaths ?? head.eyePaths ?? [],
      attentionPulls:
        head.snapshot?.attentionPulls ?? head.attentionPulls ?? [],
      strongAreas: head.snapshot?.strongAreas ?? head.strongAreas ?? [],
      directionArrows:
        head.snapshot?.directionArrows ?? head.directionArrows ?? [],
      relationshipArrows:
        head.snapshot?.relationshipArrows ?? head.relationshipArrows ?? [],
      additionalImages: additional,
    });
  }

  _visualNotesHeadingForIndex(index, sourceLabel) {
    if (index === 0) {
      const v = this.selectedVersion;
      if (v?.kind === "revision" && v.label) {
        return i18n(
          "npn_critique_reply.modal.visual_notes_heading_revision",
          { label: v.label }
        );
      }
      return i18n("npn_critique_reply.modal.visual_notes_heading_original");
    }
    return i18n("npn_critique_reply.modal.visual_notes_heading_labeled", {
      label: sourceLabel ?? `Image ${index + 1}`,
    });
  }

  // Just the heading + image-markdown lines for the visual-notes
  // block. The full reply body is assembled by `_prepareReplyText`,
  // which interleaves this with the processing-example block (if
  // any) and the critique text.
  _composeVisualNotesBlock(upload) {
    const heading = this._visualNotesHeading();
    const altText = i18n("npn_critique_reply.modal.visual_notes_alt");
    const shortUrl = upload?.short_url ?? upload?.url ?? "";
    return `${heading}\n\n![${altText}](${shortUrl})`;
  }

  _visualNotesHeading() {
    const v = this.selectedVersion;
    if (v?.kind === "revision" && v.label) {
      return i18n("npn_critique_reply.modal.visual_notes_heading_revision", {
        label: v.label,
      });
    }
    return i18n("npn_critique_reply.modal.visual_notes_heading_original");
  }

  _visualNotesFilename() {
    const topicId = this.topic?.id ?? "unknown";
    const key = this.selectedVersionKey ?? "original";
    return `npn-visual-notes-topic-${topicId}-${key}.jpg`;
  }

  _wrapVisualNotesError(stage, cause) {
    const err = new Error(`visual_notes:${stage}`);
    err.stage = stage;
    err.cause = cause;
    return err;
  }

  _visualNotesErrorMessage(stage, cause = null) {
    const base =
      {
        load: i18n("npn_critique_reply.modal.visual_notes_load_failed"),
        export: i18n("npn_critique_reply.modal.visual_notes_export_failed"),
        upload: i18n("npn_critique_reply.modal.visual_notes_upload_failed"),
      }[stage] ?? i18n("npn_critique_reply.modal.visual_notes_generic_failure");

    // When the server returned a specific reason (size / type / rate
    // limit / per-user policy), surface it. Without this the user gets
    // a generic "please try again" which obscures actionable causes —
    // e.g. "Sorry, the maximum filesize for uploads is 4 MB" or
    // "You have reached the maximum number of new posts in this hour".
    const detail = this._extractCauseMessage(cause);
    return detail ? `${base} ${detail}` : base;
  }

  _extractCauseMessage(cause) {
    if (!cause) {
      return null;
    }
    const json = cause?.jqXHR?.responseJSON ?? cause?.responseJSON;
    if (Array.isArray(json?.errors) && json.errors.length > 0) {
      return json.errors.join(". ");
    }
    if (typeof json?.error === "string") {
      return json.error;
    }
    if (typeof cause?.message === "string" && cause.message.length > 0) {
      return cause.message;
    }
    return null;
  }

  // ---- Processing Example ---------------------------------------------

  // Feature gate. Three layers:
  //
  //   1. Master plugin setting (npn_critique_reply_enabled)
  //   2. Feature-specific site setting
  //      (npn_critique_reply_processing_examples_enabled)
  //   3. Per-topic opt-out (npn_processing_examples_allowed): missing
  //      → allowed; only an explicit-false closes the section.
  //
  // Also requires an image — without a reference image there's
  // nothing meaningful to download or process.
  get processingExampleAvailable() {
    if (!this.siteSettings.npn_critique_reply_enabled) {
      return false;
    }
    if (!this.siteSettings.npn_critique_reply_processing_examples_enabled) {
      return false;
    }
    if (!this.hasImage) {
      return false;
    }
    return this.processingExampleAllowedByTopic;
  }

  // Topic-level opt-out. Missing/null → true (backward compat with
  // topics created before the submissions plugin grew the field).
  // Explicit false → disabled.
  get processingExampleAllowedByTopic() {
    const allowed = this.metadata?.processing_examples_allowed;
    return allowed !== false;
  }

  get hasProcessingExample() {
    return !!this.processingExample;
  }

  // Resolved direct-download URL for the currently-selected reference
  // image. Anchor with the `download` attribute points here; cross-
  // origin downloads (Bunny CDN) may fall back to "open in new tab",
  // which is the documented acceptable degradation per spec.
  get processingExampleSourceUrl() {
    return this.effectiveImageUrl ?? null;
  }

  get processingExampleSourceDownloadFilename() {
    return processingExampleSourceFilename(
      this.topic?.id,
      this.selectedVersionKey,
      this.processingExampleSourceUrl
    );
  }

  // Compose the processing-example block (heading + image markdown)
  // for inclusion in the final reply body. Empty string when there's
  // no example, so callers can concatenate unconditionally.
  _composeProcessingExampleBlock() {
    return composeProcessingExampleRaw({
      selectedVersion: this.selectedVersion,
      processingExample: this.processingExample,
    });
  }

  @action
  toggleMobileVisualTools() {
    this.mobileVisualToolsOpen = !this.mobileVisualToolsOpen;
  }

  @action
  toggleMobileProcessingExample() {
    this.mobileProcessingExampleOpen = !this.mobileProcessingExampleOpen;
  }

  @action
  toggleVisualFocusMode() {
    this.visualFocusMode = !this.visualFocusMode;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] visual-focus-mode", {
        topicId: this.topic?.id,
        active: this.visualFocusMode,
      });
    }
  }

  // Intercepts X / Escape / click-outside via DModal's `@beforeClose`
  // hook. Returning `false` cancels the close entirely (no exit
  // animation, no closeModal call) — that's how we keep the workspace
  // open after clicking X while Visual Focus Mode is on.
  //
  // First close attempt while focus mode is on → exits focus mode,
  // returns `false` (modal stays open). Subsequent attempts (now in
  // normal mode) → returns `true` and DModal proceeds with its
  // normal close. Toggling focus off preserves every piece of state
  // (text, annotations, version, processing example, draft).
  //
  // Wrapping `@closeModal` directly doesn't work — DModal runs its
  // exit animation BEFORE invoking the wrapped handler, so the modal
  // is already half-closed by the time we'd get to ignore the call.
  @action
  beforeClose() {
    if (this.visualFocusMode) {
      this.visualFocusMode = false;
      if (this.siteSettings.npn_critique_reply_debug_enabled) {
        // eslint-disable-next-line no-console
        console.info(
          "[npn-critique-reply] close intercepted; exited visual-focus-mode",
          { topicId: this.topic?.id }
        );
      }
      return false;
    }
    return true;
  }

  // Footer Cancel button. Calls `closeModal` directly (it doesn't
  // route through DModal's `beforeClose` because the button isn't
  // a DModal close trigger). Mirrors the same first-press-exits-
  // focus-mode behaviour as the X so the two close paths behave
  // consistently.
  @action
  cancelOrExitFocus() {
    if (this.visualFocusMode) {
      this.visualFocusMode = false;
      return;
    }
    this.args.closeModal?.();
  }

  // ---- Photographer's Notes lazy-load -----------------------------------

  get opCookedSafe() {
    if (!this._opCookedHtml) {
      return null;
    }
    return htmlSafe(this._opCookedHtml);
  }

  // Fires when the `<details>` for Photographer's Notes opens. First
  // open triggers a single GET to /posts/<op>.json; subsequent opens
  // reuse the cached cooked HTML. The OP's first post id comes from
  // either the topic model's `first_post_id` or the post stream — we
  // tolerate both shapes so a future Discourse upgrade that reshapes
  // the topic JSON still resolves.
  @action
  onPhotographersNotesToggle(event) {
    if (!event?.target?.open) {
      // Collapsing the panel dismisses the floating Quote button so
      // it doesn't dangle over later content. The body element
      // remains in the DOM under the collapsed details, so the
      // setup/teardown lifecycle does not re-run — we explicitly
      // reset the button state here.
      this._quoteButtonPosition = null;
      this._quoteSelectionText = "";
      return;
    }
    if (this._opCookedFetched || this._opCookedLoading) {
      return;
    }
    this._loadOpCooked();
  }

  async _loadOpCooked() {
    const topic = this.topic;
    if (!topic) {
      return;
    }
    const firstPostId =
      topic.first_post_id ??
      topic.get?.("first_post_id") ??
      topic.postStream?.posts?.[0]?.id ??
      topic.post_stream?.posts?.[0]?.id ??
      null;
    if (!firstPostId) {
      this._opCookedError = true;
      this._opCookedFetched = true;
      return;
    }

    this._opCookedLoading = true;
    try {
      const json = await ajax(`/posts/${firstPostId}.json`);
      if (this._destroyed) {
        return;
      }
      const cooked = json?.cooked ?? null;
      if (cooked) {
        this._opCookedHtml = this._filterOpCooked(cooked);
        // Capture attribution data for the Quote action. Username may
        // be missing on heavily redacted responses; post_number falls
        // back to 1 since the OP is always the first post. We do NOT
        // block the feature when these are missing — the quote falls
        // back to the unattributed `[quote]…[/quote]` form.
        this._opUsername = json?.username ?? null;
        this._opPostNumber = json?.post_number ?? 1;
      } else {
        this._opCookedError = true;
      }
    } catch (e) {
      if (this._destroyed) {
        return;
      }
      this._opCookedError = true;
      this._recordError(
        "photographers_notes_fetch",
        e,
        { topicId: topic?.id, firstPostId },
        "warn"
      );
    } finally {
      if (!this._destroyed) {
        this._opCookedLoading = false;
        this._opCookedFetched = true;
      }
    }
  }

  // ---- Photographer's Notes quote action -----------------------------

  // Attached via `{{didInsert}}` on the panel body. Captures the
  // container DOM ref + registers a debounced selectionchange listener.
  // Document-level listening is the standard pattern — `selectionchange`
  // only fires on `document`. We filter by container.contains() so
  // selections elsewhere in the modal are ignored.
  @action
  setupPhotographersNotes(element) {
    this._photographersNotesElement = element;
    if (this._selectionChangeHandler) {
      return;
    }
    this._selectionChangeHandler = () => {
      // rAF throttle: selectionchange fires every few ms during a
      // drag. We only need the latest state per paint to position
      // the button.
      if (this._selectionChangeRaf) {
        return;
      }
      this._selectionChangeRaf = requestAnimationFrame(() => {
        this._selectionChangeRaf = null;
        if (this._destroyed) {
          return;
        }
        this._updateQuoteButtonFromSelection();
      });
    };
    document.addEventListener("selectionchange", this._selectionChangeHandler);
    document.addEventListener("mousedown", this._maybeDismissQuoteButton, true);
  }

  // Called when the panel body unmounts (panel collapses, modal
  // closes, or cooked HTML re-renders for any reason). Drops the
  // container ref + listener so a stale node can't leak past teardown.
  @action
  teardownPhotographersNotes() {
    if (this._selectionChangeHandler) {
      document.removeEventListener(
        "selectionchange",
        this._selectionChangeHandler
      );
      this._selectionChangeHandler = null;
    }
    document.removeEventListener(
      "mousedown",
      this._maybeDismissQuoteButton,
      true
    );
    if (this._selectionChangeRaf) {
      cancelAnimationFrame(this._selectionChangeRaf);
      this._selectionChangeRaf = null;
    }
    this._photographersNotesElement = null;
    this._quoteButtonPosition = null;
    this._quoteSelectionText = "";
  }

  // ---- Pane "more below" scroll cue ---------------------------------

  // Captures the pane element so the click handler can scroll it.
  // The sentinel observer is wired up separately via
  // `setupPaneSentinel` so the sentinel's `did-insert` fires AFTER
  // the pane element is mounted regardless of children order.
  @action
  setupLeftPane(element) {
    this._leftPaneElement = element;
  }

  @action
  setupRightPane(element) {
    this._rightPaneElement = element;
  }

  // Wired to the sentinel <span> at the very end of each pane's
  // scrollable content. Uses an IntersectionObserver whose `root` is
  // the pane element — when the sentinel is intersecting the pane's
  // visible viewport, the user is at the bottom (or there's nothing
  // to scroll). Otherwise there's more content below the fold.
  //
  // Resolves the root via `element.closest(...)` instead of reading
  // `this._leftPaneElement`. Glimmer fires modifiers bottom-up, so
  // the sentinel's did-insert can run BEFORE the pane element's
  // did-insert sets the ref — closest() gives us the right node
  // synchronously regardless of ordering. setupLeftPane /
  // setupRightPane still cache the pane refs for the scroll-down
  // action.
  @action
  setupPaneSentinel(key, element) {
    if (!element || typeof IntersectionObserver === "undefined") {
      return;
    }
    const paneClass =
      key === "left"
        ? ".npn-critique-reply-modal__left-pane"
        : ".npn-critique-reply-modal__write-col";
    const root = element.closest(paneClass);
    if (!root) {
      return;
    }
    // Cache the ref here too as a defensive fallback in case
    // setupLeftPane/setupRightPane didn't run for any reason.
    if (key === "left" && !this._leftPaneElement) {
      this._leftPaneElement = root;
    } else if (key === "right" && !this._rightPaneElement) {
      this._rightPaneElement = root;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (this._destroyed) {
          return;
        }
        const intersecting = entries[0]?.isIntersecting ?? true;
        if (key === "left") {
          this._leftPaneHasMore = !intersecting;
        } else {
          this._rightPaneHasMore = !intersecting;
        }
      },
      { root, threshold: 0.01 }
    );
    observer.observe(element);
    this._paneSentinelObservers.push(observer);
  }

  @action
  scrollPaneDown(key) {
    const pane =
      key === "left" ? this._leftPaneElement : this._rightPaneElement;
    if (!pane) {
      return;
    }
    // Scroll by ~75% of the pane's visible height — enough to bring
    // the next section into view without skipping past it.
    const distance = Math.max(120, Math.round(pane.clientHeight * 0.75));
    try {
      pane.scrollBy({ top: distance, behavior: "smooth" });
    } catch {
      pane.scrollTop += distance;
    }
  }

  _teardownPaneSentinels() {
    for (const observer of this._paneSentinelObservers) {
      try {
        observer.disconnect();
      } catch {
        // Observer may have been GC'd along with its target — fine.
      }
    }
    this._paneSentinelObservers = [];
    this._leftPaneElement = null;
    this._rightPaneElement = null;
  }

  // Bound arrow form so the same identity can be added + removed
  // through addEventListener / removeEventListener. Hides the Quote
  // button when the user clicks outside the panel AND outside the
  // button itself — clicking the button is what fires the insert.
  _maybeDismissQuoteButton = (event) => {
    if (!this._quoteButtonPosition) {
      return;
    }
    const target = event.target;
    if (!(target instanceof Node)) {
      return;
    }
    if (this._photographersNotesElement?.contains(target)) {
      return;
    }
    // Closest .npn-critique-reply-modal__quote-button — the button
    // itself fires the insert; don't dismiss before its click runs.
    if (target instanceof Element &&
        target.closest(".npn-critique-reply-modal__quote-button")) {
      return;
    }
    this._quoteButtonPosition = null;
    this._quoteSelectionText = "";
  };

  _updateQuoteButtonFromSelection() {
    const container = this._photographersNotesElement;
    if (!container) {
      this._quoteButtonPosition = null;
      this._quoteSelectionText = "";
      return;
    }
    const selection = window.getSelection?.();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
      this._quoteButtonPosition = null;
      this._quoteSelectionText = "";
      return;
    }
    const range = selection.getRangeAt(0);
    // Both endpoints must live inside the panel. `contains` returns
    // true for the container itself, which is fine — text-node
    // ancestors resolve through the same chain.
    if (
      !container.contains(range.startContainer) ||
      !container.contains(range.endContainer)
    ) {
      this._quoteButtonPosition = null;
      this._quoteSelectionText = "";
      return;
    }
    const raw = selection.toString();
    const normalized = this._normalizeQuoteText(raw);
    if (!normalized) {
      this._quoteButtonPosition = null;
      this._quoteSelectionText = "";
      return;
    }
    this._quoteSelectionText = normalized;

    // Position the button near the END of the selection (above it
    // by default; below if the selection is near the top of the
    // viewport). Viewport coords from getBoundingClientRect work
    // with position: fixed.
    const rect = range.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) {
      this._quoteButtonPosition = null;
      return;
    }
    const BUTTON_HEIGHT = 32;
    const GAP = 6;
    // Anchor above the selection's top edge when there's room;
    // otherwise sit just below the selection so the button doesn't
    // cover the page chrome (modal header).
    let top = rect.top - BUTTON_HEIGHT - GAP;
    if (top < 8) {
      top = rect.bottom + GAP;
    }
    // Horizontally align to the right of the selection.
    let left = rect.right - 70;
    if (left < 8) {
      left = 8;
    }
    if (left > window.innerWidth - 90) {
      left = window.innerWidth - 90;
    }
    this._quoteButtonPosition = { top, left };
  }

  // Plain-text normalizer for selection content. `selection.toString()`
  // already inserts newlines between block elements; we just collapse
  // runs of whitespace WITHIN a line (not across newlines) and trim
  // each line. Empty trailing/leading lines are dropped. The result
  // either has paragraph breaks ("\n\n") between blocks or is a
  // single line for inline selections.
  _normalizeQuoteText(raw) {
    if (!raw) {
      return "";
    }
    const lines = raw
      .split(/\r?\n/)
      .map((line) => line.replace(/[ \t ]+/g, " ").trim());
    // Collapse runs of empty lines into a single paragraph break.
    const out = [];
    let lastBlank = true;
    for (const line of lines) {
      if (line === "") {
        if (!lastBlank) {
          out.push("");
          lastBlank = true;
        }
      } else {
        out.push(line);
        lastBlank = false;
      }
    }
    // Strip leading/trailing blanks
    while (out.length && out[0] === "") {
      out.shift();
    }
    while (out.length && out[out.length - 1] === "") {
      out.pop();
    }
    return out.join("\n");
  }

  // Click handler for the floating Quote button. Builds the quote
  // BBCode + inserts at the textarea caret via TextareaTextManipulation
  // (same path as Insert link). Dispatches a synthetic `input` event
  // so the draft autosaver picks up the change. Focuses the textarea
  // afterwards so the critic can keep typing.
  @action
  insertQuoteFromPhotographersNotes(event) {
    // Preventing default on mousedown / click keeps text selection
    // alive in some browsers, but since we read `_quoteSelectionText`
    // (snapshotted on selectionchange), even a cleared selection
    // doesn't break the insert.
    event?.preventDefault?.();
    const text = this._quoteSelectionText;
    if (!text) {
      this._quoteButtonPosition = null;
      return;
    }
    const attribution = this._buildQuoteAttribution();
    const quoteText = this._buildQuoteBlock(text, attribution);
    if (!this.#textManipulation || !this.#textarea) {
      // Defensive fallback — append to end of critiqueText with
      // the existing paragraph-spacing convention. The textarea
      // ref is set by didInsert and lives for the modal's lifetime,
      // so this path is unexpected in practice.
      this._appendToTextarea(quoteText);
    } else {
      try {
        const tm = this.#textManipulation;
        const sel = tm.getSelected();
        // Insert at caret with surrounding blank-line padding so
        // the quote always reads as its own paragraph. Read the
        // existing text + caret position to decide whether we need
        // leading / trailing newlines.
        const value = this.#textarea.value ?? "";
        const before = value.slice(0, sel.start);
        const after = value.slice(sel.end);
        let payload = quoteText;
        if (before && !/\n\n$/.test(before)) {
          payload = (before.endsWith("\n") ? "\n" : "\n\n") + payload;
        }
        if (after && !/^\n\n/.test(after)) {
          payload = payload + (after.startsWith("\n") ? "\n" : "\n\n");
        } else if (!after) {
          payload = payload + "\n";
        }
        tm.insertText(payload);
      } catch (e) {
        // Last-resort fallback — append to end.
        this._recordError("quote_insert", e, null, "warn");
        this._appendToTextarea(quoteText);
      }
    }
    // Dispatch a synthetic `input` event so the bound
    // `critiqueText` and the draft autosaver both see the change.
    // The Textarea component listens on the native `input` event.
    this.#textarea?.dispatchEvent(new Event("input", { bubbles: true }));
    this.#textarea?.focus();
    this._quoteButtonPosition = null;
    this._quoteSelectionText = "";
    // Clear the OP-side text selection so a stale highlight doesn't
    // linger after the quote has moved into the textarea.
    try {
      window.getSelection?.()?.removeAllRanges?.();
    } catch {
      // Some browsers throw on removeAllRanges in odd states; not
      // critical — the highlight will clear on the next click.
    }
  }

  _buildQuoteAttribution() {
    const username = (this._opUsername || "").trim();
    const topicId = this.topic?.id;
    const postNumber = this._opPostNumber;
    if (!username || !topicId || !postNumber) {
      return null;
    }
    return `${username}, post:${postNumber}, topic:${topicId}`;
  }

  _buildQuoteBlock(text, attribution) {
    const open = attribution ? `[quote="${attribution}"]` : "[quote]";
    return `${open}\n${text}\n[/quote]`;
  }

  // Strip duplicated content from the OP cooked HTML so the
  // Photographer's Notes panel shows the prose only. Removed:
  //   • `<img>` / `<picture>` / `a.lightbox` / `.lightbox-wrapper`
  //     / `.image-wrapper` — the reference image and its Discourse
  //     lightbox chrome. The critic is already looking at this
  //     image at full size; no need to re-render it here.
  //   • `.npn-critique-guidance` — the structured block the
  //     submissions plugin injects into the OP with Critique Style
  //     + Feedback Focus. The same info renders at the top of the
  //     right pane in the Photographer's Request card; duplicating
  //     it here makes the notes panel feel noisier than it is.
  //
  // Uses DOMParser rather than a regex so attribute-encoded ">"
  // characters and odd whitespace in tag attributes don't slip
  // through. Runs once at fetch time and the result is cached, so
  // the cost is paid exactly once per modal session.
  _filterOpCooked(html) {
    if (!html) {
      return html;
    }
    try {
      const doc = new DOMParser().parseFromString(html, "text/html");
      const selector = [
        "img",
        "picture",
        "a.lightbox",
        ".lightbox-wrapper",
        ".image-wrapper",
        ".npn-critique-guidance",
      ].join(",");
      doc.body.querySelectorAll(selector).forEach((el) => el.remove());
      // After the strip, the wrapping paragraphs/divs that USED to
      // hold the lightbox image are often left empty. They contribute
      // visible whitespace above the first real heading — the empty
      // gap where the photo used to be. Walk the body and drop any
      // node whose normalized text content is empty AND has no
      // remaining element children.
      doc.body
        .querySelectorAll("p, div, figure")
        .forEach((el) => {
          if (
            el.textContent.trim() === "" &&
            el.children.length === 0
          ) {
            el.remove();
          }
        });
      return doc.body.innerHTML;
    } catch (_e) {
      // If parsing fails for any reason, fall back to the original
      // cooked HTML rather than dropping the photographer's notes
      // entirely. Worst case: duplicated content shows.
      return html;
    }
  }

  @action
  toggleProcessingExampleMenu() {
    if (this.processingExampleMenuOpen) {
      this._closeProcessingExampleMenu();
    } else {
      this._openProcessingExampleMenu();
    }
  }

  _openProcessingExampleMenu() {
    this.processingExampleMenuOpen = true;
    // Defer wiring the click-outside listener so the same click that
    // opened the menu doesn't immediately re-close it.
    requestAnimationFrame(() => {
      if (this._destroyed || !this.processingExampleMenuOpen) {
        return;
      }
      this._processingExampleMenuOutsideHandler = (event) => {
        const root = document.getElementById(
          "npn-critique-reply-processing-example-menu"
        );
        const trigger = document.getElementById(
          "npn-critique-reply-processing-example-trigger"
        );
        if (!root) {
          return;
        }
        if (root.contains(event.target) || trigger?.contains(event.target)) {
          return;
        }
        this._closeProcessingExampleMenu();
      };
      document.addEventListener(
        "mousedown",
        this._processingExampleMenuOutsideHandler,
        true
      );
    });
  }

  _closeProcessingExampleMenu() {
    this.processingExampleMenuOpen = false;
    if (this._processingExampleMenuOutsideHandler) {
      document.removeEventListener(
        "mousedown",
        this._processingExampleMenuOutsideHandler,
        true
      );
      this._processingExampleMenuOutsideHandler = null;
    }
  }

  @action
  closeProcessingExampleMenu() {
    this._closeProcessingExampleMenu();
  }

  @action
  onProcessingExampleMenuKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      this._closeProcessingExampleMenu();
      // Return focus to the trigger button so keyboard users land
      // back on the control that opened the menu.
      document
        .getElementById("npn-critique-reply-processing-example-trigger")
        ?.focus?.();
    }
  }

  // Opens the hidden file input. The handler below reads the selected
  // file, uploads via Discourse's standard endpoint, and stores the
  // resulting upload reference in `this.processingExample`.
  @action
  triggerProcessingExampleFilePicker() {
    if (this.processingExampleUploading || this.isPosting) {
      return;
    }
    this.processingExampleError = null;
    const input = document.getElementById(
      "npn-critique-reply-processing-example-input"
    );
    input?.click?.();
  }

  @action
  async onProcessingExampleFileChange(event) {
    const file = event?.target?.files?.[0];
    // Reset the input so re-picking the same file fires `change` again.
    if (event?.target) {
      event.target.value = "";
    }
    if (!file) {
      return;
    }
    await this._uploadProcessingExampleFile(file);
  }

  async _uploadProcessingExampleFile(file) {
    if (!file) {
      return;
    }
    this.processingExampleUploading = true;
    this.processingExampleError = null;
    try {
      const filename = processingExampleFilename(
        this.topic?.id,
        this.selectedVersionKey,
        file.name
      );
      const upload = await uploadProcessingExampleFile(file, filename);
      if (this._destroyed) {
        return;
      }
      this.processingExample = {
        sourceImageVersionKey: this.selectedVersionKey ?? null,
        sourceImageVersionLabel: this.selectedVersion?.label ?? null,
        uploadId: upload?.upload_id ?? null,
        url: upload?.url ?? null,
        shortUrl: upload?.short_url ?? null,
        filename:
          upload?.original_filename ??
          file.name ??
          filename,
      };
      // Auto-switch the large image area to the freshly uploaded
      // example so the critic can immediately evaluate / write about
      // what they just submitted. Replace flows hit the same code
      // path and benefit from the same switch.
      this.largeImageView = LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE;
      // Keep the mobile Processing Example disclosure expanded after
      // a fresh / replacement upload so the Replace and Remove
      // actions are reachable without another tap.
      this.mobileProcessingExampleOpen = true;
      // Close the header quick-access menu so the user immediately
      // sees the just-uploaded example at large size instead of the
      // menu covering it. The below-image section still surfaces
      // the uploaded state.
      this._closeProcessingExampleMenu();
      this._scheduleDraftSaveAfterProcessingExampleChange();
    } catch (e) {
      if (this._destroyed) {
        return;
      }
      const stage = e?.stage ?? "upload";
      this.processingExampleError = {
        stage,
        message: this._processingExampleErrorMessage(stage),
      };
      this._recordError("processing_example_upload", e, { stage }, "warn");
    } finally {
      if (!this._destroyed) {
        this.processingExampleUploading = false;
      }
    }
  }

  @action
  removeProcessingExample() {
    if (this.processingExampleUploading || this.isPosting) {
      return;
    }
    this.processingExample = null;
    this.processingExampleError = null;
    // Switch the large area back to the reference image — there's
    // nothing else to show, and visual tools become relevant again.
    this.largeImageView = LARGE_IMAGE_VIEW_REFERENCE;
    // Close the header menu so the user immediately sees the
    // restored reference image.
    this._closeProcessingExampleMenu();
    this._scheduleDraftSaveAfterProcessingExampleChange();
  }

  // The draft autosaver listens for changes via the didUpdate
  // modifier on `draftSignature`. We compose that signature from a
  // subset of fields; manually scheduling here covers the case where
  // an action mutates only processingExample (no other tracked field
  // changes in the same tick).
  _scheduleDraftSaveAfterProcessingExampleChange() {
    if (this._restoringDraft) {
      return;
    }
    this._autosaver?.schedule?.();
  }

  _processingExampleErrorMessage(stage) {
    return (
      {
        upload: i18n(
          "npn_critique_reply.modal.processing_example.upload_failed"
        ),
      }[stage] ??
      i18n("npn_critique_reply.modal.processing_example.generic_failure")
    );
  }

  // ---- Actions ---------------------------------------------------------

  // Switch to a different submission image (submissions can carry up
  // to 5). Annotations are PRESERVED per-image — each image keeps its
  // own set of pins, crop, eye paths, areas, and arrows so the critic
  // can flip back and forth without losing work. The current image's
  // state is snapshotted on its way out and the target image's is
  // restored on the way in. Initial visits land on an empty set.
  @action
  selectImage(index) {
    if (
      typeof index !== "number" ||
      index < 0 ||
      index === this._selectedImageIndex
    ) {
      return;
    }
    this._switchImage(index);
  }

  @action
  selectPreviousImage() {
    if (this._selectedImageIndex <= 0) {
      return;
    }
    this.selectImage(this._selectedImageIndex - 1);
  }

  @action
  selectNextImage() {
    const count = this.submissionImages.length;
    if (count <= 1 || this._selectedImageIndex >= count - 1) {
      return;
    }
    this.selectImage(this._selectedImageIndex + 1);
  }

  _switchImage(index) {
    const oldIndex = this._selectedImageIndex;
    // Snapshot the outgoing image's annotations so we can restore
    // them when the critic flips back. Tracked fields stay as the
    // active-image state; the map is the per-image cold storage.
    this._annotationsByImageIndex.set(
      oldIndex,
      this._snapshotCurrentAnnotations()
    );
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] select-image", {
        topicId: this.topic?.id,
        from: oldIndex,
        to: index,
        snapshottedAnnotations: countSnapshotAnnotations(
          this._annotationsByImageIndex.get(oldIndex)
        ),
      });
    }
    this._selectedImageIndex = index;
    // Switching to a non-primary image leaves the revision selector
    // hidden. Switching BACK to the primary restores it. Drop any
    // explicit revision pick so the chain doesn't surface a stale
    // revision pointer when the critic returns to image 0 — the
    // selectedVersionKey getter falls back to default_key.
    if (index !== 0) {
      this._selectedVersionKey = null;
    }
    // Restore the incoming image's snapshot (or empty if first visit).
    this._restoreAnnotationsFromSnapshot(
      this._annotationsByImageIndex.get(index)
    );
  }

  // Build a plain-object snapshot of the current image's annotation
  // state. Used both during image switches (to stash before swapping)
  // and at draft-build time (to capture the active image's edits
  // before serializing the per-image map). Selection IDs and pending
  // popovers are NOT snapshotted — they're transient UI state that
  // shouldn't survive an image switch.
  _snapshotCurrentAnnotations() {
    return {
      notes: cloneAnnotationArray(this.notes),
      crop: this.crop ? { ...this.crop } : null,
      eyePaths: cloneEyePathsForSnapshot(this.eyePaths),
      attentionPulls: cloneAnnotationArray(this.attentionPulls),
      strongAreas: cloneAnnotationArray(this.strongAreas),
      directionArrows: cloneAnnotationArray(this.directionArrows),
      relationshipArrows: cloneAnnotationArray(this.relationshipArrows),
    };
  }

  // Apply a snapshot (or undefined for a first-time visit) to the
  // tracked active-image fields. Also clears all transient selection
  // state, since the visual layer is about to re-mount around the
  // new image.
  _restoreAnnotationsFromSnapshot(snapshot) {
    this.notes = snapshot?.notes ? cloneAnnotationArray(snapshot.notes) : [];
    this.crop = snapshot?.crop ? { ...snapshot.crop } : null;
    this.eyePaths = snapshot?.eyePaths
      ? cloneEyePathsForSnapshot(snapshot.eyePaths)
      : [];
    this.attentionPulls = snapshot?.attentionPulls
      ? cloneAnnotationArray(snapshot.attentionPulls)
      : [];
    this.strongAreas = snapshot?.strongAreas
      ? cloneAnnotationArray(snapshot.strongAreas)
      : [];
    this.directionArrows = snapshot?.directionArrows
      ? cloneAnnotationArray(snapshot.directionArrows)
      : [];
    this.relationshipArrows = snapshot?.relationshipArrows
      ? cloneAnnotationArray(snapshot.relationshipArrows)
      : [];
    // Transient state always resets on image swap.
    this._activeEyePathId = null;
    this._eyePathStarterInserted = false;
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    this.visualMode = null;
    this.pendingPin = null;
    this.pendingPinNoteText = "";
    this.pendingAttentionPullPopover = null;
    this.pendingAttentionPullPopoverText = "";
    this.pendingStrongAreaPopover = null;
    this.pendingStrongAreaPopoverText = "";
    this.pendingEyePathPopover = null;
    this.pendingEyePathPopoverText = "";
    this.pendingDirectionArrowPopover = null;
    this.pendingDirectionArrowPopoverText = "";
    this.pendingRelationshipArrowPopover = null;
    this.pendingRelationshipArrowPopoverText = "";
    this.pendingCropPopover = null;
    this.pendingCropPopoverText = "";
  }

  // Version switch (revision change) wipes the current image's
  // annotations — revisions share the SAME submission position so
  // there's no separate snapshot slot for them. We also clear the
  // per-image map's entry for this index so the cleared state
  // sticks if the critic flips to another image and back. Multi-
  // image picker uses the snapshot path instead — see _switchImage.
  _resetAnnotationsForImageSwitch() {
    this._annotationsByImageIndex.delete(this._selectedImageIndex);
    this._restoreAnnotationsFromSnapshot(null);
  }

  @action
  selectVersion(key) {
    if (key === this.selectedVersionKey) {
      return;
    }
    // All visual annotations (pins, crop, eye path) are anchored to the
    // current image's pixel space. Warn the critic if any exist;
    // confirm wipes all of them. Cancelling keeps the current version
    // and annotations untouched.
    if (this.hasVisualAnnotations) {
      this.dialog.confirm({
        message: i18n(
          "npn_critique_reply.visual_notes.confirm_clear_all_on_switch"
        ),
        confirmButtonLabel: "npn_critique_reply.visual_notes.switch_and_clear",
        didConfirm: () => this._switchVersion(key),
      });
      return;
    }
    this._switchVersion(key);
  }

  _switchVersion(key) {
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] select-version", {
        topicId: this.topic?.id,
        key,
        clearedNotes: this.notes.length,
        clearedCrop: !!this.crop,
        clearedEyePath: this.hasEyePath,
      });
    }
    this._selectedVersionKey = key;
    // Always reset annotations — they're tied to the previous image's
    // pixel layout. The textarea (including [N] lines and any starter
    // text from the crop or eye-path tools) is intentionally left
    // alone per spec. Shared with the submission-image switch flow.
    this._resetAnnotationsForImageSwitch();
  }

  // -- Visual Notes ------------------------------------------------------

  get visualNotesAvailable() {
    if (!this.siteSettings.npn_critique_reply_visual_notes_enabled) {
      return false;
    }
    if (!this.hasImage) {
      return false;
    }
    if (this.currentUser?.staff) {
      return true;
    }
    const allowedGroupIds = parseIdList(
      this.siteSettings.npn_critique_reply_visual_notes_allowed_group_ids
    );
    if (allowedGroupIds.length === 0) {
      // Empty list → staff-only (we returned true for staff above).
      return false;
    }
    const userGroupIds = (this.currentUser?.groups ?? []).map((g) => g.id);
    return allowedGroupIds.some((id) => userGroupIds.includes(id));
  }

  // Convenience getters so existing toolbar branches still read well.
  get noteMode() {
    return this.visualMode === "numbered_notes";
  }
  get cropMode() {
    return this.visualMode === "crop_suggestion";
  }
  get eyePathMode() {
    return this.visualMode === "eye_path";
  }
  get attentionPullMode() {
    return this.visualMode === "attention_pull";
  }
  get strongAreaMode() {
    return this.visualMode === "strong_area";
  }
  get directionArrowMode() {
    return this.visualMode === "direction_arrow";
  }
  get relationshipArrowMode() {
    return this.visualMode === "relationship_arrow";
  }

  // Unified contextual help line for the visual tools. Replaces the
  // per-mode inline hints that used to sit inside each tool's
  // secondary-toolbar branch. Beta feedback: testers wanted ONE
  // consistent place that explains what the current tool / sub-tool
  // does, updating as they pick things. Order matters here — sub-tool
  // states are checked before the parent tool so Eye Path / Area /
  // Crop sub-mode copy takes precedence over the generic tool copy.
  get activeToolHelpText() {
    // Retrace is a transient sub-action; same hint applies whether
    // it's an attention pull or a strong area being retraced.
    if (this.retracingAttentionPullId || this.retracingStrongAreaId) {
      return i18n("npn_critique_reply.visual_notes.tools_help.retrace");
    }
    if (this.eyePathMode) {
      if (this.eyePathInteractionMode === "points") {
        return i18n(
          "npn_critique_reply.visual_notes.tools_help.eye_path_points"
        );
      }
      if (this.eyePathInteractionMode === "stroke") {
        return i18n(
          "npn_critique_reply.visual_notes.tools_help.eye_path_stroke"
        );
      }
      return i18n("npn_critique_reply.visual_notes.tools_help.eye_path");
    }
    if (this.attentionPullMode || this.strongAreaMode) {
      if (this.areaShapeMode === "oval") {
        return i18n("npn_critique_reply.visual_notes.tools_help.area_oval");
      }
      if (this.areaShapeMode === "path") {
        return i18n("npn_critique_reply.visual_notes.tools_help.area_draw");
      }
      return i18n("npn_critique_reply.visual_notes.tools_help.area");
    }
    if (this.cropMode) {
      const ratio = this.cropAspectRatio;
      if (!ratio || ratio === "free") {
        return i18n("npn_critique_reply.visual_notes.tools_help.crop_free");
      }
      // Named ratio (e.g. 4:5) — drop the ratio name into the copy so
      // the help line tells the user exactly what they're about to
      // draw.
      return i18n(
        "npn_critique_reply.visual_notes.tools_help.crop_named_ratio",
        { ratio }
      );
    }
    if (this.noteMode) {
      return i18n("npn_critique_reply.visual_notes.tools_help.notes");
    }
    if (this.directionArrowMode) {
      return i18n("npn_critique_reply.visual_notes.tools_help.arrow");
    }
    if (this.relationshipArrowMode) {
      return i18n("npn_critique_reply.visual_notes.tools_help.relationship");
    }
    return i18n("npn_critique_reply.visual_notes.tools_help.default");
  }

  @action
  toggleNoteMode() {
    this._setVisualMode(this.noteMode ? null : "numbered_notes");
  }

  @action
  toggleCropMode() {
    this._setVisualMode(this.cropMode ? null : "crop_suggestion");
  }

  @action
  toggleEyePathMode() {
    this._setVisualMode(this.eyePathMode ? null : "eye_path");
  }

  @action
  toggleAttentionPullMode() {
    this._setVisualMode(this.attentionPullMode ? null : "attention_pull");
  }

  @action
  toggleStrongAreaMode() {
    this._setVisualMode(this.strongAreaMode ? null : "strong_area");
  }

  @action
  toggleDirectionArrowMode() {
    this._setVisualMode(
      this.directionArrowMode ? null : "direction_arrow"
    );
  }

  @action
  toggleRelationshipArrowMode() {
    this._setVisualMode(
      this.relationshipArrowMode ? null : "relationship_arrow"
    );
  }

  _setVisualMode(mode) {
    if (mode === this.visualMode) {
      return;
    }
    // Leaving numbered-notes mode while a popover is open is treated
    // as Skip — append the bare marker so the critic doesn't lose
    // the visual/written connection on the pin they just placed.
    if (this.pendingPin && mode !== "numbered_notes") {
      this._appendPinMarker(this.pendingPin.number, "");
      this.pendingPin = null;
      this.pendingPinNoteText = "";
    }
    // Leaving attention_pull mode dismisses its popover (Skip-equivalent
    // — no text appended). Same for strong_area and eye_path modes.
    if (this.pendingAttentionPullPopover && mode !== "attention_pull") {
      this.pendingAttentionPullPopover = null;
      this.pendingAttentionPullPopoverText = "";
    }
    if (this.pendingStrongAreaPopover && mode !== "strong_area") {
      this.pendingStrongAreaPopover = null;
      this.pendingStrongAreaPopoverText = "";
    }
    if (this.pendingEyePathPopover && mode !== "eye_path") {
      this.pendingEyePathPopover = null;
      this.pendingEyePathPopoverText = "";
    }
    if (this.pendingCropPopover && mode !== "crop_suggestion") {
      this.pendingCropPopover = null;
      this.pendingCropPopoverText = "";
    }
    if (
      this.pendingDirectionArrowPopover &&
      mode !== "direction_arrow"
    ) {
      this.pendingDirectionArrowPopover = null;
      this.pendingDirectionArrowPopoverText = "";
    }
    if (
      this.pendingRelationshipArrowPopover &&
      mode !== "relationship_arrow"
    ) {
      this.pendingRelationshipArrowPopover = null;
      this.pendingRelationshipArrowPopoverText = "";
    }
    const previousMode = this.visualMode;
    this.visualMode = mode;
    // Switching modes drops any active selection so toolbar context
    // stays in sync with the chosen tool. Existing annotations of all
    // kinds are preserved — only the selection state resets.
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    // Cancel any in-flight retrace — the marker it targeted is now
    // unselected (and the new tool may not even support retrace).
    this.retracingAttentionPullId = null;
    this.retracingStrongAreaId = null;
    // Eye-path session tracking. A path session ends when its
    // description popover is dismissed (Confirm or Skip) or when the
    // user leaves eye_path mode — at that point the next click /
    // drag begins a new path. Stroke mode commits a whole path per
    // drag, so the popover opens immediately and dismissal moves on
    // to the next path. Points mode keeps the session open across
    // clicks; dismissing the popover finalises the current path.
    // Re-entering eye_path mode also resets the session pointer.
    if (mode === "eye_path" && previousMode !== "eye_path") {
      this._activeEyePathId = null;
      this._eyePathStarterInserted = false;
    } else if (previousMode === "eye_path" && mode !== "eye_path") {
      this._activeEyePathId = null;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] set-visual-mode", {
        topicId: this.topic?.id,
        visualMode: this.visualMode,
      });
    }
  }

  @action
  clearNotes() {
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] clear-notes", {
        topicId: this.topic?.id,
        clearedCount: this.notes.length,
      });
    }
    // Per spec: clearing pins does NOT alter the textarea. Critics can
    // edit/remove the [N] lines themselves — auto-removing them would
    // risk eating user-written context attached to those numbers.
    this.notes = [];
    this.selectedPinNumber = null;
    // Any in-flight popover refers to a pin we're about to discard;
    // close without writing anything (the pin will be gone, so the
    // marker would dangle).
    this.pendingPin = null;
    this.pendingPinNoteText = "";
  }

  // Per-pin selection / removal --------------------------------------
  //
  // Click a pin → select it (toggle if clicked again). Selection shows
  // a non-color cue on the pin itself (scale + outer ring) plus a
  // "Remove note N" button in the toolbar. Removing a pin leaves the
  // remaining pins' numbers stable so any prose the critic already
  // wrote against [1], [2], [3]… continues to make sense.

  @action
  selectPin(pin) {
    if (!pin) {
      return;
    }
    // Clicking a shape activates the corresponding tool mode so the
    // user can immediately move / resize / edit it without a separate
    // toolbar click. `_setVisualMode` is a no-op when the mode is
    // already active, and it resets every selection state — we then
    // re-set the one we want below.
    this._setVisualMode("numbered_notes");
    // Selecting a pin deselects all other annotation kinds. The
    // toolbar only ever surfaces one Remove button at a time, so we
    // keep the model in sync across pin / crop / eye path / attention
    // pull / strong area.
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    if (this.selectedPinNumber === pin.number) {
      this.selectedPinNumber = null;
    } else {
      this.selectedPinNumber = pin.number;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] select-pin", {
        topicId: this.topic?.id,
        number: pin.number,
        selected: this.selectedPinNumber,
      });
    }
  }

  // ---- Crop ------------------------------------------------------------

  @action
  addCrop(xPct, yPct, widthPct, heightPct) {
    if (this.visualMode !== "crop_suggestion") {
      return;
    }
    if (this.crop) {
      // Stage shouldn't emit add events when crop already exists, but
      // belt-and-braces here.
      return;
    }
    // Numbered crop labels kick in only when 2+ crops exist across
    // the whole critique. Singles stay as "[Crop]" (legacy
    // aesthetic). On the 1→2 transition we retroactively label the
    // existing crop "Crop 1" — both its stored label and the
    // textarea token it left behind — and assign "Crop 2" to the
    // new one. Beyond that, each new crop is "Crop {existing+1}".
    const existingCropCount = this._cropCountAcrossImages();
    let cropLabel = null;
    if (existingCropCount === 1) {
      this._retroactivelyLabelFirstCrop();
      cropLabel = "Crop 2";
    } else if (existingCropCount >= 2) {
      cropLabel = `Crop ${existingCropCount + 1}`;
    }
    // Tie the crop's id to the active image's index so two images
    // each carrying a crop don't both arrive at the server as
    // `crop_1` — the server's seen-id dedupe would drop the second
    // one and the cooked post would lose Crop 2. Image 0's crop is
    // still `crop_1` (matching the legacy single-image case).
    this.crop = {
      id: `crop_${this._selectedImageIndex + 1}`,
      label: cropLabel,
      xPct,
      yPct,
      widthPct,
      heightPct,
      aspectRatio: this.cropAspectRatio,
    };
    // Auto-select on placement so the Transformer mounts immediately
    // and the user can move/resize without an extra click.
    this.cropSelected = true;
    this.selectedPinNumber = null;

    // Open the description popover anchored at the centre of the new
    // crop. Mirrors the attention-pull / strong-area / arrow flow:
    // user types optional text → confirm → `[CROP] {text}` appended.
    // Skip closes without writing anything (the styled [CROP] pill
    // in the cooked post acts as the marker by itself if the user
    // doesn't type a description).
    //
    // If a stale popover from a previous crop is still open, treat
    // this new add as implicit Skip on it.
    if (this.pendingCropPopover) {
      this.pendingCropPopover = null;
      this.pendingCropPopoverText = "";
    }
    this.pendingCropPopover = {
      anchorXPct: xPct + widthPct / 2,
      anchorYPct: yPct + heightPct / 2,
    };
    this.pendingCropPopoverText = "";

    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-crop", {
        topicId: this.topic?.id,
        crop: this.crop,
      });
    }
  }

  @action
  selectCrop() {
    if (!this.crop) {
      return;
    }
    // Clicking a shape activates the corresponding tool mode (see
    // selectPin for rationale). `_setVisualMode` resets every
    // selection — we re-set ours below.
    this._setVisualMode("crop_suggestion");
    this.selectedPinNumber = null;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    this.cropSelected = !this.cropSelected;
  }

  // Fired by the Konva stage on dragend / transformend. Updates the
  // crop's coordinates without changing identity (id / aspectRatio).
  // The next stage.update() call sees identical coords and skips the
  // re-render — see sameCrop() in the stage module.
  @action
  updateCrop(xPct, yPct, widthPct, heightPct) {
    if (!this.crop) {
      return;
    }
    this.crop = {
      ...this.crop,
      xPct,
      yPct,
      widthPct,
      heightPct,
    };
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] update-crop", {
        topicId: this.topic?.id,
        crop: this.crop,
      });
    }
  }

  // ---- Crop aspect ratio ----------------------------------------------

  // Order matches the toolbar layout: Free, square, then portrait/
  // landscape pairs grouped together (2:3 ↔ 3:2, 4:5 ↔ 5:4),
  // ending with wide. Keys must match ASPECT_RATIO_VALUES in the
  // Konva stage.
  cropRatioOptions = [
    "free",
    "1:1",
    "2:3",
    "3:2",
    "4:5",
    "5:4",
    "16:9",
  ];

  @action
  setCropAspectRatio(ratio) {
    if (this.cropAspectRatio === ratio) {
      return;
    }
    this.cropAspectRatio = ratio;
    // Keep the schema's aspect_ratio field on the active crop in sync.
    // The Konva stage will see the new ratio in its next `update()`
    // call and snap the geometry — its onUpdateCrop callback will
    // then bring x/y/width/height back through `updateCrop`.
    if (this.crop) {
      this.crop = { ...this.crop, aspectRatio: ratio };
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] set-crop-aspect-ratio", {
        topicId: this.topic?.id,
        aspectRatio: ratio,
      });
    }
  }

  @action
  clearCrop() {
    if (!this.crop) {
      return;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] clear-crop", {
        topicId: this.topic?.id,
      });
    }
    this.crop = null;
    this.cropSelected = false;
    // Textarea text stays; the critic decides if they want to edit it.
  }

  @action
  replaceCrop() {
    // Same effect as Clear, but keeps the modal in crop mode so the
    // critic can immediately drag a new rectangle.
    this.clearCrop();
    this._setVisualMode("crop_suggestion");
  }

  // ---- Eye path / Visual Flow ----------------------------------------

  // Commit a multi-point eye-path in one state mutation. Used by the
  // drag-to-trace gesture in the Konva stage: the stage samples many
  // points during a single pointer drag and hands them all to this
  // action on pointerup. Calling addEyePathPoint N times would also
  // work but would trigger N tracked-state reflows; this path is one
  // update for the whole shape.
  //
  // Stroke is a one-shot gesture: each drag commits a complete path,
  // immediately clears the active-session pointer, and opens the
  // description popover. Dismissing the popover ends the path session
  // so the next gesture (in either mode) starts a brand-new path.
  //
  // Caps + dedup happen here so the stage stays dumb:
  //   • bail when at MAX_EYE_PATH_COUNT (no more paths allowed)
  //   • truncate to MAX_EYE_PATH_POINTS (40, per schema)
  //   • require ≥ 2 points (a single-point "drag" falls back to
  //     a regular click via addEyePathPoint instead)
  @action
  commitEyePath(points) {
    if (this.visualMode !== "eye_path") {
      return;
    }
    if (!Array.isArray(points) || points.length < 2) {
      return;
    }
    if (this.eyePathsAtMax) {
      return;
    }

    const trimmed = points.slice(0, MAX_EYE_PATH_POINTS).map((p, i) => ({
      number: i + 1,
      xPct: p.xPct,
      yPct: p.yPct,
    }));

    // Eye-path id/label are both global across all submission images.
    // Without the global id, two images would each get `eye_path_1`
    // and the server's seen-id dedupe would drop the second path
    // from the stored payload — the cooked post would then have no
    // label for [E2] and the badge decorator would leave it as
    // plain text.
    const newId = nextEyePathId(
      this._allAnnotationsAcrossImages("eyePaths").map((p) => p.id)
    );
    const newLabel = nextEyePathLabel(this._allLabelsAcrossImages("eyePaths"));
    // commitEyePath fires from drag-to-trace → always a stroke path
    // regardless of the toggle. The toggle position is the user's
    // intent for the NEXT interaction; this callback comes from an
    // interaction that already completed in stroke form.
    const newPath = {
      id: newId,
      label: newLabel,
      mode: "stroke",
      points: trimmed,
    };

    this.eyePaths = [...this.eyePaths, newPath];
    // Stroke is a one-shot gesture — the drag IS the whole path. Clear
    // the active-session pointer immediately so the next gesture (in
    // either mode) starts a new path. Selection still points at the
    // just-committed path so the popover's `selectedEyePath` fallback
    // attaches noteText to the right shape.
    this._activeEyePathId = null;
    this.selectedEyePathId = newId;

    // Same description popover trigger the click flow uses — opens
    // at the end of the just-drawn path so the user can label it.
    // Anchored to the path's last point.
    const last = trimmed[trimmed.length - 1];
    this.pendingEyePathPopover = {
      anchorXPct: last.xPct,
      anchorYPct: last.yPct,
    };
    this.pendingEyePathPopoverText = "";
    this._eyePathStarterInserted = true;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] commit-eye-path", {
        topicId: this.topic?.id,
        pathId: newId,
        pointCount: trimmed.length,
      });
    }
  }

  @action
  addEyePathPoint(xPct, yPct) {
    if (this.visualMode !== "eye_path") {
      return;
    }

    let activePath = this.activeEyePath;

    // No active path yet in this mode-entry session — start one. Cap
    // enforced here as well as in the normalizer so the user can't
    // build past the limit on the client even if some bug let the
    // tool stay enabled.
    if (!activePath) {
      if (this.eyePathsAtMax) {
        if (this.siteSettings.npn_critique_reply_debug_enabled) {
          // eslint-disable-next-line no-console
          console.info("[npn-critique-reply] add-eye-path-point at cap", {
            topicId: this.topic?.id,
            existing: this.eyePathCount,
            cap: MAX_EYE_PATH_COUNT,
          });
        }
        return;
      }
      // Same global id/label rule as the stroke commit path above.
      const newId = nextEyePathId(
        this._allAnnotationsAcrossImages("eyePaths").map((p) => p.id)
      );
      const newLabel = nextEyePathLabel(
        this._allLabelsAcrossImages("eyePaths")
      );
      // Click-to-add → tag as Points. In Stroke mode the Konva stage
      // shouldn't fire this callback at all (short presses are
      // dropped); defensive tag here in case it does.
      activePath = {
        id: newId,
        label: newLabel,
        mode: "points",
        points: [],
      };
      this.eyePaths = [...this.eyePaths, activePath];
      this._activeEyePathId = newId;
      this.selectedEyePathId = newId;
    }

    const currentPoints = activePath.points ?? [];
    if (currentPoints.length >= MAX_EYE_PATH_POINTS) {
      return;
    }
    const nextNumber = currentPoints.length + 1;
    const newPoints = [...currentPoints, { number: nextNumber, xPct, yPct }];

    this.eyePaths = this.eyePaths.map((p) =>
      p.id === this._activeEyePathId ? { ...p, points: newPoints } : p
    );

    // Open the description popover once per session, anchored at the
    // second point (the moment the path becomes "meaningful" — it
    // has a direction). _eyePathStarterInserted is reset whenever
    // the user enters eye_path mode, so each session gets exactly
    // one prompt.
    if (newPoints.length === 2 && !this._eyePathStarterInserted) {
      this._eyePathStarterInserted = true;
      this.pendingEyePathPopover = {
        anchorXPct: xPct,
        anchorYPct: yPct,
      };
      this.pendingEyePathPopoverText = "";
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-eye-path-point", {
        topicId: this.topic?.id,
        pathId: this._activeEyePathId,
        number: nextNumber,
        xPct,
        yPct,
        starterInsertedThisSession: this._eyePathStarterInserted,
      });
    }
  }

  // Fired by the Konva stage on per-point dragend. Updates the
  // matching point's coords without changing its number. The stage
  // updates its own closure-cached path BEFORE invoking this
  // callback, so the next sync sees identical values and skips a
  // redundant re-render.
  @action
  moveEyePathPoint(pathId, number, xPct, yPct) {
    if (!pathId || number == null) {
      return;
    }
    this.eyePaths = this.eyePaths.map((p) =>
      p.id === pathId
        ? {
            ...p,
            points: (p.points ?? []).map((pt) =>
              pt.number === number ? { ...pt, xPct, yPct } : pt
            ),
          }
        : p
    );
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] move-eye-path-point", {
        topicId: this.topic?.id,
        pathId,
        number,
        xPct,
        yPct,
      });
    }
  }

  // Toolbar "Remove last point" — operates on the path the user is
  // focused on (the active session path during construction, or the
  // selected path otherwise). If removing the last point would empty
  // the path, drop it from the eyePaths array entirely.
  @action
  removeLastEyePathPoint() {
    const targetPath = this.focusedEyePath;
    if (!targetPath) {
      return;
    }
    const targetId = targetPath.id;
    const current = targetPath.points ?? [];
    if (current.length === 0) {
      return;
    }
    const next = current.slice(0, -1);
    if (next.length === 0) {
      this.eyePaths = this.eyePaths.filter((p) => p.id !== targetId);
      if (this.selectedEyePathId === targetId) {
        this.selectedEyePathId = null;
      }
      if (this._activeEyePathId === targetId) {
        this._activeEyePathId = null;
      }
      // Popover only ever anchored to the path currently being built;
      // if we just removed THAT path, clear the popover too.
      this.pendingEyePathPopover = null;
      this.pendingEyePathPopoverText = "";
    } else {
      this.eyePaths = this.eyePaths.map((p) =>
        p.id === targetId ? { ...p, points: next } : p
      );
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-last-eye-path-point", {
        topicId: this.topic?.id,
        pathId: targetId,
        remaining: next.length,
      });
    }
  }

  // Drop the path with the given id. Used by the a11y list's per-row
  // Remove button (one row per path with multi-path support).
  @action
  removeEyePathById(pathId) {
    if (!pathId) {
      return;
    }
    if (!this.eyePaths.some((p) => p.id === pathId)) {
      return;
    }
    this.eyePaths = this.eyePaths.filter((p) => p.id !== pathId);
    if (this.selectedEyePathId === pathId) {
      this.selectedEyePathId = null;
    }
    if (this._activeEyePathId === pathId) {
      this._activeEyePathId = null;
      this._eyePathStarterInserted = false;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-eye-path-by-id", {
        topicId: this.topic?.id,
        pathId,
      });
    }
  }

  // Toolbar "Remove selected path" — drops the selected path entirely.
  // Mirrors the per-pin / per-attention-pull remove pattern. Returns
  // the modal to "no eye-path selected" state without leaving
  // eye_path mode (so the user can start another path immediately).
  @action
  removeSelectedEyePath() {
    const targetId = this.selectedEyePathId ?? this._activeEyePathId;
    if (!targetId) {
      return;
    }
    this.eyePaths = this.eyePaths.filter((p) => p.id !== targetId);
    if (this.selectedEyePathId === targetId) {
      this.selectedEyePathId = null;
    }
    if (this._activeEyePathId === targetId) {
      this._activeEyePathId = null;
      this._eyePathStarterInserted = false;
    }
    this.pendingEyePathPopover = null;
    this.pendingEyePathPopoverText = "";
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-eye-path", {
        topicId: this.topic?.id,
        pathId: targetId,
      });
    }
  }

  // Click on a path (curve hit-zone or waypoint dot). Toggles
  // selection: clicking the currently-selected path deselects it,
  // clicking a different path swaps selection to it. Also switches
  // tool mode to eye_path so the toolbar shows path-specific
  // controls (matches the pattern other annotation selects use).
  @action
  selectEyePath(pathId) {
    if (!pathId) {
      return;
    }
    if (!this.eyePaths.some((p) => p.id === pathId)) {
      return;
    }
    this._setVisualMode("eye_path");
    // Mirror the cross-kind selection mutex.
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    // Selecting an EXISTING path takes over from the active session
    // — the next click on empty stage should still start a new path
    // (active session = null), which preserves the user's expectation
    // that selection ≠ extension.
    this._activeEyePathId = null;
    this.selectedEyePathId =
      this.selectedEyePathId === pathId ? null : pathId;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] select-eye-path", {
        topicId: this.topic?.id,
        pathId,
        selected: this.selectedEyePathId,
      });
    }
  }

  // Toolbar "New eye path" — explicit "I'm done with the current
  // path, start another one without toggling the tool off and on."
  // Resets only the session pointers; existing paths stay drawn and
  // selectable. The next click on empty stage will create a new
  // path (same path as the first-click-of-a-fresh-mode-entry flow).
  //
  // Also dismisses any open description popover as Skip-equivalent
  // — the popover anchors to the path the user is about to leave
  // behind, so it would otherwise read as "describe this path"
  // when the user has already moved on.
  @action
  startNewEyePath() {
    if (this.visualMode !== "eye_path") {
      return;
    }
    if (this.eyePathsAtMax) {
      return;
    }
    this._activeEyePathId = null;
    this._eyePathStarterInserted = false;
    this.selectedEyePathId = null;
    if (this.pendingEyePathPopover) {
      this.pendingEyePathPopover = null;
      this.pendingEyePathPopoverText = "";
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] start-new-eye-path", {
        topicId: this.topic?.id,
        existing: this.eyePathCount,
      });
    }
  }

  // Toolbar "Clear all paths" — wipes every eye path. Distinct from
  // removeSelectedEyePath which only drops the focused one.
  @action
  clearEyePath() {
    if (this.eyePaths.length === 0) {
      return;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] clear-eye-path", {
        topicId: this.topic?.id,
        cleared: this.eyePaths.length,
      });
    }
    this.eyePaths = [];
    this.selectedEyePathId = null;
    this._activeEyePathId = null;
    this._eyePathStarterInserted = false;
    this.pendingEyePathPopover = null;
    this.pendingEyePathPopoverText = "";
    // Textarea text stays; the critic decides if they want to edit
    // the starter line they wrote against.
  }

  // ---- Attention Pull ------------------------------------------------

  // Fired by the Konva stage on a drag-release in attention_pull mode.
  // Creates a new marker (silently dropping drags below the schema's
  // tiny-marker floor — the stage also enforces this). On the FIRST
  // attention pull of the session, inserts a single textarea starter
  // — never re-inserted for additional markers.
  @action
  setAreaShapeMode(mode) {
    if (mode !== "oval" && mode !== "path") {
      return;
    }
    this.areaShapeMode = mode;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] area-shape-mode", { mode });
    }
  }

  // Eye Path mode toggle (Stroke / Points). Switching mid-session
  // doesn't touch existing paths — already-committed paths keep
  // their stored `mode`. The next new path takes the freshly-
  // selected mode.
  @action
  setEyePathInteractionMode(mode) {
    if (mode !== "stroke" && mode !== "points") {
      return;
    }
    this.eyePathInteractionMode = mode;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] eye-path-mode", { mode });
    }
  }

  // Path-shape commit for Attention. The Konva stage samples + DP-
  // simplifies during drag and hands us the trimmed point array on
  // release. Geometry stored alongside the existing ellipse pulls;
  // a `shape: "path"` discriminator marks the new variant so the
  // renderer + exporter + server normalizer can branch correctly.
  @action
  addAttentionPullPath(points) {
    if (this.visualMode !== "attention_pull") {
      return;
    }
    if (this.attentionPullsAtMax) {
      return;
    }
    if (!Array.isArray(points) || points.length < 4) {
      return;
    }
    if (this.pendingAttentionPullPopover) {
      this.pendingAttentionPullPopover = null;
      this.pendingAttentionPullPopoverText = "";
    }
    this._attentionPullIdCounter += 1;
    const id = `attention_pull_${this._attentionPullIdCounter}`;
    // Area labels (A1, A2, ...) are global across submission images.
    const label = nextAttentionPullLabel(
      this._allLabelsAcrossImages("attentionPulls")
    );
    // Bounding box for popover anchoring + note placement
    const xs = points.map((p) => p.xPct);
    const ys = points.map((p) => p.yPct);
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);

    const newPull = {
      id,
      label,
      shape: "path",
      points: points.map((p) => ({ xPct: p.xPct, yPct: p.yPct })),
    };
    this.attentionPulls = [...this.attentionPulls, newPull];
    this.selectedAttentionPullId = id;
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;

    this.pendingAttentionPullPopover = {
      id,
      anchorXPct: (minX + maxX) / 2,
      anchorYPct: (minY + maxY) / 2,
    };
    this.pendingAttentionPullPopoverText = "";

    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-attention-pull-path", {
        topicId: this.topic?.id,
        id,
        pointCount: newPull.points.length,
      });
    }
  }

  @action
  addAttentionPull(xPct, yPct, widthPct, heightPct) {
    if (this.visualMode !== "attention_pull") {
      return;
    }
    if (this.attentionPullsAtMax) {
      return;
    }
    // If a popover is still open for a previous pull, treat the new
    // creation as an implicit Skip on it — same idea as the pin
    // popover. Keeps the rapid-place workflow viable.
    if (this.pendingAttentionPullPopover) {
      this.pendingAttentionPullPopover = null;
      this.pendingAttentionPullPopoverText = "";
    }
    this._attentionPullIdCounter += 1;
    const id = `attention_pull_${this._attentionPullIdCounter}`;
    // Area labels (A1, A2, ...) are global across submission images.
    const label = nextAttentionPullLabel(
      this._allLabelsAcrossImages("attentionPulls")
    );
    const newPull = { id, label, xPct, yPct, widthPct, heightPct };
    this.attentionPulls = [...this.attentionPulls, newPull];
    // Newly-placed marker is implicitly the "active" one — mirror
    // the crop pattern of auto-select-on-place so the toolbar's
    // Remove button is immediately available.
    this.selectedAttentionPullId = id;
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;

    // No textarea write on marker creation — only on Add note (the
    // popover writes "[A_N] <user text>"). Skip leaves the textarea
    // alone, since auto-inserting filler "because..." reads as
    // prescriptive and the critic may not want a textarea line for
    // every marker they place.
    //
    // Open the inline note popover, anchored to the ellipse's center.
    // Move/resize is suppressed via attentionPullEditEnabled while
    // it's open (see the corresponding getter).
    this.pendingAttentionPullPopover = {
      id,
      anchorXPct: xPct + widthPct / 2,
      anchorYPct: yPct + heightPct / 2,
    };
    this.pendingAttentionPullPopoverText = "";

    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-attention-pull", {
        topicId: this.topic?.id,
        id,
        xPct,
        yPct,
        widthPct,
        heightPct,
        starterInsertedThisSession: this._attentionPullStarterInserted,
      });
    }
  }

  @action
  selectAttentionPull(id) {
    if (!id) {
      return;
    }
    const exists = this.attentionPulls.some((p) => p.id === id);
    if (!exists) {
      return;
    }
    // Clicking a shape activates the corresponding tool mode (see
    // selectPin for rationale).
    this._setVisualMode("attention_pull");
    // Mirror the pin/crop/eye-path/strong-area mutex.
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    if (this.selectedAttentionPullId === id) {
      // Clicking the already-selected marker deselects (parallel
      // with pin / crop toggle behavior).
      this.selectedAttentionPullId = null;
    } else {
      this.selectedAttentionPullId = id;
    }
    // Selection change cancels retrace — the user is now interacting
    // with a different marker (or none), so the pending retrace is
    // no longer the intent.
    this.retracingAttentionPullId = null;
    this.retracingStrongAreaId = null;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] select-attention-pull", {
        topicId: this.topic?.id,
        id,
        selected: this.selectedAttentionPullId,
      });
    }
  }

  @action
  removeSelectedAttentionPull() {
    if (!this.selectedAttentionPullId) {
      return;
    }
    this.removeAttentionPullById(this.selectedAttentionPullId);
  }

  // Direct removal by id — used from the toolbar's "Remove selected"
  // and the a11y annotation list's "Remove" button.
  @action
  removeAttentionPullById(id) {
    if (!id) {
      return;
    }
    this.attentionPulls = this.attentionPulls.filter((p) => p.id !== id);
    if (this.selectedAttentionPullId === id) {
      this.selectedAttentionPullId = null;
    }
    if (this.retracingAttentionPullId === id) {
      this.retracingAttentionPullId = null;
    }
    // Close the popover if it was anchored to the removed marker.
    if (this.pendingAttentionPullPopover?.id === id) {
      this.pendingAttentionPullPopover = null;
      this.pendingAttentionPullPopoverText = "";
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-attention-pull", {
        topicId: this.topic?.id,
        id,
        remaining: this.attentionPulls.length,
      });
    }
  }

  @action
  clearAttentionPulls() {
    if (this.attentionPulls.length === 0) {
      return;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] clear-attention-pulls", {
        topicId: this.topic?.id,
        clearedCount: this.attentionPulls.length,
      });
    }
    this.attentionPulls = [];
    this.selectedAttentionPullId = null;
    this.retracingAttentionPullId = null;
    this.pendingAttentionPullPopover = null;
    this.pendingAttentionPullPopoverText = "";
    // Textarea text (including the starter) stays — same convention as
    // crop / eye path. Critics own their prose.
  }

  // Fired by the Konva stage on dragend / transformend for a selected
  // attention pull. Updates the marker's geometry without changing
  // its id. The stage updates its closure-cached pull array BEFORE
  // invoking this callback, so the next sync sees identical values
  // and skips a redundant re-render.
  @action
  updateAttentionPull(id, xPct, yPct, widthPct, heightPct) {
    if (!id) {
      return;
    }
    this.attentionPulls = this.attentionPulls.map((p) =>
      p.id === id ? { ...p, xPct, yPct, widthPct, heightPct } : p
    );
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] update-attention-pull", {
        topicId: this.topic?.id,
        id,
        xPct,
        yPct,
        widthPct,
        heightPct,
      });
    }
  }

  // ---- Attention-pull popover ----------------------------------------

  @action
  updatePendingAttentionPullPopoverText(event) {
    this.pendingAttentionPullPopoverText = event?.target?.value ?? "";
  }

  @action
  confirmPendingAttentionPullPopover() {
    if (!this.pendingAttentionPullPopover) {
      return;
    }
    const text = this.pendingAttentionPullPopoverText.trim();
    const { id } = this.pendingAttentionPullPopover;
    const pull = this.attentionPulls.find((p) => p.id === id);
    if (text && pull) {
      // Append only the user's text, prefixed with the [label]
      // reference so the textarea line still connects back to the
      // visual marker. No filler scaffolding.
      const line = i18n(
        "npn_critique_reply.visual_notes.area_note_line_template",
        { label: pull.label, text }
      );
      this._appendToTextarea(line);
      // Stash on the marker for the a11y list snippet (same as pins).
      this.attentionPulls = this.attentionPulls.map((p) =>
        p.id === id ? { ...p, noteText: text } : p
      );
    }
    this.pendingAttentionPullPopover = null;
    this.pendingAttentionPullPopoverText = "";
  }

  @action
  skipPendingAttentionPullPopover() {
    // No textarea write — the marker exists on the image; the critic
    // can describe it directly in the textarea if they want.
    this.pendingAttentionPullPopover = null;
    this.pendingAttentionPullPopoverText = "";
  }

  // ---- Strong Area ----------------------------------------------------

  // Twin of addAttentionPullPath — same shape, different kind/label.
  @action
  addStrongAreaPath(points) {
    if (this.visualMode !== "strong_area") {
      return;
    }
    if (this.strongAreasAtMax) {
      return;
    }
    if (!Array.isArray(points) || points.length < 4) {
      return;
    }
    if (this.pendingStrongAreaPopover) {
      this.pendingStrongAreaPopover = null;
      this.pendingStrongAreaPopoverText = "";
    }
    this._strongAreaIdCounter += 1;
    const id = `strong_area_${this._strongAreaIdCounter}`;
    const label = nextStrongAreaLabel(
      this._allLabelsAcrossImages("strongAreas")
    );
    const xs = points.map((p) => p.xPct);
    const ys = points.map((p) => p.yPct);
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);

    const newArea = {
      id,
      label,
      shape: "path",
      points: points.map((p) => ({ xPct: p.xPct, yPct: p.yPct })),
    };
    this.strongAreas = [...this.strongAreas, newArea];
    this.selectedStrongAreaId = id;
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;

    this.pendingStrongAreaPopover = {
      id,
      anchorXPct: (minX + maxX) / 2,
      anchorYPct: (minY + maxY) / 2,
    };
    this.pendingStrongAreaPopoverText = "";

    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-strong-area-path", {
        topicId: this.topic?.id,
        id,
        pointCount: newArea.points.length,
      });
    }
  }

  // ---- Retrace (path-shape only) -------------------------------------

  // Toggle retrace for the currently-selected Attention Pull. If the
  // selected marker is already being retraced, this acts as a cancel.
  // Only valid when the selected marker has `shape === "path"`; the
  // template only renders the button in that case, but we re-check
  // defensively.
  @action
  toggleRetraceAttentionPull() {
    const pull = this.selectedAttentionPull;
    if (!pull || pull.shape !== "path") {
      return;
    }
    if (this.retracingAttentionPullId === pull.id) {
      this.retracingAttentionPullId = null;
      return;
    }
    this.retracingAttentionPullId = pull.id;
    this.retracingStrongAreaId = null;
  }

  @action
  toggleRetraceStrongArea() {
    const area = this.selectedStrongArea;
    if (!area || area.shape !== "path") {
      return;
    }
    if (this.retracingStrongAreaId === area.id) {
      this.retracingStrongAreaId = null;
      return;
    }
    this.retracingStrongAreaId = area.id;
    this.retracingAttentionPullId = null;
  }

  // Commit a retrace by replacing `points` on the existing marker.
  // The id, label, shape ("path"), and any noteText are preserved so
  // the textarea snippet that references [Aₙ] / [Sₙ] keeps pointing
  // at the same marker. Clears retracing state on success or no-op
  // (too-few points means the drag is treated as cancel).
  @action
  retraceAttentionPullPath(id, points) {
    if (!id || this.retracingAttentionPullId !== id) {
      return;
    }
    if (!Array.isArray(points) || points.length < 4) {
      this.retracingAttentionPullId = null;
      return;
    }
    const target = this.attentionPulls.find((p) => p.id === id);
    if (!target || target.shape !== "path") {
      this.retracingAttentionPullId = null;
      return;
    }
    const nextPoints = points.map((p) => ({ xPct: p.xPct, yPct: p.yPct }));
    this.attentionPulls = this.attentionPulls.map((p) =>
      p.id === id ? { ...p, points: nextPoints } : p
    );
    this.retracingAttentionPullId = null;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] retrace-attention-pull", {
        topicId: this.topic?.id,
        id,
        pointCount: nextPoints.length,
      });
    }
  }

  @action
  retraceStrongAreaPath(id, points) {
    if (!id || this.retracingStrongAreaId !== id) {
      return;
    }
    if (!Array.isArray(points) || points.length < 4) {
      this.retracingStrongAreaId = null;
      return;
    }
    const target = this.strongAreas.find((p) => p.id === id);
    if (!target || target.shape !== "path") {
      this.retracingStrongAreaId = null;
      return;
    }
    const nextPoints = points.map((p) => ({ xPct: p.xPct, yPct: p.yPct }));
    this.strongAreas = this.strongAreas.map((p) =>
      p.id === id ? { ...p, points: nextPoints } : p
    );
    this.retracingStrongAreaId = null;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] retrace-strong-area", {
        topicId: this.topic?.id,
        id,
        pointCount: nextPoints.length,
      });
    }
  }

  // Twin of addAttentionPull — same shape, different kind/label
  // prefix/starter copy.
  @action
  addStrongArea(xPct, yPct, widthPct, heightPct) {
    if (this.visualMode !== "strong_area") {
      return;
    }
    if (this.strongAreasAtMax) {
      return;
    }
    if (this.pendingStrongAreaPopover) {
      this.pendingStrongAreaPopover = null;
      this.pendingStrongAreaPopoverText = "";
    }
    this._strongAreaIdCounter += 1;
    const id = `strong_area_${this._strongAreaIdCounter}`;
    const label = nextStrongAreaLabel(
      this._allLabelsAcrossImages("strongAreas")
    );
    const newArea = { id, label, xPct, yPct, widthPct, heightPct };
    this.strongAreas = [...this.strongAreas, newArea];
    this.selectedStrongAreaId = id;
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;

    // No textarea write on marker creation — twin of attention pull.
    // The popover writes "[S_N] <user text>" on Add note; Skip leaves
    // the textarea alone.
    this.pendingStrongAreaPopover = {
      id,
      anchorXPct: xPct + widthPct / 2,
      anchorYPct: yPct + heightPct / 2,
    };
    this.pendingStrongAreaPopoverText = "";
  }

  @action
  selectStrongArea(id) {
    if (!id) {
      return;
    }
    const exists = this.strongAreas.some((p) => p.id === id);
    if (!exists) {
      return;
    }
    // Clicking a shape activates the corresponding tool mode (see
    // selectPin for rationale).
    this._setVisualMode("strong_area");
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    if (this.selectedStrongAreaId === id) {
      this.selectedStrongAreaId = null;
      this.selectedDirectionArrowId = null;
      this.selectedRelationshipArrowId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    } else {
      this.selectedStrongAreaId = id;
    }
    this.retracingAttentionPullId = null;
    this.retracingStrongAreaId = null;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] select-strong-area", {
        topicId: this.topic?.id,
        id,
        selected: this.selectedStrongAreaId,
      });
    }
  }

  @action
  removeSelectedStrongArea() {
    if (!this.selectedStrongAreaId) {
      return;
    }
    this.removeStrongAreaById(this.selectedStrongAreaId);
  }

  @action
  removeStrongAreaById(id) {
    if (!id) {
      return;
    }
    this.strongAreas = this.strongAreas.filter((p) => p.id !== id);
    if (this.selectedStrongAreaId === id) {
      this.selectedStrongAreaId = null;
      this.selectedDirectionArrowId = null;
      this.selectedRelationshipArrowId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    }
    if (this.retracingStrongAreaId === id) {
      this.retracingStrongAreaId = null;
    }
    if (this.pendingStrongAreaPopover?.id === id) {
      this.pendingStrongAreaPopover = null;
      this.pendingStrongAreaPopoverText = "";
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-strong-area", {
        topicId: this.topic?.id,
        id,
        remaining: this.strongAreas.length,
      });
    }
  }

  @action
  clearStrongAreas() {
    if (this.strongAreas.length === 0) {
      return;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] clear-strong-areas", {
        topicId: this.topic?.id,
        clearedCount: this.strongAreas.length,
      });
    }
    this.strongAreas = [];
    this.selectedStrongAreaId = null;
    this.retracingStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    this.pendingStrongAreaPopover = null;
    this.pendingStrongAreaPopoverText = "";
  }

  @action
  updateStrongArea(id, xPct, yPct, widthPct, heightPct) {
    if (!id) {
      return;
    }
    this.strongAreas = this.strongAreas.map((p) =>
      p.id === id ? { ...p, xPct, yPct, widthPct, heightPct } : p
    );
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] update-strong-area", {
        topicId: this.topic?.id,
        id,
        xPct,
        yPct,
        widthPct,
        heightPct,
      });
    }
  }

  // ---- Strong-area popover ------------------------------------------

  @action
  updatePendingStrongAreaPopoverText(event) {
    this.pendingStrongAreaPopoverText = event?.target?.value ?? "";
  }

  @action
  confirmPendingStrongAreaPopover() {
    if (!this.pendingStrongAreaPopover) {
      return;
    }
    const text = this.pendingStrongAreaPopoverText.trim();
    const { id } = this.pendingStrongAreaPopover;
    const area = this.strongAreas.find((p) => p.id === id);
    if (text && area) {
      // Append only the user's text, prefixed with the [label]
      // reference. No filler scaffolding.
      const line = i18n(
        "npn_critique_reply.visual_notes.strong_area_line_template",
        { label: area.label, text }
      );
      this._appendToTextarea(line);
      this.strongAreas = this.strongAreas.map((p) =>
        p.id === id ? { ...p, noteText: text } : p
      );
    }
    this.pendingStrongAreaPopover = null;
    this.pendingStrongAreaPopoverText = "";
  }

  @action
  skipPendingStrongAreaPopover() {
    this.pendingStrongAreaPopover = null;
    this.pendingStrongAreaPopoverText = "";
  }

  // ---- Direction Arrow ----------------------------------------------
  //
  // Drag-to-create like attention pull, but the stored shape is two
  // endpoints (tail → head) instead of a bounding rect. Cap is
  // MAX_DIRECTION_ARROW_COUNT (per-kind cap mirroring the other
  // labeled tools). Below-threshold drags are dropped silently — the
  // Konva stage filters those before calling `addDirectionArrow`.
  @action
  addDirectionArrow(x1Pct, y1Pct, x2Pct, y2Pct) {
    if (this.visualMode !== "direction_arrow") {
      return;
    }
    if (this.directionArrowsAtMax) {
      return;
    }
    if (this.pendingDirectionArrowPopover) {
      // A previous arrow's popover is still open — treat the new
      // drag as implicit Skip on it (same pattern as attention pull
      // / strong area).
      this.pendingDirectionArrowPopover = null;
      this.pendingDirectionArrowPopoverText = "";
    }
    this._directionArrowIdCounter += 1;
    const id = `direction_arrow_${this._directionArrowIdCounter}`;
    const label = nextDirectionArrowLabel(
      this._allLabelsAcrossImages("directionArrows")
    );
    const newArrow = { id, label, x1Pct, y1Pct, x2Pct, y2Pct };
    this.directionArrows = [...this.directionArrows, newArrow];
    // Mutex: selecting a new arrow clears every other selection
    // (the cross-kind exclusivity rule).
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedRelationshipArrowId = null;
    this.selectedDirectionArrowId = id;
    // Popover anchors at the arrowhead (x2/y2) — that's where the
    // user just released, so the cursor is already nearby.
    this.pendingDirectionArrowPopover = {
      id,
      label,
      anchorXPct: x2Pct,
      anchorYPct: y2Pct,
    };
    this.pendingDirectionArrowPopoverText = "";
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-direction-arrow", {
        topicId: this.topic?.id,
        id,
        label,
      });
    }
  }

  @action
  selectDirectionArrow(id) {
    if (!id) {
      return;
    }
    if (!this.directionArrows.some((a) => a.id === id)) {
      return;
    }
    this._setVisualMode("direction_arrow");
    // Cross-kind mutex.
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedRelationshipArrowId = null;
    // Toggle: clicking the already-selected arrow deselects.
    this.selectedDirectionArrowId =
      this.selectedDirectionArrowId === id ? null : id;
  }

  // Fired by the Konva stage on endpoint dragend. The stage updates
  // its own closure-cached arrow BEFORE invoking this callback (same
  // pattern as moveEyePathPoint), so the next sync sees identical
  // values and skips a redundant re-render.
  @action
  updateDirectionArrow(id, x1Pct, y1Pct, x2Pct, y2Pct) {
    if (!id) {
      return;
    }
    this.directionArrows = this.directionArrows.map((a) =>
      a.id === id ? { ...a, x1Pct, y1Pct, x2Pct, y2Pct } : a
    );
  }

  @action
  removeSelectedDirectionArrow() {
    if (!this.selectedDirectionArrowId) {
      return;
    }
    this.removeDirectionArrowById(this.selectedDirectionArrowId);
  }

  @action
  removeDirectionArrowById(id) {
    if (!id) {
      return;
    }
    if (!this.directionArrows.some((a) => a.id === id)) {
      return;
    }
    this.directionArrows = this.directionArrows.filter((a) => a.id !== id);
    if (this.selectedDirectionArrowId === id) {
      this.selectedDirectionArrowId = null;
    }
    if (this.pendingDirectionArrowPopover?.id === id) {
      this.pendingDirectionArrowPopover = null;
      this.pendingDirectionArrowPopoverText = "";
    }
  }

  @action
  clearDirectionArrows() {
    if (this.directionArrows.length === 0) {
      return;
    }
    this.directionArrows = [];
    this.selectedDirectionArrowId = null;
    this.pendingDirectionArrowPopover = null;
    this.pendingDirectionArrowPopoverText = "";
  }

  @action
  updatePendingDirectionArrowPopoverText(event) {
    this.pendingDirectionArrowPopoverText = event?.target?.value ?? "";
  }

  @action
  confirmPendingDirectionArrowPopover() {
    if (!this.pendingDirectionArrowPopover) {
      return;
    }
    const text = this.pendingDirectionArrowPopoverText.trim();
    const label = this.pendingDirectionArrowPopover.label;
    if (text) {
      const line = i18n(
        "npn_critique_reply.visual_notes.direction_arrow_line_template",
        { label, text }
      );
      this._appendToTextarea(line);
      const id = this.pendingDirectionArrowPopover.id;
      this.directionArrows = this.directionArrows.map((a) =>
        a.id === id ? { ...a, noteText: text } : a
      );
    }
    this.pendingDirectionArrowPopover = null;
    this.pendingDirectionArrowPopoverText = "";
  }

  @action
  skipPendingDirectionArrowPopover() {
    this.pendingDirectionArrowPopover = null;
    this.pendingDirectionArrowPopoverText = "";
  }

  // ---- Relationship Arrow -------------------------------------------
  //
  // Twin of Direction Arrow but with arrowheads on both ends and
  // "R<N>" labels. Same drag-to-create + popover-on-place flow.
  @action
  addRelationshipArrow(x1Pct, y1Pct, x2Pct, y2Pct) {
    if (this.visualMode !== "relationship_arrow") {
      return;
    }
    if (this.relationshipArrowsAtMax) {
      return;
    }
    if (this.pendingRelationshipArrowPopover) {
      this.pendingRelationshipArrowPopover = null;
      this.pendingRelationshipArrowPopoverText = "";
    }
    this._relationshipArrowIdCounter += 1;
    const id = `relationship_arrow_${this._relationshipArrowIdCounter}`;
    const label = nextRelationshipArrowLabel(
      this._allLabelsAcrossImages("relationshipArrows")
    );
    const newArrow = { id, label, x1Pct, y1Pct, x2Pct, y2Pct };
    this.relationshipArrows = [...this.relationshipArrows, newArrow];
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = id;
    this.pendingRelationshipArrowPopover = {
      id,
      label,
      // Anchor mid-line so the popover doesn't favour either end —
      // relationship arrows are non-directional.
      anchorXPct: (x1Pct + x2Pct) / 2,
      anchorYPct: (y1Pct + y2Pct) / 2,
    };
    this.pendingRelationshipArrowPopoverText = "";
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-relationship-arrow", {
        topicId: this.topic?.id,
        id,
        label,
      });
    }
  }

  @action
  selectRelationshipArrow(id) {
    if (!id) {
      return;
    }
    if (!this.relationshipArrows.some((a) => a.id === id)) {
      return;
    }
    this._setVisualMode("relationship_arrow");
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId =
      this.selectedRelationshipArrowId === id ? null : id;
  }

  @action
  updateRelationshipArrow(id, x1Pct, y1Pct, x2Pct, y2Pct) {
    if (!id) {
      return;
    }
    this.relationshipArrows = this.relationshipArrows.map((a) =>
      a.id === id ? { ...a, x1Pct, y1Pct, x2Pct, y2Pct } : a
    );
  }

  @action
  removeSelectedRelationshipArrow() {
    if (!this.selectedRelationshipArrowId) {
      return;
    }
    this.removeRelationshipArrowById(this.selectedRelationshipArrowId);
  }

  @action
  removeRelationshipArrowById(id) {
    if (!id) {
      return;
    }
    if (!this.relationshipArrows.some((a) => a.id === id)) {
      return;
    }
    this.relationshipArrows = this.relationshipArrows.filter(
      (a) => a.id !== id
    );
    if (this.selectedRelationshipArrowId === id) {
      this.selectedRelationshipArrowId = null;
    }
    if (this.pendingRelationshipArrowPopover?.id === id) {
      this.pendingRelationshipArrowPopover = null;
      this.pendingRelationshipArrowPopoverText = "";
    }
  }

  @action
  clearRelationshipArrows() {
    if (this.relationshipArrows.length === 0) {
      return;
    }
    this.relationshipArrows = [];
    this.selectedRelationshipArrowId = null;
    this.pendingRelationshipArrowPopover = null;
    this.pendingRelationshipArrowPopoverText = "";
  }

  @action
  updatePendingRelationshipArrowPopoverText(event) {
    this.pendingRelationshipArrowPopoverText = event?.target?.value ?? "";
  }

  @action
  confirmPendingRelationshipArrowPopover() {
    if (!this.pendingRelationshipArrowPopover) {
      return;
    }
    const text = this.pendingRelationshipArrowPopoverText.trim();
    const label = this.pendingRelationshipArrowPopover.label;
    if (text) {
      const line = i18n(
        "npn_critique_reply.visual_notes.relationship_arrow_line_template",
        { label, text }
      );
      this._appendToTextarea(line);
      const id = this.pendingRelationshipArrowPopover.id;
      this.relationshipArrows = this.relationshipArrows.map((a) =>
        a.id === id ? { ...a, noteText: text } : a
      );
    }
    this.pendingRelationshipArrowPopover = null;
    this.pendingRelationshipArrowPopoverText = "";
  }

  @action
  skipPendingRelationshipArrowPopover() {
    this.pendingRelationshipArrowPopover = null;
    this.pendingRelationshipArrowPopoverText = "";
  }

  // ---- Eye-path popover ----------------------------------------------

  @action
  updatePendingEyePathPopoverText(event) {
    this.pendingEyePathPopoverText = event?.target?.value ?? "";
  }

  @action
  confirmPendingEyePathPopover() {
    if (!this.pendingEyePathPopover) {
      return;
    }
    const text = this.pendingEyePathPopoverText.trim();
    // Popover always anchors to the actively-constructed path —
    // that's the one whose second point triggered it. Fall back to
    // the selected path if for some reason there's no active session
    // (e.g. the user dismissed and re-opened via a future action).
    const path = this.activeEyePath ?? this.selectedEyePath;
    const label = path?.label ?? "E1";
    if (text) {
      // Append only the user's text, prefixed with the [label]
      // reference. No filler scaffolding.
      const line = i18n(
        "npn_critique_reply.visual_notes.eye_path_line_template",
        { label, text }
      );
      this._appendToTextarea(line);
      // Stash on the path so a future a11y list snippet can show a
      // description summary. With multiple paths each carries its
      // own noteText.
      if (path) {
        this.eyePaths = this.eyePaths.map((p) =>
          p.id === path.id ? { ...p, noteText: text } : p
        );
      }
    }
    this.pendingEyePathPopover = null;
    this.pendingEyePathPopoverText = "";
    // Treat popover dismissal as "I'm done with this path." Clearing
    // the session pointers means the next click / drag in eye_path
    // mode starts a fresh path with its own description popover,
    // matching the user's mental model that finishing one path moves
    // on to the next.
    this._activeEyePathId = null;
    this._eyePathStarterInserted = false;
  }

  @action
  skipPendingEyePathPopover() {
    this.pendingEyePathPopover = null;
    this.pendingEyePathPopoverText = "";
    // See confirmPendingEyePathPopover — dismissing without text still
    // ends the path session so the next gesture starts a new one.
    this._activeEyePathId = null;
    this._eyePathStarterInserted = false;
  }

  // ---- Crop popover -------------------------------------------------
  //
  // Fires once each time the user creates a crop. Confirms append
  // `[CROP] {text}` to the textarea; Skip closes without appending.
  // No-text Confirm appends bare `[CROP]` so the styled pill still
  // anchors the prose. Mirrors the other tools' popover pattern so
  // the workflow stays consistent across all annotation kinds.
  @action
  updatePendingCropPopoverText(event) {
    this.pendingCropPopoverText = event?.target?.value ?? "";
  }

  @action
  confirmPendingCropPopover() {
    if (!this.pendingCropPopover) {
      return;
    }
    const text = this.pendingCropPopoverText.trim();
    // Token shape depends on whether this crop got a number ("Crop
    // 2") or stayed unnumbered (single-crop case → "[Crop]"). The
    // crop's label was assigned at addCrop time.
    const token = this._activeCropToken();
    if (text) {
      this._appendToTextarea(`${token} ${text}`);
    } else {
      // No description typed → still drop the bare token so the
      // cooked post gets the styled crop pill. The user can fill
      // in the surrounding prose later.
      this._appendToTextarea(token);
    }
    this.pendingCropPopover = null;
    this.pendingCropPopoverText = "";
  }

  @action
  skipPendingCropPopover() {
    this.pendingCropPopover = null;
    this.pendingCropPopoverText = "";
  }

  get selectedPin() {
    if (this.selectedPinNumber == null) {
      return null;
    }
    return (
      this.notes.find((p) => p.number === this.selectedPinNumber) ?? null
    );
  }

  @action
  removeSelectedPin() {
    const number = this.selectedPinNumber;
    if (number == null) {
      return;
    }
    this.notes = this.notes.filter((p) => p.number !== number);
    this.selectedPinNumber = null;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-pin", {
        topicId: this.topic?.id,
        removedNumber: number,
        remainingNumbers: this.notes.map((p) => p.number),
      });
    }
    // Deliberately do NOT touch the textarea. The critic may have written
    // prose explaining "[2]" that's still meaningful even with the pin
    // gone (e.g. they'll re-pin and re-use the number, or they'll edit
    // the line manually). Auto-rewriting is too lossy here.
  }

  @action
  addPin(xPct, yPct) {
    if (!this.noteMode) {
      return;
    }
    // If a popover is still open for a previous pin, treat the new
    // click as an implicit "Skip" on it — append the bare marker so
    // the visual/written link is preserved, then move on to the new
    // pin. This keeps the rapid-place workflow viable.
    if (this.pendingPin) {
      this._appendPinMarker(this.pendingPin.number, "");
      this.pendingPin = null;
      this.pendingPinNoteText = "";
    }
    // Pin numbers are global across all submission images so the
    // cooked post can refer to "[1]", "[2]", ... unambiguously even
    // when the user has marked up multiple images. Highest existing
    // number anywhere wins; the new pin is max+1.
    const nextNumber = this._maxPinNumberAcrossImages() + 1;
    const newPin = {
      number: nextNumber,
      xPct,
      yPct,
      imageVersionKey: this.selectedVersionKey,
    };
    this.notes = [...this.notes, newPin];
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-pin", {
        topicId: this.topic?.id,
        number: nextNumber,
        xPct,
        yPct,
        imageVersionKey: this.selectedVersionKey,
      });
    }
    // Open the note popover. The textarea append is deferred until
    // the user confirms ("Add note") or skips. The pin itself is
    // already in `this.notes` so it renders immediately — only the
    // textarea marker waits.
    this.pendingPin = { number: nextNumber, xPct, yPct };
    this.pendingPinNoteText = "";
    // Mirror selection so the pin reads as the active annotation in
    // the toolbar and a11y list while the popover is open.
    this.selectedPinNumber = nextNumber;
    this.cropSelected = false;
  }

  // ---- Pending pin / note popover actions -----------------------------

  @action
  updatePendingPinNoteText(event) {
    this.pendingPinNoteText = event?.target?.value ?? "";
  }

  @action
  confirmPendingPinNote() {
    if (!this.pendingPin) {
      return;
    }
    const text = this.pendingPinNoteText.trim();
    const number = this.pendingPin.number;
    this._appendPinMarker(number, text);
    if (text) {
      // Stash on the pin model so the a11y annotation list can show a
      // snippet. The textarea remains the canonical store; this is a
      // UI mirror that doesn't flow into the export or schema.
      this.notes = this.notes.map((p) =>
        p.number === number ? { ...p, noteText: text } : p
      );
    }
    this.pendingPin = null;
    this.pendingPinNoteText = "";
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] confirm-pin-note", {
        topicId: this.topic?.id,
        number,
        hasText: text.length > 0,
      });
    }
  }

  @action
  skipPendingPinNote() {
    if (!this.pendingPin) {
      return;
    }
    const number = this.pendingPin.number;
    this._appendPinMarker(number, "");
    this.pendingPin = null;
    this.pendingPinNoteText = "";
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] skip-pin-note", {
        topicId: this.topic?.id,
        number,
      });
    }
  }

  // Single source of truth for the textarea marker format. Trailing
  // space when there's no note gives the cursor a natural landing
  // spot if the critic decides to type after the fact.
  _appendPinMarker(number, text) {
    const marker = text ? `[${number}] ${text}` : `[${number}] `;
    this._appendToTextarea(marker);
  }

  // Append text to the textarea with clean paragraph spacing. Always
  // single `\n\n` between existing content and the new content; never a
  // run of blank lines. Stale validation/error banners clear as a side
  // effect since the textarea state has changed.
  _appendToTextarea(addition) {
    const trimmed = this.critiqueText.trimEnd();
    this.critiqueText =
      trimmed.length > 0 ? `${trimmed}\n\n${addition}` : addition;
    this.validationMessage = null;
    this.errorMessage = null;
  }

  // Questions-to-consider expand/collapse. The compact view shows
  // the 3 default questions; this toggles the "More ideas" group
  // bank below. No prompt content is ever inserted into the
  // textarea — the panel is reference material only.
  @action
  toggleMoreIdeas() {
    this.moreIdeasExpanded = !this.moreIdeasExpanded;
    writeBool(STORAGE_KEY_MORE_IDEAS, this.moreIdeasExpanded);
  }

  // ---- Preview Critique ------------------------------------------------
  //
  // Edit-mode primary action. Builds a local snapshot of the composed
  // critique so the critic can review what they're about to send before
  // committing. Visual notes are flattened into a Blob and surfaced via
  // an object URL — there's no server upload yet, so going Back to Edit
  // doesn't waste a Discourse upload slot. The eventual Post Critique
  // action re-runs the export+upload pipeline as a single transaction
  // (preview snapshot is intentionally throwaway).
  @action
  async enterPreview() {
    if (this.isPosting || this.previewMode) {
      return;
    }
    if (!this.canPreview) {
      this.validationMessage = i18n(
        "npn_critique_reply.modal.validation_empty"
      );
      const el = document.getElementById("npn-critique-reply-textarea");
      el?.focus?.();
      return;
    }
    this.validationMessage = null;
    this.errorMessage = null;
    this.visualNotesFailureContext = null;

    this.previewBuilding = true;
    // Snapshot the active image so the preview iterates a consistent
    // per-image map (the active edits aren't yet in cold storage).
    this._annotationsByImageIndex.set(
      this._selectedImageIndex,
      this._snapshotCurrentAnnotations()
    );

    // Flatten ALL annotated images locally — same per-image walk the
    // post pipeline uses, but we stop at Blob/object-URL and don't
    // upload (preview is throwaway; Post Critique re-runs the export
    // for real). Each rendered image becomes an entry in the preview
    // snapshot's visualNotesImages array.
    const annotatedImages = this._gatherAnnotatedImagesInSubmissionOrder();
    const visualNotesImages = [];
    let visualNotesError = null;
    for (const entry of annotatedImages) {
      const sourceUrl = this._sourceUrlForImageIndex(entry.index);
      if (!sourceUrl) {
        continue;
      }
      try {
        const image = await loadImageForExport(sourceUrl);
        const canvas = buildVisualNotesCanvas({
          image,
          pins: entry.snapshot.notes,
          crop: entry.snapshot.crop,
          eyePaths: entry.snapshot.eyePaths,
          attentionPulls: entry.snapshot.attentionPulls,
          strongAreas: entry.snapshot.strongAreas,
          directionArrows: entry.snapshot.directionArrows,
          relationshipArrows: entry.snapshot.relationshipArrows,
        });
        const blob = await exportCanvasToBlob(canvas);
        visualNotesImages.push({
          index: entry.index,
          label: this._sourceLabelForImageIndex(entry.index),
          objectUrl: URL.createObjectURL(blob),
        });
      } catch (e) {
        // Preview is best-effort: if a flatten fails we still want
        // the critic to see text + processing example + any images
        // that DID work. The Post Critique step will re-run all
        // exports and surface a real error if it's truly broken.
        visualNotesError = e;
        this._recordError(
          "preview_visual_notes_export",
          e,
          { imageIndex: entry.index },
          "warn"
        );
      }
    }

    if (this._destroyed) {
      for (const img of visualNotesImages) {
        URL.revokeObjectURL(img.objectUrl);
      }
      return;
    }

    // Preview snapshot. Note: the preview's "Critique" section
    // shows the FULL textarea text — not the per-image-grouped
    // sub-bodies that the cooked post composes. We tried rendering
    // per-image prose under each image in the preview and ran into
    // a Glimmer "Expected a dynamic component definition" error
    // that only fires inside the {{#each visualNotesImages}}
    // iteration; reverting the per-image preview rendering to keep
    // the modal functional. The POSTED critique still gets the
    // per-image grouping treatment via _prepareReplyText.
    this._previewSnapshot = {
      visualNotesImages,
      visualNotesError,
      processingExampleUrl: this.processingExample?.url ?? null,
      processingExampleFilename:
        this.processingExample?.filename ?? null,
      textBody: this.critiqueText.trim(),
      hasVisualNotes: visualNotesImages.length > 0,
      hasProcessingExample: !!this.processingExample,
    };
    // Flip previewMode FIRST so the template re-renders with the
    // preview overlay in one pass. Setting previewBuilding=false
    // first triggered a brief intermediate render where the
    // edit-mode footer Preview button left isLoading state, which
    // — paired with the helper expression in its @title arg —
    // appears to trip Glimmer's helper-resolution path on some
    // Ember versions. Going `previewMode = true` first means the
    // intermediate render is already on the preview footer (no
    // helpered title), and previewBuilding clears on the same
    // microtask before any user interaction can fire.
    this.previewMode = true;
    this.previewBuilding = false;

    // Move focus into the preview region so screen readers and
    // keyboard users land on the new view. Falls back gracefully if
    // the element isn't mounted yet.
    setTimeout(() => {
      if (this._destroyed) {
        return;
      }
      const heading = document.getElementById(
        "npn-critique-reply-preview-heading"
      );
      heading?.focus?.();
    }, 0);
  }

  @action
  exitPreview() {
    this._teardownPreviewSnapshot();
    this.previewMode = false;
    setTimeout(() => {
      if (this._destroyed) {
        return;
      }
      const el = document.getElementById("npn-critique-reply-textarea");
      el?.focus?.();
    }, 0);
  }

  _teardownPreviewSnapshot() {
    const images = this._previewSnapshot?.visualNotesImages;
    if (Array.isArray(images)) {
      for (const img of images) {
        try {
          URL.revokeObjectURL(img.objectUrl);
        } catch (_e) {
          // Already revoked / never created — fine.
        }
      }
    }
    this._previewSnapshot = null;
  }

  // Preview body HTML for the critique text section. Built directly
  // (rather than via {{#each}} fragments) so template-source whitespace
  // can't leak into the rendered DOM and indent badges relative to
  // the surrounding prose. Paragraphs split on blank lines; tokens like
  // [1] / [E1] / [A1] / [Crop] become the same styled spans the cooked-
  // post decorator emits.
  get previewTextHtml() {
    const text = this._previewSnapshot?.textBody ?? "";
    if (!text) {
      return null;
    }
    return htmlSafe(buildPreviewTextHtml(text));
  }

  get previewHasText() {
    return !!this._previewSnapshot?.textBody;
  }

  @action
  async postCritique() {
    return this._doPostCritique({ skipVisualNotes: false });
  }

  @action
  async retryPostWithoutVisualNotes() {
    return this._doPostCritique({ skipVisualNotes: true });
  }

  async _doPostCritique({ skipVisualNotes }) {
    if (!this.hasUnsavedText) {
      this.validationMessage = i18n(
        "npn_critique_reply.modal.validation_empty"
      );
      this.errorMessage = null;
      this.visualNotesFailureContext = null;
      const el = document.getElementById("npn-critique-reply-textarea");
      el?.focus?.();
      return;
    }

    const topicId = this.topic?.id;
    if (!topicId) {
      this.errorMessage = i18n("npn_critique_reply.modal.post_failed");
      return;
    }

    this.validationMessage = null;
    this.errorMessage = null;
    this.visualNotesFailureContext = null;
    this._lastFailureReport = null;
    this._lastExportDiagnostic = null;
    this._lastUploadDiagnostic = null;
    this.isPosting = true;
    this.statusMessage = null;

    const selectedKey = this.selectedVersionKey;
    const includedPins = skipVisualNotes ? 0 : this.notes.length;

    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] post-critique submit", {
        topicId,
        selectedKey,
        pinCount: this.notes.length,
        skipVisualNotes,
      });
    }

    try {
      const { raw, visualBlocks } = await this._prepareReplyText({
        skipVisualNotes,
      });
      if (this._destroyed) {
        return;
      }

      this.statusMessage = i18n("npn_critique_reply.modal.posting_critique");

      // Structured visual-annotation metadata is sent ONLY when the
      // visual export + upload pipeline produced at least one image.
      // The primary entry (image_index 0) — if present — flows through
      // the legacy single-image args so old `source` + `visual_output`
      // readers still get the same shape; secondary images ride along
      // in `additionalImages`, and per-annotation `image_index` lets
      // readers route annotations to their source. Text-only critiques,
      // Post-without-visual-notes fallback, and Edit-in-Composer all
      // skip this entirely.
      const visualNotes = this._buildVisualNotesPayload(visualBlocks);

      // Processing-example metadata. Distinct from visual notes —
      // independent eligibility, independent lifecycle, independent
      // clear semantics. The block is already in `raw` (composed by
      // `_prepareReplyText`); this payload is what the server stores
      // as the `npn_processing_example` post custom field.
      const processingExamplePayload = this.processingExample
        ? buildProcessingExamplePayload({
            topic: this.topic,
            selectedVersion: this.selectedVersion,
            exampleUpload: {
              upload_id: this.processingExample.uploadId,
              url: this.processingExample.url,
              short_url: this.processingExample.shortUrl,
              filename: this.processingExample.filename,
            },
          })
        : null;

      // Edit mode → PUT /posts/:id/critique (PostRevisor + custom
      // field replace). New-critique mode → POST /topics/:id/replies.
      // Same payload shape; the server endpoint difference is the
      // entire branch here.
      const response = this.isEditing
        ? await updateCritiqueRequest(
            this.editingPost.id,
            raw,
            selectedKey,
            visualNotes,
            processingExamplePayload
          )
        : await postCritiqueRequest(
            topicId,
            raw,
            selectedKey,
            visualNotes,
            processingExamplePayload
          );
      if (this._destroyed) {
        // Post was created server-side; modal is gone. MessageBus will
        // deliver the new reply to any open topic page.
        return;
      }

      if (this.siteSettings.npn_critique_reply_debug_enabled) {
        // eslint-disable-next-line no-console
        console.info("[npn-critique-reply] post-critique success", response);
      }

      const topicController = getOwner(this).lookup("controller:topic");
      const topic = topicController?.model;
      try {
        await topic?.postStream?.refresh?.({ refreshInPlace: true });
      } catch (_e) {
        // MessageBus will catch up.
      }

      const toastKey = this.isEditing
        ? "npn_critique_reply.modal.critique_updated"
        : includedPins > 0
          ? "npn_critique_reply.modal.critique_posted_with_notes"
          : "npn_critique_reply.modal.critique_posted";
      this.toasts.success({
        duration: "short",
        data: { message: i18n(toastKey) },
      });

      // Post succeeded → drop the saved draft. Fire-and-forget; the
      // toast and modal close don't depend on the delete completing.
      this._clearDraftAfterSuccess();

      this.args.closeModal();
    } catch (error) {
      if (this._destroyed) {
        return;
      }
      if (error?.stage) {
        this.errorMessage = this._visualNotesErrorMessage(
          error.stage,
          error.cause
        );
        this.visualNotesFailureContext = "post";
      } else {
        // Server validation, rate limit, etc. — no fallback button.
        this.errorMessage = this._extractErrorMessage(error);
        this.visualNotesFailureContext = null;
      }

      // Route through the central recorder: builds the report,
      // promotes it to _lastFailureReport (so the "Copy diagnostic"
      // button picks it up), pushes onto _errorHistory, and logs to
      // console.warn unconditionally.
      this._recordError("post_critique", error, { topicId });
    } finally {
      if (!this._destroyed) {
        this.isPosting = false;
        this.statusMessage = null;
      }
    }
  }

  _extractErrorMessage(error) {
    const json = error?.jqXHR?.responseJSON;
    if (Array.isArray(json?.errors) && json.errors.length > 0) {
      return json.errors.join(". ");
    }
    if (typeof json?.error === "string") {
      return json.error;
    }
    return i18n("npn_critique_reply.modal.post_failed");
  }

  // ---- Self-service diagnostic report --------------------------------

  // Builds a structured snapshot of the failed pipeline. Called from
  // the post-critique / edit-in-composer catch blocks; the result is
  // stashed on `_lastFailureReport` so the error banner's "Copy
  // diagnostic" button can format and copy it. Synchronous — all the
  // inputs are already known to the modal.
  // Central error recorder. Any catch site in the modal (or any
  // collaborator that has a handle to the modal) can call this to:
  //   • snapshot a structured failure report
  //   • promote it to `_lastFailureReport` so the "Copy diagnostic"
  //     button picks it up
  //   • append to `_errorHistory` (capped) so chained failures stay
  //     visible
  //   • always log to console.warn (no debug-setting gate)
  //
  // `extra` is merged into the report verbatim — call sites use it
  // to attach extra context (e.g. {postId: 42} on post-fetch
  // failures, {url} on photographer's-notes fetch failures, etc.)
  // so a single report carries everything we'd want to ask about.
  //
  // Severity is a string: "error" | "warn" | "info". "warn" and
  // "info" don't override `_lastFailureReport` (we want the COPY
  // button to surface the actual failure, not a transient noisy
  // warning), but they DO end up in `_errorHistory`.
  _recordError(context, error, extra = null, severity = "error") {
    let report;
    try {
      report = this._buildFailureReport(context, error, extra);
    } catch (buildErr) {
      // Belt-and-suspenders: a broken builder shouldn't swallow the
      // original failure. Fall back to a minimal report.
      report = {
        timestamp: new Date().toISOString(),
        context,
        severity,
        builderError: {
          name: buildErr?.name ?? null,
          message: buildErr?.message ?? String(buildErr ?? ""),
        },
        error: {
          name: error?.name ?? null,
          message: error?.message ?? String(error ?? ""),
        },
        extra: extra ?? null,
      };
    }
    report.severity = severity;

    // Bound history so a long-lived session doesn't pile up forever.
    this._errorHistory.push(report);
    if (this._errorHistory.length > 20) {
      this._errorHistory.shift();
    }

    if (severity === "error") {
      this._lastFailureReport = report;
    }

    // eslint-disable-next-line no-console
    const method = severity === "info" ? "info" : "warn";
    // eslint-disable-next-line no-console
    console[method](`[npn-critique-reply] ${context} failed`, report);
    return report;
  }

  _buildFailureReport(context, error, extra = null) {
    const cause = error?.cause ?? null;
    const jqXHR = cause?.jqXHR ?? error?.jqXHR ?? null;
    const responseJSON = jqXHR?.responseJSON ?? null;
    return {
      timestamp: new Date().toISOString(),
      context,
      mode: this.isEditing ? "edit" : "new",
      topicId: this.topic?.id ?? null,
      editingPostId: this.editingPost?.id ?? null,
      stage: error?.stage ?? null,
      error: {
        name: error?.name ?? null,
        message: error?.message ?? String(error ?? ""),
        stack: error?.stack ?? null,
      },
      cause: cause
        ? {
            name: cause?.name ?? null,
            message: cause?.message ?? String(cause),
            stack: cause?.stack ?? null,
          }
        : null,
      server: jqXHR
        ? {
            status: jqXHR.status ?? null,
            statusText: jqXHR.statusText ?? null,
            errors: Array.isArray(responseJSON?.errors)
              ? responseJSON.errors
              : null,
            errorString:
              typeof responseJSON?.error === "string"
                ? responseJSON.error
                : null,
          }
        : null,
      visualNotes: this.hasVisualAnnotations
        ? {
            pinCount: this.notes?.length ?? 0,
            cropPresent: !!this.crop,
            eyePathCount: this.eyePaths?.length ?? 0,
            attentionPullCount: this.attentionPulls?.length ?? 0,
            strongAreaCount: this.strongAreas?.length ?? 0,
            directionArrowCount: this.directionArrows?.length ?? 0,
            relationshipArrowCount: this.relationshipArrows?.length ?? 0,
          }
        : null,
      selectedVersionKey: this.selectedVersionKey ?? null,
      hasProcessingExample: !!this.processingExample,
      lastExport: this._lastExportDiagnostic ?? null,
      lastUpload: this._lastUploadDiagnostic ?? null,
      // Slimmed-down history of the last few recorded errors so
      // chained failures appear together (e.g. a draft autosave that
      // started failing before the post submit).
      recentErrors: this._errorHistory.slice(-5).map((entry) => ({
        context: entry.context,
        severity: entry.severity,
        timestamp: entry.timestamp,
        errorMessage: entry.error?.message ?? null,
      })),
      extra: extra ?? null,
      browser: this._collectBrowserInfo(),
      pluginCommit:
        (this.siteSettings?.npn_critique_reply_plugin_version ?? null) ||
        null,
    };
  }

  _collectBrowserInfo() {
    if (typeof navigator === "undefined") {
      return null;
    }
    return {
      userAgent: navigator.userAgent ?? null,
      language: navigator.language ?? null,
      platform: navigator.platform ?? null,
      viewportWidth: window.innerWidth ?? null,
      viewportHeight: window.innerHeight ?? null,
      devicePixelRatio: window.devicePixelRatio ?? null,
    };
  }

  // Action wired to the error banner's "Copy diagnostic" button.
  // Serializes `_lastFailureReport` into a markdown code block and
  // copies it to the clipboard. Surfaces a toast for confirmation.
  @action
  async copyFailureDiagnostic() {
    if (!this._lastFailureReport) {
      return;
    }
    const body =
      "```json\n" +
      JSON.stringify(this._lastFailureReport, null, 2) +
      "\n```";
    let copied = false;
    if (navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(body);
        copied = true;
      } catch {
        copied = false;
      }
    }
    if (!copied) {
      // Fallback for older browsers / non-secure contexts.
      try {
        const textarea = document.createElement("textarea");
        textarea.value = body;
        textarea.setAttribute("readonly", "");
        textarea.style.position = "absolute";
        textarea.style.left = "-9999px";
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand("copy");
        document.body.removeChild(textarea);
        copied = true;
      } catch {
        copied = false;
      }
    }
    if (copied) {
      this.toasts.success({
        duration: "short",
        data: {
          message: i18n(
            "npn_critique_reply.modal.diagnostic_copied"
          ),
        },
      });
    } else {
      // Final fallback: log to console so the user can copy from there.
      // eslint-disable-next-line no-console
      console.warn(
        "[npn-critique-reply] diagnostic — clipboard unavailable, " +
          "copy from this object:",
        this._lastFailureReport
      );
      this.toasts.error?.({
        duration: "short",
        data: {
          message: i18n(
            "npn_critique_reply.modal.diagnostic_copy_failed"
          ),
        },
      });
    }
  }

  // ---- Edit in Composer ------------------------------------------------
  //
  // Opens the standard Discourse composer with the critique workspace text
  // pre-loaded so the user gets one more pass through the normal editing
  // surface before posting. Uses the same revision-prefixed `preparedRaw`
  // that Post Critique would have posted directly.
  //
  // If the composer already has text — either in-memory (open or
  // minimized) or saved as a server-side draft — we ask append / replace
  // / cancel rather than silently overwrite the user's earlier work.

  // The standard-composer escape hatch. Beta feedback: jumping into the
  // composer without warning made it unclear that visual workspace
  // tools / preview don't follow along, and that visual notes already
  // marked up may not be re-editable there. Confirm before the hand-off
  // — strongly when visual annotations or a processing example exist,
  // calmly when the workspace only has written text. Empty workspaces
  // skip the confirmation (the action is just "open the composer").
  @action
  async editInComposer() {
    const hasContent =
      this.hasUnsavedText ||
      this.hasAnyImageAnnotations ||
      this.hasProcessingExample;
    if (!hasContent) {
      return this._doEditInComposer({ skipVisualNotes: false });
    }
    const hasVisuals =
      this.hasAnyImageAnnotations || this.hasProcessingExample;
    const messageKey = hasVisuals
      ? "npn_critique_reply.modal.edit_in_composer_confirm_message_with_visuals"
      : "npn_critique_reply.modal.edit_in_composer_confirm_message_text_only";
    this.dialog.confirm({
      title: i18n("npn_critique_reply.modal.edit_in_composer_confirm_title"),
      message: i18n(messageKey),
      confirmButtonLabel:
        "npn_critique_reply.modal.edit_in_composer_confirm_continue",
      didConfirm: () => this._doEditInComposer({ skipVisualNotes: false }),
    });
  }

  @action
  async retryEditWithoutVisualNotes() {
    return this._doEditInComposer({ skipVisualNotes: true });
  }

  async _doEditInComposer({ skipVisualNotes }) {
    const hasVisual = !skipVisualNotes && this.hasAnyImageAnnotations;
    if (!this.hasUnsavedText && !hasVisual) {
      this._launchComposer({ replyText: null });
      return;
    }

    this.errorMessage = null;
    this.validationMessage = null;
    this.visualNotesFailureContext = null;
    this._lastFailureReport = null;
    this._lastExportDiagnostic = null;
    this._lastUploadDiagnostic = null;
    this.isPosting = true;
    this.statusMessage = null;

    try {
      // Edit-in-Composer only needs the raw markdown — the structured
      // visual-notes metadata isn't persisted for this flow because
      // the plugin does not create the final reply post (the native
      // composer does). See plugin docs / next-step roadmap.
      const { raw: ourText } = await this._prepareReplyText({
        skipVisualNotes,
      });
      if (this._destroyed) {
        return;
      }
      const existing = await this._existingComposerText();
      if (this._destroyed) {
        return;
      }
      if (existing && existing.trim().length > 0) {
        this._askMergeChoice(ourText, existing);
      } else {
        this._launchComposer({ replyText: ourText });
      }
    } catch (error) {
      if (this._destroyed) {
        return;
      }
      if (error?.stage) {
        this.errorMessage = this._visualNotesErrorMessage(
          error.stage,
          error.cause
        );
        this.visualNotesFailureContext = "edit";
      } else {
        this.errorMessage = this._extractErrorMessage(error);
        this.visualNotesFailureContext = null;
      }

      this._recordError("edit_in_composer", error, {
        topicId: this.topic?.id,
      });
    } finally {
      if (!this._destroyed) {
        this.isPosting = false;
        this.statusMessage = null;
      }
    }
  }

  // Returns the current composer text (in-memory or saved draft) or null
  // if nothing is sitting in the way. Swallows Draft.get errors —
  // failing-closed (treat as no existing text) would be worse than
  // failing-open (warn user about something that wasn't actually there).
  async _existingComposerText() {
    const composerService = getOwner(this).lookup("service:composer");
    const inMemory = composerService?.model?.reply;
    if (inMemory && inMemory.trim().length > 0) {
      return inMemory;
    }
    const draftKey = this.topic?.draft_key;
    if (!draftKey) {
      return null;
    }
    try {
      const draftData = await Draft.get(draftKey);
      if (draftData?.draft) {
        const parsed = JSON.parse(draftData.draft);
        return parsed?.reply ?? null;
      }
    } catch (_e) {
      // Network or parse failure — treat as no existing draft.
    }
    return null;
  }

  _askMergeChoice(ourText, existing) {
    this.dialog.alert({
      title: i18n("npn_critique_reply.modal.edit_in_composer"),
      message: i18n("npn_critique_reply.modal.edit_existing_message"),
      buttons: [
        {
          label: i18n("npn_critique_reply.modal.edit_append"),
          class: "btn-primary",
          action: () =>
            this._launchComposer({
              replyText: `${existing.trimEnd()}\n\n${ourText}`,
            }),
        },
        {
          label: i18n("npn_critique_reply.modal.edit_replace"),
          class: "btn-default",
          action: () => this._launchComposer({ replyText: ourText }),
        },
        {
          label: i18n("npn_critique_reply.modal.cancel"),
          class: "btn-flat",
          // No-op; leave the workspace modal open with text intact.
          action: () => {},
        },
      ],
    });
  }

  // Single entry-point for both Edit in Composer (with text) and Reply
  // Normally (no text). When `replyText` is set, composer.open carries it
  // into the model's `reply` property. When null, we go through the
  // topic controller so the behavior matches the native footer Reply
  // button exactly.
  _launchComposer({ replyText }) {
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] launch-composer", {
        topicId: this.topic?.id,
        withText: !!replyText,
        rawLength: replyText?.length ?? 0,
      });
    }

    // Switching to the standard composer is reversible — the user may
    // come back to the workspace to finish editing visual notes or
    // restart from where they left off. Preserve the workspace draft
    // (including its visual annotations) rather than silently deleting
    // it; the user can discard explicitly via the workspace's Discard
    // Draft button. Cancel any pending autosave so the just-rendered
    // post hand-off isn't immediately overwritten by a final flush.
    //
    // Trade-off: if the user posts via the standard composer, the
    // workspace will show "Resume Critique" on its entry button next
    // time. That's better than silently destroying their visual-notes
    // work in the workspace draft.
    this._autosaver?.cancel?.();

    this.args.closeModal();

    if (replyText) {
      const composerService = getOwner(this).lookup("service:composer");
      const topic = this.topic;
      composerService.open({
        action: Composer.REPLY,
        topic,
        draftKey: topic.draft_key,
        draftSequence: topic.draft_sequence,
        reply: replyText,
      });
    } else {
      const topicController = getOwner(this).lookup("controller:topic");
      topicController?.replyToPost();
    }
  }

  // Clear validation as soon as the user types — it's stale once they
  // start editing. Server errors stay visible so the user can read what
  // went wrong while fixing.
  @action
  clearValidationOnInput() {
    if (this.validationMessage) {
      this.validationMessage = null;
    }
  }

  // ---- Server-side critique workspace draft ---------------------------

  get draftsEnabled() {
    // Drafts apply to in-progress critiques only. When the modal is
    // reopened for editing an existing post, the post itself is the
    // canonical state and the drafts pipeline is bypassed entirely
    // (no autosave, no resume, no discard).
    if (this.isEditing) {
      return false;
    }
    return (
      this.siteSettings.npn_critique_reply_server_drafts_enabled !== false
    );
  }

  // Stable identity that changes whenever any field worth saving
  // changes. The `{{didUpdate}}` modifier on a hidden anchor watches
  // this and calls `scheduleDraftAutosave` whenever it flips, so we
  // don't have to thread an autosave call through every mutator
  // (~20+ actions). Keep it cheap to compute — it runs on every
  // render. Annotations are length-tagged to avoid stringifying a
  // potentially large array; the autosave PUT will pick up exact
  // contents.
  get draftSignature() {
    if (!this.draftsEnabled) {
      return "";
    }
    return [
      this.critiqueText.length,
      this.critiqueText,
      this.selectedVersionKey ?? "",
      // Multi-image picker — include the index so an autosave fires
      // when the critic just switches images without other edits.
      this._selectedImageIndex,
      this.notes.length,
      this.notes.map((n) => `${n.number}:${n.xPct}:${n.yPct}`).join(","),
      this.crop
        ? `${this.crop.xPct}:${this.crop.yPct}:${this.crop.widthPct}:${this.crop.heightPct}:${this.crop.aspectRatio}`
        : "",
      this.eyePaths.length,
      // Inner separators: `,` for points within a path, `;` between
      // paths. Avoids the outer `|` separator used by this signature.
      this.eyePaths
        .map(
          (path) =>
            `${path.id}:${(path.points ?? [])
              .map((p) => `${p.number}:${p.xPct}:${p.yPct}`)
              .join(",")}`
        )
        .join(";"),
      this.attentionPulls.length,
      this.attentionPulls
        .map((a) => `${a.id}:${a.xPct}:${a.yPct}:${a.widthPct}:${a.heightPct}`)
        .join(","),
      this.strongAreas.length,
      this.strongAreas
        .map((s) => `${s.id}:${s.xPct}:${s.yPct}:${s.widthPct}:${s.heightPct}`)
        .join(","),
      this.directionArrows.length,
      this.directionArrows
        .map((a) => `${a.id}:${a.x1Pct}:${a.y1Pct}:${a.x2Pct}:${a.y2Pct}`)
        .join(","),
      this.relationshipArrows.length,
      this.relationshipArrows
        .map((a) => `${a.id}:${a.x1Pct}:${a.y1Pct}:${a.x2Pct}:${a.y2Pct}`)
        .join(","),
      this.moreIdeasExpanded ? 1 : 0,
    ].join("|");
  }

  get draftStatusLabel() {
    switch (this.draftStatus) {
      case DRAFT_STATUS.SAVING:
        return i18n("npn_critique_reply.modal.drafts.status_saving");
      case DRAFT_STATUS.SAVED:
        return i18n("npn_critique_reply.modal.drafts.status_saved");
      case DRAFT_STATUS.ERROR:
        return i18n("npn_critique_reply.modal.drafts.status_error");
      default:
        return null;
    }
  }

  get showDraftDiscard() {
    // Only meaningful once we know there's a server-side draft to
    // remove — either restored on open or saved during this session.
    return this.draftsEnabled && this.draftHasSaved;
  }

  get draftImageVersionOutdatedMessage() {
    const notice = this.draftRestoreNotice;
    if (notice && typeof notice === "object" && notice.kind === "image_version_outdated") {
      return i18n("npn_critique_reply.modal.drafts.image_version_outdated", {
        label: notice.label,
      });
    }
    return null;
  }

  get draftImageVersionMissingMessage() {
    return this.draftRestoreNotice === "image_version_missing"
      ? i18n("npn_critique_reply.modal.drafts.image_version_missing")
      : null;
  }

  // Async kickoff from the constructor: fetch any saved draft, apply
  // it to local state, set up the debounced autosaver. Stays a no-op
  // when drafts are disabled or the topic is missing.
  async _initializeDraftSync() {
    if (!this.draftsEnabled) {
      return;
    }
    const topicId = this.topic?.id;
    if (!topicId) {
      return;
    }

    this._autosaver = new DraftAutosaver({
      topicId,
      onStatus: (status) => this._onDraftSaveStatus(status),
      buildPayload: () => this._buildDraftPayload(),
    });

    try {
      const draft = await loadServerDraft(topicId);
      if (this._destroyed) {
        return;
      }
      if (draft) {
        this._restoreDraft(draft);
        this.draftHasSaved = true;
      }
    } catch (e) {
      // Restore failures are non-fatal — the modal still opens, the
      // user can type, and the next autosave will overwrite whatever
      // was there before. We deliberately do NOT surface a banner.
      this._recordError("draft_restore", e, { topicId }, "warn");
    }
  }

  _onDraftSaveStatus(status) {
    if (this._destroyed) {
      return;
    }
    this.draftStatus = status;
    if (status === DRAFT_STATUS.SAVED) {
      const firstSave = !this.draftHasSaved;
      this.draftHasSaved = true;
      // Tell sibling entry-points (footer Start button + OP invitation
      // panel) that a draft now exists for this topic. Only fire on
      // the FIRST save of the session — subsequent autosaves don't
      // change the boolean state, and we don't want to spam listeners
      // every ~1500ms while the user is typing.
      if (firstSave) {
        this._broadcastDraftChanged(true);
      }
    }
    // Record save failures in the diagnostic history so a chain of
    // repeated autosave errors shows up in the next "Copy diagnostic"
    // even when the user hasn't hit Post yet.
    if (status === DRAFT_STATUS.ERROR) {
      this._recordError(
        "draft_autosave",
        new Error("Draft autosave returned ERROR status"),
        { topicId: this.topic?.id },
        "warn"
      );
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] draft-status", { status });
    }
  }

  _broadcastDraftChanged(hasDraft) {
    const topicId = this.topic?.id;
    if (!topicId) {
      return;
    }
    this.appEvents?.trigger(DRAFT_CHANGED_EVENT, { topicId, hasDraft });
  }

  // Compose the current workspace state into the v1 draft shape that
  // the server expects. Annotation conversion reuses the existing
  // schema-aware helpers, so any geometry caps / id normalization
  // applied client-side mirrors the server's normalizer.
  _buildDraftPayload() {
    // Snapshot the active image's edits into the per-image map so
    // the serialized payload picks them up alongside every other
    // image's stored annotations.
    this._annotationsByImageIndex.set(
      this._selectedImageIndex,
      this._snapshotCurrentAnnotations()
    );

    // Build a flat `annotations` array (back-compat: pre-multi-image
    // readers see one array of all kinds) PLUS a per-image map
    // keyed by image_index so restore can route each annotation
    // back to its image. Each annotation in the flat array carries
    // `image_index` (default 0) so a single-array reader still has
    // enough info to attribute marks correctly.
    const annotationsByImage = {};
    const annotations = [];
    const indices = new Set([this._selectedImageIndex]);
    for (const i of this._annotationsByImageIndex.keys()) {
      indices.add(i);
    }
    const orderedIndices = [...indices].sort((a, b) => a - b);
    for (const idx of orderedIndices) {
      const snap = this._annotationsByImageIndex.get(idx);
      if (!snap) {
        continue;
      }
      const per = [];
      per.push(...pinsToAnnotations(snap.notes ?? []));
      if (snap.crop) {
        const c = cropToAnnotation(snap.crop);
        if (c) {
          per.push(c);
        }
      }
      for (const e of eyePathsToAnnotations(snap.eyePaths ?? [])) {
        per.push(e);
      }
      for (const a of attentionPullsToAnnotations(snap.attentionPulls ?? [])) {
        per.push(a);
      }
      for (const a of strongAreasToAnnotations(snap.strongAreas ?? [])) {
        per.push(a);
      }
      for (const a of directionArrowsToAnnotations(
        snap.directionArrows ?? []
      )) {
        per.push(a);
      }
      for (const a of relationshipArrowsToAnnotations(
        snap.relationshipArrows ?? []
      )) {
        per.push(a);
      }
      if (per.length > 0) {
        annotationsByImage[idx] = per;
        for (const a of per) {
          annotations.push({ ...a, image_index: idx });
        }
      }
    }

    const payload = {
      schema_version: 1,
      selected_image_version_key: this.selectedVersionKey ?? null,
      // Submission multi-image index (0 = primary). Persisted so
      // reopening the draft lands the critic on the same image they
      // were last viewing. Always sent; the server tolerates 0 (the
      // legacy single-image case) as the default.
      selected_image_index: this._selectedImageIndex,
      critique_text: this.critiqueText ?? "",
      annotations,
      // New multi-image map: { "0": [...], "1": [...], ... }. Used
      // by _restoreDraft to re-populate the per-image snapshot map.
      // Readers that only know about the flat `annotations` array
      // still work — each entry there carries image_index.
      annotations_by_image: annotationsByImage,
      // Processing example draft entry — flat shape matching
      // ProcessingExampleNormalizer.normalize_for_draft on the
      // server. Null when no example is attached; restored on
      // modal reopen via `_restoreDraft`.
      processing_example: this.processingExample
        ? {
            source_image_version_key:
              this.processingExample.sourceImageVersionKey ?? null,
            source_image_version_label:
              this.processingExample.sourceImageVersionLabel ?? null,
            upload_id: this.processingExample.uploadId ?? null,
            url: this.processingExample.url ?? null,
            short_url: this.processingExample.shortUrl ?? null,
            filename: this.processingExample.filename ?? null,
          }
        : null,
      // Persisted large-image view selection. "reference" or
      // "processing_example". Sent regardless of whether an example
      // exists — the server whitelists the value and the restore
      // path falls back to the auto-switch default if the view
      // doesn't match the current state.
      large_image_view: this.largeImageView,
      // `prompts_expanded` is reused on the wire as the "More ideas
      // expanded" boolean — same field name (so the Ruby DraftNormalizer
      // UI_ALLOWED_KEYS whitelist doesn't need to change) but the new
      // UI binding. `prompts_hidden` is hard-coded false: the panel no
      // longer collapses entirely, and old in-flight drafts that have
      // `prompts_hidden: true` simply ignore that field on restore.
      ui: {
        prompts_hidden: false,
        prompts_expanded: !!this.moreIdeasExpanded,
      },
    };
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] draft-build-payload", {
        textLength: payload.critique_text.length,
        annotationCount: payload.annotations.length,
        imagesWithAnnotations: Object.keys(annotationsByImage).map(Number),
      });
    }
    return payload;
  }

  // Apply a server-loaded draft to in-memory state. Set
  // Edit-mode bootstrap. Mirrors the structure of `_restoreDraft` so
  // the same low-level annotation restore (`_restoreAnnotations`)
  // handles both flows. Read state from the post's serializer
  // attribute + parsed raw rather than from the drafts endpoint.
  //
  // Mostly synchronous: the post's `npn_visual_notes` serializer
  // attribute and id are already present on the model that the
  // post-menu button hands us. The post's `raw` field is NOT
  // always populated though — Discourse only serializes `cooked`
  // (HTML) into the topic post stream by default, and `raw` is
  // typically loaded lazily for editing flows. So:
  //
  //   • If `post.raw` is already populated (immediately after
  //     creating the post in the same session, or after the user
  //     hits the standard composer Edit), we use it directly.
  //   • Otherwise we kick off an async fetch of /posts/:id.json
  //     and patch `this.critiqueText` once the response arrives.
  //     This is the page-refresh case — without the fetch, the
  //     textarea would open empty even though the post body is
  //     intact server-side.
  _initializeFromPost() {
    const post = this.editingPost;
    if (!post) {
      return;
    }
    const payload = post.npn_visual_notes;

    // Critique text: the post's raw is composed as
    //   "<heading>\n\n![visual notes](upload://...)\n\n<text>"
    // by `_composeVisualNotesRaw`. Split on the image-markdown
    // line and take everything after it. Falls back to the whole
    // raw if the format doesn't match (e.g. a hand-edited post).
    if (post.raw) {
      this.critiqueText = this._parseCritiqueTextFromRaw(post.raw);
    } else {
      // Fire-and-forget. Modal renders with an empty textarea for
      // the brief window between open and the fetch resolving;
      // typical RTT < 200ms so the user just sees the text
      // populate. If the fetch fails we leave the textarea empty
      // (the user can retype or close); we don't want to throw a
      // modal-level error for a request that may succeed on retry.
      this._loadPostRawForEdit(post);
    }

    if (payload) {
      const versionKey = payload?.source?.image_version_key ?? null;
      if (versionKey && this.versions.some((v) => v.key === versionKey)) {
        this._selectedVersionKey = versionKey;
      }
      // Multi-image edit restore. Annotations on a post written
      // after the multi-image rollout carry `image_index` per
      // entry (default 0); older single-image posts don't, and
      // _restoreAnnotationsByImage's flatAnnotations branch
      // buckets them all into image 0 so the legacy behaviour is
      // preserved. Active index defaults to 0 (primary image) on
      // edit-open so the canvas mounts against the same image the
      // post is anchored to.
      this._selectedImageIndex = 0;
      this._restoreAnnotationsByImage({
        flatAnnotations: payload.annotations,
        activeIndex: 0,
        versionKey,
      });
    }

    // Processing-example restore for the edit flow. Lives on the
    // post serializer as `npn_processing_example` independently of
    // visual notes; either, both, or neither may be present. Gated
    // by current eligibility — if the topic has since opted out or
    // the site setting flipped off, the existing field is dropped
    // here client-side; a subsequent edit will then clear the
    // server-side field via the explicit-null contract in the
    // update endpoint.
    const examplePayload = post.npn_processing_example;
    if (examplePayload && this.processingExampleAvailable) {
      const restored = normalizeProcessingExampleFromServer(examplePayload);
      if (restored) {
        this.processingExample = restored;
        // Open the modal on the example view by default when editing a
        // post that carries one — same rationale as the post-upload
        // auto-switch: surface the artifact the critic is about to
        // edit at full size. They can toggle back at any time.
        this.largeImageView = LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE;
        // Auto-expand mobile Processing Example disclosure so the
        // edit-mode user immediately sees the artifact controls.
        this.mobileProcessingExampleOpen = true;
      }
    }

    // Same rationale for the Visual tools disclosure on edit-mode
    // restore: if the post had annotations, surface the toolbar so
    // the user can edit them without an extra tap.
    if (this.hasVisualAnnotations) {
      this.mobileVisualToolsOpen = true;
    }
  }

  // Async helper: fetch the post's raw markdown over the network
  // when it wasn't present on the post model (the page-refresh
  // edit case). On success, patch both the post model and the
  // tracked critiqueText so the textarea fills in. Guards against
  // modal teardown mid-flight via `_destroyed`.
  async _loadPostRawForEdit(post) {
    try {
      const json = await ajax(`/posts/${post.id}.json`);
      if (this._destroyed) {
        return;
      }
      // Patch the in-memory post model so subsequent reads (and the
      // hand-edited-body fallback path in _parseCritiqueTextFromRaw)
      // see the freshly-loaded raw.
      if (json?.raw) {
        post.raw = json.raw;
      }
      const text = this._parseCritiqueTextFromRaw(json?.raw ?? "");
      // Only adopt the fetched text if the user hasn't started
      // typing while the request was in flight. Typing during the
      // 100-200ms RTT is unlikely but real on slow connections.
      if (!this.critiqueText) {
        this.critiqueText = text;
      }
    } catch (e) {
      // Soft failure — leave the textarea empty. We deliberately
      // don't throw a modal banner because the user can still type
      // new content.
      this._recordError(
        "edit_load_post_raw",
        e,
        { postId: post.id },
        "warn"
      );
    }
  }

  // Helper for `_initializeFromPost`. Strips the heading + image
  // blocks from the post body so the textarea reopens with just the
  // critic's prose. A reply may carry up to TWO image blocks in the
  // standard order — visual notes, then processing example — and we
  // iteratively strip whichever ones are present. If the format has
  // drifted (hand-edited post, text-only critique), returns the raw
  // unchanged so the user can hand-fix it.
  _parseCritiqueTextFromRaw(raw) {
    if (!raw) {
      return "";
    }
    // Three body shapes live in the database:
    //
    //   PER-IMAGE (current): each image block is heading +
    //   per-image prose paragraphs + image markdown. General prose
    //   sits at the top, then each image's section follows. Edit
    //   needs to recover ALL the prose — general + per-image —
    //   into one textarea while dropping synthetic lines.
    //
    //   TEXT-FIRST (intermediate): text at the top, then sequential
    //   "heading + image" blocks with no per-image prose. The same
    //   strip-headings-and-images logic recovers it correctly.
    //
    //   LEGACY VISUAL-FIRST (pre-multi-image): heading + image at
    //   the start, then the critique text. Same logic — strip the
    //   leading heading + image, prose at the tail survives.
    //
    // Approach: strip image-markdown lines, strip heading lines
    // (English "Visual notes" / "Processing Example" prefixes
    // ending with ":"), then collapse blank-line runs. What
    // remains is the critic's prose in original order.
    const lines = raw.split("\n");
    const out = [];
    const imageLineRe = /^!\[[^\]]*\]\(upload:\/\/[^\s)]+\)\s*$/;
    const headingPrefixRe = /^(Visual notes|Processing Example)\b.*:\s*$/;
    for (const line of lines) {
      if (imageLineRe.test(line)) {
        continue;
      }
      if (headingPrefixRe.test(line.trim())) {
        continue;
      }
      out.push(line);
    }
    return out.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  // `_restoringDraft` first so the didUpdate autosave hook ignores
  // the burst of setter calls — we don't want to immediately PUT
  // back the same payload we just GET'd.
  _restoreDraft(draft) {
    this._restoringDraft = true;

    try {
      this.critiqueText = draft.critique_text ?? "";

      // Restore the multi-image picker selection BEFORE we apply the
      // version key, because secondary images (index >= 1) ignore the
      // version chain — applying the version first would briefly point
      // at a revision URL on the wrong image. Clamp to the available
      // submission images so an out-of-bounds saved index (e.g. an
      // image got removed from the submission) falls back to 0.
      const rawIndex = draft.selected_image_index;
      if (Number.isInteger(rawIndex) && rawIndex >= 0) {
        const count = this.submissionImages.length;
        if (count === 0 || rawIndex < count) {
          this._selectedImageIndex = rawIndex;
        }
      }

      const versionKey = draft.selected_image_version_key ?? null;
      const versionStillExists = versionKey
        ? this.versions.some((v) => v.key === versionKey)
        : true;

      if (!versionKey || versionStillExists) {
        // Apply the saved version selection (or leave the current one
        // alone for a "no version specified" draft).
        if (versionKey) {
          this._selectedVersionKey = versionKey;
        }
        // Multi-image restore: prefer the explicit map when present
        // (drafts saved after the multi-image rollout), fall back to
        // the flat array (legacy drafts) where each entry's
        // image_index — defaulting to 0 — drives the bucketing.
        this._restoreAnnotationsByImage({
          annotationsByImage: draft.annotations_by_image,
          flatAnnotations: draft.annotations,
          activeIndex: this._selectedImageIndex,
          versionKey: draft.selected_image_version_key,
        });

        // Notice when a newer revision exists than the one the draft
        // was started on — informational, not blocking.
        const defaultKey = this.imageVersions?.default_key;
        if (versionKey && defaultKey && versionKey !== defaultKey) {
          const savedVersion = this.versions.find((v) => v.key === versionKey);
          this.draftRestoreNotice = {
            kind: "image_version_outdated",
            label: savedVersion?.label ?? versionKey,
          };
        } else {
          this.draftRestoreNotice = "restored";
        }
      } else {
        // Saved version no longer exists. Restore text only; drop
        // visual annotations and surface a notice.
        this.draftRestoreNotice = "image_version_missing";
      }

      if (draft.ui && typeof draft.ui === "object") {
        // `prompts_expanded` carries the More-ideas-expanded boolean
        // on the wire (see `_buildDraftPayload`). `prompts_hidden`
        // is legacy and intentionally ignored — the section no
        // longer collapses entirely.
        if (typeof draft.ui.prompts_expanded === "boolean") {
          this.moreIdeasExpanded = draft.ui.prompts_expanded;
        }
      }

      // Processing-example restore. Gated by current eligibility so
      // a draft saved when the feature was enabled doesn't surface
      // an upload after the photographer opts out or the admin
      // turns the setting off. The example is silently dropped
      // rather than retained-but-hidden so it can't bleed into the
      // next save.
      if (draft.processing_example && this.processingExampleAvailable) {
        this.processingExample = normalizeProcessingExampleFromServer(
          draft.processing_example
        );
        if (this.processingExample) {
          // Auto-expand the mobile Processing Example disclosure when
          // a draft restores with an existing upload — otherwise the
          // user would have to tap twice (open + Replace/Remove) to
          // act on the example they previously uploaded.
          this.mobileProcessingExampleOpen = true;
        }
      }

      // Auto-expand the mobile Visual tools disclosure when restoring
      // annotations so the toolbar isn't hidden behind a closed
      // summary above the (just-restored) markers on the image.
      if (this.hasVisualAnnotations) {
        this.mobileVisualToolsOpen = true;
      }

      // Large-image view restore. The draft may carry a persisted
      // selection ("reference" or "processing_example"); fall back to
      // the auto-switch default — show the example when one exists,
      // otherwise the reference. Guard against an upload that was
      // dropped above (eligibility-gated): can't view an example
      // we don't have.
      const savedView = draft.large_image_view;
      if (savedView && LARGE_IMAGE_VIEWS.includes(savedView)) {
        this.largeImageView =
          savedView === LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE &&
          !this.hasProcessingExample
            ? LARGE_IMAGE_VIEW_REFERENCE
            : savedView;
      } else if (this.hasProcessingExample) {
        this.largeImageView = LARGE_IMAGE_VIEW_PROCESSING_EXAMPLE;
      } else {
        this.largeImageView = LARGE_IMAGE_VIEW_REFERENCE;
      }
    } finally {
      // Defer clearing the restoring flag until the next microtask so
      // the didUpdate hook sees one stable signature this render.
      queueMicrotask(() => {
        this._restoringDraft = false;
      });
    }
  }

  _restoreAnnotations(annotations, versionKey) {
    const snapshot = this._buildSnapshotFromAnnotations(annotations, versionKey);
    this._restoreAnnotationsFromSnapshot(snapshot);
    this._bumpIdCountersFromSnapshot(snapshot);
    if (snapshot.crop?.aspectRatio) {
      this.cropAspectRatio = snapshot.crop.aspectRatio;
    }
    this.cropSelected = !!snapshot.crop;
  }

  // Multi-image draft restore. Accepts either:
  //   - `annotationsByImage`: { 0: [...], 1: [...], ... }  (preferred,
  //      set by the multi-image draft payload), OR
  //   - `flatAnnotations`: a single array whose entries carry
  //     `image_index` (back-compat for drafts written before the map
  //     existed).
  // Builds a snapshot for each image and stashes them in
  // `_annotationsByImageIndex`. Then restores the active image's
  // tracked fields from its snapshot.
  _restoreAnnotationsByImage({
    annotationsByImage,
    flatAnnotations,
    activeIndex,
    versionKey,
  }) {
    const grouped = {};
    if (annotationsByImage && typeof annotationsByImage === "object") {
      for (const [key, list] of Object.entries(annotationsByImage)) {
        const idx = Number.parseInt(key, 10);
        if (Number.isInteger(idx) && idx >= 0 && Array.isArray(list)) {
          grouped[idx] = list;
        }
      }
    } else if (Array.isArray(flatAnnotations)) {
      for (const entry of flatAnnotations) {
        const idx = Number.isInteger(entry?.image_index)
          ? entry.image_index
          : 0;
        if (!grouped[idx]) {
          grouped[idx] = [];
        }
        grouped[idx].push(entry);
      }
    }

    // Build snapshots for each image and stash them. Active image is
    // populated last so the tracked-field restore reflects the right
    // snapshot.
    this._annotationsByImageIndex.clear();
    const activeIdx = Number.isInteger(activeIndex)
      ? activeIndex
      : this._selectedImageIndex;
    let activeSnapshot = null;
    for (const [idxKey, list] of Object.entries(grouped)) {
      const idx = Number.parseInt(idxKey, 10);
      const snapshot = this._buildSnapshotFromAnnotations(list, versionKey);
      this._annotationsByImageIndex.set(idx, snapshot);
      if (idx === activeIdx) {
        activeSnapshot = snapshot;
      }
    }
    this._restoreAnnotationsFromSnapshot(activeSnapshot);
    if (activeSnapshot) {
      this._bumpIdCountersFromSnapshot(activeSnapshot);
      if (activeSnapshot.crop?.aspectRatio) {
        this.cropAspectRatio = activeSnapshot.crop.aspectRatio;
      }
      this.cropSelected = !!activeSnapshot.crop;
    }
  }

  // Convert a list of annotation objects (whatever their image_index)
  // into a single-image snapshot. Reuses the existing per-kind
  // converters so the restore logic stays identical to the legacy
  // path. image_index is intentionally ignored here — callers are
  // expected to have grouped by index already.
  _buildSnapshotFromAnnotations(annotations, versionKey) {
    const list = Array.isArray(annotations) ? annotations : [];
    const synthPayload = {
      source: { image_version_key: versionKey ?? null },
      annotations: list,
    };
    const pins = annotationsToPins(synthPayload);
    const notes = pins.map((p) => ({
      number: p.number,
      xPct: p.xPct,
      yPct: p.yPct,
      note: p.note ?? null,
    }));
    const cropEntry = list.find((a) => a?.kind === "crop");
    const crop = cropEntry ? annotationToCrop(cropEntry) : null;
    const eyePaths = list
      .filter((a) => a?.kind === "eye_path")
      .map((entry) => annotationToEyePath(entry))
      .filter((p) => p && (p.points?.length ?? 0) > 0);
    return {
      notes,
      crop,
      eyePaths,
      attentionPulls: annotationsToAttentionPulls(synthPayload),
      strongAreas: annotationsToStrongAreas(synthPayload),
      directionArrows: annotationsToDirectionArrows(synthPayload),
      relationshipArrows: annotationsToRelationshipArrows(synthPayload),
    };
  }

  // Bump the per-kind id counters past any ids in the restored
  // snapshot so newly-created markers don't collide with restored
  // ones. Pulled out of the legacy _restoreAnnotations so both the
  // single-image and multi-image restore paths can share it.
  _bumpIdCountersFromSnapshot(snapshot) {
    if (!snapshot) {
      return;
    }
    this._attentionPullIdCounter = (snapshot.attentionPulls ?? []).reduce(
      (max, p) => Math.max(max, extractIdSuffix(p.id) ?? 0),
      this._attentionPullIdCounter ?? 0
    );
    this._strongAreaIdCounter = (snapshot.strongAreas ?? []).reduce(
      (max, s) => Math.max(max, extractIdSuffix(s.id) ?? 0),
      this._strongAreaIdCounter ?? 0
    );
    this._directionArrowIdCounter = (snapshot.directionArrows ?? []).reduce(
      (max, a) => Math.max(max, extractIdSuffix(a.id) ?? 0),
      this._directionArrowIdCounter ?? 0
    );
    this._relationshipArrowIdCounter = (
      snapshot.relationshipArrows ?? []
    ).reduce(
      (max, a) => Math.max(max, extractIdSuffix(a.id) ?? 0),
      this._relationshipArrowIdCounter ?? 0
    );
  }

  // Called by the didUpdate modifier whenever `draftSignature`
  // changes. Skips the no-op restore burst at the start of the
  // session and forwards to the per-topic debounce timer.
  @action
  scheduleDraftAutosave() {
    if (!this.draftsEnabled || this._restoringDraft) {
      return;
    }
    this._autosaver?.schedule();
  }

  @action
  discardDraft() {
    this.dialog.confirm({
      message: i18n("npn_critique_reply.modal.drafts.discard_confirm_message"),
      confirmButtonLabel: "npn_critique_reply.modal.drafts.discard_confirm_yes",
      cancelButtonLabel: "npn_critique_reply.modal.drafts.discard_confirm_no",
      didConfirm: () => this._performDiscardDraft(),
    });
  }

  async _performDiscardDraft() {
    const topicId = this.topic?.id;
    this._autosaver?.cancel?.();
    // Broadcast immediately so sibling entry-points flip back to
    // "Start" copy without waiting for the DELETE round-trip.
    if (this.draftHasSaved) {
      this._broadcastDraftChanged(false);
    }
    try {
      if (topicId) {
        await deleteServerDraft(topicId);
      }
    } catch (_e) {
      // Network failure — still clear local state so the user isn't
      // stuck staring at a draft they asked to throw away.
    }
    if (this._destroyed) {
      return;
    }
    this._restoringDraft = true;
    this.critiqueText = "";
    this.notes = [];
    this.crop = null;
    this.eyePaths = [];
    this._activeEyePathId = null;
    this._eyePathStarterInserted = false;
    this.attentionPulls = [];
    this.strongAreas = [];
    this.directionArrows = [];
    this.relationshipArrows = [];
    this.cropSelected = false;
    this.selectedEyePathId = null;
    this.selectedPinNumber = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;
    // Processing example is part of the workspace state too — wipe it
    // here so Discard draft returns the modal to a true clean-start,
    // not "everything except the uploaded example".
    this.processingExample = null;
    this.processingExampleError = null;
    this.largeImageView = LARGE_IMAGE_VIEW_REFERENCE;
    // Collapse the mobile disclosures back to their fresh-modal
    // defaults — there's nothing left to surface.
    this.mobileVisualToolsOpen = false;
    this.mobileProcessingExampleOpen = false;
    this.draftRestoreNotice = null;
    this.draftStatus = DRAFT_STATUS.IDLE;
    this.draftHasSaved = false;
    queueMicrotask(() => {
      this._restoringDraft = false;
    });
  }

  // Called from success paths in Post Critique and Edit in Composer.
  // Cancels any pending autosave (so it doesn't race the delete) and
  // removes the server-side draft. Failures here are silent — the
  // worst case is a stale draft that gets garbage-collected by the
  // TTL cleanup down the line.
  async _clearDraftAfterSuccess() {
    if (!this.draftsEnabled) {
      return;
    }
    const topicId = this.topic?.id;
    if (!topicId) {
      return;
    }
    this._autosaver?.cancel?.();
    // Tell sibling entry-points the draft is gone even if the DELETE
    // request itself fails — the modal is closing on success either
    // way, and the next page render will reconcile with the server.
    if (this.draftHasSaved) {
      this._broadcastDraftChanged(false);
    }
    try {
      await deleteServerDraft(topicId);
    } catch (_e) {
      // Silent — the toast already says "critique posted".
    }
  }

  <template>
    <DModal
      @title={{i18n "npn_critique_reply.modal.title"}}
      @closeModal={{@closeModal}}
      @beforeClose={{this.beforeClose}}
      class={{this.modalClassNames}}
    >
      <:body>
        {{! Hidden autosave anchor. didUpdate fires whenever any
            draft-relevant tracked state changes (via draftSignature),
            and the scheduler debounces the actual PUT. Keeps every
            mutator path autosave-aware without threading an explicit
            schedule() call through 20+ action methods. }}
        <span
          hidden="true"
          aria-hidden="true"
          {{didUpdate this.scheduleDraftAutosave this.draftSignature}}
        ></span>

        {{! Floating Quote button — appears when the user selects
            text inside Photographer's Notes. position: fixed +
            inline top/left from _quoteButtonPosition (viewport
            pixels). Rendered at body root so it isn't clipped by
            panel overflow. }}
        {{#if this._quoteButtonPosition}}
          <button
            type="button"
            class="btn btn-default btn-icon-text
              npn-critique-reply-modal__quote-button"
            style="position: fixed; top: {{this._quoteButtonPosition.top}}px;
              left: {{this._quoteButtonPosition.left}}px;"
            aria-label={{i18n
              "npn_critique_reply.modal.photographers_notes.quote_aria"
            }}
            {{on "mousedown" this.insertQuoteFromPhotographersNotes}}
          >
            {{dIcon "quote-left"}}
            <span class="d-button-label">
              {{i18n "npn_critique_reply.modal.photographers_notes.quote"}}
            </span>
          </button>
        {{/if}}

        {{#if this.draftImageVersionMissingMessage}}
          <div
            class="npn-critique-reply-modal__draft-notice
              npn-critique-reply-modal__draft-notice--image-missing"
            role="status"
          >
            {{this.draftImageVersionMissingMessage}}
          </div>
        {{/if}}
        {{#if this.draftImageVersionOutdatedMessage}}
          <div
            class="npn-critique-reply-modal__draft-notice
              npn-critique-reply-modal__draft-notice--image-outdated"
            role="status"
          >
            {{this.draftImageVersionOutdatedMessage}}
          </div>
        {{/if}}

        <div class="npn-critique-reply-modal__layout">
          {{! Left pane wraps the image column AND the Processing
              Example row so they share a single scroll context,
              independent from the writing pane on the right.
              Without this wrapper, the modal-body scroll would tie
              the two columns together: scrolling long write-col
              content would shift the Processing Example up under
              the (sticky) image. With the wrapper, the left and
              right panes each get overflow:auto and scroll
              independently. }}
          {{#if this.hasImage}}
            <div
              class="npn-critique-reply-modal__left-pane"
              {{didInsert this.setupLeftPane}}
            >
              <aside
                class="npn-critique-reply-modal__image-col"
                aria-labelledby="npn-critique-reply-image-heading"
              >
              {{! Header row: section heading on the left, Larger
                  Image / Return to Writing toggle on the right.
                  The toggle is the entry point for Visual Focus
                  Mode (see `visualFocusMode` tracked state). When
                  active, the modal modifier class hides the write
                  pane and lets the image-col fill the modal. }}
              <div class="npn-critique-reply-modal__image-col-header">
                <h3
                  id="npn-critique-reply-image-heading"
                  class="npn-critique-reply-modal__image-heading"
                >
                  {{i18n "npn_critique_reply.modal.reference_image"}}
                </h3>

                <div
                  class="npn-critique-reply-modal__image-col-header-actions"
                >
                  {{! Processing Example used to live here as a
                      quick-access popover. Moved out of the header
                      so the only action exposed up here is "Larger
                      Image" — Processing Example is reached via
                      the inline link near "Showing X" status and
                      via the Optional Processing Example section
                      lower in the pane. }}
                  <DButton
                    class="btn-flat btn-small npn-critique-reply-modal__visual-focus-toggle"
                    @action={{this.toggleVisualFocusMode}}
                    @icon={{if
                      this.visualFocusMode
                      "down-left-and-up-right-to-center"
                      "up-right-and-down-left-from-center"
                    }}
                    @label={{if
                      this.visualFocusMode
                      "npn_critique_reply.modal.visual_focus.exit"
                      "npn_critique_reply.modal.visual_focus.enter"
                    }}
                    @title={{if
                      this.visualFocusMode
                      "npn_critique_reply.modal.visual_focus.exit_title"
                      "npn_critique_reply.modal.visual_focus.enter_title"
                    }}
                    aria-pressed={{if this.visualFocusMode "true" "false"}}
                  />
                </div>
              </div>

              {{! Image first — moved up so the reference is the
                  primary visual element under the header. Version
                  selector + large-image-view-toggle (the "Showing X"
                  status indicators) now sit below the image. The
                  visual tools come further down, under their own
                  "Optional Visual Notes" section header. }}
              {{#if this.viewingProcessingExample}}
                {{! The alt text on the <img> already carries the
                    accessible name; no separate figcaption needed. }}
                <div
                  class="npn-critique-reply-modal__processing-example-large"
                >
                  <img
                    class="npn-critique-reply-modal__processing-example-large-img"
                    src={{this.processingExample.url}}
                    alt={{this.largeImageAlt}}
                  />
                </div>
              {{else}}
              <NpnCritiqueImageReference
                @imageUrl={{this.effectiveImageUrl}}
                @alt={{this.imageAlt}}
                @pins={{this.notes}}
                @crop={{this.crop}}
                @visualMode={{this.visualMode}}
                @areaShapeMode={{this.areaShapeMode}}
                @eyePathInteractionMode={{this.eyePathInteractionMode}}
                @selectedNumber={{this.selectedPinNumber}}
                @cropSelected={{this.cropSelected}}
                @onImageClick={{this.addPin}}
                @onPinSelect={{this.selectPin}}
                @onMovePin={{this.movePin}}
                @pinMoveEnabled={{this.pinMoveEnabled}}
                @onAddCrop={{this.addCrop}}
                @onSelectCrop={{this.selectCrop}}
                @onUpdateCrop={{this.updateCrop}}
                @pendingCropPopover={{this.pendingCropPopover}}
                @pendingCropPopoverText={{this.pendingCropPopoverText}}
                @onPendingCropPopoverInput={{this.updatePendingCropPopoverText}}
                @onConfirmPendingCropPopover={{this.confirmPendingCropPopover}}
                @onSkipPendingCropPopover={{this.skipPendingCropPopover}}
                @eyePaths={{this.eyePaths}}
                @selectedEyePathId={{this.selectedEyePathId}}
                @onAddEyePathPoint={{this.addEyePathPoint}}
                @onCommitEyePath={{this.commitEyePath}}
                @onSelectEyePath={{this.selectEyePath}}
                @onMoveEyePathPoint={{this.moveEyePathPoint}}
                @attentionPulls={{this.attentionPulls}}
                @selectedAttentionPullId={{this.selectedAttentionPullId}}
                @attentionPullEditEnabled={{this.attentionPullEditEnabled}}
                @retracingAttentionPullId={{this.retracingAttentionPullId}}
                @onAddAttentionPull={{this.addAttentionPull}}
                @onAddAttentionPullPath={{this.addAttentionPullPath}}
                @onRetraceAttentionPullPath={{this.retraceAttentionPullPath}}
                @onSelectAttentionPull={{this.selectAttentionPull}}
                @onUpdateAttentionPull={{this.updateAttentionPull}}
                @pendingAttentionPullPopover={{this.pendingAttentionPullPopover}}
                @pendingAttentionPullPopoverText={{this.pendingAttentionPullPopoverText}}
                @onPendingAttentionPullPopoverInput={{this.updatePendingAttentionPullPopoverText}}
                @onConfirmPendingAttentionPullPopover={{this.confirmPendingAttentionPullPopover}}
                @onSkipPendingAttentionPullPopover={{this.skipPendingAttentionPullPopover}}
                @strongAreas={{this.strongAreas}}
                @selectedStrongAreaId={{this.selectedStrongAreaId}}
                @strongAreaEditEnabled={{this.strongAreaEditEnabled}}
                @retracingStrongAreaId={{this.retracingStrongAreaId}}
                @onAddStrongArea={{this.addStrongArea}}
                @onAddStrongAreaPath={{this.addStrongAreaPath}}
                @onRetraceStrongAreaPath={{this.retraceStrongAreaPath}}
                @onSelectStrongArea={{this.selectStrongArea}}
                @onUpdateStrongArea={{this.updateStrongArea}}
                @pendingStrongAreaPopover={{this.pendingStrongAreaPopover}}
                @pendingStrongAreaPopoverText={{this.pendingStrongAreaPopoverText}}
                @onPendingStrongAreaPopoverInput={{this.updatePendingStrongAreaPopoverText}}
                @onConfirmPendingStrongAreaPopover={{this.confirmPendingStrongAreaPopover}}
                @onSkipPendingStrongAreaPopover={{this.skipPendingStrongAreaPopover}}
                @pendingEyePathPopover={{this.pendingEyePathPopover}}
                @pendingEyePathPopoverText={{this.pendingEyePathPopoverText}}
                @onPendingEyePathPopoverInput={{this.updatePendingEyePathPopoverText}}
                @onConfirmPendingEyePathPopover={{this.confirmPendingEyePathPopover}}
                @onSkipPendingEyePathPopover={{this.skipPendingEyePathPopover}}
                @directionArrows={{this.directionArrows}}
                @selectedDirectionArrowId={{this.selectedDirectionArrowId}}
                @onAddDirectionArrow={{this.addDirectionArrow}}
                @onSelectDirectionArrow={{this.selectDirectionArrow}}
                @onUpdateDirectionArrow={{this.updateDirectionArrow}}
                @pendingDirectionArrowPopover={{this.pendingDirectionArrowPopover}}
                @pendingDirectionArrowPopoverText={{this.pendingDirectionArrowPopoverText}}
                @onPendingDirectionArrowPopoverInput={{this.updatePendingDirectionArrowPopoverText}}
                @onConfirmPendingDirectionArrowPopover={{this.confirmPendingDirectionArrowPopover}}
                @onSkipPendingDirectionArrowPopover={{this.skipPendingDirectionArrowPopover}}
                @relationshipArrows={{this.relationshipArrows}}
                @selectedRelationshipArrowId={{this.selectedRelationshipArrowId}}
                @onAddRelationshipArrow={{this.addRelationshipArrow}}
                @onSelectRelationshipArrow={{this.selectRelationshipArrow}}
                @onUpdateRelationshipArrow={{this.updateRelationshipArrow}}
                @pendingRelationshipArrowPopover={{this.pendingRelationshipArrowPopover}}
                @pendingRelationshipArrowPopoverText={{this.pendingRelationshipArrowPopoverText}}
                @onPendingRelationshipArrowPopoverInput={{this.updatePendingRelationshipArrowPopoverText}}
                @onConfirmPendingRelationshipArrowPopover={{this.confirmPendingRelationshipArrowPopover}}
                @onSkipPendingRelationshipArrowPopover={{this.skipPendingRelationshipArrowPopover}}
                @cropAspectRatio={{this.cropAspectRatio}}
                @pendingPin={{this.pendingPin}}
                @pendingPinNoteText={{this.pendingPinNoteText}}
                @onPendingNoteInput={{this.updatePendingPinNoteText}}
                @onConfirmPendingNote={{this.confirmPendingPinNote}}
                @onSkipPendingNote={{this.skipPendingPinNote}}
              />
              {{/if}}

              {{! Multi-image picker. Submissions can carry up to 5
                  images; pills + prev/next chevrons let the critic
                  flip through them without showing all at once.
                  Hidden when the submission has 0 or 1 images (the
                  legacy single-image case). Switching images uses the
                  same confirm-clear-annotations flow as version
                  switching. }}
              {{#if this.hasMultipleSubmissionImages}}
                <div
                  class="npn-critique-reply-modal__image-picker"
                  role="group"
                  aria-label={{i18n
                    "npn_critique_reply.modal.image_picker.label"
                  }}
                >
                  <button
                    type="button"
                    class="npn-critique-reply-modal__image-picker-nav"
                    aria-label={{i18n
                      "npn_critique_reply.modal.image_picker.previous"
                    }}
                    disabled={{this.isOnFirstSubmissionImage}}
                    {{on "click" this.selectPreviousImage}}
                  >{{dIcon "chevron-left"}}</button>
                  {{#each this.submissionImages as |img|}}
                    <button
                      type="button"
                      class="npn-critique-reply-modal__image-picker-pill
                        {{if
                          (eq img.index this.selectedImageIndex)
                          'is-selected'
                        }}"
                      aria-pressed={{if
                        (eq img.index this.selectedImageIndex)
                        "true"
                        "false"
                      }}
                      {{on "click" (fn this.selectImage img.index)}}
                    >{{img.label}}</button>
                  {{/each}}
                  <button
                    type="button"
                    class="npn-critique-reply-modal__image-picker-nav"
                    aria-label={{i18n
                      "npn_critique_reply.modal.image_picker.next"
                    }}
                    disabled={{this.isOnLastSubmissionImage}}
                    {{on "click" this.selectNextImage}}
                  >{{dIcon "chevron-right"}}</button>
                </div>
              {{/if}}

              {{! Version (revision) selector. Revisions only apply to
                  the primary submission image, so this hides once the
                  critic switches to a non-primary image. }}
              {{#if this.versionSelectorAvailable}}
                <div
                  class="npn-critique-reply-modal__version-selector"
                  role="group"
                  aria-label={{i18n
                    "npn_critique_reply.modal.version_selector_label"
                  }}
                >
                  {{#each this.versions as |v|}}
                    <button
                      type="button"
                      class="npn-critique-reply-modal__version-button
                        {{if (eq v.key this.selectedVersionKey) 'is-selected'}}"
                      aria-pressed={{if
                        (eq v.key this.selectedVersionKey)
                        "true"
                        "false"
                      }}
                      {{on "click" (fn this.selectVersion v.key)}}
                    >
                      {{#if (eq v.key this.selectedVersionKey)}}
                        <span
                          class="npn-critique-reply-modal__version-check"
                          aria-hidden="true"
                        >
                          {{dIcon "check"}}
                        </span>
                      {{/if}}
                      <span
                        class="npn-critique-reply-modal__version-label"
                      >{{v.label}}</span>
                    </button>
                  {{/each}}
                </div>
              {{/if}}

              {{! Large-image view toggle. Surfaces only once a
                  processing example exists — before upload there's
                  nothing to switch to. Implemented as a pill-button
                  group matching the version selector visually so the
                  two "what image am I looking at" affordances feel
                  related. Uses aria-pressed so screen readers
                  announce the active view. }}
              {{#if this.hasProcessingExample}}
                <div
                  class="npn-critique-reply-modal__large-image-view"
                  role="group"
                  aria-label={{i18n
                    "npn_critique_reply.modal.large_image_view.label"
                  }}
                >
                  <button
                    type="button"
                    class="npn-critique-reply-modal__large-image-view-button
                      {{if this.viewingReference 'is-selected'}}"
                    aria-pressed={{if this.viewingReference "true" "false"}}
                    {{on
                      "click"
                      (fn this.setLargeImageView "reference")
                    }}
                  >
                    {{#if this.viewingReference}}
                      <span
                        class="npn-critique-reply-modal__large-image-view-check"
                        aria-hidden="true"
                      >
                        {{dIcon "check"}}
                      </span>
                    {{/if}}
                    <span
                      class="npn-critique-reply-modal__large-image-view-label"
                    >
                      {{i18n
                        "npn_critique_reply.modal.large_image_view.reference"
                      }}
                    </span>
                  </button>
                  <button
                    type="button"
                    class="npn-critique-reply-modal__large-image-view-button
                      {{if this.viewingProcessingExample 'is-selected'}}"
                    aria-pressed={{if
                      this.viewingProcessingExample
                      "true"
                      "false"
                    }}
                    {{on
                      "click"
                      (fn this.setLargeImageView "processing_example")
                    }}
                  >
                    {{#if this.viewingProcessingExample}}
                      <span
                        class="npn-critique-reply-modal__large-image-view-check"
                        aria-hidden="true"
                      >
                        {{dIcon "check"}}
                      </span>
                    {{/if}}
                    <span
                      class="npn-critique-reply-modal__large-image-view-label"
                    >
                      {{i18n
                        "npn_critique_reply.modal.large_image_view.processing_example"
                      }}
                    </span>
                  </button>

                  {{! Replace / Remove anchored to the view-toggle row so
                      they're always visible without scrolling or
                      opening the popover. Acts on the same Processing
                      Example as the popover and the below-image
                      section. }}
                  <div
                    class="npn-critique-reply-modal__large-image-view-actions"
                  >
                    <DButton
                      class="btn-flat btn-small"
                      @action={{this.triggerProcessingExampleFilePicker}}
                      @icon="rotate"
                      @label="npn_critique_reply.modal.processing_example.replace"
                      @disabled={{this.processingExampleUploading}}
                    />
                    <DButton
                      class="btn-flat btn-small"
                      @action={{this.removeProcessingExample}}
                      @icon="trash-can"
                      @label="npn_critique_reply.modal.processing_example.remove"
                      @disabled={{this.processingExampleUploading}}
                    />
                  </div>
                </div>
              {{/if}}

              {{! Canonical image-status line — single line directly
                  under the image. Replaces the older `__version-
                  status` that used to live below the a11y list and
                  the inline "Add processing example" anchor link
                  that scrolled to the section below. Processing
                  Example is now reachable via the disclosure button
                  in the Optional Processing Example section. }}
              {{#if this.showingVersionLabel}}
                <p
                  class="npn-critique-reply-modal__image-status-row"
                  role="status"
                  aria-live="polite"
                >
                  <span
                    class="npn-critique-reply-modal__image-status"
                  >{{this.showingVersionLabel}}</span>
                  {{#if this.revisionNote}}
                    <span
                      class="npn-critique-reply-modal__image-status-sep"
                      aria-hidden="true"
                    >—</span>
                    <span
                      class="npn-critique-reply-modal__version-note"
                    >{{i18n
                        "npn_critique_reply.modal.revision_note"
                        note=this.revisionNote
                      }}</span>
                  {{/if}}
                </p>
              {{/if}}

              {{! Optional Visual Notes section. Toolbar now sits
                  BELOW the image with a section heading and helper
                  copy so visual marks read as optional support, not
                  as the workspace's primary purpose. Hidden entirely
                  when the user is looking at the processing example
                  — in v1 annotations apply only to the reference
                  image, so surfacing the tools here would imply
                  otherwise. A compact note replaces the toolbar so
                  the disabled state is legible. }}
              {{#if this.visualNotesAvailable}}
                <section
                  class="npn-critique-reply-modal__optional-visual-notes"
                  aria-labelledby="npn-critique-reply-optional-visual-notes-heading"
                >
                <h3
                  id="npn-critique-reply-optional-visual-notes-heading"
                  class="npn-critique-reply-modal__optional-section-heading"
                >
                  {{i18n
                    "npn_critique_reply.modal.optional_visual_notes_heading"
                  }}
                </h3>
                <p
                  class="npn-critique-reply-modal__optional-section-helper"
                >
                  {{i18n
                    "npn_critique_reply.modal.optional_visual_notes_helper"
                  }}
                </p>
                {{#if this.viewingProcessingExample}}
                  <p
                    class="npn-critique-reply-modal__visual-notes-disabled-note"
                    role="status"
                  >
                    {{i18n
                      "npn_critique_reply.modal.large_image_view.tools_apply_to_reference"
                    }}
                  </p>
                {{else}}
                {{! Mobile-only disclosure. The summary button is
                    rendered always but hidden on desktop via CSS;
                    the content underneath stays open on desktop and
                    is gated by `is-open` on mobile. JS state lives
                    in mobileVisualToolsOpen; auto-set to true when
                    a draft/edit restore brings in annotations. }}
                <div
                  class="npn-critique-reply-modal__visual-tools-disclosure
                    {{if this.mobileVisualToolsOpen 'is-open'}}"
                >
                  <button
                    type="button"
                    class="npn-critique-reply-modal__visual-tools-summary"
                    aria-expanded={{if this.mobileVisualToolsOpen "true" "false"}}
                    aria-controls="npn-critique-reply-visual-tools-content"
                    {{on "click" this.toggleMobileVisualTools}}
                  >
                    <span
                      class="npn-critique-reply-modal__visual-tools-summary-label"
                    >
                      {{i18n
                        "npn_critique_reply.modal.mobile.visual_tools_summary"
                      }}
                    </span>
                    <span
                      class="npn-critique-reply-modal__visual-tools-summary-chevron"
                      aria-hidden="true"
                    >
                      {{dIcon "chevron-down"}}
                    </span>
                  </button>
                  <div
                    id="npn-critique-reply-visual-tools-content"
                    class="npn-critique-reply-modal__visual-tools-content"
                  >
                <div
                  class="npn-critique-reply-modal__visual-notes-toolbar"
                  role="toolbar"
                  aria-label={{i18n "npn_critique_reply.visual_notes.toolbar_label"}}
                >
                  {{! Mode toggles — exactly one active at a time. }}
                  <DButton
                    class={{if this.noteMode "btn-primary" "btn-default"}}
                    @action={{this.toggleNoteMode}}
                    @icon={{if this.noteMode "check" "plus"}}
                    @label={{if
                      this.noteMode
                      "npn_critique_reply.visual_notes.done"
                      "npn_critique_reply.visual_notes.numbered_notes"
                    }}
                    @title="npn_critique_reply.visual_notes.numbered_notes_title"
                    @disabled={{this.isPosting}}
                  />
                  <DButton
                    class={{if this.cropMode "btn-primary" "btn-default"}}
                    @action={{this.toggleCropMode}}
                    @icon={{if this.cropMode "check" "crop-simple"}}
                    @label={{if
                      this.cropMode
                      "npn_critique_reply.visual_notes.crop_done"
                      "npn_critique_reply.visual_notes.crop_suggestion"
                    }}
                    @title="npn_critique_reply.visual_notes.crop_suggestion_title"
                    @disabled={{this.isPosting}}
                  />
                  <DButton
                    class={{if this.eyePathMode "btn-primary" "btn-default"}}
                    @action={{this.toggleEyePathMode}}
                    @icon={{if this.eyePathMode "check" "route"}}
                    @label={{if
                      this.eyePathMode
                      "npn_critique_reply.visual_notes.eye_path_done"
                      "npn_critique_reply.visual_notes.eye_path"
                    }}
                    @title="npn_critique_reply.visual_notes.eye_path_title"
                    @disabled={{this.isPosting}}
                  />
                  {{! Unified Area tool. Internally still routes
                      through attentionPullMode / attention_pull —
                      schema and tracked state are unchanged so
                      existing annotations remain compatible. Only
                      the labels, tooltip, and helper hint change. }}
                  <DButton
                    class={{if
                      this.attentionPullMode
                      "btn-primary"
                      "btn-default"
                    }}
                    @action={{this.toggleAttentionPullMode}}
                    @icon={{if
                      this.attentionPullMode
                      "check"
                      "draw-polygon"
                    }}
                    @label={{if
                      this.attentionPullMode
                      "npn_critique_reply.visual_notes.area_note_done"
                      "npn_critique_reply.visual_notes.area_note"
                    }}
                    @title="npn_critique_reply.visual_notes.area_note_title"
                    @disabled={{this.isPosting}}
                  />
                  <DButton
                    class={{if
                      this.directionArrowMode
                      "btn-primary"
                      "btn-default"
                    }}
                    @action={{this.toggleDirectionArrowMode}}
                    @icon={{if
                      this.directionArrowMode
                      "check"
                      "arrow-right"
                    }}
                    @label={{if
                      this.directionArrowMode
                      "npn_critique_reply.visual_notes.direction_arrow_done"
                      "npn_critique_reply.visual_notes.direction_arrow"
                    }}
                    @title="npn_critique_reply.visual_notes.direction_arrow_title"
                    @disabled={{this.isPosting}}
                  />
                  <DButton
                    class={{if
                      this.relationshipArrowMode
                      "btn-primary"
                      "btn-default"
                    }}
                    @action={{this.toggleRelationshipArrowMode}}
                    @icon={{if
                      this.relationshipArrowMode
                      "check"
                      "arrows-left-right"
                    }}
                    @label={{if
                      this.relationshipArrowMode
                      "npn_critique_reply.visual_notes.relationship_arrow_done"
                      "npn_critique_reply.visual_notes.relationship_arrow"
                    }}
                    @title="npn_critique_reply.visual_notes.relationship_arrow_title"
                    @disabled={{this.isPosting}}
                  />

                </div>

                {{! Row 2 — per-mode contextual actions + crop's
                    aspect-ratio chooser. Always rendered so its
                    reserved height keeps the image position stable
                    when modes change. When the active mode has
                    nothing to surface (or no mode is active), the
                    strip is empty but maintains its min-height. }}
                <div
                  class="npn-critique-reply-modal__visual-notes-secondary"
                  role="toolbar"
                  aria-label={{i18n
                    "npn_critique_reply.visual_notes.toolbar_label"
                  }}
                >
                    {{! Pin mode. Empty state → "click to add..."
                        hint; once any pin exists → Remove (when
                        selected) + Clear. }}
                    {{#if this.noteMode}}
                      {{#if this.notes.length}}
                        {{#if this.selectedPin}}
                          <DButton
                            class="btn-default npn-critique-reply-modal__remove-pin"
                            @icon="trash-can"
                            @action={{this.removeSelectedPin}}
                            @translatedLabel={{i18n
                              "npn_critique_reply.visual_notes.remove_note"
                              number=this.selectedPin.number
                            }}
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearNotes}}
                          @label="npn_critique_reply.visual_notes.clear"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                    {{/if}}

                    {{! Crop mode actions. The Remove (trash) and
                        Replace flat are kept; "Clear crop" used to be
                        a separate flat button that called the same
                        action as Remove crop — dropped that
                        duplicate. }}
                    {{#if this.cropMode}}
                      {{#if this.crop}}
                        <DButton
                          class="btn-default npn-critique-reply-modal__remove-pin"
                          @icon="trash-can"
                          @action={{this.clearCrop}}
                          @label="npn_critique_reply.visual_notes.crop_remove"
                          @disabled={{this.isPosting}}
                        />
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.replaceCrop}}
                          @label="npn_critique_reply.visual_notes.crop_replace"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}

                      {{! Aspect-ratio chooser folds into the
                          secondary row instead of being its own
                          third strip. }}
                      <span
                        class="npn-critique-reply-modal__crop-ratio-label"
                      >{{i18n
                          "npn_critique_reply.visual_notes.crop_ratio_label"
                        }}</span>
                      {{#each this.cropRatioOptions as |option|}}
                        <button
                          type="button"
                          class="npn-critique-reply-modal__crop-ratio-button
                            {{if
                              (eq option this.cropAspectRatio)
                              'is-selected'
                            }}"
                          aria-pressed={{if
                            (eq option this.cropAspectRatio)
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on
                            "click"
                            (fn this.setCropAspectRatio option)
                          }}
                        >{{#if (eq option "free")}}{{i18n
                              "npn_critique_reply.visual_notes.crop_ratio_free"
                            }}{{else}}{{option}}{{/if}}</button>
                      {{/each}}
                    {{/if}}

                    {{! Eye-path mode actions. With multi-path support:
                        "New eye path" lets the user start another
                        path without toggling the tool off and on.
                        "Remove path" (trash) drops the currently
                        focused path (selected, or the one being
                        constructed in this session). "Remove last
                        point" trims a point from that same focused
                        path. "Clear all" wipes every eye path —
                        only shown when 2+ paths exist so it doesn't
                        duplicate the single-path remove. }}
                    {{#if this.eyePathMode}}
                      {{! Stroke / Points sub-toggle. Visible
                          whenever Eye Path is active so the user
                          can pick how the next path will be
                          captured. Existing paths keep their
                          stored mode regardless of the toggle. }}
                      <div
                        class="npn-critique-reply-modal__area-shape-toggle"
                        role="group"
                        aria-label={{i18n
                          "npn_critique_reply.visual_notes.eye_path_mode.label"
                        }}
                      >
                        <button
                          type="button"
                          class="npn-critique-reply-modal__area-shape-toggle-button
                            {{if
                              (eq this.eyePathInteractionMode 'stroke')
                              'is-selected'
                            }}"
                          aria-pressed={{if
                            (eq this.eyePathInteractionMode "stroke")
                            "true"
                            "false"
                          }}
                          title={{i18n
                            "npn_critique_reply.visual_notes.eye_path_mode.stroke_title"
                          }}
                          {{on
                            "click"
                            (fn this.setEyePathInteractionMode "stroke")
                          }}
                        >
                          {{i18n
                            "npn_critique_reply.visual_notes.eye_path_mode.stroke"
                          }}
                        </button>
                        <button
                          type="button"
                          class="npn-critique-reply-modal__area-shape-toggle-button
                            {{if
                              (eq this.eyePathInteractionMode 'points')
                              'is-selected'
                            }}"
                          aria-pressed={{if
                            (eq this.eyePathInteractionMode "points")
                            "true"
                            "false"
                          }}
                          title={{i18n
                            "npn_critique_reply.visual_notes.eye_path_mode.points_title"
                          }}
                          {{on
                            "click"
                            (fn this.setEyePathInteractionMode "points")
                          }}
                        >
                          {{i18n
                            "npn_critique_reply.visual_notes.eye_path_mode.points"
                          }}
                        </button>
                      </div>
                      {{#if this.eyePaths.length}}
                        {{#if this.focusedEyePath}}
                          {{#unless this.eyePathsAtMax}}
                            <DButton
                              class="btn-default npn-critique-reply-modal__new-eye-path"
                              @icon="plus"
                              @action={{this.startNewEyePath}}
                              @label="npn_critique_reply.visual_notes.eye_path_new"
                              @title="npn_critique_reply.visual_notes.eye_path_new_title"
                              @disabled={{this.isPosting}}
                            />
                          {{/unless}}
                          <DButton
                            class="btn-default npn-critique-reply-modal__remove-pin"
                            @icon="trash-can"
                            @action={{this.removeSelectedEyePath}}
                            @label="npn_critique_reply.visual_notes.eye_path_remove"
                            @disabled={{this.isPosting}}
                          />
                          <DButton
                            class="btn-flat npn-critique-reply-modal__clear-notes"
                            @action={{this.removeLastEyePathPoint}}
                            @label="npn_critique_reply.visual_notes.eye_path_remove_last"
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                        {{#if this.hasMultipleEyePaths}}
                          <DButton
                            class="btn-flat npn-critique-reply-modal__clear-notes"
                            @action={{this.clearEyePath}}
                            @label="npn_critique_reply.visual_notes.eye_path_clear_all"
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                      {{/if}}
                    {{/if}}

                    {{! Oval / Draw Area shape sub-toggle. Visible
                        whenever Attention or Strong Area is the
                        active tool. State is shared across both
                        tools (areaShapeMode). Default "oval"
                        matches the long-standing behaviour. }}
                    {{#if (or this.attentionPullMode this.strongAreaMode)}}
                      <div
                        class="npn-critique-reply-modal__area-shape-toggle"
                        role="group"
                        aria-label={{i18n
                          "npn_critique_reply.visual_notes.area_shape.label"
                        }}
                      >
                        <button
                          type="button"
                          class="npn-critique-reply-modal__area-shape-toggle-button
                            {{if (eq this.areaShapeMode 'path') 'is-selected'}}"
                          aria-pressed={{if
                            (eq this.areaShapeMode "path")
                            "true"
                            "false"
                          }}
                          title={{i18n
                            "npn_critique_reply.visual_notes.area_shape.draw_area_title"
                          }}
                          {{on "click" (fn this.setAreaShapeMode "path")}}
                        >
                          {{i18n
                            "npn_critique_reply.visual_notes.area_shape.draw_area"
                          }}
                        </button>
                        <button
                          type="button"
                          class="npn-critique-reply-modal__area-shape-toggle-button
                            {{if (eq this.areaShapeMode 'oval') 'is-selected'}}"
                          aria-pressed={{if
                            (eq this.areaShapeMode "oval")
                            "true"
                            "false"
                          }}
                          title={{i18n
                            "npn_critique_reply.visual_notes.area_shape.oval_title"
                          }}
                          {{on "click" (fn this.setAreaShapeMode "oval")}}
                        >
                          {{i18n
                            "npn_critique_reply.visual_notes.area_shape.oval"
                          }}
                        </button>
                      </div>
                    {{/if}}

                    {{! Attention-pull mode. }}
                    {{#if this.attentionPullMode}}
                      {{#if this.attentionPulls.length}}
                        {{#if this.selectedAttentionPull}}
                          {{#if
                            (eq this.selectedAttentionPull.shape "path")
                          }}
                            <DButton
                              class="btn-default npn-critique-reply-modal__retrace
                                {{if this.retracingAttentionPullId 'is-active'}}"
                              @icon="pencil"
                              @action={{this.toggleRetraceAttentionPull}}
                              @label={{if
                                this.retracingAttentionPullId
                                "npn_critique_reply.visual_notes.retrace.cancel"
                                "npn_critique_reply.visual_notes.retrace.button"
                              }}
                              @disabled={{this.isPosting}}
                            />
                          {{/if}}
                          <DButton
                            class="btn-default npn-critique-reply-modal__remove-pin"
                            @icon="trash-can"
                            @action={{this.removeSelectedAttentionPull}}
                            @label="npn_critique_reply.visual_notes.area_note_remove"
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearAttentionPulls}}
                          @label="npn_critique_reply.visual_notes.area_note_clear"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                    {{/if}}

                    {{! Strong-area mode. }}
                    {{#if this.strongAreaMode}}
                      {{#if this.strongAreas.length}}
                        {{#if this.selectedStrongArea}}
                          {{#if (eq this.selectedStrongArea.shape "path")}}
                            <DButton
                              class="btn-default npn-critique-reply-modal__retrace
                                {{if this.retracingStrongAreaId 'is-active'}}"
                              @icon="pencil"
                              @action={{this.toggleRetraceStrongArea}}
                              @label={{if
                                this.retracingStrongAreaId
                                "npn_critique_reply.visual_notes.retrace.cancel"
                                "npn_critique_reply.visual_notes.retrace.button"
                              }}
                              @disabled={{this.isPosting}}
                            />
                          {{/if}}
                          <DButton
                            class="btn-default npn-critique-reply-modal__remove-pin"
                            @icon="trash-can"
                            @action={{this.removeSelectedStrongArea}}
                            @label="npn_critique_reply.visual_notes.strong_area_remove"
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearStrongAreas}}
                          @label="npn_critique_reply.visual_notes.strong_area_clear"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                    {{/if}}

                    {{! Direction-arrow mode. }}
                    {{#if this.directionArrowMode}}
                      {{#if this.directionArrows.length}}
                        {{#if this.selectedDirectionArrow}}
                          <DButton
                            class="btn-default npn-critique-reply-modal__remove-pin"
                            @icon="trash-can"
                            @action={{this.removeSelectedDirectionArrow}}
                            @label="npn_critique_reply.visual_notes.direction_arrow_remove"
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearDirectionArrows}}
                          @label="npn_critique_reply.visual_notes.direction_arrow_clear"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                    {{/if}}

                    {{! Relationship-arrow mode. }}
                    {{#if this.relationshipArrowMode}}
                      {{#if this.relationshipArrows.length}}
                        {{#if this.selectedRelationshipArrow}}
                          <DButton
                            class="btn-default npn-critique-reply-modal__remove-pin"
                            @icon="trash-can"
                            @action={{this.removeSelectedRelationshipArrow}}
                            @label="npn_critique_reply.visual_notes.relationship_arrow_remove"
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearRelationshipArrows}}
                          @label="npn_critique_reply.visual_notes.relationship_arrow_clear"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                    {{/if}}
                </div>

                {{! Unified contextual help line. Lives just below the
                    secondary toolbar so it always reads as "what the
                    selected tool / sub-tool will do here." Updates
                    automatically as the user picks a tool, switches
                    sub-mode, or kicks off a retrace. aria-live=polite
                    so screen-reader users hear the change without it
                    interrupting whatever they were focused on. }}
                <p
                  class="npn-visual-tools-help"
                  role="status"
                  aria-live="polite"
                >
                  <span
                    class="npn-visual-tools-help__text"
                  >{{this.activeToolHelpText}}</span>
                </p>
                  </div>
                </div>
                {{! Closes the else branch above: toolbar + secondary
                    are the reference-view path. }}
                {{/if}}
                </section>
              {{/if}}

              {{! Visual annotation list stays available on either
                  view — annotations themselves persist while the
                  user looks at the processing example, so the
                  keyboard / screen-reader mirror keeps working. }}
              {{#if this.hasVisualAnnotations}}
                <details
                  class="npn-critique-reply-modal__a11y-list"
                  aria-label={{i18n
                    "npn_critique_reply.visual_notes.a11y_list_label"
                  }}
                >
                  <summary>{{i18n
                      "npn_critique_reply.visual_notes.a11y_list_summary"
                      count=this.annotationCount
                    }}</summary>
                  <ul class="npn-critique-reply-modal__a11y-list-items">
                    {{#each this.notes as |pin|}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.pin_label"
                            number=pin.number
                          }}{{#if pin.noteText}}
                            <span
                              class="npn-critique-reply-modal__a11y-list-note-snippet"
                            >{{i18n
                                "npn_critique_reply.visual_notes.a11y_note_snippet"
                                note=(this.snippetFor pin.noteText)
                              }}</span>
                          {{/if}}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if
                            (eq pin.number this.selectedPinNumber)
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on "click" (fn this.selectPin pin)}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on "click" (fn this.removePinByNumber pin.number)}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/each}}
                    {{#if this.crop}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.crop_a11y_label"
                          }}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if this.cropSelected "true" "false"}}
                          disabled={{this.isPosting}}
                          {{on "click" this.selectCrop}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on "click" this.clearCrop}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/if}}
                    {{#each this.eyePaths as |eyePath|}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.eye_path_a11y_label_n"
                            label=eyePath.label
                            count=eyePath.points.length
                          }}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if
                            (eq eyePath.id this.selectedEyePathId)
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on "click" (fn this.selectEyePath eyePath.id)}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on "click" (fn this.removeEyePathById eyePath.id)}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/each}}
                    {{#each this.attentionPulls as |pull|}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.area_note_a11y_label"
                            label=pull.label
                          }}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if
                            (eq pull.id this.selectedAttentionPullId)
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on "click" (fn this.selectAttentionPull pull.id)}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on
                            "click"
                            (fn this.removeAttentionPullById pull.id)
                          }}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/each}}
                    {{#each this.strongAreas as |area|}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.strong_area_a11y_label"
                            label=area.label
                          }}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if
                            (eq area.id this.selectedStrongAreaId)
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on "click" (fn this.selectStrongArea area.id)}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on
                            "click"
                            (fn this.removeStrongAreaById area.id)
                          }}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/each}}
                    {{#each this.directionArrows as |arrow|}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.direction_arrow_a11y_label"
                            label=arrow.label
                          }}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if
                            (eq arrow.id this.selectedDirectionArrowId)
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on
                            "click"
                            (fn this.selectDirectionArrow arrow.id)
                          }}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on
                            "click"
                            (fn this.removeDirectionArrowById arrow.id)
                          }}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/each}}
                    {{#each this.relationshipArrows as |arrow|}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.relationship_arrow_a11y_label"
                            label=arrow.label
                          }}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if
                            (eq arrow.id this.selectedRelationshipArrowId)
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on
                            "click"
                            (fn this.selectRelationshipArrow arrow.id)
                          }}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on
                            "click"
                            (fn this.removeRelationshipArrowById arrow.id)
                          }}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/each}}
                  </ul>
                </details>
              {{/if}}

              {{! `__version-status` removed — its content moved up
                  to the canonical __image-status-row right under the
                  image, eliminating the duplicate "Showing Original"
                  the user was seeing. }}

            </aside>

            {{! Processing Example sits inside the left pane wrapper
                so it shares the single scroll context with image-col
                rather than the writing pane. The actual section
                markup is rendered once further down (after the
                __layout closes) and moved here via SCSS… NO — we
                actually render it here. The conditional gate keeps
                it out of the DOM when not eligible. The section
                content begins below. }}
            {{#if this.processingExampleAvailable}}
              <section
                class="npn-critique-reply-modal__processing-example-row
                  npn-critique-reply-modal__processing-example
                  is-open"
                aria-labelledby="npn-critique-reply-processing-example-heading"
              >
                {{! Always-expanded section header. The disclosure
                    pattern was dropped per beta feedback — the
                    section is short enough that hiding it behind
                    "Add" / "Manage" added friction without saving
                    meaningful space. Heading + helper now read as a
                    quiet section break and the actions are always
                    one click away. }}
                <h4
                  id="npn-critique-reply-processing-example-heading"
                  class="npn-critique-reply-modal__processing-example-heading
                    npn-critique-reply-modal__optional-section-heading"
                >
                  {{i18n
                    "npn_critique_reply.modal.optional_processing_example_heading"
                  }}
                </h4>

                <div
                  id="npn-critique-reply-processing-example-content"
                  class="npn-critique-reply-modal__processing-example-content"
                >
                  {{#if this.hasProcessingExample}}
                    {{! Uploaded state: thumbnail + filename were
                        dropped per beta feedback — they weren't
                        useful. Replace / Remove live in the view-
                        toggle row above the image so they're always
                        visible without scrolling here. This section
                        just confirms the upload exists. }}
                    <p
                      class="npn-critique-reply-modal__processing-example-status-text"
                    >
                      {{i18n
                        "npn_critique_reply.modal.processing_example.uploaded"
                      }}
                    </p>
                  {{else}}
                    {{! Helper now lives inside the expanded content
                        so it surfaces only when the user opens the
                        section. Collapsed state stays minimal: just
                        heading + Add. }}
                    <p
                      class="npn-critique-reply-modal__optional-section-helper"
                    >
                      {{i18n
                        "npn_critique_reply.modal.optional_processing_example_helper"
                      }}
                    </p>
                    <div
                      class="npn-critique-reply-modal__processing-example-actions"
                    >
                      <a
                        class="btn btn-default btn-small npn-critique-reply-modal__processing-example-download"
                        href={{this.processingExampleSourceUrl}}
                        download={{this.processingExampleSourceDownloadFilename}}
                        rel="noopener"
                        target="_blank"
                      >
                        {{dIcon "download"}}
                        <span>
                          {{i18n
                            "npn_critique_reply.modal.processing_example.download"
                          }}
                        </span>
                      </a>
                      <DButton
                        class="btn-default btn-small npn-critique-reply-modal__processing-example-upload"
                        @action={{this.triggerProcessingExampleFilePicker}}
                        @icon="upload"
                        @label="npn_critique_reply.modal.processing_example.upload"
                        @disabled={{this.processingExampleUploading}}
                        @isLoading={{this.processingExampleUploading}}
                      />
                    </div>
                  {{/if}}

                  {{#if this.processingExampleError}}
                    <p
                      class="npn-critique-reply-modal__processing-example-error"
                      role="alert"
                    >
                      {{this.processingExampleError.message}}
                    </p>
                  {{/if}}

                  <input
                    id="npn-critique-reply-processing-example-input"
                    class="npn-critique-reply-modal__processing-example-input"
                    type="file"
                    accept="image/*"
                    hidden
                    {{on "change" this.onProcessingExampleFileChange}}
                  />
                </div>
              </section>
            {{/if}}

              {{! Sentinel for the IntersectionObserver. Sits at the
                  end of __left-pane's scrollable content; when it
                  intersects the pane viewport the user is at the
                  bottom and the scroll cue hides. }}
              <span
                class="npn-critique-reply-modal__pane-sentinel"
                aria-hidden="true"
                {{didInsert (fn this.setupPaneSentinel "left")}}
              ></span>
              {{#if this._leftPaneHasMore}}
                <button
                  type="button"
                  class="npn-critique-reply-modal__pane-scroll-cue"
                  aria-label={{i18n
                    "npn_critique_reply.modal.scroll_more_below"
                  }}
                  {{on "click" (fn this.scrollPaneDown "left")}}
                >
                  <span class="npn-critique-reply-modal__pane-scroll-cue-text">
                    {{i18n "npn_critique_reply.modal.scroll_more_below_label"}}
                  </span>
                  {{dIcon "chevron-down"}}
                </button>
              {{/if}}
            </div>{{! end __left-pane }}
          {{/if}}

          <div
            class="npn-critique-reply-modal__write-col"
            {{didInsert this.setupRightPane}}
          >
            <p class="npn-critique-reply-modal__intro">
              {{i18n "npn_critique_reply.modal.intro"}}
            </p>

            {{#if this.hasRequestSummary}}
              <section
                class="npn-critique-reply-modal__request"
                aria-labelledby="npn-critique-reply-request-heading"
              >
                <h3
                  id="npn-critique-reply-request-heading"
                  class="npn-critique-reply-modal__request-heading"
                >
                  {{i18n "npn_critique_reply.modal.request_heading"}}
                </h3>

                <dl class="npn-critique-reply-modal__request-list">
                  {{#if this.critiqueStyleLabel}}
                    <div class="npn-critique-reply-modal__request-row">
                      <dt>{{i18n "npn_critique_reply.modal.critique_style"}}</dt>
                      <dd><span
                          class="npn-critique-reply-modal__request-value"
                        >{{this.critiqueStyleLabel}}</span></dd>
                    </div>
                  {{/if}}
                  {{#if this.feedbackFocusLabel}}
                    <div class="npn-critique-reply-modal__request-row">
                      <dt>{{i18n "npn_critique_reply.modal.feedback_focus"}}</dt>
                      <dd><span
                          class="npn-critique-reply-modal__request-value"
                        >{{this.feedbackFocusLabel}}</span></dd>
                    </div>
                  {{/if}}
                  {{#if this.weeklyChallengeTitle}}
                    <div class="npn-critique-reply-modal__request-row">
                      <dt>{{i18n
                          "npn_critique_reply.modal.weekly_challenge"
                        }}</dt>
                      <dd><span
                          class="npn-critique-reply-modal__request-value"
                        >{{this.weeklyChallengeTitle}}</span></dd>
                    </div>
                  {{/if}}
                  {{#if this.weeklyChallengeDates}}
                    <div class="npn-critique-reply-modal__request-row">
                      <dt>{{i18n
                          "npn_critique_reply.modal.weekly_challenge_dates"
                        }}</dt>
                      <dd><span
                          class="npn-critique-reply-modal__request-value"
                        >{{this.weeklyChallengeDates}}</span></dd>
                    </div>
                  {{/if}}
                </dl>
              </section>
            {{else}}
              <p class="npn-critique-reply-modal__no-request">
                {{i18n "npn_critique_reply.modal.no_request_found"}}
              </p>
            {{/if}}

            {{! Your Critique — moved above Photographer's Notes /
                Questions to Consider so the writing surface is the
                first thing the critic reaches under the request.
                Keeps the workspace focused on the response rather
                than on the supporting material. }}
            <section class="npn-critique-reply-modal__textarea-section">
              <label
                for="npn-critique-reply-textarea"
                class="npn-critique-reply-modal__textarea-label"
              >
                {{i18n "npn_critique_reply.modal.your_critique"}}
              </label>

              {{#if this.validationMessage}}
                <p
                  class="npn-critique-reply-modal__inline-message --validation"
                  role="alert"
                >
                  {{this.validationMessage}}
                </p>
              {{/if}}
              {{#if this.errorMessage}}
                <div
                  class="npn-critique-reply-modal__inline-message --error"
                  role="alert"
                >
                  <span
                    class="npn-critique-reply-modal__inline-message-text"
                  >{{this.errorMessage}}</span>
                  {{! Fallback offered only when the failure was from the
                      visual-notes pipeline. Server validation errors don't
                      get a "post without visual notes" out, since the
                      problem isn't the export. }}
                  {{#if (eq this.visualNotesFailureContext "post")}}
                    <DButton
                      class="btn-small btn-flat npn-critique-reply-modal__fallback-action"
                      @action={{this.retryPostWithoutVisualNotes}}
                      @label="npn_critique_reply.modal.post_without_visual_notes"
                      @disabled={{this.isPosting}}
                    />
                  {{else if (eq this.visualNotesFailureContext "edit")}}
                    <DButton
                      class="btn-small btn-flat npn-critique-reply-modal__fallback-action"
                      @action={{this.retryEditWithoutVisualNotes}}
                      @label="npn_critique_reply.modal.continue_without_visual_notes"
                      @disabled={{this.isPosting}}
                    />
                  {{/if}}
                  {{! Always-on diagnostic copy button. Snapshots
                      pipeline state, browser info, server response,
                      and the last export/upload diagnostics into a
                      markdown JSON block on the clipboard. One-click
                      sharing replaces the back-and-forth of asking
                      the user to open devtools + paste console
                      output. }}
                  {{#if this._lastFailureReport}}
                    <DButton
                      class="btn-small btn-flat npn-critique-reply-modal__diagnostic-action"
                      @icon="clipboard"
                      @action={{this.copyFailureDiagnostic}}
                      @label="npn_critique_reply.modal.copy_diagnostic"
                      @title="npn_critique_reply.modal.copy_diagnostic_title"
                      @disabled={{this.isPosting}}
                    />
                  {{/if}}
                </div>
              {{/if}}
              {{#if this.statusMessage}}
                <p
                  class="npn-critique-reply-modal__inline-message --status"
                  role="status"
                  aria-live="polite"
                >
                  {{this.statusMessage}}
                </p>
              {{/if}}

              {{! Insert-link toolbar OR inline form. Both sit directly
                  above the textarea so the affordance is adjacent to
                  the field it acts on. We render one or the other —
                  never both — so the layout doesn't jump while the
                  form is open. The form is INLINE (not a sub-modal):
                  Discourse's modal service swaps the active modal
                  instead of stacking, which would dismiss the
                  critique workspace if we used DModal here. }}
              {{#if this.linkFormOpen}}
                <form
                  class="npn-critique-reply-modal__link-form"
                  aria-label={{i18n
                    "npn_critique_reply.modal.toolbar.link_modal.title"
                  }}
                  {{on "submit" this.submitLinkForm}}
                >
                  <label class="npn-critique-reply-modal__link-form-label">
                    <span>{{i18n
                        "npn_critique_reply.modal.toolbar.link_modal.url_label"
                      }}</span>
                    <input
                      class="npn-critique-reply-modal__link-form-input"
                      type="url"
                      autocomplete="off"
                      placeholder={{i18n
                        "npn_critique_reply.modal.toolbar.link_modal.url_placeholder"
                      }}
                      value={{this.linkFormUrl}}
                      {{on "input" this.updateLinkFormUrl}}
                      required
                      autofocus
                    />
                  </label>
                  <label class="npn-critique-reply-modal__link-form-label">
                    <span>{{i18n
                        "npn_critique_reply.modal.toolbar.link_modal.text_label"
                      }}</span>
                    <input
                      class="npn-critique-reply-modal__link-form-input"
                      type="text"
                      value={{this.linkFormText}}
                      {{on "input" this.updateLinkFormText}}
                    />
                  </label>
                  <div class="npn-critique-reply-modal__link-form-actions">
                    <DButton
                      @label="npn_critique_reply.modal.toolbar.link_modal.cancel"
                      @action={{this.closeLinkForm}}
                      @disabled={{this.isPosting}}
                      class="btn-flat npn-critique-reply-modal__link-form-cancel"
                    />
                    <DButton
                      @label="npn_critique_reply.modal.toolbar.link_modal.insert"
                      @action={{this.submitLinkForm}}
                      @disabled={{this.linkFormInsertDisabled}}
                      class="btn-primary npn-critique-reply-modal__link-form-submit"
                    />
                  </div>
                  <p class="npn-critique-reply-modal__link-form-note">
                    {{i18n
                      "npn_critique_reply.modal.toolbar.link_modal.markdown_note"
                    }}
                  </p>
                </form>
              {{else}}
                <div
                  class="npn-critique-reply-modal__toolbar"
                  role="toolbar"
                  aria-label={{i18n
                    "npn_critique_reply.modal.toolbar.label"
                  }}
                >
                  <span class="npn-critique-reply-modal__toolbar-hint">
                    {{i18n "npn_critique_reply.modal.markdown_supported"}}
                  </span>
                  <DButton
                    @icon="link"
                    @label="npn_critique_reply.modal.toolbar.insert_link"
                    @action={{this.openLinkForm}}
                    @disabled={{this.isPosting}}
                    class="btn-flat btn-small npn-critique-reply-modal__toolbar-button"
                  />
                </div>
              {{/if}}

              <Textarea
                id="npn-critique-reply-textarea"
                class="npn-critique-reply-modal__textarea"
                @value={{this.critiqueText}}
                placeholder={{i18n
                  "npn_critique_reply.modal.textarea_placeholder"
                }}
                disabled={{this.isPosting}}
                {{on "input" this.clearValidationOnInput}}
                {{didInsert this.setupTextarea}}
              />
            </section>

            {{! Photographer's Notes — collapsed-by-default disclosure
                showing the cooked OP content. Lazy-fetched on first
                expand via `onPhotographersNotesToggle`; cached in
                state for the rest of the session. Permissions are
                inherited from the standard /posts/:id.json endpoint
                — the user only sees content they can already see in
                the topic. }}
            <details
              class="npn-critique-reply-modal__photographers-notes"
              {{on "toggle" this.onPhotographersNotesToggle}}
            >
              <summary
                class="npn-critique-reply-modal__photographers-notes-summary"
              >
                <span
                  class="npn-critique-reply-modal__photographers-notes-title"
                >
                  {{i18n
                    "npn_critique_reply.modal.photographers_notes.title"
                  }}
                </span>
                <span
                  class="npn-critique-reply-modal__photographers-notes-hint"
                >
                  {{i18n
                    "npn_critique_reply.modal.photographers_notes.hint"
                  }}
                </span>
              </summary>
              <div
                class="npn-critique-reply-modal__photographers-notes-content"
              >
                {{#if this._opCookedLoading}}
                  <p
                    class="npn-critique-reply-modal__photographers-notes-status"
                    aria-live="polite"
                  >
                    {{i18n
                      "npn_critique_reply.modal.photographers_notes.loading"
                    }}
                  </p>
                {{else if this.opCookedSafe}}
                  <div
                    class="npn-critique-reply-modal__photographers-notes-body cooked"
                    {{didInsert this.setupPhotographersNotes}}
                  >
                    {{this.opCookedSafe}}
                  </div>
                {{else if this._opCookedError}}
                  <p
                    class="npn-critique-reply-modal__photographers-notes-status --error"
                    role="alert"
                  >
                    {{i18n
                      "npn_critique_reply.modal.photographers_notes.failed"
                    }}
                  </p>
                {{/if}}
              </div>
            </details>

            <section
              class="npn-critique-reply-modal__questions"
              aria-labelledby="npn-critique-reply-questions-heading"
            >
              <h3
                id="npn-critique-reply-questions-heading"
                class="npn-critique-reply-modal__questions-heading"
              >
                {{i18n "npn_critique_reply.modal.questions_to_consider"}}
              </h3>

              {{! Default trio — adapts to critique style + feedback
                  focus. Reads as quiet guidance: no buttons, no
                  insert affordances, just three short questions. }}
              <ul class="npn-critique-reply-modal__questions-list">
                {{#each this.defaultQuestions as |question|}}
                  <li
                    class="npn-critique-reply-modal__question-item"
                  >{{question}}</li>
                {{/each}}
              </ul>

              {{! Expandable More-ideas panel — same grouped bank
                  across every topic, with two conditional groups
                  (visual notes / project sequence). Persists open/
                  closed via localStorage + draft.ui. Still no
                  insert affordances; the panel is reference only. }}
              <button
                type="button"
                class="npn-critique-reply-modal__more-ideas-toggle"
                aria-expanded={{if this.moreIdeasExpanded "true" "false"}}
                aria-controls="npn-critique-reply-more-ideas"
                {{on "click" this.toggleMoreIdeas}}
              >
                {{#if this.moreIdeasExpanded}}
                  {{dIcon "chevron-up"}}
                  <span>{{i18n
                      "npn_critique_reply.modal.more_ideas_hide"
                    }}</span>
                {{else}}
                  {{dIcon "chevron-down"}}
                  <span>{{i18n
                      "npn_critique_reply.modal.more_ideas_show"
                    }}</span>
                {{/if}}
              </button>

              {{#if this.moreIdeasExpanded}}
                <div
                  id="npn-critique-reply-more-ideas"
                  class="npn-critique-reply-modal__more-ideas"
                >
                  {{#each this.moreIdeasGroups as |group|}}
                    <div class="npn-critique-reply-modal__prompt-group">
                      <h4
                        class="npn-critique-reply-modal__prompt-group-title"
                      >{{group.title}}</h4>
                      <ul
                        class="npn-critique-reply-modal__prompt-group-list"
                      >
                        {{#each group.prompts as |prompt|}}
                          <li
                            class="npn-critique-reply-modal__prompt-group-item"
                          >{{prompt}}</li>
                        {{/each}}
                      </ul>
                    </div>
                  {{/each}}
                </div>
              {{/if}}
            </section>

            {{! Sentinel + scroll cue for the write pane. Same shape
                as the left-pane cue — sentinel at the end of the
                scrollable content, sticky chevron when more is
                below. }}
            <span
              class="npn-critique-reply-modal__pane-sentinel"
              aria-hidden="true"
              {{didInsert (fn this.setupPaneSentinel "right")}}
            ></span>
            {{#if this._rightPaneHasMore}}
              <button
                type="button"
                class="npn-critique-reply-modal__pane-scroll-cue"
                aria-label={{i18n
                  "npn_critique_reply.modal.scroll_more_below"
                }}
                {{on "click" (fn this.scrollPaneDown "right")}}
              >
                <span class="npn-critique-reply-modal__pane-scroll-cue-text">
                  {{i18n "npn_critique_reply.modal.scroll_more_below_label"}}
                </span>
                {{dIcon "chevron-down"}}
              </button>
            {{/if}}
          </div>

        </div>

        {{! Preview Critique overlay. Rendered as a sibling to the edit
            UI rather than replacing it so the Konva stage, autocomplete,
            and other long-lived state survive a round-trip into preview
            and back. CSS gates visibility from the modal's --preview
            class (see npn-critique-reply.scss). }}
        {{#if this.previewMode}}
          <section
            class="npn-critique-reply-modal__preview"
            role="region"
            aria-labelledby="npn-critique-reply-preview-heading"
          >
            <header class="npn-critique-reply-modal__preview-header">
              <h2
                id="npn-critique-reply-preview-heading"
                class="npn-critique-reply-modal__preview-title"
                tabindex="-1"
              >Preview Critique</h2>
              <p
                class="npn-critique-reply-modal__preview-subtitle"
              >Review how your critique will appear before posting.</p>
            </header>
            <div class="npn-critique-reply-modal__preview-body">
              <section
                class="npn-critique-reply-modal__preview-section
                  npn-critique-reply-modal__preview-section--critique"
              >
                <h3
                  class="npn-critique-reply-modal__preview-section-title"
                >Critique</h3>
                {{#if this.previewHasText}}
                  <div
                    class="npn-critique-reply-modal__preview-text"
                    style="white-space: pre-wrap;"
                  >{{this._previewSnapshot.textBody}}</div>
                {{else}}
                  <p
                    class="npn-critique-reply-modal__preview-text-empty"
                  >No written critique yet.</p>
                {{/if}}
              </section>

              {{#if this._previewSnapshot.hasVisualNotes}}
                {{#each this._previewSnapshot.visualNotesImages as |img|}}
                  <section
                    class="npn-critique-reply-modal__preview-section
                      npn-critique-reply-modal__preview-section--visual-notes"
                  >
                    <h3
                      class="npn-critique-reply-modal__preview-section-title"
                    >
                      {{#if img.label}}{{img.label}}{{else}}Visual Notes{{/if}}
                    </h3>
                    <img
                      class="npn-critique-reply-modal__preview-image"
                      src={{img.objectUrl}}
                      alt="Visual notes"
                    />
                  </section>
                {{/each}}
              {{/if}}
            </div>
          </section>
        {{/if}}
      </:body>

      <:footer>
        {{! Primary action is always Post / Update — the critic can
            submit directly without a forced preview gate. In preview
            state the same button confirms; in edit state Preview is
            offered as a quieter secondary option for users who DO
            want to look first. Label changes to "Update critique"
            in edit-existing-post mode. }}
        <DButton
          class="btn-primary npn-critique-reply-modal__post"
          @action={{this.postCritique}}
          @icon="reply"
          @label={{this.postButtonLabel}}
          @disabled={{this.isPosting}}
          @isLoading={{this.isPosting}}
        />
        {{#if this.previewMode}}
          <DButton
            class="npn-critique-reply-modal__back-to-edit"
            @action={{this.exitPreview}}
            @icon="arrow-left"
            @label="npn_critique_reply.modal.preview_back_to_edit"
            @disabled={{this.isPosting}}
          />
        {{else}}
          <DButton
            class="btn-default npn-critique-reply-modal__preview-button"
            @action={{this.enterPreview}}
            @icon="eye"
            @label={{this.previewButtonLabel}}
            @title={{this.previewButtonTitle}}
            @disabled={{this.previewBuilding}}
            @isLoading={{this.previewBuilding}}
          />
        {{/if}}
        {{! The standard-composer hand-off used to live here. Beta
            feedback: even rendered as a muted text link, "Use Standard
            Composer" added confusion about whether the workspace was
            optional or how drafts moved between the two surfaces.
            Removed. The underlying editInComposer / _launchComposer
            actions stay in place because the visual-notes failure
            recovery path ("Continue without visual notes") still
            uses _doEditInComposer to bail to the composer when an
            upload fails. }}

        {{! Server-side draft status + Discard action. Quiet — sits in
            the middle of the footer alongside the primary buttons. }}
        {{#if this.draftsEnabled}}
          <span
            class="npn-critique-reply-modal__draft-status
              npn-critique-reply-modal__draft-status--{{this.draftStatus}}"
            aria-live="polite"
          >
            {{#if this.draftStatusLabel}}
              {{this.draftStatusLabel}}
            {{/if}}
          </span>
          {{#if this.showDraftDiscard}}
            <DButton
              class="btn-flat npn-critique-reply-modal__discard-draft"
              @action={{this.discardDraft}}
              @label="npn_critique_reply.modal.drafts.discard"
              @disabled={{this.isPosting}}
            />
          {{/if}}
        {{/if}}

        {{! Quiet — pushed to the far right via flex on the footer.
            Goes through `cancelOrExitFocus` so first press exits
            Visual Focus Mode rather than closing the modal — the
            X button has the same behaviour via DModal's beforeClose. }}
        <DButton
          class="btn-flat npn-critique-reply-modal__cancel"
          @action={{this.cancelOrExitFocus}}
          @label="npn_critique_reply.modal.cancel"
          @disabled={{this.isPosting}}
        />
      </:footer>
    </DModal>
  </template>
}
