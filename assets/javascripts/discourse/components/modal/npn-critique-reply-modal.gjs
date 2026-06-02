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
import { postCritique as postCritiqueRequest } from "../../lib/npn-critique-reply-api";
import {
  buildVisualNotesCanvas,
  exportCanvasToBlob,
  loadImageForExport,
  uploadVisualNotesBlob,
} from "../../lib/npn-critique-reply-visual-notes";
import {
  MAX_ATTENTION_PULL_COUNT,
  MAX_EYE_PATH_POINTS,
  MAX_STRONG_AREA_COUNT,
  annotationsToAttentionPulls,
  annotationsToPins,
  annotationsToStrongAreas,
  annotationToCrop,
  annotationToEyePath,
  attentionPullsToAnnotations,
  buildVisualAnnotationPayload,
  cropToAnnotation,
  eyePathToAnnotation,
  nextAttentionPullLabel,
  nextStrongAreaLabel,
  pinsToAnnotations,
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
  //   _cropStarterInserted — true after we've appended the textarea
  //                         starter line once; prevents re-inserting
  //                         it on Replace crop.
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
  _cropStarterInserted = false;

  // Eye-path / Visual Flow tool state. `eyePath` is null when no path
  // exists, otherwise `{ id, points: [{ number, xPct, yPct }] }`.
  // `eyePathSelected` mirrors the pin/crop selection pattern — when
  // true, the toolbar shows path-specific Remove/Clear actions and
  // the stage renders the path's points with a brighter fill.
  @tracked eyePath = null;
  @tracked eyePathSelected = false;
  // Track that the second-point textarea starter has already been
  // inserted. Avoids re-inserting on every subsequent click.
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

    // Kick off the server-draft restore + autosaver setup. Async, so
    // the modal renders an empty workspace first and fills it in once
    // the GET resolves (or stays empty if there's no draft).
    this._initializeDraftSync();
  }

  get metadata() {
    return this.args.model?.metadata ?? null;
  }

  get topic() {
    return this.args.model?.topic ?? null;
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
      this.strongAreas.length > 0
    );
  }

  get annotationCount() {
    return (
      this.notes.length +
      (this.crop ? 1 : 0) +
      (this.hasEyePath ? 1 : 0) +
      this.attentionPulls.length +
      this.strongAreas.length
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

  // True only when the eye_path has at least one valid point. The
  // tracked property may be null OR an empty-points object during the
  // brief window between user-initiated clear and the next render —
  // treat both as "no path" everywhere.
  get hasEyePath() {
    return !!this.eyePath && (this.eyePath.points?.length ?? 0) > 0;
  }

  get eyePathPointCount() {
    return this.eyePath?.points?.length ?? 0;
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
        eyePath: this.eyePath,
        attentionPulls: this.attentionPulls,
        strongAreas: this.strongAreas,
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
    this.eyePath = null;
    this.attentionPulls = [];
    this.strongAreas = [];
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.eyePathSelected = false;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.visualMode = null;
    this.pendingPin = null;
    this.pendingPinNoteText = "";
    this.pendingAttentionPullPopover = null;
    this.pendingAttentionPullPopoverText = "";
    this.pendingStrongAreaPopover = null;
    this.pendingStrongAreaPopoverText = "";
    this.pendingEyePathPopover = null;
    this.pendingEyePathPopoverText = "";
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
    this.visualMode = mode;
    // Switching modes drops any active selection so toolbar context
    // stays in sync with the chosen tool. Existing annotations of all
    // kinds are preserved — only the selection state resets.
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.eyePathSelected = false;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
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
    this.eyePathSelected = false;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
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

    // Insert the starter text once per modal session. Replacing crop
    // (clear + redraw) does NOT re-insert.
    if (!this._cropStarterInserted) {
      const starter = i18n("npn_critique_reply.visual_notes.crop_starter");
      this._appendToTextarea(starter);
      this._cropStarterInserted = true;
    }

    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] add-crop", {
        topicId: this.topic?.id,
        crop: this.crop,
        starterInsertedThisSession: this._cropStarterInserted,
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
    this.eyePathSelected = false;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
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

  // Fired by the Konva stage on a click while in eye_path mode. Appends
  // a numbered point to the path (creating the path on the first
  // click). On the second point we insert a textarea starter once per
  // session so the critic has scaffolding to describe their visual
  // flow.
  @action
  addEyePathPoint(xPct, yPct) {
    if (this.visualMode !== "eye_path") {
      return;
    }
    const currentPoints = this.eyePath?.points ?? [];
    if (currentPoints.length >= MAX_EYE_PATH_POINTS) {
      return;
    }
    const nextNumber = currentPoints.length + 1;
    const newPoints = [
      ...currentPoints,
      { number: nextNumber, xPct, yPct },
    ];
    const label = this.eyePath?.label ?? "E1";
    this.eyePath = {
      id: this.eyePath?.id ?? "eye_path_1",
      label,
      points: newPoints,
    };
    // Path becomes "meaningful" at the second point — open the inline
    // note popover anchored to the latest point. No filler starter
    // inserted into the textarea; the popover's Add note writes
    // "[E1] <user text>", and Skip leaves the textarea alone.
    // The `_eyePathStarterInserted` flag keeps the popover from
    // re-opening on every subsequent point — one description prompt
    // per path session.
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
        number: nextNumber,
        xPct,
        yPct,
        starterInsertedThisSession: this._eyePathStarterInserted,
      });
    }
  }

  // Fired by the Konva stage on per-point dragend. Updates the
  // matching point's coords without changing its number. The stage
  // updates its own closure-cached eye_path BEFORE invoking this
  // callback, so the next sync sees identical values and skips a
  // redundant re-render.
  @action
  moveEyePathPoint(number, xPct, yPct) {
    if (number == null || !this.eyePath?.points) {
      return;
    }
    this.eyePath = {
      ...this.eyePath,
      points: this.eyePath.points.map((p) =>
        p.number === number ? { ...p, xPct, yPct } : p
      ),
    };
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] move-eye-path-point", {
        topicId: this.topic?.id,
        number,
        xPct,
        yPct,
      });
    }
  }

  @action
  removeLastEyePathPoint() {
    const current = this.eyePath?.points ?? [];
    if (current.length === 0) {
      return;
    }
    const next = current.slice(0, -1);
    if (next.length === 0) {
      // Last point removed → drop the path entirely so downstream
      // checks (hasEyePath, export) see a clean null.
      this.eyePath = null;
      this.eyePathSelected = false;
      this.pendingEyePathPopover = null;
      this.pendingEyePathPopoverText = "";
    } else {
      this.eyePath = {
        ...this.eyePath,
        points: next,
      };
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] remove-last-eye-path-point", {
        topicId: this.topic?.id,
        remaining: next.length,
      });
    }
  }

  @action
  selectEyePath() {
    if (!this.hasEyePath) {
      return;
    }
    // Clicking a shape activates the corresponding tool mode (see
    // selectPin for rationale).
    this._setVisualMode("eye_path");
    // Mirror the pin/crop mutex — only one annotation reads as the
    // toolbar's active selection at a time.
    this.selectedPinNumber = null;
    this.cropSelected = false;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
    this.eyePathSelected = !this.eyePathSelected;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] select-eye-path", {
        topicId: this.topic?.id,
        selected: this.eyePathSelected,
      });
    }
  }

  @action
  clearEyePath() {
    if (!this.eyePath) {
      return;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] clear-eye-path", {
        topicId: this.topic?.id,
      });
    }
    this.eyePath = null;
    this.eyePathSelected = false;
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
    this.eyePathSelected = false;

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
    this.eyePathSelected = false;
    this.selectedStrongAreaId = null;
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
    this.eyePathSelected = false;
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
    this.eyePathSelected = false;
    this.selectedAttentionPullId = null;
    if (this.selectedStrongAreaId === id) {
      this.selectedStrongAreaId = null;
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
    const label = this.eyePath?.label ?? "E1";
    if (text) {
      // Append only the user's text, prefixed with the [label]
      // reference. No filler scaffolding.
      const line = i18n(
        "npn_critique_reply.visual_notes.eye_path_line_template",
        { label, text }
      );
      this._appendToTextarea(line);
      // Stash on the eye path so a future a11y list snippet can show
      // a description summary.
      if (this.eyePath) {
        this.eyePath = { ...this.eyePath, noteText: text };
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
              eyePath: this.eyePath,
              attentionPulls: this.attentionPulls,
              strongAreas: this.strongAreas,
            })
          : null;

      const response = await postCritiqueRequest(
        topicId,
        raw,
        selectedKey,
        visualNotes
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

      this.toasts.success({
        duration: "short",
        data: {
          message: i18n(
            includedPins > 0
              ? "npn_critique_reply.modal.critique_posted_with_notes"
              : "npn_critique_reply.modal.critique_posted"
          ),
        },
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
      this.eyePath
        ? `ep:${this.eyePath.points
            ?.map((p) => `${p.number}:${p.xPct}:${p.yPct}`)
            .join(",")}`
        : "",
      this.attentionPulls.length,
      this.attentionPulls
        .map((a) => `${a.id}:${a.xPct}:${a.yPct}:${a.widthPct}:${a.heightPct}`)
        .join(","),
      this.strongAreas.length,
      this.strongAreas
        .map((s) => `${s.id}:${s.xPct}:${s.yPct}:${s.widthPct}:${s.heightPct}`)
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
    if (this.eyePath) {
      const eyePathAnnotation = eyePathToAnnotation(this.eyePath);
      if (eyePathAnnotation) {
        annotations.push(eyePathAnnotation);
      }
    }
    for (const pull of attentionPullsToAnnotations(this.attentionPulls ?? [])) {
      annotations.push(pull);
    }
    for (const area of strongAreasToAnnotations(this.strongAreas ?? [])) {
      annotations.push(area);
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

    // The crop/eye_path converters take a SINGLE annotation, not a
    // payload, so pluck the first matching entry from the list.
    const cropEntry = list.find((a) => a?.kind === "crop");
    const eyePathEntry = list.find((a) => a?.kind === "eye_path");
    this.crop = cropEntry ? annotationToCrop(cropEntry) : null;
    if (this.crop?.aspectRatio) {
      this.cropAspectRatio = this.crop.aspectRatio;
    }
    // Match the auto-select-on-placement behaviour of addCrop so the
    // restored crop is immediately interactive (Transformer mounts,
    // drag works in one motion). Eye path handles are always draggable
    // so no selection flag is needed there. Multi-instance shapes
    // (pins, attention pulls, strong areas) intentionally do not
    // auto-select on restore — picking one would be arbitrary, and the
    // konva stage's canDrag gate already allows single-motion drag for
    // any marker in the right tool mode.
    this.cropSelected = !!this.crop;
    this.eyePath = eyePathEntry ? annotationToEyePath(eyePathEntry) : null;

    this.attentionPulls = annotationsToAttentionPulls(synthPayload);
    this.strongAreas = annotationsToStrongAreas(synthPayload);

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
    this.eyePath = null;
    this.attentionPulls = [];
    this.strongAreas = [];
    this.cropSelected = false;
    this.eyePathSelected = false;
    this.selectedPinNumber = null;
    this.selectedAttentionPullId = null;
    this.selectedStrongAreaId = null;
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
                    {{! Pin mode actions. }}
                    {{#if this.noteMode}}
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
                      {{#if this.notes.length}}
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

                    {{! Eye-path mode actions. "Clear eye path" was a
                        duplicate of "Remove eye path" — same action,
                        kept only the trash-can version. }}
                    {{#if this.eyePathMode}}
                      {{#if this.eyePathSelected}}
                        <DButton
                          class="btn-default npn-critique-reply-modal__remove-pin"
                          @icon="trash-can"
                          @action={{this.clearEyePath}}
                          @label="npn_critique_reply.visual_notes.eye_path_remove"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                      {{#if this.hasEyePath}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.removeLastEyePathPoint}}
                          @label="npn_critique_reply.visual_notes.eye_path_remove_last"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                    {{/if}}

                    {{! Attention-pull mode actions. }}
                    {{#if this.attentionPullMode}}
                      {{#if this.selectedAttentionPull}}
                        <DButton
                          class="btn-default npn-critique-reply-modal__remove-pin"
                          @icon="trash-can"
                          @action={{this.removeSelectedAttentionPull}}
                          @label="npn_critique_reply.visual_notes.attention_pull_remove"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                      {{#if this.attentionPulls.length}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearAttentionPulls}}
                          @label="npn_critique_reply.visual_notes.attention_pull_clear"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                    {{/if}}

                    {{! Strong-area mode actions. }}
                    {{#if this.strongAreaMode}}
                      {{#if this.selectedStrongArea}}
                        <DButton
                          class="btn-default npn-critique-reply-modal__remove-pin"
                          @icon="trash-can"
                          @action={{this.removeSelectedStrongArea}}
                          @label="npn_critique_reply.visual_notes.strong_area_remove"
                          @disabled={{this.isPosting}}
                        />
                      {{/if}}
                      {{#if this.strongAreas.length}}
                        <DButton
                          class="btn-flat npn-critique-reply-modal__clear-notes"
                          @action={{this.clearStrongAreas}}
                          @label="npn_critique_reply.visual_notes.strong_area_clear"
                          @disabled={{this.isPosting}}
                        />
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
                @eyePath={{this.eyePath}}
                @eyePathSelected={{this.eyePathSelected}}
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
                    {{#if this.hasEyePath}}
                      <li>
                        <span
                          class="npn-critique-reply-modal__a11y-list-label"
                        >{{i18n
                            "npn_critique_reply.visual_notes.eye_path_a11y_label"
                            count=this.eyePathPointCount
                          }}</span>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          aria-pressed={{if
                            this.eyePathSelected
                            "true"
                            "false"
                          }}
                          disabled={{this.isPosting}}
                          {{on "click" this.selectEyePath}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_select"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-default"
                          disabled={{this.isPosting}}
                          {{on "click" this.removeLastEyePathPoint}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.eye_path_remove_last"
                          }}</button>
                        <button
                          type="button"
                          class="btn-small btn-flat"
                          disabled={{this.isPosting}}
                          {{on "click" this.clearEyePath}}
                        >{{i18n
                            "npn_critique_reply.visual_notes.a11y_remove"
                          }}</button>
                      </li>
                    {{/if}}
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
        {{! Primary: direct post — bypasses the composer. }}
        <DButton
          class="btn-primary npn-critique-reply-modal__post"
          @action={{this.postCritique}}
          @icon="reply"
          @label={{if
            this.isPosting
            "npn_critique_reply.modal.posting"
            "npn_critique_reply.modal.post_critique"
          }}
          @disabled={{this.isPosting}}
          @isLoading={{this.isPosting}}
        />
        {{! Secondary accent: transfer text to the composer for a final pass. }}
        <DButton
          class="npn-critique-reply-modal__edit-composer"
          @action={{this.editInComposer}}
          @icon="far-pen-to-square"
          @label="npn_critique_reply.modal.edit_in_composer"
          @disabled={{this.isPosting}}
        />
        {{! Neutral escape hatch: clean composer, no transfer. }}
        <DButton
          class="btn-default npn-critique-reply-modal__reply-normally"
          @action={{this.replyNormally}}
          @label="npn_critique_reply.modal.reply_normally"
          @disabled={{this.isPosting}}
        />

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
