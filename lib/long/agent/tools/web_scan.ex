defmodule Long.Agent.Tools.WebScan do
  @moduledoc """
  Port of `do_web_scan`. Connects to a running Chrome via CDP, grabs the
  current page's `outerHTML`, runs `Long.Agent.Browser.SimpHtml.simplify/2`
  and returns the simplified `%{title, text, elements}` payload.

  Args:

  - `url` — optional; if given, navigate to it first
  - `text_only` — drop the `elements` list (saves tokens)
  - `target_id` — pick a specific Chrome target id; defaults to the first page
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool, ToolContext}
  alias Long.Agent.Browser.{CDP, SimpHtml}

  @impl true
  def name, do: "web_scan"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Scan the current Chrome page via CDP. Optionally navigate to a URL first. " <>
            "Returns simplified text + clickable element list.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string"},
            "text_only" => %{"type" => "boolean", "default" => false},
            "target_id" => %{"type" => "string"}
          }
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{}) do
    Tool.emit("[Action] web_scan #{args["url"] || "(current page)"}\n", do_run(args))
  end

  defp do_run(args) do
    with {:ok, target} <- pick_target(args["target_id"]),
         :ok <- maybe_navigate(target, args["url"]),
         {:ok, html} <- CDP.outer_html(target),
         {:ok, simplified} <- SimpHtml.simplify(html) do
      payload = build_payload(target, simplified, args["text_only"] == true)
      StepOutcome.cont(payload)
    else
      {:error, reason} ->
        StepOutcome.cont(%{"status" => "error", "msg" => inspect(reason)})
    end
  end

  defp pick_target(nil), do: CDP.first_page()
  # MVP: ignore target_id filter
  defp pick_target(_id), do: CDP.first_page()

  defp maybe_navigate(_target, nil), do: :ok
  defp maybe_navigate(_target, ""), do: :ok

  defp maybe_navigate(target, url) do
    case CDP.navigate(target, url) do
      {:ok, _} ->
        # Give the page a moment to load before scanning
        Process.sleep(500)
        :ok

      err ->
        err
    end
  end

  defp build_payload(target, simplified, text_only?) do
    base = %{
      "status" => "success",
      "url" => target.url,
      "title" => simplified.title,
      "text" => simplified.text
    }

    if text_only?, do: base, else: Map.put(base, "elements", simplified.elements)
  end
end
