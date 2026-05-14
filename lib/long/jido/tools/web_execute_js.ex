defmodule Long.Jido.Tools.WebExecuteJs do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.WebExecuteJs`. Runs a JS snippet
  inside the current Chrome page via CDP `Runtime.evaluate`.
  """

  use Jido.Action,
    name: "web_execute_js",
    description:
      "Run a JS snippet on the current Chrome page. Useful to click " <>
        "`document.querySelector('[data-ga-id=\"3\"]').click()`, fill inputs, etc. " <>
        "Chrome must be running with --remote-debugging-port=9222.",
    category: "web",
    tags: ["cdp", "chrome", "js"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        script: Zoi.string(description: "JavaScript snippet to execute"),
        target_id: Zoi.string() |> Zoi.optional()
      })

  alias Long.Agent.Browser.CDP

  @impl true
  def run(params, _ctx) do
    script = params[:script] || ""

    if script == "" do
      {:ok, %{status: "error", msg: "script must not be empty"}}
    else
      case eval(script) do
        {:ok, result} -> {:ok, %{status: "success", result: result}}
        {:error, e} -> {:ok, CDP.error_payload(e)}
      end
    end
  end

  defp eval(script) do
    with {:ok, target} <- CDP.first_page(),
         {:ok, result} <- CDP.evaluate(target, script) do
      {:ok, normalize_result(result)}
    end
  end

  defp normalize_result(%{"value" => v}), do: v
  defp normalize_result(%{"description" => d}), do: d
  defp normalize_result(other), do: other
end
