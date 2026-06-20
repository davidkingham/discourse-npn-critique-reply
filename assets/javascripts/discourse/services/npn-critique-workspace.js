import Service, { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { DRAFT_CHANGED_EVENT } from "../components/modal/npn-critique-reply-modal";

// Session-scoped owner of the minimized Critique Workspace.
//
// When a critic minimizes the workspace, the modal closes (it can't stay
// alive — DModal always traps focus, and each modal.show() is a fresh
// instance), and this service holds the small amount of session state the
// dock needs to offer a "Resume Critique" affordance. The critique CONTENT
// is never stored here — it lives in the server draft, which the reopened
// modal restores via its existing `_initializeDraftSync` / `_restoreDraft`
// path. So this service only tracks "is a critique minimized, for which
// topic, and what was its save status / summary at minimize time".
//
// Lifecycle: instantiated lazily the first time something injects it (the
// modal, to call `minimize`, and the dock connector, to read state). It
// subscribes to DRAFT_CHANGED_EVENT so a Post-success or Discard inside the
// workspace (both broadcast `hasDraft:false`) clears the dock automatically.
export default class NpnCritiqueWorkspaceService extends Service {
  @service appEvents;

  // Whether a critique is currently minimized to the dock this session.
  @tracked active = false;
  // The topic the minimized critique belongs to. We keep the model ref so
  // the dock can reopen the workspace without a lookup; `topicId` is the
  // cheap comparison key for topic-scoped dock visibility.
  @tracked topic = null;
  @tracked topicId = null;
  // Save status captured at minimize time: "saved" | "saving" | "error".
  // Editing can't happen while minimized, so this stays static — the dock
  // only ever shows "Draft saved" because we minimize only after a
  // confirmed flush (see the modal's minimize action).
  @tracked status = null;
  // Optional small summary for the dock label, e.g.
  // { imageIndex, imageCount, activeContext }.
  @tracked summary = null;
  // Per-session dismissal — hides the dock without touching the draft. The
  // footer "Resume Critique Draft" button still reopens the workspace.
  @tracked dismissed = false;
  // One-shot: set when a minimize just happened, so the dock moves focus
  // to its Resume button when it appears. Cleared after the dock consumes
  // it, so the dock re-appearing later (navigation back, composer close)
  // never steals focus.
  @tracked focusRequested = false;

  // Live, currently-OPEN workspace session — distinct from the minimized
  // dock session tracked above. Used by the native-Quote override
  // (`topic:quote-post` handler in the api-initializer) to route a quote
  // into the open workspace instead of the composer.
  //
  // These are PLAIN (non-@tracked) fields on purpose: they're read
  // imperatively from the appEvent handler, never in a template, so
  // mutating them must not schedule a rerender. Making them @tracked
  // would risk the backtracking-rerender assertion this codebase has hit
  // before when service state changes mid-render.
  openInstance = null; // the live NpnCritiqueReplyModal component, or null
  openTopicId = null; // topic id the open workspace belongs to

  constructor() {
    super(...arguments);
    this.appEvents.on(DRAFT_CHANGED_EVENT, this, "_onDraftChanged");
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.appEvents.off(DRAFT_CHANGED_EVENT, this, "_onDraftChanged");
  }

  // True when the dock is eligible to show (active and not dismissed). The
  // dock connector adds the topic-scoping check (current topic === topicId).
  get showDock() {
    return this.active && !this.dismissed;
  }

  // Minimize a critique to the dock. Called by the modal AFTER a confirmed
  // draft save, just before it closes.
  minimize({ topic, status = "saved", summary = null } = {}) {
    const id = topic?.id;
    if (!id) {
      return;
    }
    this.topic = topic;
    this.topicId = id;
    this.status = status;
    this.summary = summary;
    this.dismissed = false;
    this.focusRequested = true;
    this.active = true;
  }

  // Hide the dock for the session without discarding the draft.
  dismiss() {
    this.dismissed = true;
  }

  // Fully clear the minimized session — used when the workspace is resumed,
  // the critique is posted, or the draft is discarded.
  clear() {
    this.active = false;
    this.topic = null;
    this.topicId = null;
    this.status = null;
    this.summary = null;
    this.dismissed = false;
    this.focusRequested = false;
  }

  // --- Open-workspace tracking (native-Quote override) -----------------
  //
  // The modal registers itself on insert and unregisters in willDestroy
  // (which also covers minimize, since minimizing destroys the modal). One
  // modal exists at a time (the modal service serializes opens), so a
  // plain overwrite on register is safe; unregister guards against a newer
  // modal having already replaced the reference. `clear()` deliberately
  // does NOT touch these — they're owned by the modal lifecycle, not the
  // minimize/dock session.
  registerOpenInstance(instance, topicId) {
    this.openInstance = instance;
    this.openTopicId = topicId ?? null;
  }

  unregisterOpenInstance(instance) {
    if (this.openInstance === instance) {
      this.openInstance = null;
      this.openTopicId = null;
    }
  }

  // Bridge used by the topic:quote-post handler. Inserts the quote into the
  // open workspace and returns true if it was consumed; false (→ native
  // quoting) when no workspace is open or it belongs to another topic.
  insertQuote(markdown, topicId) {
    if (!markdown || !this.openInstance) {
      return false;
    }
    if (
      topicId != null &&
      this.openTopicId != null &&
      topicId !== this.openTopicId
    ) {
      return false;
    }
    this.openInstance.insertExternalQuote(markdown);
    return true;
  }

  // Auto-clear when the matching topic's draft goes away. Post-success and
  // Discard both broadcast `hasDraft:false`; `hasDraft:true` is ignored —
  // the dock is driven by explicit minimize, not by mere draft existence.
  _onDraftChanged({ topicId, hasDraft } = {}) {
    if (!hasDraft && topicId && topicId === this.topicId) {
      this.clear();
    }
  }
}
