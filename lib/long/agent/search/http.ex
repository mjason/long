defmodule Long.Agent.Search.Http do
  @moduledoc false

  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/123.0 Safari/537.36"

  @default_recv_timeout 7_000

  def user_agent, do: @user_agent

  @doc """
  Browser-flavoured headers shared by all SERP scrapers. Extra headers
  passed in `extra` win over the defaults if keys collide.
  """
  def default_headers(extra \\ []) do
    extra ++
      [
        {"user-agent", @user_agent},
        {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9"},
        {"accept-language", "en-US,en;q=0.9"}
      ]
  end

  @doc """
  GET an SERP URL with the standard headers/timeouts and dispatch on
  the response. `parse_fun` is invoked only on 200 with a binary body;
  it should return `[Result.t()]` (already limit-capped).

  Returns `{:ok, results}` | `{:error, {:http_status, status}}` |
  `{:error, transport_error}`.
  """
  def get_serp(url, query_params, parse_fun, opts) when is_function(parse_fun, 1) do
    http = Keyword.get(opts, :http, &Req.request/1)
    timeout = Keyword.get(opts, :receive_timeout, @default_recv_timeout)

    request =
      http.(
        method: :get,
        url: url,
        params: query_params,
        headers: default_headers(),
        retry: false,
        receive_timeout: timeout
      )

    case request do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_fun.(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, e} ->
        {:error, e}
    end
  end
end
