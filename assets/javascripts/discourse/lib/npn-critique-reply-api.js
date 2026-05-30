import { ajax } from "discourse/lib/ajax";

// Thin wrapper around the critique-reply post endpoint. Discourse's ajax
// helper handles CSRF, JSON serialization, and X-CSRF-Token automatically,
// so this file is mostly here to give callers a typed boundary and a
// single place to update if the URL ever changes.

/**
 * Create a normal Discourse reply on the given topic.
 *
 * @param {number} topicId
 * @param {string} raw — final reply text, already prefixed for the
 *   selected version if applicable. The server treats this as the
 *   authoritative post body.
 * @param {?string} selectedImageVersionKey — the modal's currently-
 *   selected version key ("original", "revision_2", ...). Server uses
 *   it only for future logging/metadata; permissions are independent.
 * @returns {Promise<{success: true, post: {id, post_number, topic_id, url}}>}
 */
export function postCritique(topicId, raw, selectedImageVersionKey) {
  return ajax(`/npn-critique-reply/topics/${topicId}/replies`, {
    type: "POST",
    data: {
      raw,
      selected_image_version_key: selectedImageVersionKey ?? null,
    },
  });
}
