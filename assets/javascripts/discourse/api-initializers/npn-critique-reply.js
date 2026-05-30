import { apiInitializer } from "discourse/lib/api";
import NpnCritiqueReplyInvitationPanel from "../components/npn-critique-reply-invitation-panel";
import NpnCritiqueReplyStartButton from "../components/npn-critique-reply-start-button";

// Wires up three things:
//
// 1. The "Start a Critique" secondary button rendered immediately to the left
//    of the native primary Reply button in the topic footer. We use the
//    upgrade-safe `topic-footer-main-buttons-before-create` plugin outlet
//    (the outlet exists in core specifically so plugins can sit a custom
//    action next to Reply without re-skinning the footer). The component
//    owns all per-topic eligibility (settings, category, group, metadata,
//    reply permission). The native Reply button is untouched and remains the
//    visually primary action.
//
// 2. A compact "Start a thoughtful critique" invitation panel rendered via
//    `api.renderAfterWrapperOutlet("post-article", …)` — `post-article` is
//    a WRAPPER outlet, so plain `renderInOutlet` would replace the
//    `<article>` element (and along with it the post content + every
//    reply in the stream). The wrapper-after API renders the connector
//    immediately after the article without disturbing the wrapped
//    content. The component then filters via `post.post_number === 1`
//    so the panel only renders below the OP. Gated separately via
//    `npn_critique_reply_show_below_op` so admins can dial each entry
//    point on/off independently of the footer button.
//
// 3. A staff-only, debug-only console log of the serialized
//    `npn_critique_reply` metadata on each topic view. Pure verification
//    aid — no DOM, no UI. Gated on `npn_critique_reply_debug_enabled` AND
//    staff role.

export default apiInitializer((api) => {
  api.renderInOutlet(
    "topic-footer-main-buttons-before-create",
    NpnCritiqueReplyStartButton
  );
  api.renderAfterWrapperOutlet(
    "post-article",
    NpnCritiqueReplyInvitationPanel
  );

  const siteSettings = api.container.lookup("service:site-settings");
  const currentUser = api.container.lookup("service:current-user");

  if (!siteSettings?.npn_critique_reply_enabled) {
    return;
  }
  if (!siteSettings?.npn_critique_reply_debug_enabled) {
    return;
  }
  if (!currentUser?.staff) {
    return;
  }

  api.onPageChange(() => {
    const topicController = api.container.lookup("controller:topic");
    const topic = topicController?.model;
    if (!topic) {
      return;
    }

    const metadata =
      topic.get?.("npn_critique_reply") ?? topic.npn_critique_reply;
    if (!metadata) {
      return;
    }

    // eslint-disable-next-line no-console
    console.info("[npn-critique-reply] topic metadata", {
      topicId: topic.id,
      metadata,
    });
  });
});
