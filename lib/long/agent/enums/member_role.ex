defmodule Long.Agent.Enums.MemberRole do
  @moduledoc """
  Authorization role of a household member. `:owner` may manage the
  household (add/remove members) and promote a personal skill to the
  shared global set; `:member` is an ordinary participant scoped to
  their own sessions, skills, and code workspace.
  """
  use Ash.Type.Enum, values: [:owner, :member]
end
