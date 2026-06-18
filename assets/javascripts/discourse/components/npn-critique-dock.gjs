import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import NpnCritiqueReplyModal from "./modal/npn-critique-reply-modal";

// Composer transitions don't change the route or our tracked state, so we
// re-read the authoritative composer state on each of these app events to
// keep the dock hidden while the standard composer occupies the bottom.
// (Subscribing to an event that never fires is harmless.)
const COMPOSER_EVENTS = [
  "composer:open",
  "composer:opened",
  "composer:closed",
  "composer:cancelled",
  "composer:saved",
  "composer:created-post",
  "composer:edited-post",
];

// Persistent "Critique in progress" dock, rendered once into the
// application-level `below-footer` outlet (always present, every route).
// It only shows when a critique has been minimized AND the user is on the
// originating topic — minimizing closes the workspace, this dock is the
// visible, reassuring way back. Resume reopens the workspace, which
// restores everything from the server draft (no state passed through here).
export default class NpnCritiqueDock extends Component {
  @service npnCritiqueWorkspace;
  @service modal;
  @service router;
  @service appEvents;
  @service composer;

  // Id of the topic currently being viewed (null off any topic route).
  // Tracked so the `visible` getter recomputes when the route changes —
  // we can't trust the topic controller's model alone, since it retains
  // the last topic after you navigate away.
  @tracked _currentTopicId = null;
  // Whether the standard composer is occupying the bottom of the screen.
  // We hide the dock while it is, to avoid two stacked bottom bars (and
  // direct overlap on mobile). The critique draft is untouched — separate
  // draft keys, never merged.
  @tracked _composerOpen = false;

  constructor() {
    super(...arguments);
    this._syncCurrentTopic();
    this._syncComposer();
    this.appEvents.on("page:changed", this, "_syncCurrentTopic");
    for (const evt of COMPOSER_EVENTS) {
      this.appEvents.on(evt, this, "_syncComposer");
    }
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.appEvents.off("page:changed", this, "_syncCurrentTopic");
    for (const evt of COMPOSER_EVENTS) {
      this.appEvents.off(evt, this, "_syncComposer");
    }
  }

  _syncComposer() {
    const state = this.composer?.model?.composeState;
    // Present in any non-closed state (open / fullscreen / collapsed draft
    // bar). When closed, model may be cleared — both read as not-open.
    this._composerOpen = !!state && state !== "closed";
  }

  _syncCurrentTopic() {
    const routeName = this.router.currentRouteName || "";
    if (!routeName.startsWith("topic.")) {
      this._currentTopicId = null;
      return;
    }
    const topic = getOwner(this).lookup("controller:topic")?.model;
    this._currentTopicId = topic?.id ?? null;
  }

  // Dock shows only when a critique is minimized (and not dismissed) and
  // we're viewing the topic it belongs to.
  get visible() {
    const ws = this.npnCritiqueWorkspace;
    return (
      ws.showDock &&
      !!ws.topicId &&
      this._currentTopicId === ws.topicId &&
      !this._composerOpen
    );
  }

  // "Image 2 of 4" when the minimized critique spans multiple images;
  // null for single-image critiques (no clutter).
  get imageContextLabel() {
    const summary = this.npnCritiqueWorkspace.summary;
    const total = summary?.imageCount ?? 1;
    if (!total || total < 2) {
      return null;
    }
    return i18n("npn_critique_reply.dock.image_context", {
      current: (summary?.imageIndex ?? 0) + 1,
      total,
    });
  }

  @action
  resume() {
    const ws = this.npnCritiqueWorkspace;
    const topic = ws.topic;
    if (!topic) {
      ws.clear();
      return;
    }
    const metadata = topic.npn_critique_reply ?? null;
    // Clear first so the dock hides as the workspace reopens; the modal
    // rebuilds all state from the server draft on open.
    ws.clear();
    this.modal.show(NpnCritiqueReplyModal, { model: { topic, metadata } });
  }

  @action
  dismiss() {
    // Hide the dock for the session without touching the draft — the
    // footer "Resume Critique Draft" button still reopens the workspace.
    this.npnCritiqueWorkspace.dismiss();
  }

  <template>
    {{#if this.visible}}
      <div
        class="npn-critique-dock"
        role="region"
        aria-label={{i18n "npn_critique_reply.dock.aria_label"}}
      >
        <div class="npn-critique-dock__info">
          <span class="npn-critique-dock__title">
            {{i18n "npn_critique_reply.dock.title"}}
          </span>
          <span class="npn-critique-dock__status">
            {{#if this.imageContextLabel}}
              {{this.imageContextLabel}}
              ·
            {{/if}}
            {{i18n "npn_critique_reply.dock.saved"}}
          </span>
        </div>
        <div class="npn-critique-dock__actions">
          <DButton
            class="btn-primary npn-critique-dock__resume"
            @action={{this.resume}}
            @icon="far-pen-to-square"
            @label="npn_critique_reply.dock.resume"
          />
          <DButton
            class="btn-flat npn-critique-dock__dismiss"
            @action={{this.dismiss}}
            @icon="xmark"
            @title="npn_critique_reply.dock.dismiss_title"
          />
        </div>
      </div>
    {{/if}}
  </template>
}
