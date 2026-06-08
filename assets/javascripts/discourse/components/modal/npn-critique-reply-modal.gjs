import { Textarea } from "@ember/component";
import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { ajax } from "discourse/lib/ajax";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { getURLWithCDN } from "discourse/lib/get-url";
import Composer from "discourse/models/composer";
import Draft from "discourse/models/draft";
import { and, eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import NpnCritiqueImageReference from "../npn-critique-image-reference";
import {
  critiqueStyleLabel,
  feedbackFocusLabel,
} from "../../lib/npn-critique-reply-labels";
import { buildPrompts } from "../../lib/npn-critique-reply-prompts";
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

// How many prompts the compact view shows. Tuned so a typical critic
// sees their textarea above the fold on a 13" laptop modal.
const COMPACT_PROMPT_COUNT = 3;

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

// localStorage keys for the two prompt-visibility dimensions. Stable
// strings — used by the constructor (read) and the toggle actions (write).
const STORAGE_KEY_HIDDEN = "npn-critique-reply.prompts-hidden";
const STORAGE_KEY_EXPANDED = "npn-critique-reply.prompts-expanded";

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

export default class NpnCritiqueReplyModal extends Component {
  @service siteSettings;
  @service currentUser;
  @service toasts;
  @service dialog;
  @service appEvents;

  // Draft state ----------------------------------------------------------
  @tracked critiqueText = "";

  // Post Critique state. `isPosting` disables the action buttons + close
  // path while the request is in flight; `errorMessage` is shown inline
  // above the textarea on failure so the user's draft is preserved.
  @tracked isPosting = false;
  @tracked errorMessage = null;
  // Inline validation message (shown when user clicks Post Critique with
  // empty textarea — distinct from server errors).
  @tracked validationMessage = null;
  // Async status during multi-stage flows (preparing visual notes,
  // uploading, posting). Drives a separate inline banner so the critic
  // sees progress and can tell why the modal is briefly disabled.
  @tracked statusMessage = null;

  // Version selector state. Lazy-initialized to the server's `default_key`.
  @tracked _selectedVersionKey = null;
  _selectedVersionInitialized = false;

  // Prompt panel visibility. Two independent dimensions:
  //   - `promptsHidden`   — entire Suggested Prompts section collapsed.
  //   - `promptsExpanded` — show all prompts vs the compact first 3.
  // Both are persisted to localStorage under stable keys so the modal
  // remembers the critic's preference across opens / page reloads. We
  // pull `localStorage` reads inside try/catch because some browsing
  // contexts (Safari private mode, third-party iframes) throw on access.
  @tracked promptsHidden = false;
  @tracked promptsExpanded = false;

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
  }

  constructor() {
    super(...arguments);
    // Restore prompt visibility preferences from a previous session.
    this.promptsHidden = readBool(STORAGE_KEY_HIDDEN, false);
    this.promptsExpanded = readBool(STORAGE_KEY_EXPANDED, false);

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

  // Footer primary-action label — swaps on edit / posting state.
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

  get selectedVersionKey() {
    if (!this._selectedVersionInitialized) {
      this._selectedVersionKey = this.imageVersions?.default_key ?? null;
      this._selectedVersionInitialized = true;
    }
    return this._selectedVersionKey;
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

  get effectiveImageUrl() {
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
    const v = this.selectedVersion;
    if (!v) {
      return null;
    }
    return i18n("npn_critique_reply.modal.showing_version", { label: v.label });
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

  // ---- Guided prompts --------------------------------------------------

  get prompts() {
    return buildPrompts(this.metadata);
  }

  // The compact view shows only the first N prompts so the textarea
  // remains visible above the desktop fold. `promptsExpanded` reveals
  // the rest. "Use all prompts" always operates on the full list
  // regardless of what's currently visible.
  get visiblePrompts() {
    if (this.promptsExpanded || this.prompts.length <= COMPACT_PROMPT_COUNT) {
      return this.prompts;
    }
    return this.prompts.slice(0, COMPACT_PROMPT_COUNT);
  }

  get hasMorePrompts() {
    return this.prompts.length > COMPACT_PROMPT_COUNT;
  }

  // All starters joined with paragraph breaks — used by "Use all prompts".
  // The trailing newline gives the cursor a place to land below the last
  // starter so the critic can start typing immediately.
  get formattedAllStarters() {
    return this.prompts.map((p) => p.starter).join("\n\n") + "\n";
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

  // Async path — used whenever pins OR crop exist. Exports the visual-
  // notes image (with crop overlay if present, pins on top), uploads
  // it through Discourse's standard endpoint, and composes the final
  // reply body. Throws errors tagged with a `stage` field so the
  // calling action can show a stage-specific friendly message.
  //
  // `skipVisualNotes: true` short-circuits to the text-only path so the
  // "Post / Continue without visual notes" fallback button can reuse
  // exactly the same plumbing without re-trying the failed pipeline.
  async _prepareReplyText({ skipVisualNotes = false } = {}) {
    if (skipVisualNotes || !this.hasVisualAnnotations) {
      // Text-only path — no visual upload, no annotation payload.
      return { raw: this._textOnlyRaw(), upload: null };
    }

    const url = this.effectiveImageUrl;
    if (!url) {
      throw this._wrapVisualNotesError(
        "load",
        new Error("no image url available")
      );
    }

    this.statusMessage = i18n(
      "npn_critique_reply.modal.preparing_visual_notes"
    );

    let image;
    try {
      image = await loadImageForExport(url);
    } catch (e) {
      throw this._wrapVisualNotesError("load", e);
    }

    let blob;
    try {
      const canvas = buildVisualNotesCanvas({
        image,
        pins: this.notes,
        crop: this.crop,
        eyePaths: this.eyePaths,
        attentionPulls: this.attentionPulls,
        strongAreas: this.strongAreas,
        directionArrows: this.directionArrows,
        relationshipArrows: this.relationshipArrows,
      });
      blob = await exportCanvasToBlob(canvas);
    } catch (e) {
      throw this._wrapVisualNotesError("export", e);
    }

    this.statusMessage = i18n(
      "npn_critique_reply.modal.uploading_visual_notes"
    );

    let upload;
    try {
      upload = await uploadVisualNotesBlob(blob, this._visualNotesFilename());
    } catch (e) {
      throw this._wrapVisualNotesError("upload", e);
    }

    // Caller (Post Critique) needs the upload reference to build the
    // structured visual-notes metadata persisted on the created post
    // — the markdown alone is enough for Edit-in-Composer.
    return { raw: this._composeVisualNotesRaw(upload), upload };
  }

  // Compose: heading (already names the version, so we DON'T also emit
  // "Regarding Revision N:") + image markdown + textarea body.
  _composeVisualNotesRaw(upload) {
    const text = this.critiqueText.trim();
    const heading = this._visualNotesHeading();
    const altText = i18n("npn_critique_reply.modal.visual_notes_alt");
    const shortUrl = upload?.short_url ?? upload?.url ?? "";
    const imageMarkdown = `![${altText}](${shortUrl})`;

    return text
      ? `${heading}\n\n${imageMarkdown}\n\n${text}`
      : `${heading}\n\n${imageMarkdown}`;
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

  _visualNotesErrorMessage(stage) {
    return (
      {
        load: i18n("npn_critique_reply.modal.visual_notes_load_failed"),
        export: i18n("npn_critique_reply.modal.visual_notes_export_failed"),
        upload: i18n("npn_critique_reply.modal.visual_notes_upload_failed"),
      }[stage] ?? i18n("npn_critique_reply.modal.visual_notes_generic_failure")
    );
  }

  // ---- Actions ---------------------------------------------------------

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
    this._selectedVersionInitialized = true;
    // Always reset annotations — they're tied to the previous image's
    // pixel layout. The textarea (including [N] lines and any starter
    // text from the crop or eye-path tools) is intentionally left
    // alone per spec.
    this.notes = [];
    this.crop = null;
    this.eyePaths = [];
    this._activeEyePathId = null;
    this._eyePathStarterInserted = false;
    this.attentionPulls = [];
    this.strongAreas = [];
    this.directionArrows = [];
    this.relationshipArrows = [];
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
    // Eye-path session tracking. Each entry into eye_path mode is
    // one path session: the first click creates a new path (up to
    // the per-critique cap) and subsequent clicks extend it. Leaving
    // the mode finalises the path. Re-entering eye_path mode starts
    // a fresh session by clearing the active-path pointer so the
    // next click creates another path instead of appending to the
    // previous one. `_eyePathStarterInserted` resets too so each
    // session can trigger its own description popover at point 2.
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
    this.crop = {
      id: "crop_1",
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

  // Fired by the Konva stage on a click while in eye_path mode. The
  // first click of a mode-entry session creates a NEW path (subject
  // to the per-critique cap); subsequent clicks within the same
  // session append points to that path. Re-entering eye_path mode
  // resets the session so the next click creates another new path
  // rather than extending the previous one.
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
      const newId = nextEyePathId(this.eyePaths.map((p) => p.id));
      const newLabel = nextEyePathLabel(this.eyePaths.map((p) => p.label));
      activePath = {
        id: newId,
        label: newLabel,
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
    const label = nextAttentionPullLabel(
      this.attentionPulls.map((p) => p.label)
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
        "npn_critique_reply.visual_notes.attention_pull_line_template",
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
    const label = nextStrongAreaLabel(this.strongAreas.map((p) => p.label));
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
      this.directionArrows.map((a) => a.label)
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
      this.relationshipArrows.map((a) => a.label)
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
  }

  @action
  skipPendingEyePathPopover() {
    this.pendingEyePathPopover = null;
    this.pendingEyePathPopoverText = "";
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
    if (text) {
      const line = i18n(
        "npn_critique_reply.visual_notes.crop_line_template",
        { text }
      );
      this._appendToTextarea(line);
    } else {
      // No description typed → still drop the bare token so the
      // cooked post gets the styled [CROP] pill. The user can fill
      // in the surrounding prose later.
      this._appendToTextarea(
        i18n("npn_critique_reply.visual_notes.crop_starter")
      );
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
    const nextNumber = (this.notes[this.notes.length - 1]?.number ?? 0) + 1;
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

  @action
  insertPrompt(prompt) {
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] insert-prompt", {
        topicId: this.topic?.id,
        question: prompt?.question,
      });
    }
    if (!prompt?.starter) {
      return;
    }
    this._appendToTextarea(prompt.starter);
  }

  @action
  useAllPrompts() {
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] use-all-prompts", {
        topicId: this.topic?.id,
        promptCount: this.prompts.length,
      });
    }
    this._appendToTextarea(this.formattedAllStarters);
  }

  @action
  togglePrompts() {
    this.promptsHidden = !this.promptsHidden;
    writeBool(STORAGE_KEY_HIDDEN, this.promptsHidden);
  }

  @action
  toggleExpand() {
    this.promptsExpanded = !this.promptsExpanded;
    writeBool(STORAGE_KEY_EXPANDED, this.promptsExpanded);
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
      const { raw, upload } = await this._prepareReplyText({
        skipVisualNotes,
      });
      if (this._destroyed) {
        return;
      }

      this.statusMessage = i18n("npn_critique_reply.modal.posting_critique");

      // Structured visual-annotation metadata is sent ONLY when the
      // visual export + upload pipeline succeeded AND the user has
      // annotations. Text-only critiques, Post-without-visual-notes
      // fallback, and Edit-in-Composer all skip this — the server
      // stores the payload as a `npn_visual_notes` post custom field
      // on the just-created reply for future overlay / reopen use.
      const visualNotes =
        upload && this.hasVisualAnnotations
          ? buildVisualAnnotationPayload({
              topic: this.topic,
              selectedVersion: this.selectedVersion,
              visualUpload: upload,
              pins: this.notes,
              crop: this.crop,
              eyePaths: this.eyePaths,
              attentionPulls: this.attentionPulls,
              strongAreas: this.strongAreas,
              directionArrows: this.directionArrows,
              relationshipArrows: this.relationshipArrows,
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
            visualNotes
          )
        : await postCritiqueRequest(topicId, raw, selectedKey, visualNotes);
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
        this.errorMessage = this._visualNotesErrorMessage(error.stage);
        this.visualNotesFailureContext = "post";
      } else {
        // Server validation, rate limit, etc. — no fallback button.
        this.errorMessage = this._extractErrorMessage(error);
        this.visualNotesFailureContext = null;
      }

      if (this.siteSettings.npn_critique_reply_debug_enabled) {
        // eslint-disable-next-line no-console
        console.warn("[npn-critique-reply] post-critique failed", {
          topicId,
          stage: error?.stage,
          error,
          message: this.errorMessage,
          fallbackAvailable: this.visualNotesFailureContext === "post",
        });
      }
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

  @action
  async editInComposer() {
    return this._doEditInComposer({ skipVisualNotes: false });
  }

  @action
  async retryEditWithoutVisualNotes() {
    return this._doEditInComposer({ skipVisualNotes: true });
  }

  async _doEditInComposer({ skipVisualNotes }) {
    const hasVisual = !skipVisualNotes && this.hasVisualAnnotations;
    if (!this.hasUnsavedText && !hasVisual) {
      this._launchComposer({ replyText: null });
      return;
    }

    this.errorMessage = null;
    this.validationMessage = null;
    this.visualNotesFailureContext = null;
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
        this.errorMessage = this._visualNotesErrorMessage(error.stage);
        this.visualNotesFailureContext = "edit";
      } else {
        this.errorMessage = this._extractErrorMessage(error);
        this.visualNotesFailureContext = null;
      }

      if (this.siteSettings.npn_critique_reply_debug_enabled) {
        // eslint-disable-next-line no-console
        console.warn("[npn-critique-reply] edit-in-composer failed", {
          topicId: this.topic?.id,
          stage: error?.stage,
          error,
          message: this.errorMessage,
          fallbackAvailable: this.visualNotesFailureContext === "edit",
        });
      }
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

    // Edit in Composer transfers the critique into the composer →
    // the saved draft has done its job; clear it. Reply Normally has
    // no replyText and intentionally keeps the workspace draft.
    if (replyText) {
      this._clearDraftAfterSuccess();
    } else {
      // Reply Normally: cancel pending autosave but DON'T delete —
      // the user explicitly asked to escape to the normal composer
      // without losing the workspace draft.
      this._autosaver?.cancel?.();
    }

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

  // ---- Reply Normally --------------------------------------------------

  @action
  replyNormally() {
    if (this.hasUnsavedText) {
      this.dialog.confirm({
        message: i18n("npn_critique_reply.modal.confirm_reply_normally"),
        confirmButtonLabel: "npn_critique_reply.modal.reply_normally",
        didConfirm: () => this._launchComposer({ replyText: null }),
      });
      return;
    }
    this._launchComposer({ replyText: null });
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
      this.promptsHidden ? 1 : 0,
      this.promptsExpanded ? 1 : 0,
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
    } catch (_e) {
      // Restore failures are non-fatal — the modal still opens, the
      // user can type, and the next autosave will overwrite whatever
      // was there before. We deliberately do NOT surface a banner.
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
    const annotations = pinsToAnnotations(this.notes ?? []);
    if (this.crop) {
      const cropAnnotation = cropToAnnotation(this.crop);
      if (cropAnnotation) {
        annotations.push(cropAnnotation);
      }
    }
    for (const eyePathAnnotation of eyePathsToAnnotations(this.eyePaths ?? [])) {
      annotations.push(eyePathAnnotation);
    }
    for (const pull of attentionPullsToAnnotations(this.attentionPulls ?? [])) {
      annotations.push(pull);
    }
    for (const area of strongAreasToAnnotations(this.strongAreas ?? [])) {
      annotations.push(area);
    }
    for (const arrow of directionArrowsToAnnotations(
      this.directionArrows ?? []
    )) {
      annotations.push(arrow);
    }
    for (const arrow of relationshipArrowsToAnnotations(
      this.relationshipArrows ?? []
    )) {
      annotations.push(arrow);
    }
    const payload = {
      schema_version: 1,
      selected_image_version_key: this.selectedVersionKey ?? null,
      critique_text: this.critiqueText ?? "",
      annotations,
      ui: {
        prompts_hidden: !!this.promptsHidden,
        prompts_expanded: !!this.promptsExpanded,
      },
    };
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] draft-build-payload", {
        textLength: payload.critique_text.length,
        annotationCount: payload.annotations.length,
        kinds: payload.annotations.map((a) => a.kind),
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
        this._selectedVersionInitialized = true;
      }
      this._restoreAnnotations(payload.annotations, versionKey);
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
      // Soft failure — leave the textarea empty. Surface via the
      // debug log so QA can spot it; we deliberately don't throw a
      // modal banner because the user can still type new content.
      if (this.siteSettings.npn_critique_reply_debug_enabled) {
        // eslint-disable-next-line no-console
        console.warn(
          "[npn-critique-reply] failed to load post raw for edit",
          { postId: post.id, error: e }
        );
      }
    }
  }

  // Helper for `_initializeFromPost`. Looks for the visual-notes
  // image markdown line and returns everything after it. If the post
  // doesn't have a visual-notes image (text-only critique that's
  // somehow being reopened), or if the format has drifted, returns
  // the raw unchanged so the user can hand-fix it.
  _parseCritiqueTextFromRaw(raw) {
    if (!raw) {
      return "";
    }
    // The image markdown is `![alt](upload://...)`. Match on the
    // first occurrence of an upload-scheme image link.
    const match = raw.match(/^!\[[^\]]*\]\(upload:\/\/[^\s)]+\)\s*$/m);
    if (!match) {
      return raw;
    }
    const afterImageIdx = (match.index ?? 0) + match[0].length;
    return raw.slice(afterImageIdx).replace(/^\s+/, "");
  }

  // `_restoringDraft` first so the didUpdate autosave hook ignores
  // the burst of setter calls — we don't want to immediately PUT
  // back the same payload we just GET'd.
  _restoreDraft(draft) {
    this._restoringDraft = true;

    try {
      this.critiqueText = draft.critique_text ?? "";

      const versionKey = draft.selected_image_version_key ?? null;
      const versionStillExists = versionKey
        ? this.versions.some((v) => v.key === versionKey)
        : true;

      if (!versionKey || versionStillExists) {
        // Apply the saved version selection (or leave the current one
        // alone for a "no version specified" draft).
        if (versionKey) {
          this._selectedVersionKey = versionKey;
          this._selectedVersionInitialized = true;
        }
        this._restoreAnnotations(draft.annotations, draft.selected_image_version_key);

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
        if (typeof draft.ui.prompts_hidden === "boolean") {
          this.promptsHidden = draft.ui.prompts_hidden;
        }
        if (typeof draft.ui.prompts_expanded === "boolean") {
          this.promptsExpanded = draft.ui.prompts_expanded;
        }
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
    const list = Array.isArray(annotations) ? annotations : [];
    const synthPayload = {
      source: { image_version_key: versionKey ?? null },
      annotations: list,
    };

    const pins = annotationsToPins(synthPayload);
    this.notes = pins.map((p) => ({
      number: p.number,
      xPct: p.xPct,
      yPct: p.yPct,
      note: p.note ?? null,
    }));

    // The crop converter takes a SINGLE annotation; pluck the first
    // matching entry. Eye paths support multiple — convert ALL
    // matching entries and keep them as an array.
    const cropEntry = list.find((a) => a?.kind === "crop");
    this.crop = cropEntry ? annotationToCrop(cropEntry) : null;
    if (this.crop?.aspectRatio) {
      this.cropAspectRatio = this.crop.aspectRatio;
    }
    // Match the auto-select-on-placement behaviour of addCrop so the
    // restored crop is immediately interactive (Transformer mounts,
    // drag works in one motion). Multi-instance shapes (pins,
    // attention pulls, strong areas, eye paths) intentionally do not
    // auto-select on restore — picking one would be arbitrary, and
    // the konva stage's canDrag gate already allows single-motion
    // drag for any marker in the right tool mode.
    this.cropSelected = !!this.crop;
    const eyePathEntries = list.filter((a) => a?.kind === "eye_path");
    this.eyePaths = eyePathEntries
      .map((entry) => annotationToEyePath(entry))
      .filter((p) => p && (p.points?.length ?? 0) > 0);
    this.selectedEyePathId = null;
    this._activeEyePathId = null;

    this.attentionPulls = annotationsToAttentionPulls(synthPayload);
    this.strongAreas = annotationsToStrongAreas(synthPayload);
    this.directionArrows = annotationsToDirectionArrows(synthPayload);
    this.relationshipArrows = annotationsToRelationshipArrows(synthPayload);
    this.selectedDirectionArrowId = null;
    this.selectedRelationshipArrowId = null;

    // Bump id counters past any restored ids so newly-created
    // markers don't collide.
    this._attentionPullIdCounter = this.attentionPulls.reduce(
      (max, p) => Math.max(max, extractIdSuffix(p.id) ?? 0),
      this._attentionPullIdCounter ?? 0
    );
    this._strongAreaIdCounter = this.strongAreas.reduce(
      (max, s) => Math.max(max, extractIdSuffix(s.id) ?? 0),
      this._strongAreaIdCounter ?? 0
    );
    this._directionArrowIdCounter = this.directionArrows.reduce(
      (max, a) => Math.max(max, extractIdSuffix(a.id) ?? 0),
      this._directionArrowIdCounter ?? 0
    );
    this._relationshipArrowIdCounter = this.relationshipArrows.reduce(
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
      class="npn-critique-reply-modal --workspace
        {{unless this.hasImage 'npn-critique-reply-modal--no-image'}}"
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
          {{#if this.hasImage}}
            <aside
              class="npn-critique-reply-modal__image-col"
              aria-labelledby="npn-critique-reply-image-heading"
            >
              <h3
                id="npn-critique-reply-image-heading"
                class="npn-critique-reply-modal__image-heading"
              >
                {{i18n "npn_critique_reply.modal.reference_image"}}
              </h3>

              {{#if this.hasMultipleVersions}}
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

              {{! Toolbar moved ABOVE the image so it's visible without
                  scrolling. The image's sticky positioning + max-height
                  could push the controls below the fold otherwise. }}
              {{#if this.visualNotesAvailable}}
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
                    @disabled={{this.isPosting}}
                  />
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
                      "highlighter"
                    }}
                    @label={{if
                      this.attentionPullMode
                      "npn_critique_reply.visual_notes.attention_pull_done"
                      "npn_critique_reply.visual_notes.attention_pull"
                    }}
                    @disabled={{this.isPosting}}
                  />
                  <DButton
                    class={{if
                      this.strongAreaMode
                      "btn-primary"
                      "btn-default"
                    }}
                    @action={{this.toggleStrongAreaMode}}
                    @icon={{if
                      this.strongAreaMode
                      "check"
                      "circle-check"
                    }}
                    @label={{if
                      this.strongAreaMode
                      "npn_critique_reply.visual_notes.strong_area_done"
                      "npn_critique_reply.visual_notes.strong_area"
                    }}
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
                      {{else}}
                        <p
                          class="npn-critique-reply-modal__tool-hint"
                          aria-live="polite"
                        >{{i18n "npn_critique_reply.visual_notes.hint"}}</p>
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
                      {{else}}
                        <p
                          class="npn-critique-reply-modal__tool-hint"
                          aria-live="polite"
                        >{{i18n "npn_critique_reply.visual_notes.eye_path_hint"}}</p>
                      {{/if}}
                    {{/if}}

                    {{! Attention-pull mode. }}
                    {{#if this.attentionPullMode}}
                      {{#if this.attentionPulls.length}}
                        {{#if this.selectedAttentionPull}}
                          <DButton
                            class="btn-default npn-critique-reply-modal__remove-pin"
                            @icon="trash-can"
                            @action={{this.removeSelectedAttentionPull}}
                            @label="npn_critique_reply.visual_notes.attention_pull_remove"
                            @disabled={{this.isPosting}}
                          />
                        {{/if}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearAttentionPulls}}
                          @label="npn_critique_reply.visual_notes.attention_pull_clear"
                          @disabled={{this.isPosting}}
                        />
                      {{else}}
                        <p
                          class="npn-critique-reply-modal__tool-hint"
                          aria-live="polite"
                        >{{i18n
                            "npn_critique_reply.visual_notes.attention_pull_hint"
                          }}</p>
                      {{/if}}
                    {{/if}}

                    {{! Strong-area mode. }}
                    {{#if this.strongAreaMode}}
                      {{#if this.strongAreas.length}}
                        {{#if this.selectedStrongArea}}
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
                      {{else}}
                        <p
                          class="npn-critique-reply-modal__tool-hint"
                          aria-live="polite"
                        >{{i18n
                            "npn_critique_reply.visual_notes.strong_area_hint"
                          }}</p>
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
                      {{else}}
                        <p
                          class="npn-critique-reply-modal__tool-hint"
                          aria-live="polite"
                        >{{i18n
                            "npn_critique_reply.visual_notes.direction_arrow_hint"
                          }}</p>
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
                      {{else}}
                        <p
                          class="npn-critique-reply-modal__tool-hint"
                          aria-live="polite"
                        >{{i18n
                            "npn_critique_reply.visual_notes.relationship_arrow_hint"
                          }}</p>
                      {{/if}}
                    {{/if}}
                </div>
              {{/if}}

              <NpnCritiqueImageReference
                @imageUrl={{this.effectiveImageUrl}}
                @alt={{this.imageAlt}}
                @pins={{this.notes}}
                @crop={{this.crop}}
                @visualMode={{this.visualMode}}
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
                @onSelectEyePath={{this.selectEyePath}}
                @onMoveEyePathPoint={{this.moveEyePathPoint}}
                @attentionPulls={{this.attentionPulls}}
                @selectedAttentionPullId={{this.selectedAttentionPullId}}
                @attentionPullEditEnabled={{this.attentionPullEditEnabled}}
                @onAddAttentionPull={{this.addAttentionPull}}
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
                @onAddStrongArea={{this.addStrongArea}}
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
                            "npn_critique_reply.visual_notes.attention_pull_a11y_label"
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

              {{#if this.showingVersionLabel}}
                <p
                  class="npn-critique-reply-modal__version-status"
                  aria-live="polite"
                >
                  {{this.showingVersionLabel}}
                  {{#if this.revisionNote}}
                    —
                    <span class="npn-critique-reply-modal__version-note">
                      {{i18n
                        "npn_critique_reply.modal.revision_note"
                        note=this.revisionNote
                      }}
                    </span>
                  {{/if}}
                </p>
              {{/if}}
            </aside>
          {{/if}}

          <div class="npn-critique-reply-modal__write-col">
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
                      <dd>{{this.critiqueStyleLabel}}</dd>
                    </div>
                  {{/if}}
                  {{#if this.feedbackFocusLabel}}
                    <div class="npn-critique-reply-modal__request-row">
                      <dt>{{i18n "npn_critique_reply.modal.feedback_focus"}}</dt>
                      <dd>{{this.feedbackFocusLabel}}</dd>
                    </div>
                  {{/if}}
                  {{#if this.weeklyChallengeTitle}}
                    <div class="npn-critique-reply-modal__request-row">
                      <dt>{{i18n
                          "npn_critique_reply.modal.weekly_challenge"
                        }}</dt>
                      <dd>{{this.weeklyChallengeTitle}}</dd>
                    </div>
                  {{/if}}
                  {{#if this.weeklyChallengeDates}}
                    <div class="npn-critique-reply-modal__request-row">
                      <dt>{{i18n
                          "npn_critique_reply.modal.weekly_challenge_dates"
                        }}</dt>
                      <dd>{{this.weeklyChallengeDates}}</dd>
                    </div>
                  {{/if}}
                </dl>
              </section>
            {{else}}
              <p class="npn-critique-reply-modal__no-request">
                {{i18n "npn_critique_reply.modal.no_request_found"}}
              </p>
            {{/if}}

            <section
              class="npn-critique-reply-modal__prompts"
              aria-labelledby="npn-critique-reply-prompts-heading"
            >
              <div class="npn-critique-reply-modal__prompts-header">
                <h3
                  id="npn-critique-reply-prompts-heading"
                  class="npn-critique-reply-modal__prompts-heading"
                >
                  {{i18n "npn_critique_reply.modal.suggested_prompts"}}
                </h3>
                <button
                  type="button"
                  class="npn-critique-reply-modal__prompts-toggle"
                  aria-expanded={{if this.promptsHidden "false" "true"}}
                  aria-controls="npn-critique-reply-prompts-body"
                  {{on "click" this.togglePrompts}}
                >
                  {{#if this.promptsHidden}}
                    {{dIcon "eye"}}
                    <span>{{i18n
                        "npn_critique_reply.modal.show_prompts"
                      }}</span>
                  {{else}}
                    {{dIcon "eye-slash"}}
                    <span>{{i18n
                        "npn_critique_reply.modal.hide_prompts"
                      }}</span>
                  {{/if}}
                </button>
              </div>

              {{#unless this.promptsHidden}}
                <div id="npn-critique-reply-prompts-body">
                  <ul class="npn-critique-reply-modal__prompts-list">
                    {{#each this.visiblePrompts as |prompt|}}
                      <li class="npn-critique-reply-modal__prompt-item">
                        <span
                          class="npn-critique-reply-modal__prompt-question"
                        >{{prompt.question}}</span>
                        <button
                          type="button"
                          class="npn-critique-reply-modal__prompt-insert"
                          aria-label={{i18n
                            "npn_critique_reply.modal.insert_prompt_aria"
                            question=prompt.question
                          }}
                          title={{i18n
                            "npn_critique_reply.modal.insert_prompt_title"
                          }}
                          disabled={{this.isPosting}}
                          {{on "click" (fn this.insertPrompt prompt)}}
                        >
                          {{dIcon "plus"}}
                        </button>
                      </li>
                    {{/each}}
                  </ul>

                  {{#if this.hasMorePrompts}}
                    <button
                      type="button"
                      class="npn-critique-reply-modal__prompts-expand"
                      aria-expanded={{if this.promptsExpanded "true" "false"}}
                      {{on "click" this.toggleExpand}}
                    >
                      {{#if this.promptsExpanded}}
                        {{dIcon "chevron-up"}}
                        <span>{{i18n
                            "npn_critique_reply.modal.show_fewer_prompts"
                          }}</span>
                      {{else}}
                        {{dIcon "chevron-down"}}
                        <span>{{i18n
                            "npn_critique_reply.modal.show_all_prompts"
                          }}</span>
                      {{/if}}
                    </button>
                  {{/if}}

                  <DButton
                    class="btn-small btn-default npn-critique-reply-modal__use-prompts"
                    @action={{this.useAllPrompts}}
                    @icon="far-pen-to-square"
                    @label="npn_critique_reply.modal.use_all_prompts"
                    @disabled={{this.isPosting}}
                  />
                </div>
              {{/unless}}
            </section>

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

              <Textarea
                id="npn-critique-reply-textarea"
                class="npn-critique-reply-modal__textarea"
                @value={{this.critiqueText}}
                placeholder={{i18n
                  "npn_critique_reply.modal.textarea_placeholder"
                }}
                disabled={{this.isPosting}}
                {{on "input" this.clearValidationOnInput}}
              />
            </section>
          </div>
        </div>
      </:body>

      <:footer>
        {{! Primary action — POST in new-critique mode, PUT in edit
            mode. Label changes to "Update critique" while editing. }}
        <DButton
          class="btn-primary npn-critique-reply-modal__post"
          @action={{this.postCritique}}
          @icon="reply"
          @label={{this.postButtonLabel}}
          @disabled={{this.isPosting}}
          @isLoading={{this.isPosting}}
        />
        {{! Secondary actions only apply to the new-critique flow.
            Edit mode posts straight back to the same reply, so the
            "transfer to composer" / "open a clean reply" escape
            hatches don't have a sensible analogue. }}
        {{#unless this.isEditing}}
          <DButton
            class="npn-critique-reply-modal__edit-composer"
            @action={{this.editInComposer}}
            @icon="far-pen-to-square"
            @label="npn_critique_reply.modal.edit_in_composer"
            @disabled={{this.isPosting}}
          />
          <DButton
            class="btn-default npn-critique-reply-modal__reply-normally"
            @action={{this.replyNormally}}
            @label="npn_critique_reply.modal.reply_normally"
            @disabled={{this.isPosting}}
          />
        {{/unless}}

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

        {{! Quiet — pushed to the far right via flex on the footer. }}
        <DButton
          class="btn-flat npn-critique-reply-modal__cancel"
          @action={{@closeModal}}
          @label="npn_critique_reply.modal.cancel"
          @disabled={{this.isPosting}}
        />
      </:footer>
    </DModal>
  </template>
}
