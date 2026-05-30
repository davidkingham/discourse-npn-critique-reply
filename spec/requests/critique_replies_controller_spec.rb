# frozen_string_literal: true

require "rails_helper"

describe DiscourseNpnCritiqueReply::CritiqueRepliesController do
  # Fabricated users default to trust level 0, which trips PostCreator's
  # newuser link/embedded-media validator on any post containing an
  # image reference (see `newuser_links_validator`). The visual-notes
  # test below includes image markdown, so seed both users at trust
  # level 1+ — that bypasses the newuser limits without changing any
  # of the permission flows the other tests exercise.
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:another_user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic)
  fab!(:topic_post) { Fabricate(:post, topic: topic) }

  # Discourse's request specs hit the JSON suffix explicitly — without it
  # Rails defaults the request format to HTML and core's ember_cli /
  # exception-rendering layer ends up taking over before this engine's
  # controller can render its JSON response.
  let(:endpoint) { "/npn-critique-reply/topics/#{topic.id}/replies.json" }
  let(:valid_raw) { "This is a thoughtful critique that exceeds the minimum length." }

  describe "POST /npn-critique-reply/topics/:topic_id/replies" do
    context "when not signed in" do
      it "returns 403" do
        post endpoint, params: { raw: valid_raw }
        expect(response.status).to eq(403)
      end
    end

    context "when signed in" do
      before { sign_in(user) }

      it "creates a normal reply on the topic" do
        expect {
          post endpoint, params: { raw: valid_raw }
        }.to change { topic.reload.posts.count }.by(1)

        expect(response.status).to eq(200)
        body = response.parsed_body
        expect(body["success"]).to eq(true)
        expect(body.dig("post", "topic_id")).to eq(topic.id)
        expect(body.dig("post", "post_number")).to be > 1

        new_post = Post.find(body["post"]["id"])
        expect(new_post.raw).to eq(valid_raw)
        expect(new_post.user_id).to eq(user.id)
        expect(new_post.topic_id).to eq(topic.id)
      end

      it "rejects empty raw with 422 and does not create a post" do
        expect { post endpoint, params: { raw: "   " } }.not_to(
          change { Post.count },
        )

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to be_present
      end

      it "rejects missing raw with 422" do
        post endpoint, params: {}
        expect(response.status).to eq(422)
      end

      it "returns 404 for an unknown topic_id" do
        post "/npn-critique-reply/topics/0/replies.json", params: { raw: valid_raw }
        expect(response.status).to eq(404)
      end

      it "returns 403 on a closed topic for a non-staff user" do
        topic.update!(closed: true)
        post endpoint, params: { raw: valid_raw }
        expect(response.status).to eq(403)
      end

      it "returns 403 on an archived topic for a non-staff user" do
        topic.update!(archived: true)
        post endpoint, params: { raw: valid_raw }
        expect(response.status).to eq(403)
      end

      it "surfaces PostCreator validation errors as 422" do
        # Raw below SiteSetting.min_post_length triggers a PostCreator error
        SiteSetting.min_post_length = 50
        post endpoint, params: { raw: "too short" }
        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to be_present
      end

      it "ignores selected_image_version_key for permissions but accepts it in payload" do
        post endpoint,
             params: {
               raw: valid_raw,
               selected_image_version_key: "revision_2",
             }
        expect(response.status).to eq(200)
      end

      it "stores the raw exactly as submitted (does not add the revision prefix server-side)" do
        prefixed_raw = "Regarding Revision 2:\n\n#{valid_raw}"
        post endpoint, params: { raw: prefixed_raw }
        expect(response.status).to eq(200)
        new_post = Post.find(response.parsed_body["post"]["id"])
        expect(new_post.raw).to eq(prefixed_raw)
      end

      it "accepts a visual-notes payload (heading + image markdown + body)" do
        # Sanity-check the multi-paragraph shape produced by the modal
        # when visual notes are included. PostCreator validates upload
        # references, so reference a real fabricated upload via its
        # short_url rather than an arbitrary `upload://abc.jpg`.
        visual_notes_upload = Fabricate(:upload, user: user)
        notes_raw = <<~RAW.chomp
          Visual notes based on Revision 2:

          ![visual notes](#{visual_notes_upload.short_url})

          #{valid_raw}
        RAW
        post endpoint,
             params: {
               raw: notes_raw,
               selected_image_version_key: "revision_2",
             }
        expect(response.status).to eq(200)
        new_post = Post.find(response.parsed_body["post"]["id"])
        expect(new_post.raw).to eq(notes_raw)
      end
    end

    context "with a topic the user cannot reply to (category permission)" do
      fab!(:private_group, :group)
      fab!(:private_category) { Fabricate(:private_category, group: private_group) }
      fab!(:private_topic) { Fabricate(:topic, category: private_category) }

      before { sign_in(another_user) }

      it "returns 403" do
        post "/npn-critique-reply/topics/#{private_topic.id}/replies.json",
             params: {
               raw: valid_raw,
             }
        expect(response.status).to eq(403)
      end
    end
  end
end
