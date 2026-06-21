// Questions-to-consider helper for the Critique Helper modal.
//
// Prompts are thinking aids, NOT templates. The modal no longer
// inserts prompt text into the textarea — the prose is meant to
// stay in the critic's own voice. This module exposes:
//
//   getQuestionsToConsider({
//     critiqueStyle, feedbackFocus, submissionType, visualToolsEnabled,
//   })
//   → { defaultQuestions: [3 strings], groups: [{ key, title, prompts }] }
//
// The "default" trio adapts to the photographer's requested critique
// style and feedback focus. The grouped "More ideas" bank below is
// the same expandable list of prompts across every topic; some
// groups are conditionally hidden (visual-tools / project).
//
// Selection is deterministic — same inputs, same output. No
// randomisation, no rotation. Critics get a consistent reading
// experience and admins can reproduce reports cleanly.
//
// `buildPrompts(metadata)` from the previous helper is gone; callers
// have been updated to use `getQuestionsToConsider` instead. The
// old `{ question, starter }` shape is also gone — prompts are just
// strings now, because nothing ever inserts them.

// ---- Default trio per critique style -----------------------------

// 3 strong questions per style. Index 1 (the middle question) is the
// one we replace if a feedback focus is present, so the bookends
// stay style-aligned.
const STYLE_DEFAULTS = Object.freeze({
  standard: [
    "What feels strongest in the image?",
    "Where does your eye go first, and where does it linger?",
    "What feels unresolved or worth exploring further?",
  ],
  in_depth: [
    "What do you think the image is trying to express?",
    "How do composition, light, color, and processing support that?",
    "What would you encourage the photographer to explore further?",
  ],
  initial_reaction: [
    "What was your first impression?",
    "Where did your eye go first?",
    "What feeling or mood came through before you started analyzing?",
  ],
});

// Project critique replaces the per-style trio entirely — the
// photographer is presenting a body of work rather than a single
// image, so the prompts are about the body.
const PROJECT_DEFAULTS = Object.freeze([
  "What holds the project together?",
  "Which image or sequence feels strongest?",
  "Where does the project feel less resolved?",
]);

// Feedback-focus replacement questions. When a topic specifies a
// recognised focus, we swap the middle default question for one of
// these so the focus shapes the trio without overwhelming the
// style's voice.
const FOCUS_REPLACEMENTS = Object.freeze({
  technical_help: "What technical issue most affects how the image reads?",
  artistic_expressive: "What emotional quality comes through most clearly?",
  composition: "How does your eye move through the frame?",
  processing: "Do the tones or colors support the mood?",
});

// Style + focus combinations that benefit from a different swap
// position or a hand-tuned trio. The `general` focus is intentionally
// absent — it means "use the style defaults as-is."
const STYLE_FOCUS_OVERRIDES = Object.freeze({
  // initial_reaction × artistic_expressive — the immediate-response
  // tone calls for replacing both the middle and last question to
  // keep the focus on first/lasting feeling rather than analysis.
  "initial_reaction|artistic_expressive": [
    "What was your first impression?",
    "What emotional quality came through first?",
    "What stayed with you after looking longer?",
  ],
});

const FALLBACK_STYLE_KEY = "standard";

// ---- Expandable "More ideas" prompt groups -----------------------

const GROUP_FIRST_RESPONSE = Object.freeze({
  key: "first_response",
  title: "First response",
  prompts: Object.freeze([
    "What was your first impression?",
    "Where did your eye go first?",
    "What feeling or mood came through first?",
    "What did you notice after spending more time with the image?",
  ]),
});

const GROUP_STRENGTHS = Object.freeze({
  key: "strengths",
  title: "Strengths",
  prompts: Object.freeze([
    "What feels strongest in the image?",
    "What is holding your attention?",
    "What choice by the photographer feels especially effective?",
    "What would you encourage the photographer to keep or emphasize?",
  ]),
});

