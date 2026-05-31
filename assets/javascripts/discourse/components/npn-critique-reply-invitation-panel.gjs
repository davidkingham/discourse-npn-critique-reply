import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import DButton from "discourse/ui-kit/d-button";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { and } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import NpnCritiqueReplyModal, {
  DRAFT_CHANGED_EVENT,
} from "./modal/npn-critique-reply-modal";

// Pipe-separated id lists ("1|2|3"). Mirrors the helper in
// npn-critique-reply-start-button.gjs — kept inline so the two
// entry-point components are independently auditable for upgrades.
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

// Renders into the per-post `post-article` outlet (via the wrapper-
// after sub-outlet in the api-initializer), filtered to the first
// post (the OP) via the `isFirstPost` getter. That places the panel
// directly below the OP's article and above the first reply.
//
// Single-action invitation: one primary button to open the critique
// workspace. The native footer Reply button (and the existing
// "Start a Critique" footer button next to it) cover the other
// reply paths — keeping this panel focused on one job avoids
// competing with the OP photo.
export default class NpnCritiqueReplyInvitationPanel extends Component {
  @service siteSettings;
  @service currentUser;
  @service modal;
  @service appEvents;

  // Per-session override for the serializer-provided
  // `topic.npn_critique_reply_has_draft`. See the matching field on
  // npn-critique-reply-start-button.gjs for full rationale.
  @tracked _hasDraftOverride = null;

  constructor() {
    super(...arguments);
    this.appEvents.on(DRAFT_CHANGED_EVENT, this, "_onDraftChanged");
    if (this.siteSettings?.npn_critique_reply_debug_enabled) {
      const t = this.topic;
      const p = this.args.outletArgs?.post;
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] invitation-panel:mount", {
        postNumber: p?.post_number,
        isFirstPost: this.isFirstPost,
        resolvedTopic: t
          ? {
              id: t.id,
              title: t.title,
              closed: t.closed,
              archived: t.archived,
              canCreatePost: t.details?.can_create_post,
              categoryId: t.category_id,
              hasMetadata: !!t.npn_critique_reply,
            }
          : null,
        eligible: this.eligible,
        settings: {
          enabled: this.siteSettings.npn_critique_reply_enabled,
          showBelowOp: this.siteSettings.npn_critique_reply_show_below_op,
          enabledCategoryIds:
            this.siteSettings.npn_critique_reply_enabled_category_ids,
          allowedGroupIds:
            this.siteSettings.npn_critique_reply_allowed_group_ids,
        },
      });
    }
  }

  // The `post-article` outlet fires once per post in the stream. We
  // only ever want to render below the OP — every reply gets the same
  // outlet call but skips rendering here.
  get isFirstPost() {
    return this.args.outletArgs?.post?.post_number === 1;
  }

  get topic() {
    // post-article outlet args: { post, actions, decoratorState, ... }
    // The post carries a topic reference. Fallback through `topic` /
    // `model` keys so a future Discourse upgrade that reshapes the
    // outlet args still resolves correctly.
    return (
      this.args.outletArgs?.post?.topic ??
      this.args.outletArgs?.topic ??
      this.args.outletArgs?.model ??
      null
    );
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

  // Flipped by the topic serializer when there's a saved server draft
  // for the current user on this topic (see plugin.rb after_initialize).
  // `_hasDraftOverride` lets the modal force a value at runtime when it
  // saves or clears a draft. Override wins when set; otherwise fall
  // back to the serializer value.
  get hasDraft() {
    if (this._hasDraftOverride !== null) {
      return this._hasDraftOverride;
    }
    return !!this.topic?.npn_critique_reply_has_draft;
  }

  get titleKey() {
    return this.hasDraft
      ? "npn_critique_reply.invitation_panel.resume_title"
      : "npn_critique_reply.invitation_panel.title";
  }

  get descriptionKey() {
    return this.hasDraft
      ? "npn_critique_reply.invitation_panel.resume_description"
      : "npn_critique_reply.invitation_panel.description";
  }

  get ariaLabelKey() {
    return this.hasDraft
      ? "npn_critique_reply.invitation_panel.resume_aria_label"
      : "npn_critique_reply.invitation_panel.aria_label";
  }

  get actionLabelKey() {
    return this.hasDraft
      ? "npn_critique_reply.resume_button"
      : "npn_critique_reply.start_button";
  }

  get eligible() {
    const topic = this.topic;
    if (!topic) {
      return false;
    }
    if (!this.siteSettings.npn_critique_reply_enabled) {
      return false;
    }
    // Panel-specific kill-switch. Independent of the footer button so
    // admins can dial each entry point on/off separately.
    if (!this.siteSettings.npn_critique_reply_show_below_op) {
      return false;
    }
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
      // Empty list → only topics whose serializer surfaced
      // `npn_critique_reply` metadata count as critique topics.
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

  @action
  async startCritique() {
    const topic = this.topic;
    if (!topic) {
      return;
    }
    if (this.siteSettings.npn_critique_reply_debug_enabled) {
      // eslint-disable-next-line no-console
      console.info("[npn-critique-reply] invitation-panel:start", {
        topicId: topic?.id,
      });
    }
    await this.modal.show(NpnCritiqueReplyModal, {
      model: {
        topic,
        metadata: topic?.npn_critique_reply ?? null,
      },
    });
  }

  <template>
    {{#if (and this.isFirstPost this.eligible)}}
      <aside
        class="npn-critique-reply-invitation-panel
          {{if this.hasDraft 'npn-critique-reply-invitation-panel--resume'}}"
        role="complementary"
        aria-label={{i18n this.ariaLabelKey}}
      >
        {{! Decorative icon — meaning is in the adjacent title. The
            far-pen-to-square glyph matches the footer "Start a
            Critique" button so the visual identity reads consistent
            across the two entry points. }}
        <span
          class="npn-critique-reply-invitation-panel__icon"
          aria-hidden="true"
        >
          {{dIcon "far-pen-to-square"}}
        </span>
        <div class="npn-critique-reply-invitation-panel__content">
          <h3 class="npn-critique-reply-invitation-panel__title">
            {{i18n this.titleKey}}
          </h3>
          <p class="npn-critique-reply-invitation-panel__description">
            {{i18n this.descriptionKey}}
          </p>
        </div>
        <DButton
          class="btn-primary npn-critique-reply-invitation-panel__start"
          @action={{this.startCritique}}
          @label={{this.actionLabelKey}}
        />
      </aside>
    {{/if}}
  </template>
}
