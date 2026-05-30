// Guided-prompt registry for the Critique Helper modal.
//
// Each prompt is a `{ question, starter }` pair:
//   - `question`  is what the modal shows the critic. Short, scannable,
//     prompts thinking ("What technical issue stands out most clearly?").
//   - `starter`   is what gets inserted into the textarea when the critic
//     wants to start writing from that prompt ("The technical issue I
//     notice first is..."). Markdown-safe paragraphs.
//
// buildPrompts() composes the per-topic list by layering:
//   1. The photographer's own questions (`specific_critique_questions`,
//      future schema). The question doubles as its own starter since we
//      can't generate a good opener for arbitrary user input.
//   2. Style prompts (critique_style → fallback to critique_type).
//   3. Focus prompts (feedback_focus). No fallback — focuses without a
//      registered set quietly contribute nothing.
//
// Results are deduped by question (case-insensitive trim) and capped at
// MAX_PROMPTS so the modal stays scannable.

export const MAX_PROMPTS = 6;

// Style prompts. Keys match `npn_critique_style` exactly.
const STYLE_PROMPTS = Object.freeze({
  initial_reaction: [
    {
      question: "What is your first reaction to the image?",
      starter: "My first reaction to this image is...",
    },
    {
      question: "What immediately draws your attention?",
      starter: "What immediately draws me in is...",
    },
    {
      question: "What feeling or mood comes through first?",
      starter: "The first feeling or mood that comes through is...",
    },
  ],
  standard: [
    {
      question: "What feels strongest in the image?",
      starter: "What feels strongest to me is...",
    },
    {
      question: "What is one area you would look at more closely?",
      starter: "One area I'd look at more closely is...",
    },
    {
      question: "What question would help clarify the photographer's intent?",
      starter: "A question that would help clarify the intent is...",
    },
  ],
  in_depth: [
    {
      question: "What is the image doing especially well?",
      starter: "What this image does especially well is...",
    },
    {
      question:
        "How do composition, light, color, and processing work together?",
      starter:
        "Looking at how composition, light, color, and processing interact, I see...",
    },
    {
      question: "Where does the image feel less resolved?",
      starter: "An area that feels less resolved to me is...",
    },
    {
      question: "What possible direction would you suggest exploring?",
      starter: "A direction I'd suggest exploring is...",
    },
  ],
});

// Focus prompts. Keys match `npn_feedback_focus` exactly.
const FOCUS_PROMPTS = Object.freeze({
  technical_help: [
    {
      question: "What technical issue stands out most clearly?",
      starter: "The technical issue I notice first is...",
    },
    {
      question:
        "Are there any distractions caused by exposure, contrast, color, sharpness, or artifacts?",
      starter: "A distraction I'd flag is...",
    },
    {
      question: "What adjustment would you try first, and why?",
      starter: "The adjustment I'd try first is..., because...",
    },
    {
      question: "What tradeoff might come with that change?",
      starter: "A possible tradeoff with that change is...",
    },
  ],
  artistic_expressive: [
    {
      question: "What emotional tone or mood comes through?",
      starter: "The emotional tone I'm picking up is...",
    },
    {
      question:
        "How do the visual choices support or weaken that feeling?",
      starter: "The visual choices reinforce (or weaken) that feeling by...",
    },
    {
      question: "What might deepen the expressive impact of the image?",
      starter: "Something that might deepen the expressive impact is...",
    },
  ],
  composition: [
    {
      question: "Where does your eye go first?",
      starter: "My eye goes first to...",
    },
    {
      question: "How does the framing support the subject or idea?",
      starter: "The framing supports the subject by...",
    },
    {
      question:
        "Is there anything in the frame that weakens the visual flow?",
      starter: "Something in the frame that weakens the flow is...",
    },
  ],
  processing: [
    {
      question: "How does the processing support the image's intent?",
      starter: "The processing supports the intent by...",
    },
    {
      question:
        "Do the tones, contrast, and color feel aligned with the subject?",
      starter:
        "The tones, contrast, and color feel... (aligned / off because...)",
    },
    {
      question:
        "Is there anything in the processing that calls attention to itself?",
      starter:
        "An aspect of the processing that calls attention to itself is...",
    },
  ],
  project_direction: [
    {
      question: "What thread or theme feels strongest across the work?",
      starter: "The strongest thread I see across the work is...",
    },
    {
      question: "Where does the project feel most cohesive?",
      starter: "The project feels most cohesive when...",
    },
    {
      question: "What might help clarify the next direction?",
      starter: "What might help clarify the next direction is...",
    },
  ],
});

export const FALLBACK_STYLE_KEY = "standard";

// Build the final, ordered, deduplicated, capped prompt list for the
// modal. Returns an Array of `{ question, starter }` objects.
export function buildPrompts(metadata) {
  const raw = [];

  // 1. Photographer's own questions (future schema). We don't have a
  // canned opener for arbitrary text, so the question doubles as the
  // starter — the critic will rewrite it.
  if (Array.isArray(metadata?.specific_critique_questions)) {
    for (const q of metadata.specific_critique_questions) {
      if (typeof q === "string" && q.trim()) {
        const trimmed = q.trim();
        raw.push({ question: trimmed, starter: trimmed });
      }
    }
  }

  // 2. Style prompts. critique_style (current schema) wins; critique_type
  // (future schema) is the fallback.
  const styleKey =
    pickKey(STYLE_PROMPTS, metadata?.critique_style) ||
    pickKey(STYLE_PROMPTS, metadata?.critique_type) ||
    FALLBACK_STYLE_KEY;
  for (const p of STYLE_PROMPTS[styleKey] ?? []) {
    raw.push(p);
  }

  // 3. Focus prompts. No fallback — unknown focuses simply contribute
  // nothing; the style prompts alone carry the modal.
  const focusPrompts = FOCUS_PROMPTS[metadata?.feedback_focus];
  if (focusPrompts) {
    for (const p of focusPrompts) {
      raw.push(p);
    }
  }

  return dedupe(raw).slice(0, MAX_PROMPTS);
}

function pickKey(registry, value) {
  return value && Object.prototype.hasOwnProperty.call(registry, value)
    ? value
    : null;
}

function dedupe(prompts) {
  const seen = new Set();
  const out = [];
  for (const p of prompts) {
    const key = (p?.question ?? "")
      .toLowerCase()
      .replace(/\s+/g, " ")
      .trim();
    if (key && !seen.has(key)) {
      seen.add(key);
      out.push(p);
    }
  }
  return out;
}
