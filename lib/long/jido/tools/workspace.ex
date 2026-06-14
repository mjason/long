defmodule Long.Jido.Tools.Workspace do
  @moduledoc """
  Workspace-path resolution shared by the jido file tools. Resolves a
  user-supplied (LLM-supplied) path against `ctx[:workspace_root]` and
  enforces that the result stays inside the workspace — `../` escapes
  return `{:error, reason}` instead of touching disk above the root.
  """

  @doc """
  Resolve `path` against the workspace root from `ctx`. A relative path is
  joined under the root; an absolute path is honored as-is. Either way the
  result must stay inside the root — a `../` escape or an absolute path
  above the root returns `{:error, reason}` instead of touching disk.
  """
  @spec resolve_path(map() | keyword(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_path(_ctx, nil), do: {:error, "path is required"}
  def resolve_path(_ctx, ""), do: {:error, "path is required"}

  def resolve_path(ctx, path) when is_binary(path) do
    base =
      (ctx[:workspace_root] || File.cwd!())
      |> Path.expand()

    # An absolute path — e.g. the absolute marker we hand the model for an
    # inbound file (`<workspace_root>/wechat_inbox/…`) — must be honored as
    # given. `Path.join(base, "/abs")` wrongly nests it *under* base, so the
    # staged file is never found (the inbound-file "no permission to read"
    # bug). A relative path still resolves against the workspace root.
    resolved =
      if Path.type(path) == :absolute,
        do: Path.expand(path),
        else: base |> Path.join(path) |> Path.expand()

    # Confine is unchanged: the result must stay inside the workspace root,
    # so an absolute path outside it (or a `../` escape) is still rejected.
    if resolved == base or String.starts_with?(resolved, base <> "/") do
      {:ok, resolved}
    else
      {:error, "path escapes workspace root"}
    end
  end
end
