defmodule Long.Agent.Bots.Telegram.Credential do
  @moduledoc """
  Convenience accessors over `Long.Agent.TelegramCredential`. The Ash
  resource is the source of truth; this module hides the singleton row
  name and the legacy `TELEGRAM_BOT_TOKEN` env-var fallback so the
  worker has one call to make.
  """

  alias Long.Agent

  @default_name "default"

  @doc """
  Return `{token, row}` where `row` may be nil (env-only path) or the
  active `TelegramCredential`, or `nil` if no token is configured.

  Precedence: enabled DB row → env var → none.
  """
  @spec load() :: {String.t(), Long.Agent.TelegramCredential.t() | nil} | nil
  def load(name \\ @default_name) do
    case Agent.get_telegram_credential(name) do
      {:ok, %{enabled: true, bot_token: tok} = row} when is_binary(tok) and tok != "" ->
        {tok, row}

      _ ->
        case System.get_env("TELEGRAM_BOT_TOKEN") do
          tok when is_binary(tok) and tok != "" -> {tok, nil}
          _ -> nil
        end
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
