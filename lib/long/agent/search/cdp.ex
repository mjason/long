defmodule Long.Agent.Search.Cdp do
  @moduledoc """
  Browser-rendered SERP extraction. `render_and_eval/3` navigates to a
  URL via `Browser.Cli` (Obscura) and evaluates a JS expression against
  the rendered DOM. Used by `Search.Google` to bypass the consent-wall
  / JS-only shell Google serves to non-browser clients.

  Historical name — no longer speaks CDP. Stubs in tests can plug in
  via the `:cdp_mod` opt; both the legacy `render_and_eval/3` and the
  modern `eval/3` interfaces are accepted.
  """

  alias Long.Agent.Browser.Cli

  @default_wait_ms 1_800

  @doc "Cheap availability probe — true if the Obscura binary is installed."
  @spec available?() :: boolean()
  def available? do
    cli = which_cli()
    cli.available?()
  end

  @doc """
  Fetch `url` in a real browser, evaluate `js_expr`, and return the
  result as whatever string Obscura prints (caller usually
  `Jason.decode/1`s it).

  ## Options

    * `:wait_until` — `"load"` (default) | `"domcontentloaded"` |
      `"networkidle0"`. Set to `networkidle0` for JS-heavy SPAs.
    * `:timeout_s` — max navigation time in seconds (default 25).
    * `:cdp` — deprecated; injection point for test stubs. The stub
      must implement `eval(url, js, opts)` returning `{:ok, str}` or
      `{:error, term}`. (The old module-with-`render_and_eval/3` shape
      is still accepted for compatibility.)
  """
  @spec render_and_eval(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def render_and_eval(url, js_expr, opts \\ []) do
    cli = which_cli(opts)

    cond do
      function_exported?(cli, :render_and_eval, 3) ->
        # Legacy stub interface — Search.Google's old tests inject a
        # module that implements render_and_eval/3 directly. Honor it.
        cli.render_and_eval(url, js_expr, opts)

      function_exported?(cli, :eval, 3) ->
        cli.eval(url, js_expr, eval_opts(opts))

      true ->
        {:error, {:bad_cli_stub, cli}}
    end
  end

  defp which_cli(opts \\ []) do
    case Keyword.get(opts, :cdp) || Keyword.get(opts, :cdp_mod) do
      nil -> Cli
      mod when is_atom(mod) -> mod
    end
  end

  defp eval_opts(opts) do
    [
      wait_until: Keyword.get(opts, :wait_until, "load"),
      timeout_s: Keyword.get(opts, :timeout_s, max(div(@default_wait_ms, 1_000), 15))
    ]
    |> Keyword.merge(Keyword.take(opts, [:runner, :stealth]))
  end
end
