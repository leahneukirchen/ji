require 'digest/sha2'
require 'time'

require 'm4dbi'
require 'rack'

DBH = DBI.connect("DBI:sqlite3:db.sqlite")

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

class Post < DBI::Model(:posts)
  class << self

  def overview(start=0)
    Post.where("parent IS NULL ORDER BY updated LIMIT 10 OFFSET ?", start)
  end

  def post(text, tripcode)
    n = Post.create(:content => text, :tripcode => trip(tripcode))
    n.thread = n.id
    n
  end

  def thread(id)
    posts = Post.where(:thread => id)

    return [Post[id], []]  if posts.empty?     # XXX show full subthread

    root = posts.find { |p| p.parent == nil }
    
    treeize = lambda { |r|
      [r, posts.find_all { |p| p.parent == r.id }.map { |p| treeize[p] }]
    }

    treeize[root]
  end

  def render(id)
    render_thread(*thread(id))
  end

  def render_thread(post, children)
    children = children.sort_by { |p, cs| p.order }

    maintag = post.parent ? "li" : "div"
    return <<EOF
<#{maintag} class="post#{post.moderated ? " moderated" : ""}" id="p#{post.id}">
<div class="content">
  #{post.content}
</div>
<div class="actions">
  <span class="date">#{post.posted}</span>
  <span class="trip">#{post.tripcode}</span>
  <a href="#{post.id}"><b>#{post.id}</b></a>
  <a class="replylink" href="#{post.id}?reply">reply</a>
  <a class="moderate" href="/moderate/#{post.id}">!</a>
</div>
<ul class="children">
#{
  children.map{ |p| render_thread(*p) }.join("\n")
}
</ul>
</#{maintag}>
EOF
  end

  def trip(tripcode, secret="jijijijijiji")
    if tripcode.to_s.empty?
      ""
    else
      [Digest::SHA256.digest(tripcode + "\0" + secret)].pack("m*")[0..16]
    end
  end

  end

  def reply(text, tripcode)
    post = Post.create(:content => text,
                       :tripcode => self.class.trip(tripcode),
                       :parent => id,
                       :thread => thread)
    parent = Post[post.parent]
    while parent
      parent.updated = post.updated
      parent = Post[parent.parent]
    end
    post
  end

  def moderate
    self.moderated = true
  end

  def unmoderate
    self.moderated = false
  end

  def order
    [moderated ? 1 : 0, -Time.parse(updated).to_i]
  end
end

# GET / -> main
# GET /id -> thread
# POST /id

class Ji
  HEADER = DATA.read

  def call(env)
    req = Rack::Request.new(env)
    res = Rack::Response.new

    case req.path_info
    when "/"
      if req.post?
        new_post = Post.post(req["content"], req["tripcode"])
        res["Location"] = "/#{new_post.id}"
        res.status = 302
      else
        res.write HEADER
        Post.overview.each { |post|
          p "foo"
          res.write <<EOF
<div class="post#{post.moderated ? " moderated" : ""}" id="p#{post.id}">
<div class="content">
  #{post.content}
</div>
<div class="actions">
  <span class="date">#{post.posted}</span>
  <span class="trip">#{post.tripcode}</span>
  <a href="#{post.id}"><b>#{post.id}</b></a>
</div>
</div>
EOF
        }
        res.write <<EOF
<hr>
<p>Start new thread:</p>
<form class="reply" method="POST" action="/" >
<textarea name="content" cols=79 rows=15></textarea>
trip: <input type="text" name="tripcode">
<input type="submit" value="new thread">
</form>
EOF
      end
    when %r{\A/(\d+)\z}
      if req.post?
        new_post = Post[$1].reply(req["content"], req["tripcode"])
        res["Location"] = "/#{new_post.thread}#p#{new_post.id}"
        res.status = 302
      else                      # GET
        res.write HEADER
        res.write Post.render(Integer($1))
      end
    when %r{\A/moderate/(\d+)\z}
      p = Post[$1]
      p.moderated = !p.moderated
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

.moderated .content, .moderated .actions {
  font-size: 8pt;
  background-color: #fff;
}

.moderated .content {
  border: 1px solid #ddd;
  height: 1em;
  overflow: hidden;
}

.moderated.open .content {
  height: auto;
}

.selected .content {
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
