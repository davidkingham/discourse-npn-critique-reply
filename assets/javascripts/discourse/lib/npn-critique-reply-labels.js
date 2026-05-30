import { i18n } from "discourse-i18n";

// Stable template identifiers. Kept for the future "Choose different prompts"
// surface and as draft-key suffixes in later steps. Step 3's modal doesn't
// render template cards anymore — the prompts are derived from the OP's
// critique_style + feedback_focus selections instead.
export const TEMPLATE_IDS = Object.freeze({
  INITIAL_REACTION: "initial_reaction",
  STANDARD: "standard",
  IN_DEPTH: "in_depth",
  TECHNICAL_HELP: "technical_help",
  EXPRESSIVE_FEEDBACK: "expressive_feedback",
  PROJECT_CRITIQUE: "project_critique",
  BLANK: "blank",
});

export const TEMPLATE_ORDER = Object.freeze([
  TEMPLATE_IDS.INITIAL_REACTION,
  TEMPLATE_IDS.STANDARD,
  TEMPLATE_IDS.IN_DEPTH,
  TEMPLATE_IDS.TECHNICAL_HELP,
  TEMPLATE_IDS.EXPRESSIVE_FEEDBACK,
  TEMPLATE_IDS.PROJECT_CRITIQUE,
  TEMPLATE_IDS.BLANK,
]);

// -- Submission type ------------------------------------------------------

const SUBMISSION_TYPE_LOCALE_KEYS = Object.freeze({
  image_critique: "npn_critique_reply.modal.submission_types.image_critique",
  weekly_challenge:
    "npn_critique_reply.modal.submission_types.weekly_challenge",
  project_critique:
    "npn_critique_reply.modal.submission_types.project_critique",
});

export function submissionTypeLabel(key) {
  if (!key) {
    return null;
  }
  const localeKey = SUBMISSION_TYPE_LOCALE_KEYS[key];
  return localeKey ? i18n(localeKey) : titleCase(key);
}

// -- Critique style (current upstream schema) -----------------------------

const CRITIQUE_STYLE_LOCALE_KEYS = Object.freeze({
  initial_reaction: "npn_critique_reply.modal.critique_styles.initial_reaction",
  standard: "npn_critique_reply.modal.critique_styles.standard",
  in_depth: "npn_critique_reply.modal.critique_styles.in_depth",
});

export function critiqueStyleLabel(key) {
  if (!key) {
    return null;
  }
  const localeKey = CRITIQUE_STYLE_LOCALE_KEYS[key];
  return localeKey ? i18n(localeKey) : titleCase(key);
}

// -- Feedback focus (current upstream schema) -----------------------------

// `feedback_focuses` (plural) is the hash. The singular `modal.feedback_focus`
// key holds the row-label string ("Feedback focus") and would collide with a
// same-named hash if we reused it here.
const FEEDBACK_FOCUS_LOCALE_KEYS = Object.freeze({
  technical_help: "npn_critique_reply.modal.feedback_focuses.technical_help",
  composition: "npn_critique_reply.modal.feedback_focuses.composition",
  processing: "npn_critique_reply.modal.feedback_focuses.processing",
  color: "npn_critique_reply.modal.feedback_focuses.color",
  tonal_balance: "npn_critique_reply.modal.feedback_focuses.tonal_balance",
  artistic_expressive:
    "npn_critique_reply.modal.feedback_focuses.artistic_expressive",
  artistic_technical:
    "npn_critique_reply.modal.feedback_focuses.artistic_technical",
  emotional_impact:
    "npn_critique_reply.modal.feedback_focuses.emotional_impact",
  project_direction:
    "npn_critique_reply.modal.feedback_focuses.project_direction",
});

export function feedbackFocusLabel(key) {
  if (!key) {
    return null;
  }
  const localeKey = FEEDBACK_FOCUS_LOCALE_KEYS[key];
  return localeKey ? i18n(localeKey) : titleCase(key);
}

// -- Critique type (future/richer schema) ---------------------------------

