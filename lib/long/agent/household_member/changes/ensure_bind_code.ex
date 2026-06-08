defmodule Long.Agent.HouseholdMember.Changes.EnsureBindCode do
  @moduledoc """
  Mint a `bind_code` for a `HouseholdMember`. On create it fills the code
  only when absent; with `force: true` (the `regenerate_bind_code` action)
  it always overwrites, rotating the token.
  """
  use Ash.Resource.Change

  alias Long.Agent.HouseholdMember

  @impl true
  def change(changeset, opts, _context) do
    cond do
      opts[:force] ->
        force(changeset)

      is_nil(Ash.Changeset.get_attribute(changeset, :bind_code)) ->
        force(changeset)

      true ->
        changeset
    end
  end

  defp force(changeset),
    do: Ash.Changeset.force_change_attribute(changeset, :bind_code, HouseholdMember.gen_bind_code())
end
