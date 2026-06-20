import { apiInitializer } from "discourse/lib/api";
import { buildQuote } from "discourse/lib/quote";
import { i18n } from "discourse-i18n";
import NpnCritiqueDock from "../components/npn-critique-dock";
import NpnCritiqueReplyInvitationPanel from "../components/npn-critique-reply-invitation-panel";
import NpnCritiqueReplyStartButton from "../components/npn-critique-reply-start-button";
import NpnEditVisualCritiqueButton from "../components/npn-edit-visual-critique-button";
import NpnCritiqueReplyModal from "../components/modal/npn-critique-reply-modal";
import { decorateCriticueReplyAnnotations } from "../lib/npn-critique-reply-annotation-badges";
import { isCritiqueEligible } from "../lib/npn-critique-reply-eligibility";

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
  api.renderAfterWrapperOutlet("post-article", NpnCritiqueReplyInvitationPanel);

  // Override the native Quote button (and the Ctrl+Q shortcut) so a quote
  // can flow into the Critique Workspace instead of the normal composer.
  // Core's topic controller `selectText()` fires `topic:quote-post`
  // ({ post, buffer, opts, handled }) BEFORE inserting into any composer;
  // setting `handled = true` short-circuits the native path. Both the
  // toolbar Quote button and Ctrl+Q route through `selectText()`, so this
  // single listener covers both. This replaces the old standalone
  // "Copy to Critique" toolbar button.
  //
  // Branching:
  //   1. Workspace OPEN on this topic → insert the quote into it.
  //   2. A normal reply composer already open → do nothing (native: the
  //      quote drops into that reply).
  //   3. Nothing open, critique-eligible topic → ask via a small dialog:
  //      "Start a Critique" (open the workspace pre-filled) or "Quote in a
  //      reply" (re-run native quoting behind a one-shot bypass).
  //   4. Nothing open, non-eligible topic → native.
  const workspace = api.container.lookup("service:npn-critique-workspace");
  const quoteSettings = api.container.lookup("service:site-settings");
  const quoteCurrentUser = api.container.lookup("service:current-user");
  // Re-entrancy guard: when the user picks "Quote in a reply" we re-call
  // `selectText()`, which re-fires `topic:quote-post`. This flag makes that
  // second pass fall straight through to native quoting.
  let quoteBypass = false;

  api.onAppEvent("topic:quote-post", (event) => {
    if (quoteBypass) {
      quoteBypass = false;
      return;
    }
    if (!event || event.handled) {
      return;
    }
    const markdown = buildQuote(event.post, event.buffer, event.opts);
    if (!markdown) {
      return;
    }
    const topicId = event.post?.topic_id;

    // (1) Open workspace on this topic.
    if (workspace?.insertQuote(markdown, topicId)) {
      event.handled = true;
      return;
    }

    // (2) A normal composer is already open / in draft → native behavior.
    const composer = api.container.lookup("service:composer");
    if (composer?.model) {
      return;
    }

    // (3) Nothing open: only intervene on critique-eligible topics.
    const topic =
      event.post?.topic ?? api.container.lookup("controller:topic")?.model;
    if (
      !isCritiqueEligible({
        topic,
        siteSettings: quoteSettings,
        currentUser: quoteCurrentUser,
      })
    ) {
      return;
    }

    event.handled = true;
    const dialog = api.container.lookup("service:dialog");
    const modal = api.container.lookup("service:modal");
    dialog.alert({
      title: i18n("npn_critique_reply.quote_choice.title"),
      message: i18n("npn_critique_reply.quote_choice.message"),
      buttons: [
        {
          label: i18n("npn_critique_reply.quote_choice.start"),
          class: "btn-primary",
          action: () => {
            // Fire-and-forget: a block body (not an arrow expression) so
            // we DON'T return modal.show()'s promise. The dialog's button
            // handler `await`s the action before closing, and modal.show()
            // resolves only when the workspace closes — returning it would
            // leave this dialog open behind the workspace.
            modal.show(NpnCritiqueReplyModal, {
              model: {
                topic,
                metadata: topic?.npn_critique_reply ?? null,
                initialQuote: markdown,
              },
            });
          },
        },
        {
          label: i18n("npn_critique_reply.quote_choice.reply"),
          action: () => {
            // Re-run native quoting; the bypass makes our handler fall
            // through on the re-fired event.
            quoteBypass = true;
            api.container.lookup("controller:topic")?.selectText();
          },
        },
      ],
    });
  });

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
