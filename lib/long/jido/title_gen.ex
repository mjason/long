defmodule Long.Jido.TitleGen do
  @moduledoc """
  Async one-shot title generator for chat sessions. Fires after a
  session's first user → assistant exchange completes; if the title is
  still the placeholder `"untitled"`, asks the same LLM the session is
  using to produce a short Chinese-friendly summary phrase and writes
  it back via `Agent.update_session/2`. Broadcasts
  `{:session_updated, session}` on the session's PubSub topic so any
  open LiveView refreshes its header + sidebar.
  """

  require Logger

  alias Long.Agent
  alias Long.Jido.LLMCall
  alias Long.Util.Text

  @task_sup Long.Agent.TaskSup
  @placeholder "untitled"
  @topic_prefix "agent_session:"

  @doc """
  Maybe spawn a background task to generate a title. Returns
  immediately. No-op if `alias_name` is nil — without an LLM there's
  nothing to ask.
  """
  @spec maybe_generate_async(String.t(), String.t() | nil) :: :ok
  def maybe_generate_async(_session_id, nil), do: :ok

  def maybe_generate_async(session_id, alias_name)
      when is_binary(session_id) and is_binary(alias_name) do
    Task.Supervisor.start_child(@task_sup, fn -> generate(session_id, alias_name) end)
    :ok
  end

  defp generate(session_id, alias_name) do
    with {:ok, session} <- Agent.get_session(session_id),
         true <- session.title == @placeholder,
         snippets when snippets != [] <- load_snippets(session_id),
         {:ok, title} <- ask_llm(snippets, alias_name),
         cleaned when cleaned != "" <- sanitize(title),
         {:ok, fresh} <- Agent.update_session(session, %{title: cleaned}) do
      Phoenix.PubSub.broadcast(
        Long.PubSub,
        @topic_prefix <> session_id,
        {:session_updated, fresh}
      )
    else
      reason ->
        Logger.debug("TitleGen skipped for #{session_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp load_snippets(session_id) do
    # `:by_session` already filters + sorts `inserted_at: :asc` in SQL
    # (see `Long.Agent.Message`), so no in-memory filter/sort needed.
    case Agent.list_messages_for_session(session_id) do
      {:ok, rows} ->
        rows
        |> Enum.take(4)
        |> Enum.flat_map(fn m ->
          case m.role do
            r when r in [:user, :assistant] ->
              text = String.trim(m.content || "")
              if text == "", do: [], else: [{r, text}]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp ask_llm(snippets, alias_name) do
    body =
      snippets
      |> Enum.map_join("\n", fn {role, content} ->
        prefix = if role == :user, do: "用户", else: "助手"
        "#{prefix}: #{Text.preview(content, 200)}"
      end)

    prompt = """
    根据以下对话片段,用 8 个汉字以内的简短短语总结主题,作为这段对话的标题。
    只回标题文本,不要解释,不要标点,不要引号。

    #{body}
    """

    messages = [ReqLLM.Context.user(prompt)]

    case LLMCall.call(messages, [], llm_alias: alias_name, max_tokens: 64, temperature: 0.2) do
      {:ok, %{text: text}} when is_binary(text) -> {:ok, text}
      other -> {:error, other}
    end
  end

  defp sanitize(text) do
    text
    |> String.trim()
    |> String.replace(~r/^[「『"'《]+|[」』"'》。\.!?]+$/u, "")
    |> Text.preview(24)
    |> String.trim()
  end
end
