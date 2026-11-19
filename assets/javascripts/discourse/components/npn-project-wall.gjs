import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

// The left pane of the critique workspace for a PROJECT critique: the whole
// body of work instead of a single reference image.
//
// - Every image at true proportions with its number; alternates below.
// - Click an original → open it on its own with the visual tools
//   (@onOpenImage); click an alternate → view it large (@onView…).
// - "View the project" steps through the images full-screen, in order.
// - "Suggest a hang" (or a sequence / selection, depending on the
//   photographer's presentation goal) opens the critic's own version of
//   the project — order, ranking, what's left out, alternates brought in —
//   which goes into the critique as one image.
// - The photographer's requested feedback types and presentation goal are
//   pinned at the top, and the matching tools are emphasized.
//
// The image data and the suggest tool come from discourse-npn-submissions
// (npn-sequence-builder service), passed in by the modal.
export default class NpnProjectWall extends Component {
  get images() {
    return this.args.images ?? {};
  }

  get feedbackTypes() {
    return this.images.feedback_types ?? [];
  }

  get requested() {
    return new Set(this.feedbackTypes);
  }

  get feedbackTypeLabels() {
    return this.feedbackTypes.map((type) =>
      i18n(`npn_critique_reply.project_wall.feedback_types.${type}`)
    );
  }

  get intentLabel() {
    const intent = this.images.intent;
    if (!intent) {
      return null;
    }
    const key = intent === "other" ? "other_use" : intent;
    return i18n(`npn_submissions.form.project.intents.${key}`);
  }

  get hintKey() {
    return this.args.openImagesLarge
      ? "npn_critique_reply.project_wall.hint_view_only"
      : "npn_critique_reply.project_wall.hint";
  }

  get openImageTitleKey() {
    return this.args.openImagesLarge
      ? "npn_critique_reply.project_wall.view_large"
      : "npn_critique_reply.project_wall.open_image";
  }

  get individualRequested() {
    return this.requested.has("individual");
  }

  _tile(image, index) {
    const isAlternate = image.number.startsWith("A");
    return {
      image,
      index,
      isAlternate,
      src: image.sheet_url || image.url,
      label: isAlternate ? `Alt ${image.number}` : `Image ${image.number}`,
    };
  }

  get originalTiles() {
    return (this.images.originals ?? []).map((image, i) =>
      this._tile(image, i)
    );
  }

  get alternateTiles() {
    return (this.images.alternates ?? []).map((image, i) =>
      this._tile(image, i)
    );
  }

  <template>
    <section
      class="npn-project-wall"
      aria-labelledby="npn-project-wall-heading"
    >
      <header class="npn-project-wall__header">
        <h3 id="npn-project-wall-heading" class="npn-project-wall__heading">
          {{i18n "npn_critique_reply.project_wall.heading"}}
        </h3>
        <div class="npn-project-wall__header-actions">
          <DButton
            @action={{fn @onView 0}}
            @icon="play"
            @label="npn_critique_reply.project_wall.view_project"
            class="btn-default btn-small"
          />
        </div>
      </header>

      {{#if this.feedbackTypeLabels.length}}
        <p class="npn-project-wall__context">
          <span class="npn-project-wall__context-label">
            {{i18n "npn_critique_reply.project_wall.asked_for"}}
          </span>
          {{#each this.feedbackTypeLabels as |label|}}
            <span class="npn-project-wall__chip">{{label}}</span>
          {{/each}}
        </p>
      {{/if}}
      {{#if this.intentLabel}}
        <p class="npn-project-wall__context">
          <span class="npn-project-wall__context-label">
            {{i18n "npn_critique_reply.project_wall.presentation_goal"}}
          </span>
          <span
            class="npn-project-wall__chip --goal"
          >{{this.intentLabel}}</span>
        </p>
      {{/if}}

      {{#if @hasOldTags}}
        <p class="npn-project-wall__old-tags" role="status">
          {{i18n "npn_critique_reply.project_wall.old_tags_notice"}}
        </p>
      {{/if}}
      {{#if @onSuggestSequence}}
        <div class="npn-project-wall__suggest">
          <DButton
            @action={{@onSuggestSequence}}
            @icon="film"
            @label={{@suggestLabel}}
            @disabled={{@disabled}}
            class="btn-primary"
          />
          <span class="npn-project-wall__suggest-hint">
            {{i18n "npn_critique_reply.project_wall.suggest_hint"}}
          </span>
        </div>
      {{/if}}

      <p
        class="npn-project-wall__hint
          {{if this.individualRequested '--emphasized'}}"
      >
        {{i18n this.hintKey}}
      </p>

      <div class="npn-project-wall__tiles">
        {{#each this.originalTiles as |tile|}}
          <figure class="npn-project-wall__tile">
            <figcaption class="npn-project-wall__number">
              {{tile.label}}
            </figcaption>
            <button
              type="button"
              class="npn-project-wall__image-button"
              title={{i18n this.openImageTitleKey}}
              {{on "click" (fn @onOpenImage tile.image.number)}}
            >
              <img src={{tile.src}} alt={{tile.label}} loading="lazy" />
            </button>
          </figure>
        {{/each}}
      </div>

      {{#if this.alternateTiles.length}}
        <h4 class="npn-project-wall__subheading">
          {{i18n "npn_critique_reply.project_wall.alternates"}}
        </h4>
        <div class="npn-project-wall__tiles --alternates">
          {{#each this.alternateTiles as |tile|}}
            <figure class="npn-project-wall__tile is-alternate">
              <figcaption class="npn-project-wall__number">
                {{tile.label}}
              </figcaption>
              <button
                type="button"
                class="npn-project-wall__image-button"
                title={{i18n "npn_critique_reply.project_wall.view_large"}}
                {{on "click" (fn @onViewAlternate tile.index)}}
              >
                <img src={{tile.src}} alt={{tile.label}} loading="lazy" />
              </button>
            </figure>
          {{/each}}
        </div>
      {{/if}}
    </section>
  </template>
}
