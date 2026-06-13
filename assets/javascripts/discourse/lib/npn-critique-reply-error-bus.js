// Tiny error bus for the plugin. Any plugin code (component, helper,
// initializer) can call `recordPluginError(context, error, extra)`
// without needing a handle to the modal. Failures land in a global
// ring buffer AND fire a `npn-critique-reply:error` CustomEvent on
// the window. The modal's constructor subscribes to that event and
// merges entries into its own `_errorHistory`, so the "Copy
// diagnostic" button surfaces failures from anywhere in the plugin.
//
// When the modal isn't open (or hasn't mounted yet), the ring buffer
// still keeps recent entries so a delayed open can backfill them.
//
// Always logs to console.warn (no debug-setting gate). Severity is
// "error" | "warn" | "info"; only "error"-severity entries get
// promoted to the modal's `_lastFailureReport` (so transient warns
// don't clobber the actual user-visible failure).

const MAX_BUFFER = 20;
const buffer = [];

export const NPN_ERROR_EVENT = "npn-critique-reply:error";

// Snapshot of what we know about the failure. The modal's
// `_buildFailureReport` enriches this with annotation counts, server
// response, browser info, etc. — what the bus emits is the minimal
// per-site context.
function serialize(error) {
  if (!error) {
    return { name: null, message: null, stack: null };
  }
  if (typeof error === "string") {
    return { name: null, message: error, stack: null };
  }
  return {
    name: error.name ?? null,
    message: error.message ?? String(error),
    stack: error.stack ?? null,
  };
}

export function recordPluginError(
  context,
  error,
  extra = null,
  severity = "error"
) {
  const entry = {
    timestamp: new Date().toISOString(),
    context,
    severity,
    error: serialize(error),
    extra: extra ?? null,
  };
  buffer.push(entry);
  if (buffer.length > MAX_BUFFER) {
    buffer.shift();
  }

  // Console log — no debug-setting gate. We deliberately leave a
  // breadcrumb so devtools-savvy users can scrape it even if the
  // modal isn't open to capture the event.
  const method = severity === "info" ? "info" : "warn";
  // eslint-disable-next-line no-console
  console[method](`[npn-critique-reply] ${context}`, entry);

  // Fire the event so any listening modal can merge this into its
  // diagnostic. CustomEvent details have to be a plain object —
  // pass entry by reference is fine since we don't mutate it after
  // dispatch.
  if (typeof window !== "undefined") {
    try {
      window.dispatchEvent(
        new CustomEvent(NPN_ERROR_EVENT, { detail: entry })
      );
    } catch {
      // CustomEvent unavailable on very old browsers — the console
      // log is still a useful breadcrumb.
    }
  }
  return entry;
}

// Lets the modal backfill recent entries on mount (e.g. errors that
// happened during prompt-tree generation before the user opened the
// workspace).
export function recentPluginErrors() {
  return buffer.slice();
}

// Test-only — clear the ring buffer between test cases.
export function _resetErrorBuffer() {
  buffer.length = 0;
}
