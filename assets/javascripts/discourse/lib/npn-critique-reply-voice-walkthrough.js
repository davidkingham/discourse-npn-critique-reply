// Cooked-post decorator: turns a critique reply's voice note into a
// "walkthrough" — the audio player plus the image the critic was looking
// at, with their pointer replayed over it in sync with the audio.
//
// Everything it needs is on the post's `npn_voice_note` payload (see
// VoiceNoteNormalizer). Posts without a pointer timeline — and viewers
// who don't receive the payload — keep the plain <audio> player that
// core cooked from the reply's markdown; this decorator only ever adds
// to it.

import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import {
  annotationMoments,
  formatVoiceNoteTime,
  POINTER_COORD_MAX,
  pointerAt,
  pressBetween,
} from "./npn-critique-reply-voice-note";

const WRAPPER_CLASS = "npn-voice-walkthrough";
// A press only "fires" during normal playback, not when the listener
// scrubs across it.
const MAX_PRESS_WINDOW_MS = 500;
// A jump lands slightly before the critic reaches the mark, so the
// listener hears the sentence that leads up to it.
const JUMP_LEAD_IN_MS = 1000;
const JUMP_CLASS = "npn-annotation-badge--jump";

// The cooked <audio> for this voice note. Matched by the upload's file
// name when we know it; otherwise the first audio player in the post.
function findVoiceAudio(cookedElement, payload) {
  const audios = [...cookedElement.querySelectorAll("audio")];
  if (audios.length === 0) {
    return null;
  }
  const basename = String(payload?.upload?.url ?? "")
    .split("/")
    .pop();
  if (basename) {
    const match = audios.find((audio) =>
      [audio, ...audio.querySelectorAll("source")].some((node) =>
        (node.getAttribute("src") ?? "").endsWith(basename)
      )
    );
    if (match) {
      return match;
    }
  }
  return audios[0];
}

function el(tag, className, attrs = {}) {
  const node = document.createElement(tag);
  node.className = className;
  for (const [key, value] of Object.entries(attrs)) {
    node.setAttribute(key, value);
  }
  return node;
}

