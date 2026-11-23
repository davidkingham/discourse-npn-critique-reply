import { get } from "@ember/object";
import Composer from "discourse/models/composer";
import { isCritiqueTopic } from "./npn-critique-reply-eligibility";

// Shared client-side state for "who is the topic author still to answer?".
//
// The server sends the list to the author only, as
// `topic.npn_critique_reply_unanswered_critics` = [{ username, name }]
// (see lib/discourse_npn_critique_reply/unanswered_critics.rb). Three
// things read it: the footer's "Respond to critiques" button, the
// per-post "Add Sarah to reply" button, and the combine-replies composer
// notice. It lives on the topic model so they all agree, and is read
// through `get` so templates follow updates.
const UNANSWERED_KEY = "npn_critique_reply_unanswered_critics";

// Lower-cased usernames @mentioned in `text`. Usernames may contain dots
// and hyphens but can't end with one, so "thanks @sarah." is `sarah`.
export function mentionedUsernames(text) {
  return new Set(
    [...(text ?? "").matchAll(/@([\w.-]+)/g)].map((match) =>
      match[1].toLowerCase().replace(/[.-]+$/, "")
    )
  );
}

export function unansweredCritics(topic) {
  return (topic && get(topic, UNANSWERED_KEY)) || [];
}

// An @mention per critic, each on its own line with room to write
// underneath. Anyone already mentioned in `existing` is left out.
export function mentionBlock(critics, existing = "") {
  const already = mentionedUsernames(existing);
  return critics
    .filter((critic) => !already.has(critic.username.toLowerCase()))
    .map((critic) => `@${critic.username} `)
    .join("\n\n");
}

// The author just posted: drop everyone that post replies to or
// @mentions, mirroring the server's rule, so counts are right without a
// reload. Called from the `post:created` app event.
export function markAnswered(topic, post, currentUser) {
  if (!topic || !post || post.topic_id !== topic.id) {
    return;
  }
  if (post.user_id !== currentUser?.id) {
    return;
  }
  const waiting = unansweredCritics(topic);
  if (waiting.length === 0) {
    return;
  }
  const addressed = mentionedUsernames(post.raw);
  const repliedTo = post.reply_to_user?.username;
  if (repliedTo) {
    addressed.add(repliedTo.toLowerCase());
  }
  topic.set(
    UNANSWERED_KEY,
    waiting.filter((critic) => !addressed.has(critic.username.toLowerCase()))
  );
}

// True when the viewer wrote this critique topic and the nudges toward
// one combined reply are on.
export function isCombiningAuthor({ topic, siteSettings, currentUser }) {
  return (
    !!siteSettings?.npn_critique_reply_combine_replies &&
    !!currentUser &&
    !!topic &&
    topic.user_id === currentUser.id &&
    isCritiqueTopic({ topic, siteSettings })
  );
}

// The composer model when a reply to `topic` is already being written
// (open or minimised), otherwise null. Read through `get` so callers in
// templates update when the composer opens and closes.
export function replyInProgress(composer, topic) {
  const model = composer && get(composer, "model");
  if (!model || !topic) {
    return null;
  }
  if (get(model, "action") !== Composer.REPLY) {
    return null;
  }
  return get(model, "topic.id") === topic.id ? model : null;
}
