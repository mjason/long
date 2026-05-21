defmodule LongWeb.PageHTML do
  @moduledoc """
  Pages rendered by `LongWeb.PageController` — currently just the
  homepage, which is a navigation hub linking to the chat, the manage
  admin, the channel (WeChat / Telegram) console, and the developer
  dashboards.
  """
  use LongWeb, :html

  embed_templates "page_html/*"

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true
  attr :accent, :string, default: "primary", values: ~w(primary info success warning)

  def nav_card(assigns) do
    ~H"""
    <.link navigate={@navigate} class="block group">
      <.card
        variant="bordered"
        color="natural"
        rounded="large"
        padding="medium"
        class="h-full bg-white border-zinc-200 transition group-hover:shadow-md group-hover:border-zinc-300"
      >
        <div class="flex items-center gap-3">
          <span class={["inline-flex items-center justify-center size-10 rounded-full shrink-0", accent_class(@accent)]}>
            <.icon name={@icon} class="size-5" />
          </span>
          <div class="flex-1 min-w-0">
            <div class="font-semibold text-zinc-900">{@title}</div>
            <p class="mt-1 text-sm text-zinc-500 leading-snug">{@desc}</p>
          </div>
          <.icon name="hero-arrow-right" class="size-4 text-zinc-300 group-hover:text-zinc-500 transition shrink-0" />
        </div>
      </.card>
    </.link>
    """
  end

  defp accent_class("primary"), do: "bg-teal-50 text-teal-700"
  defp accent_class("info"), do: "bg-blue-50 text-blue-700"
  defp accent_class("success"), do: "bg-emerald-50 text-emerald-700"
  defp accent_class("warning"), do: "bg-amber-50 text-amber-700"
  defp accent_class(_), do: "bg-zinc-100 text-zinc-700"

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true

  def dev_card(assigns) do
    ~H"""
    <a
      href={@href}
      class="block group rounded-lg border border-zinc-200 bg-white p-4 transition hover:shadow-sm hover:border-zinc-300"
    >
      <div class="flex items-center gap-2 text-zinc-700">
        <.icon name={@icon} class="size-4" />
        <span class="font-medium text-sm">{@title}</span>
      </div>
      <p class="mt-1 text-xs text-zinc-500">{@desc}</p>
    </a>
    """
  end
end
