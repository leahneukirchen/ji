require 'digest/sha2'
require 'time'

require 'm4dbi'
require 'rack'

class Rack::Response
  def redirect(location)
    self.status = 302
    self["Location"] = location
  end
end

class Ji
  SECRET1 = "jijijijijiji"      # CHANGE THIS
  SECRET2 = "kekekekekeke"      # CHANGE THIS
  OPS = [
         # CHANGE THIS
         Digest::SHA256.digest("root" + "\0" + SECRET1)
        ]

  HEADER = File.read("header.inc")
  FOOTER = File.read("footer.inc")

  TRIP_LENGTH = 16
  DBH = DBI.connect("DBI:SQLite3:db.sqlite")

  unless DBH.tables.include?("posts")
    DBH.do <<SQL
CREATE TABLE posts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  content TEXT,
  tripcode TEXT,
  posted DATE default CURRENT_TIMESTAMP,
  updated DATE default CURRENT_TIMESTAMP,
  moderated BOOLEAN default 0,
  parent INTEGER default NULL,
  thread INTEGER default ROWID,
  board TEXT NOT NULL
);
SQL
  end

  unless DBH.tables.include?("ips")
    DBH.do <<SQL
CREATE TABLE ips (
  id INTEGER PRIMARY KEY,
  banned BOOLEAN default 0,
  last_post DATETIME default "1970-01-01 00:00:00",
  last_bump DATETIME default "1970-01-01 00:00:00",
  last_reply DATETIME default "1970-01-01 00:00:00"
);
SQL
  end

  class << self
    def halftrip(tripcode)
      Digest::SHA256.digest(tripcode + "\0" + SECRET1)
    end
    
    def fulltrip(halftrip)
      [Digest::SHA256.digest(halftrip + "\0" + SECRET2)].
        pack("m*")[0, TRIP_LENGTH]
    end
    
    def trip(tripcode)
      fulltrip(halftrip(tripcode))
    end
  end

  class Presenter
    def initialize(user)
      @user = user
    end

    def render_posts(posts=@posts)
      r = %Q{<ul id="main">}
      posts.each { |post|
        r << %Q{<li class="post#{moderated(post)}">}
        r << render_post(post)
        r << %Q{</li>}
      }
      r << %Q{</ul>}
      r
    end

    def render_thread(root=@root, children=@children)
      children = children.sort_by { |p, cs| p.order }

      r = ""
      r << %Q{<li class="post#{moderated(root)}" id="p#{root.id}">}
      r << render_post(root)
      r << %Q{<ul class="children">}
      children.each { |post, cs|
        r << render_thread(post, cs)
      }
      r << %Q{</ul>}
      r << %Q{</li>}
      r
    end

    def render_post(post)
      return <<EOF
<div class="content">
  #{content(post)}
</div>
<div class="actions">
  <span class="date">#{post.posted}</span>
  #{trip(post)}
  #{permalink(post)}
  #{reply_link(post)}
  #{mod_link(post)}
