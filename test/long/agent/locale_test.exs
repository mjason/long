defmodule Long.Agent.LocaleTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Locale

  # Build a wechat bot_user wired to a member/group/credential, each
  # with an optional locale, so we can probe the fallback chain.
  defp chain(opts) do
    {:ok, hh} = Agent.create_group(%{name: "H-#{:rand.uniform(99_999)}", locale: opts[:group]})

    {:ok, m} =
      Agent.create_member(%{group_id: hh.id, display_name: "X", relation: :self, locale: opts[:member]})

    cname = "wc-#{:rand.uniform(99_999)}"
    {:ok, _} = Agent.upsert_wechat_credential(%{name: cname, member_id: m.id, locale: opts[:credential]})

    sess = Agent.start_session!(%{title: "t"})
    meta = if opts[:platform], do: %{"locale" => opts[:platform]}, else: %{}

    {:ok, bu} =
      Agent.create_bot_user(%{
        platform: :wechat,
        external_id: "u-#{:rand.uniform(999_999)}",
        session_id: sess.id,
        member_id: m.id,
        credential_name: cname,
        metadata: meta
      })

    bu
  end

  describe "for_bot_user/1 — channel → member → group → platform → default" do
    test "channel (credential) locale wins over everything" do
      assert Locale.for_bot_user(chain(credential: "zh", member: "en", group: "en", platform: "en")) == "zh"
    end

    test "member locale wins over group + platform" do
      assert Locale.for_bot_user(chain(member: "en", group: "zh", platform: "zh")) == "en"
    end

    test "group default applies (and beats platform-detected)" do
      assert Locale.for_bot_user(chain(group: "zh", platform: "en")) == "zh"
    end

    test "platform-detected locale used when no owner setting exists" do
      assert Locale.for_bot_user(chain(platform: "en")) == "en"
    end

    test "falls back to the system default when nothing is set" do
      assert Locale.for_bot_user(chain([])) == Long.Copy.default_locale()
    end
  end

  describe "for_member/1 — member → group → default" do
    test "member locale wins over group" do
      {:ok, hh} = Agent.create_group(%{name: "H", locale: "zh"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "X", relation: :self, locale: "en"})
      {:ok, loaded} = Agent.get_member(m.id, load: [:group])
      assert Locale.for_member(loaded) == "en"
    end

    test "group default when member locale unset" do
      {:ok, hh} = Agent.create_group(%{name: "H", locale: "zh"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "X", relation: :self})
      {:ok, loaded} = Agent.get_member(m.id, load: [:group])
      assert Locale.for_member(loaded) == "zh"
    end
  end
end
