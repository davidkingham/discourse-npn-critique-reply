# frozen_string_literal: true

require "rails_helper"

describe DiscourseNpnCritiqueReply::UnansweredCritics do
  fab!(:author) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:sarah) { Fabricate(:user, username: "sarah", name: "Sarah Marsh") }
  fab!(:tom) { Fabricate(:user, username: "tom") }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:op) { Fabricate(:post, topic: topic, user: author) }

  def usernames(user = author)
    described_class.for(topic: topic, user: user).map { |c| c[:username] }
  end

  def reply(user, raw: "Some thoughts on this image.", reply_to: nil)
    PostCreator.create!(
      user,
      topic_id: topic.id,
      raw: raw,
      reply_to_post_number: reply_to&.post_number,
      skip_validations: true,
    )
  end

  it "is empty when nobody has replied" do
    expect(usernames).to eq([])
  end

  it "lists critics the author has not answered, oldest first, with names" do
    reply(sarah)
    reply(tom)

    expect(described_class.for(topic: topic, user: author)).to eq(
      [{ username: "sarah", name: "Sarah Marsh" }, { username: "tom", name: tom.name }],
    )
  end

  it "returns nothing for anyone but the topic author" do
    reply(sarah)

    expect(usernames(tom)).to eq([])
    expect(described_class.for(topic: topic, user: nil)).to eq([])
  end

  it "treats a direct reply as an answer" do
    sarahs = reply(sarah)
    reply(tom)
    reply(author, reply_to: sarahs)

    expect(usernames).to eq(["tom"])
  end

  it "treats an @mention as an answer" do
    reply(sarah)
    reply(tom)
    reply(author, raw: "Thank you @sarah and @TOM, both really helpful.")

    expect(usernames).to eq([])
  end

  it "ignores an @name inside a code block" do
    reply(sarah)
    reply(author, raw: "Here is the syntax:\n\n```\n@sarah\n```")

    expect(usernames).to eq(["sarah"])
  end

  it "lists a critic again when they post after being answered" do
    reply(sarah)
    reply(author, raw: "Thanks @sarah, good point.")
    reply(sarah, raw: "One more thought about the foreground.")

    expect(usernames).to eq(["sarah"])
  end

  it "ignores whispers, hidden posts and deleted posts" do
    reply(sarah).update!(hidden: true)
    reply(tom).trash!
    Fabricate(:post, topic: topic, user: Fabricate(:admin), post_type: Post.types[:whisper])

    expect(usernames).to eq([])
  end

  it "caps the list at the author's mention limit" do
    SiteSetting.max_mentions_per_post = 1
    author.update!(trust_level: TrustLevel[2])
    reply(sarah)
    reply(tom)

    expect(usernames).to eq(["sarah"])
  end
end
