# frozen_string_literal: true

# name: discourse-npn-critique-reply
# about: Critique-reply helper for Nature Photographers Network. Step 1 exposes submission topic metadata to the frontend.
# version: 0.0.1
# authors: David Kingham
# url: https://github.com/davidkingham/discourse-npn-critique-reply
# license: MIT

enabled_site_setting :npn_critique_reply_enabled

register_asset "stylesheets/common/npn-critique-reply.scss"

# `far-pen-to-square` (Start a Critique topic-footer button) is already in
# core's default SVG_ICONS subset. `crop-simple` (Crop suggestion toolbar
# button) is NOT — register it here so it's included in the icon sprite.
# `route` is used for the Eye path tool button (matches the "guided path"
# product intent — show the order the eye moves through the image).
register_svg_icon "crop-simple"
register_svg_icon "route"
# `highlighter` is used for the Attention Pull tool button — represents
# soft marking of an area without warning-tool connotations.
register_svg_icon "highlighter"
# `circle-check` is used for the Strong Area tool button — the positive
# counterpart to Attention Pull. Visible "supportive observation" cue
# without overreading as "correct answer".
register_svg_icon "circle-check"

module ::DiscourseNpnCritiqueReply
  PLUGIN_NAME = "discourse-npn-critique-reply"
  SERIALIZED_KEY = :npn_critique_reply
end

require_relative "lib/discourse_npn_critique_reply/engine"

after_initialize do
  require_relative "lib/discourse_npn_critique_reply/topic_metadata_reader"
  require_relative "app/controllers/discourse_npn_critique_reply/critique_replies_controller"

  # Single topic view: expose a compact, normalized critique-reply metadata
  # object built from custom fields written by the discourse-npn-submissions
  # plugin. Returns nil when the topic has no recognised submission fields, so
  # client code can branch on presence cheaply.
  add_to_serializer(
    :topic_view,
    DiscourseNpnCritiqueReply::SERIALIZED_KEY,
    include_condition: -> { SiteSetting.npn_critique_reply_enabled },
  ) { DiscourseNpnCritiqueReply::TopicMetadataReader.read(object.topic) }

  # Mount the engine at root — `config/routes.rb` carries the full
  # `/npn-critique-reply/...` prefix, matching the URL the client uses.
  Discourse::Application.routes.append { mount ::DiscourseNpnCritiqueReply::Engine, at: "/" }
end
