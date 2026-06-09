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
 * @param {?object} visualNotes — optional NPN visual-annotation
 *   wrapper (schema_version / source / visual_output / annotations).
 *   The server stores this as a post custom field on the created
 *   reply. Pass null/undefined to skip metadata persistence (Post-
 *   without-visual-notes, text-only critiques, etc.). Sent as JSON
 *   so deeply-nested arrays round-trip cleanly.
 * @param {?object} processingExample — optional nested wrapper
 *   ({source, example_upload}). Server stores as the
 *   `npn_processing_example` post custom field. Pass null to skip.
 *   Same omit-when-absent pattern as visualNotes on the create path.
 * @returns {Promise<{success: true, post: {id, post_number, topic_id, url}}>}
 */
export function postCritique(
  topicId,
  raw,
  selectedImageVersionKey,
  visualNotes = null,
  processingExample = null
) {
  const body = {
    raw,
    selected_image_version_key: selectedImageVersionKey ?? null,
  };
  if (visualNotes) {
    body.visual_notes = visualNotes;
  }
  if (processingExample) {
    body.processing_example = processingExample;
  }
  return ajax(`/npn-critique-reply/topics/${topicId}/replies`, {
    type: "POST",
    data: JSON.stringify(body),
    contentType: "application/json",
    processData: false,
    dataType: "json",
  });
}

/**
 * Update a previously-posted critique reply. Server replaces both
 * the post's raw markdown (via PostRevisor) and the saved
 * npn_visual_notes payload. Same shape as postCritique but with one
 * deliberate difference: the `visual_notes` key is ALWAYS sent —
 * either with a payload (normal edit) or as explicit `null` (user
 * removed all annotations, or chose "Continue without visual notes"
 * in edit mode). The server treats the explicit `null` as the
 * signal to delete the post's `npn_visual_notes` custom field, so
 * the visible post body and the stored payload stay in sync.
 *
 * Create mode (`postCritique`) keeps the older behavior of omitting
 * the key for text-only critiques because there's nothing pre-
 * existing to clear on a brand-new post.
 *
 * @param {number} postId — the post being edited (NOT the topic id).
 * @param {string} raw
 * @param {?string} selectedImageVersionKey
 * @param {?object} visualNotes — pass null to explicitly clear the
 *   stored payload; pass a wrapper object to replace it.
 * @returns {Promise<{success: true, post: {id, post_number, topic_id, url}}>}
 */
export function updateCritique(
  postId,
  raw,
  selectedImageVersionKey,
  visualNotes = null,
  processingExample = null
) {
  // Note: BOTH `visual_notes` and `processing_example` are always
  // present in the update body. Distinguishing "key absent" (preserve
  // existing) from "key present with null value" (clear) is how the
  // server knows to delete the matching custom field. See
  // `sync_visual_notes_for_update` / `sync_processing_example_for_update`.
  const body = {
    raw,
    selected_image_version_key: selectedImageVersionKey ?? null,
    visual_notes: visualNotes ?? null,
    processing_example: processingExample ?? null,
  };
  return ajax(`/npn-critique-reply/posts/${postId}/critique`, {
    type: "PUT",
    data: JSON.stringify(body),
    contentType: "application/json",
    processData: false,
    dataType: "json",
  });
}
