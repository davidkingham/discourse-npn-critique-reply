import Component from "@glimmer/component";
import { action } from "@ember/object";
import { next } from "@ember/runloop";
import { service } from "@ember/service";
import Composer from "discourse/models/composer";
import DButton from "discourse/ui-kit/d-button";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import { i18n } from "discourse-i18n";
import { shortDisplayName } from "../lib/npn-critique-reply-display-name";
import {
  isCombiningAuthor,
  mentionedUsernames,
  replyInProgress,
  unansweredCritics,
} from "../lib/npn-critique-reply-unanswered";
import { combineRepliesDeclined } from "./npn-combine-replies-message";

// Replacement for core's post-menu Reply button
// (frontend/discourse/app/components/post/menu/buttons/reply.gjs) that
// names the person being replied to: "Reply to Sarah" instead of "Reply".
//
// Members confused the per-post Reply buttons with the footer button that
// replies to the whole topic — both carried the same word and icon. Core
// hard-codes one shared string (`topic.reply.title`) for both, so the only
// way to tell them apart is to swap this button via the
// `post-menu-buttons` transformer (see the api-initializer).
//
// For everyone but the topic's author, everything except the label
// mirrors core: same classes, action, icon, title and aria-label, so
// themes keep working. The label also shows on phones (core hides it).
//
// For the AUTHOR of a critique topic it also steers toward one combined
// reply (`npn_critique_reply_combine_replies`):
//
//   - A reply is already being written → the button reads "Add Sarah to
//     reply" and inserts an @mention into that draft. Core would instead
//     silently re-point the whole reply at the newly clicked post.
//   - No reply open, but other critics are waiting too → reply as normal,
//     then raise a composer notice offering to add the others.
export default class NpnReplyToNameButton extends Component {
  static shouldRender(args) {
    return args.state.canCreatePost;
  }

  @service site;
  @service siteSettings;
  @service currentUser;
  @service composer;
  @service appEvents;
  @service toasts;

  // Core shows this label on desktop only. We show it on phones too: the
  // name is the whole point of the button, and without it the icon is
  // indistinguishable from the footer's reply button. The viewer's own
  // posts stay icon-only there — no name to show, and the row is already
  // full with the edit buttons.
  get showLabel() {
    return (
      this.args.showLabel ??
      (!this.args.state.isWikiMode &&
        (this.site.desktopView || !this.isOwnPost))
    );
  }

  get post() {
    return this.args.post;
  }

  get topic() {
    return this.post?.topic;
  }

  get displayName() {
    return shortDisplayName(this.post, this.siteSettings);
  }

  get isOwnPost() {
    return this.post?.user_id === this.currentUser?.id;
  }

  get combining() {
    return (
      !this.isOwnPost &&
      isCombiningAuthor({
        topic: this.topic,
        siteSettings: this.siteSettings,
        currentUser: this.currentUser,
      })
    );
  }

  // The in-progress reply this click should add to, or null. Clicking the
  // post the reply already targets is left to core (it just refocuses).
  get openReply() {
    if (!this.combining) {
      return null;
    }
    const model = replyInProgress(this.composer, this.topic);
    if (!model || model.post?.id === this.post.id) {
      return null;
    }
    return model;
  }

  get label() {
    // Replying to your own post: "Reply to David" reads oddly, keep core's
    // plain label.
    if (!this.displayName || this.isOwnPost) {
      return i18n("topic.reply.title");
    }
    if (this.openReply) {
      return i18n("npn_critique_reply.add_to_reply", {
        name: this.displayName,
      });
    }
    return i18n("npn_critique_reply.reply_to_name", {
      name: this.displayName,
    });
  }

  get icon() {
    return this.openReply ? "plus" : "reply";
  }

  @action
  reply() {
    const model = this.openReply;
    if (model) {
      return this._addToReply(model);
    }
    this._offerToCombine();
    return this.args.buttonActions.replyToPost();
  }

  // Add this person to the reply already being written, without
  // re-pointing it. No mention needed if that reply already answers them.
  _addToReply(model) {
    const username = this.post.username;
    const alreadyAddressed =
      model.post?.user_id === this.post.user_id ||
      mentionedUsernames(model.reply).has(username.toLowerCase());

    model.set("composeState", Composer.OPEN);
    if (!alreadyAddressed) {
      this.appEvents.trigger("composer:insert-block", `@${username} `);
    }
    this.toasts.success({
      duration: "short",
      data: {
        message: i18n(
          alreadyAddressed
            ? "npn_critique_reply.already_in_reply"
            : "npn_critique_reply.added_to_reply",
          { name: this.displayName }
        ),
      },
    });
  }

  // Starting a reply to one critic while others wait: once the composer
  // has opened on this post, offer to answer them all here.
  _offerToCombine() {
    if (!this.combining || combineRepliesDeclined(this.topic.id)) {
      return;
    }
    const post = this.post;
    const topicId = this.topic.id;
    const others = unansweredCritics(this.topic).filter(
      (critic) => critic.username !== post.username
    );
    if (others.length === 0) {
      return;
    }
    const { appEvents, composer } = this;
    appEvents.one("composer:opened", () => {
      // The open may have been for something else entirely (a draft
      // prompt, another topic) — only speak up for this reply.
      if (composer.model?.post?.id !== post.id) {
        return;
      }
      next(() =>
        appEvents.trigger("composer-messages:create", {
          id: "npn-combine-replies",
          templateName: "npn-combine-replies",
          extraClass: "npn-combine-replies-message",
          critics: others,
          topicId,
        })
      );
    });
  }

  <template>
    <DButton
      class={{dConcatClass
        "post-action-menu__reply"
        "reply"
        "npn-reply-to-name"
        (if this.openReply "npn-reply-to-name--add")
        (if this.showLabel "create fade-out")
      }}
      ...attributes
      @action={{this.reply}}
      @icon={{this.icon}}
      @translatedLabel={{if this.showLabel this.label}}
      @title="post.controls.reply"
      @translatedAriaLabel={{i18n
        "post.sr_reply_to"
        post_number=@post.post_number
        username=@post.username
      }}
    />
  </template>
}
