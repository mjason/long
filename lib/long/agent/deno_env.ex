defmodule Long.Agent.DenoEnv do
  @moduledoc """
  Owns the per-member Deno workspaces the agent runs code in.

  Code execution is Deno (TypeScript/JavaScript) only — a single
  self-contained binary with a built-in permission sandbox, which is what
  makes multi-member execution safe to share on one box. Each member gets
  an isolated workspace under

      <workspace_root>/members/<member_id>/

  and the runner grants Deno read/write *only inside that directory* (see
  `Long.Agent.CodeRunner.build_command/3` for the `deno` clause), so one
  member's code can't read or clobber another's files. Unbound / web-chat
  sessions (no member) fall back to the shared workspace root.
  """

  @members_dir "members"
  @unbound_dir "unbound"

  @doc """
  Workspace root. Honors `config :long, Long.Agent, workspace_root: …`,
  falling back to the legacy `:temp_root`.
  """
  def root do
    cfg = Application.get_env(:long, Long.Agent, [])

    cfg[:workspace_root] ||
      cfg[:temp_root] ||
      Path.expand("priv/agent/workspace", File.cwd!())
  end

  @doc """
  The workspace directory for `member_id` under `base` (defaults to
  `root/0`). A `nil` member resolves to the shared base itself.
  """
  def workspace(base \\ nil, member_id)
  def workspace(base, nil), do: base || root()

  def workspace(base, member_id) when is_binary(member_id),
    do: Path.join([base || root(), @members_dir, member_id])

  @doc """
  Inbound-file directory for a bound member — `members/<id>/inbox/`, *inside*
  that member's own workspace. Staging user-sent files here (instead of a
  global `wechat_inbox`/`telegram_inbox`) is what lets the sandboxed `code_run`
  (rooted at the member dir) open them to parse `.docx`/PDF, while `file_read`
  reaches them too. Returns `nil` for a `nil` member, so bot callers fall back
  to their shared inbox for unbound/stranger sessions.
  """
  def member_inbox(base \\ nil, member_id)
  def member_inbox(base, member_id) when is_binary(member_id),
    do: Path.join(workspace(base, member_id), "inbox")

  def member_inbox(_base, _), do: nil

  @doc """
  Workspace for an unbound / web-chat session (no group member) — an
  isolated `unbound/<session_id>` dir so anonymous sessions don't share one
  directory and read each other's files. A `nil` session falls back to the
  shared base.
  """
  def unbound_workspace(base \\ nil, session_id)

  def unbound_workspace(base, session_id) when is_binary(session_id),
    do: Path.join([base || root(), @unbound_dir, session_id])

  def unbound_workspace(base, _), do: base || root()

  @doc """
  Resolve a caller's base workspace: the member's `members/<id>/` when a
  group member is bound, otherwise an isolated `unbound/<session_id>/`.
  Centralizes the member-vs-unbound branch both `code_run` tools share.
  """
  def session_workspace(base, member_id, session_id)

  def session_workspace(base, member_id, _session_id) when is_binary(member_id),
    do: workspace(base, member_id)

  def session_workspace(base, _member_id, session_id),
    do: unbound_workspace(base, session_id)

  @doc "Ensure the member's workspace dir exists. Returns `{:ok, dir}`."
  def ensure!(base \\ nil, member_id \\ nil) do
    dir = workspace(base, member_id)
    File.mkdir_p!(dir)
    {:ok, dir}
  end

  @doc """
  Resolve a caller-supplied relative `cwd` *inside* `workspace`, never
  escaping it. `..` traversal that would land outside the workspace is
  clamped back to the workspace root — the runner grants Deno
  read/write on the returned path, so letting it escape would breach the
  per-member sandbox.
  """
  def confine(workspace, rel) do
    workspace = Path.expand(workspace)
    candidate = workspace |> Path.join(rel || "") |> Path.expand()

    if candidate == workspace or String.starts_with?(candidate, workspace <> "/"),
      do: candidate,
      else: workspace
  end

  @doc """
  Path to the `deno` binary, or `{:error, :deno_missing}`. Resolved via
  `Long.Agent.Deno.Engine` (which auto-installs a managed binary at boot),
  falling back to a no-download PATH/bin-dir lookup.
  """
  def deno_bin do
    case Long.Agent.Deno.Engine.ready_path() do
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, :deno_missing}
    end
  end
end
