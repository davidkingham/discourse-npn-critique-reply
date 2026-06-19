// Shared eligibility for the critique-reply entry points — the footer
// "Start a Critique" button, the below-OP invitation panel, and the
// post-selection "Copy to Critique" button. One source of truth keeps the
// three from drifting on who may critique which topic.
//
// NOTE: the invitation panel layers its own
// `npn_critique_reply_show_below_op` kill-switch ON TOP of this. That's
// panel-specific and intentionally NOT included here.

// Pipe-separated id lists (Discourse `list` / `group_list` settings
// serialize as "1|2|3"). Positive integers only; tolerates empty/invalid.
export function parseIdList(value) {
  if (!value) {
    return [];
  }
  return value
    .toString()
    .split("|")
    .map((s) => parseInt(s, 10))
    .filter((n) => Number.isInteger(n) && n > 0);
}

// True when the current user may open the critique workspace for `topic`.
// Mirrors the checks the footer button has always applied: feature on,
// topic open + repliable, category allow-list (empty → require
// `npn_critique_reply` metadata), and group allow-list (staff bypass).
export function isCritiqueEligible({ topic, siteSettings, currentUser } = {}) {
  if (!topic) {
    return false;
  }
  if (!siteSettings?.npn_critique_reply_enabled) {
    return false;
  }
  if (topic.closed || topic.archived) {
    return false;
  }
  if (!topic.details?.can_create_post) {
    return false;
  }

  const enabledCategoryIds = parseIdList(
    siteSettings.npn_critique_reply_enabled_category_ids
  );
  if (enabledCategoryIds.length === 0) {
    // Empty list → only topics whose serializer surfaced
    // `npn_critique_reply` metadata count as critique topics.
    if (!topic.npn_critique_reply) {
      return false;
    }
  } else if (!enabledCategoryIds.includes(topic.category_id)) {
    return false;
  }

  const allowedGroupIds = parseIdList(
    siteSettings.npn_critique_reply_allowed_group_ids
  );
  if (allowedGroupIds.length > 0 && !currentUser?.staff) {
    const userGroupIds = (currentUser?.groups ?? []).map((g) => g.id);
    if (!allowedGroupIds.some((id) => userGroupIds.includes(id))) {
      return false;
    }
  }

  return true;
}
