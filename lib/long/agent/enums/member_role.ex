defmodule Long.Agent.Enums.MemberRole do
  @moduledoc """
  Authorization role of a group member. `:owner` may manage the
  group (add/remove members) and promote a personal skill to the
  shared global set; `:member` is an ordinary participant scoped to
  their own sessions, skills, and code workspace.
  """
  use Ash.Type.Enum, values: [:owner, :member]
end
