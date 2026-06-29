defmodule Long.Jido.Tools.SkillUpdate do
  @moduledoc """
  Edit an existing skill in place — rewrite its `SKILL.md` body and/or its
  one-line description from chat.

  A member may edit their own **personal** skill; editing a **shared/global**
  skill requires the group `:owner` role (the same rule as creating one). The
  skill's `name` is its identity and cannot be changed — create a new skill to
  rename. Only usable from a chat bound to a group member.
  """

  use Jido.Action,
    name: "skill_update",
    description: """
    Update an existing skill you can see: rewrite its `body` (the SKILL.md
    instructions) and/or its one-line `description`. Use this to improve a
    skill after you learn a better way to do something. `name` identifies the
    skill and cannot be changed. Editing a shared/global skill needs the owner
    role. Read the skill first (skill_read) so you don't drop existing content.
    """,
    category: "skill",
    tags: ["skill", "update"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        name: Zoi.string(description: "Name of the skill to edit (its lookup key)."),
        description:
          Zoi.string(description: "New one-line summary (omit to keep the current one).")
          |> Zoi.optional(),
        body:
          Zoi.string(description: "New full SKILL.md body, markdown (omit to keep current).")
          |> Zoi.optional()
      })

  alias Long.Agent
  alias Long.Agent.Skill.Store
  alias Long.Copy

  @impl true
  def run(params, ctx) do
    member = ctx[:session_id] && Agent.member_for_session(ctx[:session_id])

    cond do
      is_nil(member) ->
        {:ok, %{status: "error", msg: Copy.t("skill.caller_unbound")}}

      is_nil(params[:description]) and is_nil(params[:body]) ->
        {:ok, %{status: "error", msg: Copy.t("skill.update_noop")}}

      true ->
        update(params, member)
    end
  end

  defp update(params, member) do
    case Store.get_visible(params[:name], member.id) do
      {:error, :not_found} ->
        {:ok, %{status: "error", msg: Copy.t("skill.not_found", %{name: params[:name]})}}

      {:ok, %{scope: :global}} when member.role != :owner ->
        {:ok, %{status: "error", msg: Copy.t("skill.update_owner_only")}}

      {:ok, _skill} ->
        opts =
          [member_id: member.id]
          |> maybe_put(:description, params[:description])
          |> maybe_put(:body, params[:body])

        case Store.update_skill(params[:name], opts) do
          {:ok, _dir} ->
            {:ok, %{status: "updated", name: params[:name]}}

          {:error, reason} ->
            {:ok, %{status: "error", msg: Copy.t("skill.update_failed", %{reason: inspect(reason)})}}
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
