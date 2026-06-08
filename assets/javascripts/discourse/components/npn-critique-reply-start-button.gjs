import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import NpnCritiqueReplyModal, {
  DRAFT_CHANGED_EVENT,
} from "./modal/npn-critique-reply-modal";

// Pipe-separated id lists (Discourse `list` / `group_list` settings serialize
// as "1|2|3"). Positive integers only; tolerates empty/invalid input.
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

// Renders into `topic-footer-main-buttons-before-create` (next to the native
// Reply button). The component owns per-topic eligibility, the icon/label,
// and the action that opens the Step 3 Critique Helper modal.
export default class NpnCritiqueReplyStartButton extends Component {
  @service siteSettings;
  @service currentUser;
  @service modal;
  @service appEvents;

  // Per-session override for the serializer-provided
  // `topic.npn_critique_reply_has_draft`. The modal emits a
  // DRAFT_CHANGED_EVENT whenever it creates or clears a draft, and we
  // flip this flag so the button label updates without waiting for a
  // page navigation. `null` means "no override — fall back to the
  // serializer value".
  @tracked _hasDraftOverride = null;

  constructor() {
    super(...arguments);
    this.appEvents.on(DRAFT_CHANGED_EVENT, this, "_onDraftChanged");
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.appEvents.off(DRAFT_CHANGED_EVENT, this, "_onDraftChanged");
  }

  _onDraftChanged({ topicId, hasDraft } = {}) {
    if (topicId && topicId === this.topic?.id) {
      this._hasDraftOverride = !!hasDraft;
    }
  }

  get topic() {
    return this.args.outletArgs?.topic;
  }

  get eligible() {
    const topic = this.topic;
    if (!topic) {
      return false;
    }

    if (!this.siteSettings.npn_critique_reply_enabled) {
      return false;
    }
    // The `npn_critique_reply_show_below_op` setting used to also
    // gate this footer button, but it's been reclaimed by the
    // below-OP invitation panel (its original intended purpose). The
    // footer button now follows just the standard eligibility checks
    // — admins can dial the panel off independently without losing
    // the footer entry point.

    if (topic.closed || topic.archived) {
      return false;
    }
    if (!topic.details?.can_create_post) {
      return false;
    }

    const enabledCategoryIds = parseIdList(
      this.siteSettings.npn_critique_reply_enabled_category_ids
    );
    if (enabledCategoryIds.length === 0) {
      if (!topic.npn_critique_reply) {
        return false;
      }
    } else if (!enabledCategoryIds.includes(topic.category_id)) {
      return false;
    }

    const allowedGroupIds = parseIdList(
      this.siteSettings.npn_critique_reply_allowed_group_ids
    );
    if (allowedGroupIds.length > 0 && !this.currentUser?.staff) {
      const userGroupIds = (this.currentUser?.groups ?? []).map((g) => g.id);
      if (!allowedGroupIds.some((id) => userGroupIds.includes(id))) {
        return false;
      }
    }

    return true;
  }

  // Flipped by the topic serializer when there's a saved server draft
  // for the current user on this topic (see plugin.rb after_initialize).
  // `_hasDraftOverride` lets the modal force a value at runtime when it
  // saves or clears a draft, so the label flips without a page
  // navigation. Override wins when set; otherwise fall back to the
  // serializer value baked into topic JSON at page load.
  get hasDraft() {
    if (this._hasDraftOverride !== null) {
      return this._hasDraftOverride;
    }
    return !!this.topic?.npn_critique_reply_has_draft;
  }

  get label() {
    if (this.hasDraft) {
      return i18n("npn_critique_reply.resume_button");
    }
    const override = this.siteSettings.npn_critique_reply_button_label;
    return override && override.trim().length > 0
      ? override
      : i18n("npn_critique_reply.start_button");
  }

  get title() {
    return this.hasDraft
      ? i18n("npn_critique_reply.resume_button_title")
      : i18n("npn_critique_reply.start_button_title");
  }

  @action
  async start() {
    const topic = this.topic;
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] opening modal", {
        topicId: topic?.id,
        metadata: topic?.npn_critique_reply,
      });
    }

    await this.modal.show(NpnCritiqueReplyModal, {
      model: {
        topic,
        // Capture the metadata at click-time. The modal renders off this
        // snapshot so a topic re-fetch mid-interaction can't shift the
        // displayed request out from under the user.
        metadata: topic?.npn_critique_reply ?? null,
      },
    });
  }

  <template>
    {{#if this.eligible}}
      <DButton
        class="btn-primary topic-footer-button npn-critique-reply-start"
        @action={{this.start}}
        @icon="far-pen-to-square"
        @translatedLabel={{this.label}}
        @translatedTitle={{this.title}}
      />
    {{/if}}
  </template>
}
