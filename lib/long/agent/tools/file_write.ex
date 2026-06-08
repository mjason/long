defmodule Long.Agent.Tools.FileWrite do
  @moduledoc """
  Port of `do_file_write`. With native function calling the `content` arg
  carries the body directly; we still fall back to extracting a
  `<file_content>...</file_content>` or a fenced block from the LLM response
  text for compatibility with text-protocol relays.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool, ToolContext}

  @impl true
  def name, do: "file_write"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Write a file in full (`overwrite`/`append`/`prepend`). Use `file_patch` for surgical changes.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "content" => %{"type" => "string"},
            "mode" => %{
              "type" => "string",
              "enum" => ["overwrite", "append", "prepend"],
              "default" => "overwrite"
            }
          },
          "required" => ["path"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{cwd: cwd, response: response}) do
    path = cwd |> Path.join(args["path"] || "") |> Path.expand()
    mode = args["mode"] || "overwrite"
    action = action_for(mode)

    case content_from(args, response) do
      nil ->
        Tool.emit(
          Long.Copy.t("tool.file_no_content") <> "\n",
          StepOutcome.cont(%{
            "status" => "error",
            "msg" =>
              "No content found. Provide via the `content` argument or " <>
                "a <file_content>…</file_content> block in your reply."
          })
        )

      content ->
        outcome = perform_write(path, mode, content)
        Tool.emit("[Action] #{action} #{Path.basename(path)}\n", outcome)
    end
  end

  defp action_for("append"), do: "Appending to"
  defp action_for("prepend"), do: "Prepending to"
  defp action_for(_), do: "Overwriting"

  defp content_from(%{"content" => c}, _resp) when is_binary(c) and c != "", do: c

  defp content_from(_args, %{content: text}) when is_binary(text) and text != "" do
    case Regex.run(~r/<file_content[^>]*>(.*?)<\/file_content>/s, text, capture: :all_but_first) do
      [match] ->
        String.trim(match)

      _ ->
        case Regex.scan(~r/```[^\n]*\n([\s\S]*?)```/, text, capture: :all_but_first) do
          [] -> nil
          matches -> matches |> List.last() |> hd() |> String.trim()
        end
    end
  end

  defp content_from(_, _), do: nil

  defp perform_write(path, mode, content) do
    File.mkdir_p!(Path.dirname(path))

    result =
      case mode do
        "append" ->
          File.write(path, content, [:append])

        "prepend" ->
          old = if File.exists?(path), do: File.read!(path), else: ""
          File.write(path, content <> old)

        _ ->
          File.write(path, content)
      end

    case result do
      :ok ->
        StepOutcome.cont(%{
          "status" => "success",
          "bytes_written" => byte_size(content),
          "path" => path
        })

      {:error, reason} ->
        StepOutcome.cont(%{
          "status" => "error",
          "msg" => :file.format_error(reason) |> to_string()
        })
    end
  end
end
