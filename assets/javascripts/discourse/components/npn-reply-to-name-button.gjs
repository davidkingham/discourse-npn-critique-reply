import Component from "@glimmer/component";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import { i18n } from "discourse-i18n";
import { shortDisplayName } from "../lib/npn-critique-reply-display-name";

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
// Everything except the label mirrors core: same classes, action, icon,
// title, aria-label and show-label rule, so themes and the mobile
// icon-only layout keep working.
export default class NpnReplyToNameButton extends Component {
  static shouldRender(args) {
    return args.state.canCreatePost;
  }

  @service site;
  @service siteSettings;
  @service currentUser;

  get showLabel() {
    return (
      this.args.showLabel ??
      (this.site.desktopView && !this.args.state.isWikiMode)
    );
  }

  get displayName() {
    return shortDisplayName(this.args.post, this.siteSettings);
  }

  get label() {
    const post = this.args.post;
    // Replying to your own post: "Reply to David" reads oddly, keep core's
    // plain label.
    if (!this.displayName || post?.user_id === this.currentUser?.id) {
      return i18n("topic.reply.title");
    }
    return i18n("npn_critique_reply.reply_to_name", {
      name: this.displayName,
    });
  }

  <template>
    <DButton
      class={{dConcatClass
        "post-action-menu__reply"
        "reply"
        "npn-reply-to-name"
        (if this.showLabel "create fade-out")
      }}
      ...attributes
      @action={{@buttonActions.replyToPost}}
      @icon="reply"
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
