defmodule LongWeb.AgentLive.MediaControllerTest do
  use LongWeb.ConnCase, async: false

  alias Long.Agent

  setup do
    {:ok, sess} = Agent.start_session(%{title: "media"})
    dir = Agent.web_inbox_dir(sess.id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "pic.png"), "PNGDATA")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, sess: sess}
  end

  test "serves an uploaded file from the session inbox", %{conn: conn, sess: sess} do
    conn = get(conn, ~p"/chat/media/#{sess.id}/pic.png")
    assert response(conn, 200) == "PNGDATA"
  end

  test "404s for a file that isn't there", %{conn: conn, sess: sess} do
    conn = get(conn, ~p"/chat/media/#{sess.id}/missing.png")
    assert conn.status == 404
  end

  test "rejects a non-uuid session id", %{conn: conn} do
    conn = get(conn, "/chat/media/not-a-uuid/pic.png")
    assert conn.status == 404
  end

  test "rejects a traversal attempt in the filename", %{conn: conn, sess: sess} do
    conn = get(conn, "/chat/media/#{sess.id}/%2E%2E")
    assert conn.status == 404
  end
end
