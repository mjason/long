defmodule Long.Jido.SendMediaTest do
  use ExUnit.Case, async: false

  alias Long.Jido.Tools.SendMedia

  setup do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Long.PubSub, "agent_session:#{session_id}")

    tmp = Path.join(System.tmp_dir!(), "long_send_media_#{System.unique_integer([:positive])}.png")
    File.write!(tmp, "fakepng")
    on_exit(fn -> File.rm(tmp) end)

    {:ok, session_id: session_id, tmp: tmp}
  end

  test "broadcasts {:bot_send_media, ...} on the session topic", %{session_id: sid, tmp: tmp} do
    assert {:ok, %{status: "queued", kind: "image"}} =
             Jido.Exec.run(SendMedia, %{path: tmp, kind: "image"}, %{session_id: sid})

    assert_receive {:bot_send_media, %{path: ^tmp, kind: :image}}, 500
  end

  test "rejects when file does not exist", %{session_id: sid} do
    assert {:ok, %{status: "error", msg: msg}} =
             Jido.Exec.run(SendMedia, %{path: "/no/such/file"}, %{session_id: sid})

    assert msg =~ "not found"
  end

  test "rejects when session_id missing from ctx", %{tmp: tmp} do
    assert {:ok, %{status: "error", msg: msg}} =
             Jido.Exec.run(SendMedia, %{path: tmp}, %{})

    assert msg =~ "session"
  end

  test "rejects invalid kind", %{session_id: sid, tmp: tmp} do
    assert {:ok, %{status: "error", msg: msg}} =
             Jido.Exec.run(SendMedia, %{path: tmp, kind: "audio"}, %{session_id: sid})

    assert msg =~ "invalid kind"
  end

  test "defaults to file kind when omitted", %{session_id: sid, tmp: tmp} do
    assert {:ok, %{kind: "file"}} =
             Jido.Exec.run(SendMedia, %{path: tmp}, %{session_id: sid})
  end
end
