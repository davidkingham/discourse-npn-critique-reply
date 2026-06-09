import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

// Client-side helpers for the Processing Example workflow.
// =================================================================
//
// A processing example is a critic's externally-processed copy of the
// photographer's reference image, included in their critique reply as
// an additional inline image. Distinct from visual notes (which are
// annotations baked onto a flattened JPEG) — processing examples are
// uploaded alternate images, not annotation metadata.
//
// Spec / behaviour decisions:
//   • One example per critique reply (v1).
//   • No in-browser editing, no canvas baking, no annotations.
//   • Stored on the reply post as the `npn_processing_example` custom
//     field with the nested {source, example_upload} shape. The flat
//     draft shape (one level deep) round-trips through
//     `normalizeFromServerPost` / `composeDraftPayload`.
//   • Post body composition: `<heading>\n\n![alt](short_url)`. The
//     critique modal stitches this into the final post body AFTER any
//     visual-notes block and BEFORE the textarea body.

/**
 * Upload a user-picked file as a processing example. Wraps Discourse's
 * standard /uploads.json endpoint with the same `upload_type=composer`
 * + `synchronous=true` combo we use for the visual-notes blob upload.
 *
 * Errors are tagged with `stage: "upload"` so the modal can reuse its
 * existing stage-based error UI for processing-example failures.
 *
 * @param {File|Blob} file
 * @param {string} filename
 * @returns {Promise<{upload_id, url, short_url, original_filename}>}
 */
export async function uploadProcessingExampleFile(file, filename) {
  const formData = new FormData();
  formData.append("file", file, filename);
  formData.append("upload_type", "composer");
  formData.append("synchronous", "true");

  try {
    return await ajax("/uploads.json", {
      type: "POST",
      data: formData,
      processData: false,
      contentType: false,
    });
  } catch (cause) {
    throw wrapProcessingExampleError("upload", cause);
  }
}

/**
 * Build the post-shape payload sent on the critique create/update
 * request. The server normalizer rejects anything missing an upload
 * reference, so callers should only call this when an upload exists.
 *
 * Returns null when `exampleUpload` is missing or incomplete — lets
 * callers pass `null` straight through to the API client without
 * branching.
 *
 * @param {object} args
 * @param {{id: number}} args.topic
 * @param {?object} args.selectedVersion  — modal's current image-version selection
 * @param {?{upload_id?: number, url?: string, short_url?: string, original_filename?: string}} args.exampleUpload
 */
export function buildProcessingExamplePayload({
  topic,
  selectedVersion,
  exampleUpload,
}) {
  if (!exampleUpload) {
    return null;
  }
  if (
    exampleUpload.upload_id == null &&
    !exampleUpload.url &&
    !exampleUpload.short_url
  ) {
    return null;
  }

  const versionKey = selectedVersion?.key ?? null;
  const versionLabel = selectedVersion?.label ?? null;
  const sourceUploadId = selectedVersion?.upload_id ?? null;
  const sourceUrl = selectedVersion?.url ?? null;

  return {
    schema_version: 1,
    source: {
      topic_id: topic?.id ?? null,
      image_version_key: versionKey,
      image_version_label: versionLabel,
      source_upload_id: sourceUploadId,
      source_url: sourceUrl,
    },
    example_upload: {
      upload_id: exampleUpload.upload_id ?? null,
      url: exampleUpload.url ?? null,
      short_url: exampleUpload.short_url ?? null,
      filename:
        exampleUpload.filename ??
        exampleUpload.original_filename ??
        null,
    },
  };
}

/**
 * Restore the modal's tracked processing-example state from whatever
 * shape the server returned. The Post serializer emits the nested
 * post shape (`{source, example_upload}`); the drafts endpoint emits
 * the flat draft shape. Both reduce to the same flat client model.
 *
 * Returns null when the payload doesn't carry a usable upload
 * reference, so the modal can keep its tracked state untouched.
 */
