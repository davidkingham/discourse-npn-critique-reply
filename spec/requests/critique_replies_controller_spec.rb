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

    # ---- npn_visual_notes custom field persistence ------------------

    describe "npn_visual_notes post custom field" do
      before { sign_in(user) }

      let(:valid_visual_notes) do
        {
          "schema_version" => 1,
          "source" => {
            "topic_id" => topic.id,
            "image_version_key" => "revision_2",
            "image_version_label" => "Revision 2",
            "source_upload_id" => 456,
            "source_url" => "/uploads/default/original/1X/source.jpg",
          },
          "visual_output" => {
            "upload_id" => 789,
            "url" => "/uploads/default/original/1X/visual-notes.jpg",
            "short_url" => "upload://abc.jpg",
          },
          "annotations" => [
            {
              "id" => "pin_1",
              "kind" => "pin",
              "number" => 1,
              "x_pct" => 42.3,
              "y_pct" => 57.8,
            },
            {
              "id" => "crop_1",
              "kind" => "crop",
              "x_pct" => 8.0,
              "y_pct" => 10.0,
              "width_pct" => 80.0,
              "height_pct" => 70.0,
              "aspect_ratio" => "free",
            },
          ],
        }
      end

      def post_with_visual_notes(visual_notes: nil)
        body = {
          raw: valid_raw,
          selected_image_version_key: "revision_2",
        }
        body[:visual_notes] = visual_notes if visual_notes
        post endpoint, params: body.to_json, headers: {
          "CONTENT_TYPE" => "application/json",
        }
      end

      it "doesn't attach the custom field when no visual_notes payload is sent" do
        post_with_visual_notes
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields["npn_visual_notes"]).to be_nil
      end

      it "attaches a normalized payload when visual_notes is sent" do
        post_with_visual_notes(visual_notes: valid_visual_notes)
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        stored = created.custom_fields["npn_visual_notes"]

        expect(stored).to be_a(Hash)
        expect(stored["schema_version"]).to eq(1)
        expect(stored.dig("source", "topic_id")).to eq(topic.id)
        expect(stored.dig("source", "image_version_key")).to eq("revision_2")
        expect(stored.dig("source", "image_version_label")).to eq("Revision 2")
        expect(stored.dig("visual_output", "upload_id")).to eq(789)
        expect(stored.dig("visual_output", "short_url")).to eq("upload://abc.jpg")
        expect(stored["annotations"].map { |a| a["kind"] }).to contain_exactly(
          "pin",
          "crop",
        )
      end

      it "overwrites client-supplied source.topic_id with the route topic_id" do
        spoofed =
          valid_visual_notes.merge(
            "source" => valid_visual_notes["source"].merge("topic_id" => 999_999),
          )
        post_with_visual_notes(visual_notes: spoofed)
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields.dig("npn_visual_notes", "source", "topic_id"))
          .to eq(topic.id)
      end

      it "drops invalid annotations but keeps the valid ones" do
        with_bad =
          valid_visual_notes.merge(
            "annotations" => [
              { "kind" => "junk" }, # unknown kind
              { "kind" => "pin", "x_pct" => 50 }, # missing number
              {
                "kind" => "pin",
                "id" => "pin_ok",
                "number" => 1,
                "x_pct" => 50,
                "y_pct" => 50,
              }, # valid
            ],
          )
        post_with_visual_notes(visual_notes: with_bad)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        expect(stored["annotations"].length).to eq(1)
        expect(stored["annotations"].first["kind"]).to eq("pin")
      end

      it "drops unknown annotation kinds without rejecting the save" do
        with_unknown =
          valid_visual_notes.merge(
            "annotations" => [
              { "kind" => "rectangle", "x_pct" => 0, "y_pct" => 0 },
              { "kind" => "text", "x_pct" => 0, "y_pct" => 0 },
            ],
          )
        post_with_visual_notes(visual_notes: with_unknown)
        # Empty annotations + no visual_output drops to no-store, so
        # the custom field is intentionally absent in that case. Here
        # we still have visual_output, so the wrapper persists with
        # an empty annotations array.
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        expect(stored).to be_present
        expect(stored["annotations"]).to eq([])
      end

      it "caps the annotations array at MAX_ANNOTATION_COUNT" do
        too_many =
          (DiscourseNpnCritiqueReply::DraftNormalizer::MAX_ANNOTATION_COUNT + 10).times.map do |i|
            {
              "id" => "ap_#{i}",
              "kind" => "attention_pull",
              "x_pct" => 10,
              "y_pct" => 10,
              "width_pct" => 5,
              "height_pct" => 5,
            }
          end
        post_with_visual_notes(visual_notes: valid_visual_notes.merge("annotations" => too_many))
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        # Per-kind cap kicks in first (MAX_ATTENTION_PULL_COUNT = 8).
        expect(stored["annotations"].length).to eq(
          DiscourseNpnCritiqueReply::DraftNormalizer::MAX_ATTENTION_PULL_COUNT,
        )
      end

      it "treats metadata save failure as non-fatal — reply still created" do
        # Force the custom_fields save to raise via stub. The reply
        # itself must still be created and a 200 returned.
        allow_any_instance_of(Post).to receive(:save_custom_fields).and_raise(
          StandardError.new("boom"),
        )
        expect { post_with_visual_notes(visual_notes: valid_visual_notes) }.to(
          change { topic.reload.posts.count }.by(1),
        )
        expect(response.status).to eq(200)
        expect(response.parsed_body["success"]).to eq(true)
      end

      it "does not write the field when text-only critique (no visual_notes param)" do
        post_with_visual_notes # no visual_notes argument
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields).not_to include("npn_visual_notes")
      end

      it "does not write the field for the Post-without-visual-notes fallback" do
        # That flow simply omits the visual_notes param; same effect as
        # the text-only case above. Asserted separately so the intent
        # is documented.
        post endpoint,
             params: { raw: valid_raw }.to_json,
             headers: {
               "CONTENT_TYPE" => "application/json",
             }
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields).not_to include("npn_visual_notes")
      end

      it "does not write metadata when post creation fails" do
        # Force a PostCreator failure by setting min_post_length above
        # the raw length.
        SiteSetting.min_post_length = 5_000
        post_with_visual_notes(visual_notes: valid_visual_notes)
        expect(response.status).to eq(422)
        # No post exists, so no custom field could have been written.
        # We assert no NEW custom field row was inserted with the
        # visual-notes key.
        expect(
          PostCustomField.where(name: "npn_visual_notes").exists?,
        ).to eq(false)
      end

      it "does not write metadata on closed-topic 403" do
        topic.update!(closed: true)
        post_with_visual_notes(visual_notes: valid_visual_notes)
        expect(response.status).to eq(403)
        expect(
          PostCustomField.where(name: "npn_visual_notes").exists?,
        ).to eq(false)
      end
    end
  end
end
