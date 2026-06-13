import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { modifier } from "ember-modifier";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { createAnnotationStage } from "../lib/npn-critique-reply-konva-stage";
import { recordPluginError } from "../lib/npn-critique-reply-error-bus";

// Wraps the OP's primary image inside the Critique Helper modal and
// hosts the Visual Notes overlay.
//
// Renderer strategy (spike): try Konva first, fall back to the existing
// HTML pin overlay if Konva fails to load or fails to mount. Konva is
// lazy-loaded — only when the user activates note mode OR opens the
// modal on a topic that already has pins. Normal topic pages never
// fetch Konva.
//
// The data model is unchanged: pins remain `{ number, xPct, yPct }`
// in the modal, and the schema in `lib/npn-critique-reply-annotation-
// schema.js` stays canonical. Konva is purely a renderer that consumes
// the pin list and emits add/select callbacks.

const positionPin = modifier(function (element, [xPct, yPct]) {
  element.style.left = `${xPct}%`;
  element.style.top = `${yPct}%`;
});

export default class NpnCritiqueImageReference extends Component {
  // DOM refs captured via didInsert.
  _imageElement = null;

  // Konva stage handle (returned by createAnnotationStage). `null`
  // means: not loaded, or loading, or load failed and we're on the
  // HTML fallback path.
  @tracked _konvaStage = null;

  // True once we've decided to attempt Konva for this modal session.
  // Flips to true on the first frame where note mode is active or
  // pins exist. The container div renders only when this is true.
  @tracked _konvaContainerNeeded = false;

  // True if Konva loading or stage initialization threw. Sticky for
  // the modal session — we don't retry until the modal reopens.
  @tracked _konvaFailed = false;

  // Inflight load guard so a flurry of arg changes can't kick off
  // multiple parallel loadScript calls.
  _konvaInitInFlight = false;

  // Component destroy guard so async tasks completing after teardown
  // don't touch a torn-down stage / tracked properties.
  _destroyed = false;

  get altText() {
    return this.args.alt ?? i18n("npn_critique_reply.modal.image_alt");
  }

  get pins() {
    return Array.isArray(this.args.pins) ? this.args.pins : [];
  }

  // Should the Konva container be in the DOM right now? We only mount
  // the container element after we've actually decided to use Konva
  // for this session, AND the load hasn't failed.
  get _showKonvaContainer() {
    return this._konvaContainerNeeded && !this._konvaFailed;
  }

  // HTML overlay (the pre-Konva renderer) shows whenever Konva isn't
  // active. That covers three cases:
  //   1. Konva hasn't been triggered yet (no note mode, no pins).
  //   2. Konva is loading — fallback shows during the brief window.
  //   3. Konva failed to load (network, missing vendor file, etc.).
  get _showHtmlOverlay() {
    return !this._konvaContainerNeeded || this._konvaFailed;
  }

  // Decide whether we need to start loading Konva for this session.
  // Triggers: any visual mode active, or any existing annotation.
  _maybeFlagKonvaNeeded() {
    if (this._konvaContainerNeeded || this._konvaFailed) {
      return;
    }
    if (
      this.args.visualMode ||
      this.pins.length > 0 ||
      this.args.crop ||
      (this.args.eyePaths?.length ?? 0) > 0 ||
      (this.args.attentionPulls?.length ?? 0) > 0 ||
      (this.args.strongAreas?.length ?? 0) > 0 ||
      (this.args.directionArrows?.length ?? 0) > 0 ||
      (this.args.relationshipArrows?.length ?? 0) > 0
    ) {
      this._konvaContainerNeeded = true;
    }
  }

  // ---- DOM ref capture --------------------------------------------

  @action
  registerImage(element) {
    this._imageElement = element;
    // If the modal opened mid-session with pins already present (a
    // future scenario), trigger Konva loading immediately.
    this._maybeFlagKonvaNeeded();
  }

  @action
  handleImageLoad() {
    // No state change required; the resize observer inside the stage
    // will pick up the image's final dimensions when it mounts.
  }

  // ---- Konva mount / sync / destroy -------------------------------

