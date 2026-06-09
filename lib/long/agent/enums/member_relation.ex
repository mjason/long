defmodule Long.Agent.Enums.MemberRelation do
  @moduledoc """
  A neutral identity tag for a group member, kept separate from the
  permission `role`. `:self` marks the owner's own member record (so the
  agent can exclude "me" when addressing others); `:other` is everyone
  else. The specific label — a name, a kinship term, a title — lives in
  the free-form `display_name`.
  """
  use Ash.Type.Enum, values: [:self, :other]
end
