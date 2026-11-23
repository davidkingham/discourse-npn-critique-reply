# frozen_string_literal: true

module DiscourseNpnCritiqueReply
  # Who is still waiting on the topic author?
  #
  # Feeds the author's "Respond to critiques" footer button, which opens
  # ONE reply pre-filled with an @mention per person. That is the behaviour
  # we want to make easy: an author who clicks Reply under each of ten
  # critiques sends ten posts and a pile of notifications.
  #
  # A critic is anyone other than the author with a visible regular reply
  # in the topic. They count as answered once the author has, in a LATER
  # post, either replied to them directly or @mentioned them. A critic who
  # posts again after being answered is waiting again.
  #
  # Runs server-side because long topics are only partly loaded in the
  # browser. Two small queries, and only for the author's own page views.
  module UnansweredCritics
    # A cooked user mention: <a class="mention" href="/u/sam">@sam</a>.
    # Read from `cooked` so @names inside code blocks and quotes, which
    # never notified anyone, don't count as an answer.
    MENTION_HREF = %r{<a class="mention" href="[^"]*/u/([^"/]+)"}i

    module_function

    # Returns [{ username:, name: }], oldest waiting critic first, capped
    # at the number of mentions the author may put in one post.
    def for(topic:, user:)
      return [] if topic.blank? || user.blank?
      return [] if topic.user_id != user.id

      replies =
        Post.where(topic_id: topic.id, post_type: Post.types[:regular], hidden: false).where(
          "post_number > 1",
        )

      latest_by_critic =
        replies
          .where.not(user_id: user.id)
          .where("user_id > 0")
          .group(:user_id)
          .maximum(:post_number)
      return [] if latest_by_critic.empty?

      critics = User.where(id: latest_by_critic.keys).pluck(:id, :username, :name)
      id_by_username = critics.to_h { |id, username, _| [username.downcase, id] }

      answered_at = Hash.new(0)
      replies
        .where(user_id: user.id)
        .pluck(:post_number, :reply_to_user_id, :cooked)
        .each do |post_number, reply_to_user_id, cooked|
          addressed = [reply_to_user_id]
          cooked.to_s.scan(MENTION_HREF) { |(name)| addressed << id_by_username[name.downcase] }
          addressed.compact.each do |id|
            answered_at[id] = post_number if post_number > answered_at[id]
          end
        end

      critics
        .select { |id, _, _| latest_by_critic[id] > answered_at[id] }
        .sort_by { |id, _, _| latest_by_critic[id] }
        .first(mention_limit(user))
        .map { |_, username, name| { username: username, name: name } }
    end

    def mention_limit(user)
      limit =
        if user.trust_level == TrustLevel[0]
          SiteSetting.newuser_max_mentions_per_post
        else
          SiteSetting.max_mentions_per_post
        end
      [limit.to_i, 0].max
    end
  end
end