const GROUP_COMPOSITION_FLOW = Object.freeze({
  key: "composition_flow",
  title: "Composition & visual flow",
  prompts: Object.freeze([
    "How does your eye move through the frame?",
    "Where does the image feel balanced or unbalanced?",
    "Is there an area pulling attention away from the main idea?",
    "Would a different crop strengthen the visual flow?",
    "Are there relationships between shapes, lines, colors, or tones that stand out?",
  ]),
});

const GROUP_LIGHT_COLOR_TONE = Object.freeze({
  key: "light_color_tone",
  title: "Light, color & tone",
  prompts: Object.freeze([
    "How are light and shadow shaping the image?",
    "Do the tones or colors support the mood?",
    "Is there an area that feels too visually dominant?",
    "What tonal relationship feels most important?",
    "Does the color palette support the image's feeling?",
  ]),
});

const GROUP_TECHNICAL_PROCESSING = Object.freeze({
  key: "technical_processing",
  title: "Technical & processing",
  prompts: Object.freeze([
    "Is anything distracting because of sharpness, noise, halos, color, or contrast?",
    "Does the processing feel natural for the image's intent?",
    "Is there a technical issue that affects how the image reads?",
    "What adjustment would you try first, and why?",
    "Are there any artifacts or processing choices that pull attention away from the image?",
  ]),
});

const GROUP_EXPRESSION_INTENT = Object.freeze({
  key: "expression_intent",
  title: "Expression & intent",
  prompts: Object.freeze([
    "What do you think the image is trying to express?",
    "What emotional quality comes through?",
    "What feels personal or distinctive about the photographer's response?",
    "What would help clarify the photographer's intent?",
    "Does the image invite you to stay with it?",
  ]),
});

const GROUP_SUGGESTIONS = Object.freeze({
  key: "suggestions_next_steps",
  title: "Suggestions & next steps",
  prompts: Object.freeze([
    "What is one direction the photographer might explore?",
    "What small change might strengthen the image?",
    "What would you be curious to see in a revision?",
    "What would you leave alone?",
    "What question would you ask the photographer before suggesting changes?",
  ]),
});

const GROUP_VISUAL_NOTES = Object.freeze({
  key: "visual_notes_ideas",
  title: "Visual notes ideas",
  prompts: Object.freeze([
    "Use Notes to connect a specific part of the image to your written feedback.",
    "Use Crop if a different frame might clarify the image.",
    "Use Eye Path to show how your attention moves through the image.",
    "Use Attention to mark an area that pulls your eye away.",
    "Use Arrow to show direction or visual pull.",
    "Use Relationship to show a connection, echo, balance, or tension between areas.",
  ]),
});

const GROUP_PROJECT_SEQUENCE = Object.freeze({
  key: "project_sequence",
  title: "Project sequence",
  prompts: Object.freeze([
    "What holds the project together?",
    "Which image feels central to the project?",
    "Which image feels least connected to the others?",
    "Does the sequence build or shift in a meaningful way?",
    "What would make the project feel more cohesive?",
    "What would you want to see more of?",
  ]),
});

// Order matters — this is the rendered order in the "More ideas"
// panel. Keep the most-used groups near the top so the panel reads
// well even when only the first few groups are visible.
const ALL_GROUPS = Object.freeze([
  GROUP_FIRST_RESPONSE,
  GROUP_STRENGTHS,
  GROUP_COMPOSITION_FLOW,
  GROUP_LIGHT_COLOR_TONE,
  GROUP_TECHNICAL_PROCESSING,
  GROUP_EXPRESSION_INTENT,
  GROUP_SUGGESTIONS,
]);

// ---- Normalisation ----------------------------------------------

function normaliseStyle(raw) {
  if (typeof raw !== "string") {
    return FALLBACK_STYLE_KEY;
  }
  const key = raw.trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(STYLE_DEFAULTS, key)
    ? key
    : FALLBACK_STYLE_KEY;
}

