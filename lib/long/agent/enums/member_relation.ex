defmodule Long.Agent.Enums.MemberRelation do
  @moduledoc """
  A household member's relation within the family group, used both for
  display and for relation-based addressing (e.g. an agent asked to
  "notify my spouse …" resolves the `:spouse` member of the same household).

  `:self` is the household owner's own member record. `:other` is the
  catch-all for relations not worth enumerating — the free-form
  `display_name` carries the specific label in that case.
  """
  use Ash.Type.Enum, values: [:self, :spouse, :child, :parent, :other]
end