</div>
EOF
    end

    def content(post)
      markup post.content.to_s
    end

    def trip(post)
      if post.tripcode && !post.tripcode.empty?
        hash = post.tripcode.unpack("m*")[0].gsub(/./mn) { |c| "%02x" % c[0].to_s }
        %Q{<span class="trip" style="background: url(http://www.gravatar.com/avatar/#{hash}?d=identicon&f=1&s=24)" title="#{post.tripcode}">#{post.tripcode}</span>}
      else
        ""
      end
    end

    def reply_link(post)
      if reply
        %{<a class="replylink" href="#{post.id}?reply">reply</a>} 
      else
        ""
      end
    end

    def mod_link(post)
      if @root && @user.can_moderate?(post)
        %{<a class="moderate" href="/moderate/#{post.id}">!</a>} 
      else
        ""
      end
    end

    def permalink(post)
      %Q{<a href="#{post.id}"><b>#{post.id}</b></a>}
    end

    def reply
      true
    end

    def markup(str)
      str.gsub("\r\n", "\n").split(/\n\n+/).map { |para|
        if para =~ /\A(>+) /
          "<blockquote>" * ($1.size) + 
            Rack::Utils.escape_html($') +
            "</blockquote>" * ($1.size)
        else
          body = Rack::Utils.escape_html(para)
          body.gsub!(%r{((?:http://|www\.).*?)(\s|$)}) {
            url = $1
            case url
            when /\.(png|jpe?g|gif)\z/
              %Q{<a rel="nofollow" href="#{url}"><img src="#{url}"></a> }
            else
              %Q{<a rel="nofollow" href="#{url}">#{url}</a> }
            end
          }
          "<p>#{body}</p>"
        end
      }.join
    end

    def moderated(post)
      post.moderated ? " moderated" : ""
    end
  end

  class Overview < Presenter
    def initialize(board, user, start=0, items=10)
      super user
      @board = board
      @start = start
      @items = items
    end

    def to_html
      if @board
        @posts = Post.where("parent IS NULL AND board = ? 
                             ORDER BY moderated, updated DESC
                             LIMIT ? OFFSET ?", @board, @items, @start)
      else
        @posts = Post.where("parent IS NULL ORDER BY moderated, updated DESC
                             LIMIT ? OFFSET ?", @items, @start)
      end

      render_posts
    end

    def reply
      false
    end

    def content(post)
      size = DBH.sc("SELECT count(id) FROM posts WHERE thread = ?", post.thread).to_i
      super +
      if @board.nil?
        %Q{<b>/#{post.board}</b> }
      else
        ""
      end +
      %Q{<a href="#{post.thread}">#{size-1} more...</a></div>}
    end
  end

  class OverviewWithLatest < Presenter
    def initialize(board, user, start=0, items=10, latest=3)
      super user
      @board = board
      @start = start
      @items = items
      @latest = latest
    end

    def to_html
      if @board
        posts = Post.where("parent IS NULL AND board = ?
                            ORDER BY moderated, updated DESC
                            LIMIT ? OFFSET ?", @board, @items, @start)
      else
        posts = Post.where("parent IS NULL ORDER BY moderated, updated DESC
                            LIMIT ? OFFSET ?", @items, @start)
      end

      r = %Q{<ul id="main">}
      posts.each { |post|
        r << %Q{<li class="post#{moderated(post)}" id="p#{post.id}">}
        r << render_post(post)
        r << %Q{<ul class="children">}

        children = Post.where("thread = ? AND moderated = 0
                                          AND parent IS NOT NULL
                               ORDER BY posted DESC LIMIT 5", post.id)
        children.reverse_each { |child|
          r << %Q{<li class="post#{moderated(child)}" id="p#{child.id}">}
          r << render_post(child)
          r << %Q{<ul class="children">}
          r << %Q{</ul>}
          r << %Q{</li>}
        }

        r << %Q{</ul>}
        r << %Q{</li>}
      }
      r << %Q{</ul>}
      r
    end

    def permalink(post)
      %Q{<a href="/#{post.thread}#p#{post.id}"><b>#{post.id}</b></a>}
    end

    def content(post)
      if post.parent 
        if post.parent != post.thread
          %Q{<a href="/#{post.thread}#p#{post.parent}">&gt;&gt; #{post.parent}</a>} + super
        else
          super
        end
      else
        size = DBH.sc("SELECT count(id) FROM posts WHERE thread = ?", post.thread).to_i
        super + %Q{<p>(<b>/#{post.board}</b> <a href="#{post.thread}">#{size} total...</a>)</p>}
      end
    end
  end

  class FullThread < Presenter
    def initialize(user, id)
      super user
      @id = id
    end

    def to_html
      @root, @children = Post.thread(@id)
      %Q{<ul id="main">} + render_thread + "</ul>"
    end
  end

  class Post < DBI::Model(:posts)
    class << self

      def post(text, tripcode, board)
        p board
        n = Post.create(:content => text,
                        :tripcode => trip(tripcode),
                        :board => board)
        n.thread = n.id
        n
      end

      def thread(id)
        root = Post[id]
        posts = Post.where(:thread => root.thread)

        treeize = lambda { |r|
          [r, posts.find_all { |p| p.parent == r.id }.map { |p| treeize[p] }]
        }

        treeize[root]
      end

      def trip(tripcode)
        if tripcode.to_s.empty?
          ""
        else
          Ji.trip(tripcode)
        end
      end

    end

    def reply(text, tripcode, sage)
      if text != ""
        post = Post.create(:content => text,
                           :tripcode => trip(tripcode),
                           :parent => id,
                           :thread => thread,
                           :board => Post[id].board)
      else
        if tripcode == "bump"
          post = self
        else
          raise Forbidden, "No text"
        end
      end

      unless sage
        parent = Post[post.parent]
        while parent
          parent.updated = post.updated
          parent = Post[parent.parent]
        end
      end

      post
    end

    def trip(str)
      self.class.trip(str)
    end

    def moderate
      self.moderated = !self.moderated
    end

    def order
      [moderated ? 1 : 0, -Time.parse(updated).to_i]
    end
  end

  class Forbidden < RuntimeError; end
  class NotFound < RuntimeError; end

  class User < DBI::Model(:ips)
    def self.from(env)
      numeric_ip = (env["HTTP_X_FORWARDED_FOR"] || env["REMOTE_ADDR"]).
        split(".").inject(0) { |a,e| a<<8 | e.to_i }
      user = User[numeric_ip] || User.create(:id => numeric_ip)
      r = Rack::Request.new(env)
      user.instance_variable_set :@last_trip, r.cookies["tripcode"]
      user
    end

    def can_post?
      (Time.now - Time.parse(last_post)) > 5*60
    end

    def posted
      self.last_post = Time.now
    end

    def post(text, tripcode, board)
      if user.can_post?
        new_post = Post.post(text, tripcode, board)
        self.last_trip = tripcode
        new_post
      else
        raise Forbidden, "You cannot yet make another new thread."
      end
    end

    def can_reply?
      (Time.now - Time.parse(last_reply)) > 20
    end

    def posted_reply
      self.last_reply = Time.now
    end

    def reply(id, text, tripcode, sage)
      if can_reply?
        post = Post[id]
        self.last_trip = tripcode  if tripcode && tripcode != "bump"
        
        if text == "" && tripcode == "bump" 
          if can_bump?
            new_post = post.reply(text, tripcode, sage)
            bumped
          else
            new_post = post     # Ignore the bump
          end
        else
          new_post = post.reply(text, tripcode, sage)
          posted_reply
        end
        new_post
      else
        raise Forbidden, "You cannot yet post again."
      end
    end

    def can_bump?
      (Time.now - Time.parse(last_bump)) > 5*60
    end

    def bumped
      self.last_bump = Time.now
    end

    def last_trip=(trip)
      if trip && !trip.empty?
        @last_trip = Ji.halftrip(trip)
      end
    end

    def half_trip
      @last_trip
    end

    def tripped?(trip)
      return false  unless @last_trip  
      Ji.fulltrip(@last_trip) == trip
    end

    def can_moderate?(post)
      tripped?(Post[post.thread].tripcode) || OPS.include?(@last_trip)
    end

    def moderate(id)
      post = Post[id]
      if can_moderate?(post)
        post.moderate
      end
    end
  end

  def post_form(description, url, button, sage=nil)
    s = if sage.nil?
          "" 
        else
          %Q{<label><input type="checkbox" value="sage" #{sage && " checked"} name="sage"> No bump</label>}
        end

    return <<EOF
<p>#{description}</p>
<form class="reply" method="POST" action="#{url}" >
<textarea name="content" cols=79 rows=15></textarea>
trip: <input type="password" name="tripcode">
#{s}
<input type="submit" value="#{button}">
</form>
EOF
  end

  class Boards
    def initialize(boards)
      @boards = {"/" => Ji.new(nil, "Ji")}
      boards.each { |name, desc|
        @boards["/" + name] = Ji.new(name, desc)
      }
      @map = Rack::URLMap.new(@boards)
      p @map
    end

    def call(env)
      @map.call(env)
    end
  end

  def initialize(board=nil, title="Untitled")
    @board = board
    @title = title
  end

  def header
    HEADER.gsub("$TITLE", %{<a href="/#{@board}">/#{@board} – #{@title}</a>})
  end

  def footer
    FOOTER.gsub("$TITLE", %{<a href="/#{@board}">/#{@board} – #{@title}</a>})
  end

  def call(env)
    req = Rack::Request.new(env)
    res = Rack::Response.new

    user = User.from(env)

    begin
      if req.get?
        case req.path_info
        when "/", ""                # overview
          res.write header
          res.write <<EOF
<div class="nav">
  <form method="POST" action="/login">
    trip: <input type="password" name="tripcode" value="">
    <input type="submit" value="log in">
  </form>
  <form method="POST" action="/logout">
    <input type="submit" value="log out">
  </form>
</div>
EOF
          res.write Overview.new(@board, user).to_html
          if @board
            res.write "<hr>"
            res.write post_form("Start new thread:", "/#{@board}", "new thread", nil)
          end
          res.write footer
          
        when "/latest"
          res.write header
          res.write OverviewWithLatest.new(@board, user).to_html
          
        when %r{\A/(\d+)\z}         # (sub)thread
          res.write header
          if @board && req.query_string == "reply"
            res.write post_form("Reply:", "/#{$1}", "reply", false)
          end
          res.write FullThread.new(user, Integer($1)).to_html
          res.write footer
          
        when %r{\A/moderate/(\d+)\z} # moderation
          user.moderate($1)
          p = Post[$1]
          res.redirect "/#{p.thread}"
          
        else
          raise NotFound
        end
      elsif req.post?
        if user.banned
          raise Forbidden, "You are banned."
        else
          case req.path_info
            
          when "/logout"
            res.delete_cookie "tripcode"
            res.redirect "/"
            return res.finish
            
          when "/login"
            user.last_trip = req["tripcode"]
            res.redirect "/"
            
          when "/", ""                # overview
            new_post = user.post(req["content"], req["tripcode"], @board)
            res.redirect "/#{new_post.id}"
            
          when %r{\A/(\d+)\z}         # (sub)thread
            new_post = user.reply($1,
                                  req["content"],
                                  req["tripcode"],
                                  req["sage"] == "sage")
            res.redirect "/#{new_post.thread}#p#{new_post.id}"
            
          else
            raise NotFound
          end
          
          if user.half_trip
            res.set_cookie("tripcode",
                           {:expires => Time.now + 24*60*60,
                             :httponly => true,
                             :value => user.half_trip})
          end
        end
      end

    rescue Forbidden => ex
      res.status = 403
      res.write ex.message
      
    rescue NotFound => ex
      res.status = 404
      
    end
    res.finish
  end
end