function normaliseFocus(raw) {
  if (typeof raw !== "string") {
    return null;
  }
  const key = raw.trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(FOCUS_REPLACEMENTS, key)
    ? key
    : null;
}

function normaliseSubmissionType(raw) {
  if (typeof raw !== "string") {
    return null;
  }
  return raw.trim().toLowerCase() || null;
}

// ---- Public API --------------------------------------------------

export function getQuestionsToConsider({
  critiqueStyle,
  feedbackFocus,
  submissionType,
  visualToolsEnabled = false,
} = {}) {
  const style = normaliseStyle(critiqueStyle);
  const focus = normaliseFocus(feedbackFocus);
  const subType = normaliseSubmissionType(submissionType);
  const isProject = subType === "project_critique";

  let defaultQuestions;
  if (isProject) {
    // Project critique replaces the trio entirely; focus blending
    // doesn't apply because the project default questions are
    // already cohesion-oriented rather than image-oriented.
    defaultQuestions = [...PROJECT_DEFAULTS];
  } else {
    const overrideKey = `${style}|${focus}`;
    const override = STYLE_FOCUS_OVERRIDES[overrideKey];
    if (override) {
      defaultQuestions = [...override];
    } else {
      defaultQuestions = [...STYLE_DEFAULTS[style]];
      if (focus) {
        // Swap the middle question for the focus-flavoured one. The
        // first and last questions remain style-aligned so the trio
        // reads as "your critique style, threaded with this focus".
        defaultQuestions[1] = FOCUS_REPLACEMENTS[focus];
      }
    }
  }

  // Cap at 3 + dedupe defensively (most code paths produce exactly
  // 3 unique strings already; cap covers any future tuning that
  // accidentally pads the list).
  defaultQuestions = dedupeStrings(defaultQuestions).slice(0, 3);

  // Build the "More ideas" groups. Conditional groups (visual notes,
  // project sequence) are appended/skipped based on the inputs.
  const groups = [...ALL_GROUPS];
  if (visualToolsEnabled) {
    groups.push(GROUP_VISUAL_NOTES);
  }
  if (isProject) {
    groups.push(GROUP_PROJECT_SEQUENCE);
  }

  return { defaultQuestions, groups };
}

function dedupeStrings(arr) {
  const seen = new Set();
  const out = [];
  for (const s of arr) {
    if (typeof s !== "string") {
      continue;
    }
    const key = s.trim().toLowerCase().replace(/\s+/g, " ");
    if (key && !seen.has(key)) {
      seen.add(key);
      out.push(s);
    }
  }
  return out;
}

// ---- Self-check (developer aid; no test harness yet) -------------

