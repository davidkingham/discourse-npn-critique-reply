import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { isCritiqueEligible } from "../lib/npn-critique-reply-eligibility";
import NpnCritiqueReplyModal from "./modal/npn-critique-reply-modal";

// "Copy to Critique" — a button rendered into the post text-selection
// toolbar (next to native Quote / Copy Quote) via
// `renderAfterWrapperOutlet("post-text-buttons", …)`. The native quote
// buttons are untouched; this just adds a critique-specific path.
//
// On click it builds the same attributed [quote=…] markdown the native
// Copy Quote produces, then opens (or resumes) the Critique Workspace with
// the quote pre-inserted — replacing the old clipboard-import flow.
export default class NpnCopyToCritiqueButton extends Component {
  @service modal;
  @service siteSettings;
  @service currentUser;

  // The toolbar's data bag — { topic, quoteState, buildQuote, hideToolbar,
  // … } — forwarded through the wrapper outlet's @outletArgs.
  get data() {
    return this.args.outletArgs?.data;
  }

  get topic() {
    return this.data?.topic;
  }

  get eligible() {
    return isCritiqueEligible({
      topic: this.topic,
      siteSettings: this.siteSettings,
      currentUser: this.currentUser,
    });
  }

  @action
  async copyToCritique() {
    const data = this.data;
    const topic = this.topic;
    if (!data || !topic) {
      return;
    }
    let quote;
    try {
      // Resolves to the attributed
      // [quote="name, post:N, topic:T, full:true"]…[/quote] markdown.
      quote = await data.buildQuote();
    } catch {
      return;
    }
    // Dismiss the selection toolbar before the modal opens.
    await data.hideToolbar?.();
    if (!quote) {
      return;
    }
    this.modal.show(NpnCritiqueReplyModal, {
      model: {
        topic,
        metadata: topic.npn_critique_reply ?? null,
        initialQuote: quote,
      },
    });
  }

  <template>
    {{#if this.eligible}}
      <DButton
        @icon="far-pen-to-square"
        @label="npn_critique_reply.copy_to_critique.label"
        @title="npn_critique_reply.copy_to_critique.title"
        class="btn-flat npn-copy-to-critique"
        @action={{this.copyToCritique}}
      />
    {{/if}}
  </template>
}