export function normalizeProcessingExampleFromServer(payload) {
  if (!payload || typeof payload !== "object") {
    return null;
  }
  // Nested (post custom field) shape.
  const source = payload.source && typeof payload.source === "object"
    ? payload.source
    : null;
  const upload =
    payload.example_upload && typeof payload.example_upload === "object"
      ? payload.example_upload
      : null;

  const versionKey =
    source?.image_version_key ?? payload.source_image_version_key ?? null;
  const versionLabel =
    source?.image_version_label ?? payload.source_image_version_label ?? null;
  const uploadId = upload?.upload_id ?? payload.upload_id ?? null;
  const url = upload?.url ?? payload.url ?? null;
  const shortUrl = upload?.short_url ?? payload.short_url ?? null;
  const filename = upload?.filename ?? payload.filename ?? null;

  if (uploadId == null && !url && !shortUrl) {
    return null;
  }

  return {
    sourceImageVersionKey: versionKey,
    sourceImageVersionLabel: versionLabel,
    uploadId,
    url,
    shortUrl,
    filename,
  };
}

/**
 * Render the heading line + image markdown that gets stitched into
 * the final post body. The caller controls placement (visual notes
 * block first when present, then this block, then the critique
 * text); this helper just produces the block itself.
 *
 * Returns an empty string when there's no example to render, so the
 * caller can concatenate unconditionally.
 *
 * @param {object} args
 * @param {?object} args.selectedVersion — modal's current image-version selection
 * @param {?{shortUrl?: string, url?: string}} args.processingExample
 */
export function composeProcessingExampleRaw({
  selectedVersion,
  processingExample,
}) {
  if (!processingExample) {
    return "";
  }
  const refUrl =
    processingExample.shortUrl || processingExample.url || "";
  if (!refUrl) {
    return "";
  }

  const heading = processingExampleHeading(selectedVersion);
  const altText = i18n("npn_critique_reply.modal.processing_example.image_alt");
  return `${heading}\n\n![${altText}](${refUrl})`;
}

// The heading bakes the version label into the post body so a
// re-viewed critique is self-documenting about which version the
// critic processed.
export function processingExampleHeading(selectedVersion) {
  if (selectedVersion?.kind === "revision" && selectedVersion?.label) {
    return i18n(
      "npn_critique_reply.modal.processing_example.heading_revision",
      { label: selectedVersion.label }
    );
  }
  return i18n(
    "npn_critique_reply.modal.processing_example.heading_original"
  );
}

// Produces a stable filename for the uploaded example so site admins
// scanning the uploads table can tell what the file is. We can't
// always know the user's preferred extension (the picker may give
// HEIC/AVIF/etc), so we honour the original extension when present
// and fall back to `.jpg`.
export function processingExampleFilename(topicId, versionKey, originalName) {
  const safeTopic = topicId ?? "unknown";
  const safeVersion = versionKey ?? "original";
  const ext = extractExtension(originalName) || "jpg";
  return `npn-processing-example-topic-${safeTopic}-${safeVersion}.${ext}`;
}

// Build a download filename for the source reference image. Used by
// the "Download Reference Image" anchor's `download` attribute so
// browsers that honour cross-origin downloads get a meaningful name.
export function processingExampleSourceFilename(topicId, versionKey, sourceUrl) {
  const safeTopic = topicId ?? "unknown";
  const safeVersion = versionKey ?? "original";
  const ext = extractExtension(sourceUrl) || "jpg";
  return `npn-reference-topic-${safeTopic}-${safeVersion}.${ext}`;
}

// Wrap an arbitrary error so the modal's existing stage-based error
// renderer can show a friendly per-stage message. The visual-notes
// pipeline uses the same shape.
export function wrapProcessingExampleError(stage, cause) {
  const err = new Error(`processing_example:${stage}`);
  err.stage = stage;
  err.cause = cause;
  err.feature = "processing_example";
  return err;
}

// Pluck a lowercase extension off a filename or URL path. Returns
// null when no `.ext` (where ext is 2-5 letters/digits) is present.
function extractExtension(input) {
  if (!input) {
    return null;
  }
  const m = String(input).match(/\.([a-zA-Z0-9]{2,5})(?:\?.*)?$/);
  return m ? m[1].toLowerCase() : null;
}
