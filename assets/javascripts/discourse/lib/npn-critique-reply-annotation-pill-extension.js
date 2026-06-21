// Rich-editor (ProseMirror / WYSIWYG) extension that styles visual-annotation
// marker tokens — [1], [A1], [E1], [Crop 2], … — as the same colored pills
// they become in the cooked post and on the image overlay, right inside the
// critique writing surface.
//
// It is a pure INLINE DECORATION: it only attaches a CSS class to the matched
// text ranges. The underlying markdown is never touched (the tokens stay
// editable plain text and serialize unchanged), so drafts / preview / posting
// are unaffected. Only the rich editor renders pills; Markdown mode shows the
// raw `[A1]` text, as expected.
//
// `api.registerRichEditorExtension` registers globally for every rich editor
// on the site, so the plugin gates itself to the Critique Workspace: it only
// produces decorations when its editor lives inside `.npn-critique-reply-modal`.
// In every other composer it is completely inert (no decorations, no scans).

import {
  annotationLabelToBadgeSuffix,
  TOKEN_PATTERN,
} from "./npn-critique-reply-annotation-badges";

// Build the full DecorationSet for a document: one inline decoration per
// recognized marker token, carrying the shared badge classes. Skips code
// blocks, inline code, and links — mirroring the cooked-post decorator's
// skip rules so an incidental `[1]` in code/a link isn't pilled.
function buildDecorations(doc, Decoration, DecorationSet) {
  const decorations = [];

  doc.descendants((node, pos, parent) => {
    if (!node.isText) {
      return;
    }
    if (parent && parent.type.name === "code_block") {
      return;
    }
    if (
      node.marks.some(
        (mark) => mark.type.name === "code" || mark.type.name === "link"
      )
    ) {
      return;
    }

    const text = node.text;
    if (!text || text.indexOf("[") === -1) {
      return;
    }

    // Same reset-then-matchAll pattern the cooked decorator uses, so the
    // shared global regex's lastIndex can't leak between callers.
    TOKEN_PATTERN.lastIndex = 0;
    for (const match of text.matchAll(TOKEN_PATTERN)) {
      const suffix = annotationLabelToBadgeSuffix(match[1]);
      if (!suffix) {
        continue;
      }
      const from = pos + match.index;
      const to = from + match[0].length;
      decorations.push(
        Decoration.inline(from, to, {
          class: `npn-annotation-badge npn-annotation-badge--${suffix}`,
        })
      );
    }
  });

  return DecorationSet.create(doc, decorations);
}

const annotationPillExtension = {
  plugins({
    pmState: { Plugin, PluginKey },
    pmView: { Decoration, DecorationSet },
  }) {
    const key = new PluginKey("npnAnnotationPills");

    return new Plugin({
      key,
      state: {
        init() {
          // The DOM (and thus the modal gate) isn't available until view()
          // runs, so start inert and light up via a setMeta from view().
          return { active: false, decorations: DecorationSet.empty };
        },
        apply(tr, prev, _oldState, newState) {
          const meta = tr.getMeta(key);
          const active = meta?.active ?? prev.active;

          if (!active) {
            return { active, decorations: DecorationSet.empty };
          }

          // Rebuild on activation or any doc change; otherwise just map the
          // existing decorations through the transaction.
          if (meta?.active || tr.docChanged) {
            return {
              active,
              decorations: buildDecorations(
                newState.doc,
                Decoration,
                DecorationSet
              ),
            };
          }

          return {
            active,
            decorations: prev.decorations.map(tr.mapping, tr.doc),
          };
        },
      },
      view(editorView) {
        let destroyed = false;

        if (editorView.dom.closest(".npn-critique-reply-modal")) {
          // Defer so we aren't dispatching while the view is still being
          // constructed; this paints the initial draft's tokens as pills.
          Promise.resolve().then(() => {
            if (destroyed) {
              return;
            }
            editorView.dispatch(
              editorView.state.tr.setMeta(key, { active: true })
            );
          });
        }

        return {
          destroy() {
            destroyed = true;
          },
        };
      },
      props: {
        decorations(state) {
          return key.getState(state).decorations;
        },
      },
    });
  },
};

export default annotationPillExtension;