export function decorateVoiceWalkthrough(cookedElement, helper) {
  const payload = helper?.model?.npn_voice_note;
  const points = payload?.timeline?.points;
  if (
    !payload?.stage_image_url ||
    !Array.isArray(points) ||
    points.length < 3 ||
    cookedElement.querySelector(`.${WRAPPER_CLASS}`)
  ) {
    return;
  }
  const audio = findVoiceAudio(cookedElement, payload);
  if (!audio) {
    return;
  }
  const presses = payload.timeline.presses ?? [];

  const wrapper = el("div", WRAPPER_CLASS);
  const bar = el("div", `${WRAPPER_CLASS}__bar`);
  const toggle = el("button", `btn btn-default btn-small ${WRAPPER_CLASS}__toggle`, {
    type: "button",
    "aria-expanded": "false",
  });
  const stage = el("div", `${WRAPPER_CLASS}__stage`);
  stage.hidden = true;
  const frame = el("div", `${WRAPPER_CLASS}__frame`);
  const image = el("img", `${WRAPPER_CLASS}__image`, {
    alt: i18n("npn_critique_reply.voice_walkthrough.image_alt"),
    loading: "lazy",
    decoding: "async",
  });
  const cursor = el("div", `${WRAPPER_CLASS}__cursor`, {
    "aria-hidden": "true",
  });
  cursor.hidden = true;
  const hint = el("p", `${WRAPPER_CLASS}__hint`);
  hint.textContent = i18n("npn_critique_reply.voice_walkthrough.hint");

  audio.replaceWith(wrapper);
  bar.append(audio, toggle);
  frame.append(image, cursor);
  stage.append(frame, hint);
  wrapper.append(bar, stage);

  // The listener's own choice wins over auto-open on play.
  let userClosed = false;
  let frameRequest = null;
  let lastMs = 0;

  function setOpen(open) {
    stage.hidden = !open;
    toggle.setAttribute("aria-expanded", String(open));
    toggle.textContent = i18n(
      open
        ? "npn_critique_reply.voice_walkthrough.hide"
        : "npn_critique_reply.voice_walkthrough.show"
    );
    if (open && !image.getAttribute("src")) {
      // Loaded on first open, so a collapsed walkthrough costs nothing.
      image.setAttribute("src", getURL(payload.stage_image_url));
    }
    if (open) {
      render();
    }
  }

  function render() {
    const nowMs = audio.currentTime * 1000;
    const at = pointerAt(points, nowMs);
    if (at) {
      cursor.style.left = `${(at.x / POINTER_COORD_MAX) * 100}%`;
      cursor.style.top = `${(at.y / POINTER_COORD_MAX) * 100}%`;
    }
    cursor.hidden = !at;

    const elapsed = nowMs - lastMs;
    if (
      at &&
      elapsed > 0 &&
      elapsed <= MAX_PRESS_WINDOW_MS &&
      pressBetween(presses, lastMs, nowMs)
    ) {
      // Restart the CSS ripple.
      cursor.classList.remove("--pressed");
      void cursor.offsetWidth;
      cursor.classList.add("--pressed");
    }
    lastMs = nowMs;
  }

  function loop() {
    frameRequest = null;
    // The post left the DOM (navigation, re-cook) — stop for good.
    if (!wrapper.isConnected || audio.paused || audio.ended) {
      return;
    }
    if (!stage.hidden) {
      render();
    }
    frameRequest = requestAnimationFrame(loop);
  }

  function startLoop() {
    if (frameRequest === null) {
      frameRequest = requestAnimationFrame(loop);
    }
  }

  toggle.addEventListener("click", () => {
    const open = stage.hidden;
    userClosed = !open;
    setOpen(open);
  });
  audio.addEventListener("play", () => {
    if (stage.hidden && !userClosed) {
      setOpen(true);
    }
    lastMs = audio.currentTime * 1000;
    startLoop();
  });
  // Scrubbing while paused: move the pointer to match, no ripple.
  function syncToAudio() {
    lastMs = audio.currentTime * 1000;
    if (!stage.hidden) {
      render();
    }
  }
  for (const type of ["seeked", "pause", "ended"]) {
    audio.addEventListener(type, syncToAudio);
  }
  // Safety net: `timeupdate` keeps arriving (a few times a second) even
  // when animation frames are throttled or the frame loop bailed during
  // a seek-then-play race, so the pointer can lag but never freeze.
  audio.addEventListener("timeupdate", () => {
    if (audio.paused || stage.hidden) {
      return;
    }
    render();
    startLoop();
  });

  setOpen(false);
  wireJumpLinks();

  // Annotation pills in the critique text ([1], [A1], [Crop]…) become
  // jump links to the moment the critic pointed at that mark.
  function wireJumpLinks() {
    const moments = annotationMoments(
      helper?.model?.npn_visual_notes?.annotations,
      payload.timeline,
      {
        imageIndex: payload.image_index ?? 0,
        durationMs: payload.duration_ms ?? 0,
      }
    );
    if (moments.size === 0) {
      return;
    }
    const momentFor = (target) => {
      const badge = target?.closest?.(".npn-annotation-badge[data-label]");
      if (!badge || !cookedElement.contains(badge)) {
        return null;
      }
      return moments.get(badge.getAttribute("data-label")) ?? null;
    };
    const jumpTo = (momentMs) => {
      userClosed = false;
      setOpen(true);
      audio.currentTime = Math.max(0, momentMs - JUMP_LEAD_IN_MS) / 1000;
      // Rejected only when the browser blocks playback; the seek stands.
      audio.play()?.catch?.(() => {});
      wrapper.scrollIntoView({ block: "nearest", behavior: "smooth" });
    };

    for (const badge of cookedElement.querySelectorAll(
      ".npn-annotation-badge[data-label]"
    )) {
      const momentMs = moments.get(badge.getAttribute("data-label"));
      if (momentMs === undefined) {
        continue;
      }
      badge.classList.add(JUMP_CLASS);
      badge.setAttribute("role", "button");
      badge.setAttribute("tabindex", "0");
      badge.setAttribute(
        "title",
        i18n("npn_critique_reply.voice_walkthrough.jump", {
          time: formatVoiceNoteTime(momentMs / 1000),
        })
      );
    }
    cookedElement.addEventListener("click", (event) => {
      const momentMs = momentFor(event.target);
      if (momentMs !== null) {
        event.preventDefault();
        jumpTo(momentMs);
      }
    });
    cookedElement.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") {
        return;
      }
      const momentMs = momentFor(event.target);
      if (momentMs !== null) {
        event.preventDefault();
        jumpTo(momentMs);
      }
    });
  }
}
