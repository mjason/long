defmodule LongWeb.ManageLive.MemoriesTest do
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Long.Agent

  test "session memory is editable with the full value (not just deletable)", %{conn: conn} do
    {:ok, sess} = Agent.start_session(%{title: "mem"})
    long_value = String.duplicate("详细的中文记忆内容 ", 30)

    {:ok, mem} =
      Agent.put_session_memory(%{
        session_id: sess.id,
        key: "writing_pref",
        value: long_value,
        kind: :preference,
        importance: 3
      })

    {:ok, view, html} = live(conn, ~p"/manage/memories")

    # Listed, but the table truncates the value (full text not present there).
    assert html =~ "writing_pref"
    refute html =~ long_value

    # Edit opens a modal showing the FULL value.
    opened =
      view
      |> element("button[phx-click='edit_session_memory'][phx-value-id='#{mem.id}']")
      |> render_click()

    assert opened =~ "save_session_memory"
    assert opened =~ String.trim_trailing(long_value)

    # Save an edited value (in Chinese) + bumped importance — persists in place.
    view
    |> form("form[phx-submit='save_session_memory']",
      memory: %{
        session_id: sess.id,
        key: "writing_pref",
        value: "改写后的内容",
        kind: "preference",
        importance: "5"
      }
    )
    |> render_submit()

    {:ok, rows} = Agent.list_session_memory_for(sess.id)
    row = Enum.find(rows, &(&1.key == "writing_pref"))
    assert row.value == "改写后的内容"
    assert row.importance == 5
  end
end
