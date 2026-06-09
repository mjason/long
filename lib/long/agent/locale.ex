defmodule Long.Agent.Locale do
  @moduledoc """
  Resolve the display language for a chat user's outbound bot copy via a
  fallback chain:

      channel (credential) → member → household → platform-detected → system default

  Owner-set values (credential / member / household, configured in `/manage`)
  win over the platform's auto-detected language (e.g. Telegram's
  `language_code`), which in turn beats the hard `en` fallback. A `nil`/blank
  at any level falls through to the next. Unknown locale strings are left
  as-is — `Long.Copy.t/3` normalizes and falls back when rendering.
  """

  alias Long.Agent
  alias Long.Copy

  @doc "Locale for the `BotUser` this chat belongs to (the full chain)."
  def for_bot_user(%{} = user) do
    credential_locale(Map.get(user, :platform), Map.get(user, :credential_name)) ||
      member_locale(Map.get(user, :member_id)) ||
      platform_locale(Map.get(user, :metadata)) ||
      Copy.default_locale()
  end

  def for_bot_user(_), do: Copy.default_locale()

  @doc """
  Locale for a household member directly (member → household → default).
  Used when addressing someone other than the current chat user.
  """
  def for_member(%{} = member), do: member_chain(member) || Copy.default_locale()
  def for_member(_), do: Copy.default_locale()

  # ── chain steps ─────────────────────────────────────────────────────

  defp credential_locale(:wechat, name) when is_binary(name) do
    case Agent.get_wechat_credential(name) do
      {:ok, %{locale: locale}} -> blank(locale)
      _ -> nil
    end
  end

  defp credential_locale(:telegram, name) when is_binary(name) do
    case Agent.get_telegram_credential(name) do
      {:ok, %{locale: locale}} -> blank(locale)
      _ -> nil
    end
  end

  defp credential_locale(_, _), do: nil

  defp member_locale(member_id) when is_binary(member_id) do
    case Agent.get_member(member_id, load: [:household]) do
      {:ok, %{} = member} -> member_chain(member)
      _ -> nil
    end
  end

  defp member_locale(_), do: nil

  defp member_chain(member) do
    blank(Map.get(member, :locale)) || household_locale(Map.get(member, :household))
  end

  defp household_locale(%{locale: locale}), do: blank(locale)
  defp household_locale(_), do: nil

  defp platform_locale(meta) when is_map(meta), do: blank(meta["locale"])
  defp platform_locale(_), do: nil

  defp blank(s) when is_binary(s) and s != "", do: s
  defp blank(_), do: nil
end
