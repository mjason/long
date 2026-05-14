defmodule Long.Agent.Tools.WebExecuteJs do
  @moduledoc """
  Port of `do_web_execute_js`. Runs an arbitrary JS snippet inside the
  current Chrome page via CDP `Runtime.evaluate`. Returns the value (when
  serializable) or the thrown exception.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool, ToolContext}
  alias Long.Agent.Browser.CDP

  @impl true
  def name, do: "web_execute_js"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Run a JS snippet on the current Chrome page. Useful to click " <>
            "`document.querySelector('[data-ga-id=\"3\"]').click()`, fill inputs, etc.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "script" => %{"type" => "string"},
            "target_id" => %{"type" => "string"}
          },
          "required" => ["script"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{}) do
    Tool.emit("[Action] web_execute_js\n", do_run(args))
  end

  defp do_run(args) do
    script = args["script"] || ""

    if script == "" do
      StepOutcome.cont(%{"status" => "error", "msg" => "script must not be empty"})
    else
      case eval(script) do
        {:ok, result} -> StepOutcome.cont(%{"status" => "success", "result" => result})
        {:error, e} -> StepOutcome.cont(CDP.error_payload(e))
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
