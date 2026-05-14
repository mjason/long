defmodule Long.Agent.Tools.FilePatch do
  @moduledoc """
  Port of `do_file_patch`. Replaces an anchored snippet (`old_content`) with
  `new_content`. We require the anchor to appear **exactly once** in the file
  so the model can't accidentally patch the wrong site.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool, ToolContext}

  @impl true
  def name, do: "file_patch"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Replace an exact `old_content` snippet with `new_content` in a file. " <>
            "The anchor must appear exactly once.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "old_content" => %{"type" => "string"},
            "new_content" => %{"type" => "string"}
          },
          "required" => ["path", "old_content", "new_content"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{cwd: cwd}) do
    path = cwd |> Path.join(args["path"] || "") |> Path.expand()
    old = args["old_content"] || ""
    new = args["new_content"] || ""

    Tool.emit("[Action] Patching file: #{path}\n", patch(path, old, new))
  end

  defp patch(_path, "", _new),
    do: StepOutcome.cont(%{"status" => "error", "msg" => "old_content must not be empty"})

  defp patch(path, old, new) do
    case File.read(path) do
      {:error, reason} ->
        StepOutcome.cont(%{
          "status" => "error",
          "msg" => :file.format_error(reason) |> to_string()
        })

      {:ok, content} ->
        count = occurrences(content, old)

        cond do
          count == 0 ->
            StepOutcome.cont(%{"status" => "error", "msg" => "old_content not found"})

          count > 1 ->
            StepOutcome.cont(%{
              "status" => "error",
              "msg" => "old_content matches #{count} sites; refine the anchor"
            })

          true ->
            new_content = String.replace(content, old, new, global: false)
            File.write!(path, new_content)

            StepOutcome.cont(%{
              "status" => "success",
              "bytes_before" => byte_size(content),
              "bytes_after" => byte_size(new_content)
            })
        end
    end
  end

  defp occurrences(haystack, needle) do
    haystack
    |> :binary.matches(needle)
    |> length()
  end
end
