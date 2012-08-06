require_relative 'content'

class CommentThread < Content
  include Mongo::Voteable
  include Mongoid::Timestamps
  include Mongoid::Taggable

  voteable self, :up => +1, :down => -1

  field :comment_count, type: Integer, default: 0
  field :title, type: String
  field :body, type: String
  field :course_id, type: String
  field :commentable_id, type: String
  field :anonymous, type: Boolean, default: false
  field :closed, type: Boolean, default: false
  field :at_position_list, type: Array, default: []
  field :last_activity_at, type: Time

  include Tire::Model::Search
  include Tire::Model::Callbacks

  #def to_indexed_json
  #  self.to_json
  #end
  
  settings :analyzer => {
    :tags_analyzer => {
      'type' => 'stop',
      'stopwords' => [','],
      #'tokenizer' => "keyword",
      #'type' => "custom",
      #'filter' => ['unique'],
    }
  }
=begin
  , :properties => {
    :tags_array => {
      :type => "mutli_field",
      :fields => {
        :tags => { :type => :array, index: :analyzed},
        :untouched_tags => { :type => :array, index: :not_analyzed},
      }
    }
  }
=end
  mapping do

    indexes :title, type: :string, analyzer: 'i_do_not_exist'#:whitespace#:snowball#, boost: 5.0
    indexes :body, type: :string, analyzer: :whitespace#:snowball
    indexes :tags_in_text, type: :array, as: 'tags_array', index: :analyzed#proc {puts tags_array; tags_array}#, analyzer: :whitespace
    indexes :tags, type: :string, as: 'tags_array', index: :not_analyzed#:analyzer: "lowercase_keyword"#, included_in_all: false
    indexes :created_at, type: :date, included_in_all: false
    indexes :updated_at, type: :date, included_in_all: false
    indexes :last_activity_at, type: :date, included_in_all: false

    indexes :comment_count, type: :integer, included_in_all: false
    indexes :votes_point, type: :integer, as: 'votes_point', included_in_all: false

    indexes :course_id, type: :string, index: :not_analyzed, incldued_in_all: false
    indexes :commentable_id, type: :string, index: :not_analyzed, incldued_in_all: false
    indexes :author_id, type: :string, as: 'author_id', index: :not_analyzed, incldued_in_all: false
  end

  belongs_to :author, class_name: "User", inverse_of: :comment_threads, index: true#, autosave: true
  has_many :comments, dependent: :destroy#, autosave: true# Use destroy to envoke callback on the top-level comments TODO async

  attr_accessible :title, :body, :course_id, :commentable_id, :anonymous, :closed

  validates_presence_of :title
  validates_presence_of :body
  validates_presence_of :course_id # do we really need this?
  validates_presence_of :commentable_id
  validates_presence_of :author, autosave: false

  validate :tag_names_valid
  validate :tag_names_unique

  before_create :set_last_activity_at
  before_update :set_last_activity_at

  def self.recreate_index
    Tire.index 'comment_threads' do
      delete
      create
      CommentThread.tire.index.import CommentThread.all
    end
  end

  def self.new_dumb_thread(options={})
    c = self.new
    c.title = options[:title] || "title"
    c.body = options[:body] || "body"
    c.commentable_id = options[:commentable_id] || "commentable_id"
    c.course_id = options[:course_id] || "course_id"
    c.author = options[:author] || User.first
    c.tags = options[:tags] || "test-tag-1, test-tag-2"
    c.save!
    c
  end

  def root_comments
    Comment.roots.where(comment_thread_id: self.id)
  end

  def commentable
    Commentable.find(commentable_id)
  end

  def subscriptions
    Subscription.where(source_id: id.to_s, source_type: self.class.to_s)
  end

  def subscribers
    subscriptions.map(&:subscriber)
  end

  def to_hash(params={})
    doc = as_document.slice(*%w[title body course_id anonymous commentable_id created_at updated_at at_position_list closed])
                      .merge("id" => _id)
                      .merge("user_id" => author.id)
                      .merge("username" => author.username)
                      .merge("votes" => votes.slice(*%w[count up_count down_count point]))
                      .merge("tags" => tags_array)

    if params[:recursive]
      doc = doc.merge("children" => root_comments.map{|c| c.to_hash(recursive: true)})
    else
      doc = doc.merge("comments_count" => comments.count)
    end
    doc
  end

  def self.tag_name_valid?(tag)
    !!(tag =~ RE_TAG)
  end

private

  RE_HEADCHAR = /[a-z0-9]/
  RE_ENDONLYCHAR = /\+/
  RE_ENDCHAR = /[a-z0-9\#]/
  RE_CHAR = /[a-z0-9\-\#\.]/
  RE_WORD = /#{RE_HEADCHAR}(((#{RE_CHAR})*(#{RE_ENDCHAR})+)?(#{RE_ENDONLYCHAR})*)?/
  RE_TAG = /^#{RE_WORD}( #{RE_WORD})*$/

  

  def tag_names_valid
    unless tags_array.all? {|tag| self.class.tag_name_valid? tag}
      errors.add :tag, "can consist of words, numbers, dashes and spaces only and cannot start with dash"
    end
  end

  def tag_names_unique
    unless tags_array.uniq.size == tags_array.size
      errors.add :tags, "must be unique"
    end
  end

  def set_last_activity_at
    self.last_activity_at = Time.now.utc unless last_activity_at_changed? 
  end
end
