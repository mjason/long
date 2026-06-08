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

  def push(%{platform: :wechat} = user, result, opts) do
    case nonempty(user.external_id) do
      nil -> {:error, :no_uid}
      uid -> Wechat.push(uid, result, Keyword.put(opts, :credential_name, wechat_account_for(user)))
    end
  end

  def push(%{platform: :telegram} = user, result, opts) do
    case nonempty(user.chat_id) || nonempty(user.external_id) do
      nil -> {:error, :no_chat_id}
      cid -> Telegram.push(cid, result, Keyword.put_new(opts, :server, telegram_worker_for(user)))
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

  # A WeChat reply goes out on the *exact* account the chat arrived on
  # (`credential_name`), so it's always reachable; then the recipient
  # member's assigned account; then the single "default" account.
  defp wechat_account_for(%{credential_name: c}) when is_binary(c) and c != "", do: c

  defp wechat_account_for(%{member_id: mid}) when is_binary(mid),
    do: Long.Agent.Bots.Wechat.Credential.for_member(mid) || "default"

  defp wechat_account_for(_user), do: "default"

  # The Telegram worker (pid) for the bot the chat arrived on
  # (`credential_name`) — a Telegram user can only be messaged by the
  # exact bot they talk to. Falls back to the recipient member's assigned
  # bot, then the first enabled bot. `nil` when that bot has no worker
  # running (a clear, actionable failure rather than a wrong-bot send).
  defp telegram_worker_for(%{credential_name: c}) when is_binary(c) and c != "",
    do: worker_pid(c)

  defp telegram_worker_for(%{member_id: mid}) when is_binary(mid),
    do: tg_worker(Long.Agent.Bots.Telegram.Credential.for_member(mid))

  defp telegram_worker_for(_user), do: tg_worker(nil)

  defp tg_worker(name) do
    # member's bot, else the first enabled bot — then resolve to its pid.
    worker_pid(name || List.first(Long.Agent.Bots.Telegram.Credential.enabled_names()))
  end

  defp worker_pid(nil), do: nil
  defp worker_pid(name), do: Long.Agent.Bots.Telegram.Manager.worker_pid(name)

  defp nonempty(nil), do: nil
  defp nonempty(""), do: nil
  defp nonempty(s) when is_binary(s), do: s
end