  @action
  async mountKonva(containerElement) {
    if (this._konvaInitInFlight || this._konvaStage || this._konvaFailed) {
      return;
    }
    if (!this._imageElement) {
      return;
    }
    this._konvaInitInFlight = true;

    try {
      // Wait for the source image to be fully decoded so we can size
      // the stage to it. Cached images may already be complete.
      if (
        !this._imageElement.complete ||
        this._imageElement.naturalWidth === 0
      ) {
        await new Promise((resolve) => {
          const done = () => {
            this._imageElement.removeEventListener("load", done);
            this._imageElement.removeEventListener("error", done);
            resolve();
          };
          this._imageElement.addEventListener("load", done, { once: true });
          this._imageElement.addEventListener("error", done, { once: true });
        });
      }

      if (this._destroyed) {
        return;
      }

      const stage = await createAnnotationStage({
        container: containerElement,
        imageElement: this._imageElement,
        pins: this.pins,
        crop: this.args.crop,
        eyePaths: this.args.eyePaths,
        selectedPinNumber: this.args.selectedNumber,
        cropSelected: this.args.cropSelected,
        selectedEyePathId: this.args.selectedEyePathId,
        visualMode: this.args.visualMode,
        areaShapeMode: this.args.areaShapeMode,
        eyePathInteractionMode: this.args.eyePathInteractionMode,
        aspectRatio: this.args.cropAspectRatio,
        pinMoveEnabled: this.args.pinMoveEnabled,
        onAddPin: (xPct, yPct) => this.args.onImageClick?.(xPct, yPct),
        onSelectPin: (pin) => this.args.onPinSelect?.(pin),
        onMovePin: (number, xPct, yPct) =>
          this.args.onMovePin?.(number, xPct, yPct),
        onAddCrop: (xPct, yPct, widthPct, heightPct) =>
          this.args.onAddCrop?.(xPct, yPct, widthPct, heightPct),
        onSelectCrop: () => this.args.onSelectCrop?.(),
        onUpdateCrop: (xPct, yPct, widthPct, heightPct) =>
          this.args.onUpdateCrop?.(xPct, yPct, widthPct, heightPct),
        onAddEyePathPoint: (xPct, yPct) =>
          this.args.onAddEyePathPoint?.(xPct, yPct),
        onCommitEyePath: (points) =>
          this.args.onCommitEyePath?.(points),
        onSelectEyePath: (pathId) => this.args.onSelectEyePath?.(pathId),
        onMoveEyePathPoint: (pathId, number, xPct, yPct) =>
          this.args.onMoveEyePathPoint?.(pathId, number, xPct, yPct),
        attentionPulls: this.args.attentionPulls,
        selectedAttentionPullId: this.args.selectedAttentionPullId,
        attentionPullEditEnabled: this.args.attentionPullEditEnabled,
        retracingAttentionPullId: this.args.retracingAttentionPullId,
        onAddAttentionPull: (xPct, yPct, widthPct, heightPct) =>
          this.args.onAddAttentionPull?.(xPct, yPct, widthPct, heightPct),
        onAddAttentionPullPath: (points) =>
          this.args.onAddAttentionPullPath?.(points),
        onRetraceAttentionPullPath: (id, points) =>
          this.args.onRetraceAttentionPullPath?.(id, points),
        onSelectAttentionPull: (id) =>
          this.args.onSelectAttentionPull?.(id),
        onUpdateAttentionPull: (id, xPct, yPct, widthPct, heightPct) =>
          this.args.onUpdateAttentionPull?.(
            id,
            xPct,
            yPct,
            widthPct,
            heightPct
          ),
        strongAreas: this.args.strongAreas,
        selectedStrongAreaId: this.args.selectedStrongAreaId,
        strongAreaEditEnabled: this.args.strongAreaEditEnabled,
        retracingStrongAreaId: this.args.retracingStrongAreaId,
        onAddStrongArea: (xPct, yPct, widthPct, heightPct) =>
          this.args.onAddStrongArea?.(xPct, yPct, widthPct, heightPct),
        onAddStrongAreaPath: (points) =>
          this.args.onAddStrongAreaPath?.(points),
        onRetraceStrongAreaPath: (id, points) =>
          this.args.onRetraceStrongAreaPath?.(id, points),
        onSelectStrongArea: (id) => this.args.onSelectStrongArea?.(id),
        onUpdateStrongArea: (id, xPct, yPct, widthPct, heightPct) =>
          this.args.onUpdateStrongArea?.(
            id,
            xPct,
            yPct,
            widthPct,
            heightPct
          ),
        directionArrows: this.args.directionArrows,
        selectedDirectionArrowId: this.args.selectedDirectionArrowId,
        onAddDirectionArrow: (x1Pct, y1Pct, x2Pct, y2Pct) =>
          this.args.onAddDirectionArrow?.(x1Pct, y1Pct, x2Pct, y2Pct),
        onSelectDirectionArrow: (id) =>
          this.args.onSelectDirectionArrow?.(id),
        onUpdateDirectionArrow: (id, x1Pct, y1Pct, x2Pct, y2Pct) =>
          this.args.onUpdateDirectionArrow?.(
            id,
            x1Pct,
            y1Pct,
            x2Pct,
            y2Pct
          ),
        relationshipArrows: this.args.relationshipArrows,
        selectedRelationshipArrowId: this.args.selectedRelationshipArrowId,
        onAddRelationshipArrow: (x1Pct, y1Pct, x2Pct, y2Pct) =>
          this.args.onAddRelationshipArrow?.(x1Pct, y1Pct, x2Pct, y2Pct),
        onSelectRelationshipArrow: (id) =>
          this.args.onSelectRelationshipArrow?.(id),
        onUpdateRelationshipArrow: (id, x1Pct, y1Pct, x2Pct, y2Pct) =>
          this.args.onUpdateRelationshipArrow?.(
            id,
            x1Pct,
            y1Pct,
            x2Pct,
            y2Pct
          ),
      });

      if (this._destroyed) {
        // Modal closed mid-load. Tear down the stage we just made so
        // we don't leak a Konva.Stage in memory.
        stage.destroy();
        return;
      }
      this._konvaStage = stage;
    } catch (e) {
      // Most likely paths:
      //   • vendored konva.min.js missing → loadScript 404
      //   • CSP blocking the script tag
      //   • Konva loaded but constructor threw
      // All resolve to: record on the plugin error bus, flag failed,
      // fall back to HTML overlay. The modal's listener picks the
      // entry up so the next "Copy diagnostic" report carries this.
      recordPluginError(
        "konva_stage_init",
        e,
        {
          hasImage: !!this._imageElement,
          imageNaturalWidth: this._imageElement?.naturalWidth ?? null,
          imageNaturalHeight: this._imageElement?.naturalHeight ?? null,
          imageSrc: this.args.imageUrl ?? null,
        },
        "warn"
      );
      this._konvaFailed = true;
    } finally {
      this._konvaInitInFlight = false;
    }
  }

