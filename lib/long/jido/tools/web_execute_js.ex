defmodule Long.Jido.Tools.WebExecuteJs do
  @moduledoc """
  Open a URL in Obscura and evaluate an arbitrary JS expression against
  the rendered DOM. Returns whatever the expression resolved to (Obscura
  prints it to stdout — usually JSON for structured payloads).

  Use this when you need a custom extractor beyond what `web_scan` gives
  you — e.g. pulling a specific `<table>`'s rows, scraping JSON-LD,
  reading inline window globals.

  No persistent session: every call is a fresh browser, navigation, JS
  eval, and exit. Combine `URL` + `script` in one call.
  """

  use Jido.Action,
    name: "web_execute_js",
    description:
      "Open a URL in a real headless browser (Obscura) and run a custom JS " <>
        "expression against the rendered DOM. Returns the expression's value " <>
        "as a string (JSON-encode in your script if you need structured output). " <>
        "Use this for custom extractors when `web_scan`'s default text+links " <>
        "summary isn't enough. Each call is a fresh browser — there is no " <>
        "\"current tab\" carried between calls.",
    category: "web",
    tags: ["browser", "js", "extract"],
    vsn: "2.0.0",
    schema:
      Zoi.object(%{
        url: Zoi.string(description: "Absolute URL to load before running the script."),
        script:
          Zoi.string(
            description:
              "JavaScript expression. Top-level value is what gets returned. " <>
                "Wrap multi-statement logic in `(() => { … return X; })()`."
          ),
        wait_until:
          Zoi.string(description: "load (default) | domcontentloaded | networkidle0")
          |> Zoi.optional(),
        timeout_s:
          Zoi.integer(description: "Max navigation time in seconds (default 25)")
          |> Zoi.optional()
      })

  alias Long.Agent.Browser.Cli

  @impl true
  def run(params, _ctx) do
    url = params[:url] || params["url"] || ""
    script = params[:script] || params["script"] || ""

    cond do
      url == "" ->
        {:ok, %{status: "error", msg: "url is required"}}

      script == "" ->
        {:ok, %{status: "error", msg: "script must not be empty"}}

      true ->
        do_eval(url, script, params)
    end
  end

  defp do_eval(url, script, params) do
    cli_opts = build_cli_opts(params)

    case Cli.eval(url, script, cli_opts) do
      {:ok, raw} ->
        {:ok, %{status: "success", url: url, result: String.trim(raw)}}

      {:error, :not_installed} ->
        {:ok,
         %{
           status: "error",
           msg:
             "Obscura headless browser is not installed yet. " <>
               "Background install may still be running — retry shortly."
         }}

      {:error, reason} ->
        {:ok, %{status: "error", url: url, msg: inspect(reason)}}
    end
  end

  defp build_cli_opts(params) do
    [:wait_until, :timeout_s]
    |> Enum.reduce([], fn key, acc ->
      case params[key] do
        nil -> acc
        v -> [{key, v} | acc]
      end
    end)
  end
end
