defmodule Long.Jido.Tools.FileRead do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.FileRead`. Resolves paths against
  the per-session workspace root (`ctx.workspace_root`).
  """

  use Jido.Action,
    name: "file_read",
    description:
      "Read a file. Returns up to `count` lines starting at `start`. If `keyword` " <>
        "is given, returns the first case-insensitive match's neighbourhood.",
    category: "filesystem",
    tags: ["file"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        path: Zoi.string(description: "Path relative to the workspace cwd."),
        start: Zoi.integer() |> Zoi.optional() |> Zoi.default(1),
        count: Zoi.integer() |> Zoi.optional() |> Zoi.default(200),
        keyword: Zoi.string() |> Zoi.optional(),
        show_linenos: Zoi.boolean() |> Zoi.optional() |> Zoi.default(true)
      })

  alias Long.Jido.Tools.Workspace

  @impl true
  def run(params, ctx) do
    with {:ok, path} <- Workspace.resolve_path(ctx, params[:path]),
         {:ok, contents} <- File.read(path) do
      if binary_blob?(contents),
        do: {:ok, %{status: "error", msg: binary_hint()}},
        else: render(contents, params)
    else
      {:error, reason} when is_binary(reason) ->
        {:ok, %{status: "error", msg: reason}}

      {:error, reason} ->
        {:ok, %{status: "error", msg: :file.format_error(reason) |> to_string()}}
    end
  end

  # A NUL byte means this isn't UTF-8 text the model can use — it's a binary
  # blob (.docx is a zip; .pdf / .doc are binary). file_read would only hand
  # back mojibake, so point the model at code_run + a parser instead. The file
  # now lives in the member's own workspace inbox, so code_run (sandboxed to
  # that dir) can open it.
  defp binary_blob?(contents), do: String.contains?(contents, <<0>>)

  defp binary_hint do
    "This file looks binary (.docx / .pptx / .xlsx / .pdf / .doc), not text — " <>
      "file_read can't extract it. Use code_run (Deno, NO subprocess) instead: " <>
      "import a parser from esm.sh — `mammoth` for .docx, `unpdf` for .pdf — or, " <>
      "since .docx/.pptx/.xlsx are ZIP, unzip with `JSZip` and read the XML (for " <>
      ".pptx, the slides' `<a:t>` text). Don't shell out to python/libreoffice; " <>
      "there is no subprocess. A legacy .doc/.ppt has no good JS parser — ask for " <>
      ".docx/.pptx, PDF, or text."
  end

  defp render(contents, params) do
    lines = String.split(contents, ~r/\r?\n/, trim: false)
    total = length(lines)
    start = params[:start] || 1
    count = params[:count] || 200
    show? = Map.get(params, :show_linenos, true)

    {sliced, base_no} =
      case params[:keyword] do
        kw when is_binary(kw) and kw != "" -> grep(lines, kw, count)
        _ -> {Enum.slice(lines, (start - 1)..(start - 1 + count - 1)//1), start}
      end

    body =
      if show? do
        sliced
        |> Enum.with_index(base_no)
        |> Enum.map_join("\n", fn {l, n} -> "#{n}|#{l}" end)
      else
        Enum.join(sliced, "\n")
      end

    {:ok, %{status: "success", total_lines: total, content: body}}
  end

  defp grep(lines, keyword, count) do
    kw = String.downcase(keyword)

    case Enum.find_index(lines, &String.contains?(String.downcase(&1), kw)) do
      nil ->
        {["(keyword not found)"], 1}

      i ->
        from = max(0, i - div(count, 2))
        to = min(length(lines) - 1, from + count - 1)
        {Enum.slice(lines, from..to), from + 1}
    end
  end
end
