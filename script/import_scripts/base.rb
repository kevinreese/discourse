module ImportScripts; end

class ImportScripts::Base

  def initialize
    require File.expand_path(File.dirname(__FILE__) + "/../../config/environment")

    @existing_users = {}
    @failed_users = []
    @categories = {}
    @posts = {}
    @topic_lookup = {}

    UserCustomField.where(name: 'import_id').pluck(:user_id, :value).each do |user_id, import_id|
      @existing_users[import_id] = user_id
    end

    CategoryCustomField.where(name: 'import_id').pluck(:category_id, :value).each do |category_id, import_id|
      @categories[import_id] = Category.find(category_id.to_i)
    end

    PostCustomField.where(name: 'import_id').pluck(:post_id, :value).each do |post_id, import_id|
      @posts[import_id] = post_id
    end

    Post.pluck(:id, :topic_id, :post_number).each do |p,t,n|
      @topic_lookup[p] = {topic_id: t, post_number: n}
    end
  end

  def perform
    Rails.logger.level = 3 # :error, so that we don't create log files that are many GB
    SiteSetting.email_domains_blacklist = ''
    RateLimiter.disable

    execute

    update_bumped_at

  ensure
    RateLimiter.enable
  end

  # Implementation will do most of its work in its execute method.
  # It will need to call create_users, create_categories, and create_posts.
  def execute
    raise NotImplementedError
  end

  # Get the Discourse Post id based on the id of the source record
  def post_id_from_imported_post_id(import_id)
    @posts[import_id] || @posts[import_id.to_s]
  end

  # Get the Discourse topic info (a hash) based on the id of the source record
  def topic_lookup_from_imported_post_id(import_id)
    post_id = post_id_from_imported_post_id(import_id)
    post_id ? @topic_lookup[post_id] : nil
  end

  # Get the Discourse User id based on the id of the source user
  def user_id_from_imported_user_id(import_id)
    @existing_users[import_id] || @existing_users[import_id.to_s]
  end

  # Get the Discourse Category id based on the id of the source category
  def category_from_imported_category_id(import_id)
    @categories[import_id] || @categories[import_id.to_s]
  end

  def create_admin(opts={})
    admin = User.new
    admin.email = opts[:email] || "sam.saffron@gmail.com"
    admin.username = opts[:username] || "sam"
    admin.password = SecureRandom.uuid
    admin.save!
    admin.grant_admin!
    admin.change_trust_level!(:regular)
    admin.email_tokens.update_all(confirmed: true)
    admin
  end

  # Iterate through a list of user records to be imported.
  # Takes a collection, and yields to the block for each element.
  # Block should return a hash with the attributes for the User model.
  # Required fields are :id and :email, where :id is the id of the
  # user in the original datasource. The given id will not be used to
  # create the Discourse user record.
  def create_users(results)
    puts "creating users"
    users_created = 0
    users_skipped = 0
    progress = 0

    results.each do |result|
      u = yield(result)

      if user_id_from_imported_user_id(u[:id])
        users_skipped += 1
      elsif u[:email].present?
        new_user = create_user(u, u[:id])

        if new_user.valid?
          @existing_users[u[:id].to_s] = new_user.id
          users_created += 1
        else
          @failed_users << u
          puts "Failed to create user id #{u[:id]} #{new_user.email}: #{new_user.errors.full_messages}"
        end
      else
        @failed_users << u
        puts "Skipping user id #{u[:id]} because email is blank"
      end

      print_status users_created + users_skipped + @failed_users.length, results.size
    end

    puts ''
    puts "created: #{users_created} users"
    puts " failed: #{@failed_users.size}" if @failed_users.size > 0
  end

  def create_user(opts, import_id)
    opts.delete(:id)
    existing = User.where(email: opts[:email].downcase, username: opts[:username]).first
    return existing if existing and existing.custom_fields["import_id"].to_i == import_id.to_i

    opts[:name] = User.suggest_name(opts[:name]) if opts[:name]
    opts[:username] = UserNameSuggester.suggest((opts[:username].present? ? opts[:username] : nil) || opts[:name] || opts[:email])
    opts[:email] = opts[:email].downcase
    opts[:trust_level] = TrustLevel.levels[:basic] unless opts[:trust_level]

    u = User.new(opts)
    u.custom_fields["import_id"] = import_id
    u.custom_fields["import_username"] = opts[:username] if opts[:username].present?

    begin
      u.save!
    rescue
      # try based on email
      existing = User.find_by(email: opts[:email].downcase)
      if existing
        existing.custom_fields["import_id"] = import_id
        existing.save!
        u = existing
      end
    end

    u # If there was an error creating the user, u.errors has the messages
  end

  def find_user_by_import_id(import_id)
    UserCustomField.where(name: 'import_id', value: import_id.to_s).first.try(:user)
  end

  # Iterates through a collection to create categories.
  # The block should return a hash with attributes for the new category.
  # Required fields are :id and :name, where :id is the id of the
  # category in the original datasource. The given id will not be used to
  # create the Discourse category record.
  # Optional attributes are position, description, and parent_category_id.
  def create_categories(results)
    puts "creating categories"

    results.each do |c|
      params = yield(c)
      puts "    #{params[:name]}"
      new_category = create_category(params, params[:id])
      @categories[params[:id]] = new_category
    end
  end

  def create_category(opts, import_id)
    existing = category_from_imported_category_id(import_id)
    return existing if existing

    new_category = Category.new(
      name: opts[:name],
      user_id: -1,
      position: opts[:position],
      description: opts[:description],
      parent_category_id: opts[:parent_category_id]
    )
    new_category.custom_fields["import_id"] = import_id if import_id
    new_category.save!
    new_category
  end

  # Iterates through a collection of posts to be imported.
  # It can create topics and replies.
  # Attributes will be passed to the PostCreator.
  # Topics should give attributes title and category.
  # Replies should provide topic_id. Use topic_lookup_from_imported_post_id to find the topic.
  def create_posts(results, opts={})
    skipped = 0
    created = 0
    total = opts[:total] || results.size

    results.each do |r|
      params = yield(r)

      if params.nil?
        skipped += 1
        next # block returns nil to skip a post
      end

      import_id = params.delete(:id).to_s

      if post_id_from_imported_post_id(import_id)
        skipped += 1 # already imported this post
      else
        begin
          new_post = create_post(params)
          @posts[import_id] = new_post.id
          @topic_lookup[new_post.id] = {post_number: new_post.post_number, topic_id: new_post.topic_id}

          created += 1
        rescue => e
          skipped += 1
          puts "Error creating post #{import_id}. Skipping."
          puts e.message
        end
      end

      print_status skipped + created + (opts[:offset] || 0), total
    end

    return [created, skipped]
  end

  def create_post(opts)
    user = User.find(opts[:user_id])
    opts = opts.merge(skip_validations: true)

    PostCreator.create(user, opts)
  end

  def close_inactive_topics(opts={})
    num_days = opts[:days] || 30
    puts '', "Closing topics that have been inactive for more than #{num_days} days."

    query = Topic.where('last_posted_at < ?', num_days.days.ago).where(closed: false)
    total_count = query.count
    closed_count = 0

    query.find_each do |topic|
      topic.update_status('closed', true, Discourse.system_user)
      closed_count += 1
      print_status(closed_count, total_count)
    end
  end

  def update_bumped_at
    Post.exec_sql("update topics t set bumped_at = (select max(created_at) from posts where topic_id = t.id and post_type != #{Post.types[:moderator_action]})")
  end

  def print_status(current, max)
    print "\r%9d / %d (%5.1f%%)    " % [current, max, ((current.to_f / max.to_f) * 100).round(1)]
  end

  def batches(batch_size)
    offset = 0
    loop do
      yield offset
      offset += batch_size
    end
  end
end
