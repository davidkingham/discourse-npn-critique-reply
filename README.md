# discourse-npn-critique-reply

A Discourse plugin that adds a **visual critique workspace** to photo-submission
topics on Nature Photographers Network (NPN). On an eligible topic it surfaces a
"Start a Critique" button and an invitation panel that open a large modal where a
critic can annotate the submitted image, write structured feedback, and post it
as a **normal Discourse reply**.

It is the read-side companion to
[`discourse-npn-submissions`](https://github.com/davidkingham/discourse-npn-submissions):
that plugin creates the submission topics and writes the metadata this plugin
consumes. See [Relationship to discourse-npn-submissions](#relationship-to-discourse-npn-submissions).

## What the workspace does

- Shows the submitted image(s) and the photographer's structured request
  ("Feedback Requested", "About this image", …) pinned above the editor.
- **Visual annotations** on a Konva canvas: crop suggestions, eye-path, area
  markers, arrows, rotate/flip. The annotated image is flattened to a JPEG and
  posted into the reply; the annotation schema is stored on the post custom
  field `npn_visual_notes` so the critique can be reopened and re-edited.
- **Processing example** (optional): download the reference image, process it
  externally, and re-upload one example (post custom field
  `npn_processing_example`). Gated globally and per-topic.
- **Server-side drafts**: in-progress critiques autosave to the `PluginStore`
  and can be minimized to a persistent dock and resumed across devices.
- **Edit Visual Critique**: a post-menu button reopens a posted critique for
  editing (`PostRevisor` under the hood).

The reply is created through the standard `PostCreator` / `PostRevisor` (no
guardian skipping), so critiques are ordinary posts — nothing about reading,
moderation, search, or backup changes.

## How eligibility works — where the button appears

There is **no dedicated route**; the UI injects into the normal topic view via
plugin outlets. A topic is critique-eligible when ALL of these hold
(`assets/javascripts/discourse/lib/npn-critique-reply-eligibility.js`):

1. `npn_critique_reply_enabled` is on.
2. The topic is open (not closed/archived) and the user can reply.
3. **Category gate** — `npn_critique_reply_enabled_category_ids`:
   - If non-empty → the topic's category must be in the list.
   - **If empty (default) → the topic must carry submission metadata** (i.e.
     `discourse-npn-submissions` wrote its `npn_*` fields to it). This is the
     zero-config path: the workspace lights up on every submission topic.
4. **Group gate** — the user is in `npn_critique_reply_allowed_group_ids` (staff
   bypass).

## Configuration

All settings live under **Admin → Settings → Plugins** (filter: `npn_critique`).

| Setting | Default | Purpose |
| --- | --- | --- |
| `npn_critique_reply_enabled` | `true` | Master on/off. |
| `npn_critique_reply_enabled_category_ids` | "" | Categories where the workspace is offered. **Empty → offered on any topic carrying submissions metadata.** If you restrict this, add every submission category (including the New Members Area category) you want critiques on. |
| `npn_critique_reply_allowed_group_ids` | "" | Groups whose members may critique (staff always may). |
| `npn_critique_reply_show_below_op` | `true` | Show the invitation panel below the first post. |
| `npn_critique_reply_button_label` | "Start a Critique" | Footer button label. |
| `npn_critique_reply_visual_notes_enabled` | `false` | Enable the visual-annotation canvas. |
| `npn_critique_reply_visual_notes_allowed_group_ids` | "" | Groups allowed to use visual notes (empty → all eligible critics). |
| `npn_critique_reply_processing_examples_enabled` | `true` | Global gate for the processing-example workflow (per-topic override via the `npn_processing_examples_allowed` custom field written by the submissions form). |
| `npn_critique_reply_server_drafts_enabled` | `true` | Autosave in-progress critiques server-side. |
| `npn_critique_reply_draft_ttl_days` | `30` | How long server drafts are retained. |
| `npn_critique_reply_rich_editor_experiment` | `true` | Use the WYSIWYG (ProseMirror) critique field; set `false` to fall back to a plain textarea. |
| `npn_critique_reply_docked_experiment` | `false` | Experimental docked (side-panel) workspace layout. |
| `npn_critique_reply_fontawesome_pro_light_icons` | `false` | Use FontAwesome Pro light icons (dev environments have no Pro fonts). |
| `npn_critique_reply_debug_enabled` | `false` | Verbose client/server debug logging. |

## Relationship to discourse-npn-submissions

This plugin is a **read-side consumer** of `discourse-npn-submissions`. There are
no direct API calls between them — the contract is the shared `npn_*`-prefixed
topic custom fields and `topic_view` serializer attributes the submissions plugin
writes:

- **Presence** — `npn_submission_type` / `npn_submission_schema_version` mark a
  topic as a submission (the signal used when the category gate is empty).
  Normalized for the client by
  `lib/discourse_npn_critique_reply/topic_metadata_reader.rb` into the
  `npn_critique_reply` serializer object.
- **Image** — `npn_original_primary_image_upload_id` /
  `npn_original_image_upload_ids` / `npn_original_primary_image_url` populate the
  full-resolution annotation canvas and the multi-image picker. When absent
  (pre-plugin / imported topics), the workspace falls back to the topic
  thumbnail.
- **Structured ask** — live `topic_view` attributes (`npn_feedback_requested`,
  `npn_about_this_image`, `npn_technical_details`, …) populate the pinned
  request panel; the workspace falls back to the cooked OP body when they're
  absent.

### New Members Area images

New Members Area image submissions (`new_member_image`) are supported with full
parity: the submissions plugin puts them on the image-version surface
(`Submission::IMAGE_VERSION_TYPES`) and maps `npn_feedback_requested` from the
new-member `feedback` field, so a new-member image gets the same
full-resolution canvas and pinned ask as a regular critique — while staying out
of the submissions daily limit. If `npn_critique_reply_enabled_category_ids` is
restricted (not empty), **add the New Members Area category to it** for the
button to appear there.

## Server surface

Small engine mounted at `/` (`config/routes.rb`):

| Route | Purpose |
| --- | --- |
| `POST /npn-critique-reply/topics/:topic_id/replies` | Create a critique reply (via `PostCreator`). |
| `PUT  /npn-critique-reply/posts/:post_id/critique` | Reopen + update a posted critique (via `PostRevisor`). |
| `GET/PUT/DELETE /npn-critique-reply/topics/:topic_id/draft` | Per-user/per-topic workspace draft CRUD. |

Post custom fields: `npn_visual_notes` (JSON annotation schema),
`npn_processing_example`. `topic_view` serializer additions: `npn_critique_reply`
(normalized submission metadata) and `npn_critique_reply_has_draft`.

## Installation

Standard Discourse plugin install:

```
cd /var/discourse
# add to containers/app.yml under hooks/after_code:
#   - git clone https://github.com/davidkingham/discourse-npn-critique-reply.git
./launcher rebuild app
```

`discourse-npn-submissions` should be installed alongside it — this plugin is
inert on topics that carry no submission metadata (unless you point
`npn_critique_reply_enabled_category_ids` at categories directly).

For local dev, clone into `plugins/` and restart `ember-cli` + `unicorn`/`puma`.

## Testing

Backend specs (run inside the Discourse repo with plugins loaded):

```
LOAD_PLUGINS=1 bin/rspec plugins/discourse-npn-critique-reply/spec
```

## License

MIT.
