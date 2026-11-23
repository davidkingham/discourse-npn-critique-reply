import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import { isCritiqueEligible } from "../lib/npn-critique-reply-eligibility";
import { footerReplyLabelFor } from "../lib/npn-critique-reply-footer-labels";
import NpnCritiqueReplyModal, {
  CRITIQUE_POSTED_EVENT,
  DRAFT_CHANGED_EVENT,
} from "./modal/npn-critique-reply-modal";
import NpnCritiqueReplyStartButton from "./npn-critique-reply-start-button";

// The topic footer's reply area, rendered into
// `topic-footer-main-buttons-before-create`.
//
// Instead of sitting a "Start a Critique" button NEXT TO the native Reply
// button, this component owns the whole reply area and shows ONE primary
// action chosen by who is looking:
//
//   critique topic, not the author, hasn't posted here yet
//       → [Start a Critique]  "or leave a quick comment"
//   critique topic, not the author, already posted
//       → [Add another critique]  [Reply to topic]
//   everything else (the author, non-critique categories, people outside
//   the critique groups)
//       → [Reply to topic], or the category's label from
//         `npn_critique_reply_footer_reply_labels`
//
// The native Reply button is hidden by one CSS rule keyed on this
// component's wrapper (`:has(.npn-footer-reply)`), so if this component
// renders nothing the native button is still there. Core offers no hook to
// relabel or hide that button, hence CSS.
//
// On phones core hides every footer label, leaving icons only. The quick
// comment link therefore carries a reply icon that CSS shows only there,
// so a plain reply stays reachable on mobile.
//
// These buttons deliberately do NOT carry core's `create` class: older
// theme CSS targets `.btn-primary.create` in the footer to rewrite the
// label, and would rewrite ours too.
//
// `npn_critique_reply_footer_takeover` off → the previous behaviour: the
// standalone Start a Critique button beside the untouched native Reply.
export default class NpnCritiqueReplyFooterButtons extends Component {
  @service siteSettings;
  @service currentUser;
  @service modal;
  @service appEvents;
  @service router;

  // Per-session overrides for serializer values baked into the topic JSON
  // at page load, so the buttons update the moment a draft is saved or a
  // reply is posted. `null` → no override, use the serializer value.
  @tracked _hasDraftOverride = null;
  @tracked _postedOverride = null;

  constructor() {
    super(...arguments);
    this.appEvents.on(DRAFT_CHANGED_EVENT, this, "_onDraftChanged");
    this.appEvents.on(CRITIQUE_POSTED_EVENT, this, "_onCritiquePosted");
    this.appEvents.on("post:created", this, "_onPostCreated");
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.appEvents.off(DRAFT_CHANGED_EVENT, this, "_onDraftChanged");
    this.appEvents.off(CRITIQUE_POSTED_EVENT, this, "_onCritiquePosted");
    this.appEvents.off("post:created", this, "_onPostCreated");
  }

  _onDraftChanged({ topicId, hasDraft } = {}) {
    if (topicId && topicId === this.topic?.id) {
      this._hasDraftOverride = !!hasDraft;
    }
  }

  _onCritiquePosted({ topicId } = {}) {
    if (topicId && topicId === this.topic?.id) {
      this._postedOverride = true;
    }
  }

  // Core fires this after the normal composer creates a post.
  _onPostCreated(post) {
    if (post?.topic_id && post.topic_id === this.topic?.id) {
      this._postedOverride = true;
    }
  }

  get topic() {
    return this.args.outletArgs?.topic;
  }

  // The outlet also renders in footers where core hides its own Reply
  // button (the nested view passes `showCreate=false`). Only take over on
  // the regular topic route.
  get takeover() {
    return (
      this.siteSettings.npn_critique_reply_enabled &&
      this.siteSettings.npn_critique_reply_footer_takeover &&
      this.router.currentRouteName?.startsWith("topic.")
    );
  }

  get canReply() {
    return !!this.topic?.details?.can_create_post;
  }

