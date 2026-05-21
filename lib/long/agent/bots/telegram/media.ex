defmodule Long.Agent.Bots.Telegram.Media do
  @moduledoc """
  Telegram-specific media helpers: pull inbound photos / documents /
  videos out of a message and download them to a local dir, and push
  outbound attachments back via `sendPhoto` / `sendVideo` /
  `sendDocument`.

  Telegram's API uses multipart/form-data uploads keyed by a fixed
  field name per endpoint (`photo`, `video`, `document`), so the bulk
  of the outbound code is shape conversion + a single Req call. Inbound
  is a two-step dance: `getFile(file_id)` returns a path on Telegram's
  CDN, then we GET `<api>/file/bot<TOKEN>/<path>` to fetch the bytes.

  Sticker / location / contact messages are ignored — the agent has
  no useful way to react to them today.
  """

  require Logger

  alias Long.Agent.Bots.Telegram.Format

  # ── Inbound ──────────────────────────────────────────────────────────

  @doc """
  Return a list of `{kind, file_id, suggested_name}` for any media
  payloads in `message`. `kind` matches the `Long.Jido.Tools.SendMedia`
  vocabulary (`:image | :video | :file`) so downstream code only has
  to deal with three values regardless of Telegram's many message
  shapes.

  Photos arrive as a list of resolutions; we take the largest so the
  agent's multimodal model gets the best chance at reading it.
  """
  @spec inbound_descriptors(map()) :: [{atom(), String.t(), String.t() | nil}]
  def inbound_descriptors(%{} = msg) do
    [
      photo_descriptor(msg),
      document_descriptor(msg),
      video_descriptor(msg),
      audio_descriptor(msg),
      voice_descriptor(msg)
    ]
    |> Enum.reject(&is_nil/1)
  end

  def inbound_descriptors(_), do: []

  defp photo_descriptor(%{"photo" => [_ | _] = photos}) do
    largest =
      Enum.max_by(photos, fn p -> Map.get(p, "width", 0) * Map.get(p, "height", 0) end)

    {:image, largest["file_id"], nil}
  end

  defp photo_descriptor(_), do: nil

  defp document_descriptor(%{"document" => %{"file_id" => id} = doc}),
    do: {:file, id, doc["file_name"]}

  defp document_descriptor(_), do: nil

  defp video_descriptor(%{"video" => %{"file_id" => id} = v}),
    do: {:video, id, v["file_name"]}

  defp video_descriptor(_), do: nil

  # Music files (audio) and voice notes (voice) — keep them as :file
  # so they land on disk for the agent to inspect; we don't have a
  # multimodal "listen to this" path yet.
  defp audio_descriptor(%{"audio" => %{"file_id" => id} = a}),
    do: {:file, id, a["file_name"]}

  defp audio_descriptor(_), do: nil

  defp voice_descriptor(%{"voice" => %{"file_id" => id}}), do: {:file, id, nil}
  defp voice_descriptor(_), do: nil

  @doc """
  Download every descriptor returned by `inbound_descriptors/1` to
  `dir`. Returns the list of absolute paths written; failures are
  logged and skipped so a single broken upload doesn't abort the whole
  dispatch. Downloads run concurrently — Telegram albums arrive as
  many descriptors and serializing the `getFile` round-trips was the
  biggest source of latency.
  """
  @spec download_all([{atom(), String.t(), String.t() | nil}], String.t(), String.t(), function()) ::
          [String.t()]
  def download_all([], _dir, _token, _http), do: []

  def download_all(descriptors, dir, token, http) do
    File.mkdir_p!(dir)

    descriptors
    |> Task.async_stream(
      fn {_kind, file_id, suggested} -> {file_id, download_one(file_id, suggested, dir, token, http)} end,
      max_concurrency: 4,
      timeout: 60_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, {_id, {:ok, path}}} ->
        [path]

      {:ok, {id, {:error, reason}}} ->
        Logger.warning("Telegram: download #{id} failed: #{inspect(reason)}")
        []

      {:exit, reason} ->
        Logger.warning("Telegram: download task crashed: #{inspect(reason)}")
        []
    end)
  end

  defp download_one(file_id, suggested_name, dir, token, http) do
    with {:ok, file_path} <- get_file_path(file_id, token, http),
         {:ok, bytes} <- fetch_file_bytes(file_path, token, http),
         {:ok, target} <- write_unique(dir, suggested_name || Path.basename(file_path), bytes) do
      {:ok, target}
    end
  end

  # Race-free atomic create: open with `:exclusive` and on collision
  # rebuild the name with a unique suffix and retry. Two concurrent
  # downloads with the same file_name can't trample each other.
  defp write_unique(dir, name, bytes) do
    base = Path.join(dir, sanitize_name(name))
    do_write_unique(base, bytes, 0)
  end

  defp do_write_unique(_path, _bytes, attempt) when attempt > 5,
    do: {:error, :too_many_collisions}

  defp do_write_unique(path, bytes, attempt) do
    target =
      if attempt == 0 do
        path
      else
        ext = Path.extname(path)
        stem = Path.basename(path, ext)
        Path.join(Path.dirname(path), "#{stem}-#{System.unique_integer([:positive])}#{ext}")
      end

    case File.open(target, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        IO.binwrite(io, bytes)
        File.close(io)
        {:ok, target}

      {:error, :eexist} ->
        do_write_unique(path, bytes, attempt + 1)

      {:error, _} = err ->
        err
    end
  end

  defp get_file_path(file_id, token, http) do
    case http.(
           method: :get,
           url: "https://api.telegram.org/bot#{token}/getFile",
           params: %{file_id: file_id}
         ) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => %{"file_path" => path}}}}
      when is_binary(path) ->
        {:ok, path}

      {:ok, %Req.Response{} = r} ->
        {:error, {:bad_payload, r.status, r.body}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp fetch_file_bytes(file_path, token, http) do
    case http.(
           method: :get,
           url: "https://api.telegram.org/file/bot#{token}/#{file_path}",
           decode_body: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{} = r} ->
        {:error, {:bad_payload, r.status, byte_size(r.body || "")}}

      {:error, e} ->
        {:error, e}
    end
  end

  # Telegram filenames are user-supplied; strip directory traversal
  # and the few special chars that confuse downstream shells.
  defp sanitize_name(name) when is_binary(name) and name != "" do
    name
    |> Path.basename()
    |> String.replace(~r/[^\w.\-]/u, "_")
  end

  defp sanitize_name(_), do: "telegram-#{System.unique_integer([:positive])}.bin"

  # ── Outbound ─────────────────────────────────────────────────────────

  @doc """
  Send a single `Long.Jido.Tools.SendMedia` payload back to a chat via
  the appropriate Telegram endpoint. Returns the Req response in the
  usual `{:ok, %Req.Response{}}` / `{:error, term()}` shape.
  """
  @spec send_attachment(map(), String.t() | integer(), map()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def send_attachment(state, chat_id, %{path: path, kind: kind} = payload) do
    {endpoint, field} = endpoint_for(kind)
    caption = payload[:caption]

    case File.read(path) do
      {:ok, bytes} ->
        upload(state, chat_id, endpoint, field, path, bytes, caption)

      {:error, reason} ->
        Logger.warning("Telegram: skipping #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def endpoint_for(:image), do: {"sendPhoto", :photo}
  def endpoint_for(:video), do: {"sendVideo", :video}
  def endpoint_for(_), do: {"sendDocument", :document}

  defp upload(state, chat_id, endpoint, field, path, bytes, caption) do
    form = build_form(chat_id, field, path, bytes, caption)

    state.http.(
      method: :post,
      url: "https://api.telegram.org/bot#{state.token}/#{endpoint}",
      form_multipart: form
    )
  end

  # Req's `form_multipart` expects each part as `{name, value}` or
  # `{name, {value, opts}}` — the 3-tuple `{name, value, opts}` shape
  # fails with `no function clause matching in
  # Req.Utils.encode_form_part/2`.
  defp build_form(chat_id, field, path, bytes, caption) do
    base = [
      {"chat_id", to_string(chat_id)},
      {field, {bytes, filename: Path.basename(path), content_type: content_type(path)}}
    ]

    case caption do
      c when is_binary(c) and c != "" ->
        # Captions render alongside the media; reuse the same HTML
        # parser the text path uses so `**bold**` etc. behave the same.
        base ++ [{"caption", Format.to_html(c)}, {"parse_mode", "HTML"}]

      _ ->
        base
    end
  end

  # Telegram doesn't strictly require Content-Type (it sniffs), but a
  # correct value makes the in-chat preview pick the right rendering.
  # `MIME.from_path/1` is the standard 1k-entry table that ships with
  # the `mime` dep (already present transitively).
  defp content_type(path), do: MIME.from_path(path)
end
