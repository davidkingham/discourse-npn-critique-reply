import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import DButton from "discourse/ui-kit/d-button";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

const TAG_ICONS = {
  strongest: "star",
  keep: "check",
  unsure: "question",
  cut: "xmark",
  bring_in: "arrow-turn-up",
};

// The left pane of the critique workspace for a PROJECT critique: the whole
// body of work instead of a single reference image.
//
// - Every image at true proportions with its number; alternates below.
// - Click an original → open it on its own with the visual tools
//   (@onOpenImage); click an alternate → view it large (@onView…).
// - "View the project" steps through the images full-screen, in order.
// - Tag buttons under each image build a suggested edit (strongest / keep /
//   unsure / cut, alternates "bring in"); "Add edit to critique" turns the
//   tags into one graphic in the critique text.
// - The photographer's requested feedback types and presentation goal are
//   pinned at the top, and the matching tools are emphasized.
//
// Tag definitions and the image data come from discourse-npn-submissions
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

  get editRequested() {
    return this.requested.has("edit");
  }

  get sequenceRequested() {
    return this.requested.has("sequence");
  }

  get individualRequested() {
    return this.requested.has("individual");
  }

  _tile(image, index) {
    const tags = this.args.tags ?? {};
    const current = tags[image.number] ?? null;
    const isAlternate = image.number.startsWith("A");
    return {
      image,
      index,
      isAlternate,
      src: image.sheet_url || image.url,
      label: isAlternate ? `Alt ${image.number}` : `Image ${image.number}`,
      current,
      buttons: (this.args.tagDefs ?? [])
        .filter((tag) => tag.alternateOnly === isAlternate)
        .map((tag) => ({
          key: tag.key,
          icon: TAG_ICONS[tag.key],
          title: i18n(`npn_critique_reply.project_wall.tags.${tag.key}`),
          active: current === tag.key,
        })),
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

  get tagCounts() {
    const counts = {};
    Object.values(this.args.tags ?? {}).forEach((tag) => {
      counts[tag] = (counts[tag] ?? 0) + 1;
    });
    return (this.args.tagDefs ?? [])
      .filter((tag) => counts[tag.key])
      .map((tag) => ({
        key: tag.key,
        icon: TAG_ICONS[tag.key],
        text: `${counts[tag.key]} ${i18n(
          `npn_critique_reply.project_wall.tags.${tag.key}`
        ).toLowerCase()}`,
      }));
  }

  get hasTags() {
    return this.tagCounts.length > 0;
  }

  get editButtonLabel() {
    if (this.args.editBusy) {
      return "npn_critique_reply.project_wall.edit_creating";
    }
    return this.args.hasEditImage
      ? "npn_critique_reply.project_wall.edit_update"
      : "npn_critique_reply.project_wall.edit_add";
  }

  get editButtonDisabled() {
    return !this.hasTags || this.args.editBusy || this.args.disabled;
  }

  <template>
    <section
      class="npn-project-wall {{if this.editRequested '--edit-requested'}}"
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
          {{#if @onSuggestSequence}}
            <DButton
              @action={{@onSuggestSequence}}
              @icon="film"
              @label="npn_submissions.sequence.toolbar_button"
              @disabled={{@disabled}}
              class="btn-small
                {{if this.sequenceRequested 'btn-primary' 'btn-default'}}"
            />
          {{/if}}
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
          <span class="npn-project-wall__chip --goal">{{this.intentLabel}}</span>
        </p>
      {{/if}}

      <p
        class="npn-project-wall__hint
          {{if this.individualRequested '--emphasized'}}"
      >
        {{i18n "npn_critique_reply.project_wall.hint"}}
      </p>

      <div class="npn-project-wall__tiles">
        {{#each this.originalTiles as |tile|}}
          <figure
            class="npn-project-wall__tile
              {{if tile.current (concatClass '--tag-' tile.current)}}"
          >
            <figcaption class="npn-project-wall__number">
              {{tile.label}}
            </figcaption>
            <button
              type="button"
              class="npn-project-wall__image-button"
              title={{i18n "npn_critique_reply.project_wall.open_image"}}
              {{on "click" (fn @onOpenImage tile.image.number)}}
            >
              <img src={{tile.src}} alt={{tile.label}} loading="lazy" />
            </button>
            <div
              class="npn-project-wall__tags"
              role="group"
              aria-label={{i18n "npn_critique_reply.project_wall.tag_group"}}
            >
              {{#each tile.buttons as |tagButton|}}
                <button
                  type="button"
                  class="npn-project-wall__tag --{{tagButton.key}}
                    {{if tagButton.active 'is-active'}}"
                  title={{tagButton.title}}
                  aria-label={{tagButton.title}}
                  aria-pressed={{if tagButton.active "true" "false"}}
                  disabled={{@disabled}}
                  {{on "click" (fn @onSetTag tile.image.number tagButton.key)}}
                >{{dIcon tagButton.icon}}</button>
              {{/each}}
            </div>
          </figure>
        {{/each}}
      </div>

      {{#if this.alternateTiles.length}}
        <h4 class="npn-project-wall__subheading">
          {{i18n "npn_critique_reply.project_wall.alternates"}}
        </h4>
        <div class="npn-project-wall__tiles --alternates">
          {{#each this.alternateTiles as |tile|}}
            <figure
              class="npn-project-wall__tile is-alternate
                {{if tile.current (concatClass '--tag-' tile.current)}}"
            >
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
              <div class="npn-project-wall__tags" role="group">
                {{#each tile.buttons as |tagButton|}}
                  <button
                    type="button"
                    class="npn-project-wall__tag --{{tagButton.key}}
                      {{if tagButton.active 'is-active'}}"
                    title={{tagButton.title}}
                    aria-label={{tagButton.title}}
                    aria-pressed={{if tagButton.active "true" "false"}}
                    disabled={{@disabled}}
                    {{on "click" (fn @onSetTag tile.image.number tagButton.key)}}
                  >{{dIcon tagButton.icon}}</button>
                {{/each}}
              </div>
            </figure>
          {{/each}}
        </div>
      {{/if}}

      <footer class="npn-project-wall__edit">
        <div class="npn-project-wall__edit-summary">
          {{#if this.hasTags}}
            {{#each this.tagCounts as |count|}}
              <span class="npn-project-wall__count --{{count.key}}">
                {{dIcon count.icon}}
                {{count.text}}
              </span>
            {{/each}}
          {{else}}
            <span class="npn-project-wall__edit-hint">
              {{i18n "npn_critique_reply.project_wall.edit_hint"}}
            </span>
          {{/if}}
        </div>
        <div class="npn-project-wall__edit-actions">
          {{#if this.hasTags}}
            <DButton
              @action={{@onClearTags}}
              @label="npn_critique_reply.project_wall.edit_clear"
              @disabled={{@editBusy}}
              class="btn-flat btn-small"
            />
          {{/if}}
          <DButton
            @action={{@onAddEdit}}
            @label={{this.editButtonLabel}}
            @disabled={{this.editButtonDisabled}}
            class="btn-small
              {{if this.editRequested 'btn-primary' 'btn-default'}}"
          />
        </div>
        {{#if this.hasTags}}
          <p class="npn-project-wall__edit-note">
            {{i18n "npn_critique_reply.project_wall.edit_auto_note"}}
          </p>
        {{/if}}
        {{#if @editError}}
          <p class="npn-project-wall__error" role="alert">{{@editError}}</p>
        {{/if}}
      </footer>
    </section>
  </template>
}

function concatClass(prefix, value) {
  return `${prefix}${value}`;
}
