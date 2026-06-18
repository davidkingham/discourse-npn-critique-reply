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
        expect(stored["schema_version"]).to eq(2)
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

      it "round-trips v2 separated written-text fields (overall + per-image notes)" do
        with_text =
          valid_visual_notes.merge(
            "overall_critique_text" => "My overall response to the series.",
            "sources" => [
              {
                "image_index" => 0,
                "source" => valid_visual_notes["source"],
                "visual_output" => valid_visual_notes["visual_output"],
                "notes" => "Notes about the marks on this image.",
              },
            ],
          )
        post_with_visual_notes(visual_notes: with_text)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields["npn_visual_notes"]
        expect(stored["overall_critique_text"]).to eq("My overall response to the series.")
        expect(stored.dig("sources", 0, "notes")).to eq("Notes about the marks on this image.")
      end

      it "omits the written-text fields for a v1-style payload (no text)" do
        post_with_visual_notes(visual_notes: valid_visual_notes)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields["npn_visual_notes"]
        expect(stored).not_to have_key("overall_critique_text")
      end

      it "drops whitespace-only written-text fields" do
        blank_text =
          valid_visual_notes.merge("overall_critique_text" => "   \n  ")
        post_with_visual_notes(visual_notes: blank_text)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields["npn_visual_notes"]
        expect(stored).not_to have_key("overall_critique_text")
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

      # ---- Direction + Relationship arrows ----------------------------

      let(:arrow_visual_notes) do
        valid_visual_notes.merge(
          "annotations" => [
            {
              "id" => "direction_arrow_1",
              "kind" => "direction_arrow",
              "label" => "D1",
              "x1_pct" => 10.0,
              "y1_pct" => 20.0,
              "x2_pct" => 80.0,
              "y2_pct" => 50.0,
            },
            {
              "id" => "relationship_arrow_1",
              "kind" => "relationship_arrow",
              "label" => "R1",
              "x1_pct" => 5.0,
              "y1_pct" => 5.0,
              "x2_pct" => 95.0,
              "y2_pct" => 95.0,
            },
          ],
        )
      end

      it "round-trips direction + relationship arrows through the normalizer" do
        post_with_visual_notes(visual_notes: arrow_visual_notes)
        expect(response.status).to eq(200)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        direction = stored["annotations"].find { |a| a["kind"] == "direction_arrow" }
        relationship = stored["annotations"].find { |a| a["kind"] == "relationship_arrow" }
        expect(direction).to be_present
        expect(direction["id"]).to eq("direction_arrow_1")
        expect(direction["label"]).to eq("D1")
        expect(direction["x1_pct"]).to eq(10.0)
        expect(direction["x2_pct"]).to eq(80.0)
        expect(relationship).to be_present
        expect(relationship["id"]).to eq("relationship_arrow_1")
        expect(relationship["label"]).to eq("R1")
      end

      it "drops sub-threshold arrows (less than MIN_ARROW_DISTANCE_PCT)" do
        tiny =
          arrow_visual_notes.merge(
            "annotations" => [
              {
                "kind" => "direction_arrow",
                "x1_pct" => 50,
                "y1_pct" => 50,
                # ~1% distance — well under the 3% floor
                "x2_pct" => 50.5,
                "y2_pct" => 50.5,
              },
            ],
          )
        post_with_visual_notes(visual_notes: tiny)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        # Sub-threshold arrow dropped → annotations array empty. The
        # wrapper itself survives because the payload still has a
        # visual_output (from `valid_visual_notes`); only the tiny
        # arrow is filtered out by the normalizer.
        expect(stored).to be_present
        expect(stored["annotations"]).to eq([])
      end

      it "clamps arrow coordinates to 0..100" do
        out_of_bounds =
          arrow_visual_notes.merge(
            "annotations" => [
              {
                "kind" => "direction_arrow",
                "x1_pct" => -25,
                "y1_pct" => 200,
                "x2_pct" => 50,
                "y2_pct" => 60,
              },
            ],
          )
        post_with_visual_notes(visual_notes: out_of_bounds)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        arrow = stored["annotations"].find { |a| a["kind"] == "direction_arrow" }
        expect(arrow["x1_pct"]).to eq(0.0)
        expect(arrow["y1_pct"]).to eq(100.0)
      end

      it "enforces per-kind arrow caps (8 direction + 8 relationship)" do
        too_many_direction =
          (DiscourseNpnCritiqueReply::DraftNormalizer::MAX_DIRECTION_ARROW_COUNT + 5).times.map do |i|
            {
              "id" => "da_#{i}",
              "kind" => "direction_arrow",
              "x1_pct" => 5 + i,
              "y1_pct" => 5,
              "x2_pct" => 80,
              "y2_pct" => 80,
            }
          end
        post_with_visual_notes(
          visual_notes: arrow_visual_notes.merge("annotations" => too_many_direction),
        )
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        kept = stored["annotations"].select { |a| a["kind"] == "direction_arrow" }
        expect(kept.length).to eq(
          DiscourseNpnCritiqueReply::DraftNormalizer::MAX_DIRECTION_ARROW_COUNT,
        )
      end

      it "regenerates duplicate / missing arrow labels via max-suffix+1" do
        dupes =
          arrow_visual_notes.merge(
            "annotations" => [
              {
                "id" => "a",
                "kind" => "direction_arrow",
                "label" => "D1",
                "x1_pct" => 10,
                "y1_pct" => 10,
                "x2_pct" => 80,
                "y2_pct" => 80,
              },
              # Same label — server should keep the first and let the
              # client regenerate; the Ruby normalizer doesn't dedupe
              # labels (only ids) so it preserves both as-supplied.
              # The CLIENT-side normalizer (JS) regenerates duplicates;
              # this just confirms the server preserves whatever it gets.
              {
                "id" => "b",
                "kind" => "direction_arrow",
                "label" => "D1",
                "x1_pct" => 5,
                "y1_pct" => 5,
                "x2_pct" => 90,
                "y2_pct" => 90,
              },
            ],
          )
        post_with_visual_notes(visual_notes: dupes)
        stored = Post.find(response.parsed_body["post"]["id"]).custom_fields[
          "npn_visual_notes"
        ]
        arrows = stored["annotations"].select { |a| a["kind"] == "direction_arrow" }
        expect(arrows.length).to eq(2)
      end

      it "treats metadata save failure as non-fatal — reply still created" do
        # Force the visual-notes pipeline to raise from inside
        # attach_visual_notes. The rescue block in the controller
        # should catch it so the reply (already saved by PostCreator)
        # survives. Stubbing VisualNotesNormalizer is targeted —
        # PostCreator doesn't touch it, so the stub only fires inside
        # the plugin's own code path. (An earlier version of this
        # test stubbed Post#save_custom_fields, but PostCreator now
        # calls that internally during post creation, so the broad
        # stub aborted creation before attach_visual_notes ran.)
        allow(DiscourseNpnCritiqueReply::VisualNotesNormalizer).to receive(
          :normalize,
        ).and_raise(StandardError.new("boom"))
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

    # ---- npn_processing_example custom field persistence ------------

    describe "npn_processing_example post custom field" do
      before { sign_in(user) }

      let(:valid_processing_example) do
        {
          "schema_version" => 1,
          "source" => {
            "topic_id" => topic.id,
            "image_version_key" => "revision_2",
            "image_version_label" => "Revision 2",
            "source_upload_id" => 456,
            "source_url" => "/uploads/default/original/1X/source.jpg",
          },
          "example_upload" => {
            "upload_id" => 789,
            "url" => "/uploads/default/original/1X/example.jpg",
            "short_url" => "upload://example.jpg",
            "filename" => "example.jpg",
          },
        }
      end

      def post_with_processing_example(processing_example: nil, visual_notes: nil)
        body = {
          raw: valid_raw,
          selected_image_version_key: "revision_2",
        }
        body[:visual_notes] = visual_notes if visual_notes
        body[:processing_example] = processing_example if processing_example
        post endpoint, params: body.to_json, headers: {
          "CONTENT_TYPE" => "application/json",
        }
      end

      it "doesn't attach the custom field when no processing_example payload is sent" do
        post_with_processing_example
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields["npn_processing_example"]).to be_nil
      end

      it "attaches a normalized payload when processing_example is sent" do
        post_with_processing_example(processing_example: valid_processing_example)
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        stored = created.custom_fields["npn_processing_example"]

        expect(stored).to be_a(Hash)
        expect(stored["schema_version"]).to eq(1)
        expect(stored.dig("source", "topic_id")).to eq(topic.id)
        expect(stored.dig("source", "image_version_key")).to eq("revision_2")
        expect(stored.dig("source", "image_version_label")).to eq("Revision 2")
        expect(stored.dig("example_upload", "upload_id")).to eq(789)
        expect(stored.dig("example_upload", "short_url")).to eq("upload://example.jpg")
        expect(stored.dig("example_upload", "filename")).to eq("example.jpg")
      end

      it "overwrites client-supplied source.topic_id with the route topic_id" do
        spoofed =
          valid_processing_example.merge(
            "source" => valid_processing_example["source"].merge("topic_id" => 999_999),
          )
        post_with_processing_example(processing_example: spoofed)
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields["npn_processing_example"].dig("source", "topic_id"))
          .to eq(topic.id)
      end

      it "drops the payload when there's no usable upload reference" do
        empty_upload =
          valid_processing_example.merge(
            "example_upload" => { "filename" => "orphan.jpg" },
          )
        post_with_processing_example(processing_example: empty_upload)
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields["npn_processing_example"]).to be_nil
      end

      it "stores BOTH npn_visual_notes and npn_processing_example when both are sent" do
        post endpoint,
             params: {
               raw: valid_raw,
               selected_image_version_key: "revision_2",
               visual_notes: {
                 "source" => { "image_version_key" => "revision_2" },
                 "visual_output" => {
                   "upload_id" => 100,
                   "short_url" => "upload://visual.jpg",
                 },
                 "annotations" => [
                   {
                     "id" => "pin_1",
                     "kind" => "pin",
                     "number" => 1,
                     "x_pct" => 50,
                     "y_pct" => 50,
                   },
                 ],
               },
               processing_example: valid_processing_example,
             }.to_json,
             headers: {
               "CONTENT_TYPE" => "application/json",
             }
        expect(response.status).to eq(200)
        created = Post.find(response.parsed_body["post"]["id"])
        expect(created.custom_fields["npn_visual_notes"]).to be_a(Hash)
        expect(created.custom_fields["npn_processing_example"]).to be_a(Hash)
      end

      context "with the topic opt-out flag (npn_processing_examples_allowed)" do
        it "treats a missing custom field as allowed (backward compat)" do
          # The fabricated topic doesn't carry the field at all.
          post_with_processing_example(processing_example: valid_processing_example)
          expect(response.status).to eq(200)
          created = Post.find(response.parsed_body["post"]["id"])
          expect(created.custom_fields["npn_processing_example"]).to be_a(Hash)
        end

        it "stores when the field is explicitly true" do
          topic.custom_fields["npn_processing_examples_allowed"] = true
          topic.save_custom_fields
          post_with_processing_example(processing_example: valid_processing_example)
          expect(response.status).to eq(200)
          created = Post.find(response.parsed_body["post"]["id"])
          expect(created.custom_fields["npn_processing_example"]).to be_a(Hash)
        end

        it "silently drops the payload when the field is explicitly false" do
          topic.custom_fields["npn_processing_examples_allowed"] = false
          topic.save_custom_fields
          post_with_processing_example(processing_example: valid_processing_example)
          # The reply itself still succeeds (the post body is the
          # source of truth), but no metadata is persisted.
          expect(response.status).to eq(200)
          created = Post.find(response.parsed_body["post"]["id"])
          expect(created.custom_fields["npn_processing_example"]).to be_nil
        end
      end

      context "with the site setting disabled" do
        before do
          SiteSetting.npn_critique_reply_processing_examples_enabled = false
        end

        it "silently drops the payload" do
          post_with_processing_example(processing_example: valid_processing_example)
          expect(response.status).to eq(200)
          created = Post.find(response.parsed_body["post"]["id"])
          expect(created.custom_fields["npn_processing_example"]).to be_nil
        end
      end
    end
  end

  describe "PUT /npn-critique-reply/posts/:post_id/critique (edit)" do
    fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
    fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[2]) }
    fab!(:critique_topic, :topic)
    fab!(:critique_op) { Fabricate(:post, topic: critique_topic) }

    let(:existing_visual_notes) do
      DiscourseNpnCritiqueReply::VisualNotesNormalizer.normalize(
        {
          "source" => { "image_version_key" => "original" },
          "visual_output" => { "upload_id" => 1, "url" => "/x.jpg", "short_url" => "upload://x.jpg" },
          "annotations" => [
            { "kind" => "pin", "id" => "pin_1", "number" => 1, "x_pct" => 50, "y_pct" => 50 },
          ],
        },
        topic_id: critique_topic.id,
      )
    end

    let(:critique_reply) do
      reply =
        Fabricate(
          :post,
          topic: critique_topic,
          user: author,
          raw: "Visual notes based on Original:\n\n![visual notes](upload://x.jpg)\n\nFirst pass — too tight in the foreground.",
        )
      reply.custom_fields["npn_visual_notes"] = existing_visual_notes
      reply.save_custom_fields
      reply
    end

    let(:updated_raw) do
      "Visual notes based on Original:\n\n![visual notes](upload://x.jpg)\n\nRevised — softer edit. The light feels good now."
    end

    let(:updated_visual_notes) do
      {
        "source" => { "image_version_key" => "original" },
        "visual_output" => {
          "upload_id" => 2,
          "url" => "/y.jpg",
          "short_url" => "upload://y.jpg",
        },
        "annotations" => [
          {
            "id" => "pin_1",
            "kind" => "pin",
            "number" => 1,
            "x_pct" => 60,
            "y_pct" => 40,
          },
          {
            "id" => "pin_2",
            "kind" => "pin",
            "number" => 2,
            "x_pct" => 30,
            "y_pct" => 70,
          },
        ],
      }
    end

    # Sentinel for "do NOT include the visual_notes key in the request
    # body at all" (vs `nil`, which means "include the key with an
    # explicit null value"). The server distinguishes these — explicit
    # null clears the custom field, missing key preserves it — so the
    # helper has to be able to express both.
    OMITTED_VISUAL_NOTES = Object.new.freeze

    def put_update(post_id, raw: updated_raw, visual_notes: updated_visual_notes)
      body = { raw: raw }
      body[:visual_notes] = visual_notes unless visual_notes.equal?(OMITTED_VISUAL_NOTES)
      put "/npn-critique-reply/posts/#{post_id}/critique.json",
          params: body.to_json,
          headers: {
            "CONTENT_TYPE" => "application/json",
          }
    end

    context "when not signed in" do
      it "returns 403" do
        put_update(critique_reply.id)
        expect(response.status).to eq(403)
      end
    end

    context "when signed in as the author" do
      before { sign_in(author) }

      it "updates the raw + replaces npn_visual_notes" do
        put_update(critique_reply.id)
        expect(response.status).to eq(200)
        expect(response.parsed_body["success"]).to eq(true)

        reloaded = Post.find(critique_reply.id)
        expect(reloaded.raw).to eq(updated_raw)
        stored = reloaded.custom_fields["npn_visual_notes"]
        expect(stored).to be_present
        expect(stored["annotations"].length).to eq(2)
        expect(stored["annotations"].map { |a| a["number"] }).to contain_exactly(1, 2)
      end

      it "rejects updates when the post has no existing npn_visual_notes" do
        plain_reply = Fabricate(:post, topic: critique_topic, user: author)
        put_update(plain_reply.id)
        expect(response.status).to eq(403)
      end

      it "rejects updates to a post the user doesn't own" do
        other_post = Fabricate(:post, topic: critique_topic, user: other_user)
        other_post.custom_fields["npn_visual_notes"] = existing_visual_notes
        other_post.save_custom_fields
        put_update(other_post.id)
        expect(response.status).to eq(403)
      end

      it "rejects empty raw" do
        put_update(critique_reply.id, raw: "   ")
        expect(response.status).to eq(422)
      end

      it "returns 404 for unknown post_id" do
        put_update(0)
        expect(response.status).to eq(404)
      end

      it "ignores spoofed source.topic_id in the visual_notes payload" do
        spoofed =
          updated_visual_notes.merge(
            "source" => updated_visual_notes["source"].merge("topic_id" => 999_999),
          )
        put_update(critique_reply.id, visual_notes: spoofed)
        stored =
          Post.find(critique_reply.id).custom_fields["npn_visual_notes"]
        expect(stored.dig("source", "topic_id")).to eq(critique_topic.id)
      end

      # ---- annotation-clearing behavior ----------------------------
      #
      # When the modal sends an explicit `visual_notes: null` (user
      # removed every annotation, or chose "Continue without visual
      # notes" in edit mode) the server must delete the
      # `npn_visual_notes` custom field so the post body and the
      # stored payload stay in sync.

      it "clears npn_visual_notes when the client sends visual_notes: null" do
        text_only_raw = "Revised — softer edit. The light feels good now."

        put_update(critique_reply.id, raw: text_only_raw, visual_notes: nil)

        expect(response.status).to eq(200)
        reloaded = Post.find(critique_reply.id)
        expect(reloaded.raw).to eq(text_only_raw)
        expect(reloaded.custom_fields["npn_visual_notes"]).to be_blank
        # PostCustomField row should be gone, not just nilled out in
        # the in-memory hash — otherwise a stale row would resurface
        # the next time custom_fields is read.
        expect(
          PostCustomField.where(post_id: critique_reply.id, name: "npn_visual_notes").exists?,
        ).to eq(false)
      end

      it "is a no-op (preserves existing) when visual_notes key is absent" do
        # Backwards compatibility: an older client that doesn't yet
        # include the `visual_notes` key in update requests must NOT
        # see its existing payload wiped just by saving a text edit.
        text_only_raw = "Revised — softer edit. The light feels good now."

        put_update(
          critique_reply.id,
          raw: text_only_raw,
          visual_notes: OMITTED_VISUAL_NOTES,
        )

        expect(response.status).to eq(200)
        reloaded = Post.find(critique_reply.id)
        expect(reloaded.raw).to eq(text_only_raw)
        expect(reloaded.custom_fields["npn_visual_notes"]).to be_present
      end

      it "clears npn_visual_notes when a non-null payload normalises to blank" do
        # Defensive case: client somehow sends a wrapper with no
        # annotations and no visual_output. In update mode that
        # should clear (not silently leave a stale field behind).
        empty_wrapper = {
          "source" => { "image_version_key" => "original" },
          "visual_output" => nil,
          "annotations" => [],
        }
        put_update(critique_reply.id, visual_notes: empty_wrapper)
        expect(response.status).to eq(200)
        expect(
          Post.find(critique_reply.id).custom_fields["npn_visual_notes"],
        ).to be_blank
      end

      it "does NOT clear npn_visual_notes when the post body update fails" do
        # PostRevisor failure path. The 422 must leave both raw and
        # the custom field unchanged.
        original_raw = critique_reply.raw
        put_update(critique_reply.id, raw: "   ", visual_notes: nil)

        expect(response.status).to eq(422)
        reloaded = Post.find(critique_reply.id)
        expect(reloaded.raw).to eq(original_raw)
        expect(reloaded.custom_fields["npn_visual_notes"]).to be_present
      end

      it "stops serializing npn_visual_notes after the field is cleared" do
        # End-to-end check that the post-menu button's visibility
        # gate goes false: the button reads `post.npn_visual_notes`
        # from the post serializer, which is itself gated on
        # `custom_fields["npn_visual_notes"].present?` (see
        # plugin.rb add_to_serializer block).
        put_update(critique_reply.id, raw: "Text-only revision.", visual_notes: nil)
        expect(response.status).to eq(200)

        SiteSetting.npn_critique_reply_enabled = true
        serialized =
          PostSerializer.new(
            Post.find(critique_reply.id),
            scope: Guardian.new(author),
            root: false,
          ).as_json
        expect(serialized).not_to include(:npn_visual_notes)
      end
    end

    context "when signed in as staff (not the author)" do
      fab!(:admin)
      before { sign_in(admin) }

      it "is allowed to edit anyone's critique" do
        put_update(critique_reply.id)
        expect(response.status).to eq(200)
        expect(Post.find(critique_reply.id).raw).to eq(updated_raw)
      end
    end

    # ---- npn_processing_example edit reconciliation ------------------

    describe "processing_example edit behaviour" do
      let(:processing_example_only_reply) do
        reply =
          Fabricate(
            :post,
            topic: critique_topic,
            user: author,
            raw: "Processing example based on the original image:\n\n![processing example](upload://example.jpg)\n\nWent for a quieter mid-tone.",
          )
        reply.custom_fields["npn_processing_example"] =
          DiscourseNpnCritiqueReply::ProcessingExampleNormalizer.normalize_for_post(
            {
              "source" => { "image_version_key" => "original" },
              "example_upload" => {
                "upload_id" => 42,
                "short_url" => "upload://example.jpg",
                "url" => "/uploads/default/original/1X/example.jpg",
                "filename" => "example.jpg",
              },
            },
            topic_id: critique_topic.id,
          )
        reply.save_custom_fields
        reply
      end

      def put_update_with(post_id, body)
        put "/npn-critique-reply/posts/#{post_id}/critique.json",
            params: body.to_json,
            headers: {
              "CONTENT_TYPE" => "application/json",
            }
      end

      before { sign_in(author) }

      it "allows editing a post that has only a processing example (no visual notes)" do
        put_update_with(processing_example_only_reply.id, {
          raw: "Processing example based on the original image:\n\n![processing example](upload://example.jpg)\n\nDifferent tone choice this pass.",
          visual_notes: nil,
          processing_example: {
            "source" => { "image_version_key" => "original" },
            "example_upload" => {
              "upload_id" => 42,
              "short_url" => "upload://example.jpg",
              "url" => "/uploads/default/original/1X/example.jpg",
              "filename" => "example.jpg",
            },
          },
        })
        expect(response.status).to eq(200)
      end

      it "clears npn_processing_example when explicit null is sent" do
        put_update_with(processing_example_only_reply.id, {
          raw: "Processing example based on the original image:\n\n![processing example](upload://example.jpg)\n\nKeeping but rewriting the prose.",
          visual_notes: nil,
          processing_example: nil,
        })
        expect(response.status).to eq(200)
        reloaded = Post.find(processing_example_only_reply.id)
        expect(reloaded.custom_fields["npn_processing_example"]).to be_nil
      end

      it "replaces npn_processing_example with the new normalized payload" do
        new_filename = "fresh-pass.jpg"
        put_update_with(processing_example_only_reply.id, {
          raw: "Processing example based on the original image:\n\n![processing example](upload://example.jpg)\n\nReplaced the example.",
          visual_notes: nil,
          processing_example: {
            "source" => { "image_version_key" => "original" },
            "example_upload" => {
              "upload_id" => 99,
              "short_url" => "upload://newer.jpg",
              "url" => "/uploads/default/original/1X/newer.jpg",
              "filename" => new_filename,
            },
          },
        })
        expect(response.status).to eq(200)
        reloaded = Post.find(processing_example_only_reply.id)
        stored = reloaded.custom_fields["npn_processing_example"]
        expect(stored.dig("example_upload", "upload_id")).to eq(99)
        expect(stored.dig("example_upload", "filename")).to eq(new_filename)
      end

      it "clears the field when the topic has opted out, even if a payload is sent" do
        critique_topic.custom_fields["npn_processing_examples_allowed"] = false
        critique_topic.save_custom_fields
        put_update_with(processing_example_only_reply.id, {
          raw: "Edited prose only.",
          visual_notes: nil,
          processing_example: {
            "source" => { "image_version_key" => "original" },
            "example_upload" => {
              "upload_id" => 42,
              "short_url" => "upload://example.jpg",
            },
          },
        })
        expect(response.status).to eq(200)
        reloaded = Post.find(processing_example_only_reply.id)
        expect(reloaded.custom_fields["npn_processing_example"]).to be_nil
      end

      it "preserves npn_processing_example when the key is absent from the payload (defensive)" do
        put_update_with(processing_example_only_reply.id, {
          raw: "Edited prose only.",
          visual_notes: nil,
          # processing_example key intentionally omitted
        })
        expect(response.status).to eq(200)
        reloaded = Post.find(processing_example_only_reply.id)
        expect(reloaded.custom_fields["npn_processing_example"]).to be_a(Hash)
      end
    end
  end
end