  get critiqueEligible() {
    return isCritiqueEligible({
      topic: this.topic,
      siteSettings: this.siteSettings,
      currentUser: this.currentUser,
    });
  }

  get isAuthor() {
    const authorId = this.topic?.user_id ?? this.topic?.details?.created_by?.id;
    return !!authorId && authorId === this.currentUser?.id;
  }

  // Core's `posted` flag: has the viewer posted in this topic at all.
  get hasPosted() {
    if (this._postedOverride !== null) {
      return this._postedOverride;
    }
    return !!this.topic?.posted;
  }

  get hasDraft() {
    if (this._hasDraftOverride !== null) {
      return this._hasDraftOverride;
    }
    return !!this.topic?.npn_critique_reply_has_draft;
  }

  // "critique-first" | "reply-first" | "reply-only"
  get mode() {
    if (!this.critiqueEligible || this.isAuthor) {
      return "reply-only";
    }
    return this.hasPosted ? "reply-first" : "critique-first";
  }

  get critiqueFirst() {
    return this.mode === "critique-first";
  }

  get replyFirst() {
    return this.mode === "reply-first";
  }

  get startLabel() {
    if (this.hasDraft) {
      return i18n("npn_critique_reply.resume_button");
    }
    const override = this.siteSettings.npn_critique_reply_button_label;
    return override && override.trim().length > 0
      ? override
      : i18n("npn_critique_reply.start_button");
  }

  get startTitle() {
    return this.hasDraft
      ? i18n("npn_critique_reply.resume_button_title")
      : i18n("npn_critique_reply.start_button_title");
  }

  get anotherLabel() {
    return this.hasDraft
      ? i18n("npn_critique_reply.resume_button")
      : i18n("npn_critique_reply.footer.another_critique");
  }

  get replyLabel() {
    return (
      footerReplyLabelFor(
        this.topic?.category,
        this.siteSettings.npn_critique_reply_footer_reply_labels
      ) ?? i18n("npn_critique_reply.footer.reply_to_topic")
    );
  }

  @action
  async startCritique() {
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
        // Snapshot at click-time so a topic re-fetch mid-interaction can't
        // shift the displayed request out from under the user.
        metadata: topic?.npn_critique_reply ?? null,
      },
    });
  }

  // Same path as the native footer Reply button and the `shift+r`
  // shortcut: the topic controller's `replyToPost()` with no post.
  @action
  replyToTopic() {
    getOwner(this).lookup("controller:topic")?.replyToPost();
  }

  <template>
    {{#if this.takeover}}
      {{#if this.canReply}}
        <span class="npn-footer-reply npn-footer-reply--{{this.mode}}">
          {{#if this.critiqueFirst}}
            <DButton
              class="btn-primary topic-footer-button npn-footer-reply__btn npn-critique-reply-start"
              @action={{this.startCritique}}
              @icon="far-pen-to-square"
              @translatedLabel={{this.startLabel}}
              @translatedTitle={{this.startTitle}}
            />
            <DButton
              class="btn-transparent npn-footer-reply__quick"
              @action={{this.replyToTopic}}
              @icon="reply"
              @label="npn_critique_reply.footer.quick_comment"
              @title="npn_critique_reply.footer.quick_comment_title"
            />
          {{else}}
            {{#if this.replyFirst}}
              <DButton
                class="btn-default topic-footer-button npn-footer-reply__btn npn-critique-reply-start"
                @action={{this.startCritique}}
                @icon="far-pen-to-square"
                @translatedLabel={{this.anotherLabel}}
                @translatedTitle={{this.startTitle}}
              />
            {{/if}}
            <DButton
              class="btn-primary topic-footer-button npn-footer-reply__btn npn-footer-reply__reply"
              @action={{this.replyToTopic}}
              @icon="reply"
              @translatedLabel={{this.replyLabel}}
              @title="topic.reply.help"
            />
          {{/if}}
        </span>
      {{/if}}
    {{else}}
      <NpnCritiqueReplyStartButton @outletArgs={{@outletArgs}} />
    {{/if}}
  </template>
}
