defmodule Long.Jido.Tools.Workspace do
  @moduledoc """
  Workspace-path resolution shared by the jido file tools. Resolves a
  user-supplied (LLM-supplied) path against `ctx[:workspace_root]` and
  enforces that the result stays inside the workspace — `../` escapes
  return `{:error, reason}` instead of touching disk above the root.
  """

  @doc """
  Resolve `path` relative to the workspace root from `ctx`. Returns
  `{:ok, absolute_path}` when the result is inside the workspace, or
  `{:error, reason}` otherwise.
  """
  @spec resolve_path(map() | keyword(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_path(_ctx, nil), do: {:error, "path is required"}
  def resolve_path(_ctx, ""), do: {:error, "path is required"}

  def resolve_path(ctx, path) when is_binary(path) do
    base =
      (ctx[:workspace_root] || File.cwd!())
      |> Path.expand()

    resolved = base |> Path.join(path) |> Path.expand()

    if resolved == base or String.starts_with?(resolved, base <> "/") do
      {:ok, resolved}
    else
      {:error, "path escapes workspace root"}
    end
  end
end