  // didUpdate fires whenever any of the tracked args we list in the
  // template change. We push the new values into the stage so Konva
  // re-renders pins / selection state in lockstep with the modal.
  @action
  syncKonva() {
    if (!this._konvaStage) {
      return;
    }
    this._konvaStage.update({
      pins: this.pins,
      crop: this.args.crop,
      eyePaths: this.args.eyePaths,
      attentionPulls: this.args.attentionPulls,
      strongAreas: this.args.strongAreas,
      directionArrows: this.args.directionArrows,
      relationshipArrows: this.args.relationshipArrows,
      selectedPinNumber: this.args.selectedNumber,
      cropSelected: this.args.cropSelected,
      selectedEyePathId: this.args.selectedEyePathId,
      selectedAttentionPullId: this.args.selectedAttentionPullId,
      selectedStrongAreaId: this.args.selectedStrongAreaId,
      selectedDirectionArrowId: this.args.selectedDirectionArrowId,
      selectedRelationshipArrowId: this.args.selectedRelationshipArrowId,
      visualMode: this.args.visualMode,
      areaShapeMode: this.args.areaShapeMode,
      eyePathInteractionMode: this.args.eyePathInteractionMode,
      aspectRatio: this.args.cropAspectRatio,
      pinMoveEnabled: this.args.pinMoveEnabled,
      attentionPullEditEnabled: this.args.attentionPullEditEnabled,
      strongAreaEditEnabled: this.args.strongAreaEditEnabled,
      retracingAttentionPullId: this.args.retracingAttentionPullId,
      retracingStrongAreaId: this.args.retracingStrongAreaId,
    });
  }