const CRITIQUE_TYPE_LOCALE_KEYS = Object.freeze({
  standard: "npn_critique_reply.modal.critique_types.standard",
  in_depth: "npn_critique_reply.modal.critique_types.in_depth",
  initial_reaction: "npn_critique_reply.modal.critique_types.initial_reaction",
  technical_help: "npn_critique_reply.modal.critique_types.technical_help",
  artistic_expressive:
    "npn_critique_reply.modal.critique_types.artistic_expressive",
  project_critique: "npn_critique_reply.modal.critique_types.project_critique",
});

export function critiqueTypeLabel(key) {
  if (!key) {
    return null;
  }
  const localeKey = CRITIQUE_TYPE_LOCALE_KEYS[key];
  return localeKey ? i18n(localeKey) : titleCase(key);
}

// -- Feedback areas (future/richer schema) --------------------------------

const FEEDBACK_AREA_LOCALE_KEYS = Object.freeze({
  composition: "npn_critique_reply.modal.feedback_area.composition",
  processing: "npn_critique_reply.modal.feedback_area.processing",
  exposure: "npn_critique_reply.modal.feedback_area.exposure",
  color: "npn_critique_reply.modal.feedback_area.color",
  light: "npn_critique_reply.modal.feedback_area.light",
  mood: "npn_critique_reply.modal.feedback_area.mood",
  technical: "npn_critique_reply.modal.feedback_area.technical",
  emotional_impact: "npn_critique_reply.modal.feedback_area.emotional_impact",
  storytelling: "npn_critique_reply.modal.feedback_area.storytelling",
  artistic_intent: "npn_critique_reply.modal.feedback_area.artistic_intent",
});

export function feedbackAreaLabel(key) {
  if (!key) {
    return "";
  }
  const localeKey = FEEDBACK_AREA_LOCALE_KEYS[key];
  return localeKey ? i18n(localeKey) : titleCase(key);
}

// -- Templates (forward-compat helpers, not currently rendered) -----------

export function templateTitle(id) {
  return i18n(`npn_critique_reply.templates.${id}.title`);
}

export function templateDescription(id) {
  return i18n(`npn_critique_reply.templates.${id}.description`);
}

// Map either critique_style (current schema) or critique_type (future
// schema) to a template id. Returns null if no mapping applies.
function styleOrTypeToTemplate(value) {
  switch (value) {
    case "initial_reaction":
      return TEMPLATE_IDS.INITIAL_REACTION;
    case "standard":
      return TEMPLATE_IDS.STANDARD;
    case "in_depth":
      return TEMPLATE_IDS.IN_DEPTH;
    case "technical_help":
      return TEMPLATE_IDS.TECHNICAL_HELP;
    case "artistic_expressive":
      return TEMPLATE_IDS.EXPRESSIVE_FEEDBACK;
    case "project_critique":
      return TEMPLATE_IDS.PROJECT_CRITIQUE;
    default:
      return null;
  }
}

function focusToTemplate(value) {
  switch (value) {
    case "technical_help":
      return TEMPLATE_IDS.TECHNICAL_HELP;
    case "artistic_expressive":
    case "emotional_impact":
      return TEMPLATE_IDS.EXPRESSIVE_FEEDBACK;
    case "project_direction":
      return TEMPLATE_IDS.PROJECT_CRITIQUE;
    default:
      return null;
  }
}

// Choose the template that best matches the photographer's request.
// Precedence (most-specific first):
//   1. submission_type === "project_critique"  → Project Critique
//   2. critique_style                          → mapped template (current schema)
//   3. critique_type                           → mapped template (future schema)
//   4. feedback_focus                          → mapped template
//   5. fallback                                → Standard Critique
//
// Returns one of TEMPLATE_IDS — never null.
export function recommendTemplate(metadata) {
  if (!metadata) {
    return TEMPLATE_IDS.STANDARD;
  }
  if (metadata.submission_type === "project_critique") {
    return TEMPLATE_IDS.PROJECT_CRITIQUE;
  }
  return (
    styleOrTypeToTemplate(metadata.critique_style) ||
    styleOrTypeToTemplate(metadata.critique_type) ||
    focusToTemplate(metadata.feedback_focus) ||
    TEMPLATE_IDS.STANDARD
  );
}

// -- Utilities ------------------------------------------------------------

function titleCase(value) {
  return String(value)
    .replace(/[_-]+/g, " ")
    .trim()
    .replace(/\b\w/g, (c) => c.toUpperCase());
}
