import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import ComposerTipCloseButton from "discourse/components/composer-tip-close-button";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import { shortDisplayName } from "../lib/npn-critique-reply-display-name";
import { mentionBlock } from "../lib/npn-critique-reply-unanswered";

// Topics where the author said "no thanks" this session — don't ask again.
const declinedTopicIds = new Set();

export function combineRepliesDeclined(topicId) {
  return declinedTopicIds.has(topicId);
}

// Composer notice shown to a topic author who starts a reply to ONE
// critique while other critics are still waiting: offer to answer them
// all in this post, so each person gets one notification instead of the
// author posting a separate reply under every critique.
//
// Registered under the `npn-combine-replies` template name through the
// `composer-message-components` transformer and raised with the
// `composer-messages:create` app event (see the api-initializer and
// npn-reply-to-name-button.gjs). `@message.critics` is the list of other
// waiting critics, `[{ username, name }]`.
export default class NpnCombineRepliesMessage extends Component {
  @service appEvents;
  @service composer;
  @service siteSettings;

  get critics() {
    return this.args.message.critics ?? [];
  }

  get body() {
    if (this.critics.length === 1) {
      return i18n("npn_critique_reply.combine_replies.body_one", {
        name: shortDisplayName(this.critics[0], this.siteSettings),
      });
    }
    return i18n("npn_critique_reply.combine_replies.body_many", {
      count: this.critics.length,
    });
  }

  @action
  addEveryone() {
    const block = mentionBlock(this.critics, this.composer.model?.reply ?? "");
    if (block) {
      this.appEvents.trigger("composer:insert-block", block);
    }
    this.args.closeMessage(this.args.message);
  }

  @action
  decline() {
    const topicId = this.args.message.topicId;
    if (topicId) {
      declinedTopicIds.add(topicId);
    }
    this.args.closeMessage(this.args.message);
  }

  <template>
    <ComposerTipCloseButton @action={{fn @closeMessage @message}} />

    <div class="composer-popup__content npn-combine-replies">
      <h3>{{i18n "npn_critique_reply.combine_replies.title"}}</h3>
      <p>{{this.body}}</p>
      <p>{{i18n "npn_critique_reply.combine_replies.why"}}</p>

      <DButton
        class="btn-primary npn-combine-replies__add"
        @action={{this.addEveryone}}
        @icon="reply-all"
        @label="npn_critique_reply.combine_replies.add"
      />
      <DButton
        class="btn-transparent npn-combine-replies__decline"
        @action={{this.decline}}
        @label="npn_critique_reply.combine_replies.decline"
      />
    </div>
  </template>
}
