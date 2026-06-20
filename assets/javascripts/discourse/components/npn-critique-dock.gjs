import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
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
  @service siteSettings;

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
      this.siteSettings.npn_critique_reply_enabled !== false &&
      ws.showDock &&
      !!ws.topicId &&
      this._currentTopicId === ws.topicId &&
      !this._composerOpen
    );
  }

  // When the dock appears because of a Minimize (not a navigation/composer
  // re-show), move focus to Resume so keyboard + screen-reader users land
  // on the way back. Consumed once, then cleared.
  @action
  onDockShown(element) {
    if (!this.npnCritiqueWorkspace.focusRequested) {
      return;
    }
    this.npnCritiqueWorkspace.focusRequested = false;
    // Defer so focus wins after the closing modal's focus-trap teardown.
    setTimeout(() => {
      element
        ?.querySelector?.(".npn-critique-dock__resume")
        ?.focus?.();
    }, 0);
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
    // rebuilds all state from the server draft on open. `focusWriting`
    // asks the reopened workspace to land focus in the active writing
    // field (resume-only — Start/Edit opens are unchanged).
    ws.clear();
    this.modal.show(NpnCritiqueReplyModal, {
      model: { topic, metadata, focusWriting: true },
    });
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
        {{didInsert this.onDockShown}}
      >
        <div class="npn-critique-dock__info">
          <span class="npn-critique-dock__title">
            {{i18n "npn_critique_reply.dock.title"}}
          </span>
          <span class="npn-critique-dock__status">
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
