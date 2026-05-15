defmodule Long.Jido.HistoryCompressTest do
  @moduledoc """
  Exercises `History.load_or_compress/3` with a stubbed summarizer so
  the test stays offline. Verifies:

  - Under budget: returns the existing summary unchanged + the full
    raw tail.
  - Over budget: invokes the summarizer, persists the new summary +
    cutoff timestamp to the session, returns only the tail under the
    low-water mark.
  - Existing summary is dropped from the raw tail (via
    `summary_through_inserted_at`).
  """

  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Jido.History

  setup do
    {:ok, session} = Agent.start_session(%{title: "compress-test"})
    {:ok, session: session}
  end

  describe "load_or_compress/3" do
    test "no compression needed when under high-water mark", %{session: session} do
      {:ok, _} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "hi", turn: 1})

      summarizer = fn _, _, _ -> flunk("summarizer should not be called") end

      assert %{system_addendum: nil, messages: [%ReqLLM.Message{}]} =
               History.load_or_compress(session.id, "聆思",
                 high_water: 1_000,
                 low_water: 500,
                 summarizer: summarizer
               )
    end

    test "uses existing summary; skips messages already covered", %{session: session} do
      {:ok, m1} =
        Agent.append_message(%{
          session_id: session.id,
          role: :user,
          content: "old",
          turn: 1
        })

      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :user,
          content: "new",
          turn: 2
        })

      {:ok, _} =
        Agent.update_session(session, %{
          summary: "prior summary",
          summary_through_inserted_at: m1.inserted_at
        })

      summarizer = fn _, _, _ -> flunk("summarizer should not be called") end

      assert %{system_addendum: "prior summary", messages: [msg]} =
               History.load_or_compress(session.id, "聆思",
                 high_water: 1_000,
                 low_water: 500,
                 summarizer: summarizer
               )

      assert msg.role == :user
    end

    test "calls summarizer and persists new summary when over budget",
         %{session: session} do
      for i <- 1..6 do
        {:ok, _} =
          Agent.append_message(%{
            session_id: session.id,
            role: :user,
            content: String.duplicate("a", 100),
            turn: i
          })
      end

      summarizer = fn _prior, rows, _alias ->
        send(self(), {:summarizer_called, length(rows)})
        {:ok, "fresh summary"}
      end

      result =
        History.load_or_compress(session.id, "聆思",
          high_water: 300,
          low_water: 150,
          summarizer: summarizer
        )

      assert %{system_addendum: "fresh summary"} = result
      assert_received {:summarizer_called, _}

      {:ok, reloaded} = Agent.get_session(session.id)
      assert reloaded.summary == "fresh summary"
      assert reloaded.summary_through_inserted_at != nil
      assert length(result.messages) > 0
    end

    test "falls back to hard truncation when summarizer errors",
         %{session: session} do
      for i <- 1..6 do
        {:ok, _} =
          Agent.append_message(%{
            session_id: session.id,
            role: :user,
            content: String.duplicate("b", 100),
            turn: i
          })
      end

      summarizer = fn _, _, _ -> {:error, :stub_failure} end

      assert %{messages: msgs} =
               History.load_or_compress(session.id, "聆思",
                 high_water: 300,
                 low_water: 150,
                 summarizer: summarizer
               )

      assert msgs != []

      {:ok, reloaded} = Agent.get_session(session.id)
      assert reloaded.summary == nil
    end

    test "falls back to hard truncation when summarizer raises", %{session: session} do
      for i <- 1..6 do
        {:ok, _} =
          Agent.append_message(%{
            session_id: session.id,
            role: :user,
            content: String.duplicate("r", 100),
            turn: i
          })
      end

      raising = fn _, _, _ -> raise "boom" end

      assert %{messages: msgs} =
               History.load_or_compress(session.id, "聆思",
                 high_water: 300,
                 low_water: 150,
                 summarizer: raising
               )

      assert msgs != []

      {:ok, reloaded} = Agent.get_session(session.id)
      assert reloaded.summary == nil
    end

    test "without llm_alias the loader returns empty rather than crashing",
         %{session: session} do
      for i <- 1..6 do
        {:ok, _} =
          Agent.append_message(%{
            session_id: session.id,
            role: :user,
            content: String.duplicate("c", 100),
            turn: i
          })
      end

      assert %{system_addendum: nil, messages: []} =
               History.load_or_compress(session.id, nil,
                 high_water: 300,
                 low_water: 150
               )
    end
  end
end
