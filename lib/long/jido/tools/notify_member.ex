defmodule Long.Jido.Tools.NotifyMember do
  @moduledoc """
  Proactively message another member of the caller's group — the
  "notify the others …" capability. The caller is resolved from the current
  session's bound `BotUser` → `Member`; the target is addressed by display
  name (or implied when there's only one other member), scoped to the same
  group. The user-facing strings stay Chinese to match the rest of the
  bot-chat surface (see `Long.Agent.Bots`).

  The message is pushed to *every* chat account the target has bound
  (WeChat + Telegram), via `Long.Agent.Bots.Outbound`. Delivery is
  fire-and-forget; the tool returns how many channels accepted it.

  Only works from a bound chat session — a web chat or an unbound account
  has no caller member, so the tool returns an error asking the user to
  `/bind` first.
  """

  use Jido.Action,
    name: "notify_member",
    description: """
    Send a message to another member of your group — use this
    whenever the user asks to tell / pass a message to / 通知 / 和某人说
    someone in the group.

    Addressing the recipient (`target`):
      - With exactly ONE other member in the group, the target is
        ignored — any value (a display name, a pronoun in any language,
        or an empty string) reaches that member. So for "tell him OK" /
        "和他说一声好的", just call this with the message; do NOT ask who.
      - With several other members, pass the member's display name
        (partial match works). On a miss the error lists who's
        available — retry with one of those names.

    The message is delivered to every chat account (WeChat / Telegram)
    the target has bound. Only usable from a chat bound to a group
    member; if it isn't, ask the user to `/bind <code>` first.
    """,
    category: "messaging",
    tags: ["notify", "group"],
    vsn: "2.0.0",
    schema:
      Zoi.object(%{
        target:
          Zoi.string(
            description:
              "Who to notify. Ignored when there's only one other member (leave empty for 'the other person'). Otherwise the member's display name (partial match ok)."
          )
          |> Zoi.optional(),
        message: Zoi.string(description: "The message text to deliver to that member.")
      })

  alias Long.Agent
  alias Long.Agent.Bots.Outbound
  alias Long.Copy
  alias Long.Jido.Tools.Format

  @impl true
  def run(params, ctx) do
    # Delivery is injectable so the resolution + delivery path is fully
    # testable without a live bot worker (ctx[:deliver]); production uses
    # `Long.Agent.Bots.Outbound.push/2`.
    push_fn = ctx[:deliver] || (&Outbound.push/2)

    with {:ok, session_id} <- Format.require_session_id(ctx),
         locale = caller_locale(session_id),
         {:ok, me} <- caller_member(session_id, locale),
         {:ok, target} <- resolve_target(me, params[:target], locale),
         {:ok, recipients} <- recipients(target, locale) do
      results = deliver(recipients, me, params[:message], locale, push_fn)
      {:ok, build_result(target, length(recipients), results, locale)}
    else
      {:error, msg} -> {:ok, %{status: "error", msg: msg}}
    end
  end

  defp build_result(target, channels, results, locale) do
    delivered = Enum.count(results, &match?({_bu, :ok}, &1))

    base = %{
      status: if(delivered > 0, do: "sent", else: "error"),
      to: target.display_name,
      delivered: delivered,
      channels: channels
    }

    if delivered > 0 do
      Map.put(base, :msg, nil)
    else
      reason =
        results
        |> Enum.map(fn {bu, r} -> "#{bu.platform}: #{reason_str(r)}" end)
        |> Enum.join("; ")

      Map.put(
        base,
        :msg,
        Copy.t("notify.delivered_none", %{member: target.display_name, reason: reason}, locale)
      )
    end
  end

  defp reason_str(:ok), do: "ok"
  defp reason_str({:error, r}), do: Long.Util.Error.humanize(r)
  defp reason_str(other), do: Long.Util.Error.humanize(other)

  # The caller's display locale, resolved via the channel → member →
  # group → platform → default chain (see `Long.Agent.Locale`).
  defp caller_locale(session_id) do
    case Agent.get_bot_user_for_session(session_id) do
      {:ok, %{} = bot_user} -> Long.Agent.Locale.for_bot_user(bot_user)
      _ -> Copy.default_locale()
    end
  end

  # The group member behind the current session, or an error if the
  # chat isn't bound to one.
  defp caller_member(session_id, locale) do
    case Agent.member_for_session(session_id) do
      nil -> {:error, Copy.t("notify.caller_unbound", %{}, locale)}
      member -> {:ok, member}
    end
  end

  # Resolve `target` to one other member of the caller's group.
  #
  # The language-agnostic rule: in a group with exactly ONE other
  # member, *any* target reaches them — a pronoun in any language ("他",
  # "him", "对方", …), a name, or an empty string. No keyword list to
  # maintain; the LLM does the natural-language understanding. Only when
  # several other members exist do we need a specific match (relation or
  # display name); a miss returns the roster so the caller can retry.
  defp resolve_target(me, target, locale) do
    target = if is_binary(target), do: String.trim(target), else: ""

    others =
      me.group_id
      |> Agent.list_members_for_group!(load: [:bot_users])
      |> Enum.reject(&(&1.id == me.id))

    pick(others, target, locale)
  end

  defp pick([], _target, locale),
    do: {:error, Copy.t("notify.no_others", %{}, locale)}

  defp pick([only], _target, _locale), do: {:ok, only}

  defp pick(others, "", locale),
    do: {:error, Copy.t("notify.which_member", %{options: member_list(others)}, locale)}

  defp pick(others, target, locale) do
    case name_matches(others, target) do
      [one] -> {:ok, one}
      [] -> {:error, Copy.t("notify.no_match", %{target: target, options: member_list(others)}, locale)}
      many -> {:error, Copy.t("notify.ambiguous", %{options: member_list(many)}, locale)}
    end
  end

  defp name_matches(others, target) do
    t = String.downcase(String.trim(target))

    Enum.filter(others, fn m ->
      name = String.downcase(m.display_name || "")
      t != "" and name != "" and (String.contains?(name, t) or String.contains?(t, name))
    end)
  end

  defp member_list(members),
    do: Enum.map_join(members, ", ", & &1.display_name)

  # `bot_users` is already loaded on the member by `resolve_target`.
  defp recipients(%{bot_users: [_ | _] = bus}, _locale), do: {:ok, bus}

  defp recipients(member, locale),
    do: {:error, Copy.t("notify.no_channel", %{member: member.display_name}, locale)}

  # Returns `[{bot_user, :ok | {:error, reason}}]` — one entry per channel,
  # so the caller can count successes and report why the rest failed.
  defp deliver(recipients, me, message, locale, push_fn) do
    body = %{text: compose(me, message, locale), tool_calls: [], attachments: [], ask: nil, error: nil}
    Enum.map(recipients, fn bu -> {bu, safe_push(push_fn, bu, body)} end)
  end

  # A dead channel (worker down, network/credential failure, or a
  # `GenServer.call` timeout that *exits*) must not take down the whole
  # tool — one member may have several bound accounts. Capture any
  # raise/throw/exit as an error reason and keep going.
  defp safe_push(push_fn, bot_user, body) do
    case push_fn.(bot_user, body) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp compose(me, message, locale),
    do: Copy.t("notify.envelope", %{sender: me.display_name, message: message}, locale)
end
