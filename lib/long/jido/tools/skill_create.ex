defmodule Long.Jido.Tools.SkillCreate do
  @moduledoc """
  Create a new skill (a reusable `SKILL.md` capability package) from chat.

  Two spaces:
    * **personal** (default) — lands in the caller's `members/<id>/` space,
      visible only to them.
    * **shared** (`shared: true`) — lands in the household's shared/global
      space, visible to everyone. Only a member with role `:owner` may
      create a shared skill (the web admin can also create shared skills
      from `/manage → Skills`).

  Only usable from a chat bound to a family member.
  """

  use Jido.Action,
    name: "skill_create",
    description: """
    Create a reusable skill (a SKILL.md manual the agent can later read and
    follow). Personal by default; set shared: true to publish it to the
    whole family — only the household owner may do that. Give a short
    `name`, a one-line `description` (used for discovery), and the `body`
    (the SKILL.md instructions, markdown).
    """,
    category: "skill",
    tags: ["skill", "create"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        name: Zoi.string(description: "Skill name (also its lookup key)."),
        description: Zoi.string(description: "One-line summary, used for discovery."),
        body:
          Zoi.string(description: "SKILL.md body (markdown instructions).")
          |> Zoi.optional()
          |> Zoi.default(""),
        shared:
          Zoi.boolean(description: "Publish to the shared/global space (owner only).")
          |> Zoi.optional()
          |> Zoi.default(false)
      })

  alias Long.Agent
  alias Long.Agent.Skill.Store
  alias Long.Copy

  @impl true
  def run(params, ctx) do
    member = ctx[:session_id] && Agent.member_for_session(ctx[:session_id])
    shared? = params[:shared] == true

    cond do
      is_nil(member) ->
        {:ok, %{status: "error", msg: Copy.t("skill.caller_unbound")}}

      shared? and member.role != :owner ->
        {:ok, %{status: "error", msg: Copy.t("skill.owner_only")}}

      true ->
        member_id = if shared?, do: nil, else: member.id
        create(params, shared?, member_id)
    end
  end

  defp create(params, shared?, member_id) do
    case Store.create_skill(params[:name], params[:description], params[:body], member_id: member_id) do
      {:ok, _dir} ->
        {:ok, %{status: "created", name: params[:name], scope: if(shared?, do: "shared", else: "personal")}}

      {:error, :name_taken} ->
        {:ok, %{status: "error", msg: Copy.t("skill.name_taken", %{name: params[:name]})}}

      {:error, reason} ->
        {:ok, %{status: "error", msg: Copy.t("skill.create_failed", %{reason: inspect(reason)})}}
    end
  end
end
