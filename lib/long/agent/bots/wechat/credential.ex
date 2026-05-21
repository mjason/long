defmodule Long.Agent.Bots.Wechat.Credential do
  @moduledoc """
  Convenience accessors over `Long.Agent.WechatCredential`. The Ash
  resource is the source of truth; this module just hides a couple of
  shape conversions so callers don't have to think about the singleton
  row name or build maps with the right keys.

  Also owns the `:wechat_connected` lifecycle PubSub (mirrors
  `Long.Agent.SessionPubSub`): the QR-login view broadcasts on confirm,
  the Channels admin page subscribes to refresh its status card.
  """

  alias Long.Agent

  @default_name "default"
  @connect_topic "wechat_login"

  @doc "PubSub topic broadcast to on credential connect."
  def connect_topic, do: @connect_topic

  @doc "Subscribe the calling process to credential-connect events."
  def subscribe, do: Phoenix.PubSub.subscribe(Long.PubSub, @connect_topic)

  @doc "Announce a freshly-confirmed credential to any subscribers."
  def broadcast_connected, do: Phoenix.PubSub.broadcast(Long.PubSub, @connect_topic, :wechat_connected)

  @doc """
  Return the stored credential as a state map suitable for
  `Long.Agent.Bots.Wechat.Client`, or `nil` if no row has been
  persisted yet.
  """
  @spec load() :: %{bot_token: String.t(), ilink_bot_id: String.t(), updates_buf: String.t()} | nil
  def load(name \\ @default_name) do
    case Agent.get_wechat_credential(name) do
      {:ok, row} ->
        %{
          bot_token: row.bot_token || "",
          ilink_bot_id: row.ilink_bot_id || "",
          updates_buf: row.updates_buf || ""
        }

      _ ->
        nil
    end
  end

  @doc """
  Insert or update the credential row. Accepts a partial map; existing
  fields are preserved.
  """
  @spec save(map()) :: {:ok, term()} | {:error, term()}
  def save(attrs, name \\ @default_name) when is_map(attrs) do
    current =
      case Agent.get_wechat_credential(name) do
        {:ok, row} -> Map.from_struct(row)
        _ -> %{}
      end

    Agent.upsert_wechat_credential(%{
      name: name,
      bot_token: attrs[:bot_token] || current[:bot_token] || "",
      ilink_bot_id: attrs[:ilink_bot_id] || current[:ilink_bot_id] || "",
      updates_buf: Map.get(attrs, :updates_buf, current[:updates_buf] || "")
    })
  end

  @doc """
  Cheap cursor update. If no row exists yet, this is a no-op — the
  cursor is meaningless without a bot_token.
  """
  @spec save_buf(String.t()) :: :ok
  def save_buf(buf, name \\ @default_name) when is_binary(buf) do
    case Agent.get_wechat_credential(name) do
      {:ok, row} -> Agent.update_wechat_credential_buf(row, %{updates_buf: buf})
      _ -> :ok
    end

    :ok
  end

  @doc "True when there's a stored row with a non-empty bot_token."
  def has_token?(name \\ @default_name) do
    case load(name) do
      %{bot_token: t} when is_binary(t) and t != "" -> true
      _ -> false
    end
  end

  @doc """
  Delete the stored credential and reload the worker (so it pauses).
  Returns `:ok` whether or not a row existed.
  """
  @spec delete(String.t()) :: :ok
  def delete(name \\ @default_name) do
    with {:ok, row} <- Agent.get_wechat_credential(name) do
      _ = Agent.destroy_wechat_credential(row)
      Long.Agent.Bots.Wechat.Worker.reload()
    end

    :ok
  end
end
