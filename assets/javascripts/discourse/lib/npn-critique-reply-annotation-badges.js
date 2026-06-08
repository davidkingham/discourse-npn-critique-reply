// Cooked-post decorator that turns plain-text annotation references
// like [1], [A1], [S1], [D1], [R1], [E1] into small styled inline
// badges that visually match the annotations on the post's visual-
// notes image.
//
// Raw post text stays untouched — the user composes plain markers in
// the modal textarea, the server stores plain markdown, the cooked
// HTML is generated normally by Discourse. THIS decorator runs after
// cooking and rewrites text nodes in-place.
//
// Source of truth for "which labels are styled" is the post's
// `npn_visual_notes.annotations` payload. References that aren't
// present in the payload — `[A99]` typo, manual hand-edit, etc. —
// stay as plain text. Markers inside <code>, <pre>, and <a> are
// skipped so prose context (e.g. an inline code snippet that happens
// to contain `[1]`) doesn't get badged.
//
// The decorator is intentionally idempotent: Discourse regenerates
// the cooked HTML on update, so we always start from fresh markup
// rather than detecting existing badges and skipping them.

// Annotation kind → CSS modifier class suffix. The mapping is small
// and explicit so the SCSS file stays in lock-step.
const KIND_CSS_SUFFIX = Object.freeze({
  pin: "note",
  eye_path: "eye-path",
  attention_pull: "attention",
  strong_area: "strong-area",
  direction_arrow: "direction",
  relationship_arrow: "relationship",
});

// Build the label-to-CSS-suffix map for a single post's annotations.
// Pins use their numeric `number` field ("1", "2", …); every other
// kind uses the alpha-prefixed `label` field ("A1", "S2", "E1", …).
// Returns a Map so callers get O(1) lookups during text-node walks.
export function buildAnnotationLabelMap(annotations) {
  const map = new Map();
  if (!Array.isArray(annotations)) {
    return map;
  }
  for (const annotation of annotations) {
    if (!annotation || typeof annotation !== "object") {
      continue;
    }
    const suffix = KIND_CSS_SUFFIX[annotation.kind];
    if (!suffix) {
      continue;
    }
    if (annotation.kind === "pin") {
      const number = annotation.number;
      if (typeof number === "number" && Number.isInteger(number) && number >= 1) {
        map.set(String(number), suffix);
      }
      continue;
    }
    const label = annotation.label;
    if (typeof label === "string" && label.length > 0) {
      map.set(label, suffix);
    }
  }
  return map;
}

// Tags whose descendants should NEVER be badged. Code blocks and
// links carry their own visual meaning, and rewriting their text
// would corrupt the surrounding markup (e.g. an `<a href>` text
// containing `[1]` shouldn't suddenly grow a <span> child).
const SKIP_ANCESTOR_TAGS = new Set([
  "CODE",
  "PRE",
  "A",
  "TEXTAREA",
  "INPUT",
  "SCRIPT",
  "STYLE",
]);

// Single pattern covering every valid token shape — the label-map
// gate after-the-fact filters out anything that's not in this
// post's annotations. Numeric form for pins, alpha+number for the
// other kinds.
const TOKEN_PATTERN = /\[([1-9]\d{0,2}|[ASDRE]\d{1,3})\]/g;

// Walk every text node under `root` whose ancestors don't include a
// skip-tag, and hand each one to `replaceTokensInTextNode`. We
// collect the nodes first because mutating the DOM during a live
// TreeWalker iteration can confuse the walker.
function collectEligibleTextNodes(root) {
  const out = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue || node.nodeValue.indexOf("[") === -1) {
        return NodeFilter.FILTER_REJECT;
      }
      let p = node.parentElement;
      while (p && p !== root) {
        if (SKIP_ANCESTOR_TAGS.has(p.tagName)) {
          return NodeFilter.FILTER_REJECT;
        }
        p = p.parentElement;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  while (walker.nextNode()) {
    out.push(walker.currentNode);
  }
  return out;
}

// Rewrite a single text node, replacing valid annotation references
// with badge <span>s and leaving everything else untouched. Returns
// silently when there's nothing to replace.
function replaceTokensInTextNode(textNode, labelMap) {
  const text = textNode.nodeValue;
  // Reset the global regex's lastIndex each call — String#matchAll
  // creates a fresh iterator so this is defensive against future
  // refactors.
  TOKEN_PATTERN.lastIndex = 0;
  const matches = [];
  for (const match of text.matchAll(TOKEN_PATTERN)) {
    if (labelMap.has(match[1])) {
      matches.push(match);
    }
  }
  if (matches.length === 0) {
    return;
  }

  const fragment = document.createDocumentFragment();
  let cursor = 0;
  for (const match of matches) {
    const label = match[1];
    const suffix = labelMap.get(label);
    if (match.index > cursor) {
      fragment.appendChild(
        document.createTextNode(text.slice(cursor, match.index))
      );
    }
    const span = document.createElement("span");
    span.className = `npn-annotation-badge npn-annotation-badge--${suffix}`;
    // Visible badge text omits the brackets — the styled pill IS the
    // visual reference. The data-label attribute keeps the original
    // token addressable for future scroll-to / highlight features.
    span.textContent = label;
    span.setAttribute("data-label", label);
    fragment.appendChild(span);
    cursor = match.index + match[0].length;
  }
  if (cursor < text.length) {
    fragment.appendChild(document.createTextNode(text.slice(cursor)));
  }
  textNode.parentNode.replaceChild(fragment, textNode);
}

// Entry point invoked by the api.decorateCookedElement registration
// in the api-initializer. Cheap no-op for posts that don't carry an
// npn_visual_notes payload — the gate is checked once at the top so
// the TreeWalker only runs for the small subset of posts that
// actually need it.
export function decorateCriticueReplyAnnotations(cookedElement, helper) {
  const post = helper?.model;
  if (!post) {
    return;
  }
  const payload = post.npn_visual_notes;
  if (!payload || !Array.isArray(payload.annotations)) {
    return;
  }
  const labelMap = buildAnnotationLabelMap(payload.annotations);
  if (labelMap.size === 0) {
    return;
  }
  const nodes = collectEligibleTextNodes(cookedElement);
  for (const node of nodes) {
    replaceTokensInTextNode(node, labelMap);
  }
}
