defmodule Long.Agent.Bots.Telegram.Credential do
  @moduledoc """
  Convenience accessors over `Long.Agent.TelegramCredential`. The Ash
  resource is the source of truth; this module hides credential
  selection + the legacy `TELEGRAM_BOT_TOKEN` env-var fallback so the
  worker has one call to make.

  The worker today only runs one bot at a time; we pick the first
  enabled row (sorted by name for stable selection). The schema
  supports multiple bots for a future "switch between accounts" UX,
  but until that lands the names "default" / "电报" / anything else
  the operator typed all work — what matters is `enabled: true`.
  """

  alias Long.Agent

  @doc """
  Return `{token, row}` where `row` may be nil (env-only path) or the
  active `TelegramCredential`, or `nil` if no token is configured.

  Precedence: first enabled DB row → env var → none.
  """
  @spec load() :: {String.t(), Long.Agent.TelegramCredential.t() | nil} | nil
  def load do
    case active_row() do
      %{bot_token: tok} = row when is_binary(tok) and tok != "" -> {tok, row}
      _ -> env_fallback()
    end
  end

  defp active_row do
    case Agent.list_telegram_credentials() do
      {:ok, rows} ->
        rows
        |> Enum.filter(& &1.enabled)
        |> Enum.sort_by(& &1.name)
        |> List.first()

      _ ->
        nil
    end
  end

  defp env_fallback do
    case System.get_env("TELEGRAM_BOT_TOKEN") do
      tok when is_binary(tok) and tok != "" -> {tok, nil}
      _ -> nil
    end
  end

  @doc "Cache the bot's `@username` on the active row (no-op if env-only)."
  @spec save_username(Long.Agent.TelegramCredential.t() | nil, String.t()) :: :ok
  def save_username(nil, _username), do: :ok

  def save_username(%_{username: same}, username) when same == username, do: :ok

  def save_username(row, username) do
    _ = Agent.update_telegram_credential_username(row, %{username: username})
    :ok
  end
end
