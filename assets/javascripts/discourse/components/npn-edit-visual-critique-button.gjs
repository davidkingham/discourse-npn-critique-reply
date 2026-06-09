import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import NpnCritiqueReplyModal from "./modal/npn-critique-reply-modal";

// Post-menu button: "Edit Visual Critique".
//
// Glimmer-native button component registered via the
// `post-menu-buttons` value transformer (see
// assets/javascripts/discourse/api-initializers/npn-critique-reply.js).
// Opens the critique workspace modal in edit mode, wired through
// the existing server-side update endpoint.
//
// Visibility — two layers (intentional belt-and-braces):
//   1. Transformer-level: the api-initializer only adds this button
//      to the DAG when `post.npn_visual_notes` is present and the
//      viewer can edit. That keeps the button out of the menu's
//      button list entirely for posts that don't qualify.
//   2. `shouldRender` on the component: the post-menu re-evaluates
//      this per render, so if a state change later removes
//      eligibility (e.g. the post's `can_edit` flips) the button
//      hides cleanly.
export default class NpnEditVisualCritiqueButton extends Component {
  static shouldRender(args) {
    const post = args?.post;
    if (!post) {
      return false;
    }
    // Either flavour of plugin-created reply qualifies — posts with
    // visual notes, with a processing example, or with both. Keeps
    // the button in sync with the transformer-level gate in the
    // api-initializer.
    if (!post.npn_visual_notes && !post.npn_processing_example) {
      return false;
    }
    // `can_edit` is Discourse's standard post-level edit flag —
    // true for the author and for staff under default permissions.
    // The server endpoint (PUT /npn-critique-reply/posts/:id/critique)
    // checks again, so this is a UI-level convenience gate.
    if (!post.can_edit) {
      return false;
    }
    return true;
  }

  @service modal;

  @action
  openEditCritiqueModal() {
    const post = this.args.post;
    const topic = post?.topic;
    if (!post || !topic) {
      return;
    }
    this.modal.show(NpnCritiqueReplyModal, {
      model: {
        topic,
        // Critique metadata for the workspace's request-summary
        // panel. Falls back to whatever `topic.npn_critique_reply`
        // resolves to via either getter shape.
        metadata:
          topic.get?.("npn_critique_reply") ?? topic.npn_critique_reply ?? null,
        // Wires the modal into edit mode — see `editingPost` getter
        // and `_initializeFromPost()` in the modal.
        editingPost: post,
      },
    });
  }

  <template>
    <DButton
      class="post-action-menu__npn-edit-critique"
      ...attributes
      @action={{this.openEditCritiqueModal}}
      @icon="far-pen-to-square"
      @label="npn_critique_reply.modal.edit_critique_button"
      @title="npn_critique_reply.modal.edit_critique_button_title"
    />
  </template>
}
