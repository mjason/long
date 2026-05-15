defmodule Long.Agent.Bots.Wechat.Media do
  @moduledoc """
  Encrypted media upload/download for iLink bots. Outbound files are
  AES-128-ECB encrypted with a fresh per-message key, uploaded to the
  CDN endpoint returned by `ilink/bot/getuploadurl`, and referenced
  back in `sendmessage` via an opaque `encrypt_query_param` token.

  Inbound media works the reverse direction: download from CDN with the
  `encrypt_query_param` we received, decrypt with the `aes_key` field
  on the incoming item.

  This module owns the CDN HTTP surface and the encryption envelopes;
  the higher-level send/receive flows live in `Worker`.
  """

  alias Long.Agent.Bots.Wechat.{Client, Crypto}

  @media_image 1
  @media_video 2
  @media_file 3

  @doc "Send a local file to a user. Picks file_item / image_item / video_item by extension."
  def send_file(state, to_user_id, path, opts \\ []) do
    send_media(state, to_user_id, path, :file, opts)
  end

  def send_image(state, to_user_id, path, opts \\ []) do
    send_media(state, to_user_id, path, :image, opts)
  end

  def send_video(state, to_user_id, path, opts \\ []) do
    send_media(state, to_user_id, path, :video, opts)
  end

  defp send_media(state, to_user_id, path, kind, opts) do
    with {:ok, raw} <- File.read(path),
         {:ok, upload_info} <- request_upload_url(state, to_user_id, path, raw, kind),
         {:ok, media} <- upload(upload_info, raw) do
      msg = build_message(to_user_id, path, raw, kind, media, upload_info, opts)

      Client.post(
        "ilink/bot/sendmessage",
        state,
        %{"msg" => msg, "base_info" => %{"channel_version" => Client.channel_version()}}
      )
    end
  end

  # ── Outbound: getuploadurl → CDN POST ────────────────────────────────

  defp request_upload_url(state, to_user_id, path, raw, kind) do
    filekey = uuid_hex()
    aes_key = Crypto.random_key()
    ciphertext_size = Crypto.ciphertext_size(byte_size(raw))

    base_body = %{
      "filekey" => filekey,
      "media_type" => media_type(kind),
      "to_user_id" => to_user_id,
      "rawsize" => byte_size(raw),
      "rawfilemd5" => md5_hex(raw),
      "filesize" => ciphertext_size,
      "no_need_thumb" => kind not in [:image, :video],
      "aeskey" => Base.encode16(aes_key, case: :lower),
      "base_info" => %{"channel_version" => Client.channel_version()}
    }

    case Client.post("ilink/bot/getuploadurl", state, base_body) do
      {:ok, resp} ->
        upload_param = Map.get(resp, "upload_param", "")
        upload_url = Map.get(resp, "upload_full_url", "")

        if upload_param == "" and upload_url == "" do
          {:error, {:getuploadurl_failed, resp}}
        else
          {:ok,
           %{
             filekey: filekey,
             aes_key: aes_key,
             upload_param: upload_param,
             upload_url: upload_url,
             ciphertext_size: ciphertext_size,
             # We don't generate image thumbnails locally — fall back
             # to reusing the original media as its own thumb (this is
             # the Python `thumb_media = media` branch).
             thumb_upload_param: Map.get(resp, "thumb_upload_param", ""),
             thumb_upload_url: Map.get(resp, "thumb_upload_full_url", ""),
             path: path
           }}
        end

      err ->
        err
    end
  end

  defp upload(%{} = info, raw) do
    encrypted = Crypto.encrypt(raw, info.aes_key)

    url =
      cond do
        info.upload_url != "" -> info.upload_url
        true -> "#{Client.cdn_base()}/upload?encrypted_query_param=#{URI.encode_www_form(info.upload_param)}&filekey=#{info.filekey}"
      end

    case Req.post(url,
           headers: [
             {"content-type", "application/octet-stream"},
             {"user-agent", Client.ua()}
           ],
           body: encrypted,
           receive_timeout: 120_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, headers: headers}} ->
        case header(headers, "x-encrypted-param") do
          nil ->
            {:error, "CDN upload response missing x-encrypted-param header"}

          eq ->
            {:ok,
             %{
               "encrypt_query_param" => eq,
               "aes_key" => info.aes_key |> Base.encode16(case: :lower) |> Base.encode64(),
               "encrypt_type" => 1
             }}
        end

      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        msg = header(headers, "x-error-message") || inspect(body)
        {:error, "CDN upload error #{status}: #{msg}"}

      {:error, %{__exception__: true} = e} ->
        {:error, Exception.message(e)}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  defp build_message(to_user_id, path, raw, kind, media, upload_info, opts) do
    item =
      %{"media" => media}
      |> add_kind_specific(kind, path, raw, media, upload_info)

    msg = %{
      "from_user_id" => "",
      "to_user_id" => to_user_id,
      "client_id" => "elixir-" <> uuid_hex() |> binary_part(0, 22),
      "message_type" => Client.msg_bot(),
      "message_state" => Client.state_finish(),
      "item_list" => [%{"type" => item_type(kind), item_key(kind) => item}]
    }

    case opts[:context_token] do
      ctx when is_binary(ctx) and ctx != "" -> Map.put(msg, "context_token", ctx)
      _ -> msg
    end
  end

  defp add_kind_specific(item, :file, path, raw, _media, _info) do
    item
    |> Map.put("file_name", Path.basename(path))
    |> Map.put("len", to_string(byte_size(raw)))
  end

  defp add_kind_specific(item, :video, _path, _raw, _media, info) do
    Map.put(item, "video_size", info.ciphertext_size)
  end

  defp add_kind_specific(item, :image, _path, _raw, media, info) do
    # No local thumbnail pipeline — reuse the encrypted original as the
    # thumb. Server-side this lands as a (slightly oversized) thumb but
    # WeChat clients accept it. If you need real thumbnails later, add
    # a Vix/Mogrify dep and replace this branch.
    item
    |> Map.put("mid_size", info.ciphertext_size)
    |> Map.put("thumb_media", media)
    |> Map.put("thumb_size", info.ciphertext_size)
    |> Map.put("thumb_width", 240)
    |> Map.put("thumb_height", 240)
  end

  # ── Inbound: parse item → download + decrypt ─────────────────────────

  @media_keys [
    {"image_item", ".jpg"},
    {"video_item", ".mp4"},
    {"file_item", ""},
    {"voice_item", ".silk"}
  ]

  @doc """
  Walk an incoming message's `item_list`, decrypt each media item and
  write it under `dir`. Returns the list of local paths.
  """
  def download_all(%{"item_list" => items}, dir) when is_list(items) and is_binary(dir) do
    File.mkdir_p!(dir)

    items
    |> Enum.flat_map(&download_one(&1, dir))
  end

  def download_all(_, _), do: []

  defp download_one(item, dir) do
    Enum.find_value(@media_keys, [], fn {key, ext} ->
      case Map.get(item, key) do
        nil ->
          false

        sub ->
          case extract_media_ref(sub) do
            {:ok, eq, aes_key} ->
              filename = Map.get(sub, "file_name") || (uuid_hex() |> binary_part(0, 8)) <> default_ext(ext)
              path = Path.join(dir, filename)

              case fetch_and_decrypt(eq, aes_key, path) do
                :ok -> [path]
                _ -> []
              end

            _ ->
              false
          end
      end
    end)
  end

  defp extract_media_ref(sub) do
    media = Map.get(sub, "media") || %{}
    eq = Map.get(media, "encrypt_query_param", "")
    ak_b64 = Map.get(media, "aes_key", "") || Map.get(sub, "aeskey", "")

    cond do
      eq == "" or ak_b64 == "" ->
        :missing

      # Python: `bytes.fromhex(base64.b64decode(ak).decode())` when sub
      # has `media.aes_key` (b64-of-hex); else `bytes.fromhex(ak)` for
      # the legacy top-level `aeskey` (just hex).
      Map.has_key?(media, "aes_key") ->
        with {:ok, hex} <- Base.decode64(ak_b64),
             {:ok, key} <- Base.decode16(hex, case: :mixed) do
          {:ok, eq, key}
        else
          _ -> :bad_key
        end

      true ->
        case Base.decode16(ak_b64, case: :mixed) do
          {:ok, key} -> {:ok, eq, key}
          _ -> :bad_key
        end
    end
  end

  defp fetch_and_decrypt(eq, aes_key, path) do
    url = "#{Client.cdn_base()}/download?encrypted_query_param=#{URI.encode_www_form(eq)}"

    case Req.get(url,
           headers: [{"user-agent", Client.ua()}],
           receive_timeout: 60_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        File.write!(path, Crypto.decrypt(body, aes_key))
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:cdn_status, status}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp default_ext(""), do: ".bin"
  defp default_ext(ext), do: ext

  # ── Constants / helpers ──────────────────────────────────────────────

  defp media_type(:image), do: @media_image
  defp media_type(:video), do: @media_video
  defp media_type(:file), do: @media_file

  defp item_type(:image), do: Client.item_image()
  defp item_type(:video), do: Client.item_video()
  defp item_type(:file), do: Client.item_file()

  defp item_key(:image), do: "image_item"
  defp item_key(:video), do: "video_item"
  defp item_key(:file), do: "file_item"

  defp md5_hex(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
  defp uuid_hex, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name do
          if is_list(v), do: List.first(v), else: v
        end

      _ ->
        nil
    end)
  end
end
