// Per-category label for the footer reply button.
//
// `npn_critique_reply_footer_reply_labels` is a pipe-separated list of
// `category:Label` entries. `category` may be a numeric id (survives a
// rename), a slug (`ama`), or a `parent/child` slug path (`learning/ama`).
// The first matching entry wins; no match → null, and the caller falls
// back to the default "Reply to topic" label.
export function parseFooterReplyLabels(value) {
  if (!value) {
    return [];
  }
  return value
    .toString()
    .split("|")
    .map((entry) => {
      const index = entry.indexOf(":");
      if (index < 1) {
        return null;
      }
      const key = entry.slice(0, index).trim().toLowerCase();
      const label = entry.slice(index + 1).trim();
      return key && label ? { key, label } : null;
    })
    .filter(Boolean);
}

export function footerReplyLabelFor(category, value) {
  if (!category) {
    return null;
  }
  const entries = parseFooterReplyLabels(value);
  if (entries.length === 0) {
    return null;
  }

  const slug = category.slug?.toLowerCase();
  const parentSlug = (
    category.parentCategory?.slug ?? category.parent_category?.slug
  )?.toLowerCase();
  const keys = new Set([String(category.id)]);
  if (slug) {
    keys.add(parentSlug ? `${parentSlug}/${slug}` : slug);
  }
  // A bare slug also matches a subcategory, so `ama` works for
  // `learning/ama` without spelling out the parent.
  const match =
    entries.find((entry) => keys.has(entry.key)) ??
    entries.find((entry) => slug && entry.key === slug);
  return match?.label ?? null;
}
