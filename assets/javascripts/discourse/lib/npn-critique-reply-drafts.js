// Server-side critique workspace drafts.
// =================================================================
//
// Thin client wrapper around the plugin's draft endpoints
// (drafts_controller.rb). One active draft per (current_user, topic).
// The modal calls into this module on open (loadDraft), on meaningful
// state changes (scheduleSaveDraft, debounced), on success paths
// (deleteDraft), and on Discard (deleteDraft).
//
// Status states:
//   • idle    — no recent save activity
//   • saving  — debounced save in flight
//   • saved   — last save succeeded
//   • error   — last save failed (transient; UI doesn't block writing)
//
// The store deliberately does NOT debounce loadDraft — restores need
// to happen immediately on modal open. saveDraft is fired through a
// per-topic debounce timer.

import { ajax } from "discourse/lib/ajax";
import { recordPluginError } from "./npn-critique-reply-error-bus";

export const DRAFT_AUTOSAVE_DEBOUNCE_MS = 1500;

export const DRAFT_STATUS = Object.freeze({
  IDLE: "idle",
  SAVING: "saving",
  SAVED: "saved",
  ERROR: "error",
});

function draftEndpoint(topicId) {
  return `/npn-critique-reply/topics/${topicId}/draft.json`;
}

// Fetch the user's draft for `topicId`. Returns the draft hash on
// success, `null` when there is no draft (or it expired server-side),
// and re-throws on transport errors so callers can surface them.
export async function loadDraft(topicId) {
  const response = await ajax(draftEndpoint(topicId), { type: "GET" });
  return response?.draft ?? null;
}

// One-shot save. Returns the server-normalized draft body so the
// caller can sync any server-side defaults (timestamps, dropped
// invalid annotations).
//
// Sent as `application/json` rather than the jQuery-default
// form-encoded body. Form-encoding round-trips deeply nested arrays
// (e.g. `draft[annotations][0][points][1][x_pct]`) through Rack with
// quirks that varied across jQuery + Rails versions and caused
// annotations to drop server-side. JSON has no such ambiguity.
export async function saveDraft(topicId, payload) {
  const response = await ajax(draftEndpoint(topicId), {
    type: "PUT",
    data: JSON.stringify({ draft: payload }),
    contentType: "application/json",
    processData: false,
    dataType: "json",
  });
  return response?.draft ?? null;
}

export async function deleteDraft(topicId) {
  await ajax(draftEndpoint(topicId), { type: "DELETE" });
  return true;
}

// Per-topic debounce scheduler. The modal calls this on every
// meaningful state change; we coalesce rapid successive calls into a
// single PUT after `DRAFT_AUTOSAVE_DEBOUNCE_MS` of silence.
//
// `onStatus(status, error?)` is invoked with the DRAFT_STATUS strings
// above. The modal renders the small status indicator from those.
export class DraftAutosaver {
  constructor({
    topicId,
    onStatus,
    buildPayload,
    debounceMs = DRAFT_AUTOSAVE_DEBOUNCE_MS,
  }) {
    this.topicId = topicId;
    this.onStatus = onStatus || (() => {});
    this.buildPayload = buildPayload;
    this.debounceMs = debounceMs;
    this._timer = null;
    this._inflight = null;
    this._destroyed = false;
  }

  // Trigger a debounced save. Safe to call on every keystroke /
  // annotation change.
  schedule() {
    if (this._destroyed) {
      return;
    }
    if (this._timer) {
      clearTimeout(this._timer);
    }
    this._timer = setTimeout(() => {
      this._timer = null;
      this._flush();
    }, this.debounceMs);
  }

  // Force-flush any pending save, returning a promise. Called by
  // success paths (Post Critique, Edit in Composer) before they hand
  // off so we don't race a delete against an in-flight save.
  async flush() {
    if (this._timer) {
      clearTimeout(this._timer);
      this._timer = null;
    }
    return this._flush();
  }

  cancel() {
    if (this._timer) {
      clearTimeout(this._timer);
      this._timer = null;
    }
  }

  destroy() {
    this.cancel();
    this._destroyed = true;
  }

  async _flush() {
    if (this._destroyed) {
      return null;
    }
    const payload = this.buildPayload?.();
    if (!payload) {
      return null;
    }
    this.onStatus(DRAFT_STATUS.SAVING);
    try {
      const result = await saveDraft(this.topicId, payload);
      this._inflight = null;
      if (!this._destroyed) {
        this.onStatus(DRAFT_STATUS.SAVED);
      }
      return result;
    } catch (error) {
      this._inflight = null;
      // Record the actual save failure on the plugin error bus so the
      // diagnostic report carries the network response / message —
      // the modal's _onDraftSaveStatus only sees the DRAFT_STATUS
      // enum, not the underlying error.
      recordPluginError(
        "draft_autosave_save",
        error,
        {
          topicId: this.topicId,
          status: error?.jqXHR?.status ?? null,
        },
        "warn"
      );
      if (!this._destroyed) {
        this.onStatus(DRAFT_STATUS.ERROR, error);
      }
      return null;
    }
  }
}