  @action
  watchArgsForKonvaNeed() {
    // Called by didUpdate on the figure; flips _konvaContainerNeeded
    // to true the first time we see noteModeActive or pins.
    this._maybeFlagKonvaNeeded();
  }

  @action
  teardownKonva() {
    this._destroyed = true;
    if (this._konvaStage) {
      try {
        this._konvaStage.destroy();
      } catch (_e) {
        // Konva already torn down — fine.
      }
      this._konvaStage = null;
    }
  }

  // ---- HTML fallback handlers (unchanged from previous step) -----

  // ---- Note popover -----------------------------------------------

  // Auto-focus the input the moment the popover mounts. The pending
  // pin is the user's most recent intent — moving focus there lets
  // them type a note immediately or hit Escape to skip.
  @action
  focusNoteInput(element) {
    // Defer one frame so the element has its initial layout before
    // we steal focus. This avoids the rare case where focus lands
    // before the popover has been positioned and the browser
    // scrolls to a phantom location.
    requestAnimationFrame(() => {
      try {
        element.focus({ preventScroll: true });
        // Select all so re-opening the popover with stale text
        // (shouldn't happen with our state reset, but cheap defense)
        // would be one keystroke away from being replaced.
        element.select?.();
      } catch (_e) {
        // Ignore — DOM may have been replaced or the element may
        // already be focused. Either way the popover still works.
      }
    });
  }

  // Anchored positioning. We measure the figure frame and the
  // popover, place it near the anchor's pixel coords, then flip to
  // the opposite side when it would overflow.
  //
  // The anchor object is shape-flexible — pins pass `{xPct, yPct}`,
  // the attention-pull and eye-path popovers pass `{anchorXPct,
  // anchorYPct}`. We accept either.
  @action
  positionNotePopover(element, [anchor]) {
    if (!anchor || !this._imageElement) {
      return;
    }
    const xPct = anchor.xPct ?? anchor.anchorXPct;
    const yPct = anchor.yPct ?? anchor.anchorYPct;
    if (xPct == null || yPct == null) {
      return;
    }
    const frame = element.parentElement;
    if (!frame) {
      return;
    }
    const fw = frame.clientWidth;
    const fh = frame.clientHeight;
    if (fw === 0 || fh === 0) {
      return;
    }
    const pinX = (xPct / 100) * fw;
    const pinY = (yPct / 100) * fh;

    // Allow the popover to measure itself before flipping. width/
    // height are clientWidth/Height which include padding but not
    // border (border is 1px here — close enough for flipping).
    const pw = element.offsetWidth;
    const ph = element.offsetHeight;
    const gap = 16;

    let left = pinX + gap;
    let top = pinY + gap;
    if (left + pw > fw) {
      left = pinX - pw - gap;
    }
    if (top + ph > fh) {
      top = pinY - ph - gap;
    }
    left = Math.max(4, Math.min(fw - pw - 4, left));
    top = Math.max(4, Math.min(fh - ph - 4, top));

    element.style.left = `${left}px`;
    element.style.top = `${top}px`;
  }

