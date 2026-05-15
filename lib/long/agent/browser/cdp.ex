defmodule Long.Agent.Browser.CDP do
  @moduledoc """
  Minimal Chrome DevTools Protocol client. Replaces `TMWebDriver.py`'s
  WebSocket bridge with a connectionless `Mint.WebSocket` round-trip:
  connect → upgrade → send one command → receive one response → close.

  Suitable for one-shot tool invocations (`web_scan`, `web_execute_js`);
  for long-running interaction we'd add a GenServer that keeps the socket
  open and multiplexes by command id.

  ## Setup

  Run Chrome with the remote debugging port open:

      google-chrome --remote-debugging-port=9222

  Then `Long.Agent.Browser.CDP.targets/0` will list every open page.

  ## API

  - `targets/1` — list page targets via `http://host:port/json`
  - `evaluate/3` — `Runtime.evaluate` JS on a target, return value
  - `outer_html/2` — fetch the live `outerHTML` of `<html>` on a target
  - `navigate/3` — navigate a target to a URL
  """

  @default_recv_timeout 15_000

  @doc """
  Resolve the CDP HTTP endpoint. Precedence: explicit `:endpoint` opt
  on each call → app config `:long, Long.Agent.Browser, :endpoint` →
  `CHROME_DEBUG_URL` env var → `http://127.0.0.1:9222`.
  """
  def default_endpoint do
    cfg = Application.get_env(:long, Long.Agent.Browser, [])

    Keyword.get(cfg, :endpoint) ||
      System.get_env("CHROME_DEBUG_URL") ||
      "http://127.0.0.1:9222"
  end

  defmodule Target do
    @moduledoc false
    defstruct [:id, :title, :url, :type, :ws_url]
  end

  @doc """
  True if `reason` smells like "Chrome isn't reachable" (connection
  refused, transport timeout, …). Used by `web_scan` / `web_execute_js` to
  upgrade an opaque transport error to an actionable hint.
  """
  def unreachable?(%{reason: r}) when r in [:econnrefused, :timeout, :enetunreach, :ehostunreach],
    do: true

  def unreachable?(%{__struct__: Mint.TransportError}), do: true
  def unreachable?(_), do: false

  @doc """
  Hint string for the model when the Obscura binary isn't installed
  (yet). Tools `web_scan` / `web_execute_js` shell out to `obscura fetch`;
  if the binary isn't on disk, they surface this hint via their error
  payload.
  """
  def unreachable_hint do
    "Obscura headless browser isn't installed yet. The supervisor " <>
      "may still be downloading it in the background (~50 MB, one-time) — " <>
      "retry in a few seconds. For machine endpoints (JSON/RSS/sitemaps) " <>
      "use `http_fetch` instead; for search use `web_search`."
  end

  @doc """
  Build a standard error payload for the agent. Tools can pipe their CDP
  errors through this for uniform shape + hinting.
  """
  def error_payload(reason) do
    base = %{"status" => "error", "msg" => inspect(reason)}
    if unreachable?(reason), do: Map.put(base, "hint", unreachable_hint()), else: base
  end

  def targets(opts \\ []) do
    base = Keyword.get(opts, :endpoint) || default_endpoint()
    http = Keyword.get(opts, :http, &Req.request/1)

    case http.(method: :get, url: base <> "/json", retry: false) do
      {:ok, %Req.Response{status: 200, body: list}} when is_list(list) ->
        {:ok,
         list
         |> Enum.filter(&(&1["type"] in ["page", "iframe"]))
         |> Enum.map(
           &%Target{
             id: &1["id"],
             title: &1["title"],
             url: &1["url"],
             type: &1["type"],
             ws_url: &1["webSocketDebuggerUrl"]
           }
         )}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, e} ->
        {:error, e}
    end
  end

  def first_page(opts \\ []) do
    case targets(opts) do
      {:ok, []} -> {:error, :no_targets}
      {:ok, list} -> {:ok, Enum.find(list, &(&1.type == "page")) || hd(list)}
      err -> err
    end
  end

  def evaluate(target_or_ws_url, expression, opts \\ []) do
    call(
      target_or_ws_url,
      "Runtime.evaluate",
      %{
        "expression" => expression,
        "returnByValue" => true,
        "awaitPromise" => Keyword.get(opts, :await_promise?, true)
      },
      opts
    )
  end

  def outer_html(target_or_ws_url, opts \\ []) do
    case evaluate(target_or_ws_url, "document.documentElement.outerHTML", opts) do
      {:ok, %{"result" => %{"value" => html}}} when is_binary(html) -> {:ok, html}
      {:ok, other} -> {:error, {:bad_response, other}}
      err -> err
    end
  end

  def navigate(target_or_ws_url, url, opts \\ []) do
    call(target_or_ws_url, "Page.navigate", %{"url" => url}, opts)
  end

  # ── transport ─────────────────────────────────────────────────────────────

  @doc """
  Send a CDP command and wait for the matching response. Public so tests
  can drive it with a fake transport via the `:transport` option.
  """
  def call(%Target{ws_url: ws_url}, method, params, opts), do: call(ws_url, method, params, opts)

  def call(ws_url, method, params, opts) when is_binary(ws_url) do
    transport = Keyword.get(opts, :transport, &default_transport/4)
    request = %{"id" => :rand.uniform(1_000_000), "method" => method, "params" => params}

    case transport.(ws_url, request, Jason.encode!(request), opts) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => err}} -> {:error, err}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  defp default_transport(ws_url, _request, payload, opts) do
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)

    with {:ok, uri} <- parse_uri(ws_url),
         {:ok, conn} <- mint_connect(uri),
         {:ok, conn, ref} <- ws_upgrade(conn, uri),
         {:ok, conn, ws} <- ws_complete_handshake(conn, ref, recv_timeout),
         {:ok, conn, ws} <- ws_send(conn, ws, ref, {:text, payload}),
         {:ok, frame} <- ws_recv_text(conn, ws, ref, recv_timeout) do
      _ = ws_close(conn, ws, ref)
      Jason.decode(frame)
    end
  end

  defp parse_uri(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["ws", "wss"] -> {:error, {:bad_scheme, uri.scheme}}
      true -> {:ok, uri}
    end
  end

  defp mint_connect(%URI{scheme: scheme, host: host, port: port}) do
    transport = if scheme == "wss", do: :https, else: :http

    Mint.HTTP.connect(transport, host || "localhost", port || default_port(scheme),
      protocols: [:http1]
    )
  end

  defp default_port("wss"), do: 443
  defp default_port(_), do: 80

  defp ws_upgrade(conn, uri) do
    path = uri.path || "/"
    full_path = if uri.query, do: path <> "?" <> uri.query, else: path
    Mint.WebSocket.upgrade(scheme_for(uri.scheme), conn, full_path, [])
  end

  defp scheme_for("wss"), do: :wss
  defp scheme_for(_), do: :ws

  defp ws_complete_handshake(conn, ref, timeout) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case Enum.find(responses, &match?({:done, ^ref}, &1)) do
              nil ->
                ws_complete_handshake(conn, ref, timeout)

              {:done, ^ref} ->
                with {:status, ^ref, status} <-
                       Enum.find(responses, &match?({:status, ^ref, _}, &1)),
                     {:headers, ^ref, headers} <-
                       Enum.find(responses, &match?({:headers, ^ref, _}, &1)),
                     {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, headers) do
                  {:ok, conn, ws}
                end
            end

          {:error, conn, reason, _responses} ->
            {:error, {conn, reason}}
        end
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp ws_send(conn, ws, ref, frame) do
    {:ok, ws, data} = Mint.WebSocket.encode(ws, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, conn, ws}
  end

  defp ws_recv_text(conn, ws, ref, timeout) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, [{:data, ^ref, data}]} ->
            decode_frames(conn, ws, ref, data, timeout)

          {:ok, conn, responses} ->
            payload =
              responses
              |> Enum.filter(&match?({:data, ^ref, _}, &1))
              |> Enum.map_join("", fn {:data, _, d} -> d end)

            decode_frames(conn, ws, ref, payload, timeout)

          {:error, conn, reason, _responses} ->
            {:error, {conn, reason}}
        end
    after
      timeout -> {:error, :recv_timeout}
    end
  end

  defp decode_frames(_conn, ws, _ref, data, _timeout) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, _ws, frames} ->
        case Enum.find(frames, &match?({:text, _}, &1)) do
          {:text, text} -> {:ok, text}
          nil -> {:error, :no_text_frame}
        end

      {:error, _ws, reason} ->
        {:error, reason}
    end
  end

  defp ws_close(conn, ws, ref) do
    case Mint.WebSocket.encode(ws, :close) do
      {:ok, _ws, data} ->
        _ = Mint.WebSocket.stream_request_body(conn, ref, data)
        _ = Mint.HTTP.close(conn)
        :ok

      _ ->
        _ = Mint.HTTP.close(conn)
        :ok
    end
  end
end
