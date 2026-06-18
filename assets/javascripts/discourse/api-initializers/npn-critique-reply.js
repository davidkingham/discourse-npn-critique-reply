import { apiInitializer } from "discourse/lib/api";
import NpnCritiqueDock from "../components/npn-critique-dock";
import NpnCritiqueReplyInvitationPanel from "../components/npn-critique-reply-invitation-panel";
import NpnCritiqueReplyStartButton from "../components/npn-critique-reply-start-button";
import NpnEditVisualCritiqueButton from "../components/npn-edit-visual-critique-button";
import { decorateCriticueReplyAnnotations } from "../lib/npn-critique-reply-annotation-badges";

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
// 3. The "Edit Visual Critique" post-menu button, registered via
//    `api.registerValueTransformer("post-menu-buttons", …)`. This is
//    the documented Glimmer-friendly replacement for the now-
//    decommissioned `api.addPostMenuButton` hook (see
//    `discourse/app/lib/plugin-api.gjs` for the decommission notice
//    and `discourse/app/components/post/menu.gjs` for the
//    transformer call). The earlier widget-API attempt crashed app
//    boot — this transformer integrates with the new Glimmer post
//    component without touching widget internals. Visibility is
//    gated twice: once at the DAG level here (no entry added when
//    the post has no visual notes or the viewer can't edit), and
//    once via `shouldRender` inside the button component itself.
//
// 4. Inline annotation-badge decorator for cooked critique posts.
//    Walks the post's cooked DOM after Discourse renders the
//    markdown, finds plain text references like [1], [A1], [S1],
//    [D1], [R1], [E1] inside paragraphs/list items, and rewrites
//    them as small styled <span> badges that visually match the
//    annotations on the visual-notes image. Source of truth for
//    which labels are valid is the post's `npn_visual_notes`
//    payload; references not present in the payload stay as plain
//    text. Code/pre/anchor descendants are skipped so unrelated
//    `[1]`s in unrelated content are left alone. See
//    npn-critique-reply-annotation-badges.js for the walker.
//
// 5. A staff-only, debug-only console log of the serialized
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

  // Persistent "Critique in progress" dock for the minimize-to-dock flow.
  // `below-footer` is an application-level outlet (always rendered, every
  // route), so the single dock instance lives for the session and shows
  // itself only when a critique is minimized on the topic being viewed.
  api.renderInOutlet("below-footer", NpnCritiqueDock);

  api.decorateCookedElement(decorateCriticueReplyAnnotations, {
    id: "npn-critique-reply-annotation-badges",
    onlyStream: true,
  });

  // Edit Visual Critique post-menu button.
  //
  // Transformer shape (verified against current Discourse core,
  // `frontend/discourse/app/components/post/menu.gjs`):
  //   ({ value: dag, context: { post, buttonKeys, … } }) => …
  // — `value` is the DAG of menu buttons keyed by
  // `buttonKeys.{REPLY,EDIT,SHOW_MORE,…}`; `context.post` is the
  // post model for the post whose menu is being built.
  //
  // `dag.add(key, Component, { after: [buttonKeys.EDIT] })` slots
  // our entry immediately after the standard Edit button so the two
  // edit affordances sit next to each other. The button only joins
  // the DAG when the post has visual notes AND the viewer can edit
  // — anonymous viewers, posts without visual notes, and viewers
  // without edit permission all skip the `dag.add` call entirely.
  // The component's `shouldRender` repeats the check so per-render
  // state changes (e.g. `can_edit` flipping) hide the button cleanly.
  api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag, context: { post, buttonKeys } }) => {
      // Show for posts carrying EITHER visual-notes metadata OR a
      // processing-example payload — both flavours are
      // plugin-created replies that should round-trip through the
      // workspace modal. The label stays "Edit Visual Critique"
      // (intentional naming continuity even though "visual" no
      // longer strictly matches example-only posts).
      if (!post?.npn_visual_notes && !post?.npn_processing_example) {
        return;
      }
      if (!post?.can_edit) {
        return;
      }
      dag.add("npn-edit-visual-critique", NpnEditVisualCritiqueButton, {
        after: [buttonKeys.EDIT],
      });
    }
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