  // Enter confirms (single-line input, matches the user's spec).
  // Escape skips. Other keys fall through to the input.
  @action
  handleNoteKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.args.onConfirmPendingNote?.();
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.args.onSkipPendingNote?.();
    }
  }

  @action
  handleAttentionPullPopoverKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.args.onConfirmPendingAttentionPullPopover?.();
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.args.onSkipPendingAttentionPullPopover?.();
    }
  }

  @action
  handleStrongAreaPopoverKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.args.onConfirmPendingStrongAreaPopover?.();
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.args.onSkipPendingStrongAreaPopover?.();
    }
  }

  @action
  handleEyePathPopoverKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.args.onConfirmPendingEyePathPopover?.();
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.args.onSkipPendingEyePathPopover?.();
    }
  }

  @action
  handleCropPopoverKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.args.onConfirmPendingCropPopover?.();
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.args.onSkipPendingCropPopover?.();
    }
  }

  @action
  handleDirectionArrowPopoverKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.args.onConfirmPendingDirectionArrowPopover?.();
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.args.onSkipPendingDirectionArrowPopover?.();
    }
  }

  @action
  handleRelationshipArrowPopoverKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      this.args.onConfirmPendingRelationshipArrowPopover?.();
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.args.onSkipPendingRelationshipArrowPopover?.();
    }
  }

  @action
  handleOverlayClick(event) {
    // HTML fallback only supports the numbered-notes mode — crop is
    // Konva-only. The toolbar already hides the Crop tool when Konva
    // failed; this guard is belt-and-braces.
    if (this.args.visualMode !== "numbered_notes" || !this.args.onImageClick) {
      return;
    }
    const rect = event.currentTarget.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) {
      return;
    }
    const xPct = clamp(
      ((event.clientX - rect.left) / rect.width) * 100,
      0,
      100
    );
    const yPct = clamp(
      ((event.clientY - rect.top) / rect.height) * 100,
      0,
      100
    );
    this.args.onImageClick(xPct, yPct);
  }

  @action
  handlePinClick(pin, event) {
    event.stopPropagation();
    this.args.onPinSelect?.(pin);
  }

  <template>
    {{#if @imageUrl}}
      <figure
        class="npn-critique-image-reference
          {{if @visualMode 'is-visual-mode'}}
          {{if (eq @visualMode 'numbered_notes') 'is-note-mode'}}
          {{if (eq @visualMode 'crop_suggestion') 'is-crop-mode'}}
          {{if (eq @visualMode 'eye_path') 'is-eye-path-mode'}}
          {{if (eq @visualMode 'attention_pull') 'is-attention-pull-mode'}}
          {{if (eq @visualMode 'strong_area') 'is-strong-area-mode'}}
          {{if (eq @visualMode 'direction_arrow') 'is-direction-arrow-mode'}}
          {{if (eq @visualMode 'relationship_arrow') 'is-relationship-arrow-mode'}}
          {{if this._konvaStage 'is-konva-active'}}"
        data-markup-slot="image"
        {{didUpdate
          this.watchArgsForKonvaNeed
          @visualMode
          this.pins.length
          @crop
          @eyePaths
          @attentionPulls
          @strongAreas
          @directionArrows
          @relationshipArrows
        }}
        {{willDestroy this.teardownKonva}}
      >
        <div class="npn-critique-image-reference__frame">
          <img
            class="npn-critique-image-reference__img"
            src={{@imageUrl}}
            alt={{this.altText}}
            loading="lazy"
            decoding="async"
            {{didInsert this.registerImage}}
            {{on "load" this.handleImageLoad}}
          />

          {{#if this._showKonvaContainer}}
            <div
              class="npn-critique-image-reference__konva-container"
              data-markup-slot="overlay"
              {{didInsert this.mountKonva}}
              {{didUpdate
                this.syncKonva
                this.pins
                @selectedNumber
                @visualMode
                @areaShapeMode
                @eyePathInteractionMode
                @crop
                @cropSelected
                @cropAspectRatio
                @pinMoveEnabled
                @eyePaths
                @selectedEyePathId
                @attentionPulls
                @selectedAttentionPullId
                @attentionPullEditEnabled
                @retracingAttentionPullId
                @strongAreas
                @selectedStrongAreaId
                @strongAreaEditEnabled
                @retracingStrongAreaId
                @directionArrows
                @selectedDirectionArrowId
                @relationshipArrows
                @selectedRelationshipArrowId
              }}
            ></div>
          {{/if}}

          {{#if this._showHtmlOverlay}}
            <div
              class="npn-critique-image-reference__overlay"
              data-markup-slot="overlay"
              aria-hidden={{unless @visualMode "true"}}
              {{on "click" this.handleOverlayClick}}
            >
              {{#each this.pins as |pin|}}
                <button
                  type="button"
                  class="npn-critique-pin
                    {{if (eq pin.number @selectedNumber) 'is-selected'}}"
                  aria-label={{i18n
                    "npn_critique_reply.visual_notes.pin_label"
                    number=pin.number
                  }}
                  aria-pressed={{if
                    (eq pin.number @selectedNumber)
                    "true"
                    "false"
                  }}
                  {{positionPin pin.xPct pin.yPct}}
                  {{on "click" (fn this.handlePinClick pin)}}
                >{{pin.number}}</button>
              {{/each}}
            </div>
          {{/if}}

          {{#if @pendingPin}}
            <div
              class="npn-critique-image-reference__note-popover"
              role="dialog"
              aria-label={{i18n
                "npn_critique_reply.visual_notes.note_popover_dialog_label"
                number=@pendingPin.number
              }}
              {{didInsert this.positionNotePopover @pendingPin}}
              {{didUpdate this.positionNotePopover @pendingPin}}
            >
              <div
                class="npn-critique-image-reference__note-popover-title"
              >{{i18n
                  "npn_critique_reply.visual_notes.note_popover_title"
                  number=@pendingPin.number
                }}</div>
              <input
                type="text"
                class="npn-critique-image-reference__note-popover-input"
                placeholder={{i18n
                  "npn_critique_reply.visual_notes.note_popover_placeholder"
                }}
                value={{@pendingPinNoteText}}
                autocomplete="off"
                {{on "input" @onPendingNoteInput}}
                {{on "keydown" this.handleNoteKeydown}}
                {{didInsert this.focusNoteInput}}
              />
              <div
                class="npn-critique-image-reference__note-popover-actions"
              >
                <button
                  type="button"
                  class="btn btn-primary btn-small
                    npn-critique-image-reference__note-popover-add"
                  {{on "click" @onConfirmPendingNote}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_add"
                  }}</button>
                <button
                  type="button"
                  class="btn btn-flat btn-small
                    npn-critique-image-reference__note-popover-skip"
                  {{on "click" @onSkipPendingNote}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_skip"
                  }}</button>
              </div>
            </div>
          {{/if}}

          {{#if @pendingAttentionPullPopover}}
            <div
              class="npn-critique-image-reference__note-popover"
              role="dialog"
              aria-label={{i18n
                "npn_critique_reply.visual_notes.area_note_popover_dialog_label"
              }}
              {{didInsert
                this.positionNotePopover
                @pendingAttentionPullPopover
              }}
              {{didUpdate
                this.positionNotePopover
                @pendingAttentionPullPopover
              }}
            >
              <div
                class="npn-critique-image-reference__note-popover-title"
              >{{i18n
                  "npn_critique_reply.visual_notes.area_note_popover_title"
                }}</div>
              <input
                type="text"
                class="npn-critique-image-reference__note-popover-input"
                placeholder={{i18n
                  "npn_critique_reply.visual_notes.area_note_popover_placeholder"
                }}
                value={{@pendingAttentionPullPopoverText}}
                autocomplete="off"
                {{on "input" @onPendingAttentionPullPopoverInput}}
                {{on "keydown" this.handleAttentionPullPopoverKeydown}}
                {{didInsert this.focusNoteInput}}
              />
              <div
                class="npn-critique-image-reference__note-popover-actions"
              >
                <button
                  type="button"
                  class="btn btn-primary btn-small
                    npn-critique-image-reference__note-popover-add"
                  {{on "click" @onConfirmPendingAttentionPullPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_add"
                  }}</button>
                <button
                  type="button"
                  class="btn btn-flat btn-small
                    npn-critique-image-reference__note-popover-skip"
                  {{on "click" @onSkipPendingAttentionPullPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_skip"
                  }}</button>
              </div>
            </div>
          {{/if}}

          {{#if @pendingStrongAreaPopover}}
            <div
              class="npn-critique-image-reference__note-popover"
              role="dialog"
              aria-label={{i18n
                "npn_critique_reply.visual_notes.strong_area_popover_dialog_label"
              }}
              {{didInsert
                this.positionNotePopover
                @pendingStrongAreaPopover
              }}
              {{didUpdate
                this.positionNotePopover
                @pendingStrongAreaPopover
              }}
            >
              <div
                class="npn-critique-image-reference__note-popover-title"
              >{{i18n
                  "npn_critique_reply.visual_notes.strong_area_popover_title"
                }}</div>
              <input
                type="text"
                class="npn-critique-image-reference__note-popover-input"
                placeholder={{i18n
                  "npn_critique_reply.visual_notes.strong_area_popover_placeholder"
                }}
                value={{@pendingStrongAreaPopoverText}}
                autocomplete="off"
                {{on "input" @onPendingStrongAreaPopoverInput}}
                {{on "keydown" this.handleStrongAreaPopoverKeydown}}
                {{didInsert this.focusNoteInput}}
              />
              <div
                class="npn-critique-image-reference__note-popover-actions"
              >
                <button
                  type="button"
                  class="btn btn-primary btn-small
                    npn-critique-image-reference__note-popover-add"
                  {{on "click" @onConfirmPendingStrongAreaPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_add"
                  }}</button>
                <button
                  type="button"
                  class="btn btn-flat btn-small
                    npn-critique-image-reference__note-popover-skip"
                  {{on "click" @onSkipPendingStrongAreaPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_skip"
                  }}</button>
              </div>
            </div>
          {{/if}}

          {{#if @pendingEyePathPopover}}
            <div
              class="npn-critique-image-reference__note-popover"
              role="dialog"
              aria-label={{i18n
                "npn_critique_reply.visual_notes.eye_path_popover_dialog_label"
              }}
              {{didInsert
                this.positionNotePopover
                @pendingEyePathPopover
              }}
              {{didUpdate
                this.positionNotePopover
                @pendingEyePathPopover
              }}
            >
              <div
                class="npn-critique-image-reference__note-popover-title"
              >{{i18n
                  "npn_critique_reply.visual_notes.eye_path_popover_title"
                }}</div>
              <input
                type="text"
                class="npn-critique-image-reference__note-popover-input"
                placeholder={{i18n
                  "npn_critique_reply.visual_notes.eye_path_popover_placeholder"
                }}
                value={{@pendingEyePathPopoverText}}
                autocomplete="off"
                {{on "input" @onPendingEyePathPopoverInput}}
                {{on "keydown" this.handleEyePathPopoverKeydown}}
                {{didInsert this.focusNoteInput}}
              />
              <div
                class="npn-critique-image-reference__note-popover-actions"
              >
                <button
                  type="button"
                  class="btn btn-primary btn-small
                    npn-critique-image-reference__note-popover-add"
                  {{on "click" @onConfirmPendingEyePathPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_add"
                  }}</button>
                <button
                  type="button"
                  class="btn btn-flat btn-small
                    npn-critique-image-reference__note-popover-skip"
                  {{on "click" @onSkipPendingEyePathPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_skip"
                  }}</button>
              </div>
            </div>
          {{/if}}

          {{#if @pendingCropPopover}}
            <div
              class="npn-critique-image-reference__note-popover"
              role="dialog"
              aria-label={{i18n
                "npn_critique_reply.visual_notes.crop_popover_dialog_label"
              }}
              {{didInsert
                this.positionNotePopover
                @pendingCropPopover
              }}
              {{didUpdate
                this.positionNotePopover
                @pendingCropPopover
              }}
            >
              <div
                class="npn-critique-image-reference__note-popover-title"
              >{{i18n
                  "npn_critique_reply.visual_notes.crop_popover_title"
                }}</div>
              <input
                type="text"
                class="npn-critique-image-reference__note-popover-input"
                placeholder={{i18n
                  "npn_critique_reply.visual_notes.crop_popover_placeholder"
                }}
                value={{@pendingCropPopoverText}}
                autocomplete="off"
                {{on "input" @onPendingCropPopoverInput}}
                {{on "keydown" this.handleCropPopoverKeydown}}
                {{didInsert this.focusNoteInput}}
              />
              <div
                class="npn-critique-image-reference__note-popover-actions"
              >
                <button
                  type="button"
                  class="btn btn-primary btn-small
                    npn-critique-image-reference__note-popover-add"
                  {{on "click" @onConfirmPendingCropPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_add"
                  }}</button>
                <button
                  type="button"
                  class="btn btn-flat btn-small
                    npn-critique-image-reference__note-popover-skip"
                  {{on "click" @onSkipPendingCropPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_skip"
                  }}</button>
              </div>
            </div>
          {{/if}}

          {{#if @pendingDirectionArrowPopover}}
            <div
              class="npn-critique-image-reference__note-popover"
              role="dialog"
              aria-label={{i18n
                "npn_critique_reply.visual_notes.direction_arrow_popover_dialog_label"
              }}
              {{didInsert
                this.positionNotePopover
                @pendingDirectionArrowPopover
              }}
              {{didUpdate
                this.positionNotePopover
                @pendingDirectionArrowPopover
              }}
            >
              <div
                class="npn-critique-image-reference__note-popover-title"
              >{{i18n
                  "npn_critique_reply.visual_notes.direction_arrow_popover_title"
                }}</div>
              <input
                type="text"
                class="npn-critique-image-reference__note-popover-input"
                placeholder={{i18n
                  "npn_critique_reply.visual_notes.direction_arrow_popover_placeholder"
                }}
                value={{@pendingDirectionArrowPopoverText}}
                autocomplete="off"
                {{on "input" @onPendingDirectionArrowPopoverInput}}
                {{on "keydown" this.handleDirectionArrowPopoverKeydown}}
                {{didInsert this.focusNoteInput}}
              />
              <div
                class="npn-critique-image-reference__note-popover-actions"
              >
                <button
                  type="button"
                  class="btn btn-primary btn-small
                    npn-critique-image-reference__note-popover-add"
                  {{on "click" @onConfirmPendingDirectionArrowPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_add"
                  }}</button>
                <button
                  type="button"
                  class="btn btn-flat btn-small
                    npn-critique-image-reference__note-popover-skip"
                  {{on "click" @onSkipPendingDirectionArrowPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_skip"
                  }}</button>
              </div>
            </div>
          {{/if}}

          {{#if @pendingRelationshipArrowPopover}}
            <div
              class="npn-critique-image-reference__note-popover"
              role="dialog"
              aria-label={{i18n
                "npn_critique_reply.visual_notes.relationship_arrow_popover_dialog_label"
              }}
              {{didInsert
                this.positionNotePopover
                @pendingRelationshipArrowPopover
              }}
              {{didUpdate
                this.positionNotePopover
                @pendingRelationshipArrowPopover
              }}
            >
              <div
                class="npn-critique-image-reference__note-popover-title"
              >{{i18n
                  "npn_critique_reply.visual_notes.relationship_arrow_popover_title"
                }}</div>
              <input
                type="text"
                class="npn-critique-image-reference__note-popover-input"
                placeholder={{i18n
                  "npn_critique_reply.visual_notes.relationship_arrow_popover_placeholder"
                }}
                value={{@pendingRelationshipArrowPopoverText}}
                autocomplete="off"
                {{on "input" @onPendingRelationshipArrowPopoverInput}}
                {{on "keydown" this.handleRelationshipArrowPopoverKeydown}}
                {{didInsert this.focusNoteInput}}
              />
              <div
                class="npn-critique-image-reference__note-popover-actions"
              >
                <button
                  type="button"
                  class="btn btn-primary btn-small
                    npn-critique-image-reference__note-popover-add"
                  {{on "click" @onConfirmPendingRelationshipArrowPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_add"
                  }}</button>
                <button
                  type="button"
                  class="btn btn-flat btn-small
                    npn-critique-image-reference__note-popover-skip"
                  {{on "click" @onSkipPendingRelationshipArrowPopover}}
                >{{i18n
                    "npn_critique_reply.visual_notes.note_popover_skip"
                  }}</button>
              </div>
            </div>
          {{/if}}
        </div>

        {{! Per-tool hints have moved into the modal's secondary
            toolbar (right next to where the tool was activated). The
            crop hint stays here because it changes based on whether
            a crop exists yet, and it's positioned alongside the
            aspect-ratio chooser, so the inline-below-image placement
            still reads naturally. }}
        {{#if (eq @visualMode "crop_suggestion")}}
          <p
            class="npn-critique-image-reference__hint"
            aria-live="polite"
          >{{i18n
              (if
                @crop
                "npn_critique_reply.visual_notes.crop_present_hint"
                "npn_critique_reply.visual_notes.crop_hint"
              )
            }}</p>
        {{/if}}
      </figure>
    {{/if}}
  </template>
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}
