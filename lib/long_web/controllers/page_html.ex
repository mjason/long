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
    <.link navigate={@navigate} class="group block">
      <div class="h-full rounded-2xl border border-zinc-200/80 bg-white p-5 shadow-sm transition-all duration-200 group-hover:-translate-y-0.5 group-hover:border-zinc-300 group-hover:shadow-md">
        <div class="flex items-start gap-3.5">
          <span class={["inline-flex size-10 shrink-0 items-center justify-center rounded-xl ring-1 ring-inset", accent_class(@accent)]}>
            <.icon name={@icon} class="size-5" />
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5">
              <span class="font-semibold text-zinc-900">{@title}</span>
              <.icon
                name="hero-arrow-up-right"
                class="size-3.5 text-zinc-300 transition group-hover:translate-x-0.5 group-hover:text-zinc-500"
              />
            </div>
            <p class="mt-1 text-sm leading-snug text-zinc-500">{@desc}</p>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  defp accent_class("primary"), do: "bg-primary-50 text-primary-600 ring-primary-100"
  defp accent_class("info"), do: "bg-sky-50 text-sky-600 ring-sky-100"
  defp accent_class("success"), do: "bg-emerald-50 text-emerald-600 ring-emerald-100"
  defp accent_class("warning"), do: "bg-amber-50 text-amber-600 ring-amber-100"
  defp accent_class(_), do: "bg-zinc-100 text-zinc-600 ring-zinc-200"

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true

  def dev_card(assigns) do
    ~H"""
    <a
      href={@href}
      class="group block rounded-xl border border-zinc-200/80 bg-white px-4 py-3.5 transition-all hover:border-zinc-300 hover:shadow-sm"
    >
      <div class="flex items-center gap-2 text-zinc-700">
        <.icon name={@icon} class="size-4 text-zinc-400 transition group-hover:text-zinc-600" />
        <span class="text-sm font-medium">{@title}</span>
      </div>
      <p class="mt-1 text-xs text-zinc-400">{@desc}</p>
    </a>
    """
  end
end
