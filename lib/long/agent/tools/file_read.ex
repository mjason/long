defmodule Long.Agent.Tools.FileRead do
  @moduledoc """
  Port of `do_file_read`. Reads a slice of a file, optionally filtered by a
  case-insensitive keyword, with optional line numbers prepended (`N|line`).
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, ToolContext}

  @impl true
  def name, do: "file_read"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Read the contents of a file. Returns up to `count` lines starting at `start`. " <>
            "If `keyword` is given, returns the first match (case-insensitive) and its neighbourhood.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path relative to the agent cwd."},
            "start" => %{
              "type" => "integer",
              "default" => 1,
              "description" => "1-based start line."
            },
            "count" => %{"type" => "integer", "default" => 200},
            "keyword" => %{"type" => "string"},
            "show_linenos" => %{"type" => "boolean", "default" => true}
          },
          "required" => ["path"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{cwd: cwd}) do
    path = expand(cwd, args["path"] || "")
    start = args["start"] || 1
    count = args["count"] || 200
    keyword = args["keyword"]
    show? = Map.get(args, "show_linenos", true)

    Stream.concat([
      [{:output, "\n[Action] Reading file: #{path}\n"}],
      Stream.resource(
        fn -> path end,
        fn
          :done -> {:halt, :done}
          p -> {[{:outcome, read_file(p, start, count, keyword, show?)}], :done}
        end,
        fn _ -> :ok end
      )
    ])
  end

  defp expand(cwd, rel), do: cwd |> Path.join(rel) |> Path.expand()

  defp read_file(path, start, count, keyword, show?) do
    case File.read(path) do
      {:error, reason} ->
        StepOutcome.cont(%{"status" => "error", "msg" => "Error: #{:file.format_error(reason)}"})

      {:ok, contents} ->
        lines = String.split(contents, ~r/\r?\n/, trim: false)
        total = length(lines)

        {sliced, base_no} =
          case keyword do
            kw when is_binary(kw) and kw != "" -> grep(lines, kw, count)
            _ -> {Enum.slice(lines, (start - 1)..(start - 1 + count - 1)//1), start}
          end

        body =
          if show? do
            sliced
            |> Enum.with_index(base_no)
            |> Enum.map_join("\n", fn {line, n} -> "#{n}|#{line}" end)
          else
            Enum.join(sliced, "\n")
          end

        body =
          if show?,
            do: "show_linenos is set, so the output below is formatted as (line_no|)content.\n" <> body,
            else: body

        StepOutcome.cont(%{"status" => "success", "total_lines" => total, "content" => body})
    end
  end

  defp grep(lines, keyword, count) do
    kw = String.downcase(keyword)

    case Enum.find_index(lines, fn l -> String.contains?(String.downcase(l), kw) end) do
      nil ->
        {["(keyword not found)"], 1}

      i ->
        from = max(0, i - div(count, 2))
        to = min(length(lines) - 1, from + count - 1)
        {Enum.slice(lines, from..to), from + 1}
    end
  end
end
