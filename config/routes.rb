# frozen_string_literal: true

DiscourseNpnCritiqueReply::Engine.routes.draw do
  post "/npn-critique-reply/topics/:topic_id/replies" =>
         "critique_replies#create"
end
