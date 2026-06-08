defmodule Long.Agent.DenoEnv do
  @moduledoc """
  Owns the per-member Deno workspaces the agent runs code in.

  Code execution defaults to Deno (TypeScript/JavaScript) rather than
  Python: Deno is a single self-contained binary with a built-in
  permission sandbox, which is what makes multi-member execution safe to
  share on one box. Each member gets an isolated workspace under

      <workspace_root>/members/<member_id>/

  and the runner only grants Deno read/write *inside that directory*
  (see `Long.Agent.PythonRunner.build_command/3` for the `deno` clause),
  so one member's code can't read or clobber another's files. Unbound /
  web-chat sessions (no member) fall back to the shared workspace root.

  Python stays available as an opt-in "heavy mode" for the rare task that
  genuinely needs the Python package ecosystem; it runs in the same
  per-member directory via `Long.Agent.PythonEnv`.
  """

  @members_dir "members"

  @doc """
  Workspace root — the single source of truth lives in
  `Long.Agent.PythonEnv.root/0`; Deno and Python share the same base.
  """
  defdelegate root, to: Long.Agent.PythonEnv

  @doc """
  The workspace directory for `member_id` under `base` (defaults to
  `root/0`). A `nil` member resolves to the shared base itself.
  """
  def workspace(base \\ nil, member_id)
  def workspace(base, nil), do: base || root()

  def workspace(base, member_id) when is_binary(member_id),
    do: Path.join([base || root(), @members_dir, member_id])

  @doc "Ensure the member's workspace dir exists. Returns `{:ok, dir}`."
  def ensure!(base \\ nil, member_id \\ nil) do
    dir = workspace(base, member_id)
    File.mkdir_p!(dir)
    {:ok, dir}
  end

  @doc "Path to the `deno` binary, or `{:error, :deno_missing}` if not on PATH."
  def deno_bin do
    case System.find_executable("deno") do
      nil -> {:error, :deno_missing}
      path -> {:ok, path}
    end
  end
end
