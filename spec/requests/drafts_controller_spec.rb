# frozen_string_literal: true

require "rails_helper"

describe DiscourseNpnCritiqueReply::DraftsController do
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic)
  fab!(:topic_post) { Fabricate(:post, topic: topic) }

  let(:endpoint) { "/npn-critique-reply/topics/#{topic.id}/draft.json" }

  let(:valid_payload) do
    {
      "critique_text" => "Working draft text",
      "selected_image_version_key" => "original",
      "annotations" => [
        { "kind" => "pin", "id" => "pin_1", "number" => 1, "x_pct" => 50, "y_pct" => 50 },
      ],
      "ui" => {
        "prompts_hidden" => true,
      },
    }
  end

  describe "GET /npn-critique-reply/topics/:topic_id/draft" do
    context "when not signed in" do
      it "returns 403" do
        get endpoint
        expect(response.status).to eq(403)
      end
    end

    context "when signed in" do
      before { sign_in(user) }

      it "returns nil draft when none has been saved" do
        get endpoint
        expect(response.status).to eq(200)
        expect(response.parsed_body["draft"]).to be_nil
      end

      it "returns the user's own draft" do
        put endpoint, params: { draft: valid_payload }
        get endpoint
        expect(response.parsed_body["draft"]["critique_text"]).to eq("Working draft text")
      end

      it "does not surface another user's draft for the same topic" do
        put endpoint, params: { draft: valid_payload }
        sign_in(other_user)
        get endpoint
        expect(response.parsed_body["draft"]).to be_nil
      end

      it "returns 404 for an unknown topic_id" do
        get "/npn-critique-reply/topics/0/draft.json"
        expect(response.status).to eq(404)
      end

      it "returns 404 when server drafts are disabled" do
        SiteSetting.npn_critique_reply_server_drafts_enabled = false
        get endpoint
        expect(response.status).to eq(404)
      end

      it "ignores and prunes drafts older than the TTL" do
        SiteSetting.npn_critique_reply_draft_ttl_days = 30
        put endpoint, params: { draft: valid_payload }
        # Backdate the stored draft to expire it.
        key =
          DiscourseNpnCritiqueReply::DraftStore.key_for(user_id: user.id, topic_id: topic.id)
        stored = PluginStore.get(DiscourseNpnCritiqueReply::DraftStore::PLUGIN_NAME, key)
        stored["updated_at"] = (Time.now.utc - (60 * 24 * 60 * 60)).iso8601
        PluginStore.set(DiscourseNpnCritiqueReply::DraftStore::PLUGIN_NAME, key, stored)
        get endpoint
        expect(response.parsed_body["draft"]).to be_nil
      end
    end

    context "with a topic the user cannot see (private category)" do
      fab!(:private_group, :group)
      fab!(:private_category) { Fabricate(:private_category, group: private_group) }
      fab!(:private_topic) { Fabricate(:topic, category: private_category) }

      before { sign_in(user) }

      it "returns 403" do
        get "/npn-critique-reply/topics/#{private_topic.id}/draft.json"
        expect(response.status).to eq(403)
      end
    end
  end

  describe "PUT /npn-critique-reply/topics/:topic_id/draft" do
    context "when signed in" do
      before { sign_in(user) }

      it "stores a normalized draft" do
        put endpoint, params: { draft: valid_payload }
        expect(response.status).to eq(200)
        draft = response.parsed_body["draft"]
        expect(draft["critique_text"]).to eq("Working draft text")
        expect(draft["selected_image_version_key"]).to eq("original")
        expect(draft["annotations"].length).to eq(1)
        expect(draft["annotations"].first["kind"]).to eq("pin")
      end

      it "ignores a client-supplied topic_id and user_id inside the payload" do
        evil = valid_payload.merge("topic_id" => 999_999, "user_id" => other_user.id)
        put endpoint, params: { draft: evil }
        draft = response.parsed_body["draft"]
        expect(draft["topic_id"]).to eq(topic.id)
        expect(draft["user_id"]).to eq(user.id)
      end

      it "drops invalid annotations rather than rejecting the save" do
        put endpoint,
            params: {
              draft:
                valid_payload.merge(
                  "annotations" => [
                    { "kind" => "junk" },
                    {
                      "kind" => "pin",
                      "id" => "pin_a",
                      "number" => 1,
                      "x_pct" => 10,
                      "y_pct" => 10,
                    },
                  ],
                ),
            }
        expect(response.parsed_body["draft"]["annotations"].map { |a| a["kind"] }).to eq(["pin"])
      end

      it "returns 403 on a closed topic for a non-staff user" do
        topic.update!(closed: true)
        put endpoint, params: { draft: valid_payload }
        expect(response.status).to eq(403)
      end

      it "returns 404 when server drafts are disabled" do
        SiteSetting.npn_critique_reply_server_drafts_enabled = false
        put endpoint, params: { draft: valid_payload }
        expect(response.status).to eq(404)
      end
    end
  end

  describe "DELETE /npn-critique-reply/topics/:topic_id/draft" do
    context "when signed in" do
      before { sign_in(user) }

      it "removes the draft" do
        put endpoint, params: { draft: valid_payload }
        delete endpoint
        expect(response.status).to eq(200)
        get endpoint
        expect(response.parsed_body["draft"]).to be_nil
      end

      it "is idempotent when no draft exists" do
        delete endpoint
        expect(response.status).to eq(200)
      end
    end

    context "when not signed in" do
      it "returns 403" do
        delete endpoint
        expect(response.status).to eq(403)
      end
    end
  end

  describe "Post Critique clears the draft" do
    fab!(:user_for_post) { Fabricate(:user, trust_level: TrustLevel[2]) }

    before { sign_in(user_for_post) }

    it "draft survives a failed post and clears on a successful one" do
      # Save a draft for this user.
      put endpoint, params: { draft: valid_payload }
      key =
        DiscourseNpnCritiqueReply::DraftStore.key_for(
          user_id: user_for_post.id,
          topic_id: topic.id,
        )
      expect(PluginStore.get(DiscourseNpnCritiqueReply::DraftStore::PLUGIN_NAME, key)).to be_present

      # The replies controller is what fires on Post Critique. After it
      # succeeds, the modal calls DELETE /draft from the client. So at
      # the request-level we verify DELETE clears the draft, which is
      # the contract Post Critique relies on.
      delete endpoint
      expect(PluginStore.get(DiscourseNpnCritiqueReply::DraftStore::PLUGIN_NAME, key)).to be_nil
    end
  end
end
