require 'digest/sha2'
require 'time'

require 'm4dbi'
require 'rack'

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
  last_thread DATETIME default "1970-01-01 00:00:00",
  last_trip TEXT
);
SQL
end

class Post < DBI::Model(:posts)
  class << self

  def overview(start=0)
    Post.where("parent IS NULL ORDER BY updated DESC LIMIT 10 OFFSET ?", start)
  end

  def post(text, tripcode, user)
    n = Post.create(:content => text, :tripcode => trip(tripcode))
    user.last_trip = trip(tripcode)  unless trip(tripcode).empty?
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

  def render(id, user=nil, reply=true)
    post, children = thread(id)

    moderate = user && post.parent.nil? && post.tripcode == user.last_trip
    render_thread(post, children, 0, reply, moderate)
  end

  def render_thread(post, children, depth=0, reply=true, moderate=false)
    children = children.sort_by { |p, cs| p.order }
    modlink = %{<a class="moderate" href="/moderate/#{post.id}">!</a>}  if moderate
    replylink = %{<a class="replylink" href="#{post.id}?reply">reply</a>}  if reply

    return <<EOF
<li class="post#{post.moderated ? " moderated" : ""}" id="p#{post.id}">
<div class="content">
  #{markup post.content.to_s}
</div>
<div class="actions">
  <span class="date">#{post.posted}</span>
  <span class="trip">#{post.tripcode}</span>
  <a href="#{post.id}"><b>#{post.id}</b></a>
  #{replylink}
  #{modlink}
</div>
<ul class="children">
#{
  children.map{ |p, cs| render_thread(p, cs, depth+1, reply, moderate) }.join("\n")
}
</ul>
</li>
EOF
  end

  def markup(str)
    str.split(/\n\n+/).map { |para|
      if para =~ /\A(>+) /
        "<blockquote>" * ($1.size) + 
          Rack::Utils.escape_html($') +
          "</blockquote>" * ($1.size)
      else
        "<p>" + Rack::Utils.escape_html(para) + "</p>"
      end
    }.join
  end

  def trip(tripcode, secret="jijijijijiji")
    if tripcode.to_s.empty?
      ""
    else
      [Digest::SHA256.digest(tripcode + "\0" + secret)].pack("m*")[0..16]
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
        user.last_trip = trip(tripcode)  unless trip(tripcode).empty?
        return self
      end
    else
      post = Post.create(:content => text,
                         :tripcode => trip(tripcode),
                         :parent => id,
                         :thread => thread)
      user.last_trip = trip(tripcode)  unless trip(tripcode).empty?
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
    if root.tripcode == user.last_trip
      self.moderated = !self.moderated
    end
  end

  def order
    [moderated ? 1 : 0, -Time.parse(updated).to_i]
  end
end

class User < DBI::Model(:ips)
  def can_post?
    (Time.now - Time.parse(last_post)) > 1*60
  end

  def posted
    self.last_post = Time.now
  end

  def can_thread?
    p [Time.now, last_thread, self]
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
end

class Ji
  HEADER = DATA.read

  def post_form(description, url, button)
    return <<EOF
<p>#{description}</p>
<form class="reply" method="POST" action="#{url}" >
<textarea name="content" cols=79 rows=15></textarea>
trip: <input type="text" name="tripcode">
<input type="submit" value="#{button}">
</form>
EOF
  end
  
  def call(env)
    req = Rack::Request.new(env)
    res = Rack::Response.new

    numeric_ip = env["REMOTE_ADDR"].split(".").inject(0) { |a,e| a<<8 | e.to_i }
    user = User[numeric_ip] || User.create(:id => numeric_ip)

    if user.banned
      res.status = 404
      res.write "You are banned."
      return res.finish
    end

    case req.path_info
    when "/"                    # overview
      if req.post?
        if user.can_thread?
          new_post = Post.post(req["content"], req["tripcode"], user)
          user.posted_thread
          res["Location"] = "/#{new_post.id}"
          res.status = 302
        else
          res.status = 403
          res.write "You cannot yet make another new thread."
        end
      else
        res.write HEADER
        res.write '<ul id="main">'
        Post.overview.each { |post|
          size = DBH.sc("SELECT count(id) FROM posts WHERE thread = ?", post.thread).to_i
          res.write Post.render_thread(post, [], 0, nil, false).sub(
                                                                    "</div>", %Q{<a href="#{post.thread}">#{size-1} more...</a></div>})
        }
        res.write '</ul>'
        res.write "<hr>"
        res.write post_form("Start new thread:", "/", "new thread")
      end
    when %r{\A/(\d+)\z}         # (sub)thread
      if req.post?
        if user.can_post? || req["tripcode"] == ""
          new_post = Post[$1].reply(req["content"], req["tripcode"], user)
          res["Location"] = "/#{new_post.thread}#p#{new_post.id}"
          res.status = 302
        else
          res.status = 403
          res.write "You cannot yet post again."
        end
      else                      # GET
        res.write HEADER
        if req.query_string == "reply"
          res.write post_form("Reply:", "/#{$1}", "reply")
        end
        res.write '<ul id="main">'
        res.write Post.render(Integer($1), user)
        res.write '</ul>'
      end
    when %r{\A/moderate/(\d+)\z} # moderation
      p = Post[$1]
      p.moderate(user)
      res["Location"] = "/#{p.thread}"
      res.status = 302
    else
      res.status = 404
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
  margin: 2em 3em;
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
trip: <input type="text" name="tripcode">\
<input type="submit" value="reply">\
</form></li>'))
    return false;
  })

  $(document.location.hash).addClass("selected")
})
</script>
