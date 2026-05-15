defmodule Long.Agent.Bots.Outbound do
  @moduledoc """
  Platform-agnostic outbound dispatcher. Given a `Long.Agent.BotUser`
  and a `result` map (the shape returned by `Long.Agent.Bots.run_on_session/3`),
  route the reply to the right platform helper.

  Used for proactive pushes — currently driven by
  `Long.Agent.Workers.RunScheduledTask` when a scheduled task fires for
  a session that originated from a bot platform. The inbound path
  (long-poll / webhook) handles its own reply because it already has the
  inbound context (token, context_token, message_id).
  """

  alias Long.Agent.Bots.{Feishu, Telegram, Wechat}

  @type result_map :: %{
          optional(:text) => String.t() | nil,
          optional(:tool_calls) => list(),
          optional(:attachments) => list(),
          optional(:ask) => map() | nil,
          optional(:error) => term() | nil
        }

  @spec push(map(), result_map(), keyword()) :: :ok | {:error, term()}
  def push(bot_user, result, opts \\ [])

  def push(%{platform: :wechat} = user, result, _opts) do
    case nonempty(user.external_id) do
      nil -> {:error, :no_uid}
      uid -> Wechat.push(uid, result)
    end
  end

  def push(%{platform: :telegram} = user, result, opts) do
    case nonempty(user.chat_id) || nonempty(user.external_id) do
      nil -> {:error, :no_chat_id}
      cid -> Telegram.push(cid, result, opts)
    end
  end

  def push(%{platform: :feishu} = user, result, opts) do
    case nonempty(user.external_id) do
      nil -> {:error, :no_open_id}
      open_id -> Feishu.push(open_id, result, opts)
    end
  end

  def push(%{platform: other}, _result, _opts) do
    {:error, {:unsupported_platform, other}}
  end

  defp nonempty(nil), do: nil
  defp nonempty(""), do: nil
  defp nonempty(s) when is_binary(s), do: s
end