// Lightweight assertion runner that the inline tests in the schema
// module also use. Returns `{ passed, failed, results }`.
export function runSelfCheck() {
  const results = [];
  function t(name, fn) {
    let ok = false;
    let err = null;
    try {
      ok = !!fn();
    } catch (e) {
      err = e;
    }
    results.push({ name, ok, err });
  }

  // 1. Unknown style/focus → general defaults (standard).
  t("unknown inputs fall back to standard defaults", () => {
    const out = getQuestionsToConsider({
      critiqueStyle: "??",
      feedbackFocus: "??",
    });
    return (
      out.defaultQuestions.length === 3 &&
      out.defaultQuestions[0] === STYLE_DEFAULTS.standard[0]
    );
  });

  // 2. Standard critique returns balanced defaults.
  t("standard critique → balanced trio", () => {
    const out = getQuestionsToConsider({ critiqueStyle: "standard" });
    return (
      out.defaultQuestions.length === 3 &&
      out.defaultQuestions[0].startsWith("What feels strongest")
    );
  });

  // 3. In-depth critique returns reflective defaults.
  t("in_depth critique → reflective trio", () => {
    const out = getQuestionsToConsider({ critiqueStyle: "in_depth" });
    return (
      out.defaultQuestions[0].startsWith("What do you think") &&
      out.defaultQuestions[1].includes("composition, light")
    );
  });

  // 4. Initial reaction returns immediate-response defaults.
  t("initial_reaction critique → immediate trio", () => {
    const out = getQuestionsToConsider({ critiqueStyle: "initial_reaction" });
    return out.defaultQuestions[0].startsWith("What was your first impression");
  });

  // 5. Technical help focus replaces the middle question.
  t("focus technical_help threads through the middle question", () => {
    const out = getQuestionsToConsider({
      critiqueStyle: "standard",
      feedbackFocus: "technical_help",
    });
    return out.defaultQuestions[1] === FOCUS_REPLACEMENTS.technical_help;
  });

  // 6. Artistic/expressive focus on initial_reaction uses the hand-tuned
  // override (not the generic middle-swap).
  t("initial_reaction × artistic_expressive uses the override trio", () => {
    const out = getQuestionsToConsider({
      critiqueStyle: "initial_reaction",
      feedbackFocus: "artistic_expressive",
    });
    return (
      out.defaultQuestions[0].startsWith("What was your first") &&
      out.defaultQuestions[1].startsWith("What emotional quality came") &&
      out.defaultQuestions[2].startsWith("What stayed with you")
    );
  });

  // 7. Composition focus influences defaults.
  t("focus composition threads through the middle question", () => {
    const out = getQuestionsToConsider({
      critiqueStyle: "standard",
      feedbackFocus: "composition",
    });
    return out.defaultQuestions[1] === FOCUS_REPLACEMENTS.composition;
  });

  // 8. Project critique replaces defaults with project trio.
  t("project critique submission type → project default trio", () => {
    const out = getQuestionsToConsider({
      critiqueStyle: "standard",
      feedbackFocus: "general",
      submissionType: "project_critique",
    });
    return out.defaultQuestions[0] === PROJECT_DEFAULTS[0];
  });

  // 9. Project critique includes the Project sequence group.
  t("project critique → includes Project sequence group", () => {
    const out = getQuestionsToConsider({
      submissionType: "project_critique",
    });
    return out.groups.some((g) => g.key === "project_sequence");
  });

  // 10. Visual tools disabled hides Visual notes ideas.
  t("visualToolsEnabled=false hides Visual notes ideas", () => {
    const out = getQuestionsToConsider({ visualToolsEnabled: false });
    return !out.groups.some((g) => g.key === "visual_notes_ideas");
  });

  // 11. Visual tools enabled shows Visual notes ideas.
  t("visualToolsEnabled=true shows Visual notes ideas", () => {
    const out = getQuestionsToConsider({ visualToolsEnabled: true });
    return out.groups.some((g) => g.key === "visual_notes_ideas");
  });

  // 12. Default questions are always capped at 3.
  t("defaultQuestions is always length 3", () => {
    const out = getQuestionsToConsider({ critiqueStyle: "in_depth" });
    return out.defaultQuestions.length === 3;
  });

  // 13. `general` focus does NOT replace any question.
  t("focus=general leaves style defaults intact", () => {
    const out = getQuestionsToConsider({
      critiqueStyle: "standard",
      feedbackFocus: "general",
    });
    return out.defaultQuestions[1] === STYLE_DEFAULTS.standard[1];
  });

  // 14. Group titles are non-empty strings.
  t("every group has a non-empty title", () => {
    const out = getQuestionsToConsider({ visualToolsEnabled: true });
    return out.groups.every(
      (g) => typeof g.title === "string" && g.title.length > 0
    );
  });

  // 15. Every group has at least 3 prompts.
  t("every group has at least 3 prompts", () => {
    const out = getQuestionsToConsider({
      visualToolsEnabled: true,
      submissionType: "project_critique",
    });
    return out.groups.every(
      (g) => Array.isArray(g.prompts) && g.prompts.length >= 3
    );
  });

  const passed = results.filter((r) => r.ok).length;
  const failed = results.length - passed;
  return { passed, failed, results };
}
