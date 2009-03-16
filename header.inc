<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />

    <style type="text/css">
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
  min-width: 25em;
  max-width: 60em;
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
  top: -1.55em;
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
  width: 12px;
  height: 12px;
  overflow: hidden;
  display: inline-block;
  color: none;
  font-size: 100px;
}

.actions .date {
  color: #555;
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

    <script type="text/javascript">
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
  </head>
  <body>
    <h1>$TITLE</h1>
