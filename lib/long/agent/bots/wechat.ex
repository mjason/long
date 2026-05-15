defmodule Long.Agent.Bots.Wechat do
  @moduledoc """
  Top-level WeChat helpers shared by the inbound long-poll worker and
  the outbound scheduled-task push path.

  `push/3` loads the stored credential on demand (used by code that
  doesn't already hold a token, e.g. `Long.Agent.Workers.RunScheduledTask`).

  `push_with_token/4` reuses an already-loaded token plus an optional
  `:context_token` (used by `Wechat.Worker` when replying inside the
  inbound message context).
  """

  require Logger

  alias Long.Agent.Bots.Wechat.{Client, Credential, Markdown, Media}

  @max_outbound_chars 2_000

  @type push_result :: %{
          optional(:text) => String.t() | nil,
          optional(:attachments) => list(),
          optional(:ask) => map() | nil
        }

  @doc """
  Push a collected `result` map to a WeChat user. Loads the credential
  via `Credential.load/0`; returns `{:error, :no_credential}` if none
  is stored.
  """
  @spec push(String.t(), push_result(), keyword()) :: :ok | {:error, term()}
  def push(uid, %{} = result, opts \\ []) when is_binary(uid) do
    case Credential.load() do
      nil ->
        Logger.warning("Wechat push to #{uid}: no credential; run `mix long.wechat.login`.")
        {:error, :no_credential}

      token ->
        push_with_token(token, uid, result, opts)
    end
  end

  @doc """
  Push a result using an already-loaded token. `opts[:context_token]`
  threads through to `Client.send_text` for in-context replies; absent
  for proactive pushes (scheduled triggers).
  """
  @spec push_with_token(map(), String.t(), push_result(), keyword()) :: :ok
  def push_with_token(token, uid, %{} = result, opts \\ []) when is_binary(uid) do
    ctx = Keyword.get(opts, :context_token, "")

    text = Map.get(result, :text, "") || ""
    attachments = Map.get(result, :attachments, []) || []
    ask = Map.get(result, :ask)

    cleaned = Markdown.clean(text)
    full = cleaned <> ask_suffix(ask)

    full
    |> chunk_text()
    |> Enum.each(&send_text_chunk(token, uid, ctx, &1))

    Enum.each(attachments, &send_attachment(token, uid, ctx, &1))

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp ask_suffix(nil), do: ""
  defp ask_suffix(%{"question" => q}) when is_binary(q), do: "\n\n❓ " <> q
  defp ask_suffix(_), do: ""

  defp send_text_chunk(_token, _uid, _ctx, ""), do: :ok

  defp send_text_chunk(token, uid, ctx, text) do
    case Client.send_text(token, uid, text, context_token: ctx) do
      {:ok, _} -> :ok
      err -> Logger.warning("Wechat send_text failed: #{inspect(err)}")
    end
  end

  defp send_attachment(token, uid, ctx, %{path: path, kind: kind}) do
    sender =
      case kind do
        :image -> &Media.send_image/4
        :video -> &Media.send_video/4
        _ -> &Media.send_file/4
      end

    case sender.(token, uid, path, context_token: ctx) do
      {:ok, _} -> :ok
      err -> Logger.warning("Wechat send_media #{path} (#{kind}) failed: #{inspect(err)}")
    end
  end

  # WeChat truncates around 2K chars. Approximate the Python frontend's
  # turn-marker chunking by splitting on blank lines and packing into a
  # char cap.
  defp chunk_text(text) when byte_size(text) <= @max_outbound_chars, do: [text]

  defp chunk_text(text) do
    text
    |> String.split("\n\n", trim: true)
    |> Enum.reduce({[], ""}, fn para, {acc, buf} ->
      candidate = if buf == "", do: para, else: buf <> "\n\n" <> para

      if String.length(candidate) > @max_outbound_chars do
        {[buf | acc], para}
      else
        {acc, candidate}
      end
    end)
    |> then(fn {acc, last} -> Enum.reverse([last | acc]) end)
    |> Enum.reject(&(&1 == ""))
  end
end
