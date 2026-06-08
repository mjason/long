defmodule Long.Agent.HouseholdMember do
  @moduledoc """
  A person inside a `Household`. Identified within the family by
  `relation` (self / spouse / child / …) plus a free-form `display_name`,
  and optionally a `:owner`/`:member` `role`.

  A member binds one or more chat accounts by sending their `bind_code`
  to the bot; each binding becomes a `BotUser` row pointing back here
  (`BotUser.member_id`), so one member can be reached across both WeChat
  and Telegram, and other members can address them (e.g. "notify my spouse …").

  `bind_code` is a short random token minted on create. It is the only
  secret needed to claim a member, so `regenerate_bind_code` exists to
  rotate it (e.g. after a member is bound, or if a code leaks).
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_household_members"
    repo Long.Repo

    references do
      reference :household, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:household_id, :display_name, :relation, :role]
      change {Long.Agent.HouseholdMember.Changes.EnsureBindCode, []}
    end

    update :update do
      accept [:display_name, :relation, :role]
    end

    update :regenerate_bind_code do
      require_atomic? false
      change {Long.Agent.HouseholdMember.Changes.EnsureBindCode, force: true}
    end

    read :by_bind_code do
      argument :bind_code, :string, allow_nil?: false
      filter expr(bind_code == ^arg(:bind_code))
      get? true
    end

    read :by_household do
      argument :household_id, :uuid, allow_nil?: false
      filter expr(household_id == ^arg(:household_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :display_name, :string do
      allow_nil? false
      public? true
    end

    attribute :relation, Long.Agent.Enums.MemberRelation do
      default :other
      allow_nil? false
      public? true
    end

    attribute :role, Long.Agent.Enums.MemberRole do
      default :member
      allow_nil? false
      public? true
    end

    attribute :bind_code, :string do
      description "Short random token a chat account sends to the bot to claim this member."
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :household, Long.Agent.Household do
      allow_nil? false
      public? true
    end

    has_many :bot_users, Long.Agent.BotUser do
      destination_attribute :member_id
    end
  end

  identities do
    identity :unique_bind_code, [:bind_code]
  end

  @bind_code_bytes 5

  @doc """
  Generate a short, URL/chat-safe bind code. Base32 (Crockford-ish via
  the standard alphabet, padding stripped) over a few random bytes is
  enough entropy for a family-scale namespace while staying easy to type
  from a phone.
  """
  @spec gen_bind_code() :: String.t()
  def gen_bind_code do
    @bind_code_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end
end
