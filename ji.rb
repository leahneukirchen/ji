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
  TRIP_LENGTH = 16
  OPS = [
         # CHANGE THIS
         Digest::SHA256.digest("root" + "\0" + SECRET1)
        ]

  class << self
    def halftrip(tripcode)
      Digest::SHA256.digest(tripcode + "\0" + SECRET1)
    end
    
    def fulltrip(halftrip)
      [Digest::SHA256.digest(halftrip + "\0" + SECRET2)].
        pack("m*")[0..TRIP_LENGTH]
    end
    
    def trip(tripcode)
      fulltrip(halftrip(tripcode))
    end
  end

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
  thread INTEGER default ROWID
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
  last_thread DATETIME default "1970-01-01 00:00:00"
);
SQL
  end

  class Presenter
    def initialize(user)
      @user = user
    end

    def render_posts(posts=@posts)
      r = %Q{<ul id="main"}
      posts.each { |post|
        r << %Q{<li class="post#{moderated(post)}">}
        r << render_post(post)
        r << %Q{</li>}
      }
      r << %Q{</ul>}
      r
    end

    def render_thread(root=@root, children=@children)
      r = ""
      r << render_post(root)
      r << %Q{<ul class="children">}
      children.each { |post, cs|
        r << %Q{<li class="post#{moderated(post)}">}
        r << render_thread(post, cs)
        r << %Q{</li>}
      }
      r << %Q{</ul>}
      r
    end

    def render_post(post)
      return <<EOF
<div class="content">
  #{markup post.content.to_s}
  #{extra(post)}
</div>
<div class="actions">
  <span class="date">#{post.posted}</span>
  <span class="trip">#{post.tripcode}</span>
  <a href="#{post.id}"><b>#{post.id}</b></a>
  #{reply_link(post)}
  #{mod_link(post)}
</div>
EOF
    end

    def reply_link(post)
      if reply
        %{<a class="replylink" href="#{post.id}?reply">reply</a>} 
      else
        ""
      end
    end

    def mod_link(post)
      if @root && @user.can_moderate?(@root)
        %{<a class="moderate" href="/moderate/#{post.id}">!</a>} 
      else
        ""
      end
    end

    def reply
      true
    end

    def extra(post)
      ""
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
    def initialize(user, start=0, items=10)
      super user
      @start = start
      @items = items
    end

    def to_html
      @posts = Post.where("parent IS NULL ORDER BY updated DESC
                                        LIMIT ? OFFSET ?", @items, @start)
      render_posts
    end

    def reply
      false
    end

    def extra(post)
      size = DBH.sc("SELECT count(id) FROM posts WHERE thread = ?", post.thread).to_i
      %Q{<a href="#{post.thread}">#{size-1} more...</a></div>}
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

      def post(text, tripcode, user)
        n = Post.create(:content => text, :tripcode => trip(tripcode))
        n.thread = n.id
        user.last_trip = tripcode
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

    def reply(text, tripcode, user)
      if text == ""
        if tripcode == "bump"
          if user.can_bump?
            post = self
            post.updated = Time.now
            user.bumped  
          end
        else
          user.last_trip = tripcode
          return self
        end
      else
        post = Post.create(:content => text,
                           :tripcode => trip(tripcode),
                           :parent => id,
                           :thread => thread)
        user.last_trip = tripcode
        user.posted
      end

      parent = Post[post.parent]
      while parent
        parent.updated = post.updated
        parent = Post[parent.parent]
      end

      post
    end

    def trip(str)
      self.class.trip(str)
    end

    def moderate(user)
      root = Post[thread]
      if user.can_moderate?(root)
        self.moderated = !self.moderated
      end
    end

    def order
      [moderated ? 1 : 0, -Time.parse(updated).to_i]
    end
  end

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
      (Time.now - Time.parse(last_post)) > 1*60
    end

    def posted
      self.last_post = Time.now
    end

    def can_thread?
      (Time.now - Time.parse(last_thread)) > 15*60
    end

    def posted_thread
      self.last_thread = Time.now
    end

    def can_bump?
      (Time.now - Time.parse(last_bump)) > 2*60*60
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
      tripped?(post.tripcode) || OPS.include?(@last_trip)
    end
  end

  HEADER = DATA.read

  def post_form(description, url, button)
    return <<EOF
<p>#{description}</p>
<form class="reply" method="POST" action="#{url}" >
<textarea name="content" cols=79 rows=15></textarea>
trip: <input type="password" name="tripcode">
<input type="submit" value="#{button}">
</form>
EOF
  end

  def call(env)
    req = Rack::Request.new(env)
    res = Rack::Response.new

    user = User.from(env)

    if req.get?
      case req.path_info
      when "/"                    # overview
        res.write HEADER
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
        res.write Overview.new(user).to_html
        res.write "<hr>"
        res.write post_form("Start new thread:", "/", "new thread")

      when %r{\A/(\d+)\z}         # (sub)thread
        res.write HEADER
        if req.query_string == "reply"
          res.write post_form("Reply:", "/#{$1}", "reply")
        end
        res.write FullThread.new(user, Integer($1)).to_html

      when %r{\A/moderate/(\d+)\z} # moderation
        p = Post[$1]
        p.moderate(user)
        res.redirect "/#{p.thread}"

      else
        res.status = 404
      end
    elsif req.post?
      if user.banned
        res.status = 403
        res.write "You are banned."
      else
        case req.path_info

        when "/logout"
          res.delete_cookie "tripcode"
          res.redirect "/"
          return res.finish

        when "/login"
          user.last_trip = req["tripcode"]
          res.redirect "/"

        when "/"                    # overview
          if user.can_thread?
            new_post = Post.post(req["content"], req["tripcode"], user)
            user.posted_thread
            res.redirect "/#{new_post.id}"
          else
            res.status = 403
            res.write "You cannot yet make another new thread."
          end

        when %r{\A/(\d+)\z}         # (sub)thread
          if user.can_post? || req["body"] == ""
            new_post = Post[$1].reply(req["content"], req["tripcode"], user)
            res.redirect "/#{new_post.thread}#p#{new_post.id}"
          else
            res.status = 403
            res.write "You cannot yet post again."
          end

        else
          res.status = 404
        end

        if user.half_trip
          res.set_cookie("tripcode",
                         {:expires => Time.now + 24*60*60,
                          :httponly => true,
                          :value => user.half_trip})
        end
      end
    end

    res.finish
  end
end

Rack::Handler::WEBrick.run(Ji.new, :Port => 9999)

__END__
<meta charset=utf-8>

<style>
body {
  font: 11pt/1.33 sans-serif;
  background-color: #fff;
  color: #000;
  margin: 3em;
}

#main {
  list-style-type: none;
  margin: 0 0 2em 0;
  padding: 0;
}

.nav {
  float: right;
  list-style-type: none;
  margin: -2em 0.5em 1.5em 0;
}

.nav form {
  display: inline;
}

.nav li {
  display: inline;
}

.post, .reply {
  clear: both;
  margin-top: 1em;
}

.content {
  background-color: #ddd;
  padding: 7pt;
  padding-bottom: 1.5em;
}

.content p {
  padding: 0;
  margin: 0;
}
.content p + p {
  margin: 1em 0 0 0;
}

.content blockquote {
  margin-left: 2em;
}

.content > blockquote {
  color: #777;
}

.content img {
  max-width: 100%;
}

.actions {
  text-align: right;
  position: relative;
  top: -1.5em;
  margin-right: 0.5em;
  background-color: #ddd;
  display: inline;
  float: right;
}

.actions a {
  font-weight: bold;
  text-decoration: none;
}

.actions a b {
  color: black;
}

.actions .trip {
  font-style: italic;
}

.actions .date {
  font-size: 8pt;
}

.children {
  flush: both;
  list-style-type: none;
  padding-left: 6em;
}

.moderated > .content, .moderated > .actions {
  font-size: 8pt;
  background-color: #fff;
}

.moderated > .content {
  border: 1px solid #ddd;
  height: 1em;
  overflow: hidden;
}

.moderated.open > .content {
  height: auto;
}

.selected > .content {
  outline: 2px solid #aaa;
}

.reply textarea {
  width: 100%;
  margin-bottom: 0.5em;
  font: 11pt/1.33 sans-serif;
}

.reply input {
  margin-left: 0.5em;
}

.reply {
  text-align: right;
}
</style>

<script src="http://ajax.googleapis.com/ajax/libs/jquery/1.3/jquery.min.js"></script>
<script>
jQuery(function($) {
  $(".moderated .content").toggle(function() {
    $(this).parent().addClass("open")
  }, function() {
    $(this).parent().removeClass("open")
  })

  $("a.replylink").click(function() {
    $(".reply:has(textarea:empty)").remove()
    $(this).parent().siblings(".children").prepend($('<li><form class="reply" method="POST" action="' + $(this).attr("href") + '" >\
<textarea name="content" cols=79 rows=15></textarea>\
trip: <input type="password" name="tripcode">\
<input type="submit" value="reply">\
</form></li>'))
    return false;
  })

  $(document.location.hash).addClass("selected")
})
</script>
