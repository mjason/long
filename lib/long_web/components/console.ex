defmodule LongWeb.Components.Console do
  @moduledoc """
  Reusable building blocks for the admin console ("Quiet instrument" design system).

  These components reproduce the exact markup that was hand-repeated across the
  management LiveView, so the look is unchanged — they only remove duplication.
  """
  use Phoenix.Component
  use Gettext, backend: LongWeb.Gettext

  import LongWeb.CoreComponents, only: [icon: 1]
  alias PetalComponents.Badge
  alias PetalComponents.Button

  @doc """
  Section title block: an `h1` in the Quiet style, an optional one-line
  description below it, and an optional right-aligned actions slot.

  The outer `<div class="p-6 space-y-N">` page wrapper stays at the call site.
  """
  attr :title, :string, required: true
  slot :desc
  slot :actions

  def section_header(assigns) do
    ~H"""
    <div :if={@actions != []} class="flex items-center gap-3">
      <h1 class="text-xl font-semibold tracking-tight flex-1">{@title}</h1>
      <div class="flex flex-none items-center gap-2">{render_slot(@actions)}</div>
    </div>
    <h1 :if={@actions == []} class="text-xl font-semibold tracking-tight">{@title}</h1>
    <p :if={@desc != []} class="mt-1 max-w-2xl text-xs text-zinc-500">{render_slot(@desc)}</p>
    """
  end

  @doc """
  A labelled form field: `<label>` wrapper + label text + the control (slot) +
  optional hint. Controls stay raw inside the slot so raw `name="x[y]"` params
  are preserved exactly.
  """
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :class, :any, default: "block"
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <label class={@class}>
      <span :if={@label} class="text-xs font-medium text-zinc-600">{@label}</span>
      {render_slot(@inner_block)}
      <span :if={@hint} class="text-[11px] text-zinc-500">{@hint}</span>
    </label>
    """
  end

  @doc """
  A styled form control (input / select / textarea) carrying the Quiet focus
  ring. `size` is `md` (px-3 py-2) or `sm` (px-2 py-1.5); `full` toggles
  `w-full`; `mono` adds `font-mono`. Select options / textarea overrides via the
  inner block / `value`.
  """
  attr :type, :string, default: "text", values: ~w(text password number email url select textarea)
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :size, :string, default: "md", values: ~w(md sm)
  attr :full, :boolean, default: true
  attr :mono, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(required readonly placeholder min max step pattern rows disabled autofocus)

  slot :inner_block

  def control(assigns) do
    ~H"""
    <input
      :if={@type in ~w(text password number email url)}
      type={@type}
      name={@name}
      value={@value}
      class={control_class(assigns)}
      {@rest}
    />
    <select :if={@type == "select"} name={@name} class={control_class(assigns)} {@rest}>{render_slot(@inner_block)}</select>
    <textarea :if={@type == "textarea"} name={@name} class={control_class(assigns)} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
    """
  end

  defp control_class(assigns) do
    [
      "mt-1",
      assigns.full && "w-full",
      "rounded-lg border border-zinc-300 transition focus:border-primary-400 focus:ring-2 focus:ring-primary-100 focus:outline-none",
      (assigns.size == "sm" && "px-2 py-1.5 text-sm") || "px-3 py-2 text-sm",
      assigns.mono && "font-mono",
      assigns.class
    ]
  end

  @doc "On/off status pill: green when `on`, gray otherwise, with two-state labels."
  attr :on, :boolean, required: true
  attr :on_label, :string, required: true
  attr :off_label, :string, required: true

  def enabled_badge(assigns) do
    ~H"""
    <Badge.badge color={if @on, do: "success", else: "gray"} size="xs">
      {if @on, do: @on_label, else: @off_label}
    </Badge.badge>
    """
  end

  @doc """
  Ownership/scope chip. `:personal` renders a person icon + the owner's name in
  a calm neutral pill; anything else renders a globe + "Global" in emerald.
  """
  attr :scope, :atom, required: true
  attr :owner, :string, default: nil

  def scope_badge(assigns) do
    ~H"""
    <span
      :if={@scope == :personal}
      class="inline-flex items-center gap-1 rounded-full bg-zinc-100 py-0.5 pl-1.5 pr-2 text-xs font-medium text-zinc-700"
      title={gettext("Personal — only this member's chats see it")}
    >
      <.icon name="hero-user" class="size-3 text-zinc-400" />
      {@owner || gettext("unknown")}
    </span>
    <span
      :if={@scope != :personal}
      class="inline-flex items-center gap-1 rounded-full bg-emerald-50 py-0.5 pl-1.5 pr-2 text-xs font-medium text-emerald-700"
      title={gettext("Global — available to everyone")}
    >
      <.icon name="hero-globe-alt" class="size-3 text-emerald-500" />
      {gettext("Global")}
    </span>
    """
  end

  @doc """
  The console table scaffold: Quiet card shell + header + hover rows + empty
  state. Cell bodies live in `:col` slots (each receives the row); an optional
  `:action` slot renders the right-aligned actions column.
  """
  attr :rows, :list, required: true
  attr :empty, :string, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :align, :string
    attr :class, :any
  end

  slot :action

  def data_table(assigns) do
    ~H"""
    <div class="rounded-xl border border-zinc-200/80 bg-white shadow-sm overflow-hidden">
      <table class="w-full text-sm">
        <thead class="text-[11px] uppercase tracking-wider text-zinc-400 bg-zinc-50/80">
          <tr>
            <th
              :for={col <- @col}
              class={[(col[:align] == "right" && "text-right") || "text-left", "px-4 py-2.5", col[:class]]}
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class="text-right px-4 py-2.5">{gettext("Actions")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            class="border-t border-zinc-100 transition-colors hover:bg-zinc-50/70"
          >
            <td :for={col <- @col} class={["px-4 py-2", col[:align] == "right" && "text-right", col[:class]]}>
              {render_slot(col, row)}
            </td>
            <td :if={@action != []} class="px-4 py-2">
              <div class="flex justify-end gap-1">{render_slot(@action, row)}</div>
            </td>
          </tr>
          <tr :if={@rows == []}>
            <td
              colspan={length(@col) + ((@action != [] && 1) || 0)}
              class="px-4 py-8 text-center text-zinc-400 text-sm"
            >
              {@empty}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "Row edit icon-button. Pass the phx-click / phx-value-* via attributes."
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-alias phx-value-name)

  def row_action_edit(assigns) do
    ~H"""
    <Button.icon_button {@rest} color="gray" size="xs" title={gettext("Edit")}>
      <.icon name="hero-pencil-square" class="size-4" />
    </Button.icon_button>
    """
  end

  @doc "Row delete icon-button with a confirmation prompt."
  attr :confirm, :string, default: nil
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-alias phx-value-name)

  def row_action_delete(assigns) do
    ~H"""
    <Button.icon_button {@rest} color="danger" size="xs" data-confirm={@confirm} title={gettext("Delete")}>
      <.icon name="hero-trash" class="size-4" />
    </Button.icon_button>
    """
  end

  @doc "Row enable/disable toggle icon-button (pause when on, play when off)."
  attr :on, :boolean, required: true
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-alias)

  def row_action_toggle(assigns) do
    ~H"""
    <Button.icon_button
      {@rest}
      color="gray"
      size="xs"
      title={if @on, do: gettext("Disable"), else: gettext("Enable")}
    >
      <.icon name={if @on, do: "hero-pause", else: "hero-play"} class="size-4" />
    </Button.icon_button>
    """
  end

  @doc """
  EN | 中文 locale links. `variant` "bar" is the icon + pill style used in the
  console sidebar; "plain" is the separator style used on the login page.
  """
  attr :locale, :string, required: true
  attr :variant, :string, default: "bar", values: ~w(bar plain)

  def locale_switcher(assigns) do
    ~H"""
    <div :if={@variant == "bar"} class="flex items-center gap-1 text-xs">
      <.icon name="hero-language" class="size-4 text-zinc-400" />
      <.link
        href="/locale/en"
        class={["rounded px-1.5 py-0.5", (@locale == "en" && "bg-zinc-100 font-semibold text-zinc-900") || "text-zinc-400 hover:text-zinc-700"]}
      >
        EN
      </.link>
      <.link
        href="/locale/zh"
        class={["rounded px-1.5 py-0.5", (@locale == "zh" && "bg-zinc-100 font-semibold text-zinc-900") || "text-zinc-400 hover:text-zinc-700"]}
      >
        中文
      </.link>
    </div>
    <span :if={@variant == "plain"} class="inline-flex items-center gap-2 text-xs">
      <.link
        href="/locale/en"
        class={["px-1.5", (@locale == "en" && "font-semibold text-zinc-900") || "text-zinc-400 hover:text-zinc-600"]}
      >
        EN
      </.link>
      <span class="text-zinc-300">|</span>
      <.link
        href="/locale/zh"
        class={["px-1.5", (@locale == "zh" && "font-semibold text-zinc-900") || "text-zinc-400 hover:text-zinc-600"]}
      >
        中文
      </.link>
    </span>
    """
  end

  @doc "Plain (non-table) Quiet card container. Opt into shadow via `class`."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <div class={["rounded-xl border border-zinc-200/80 bg-white", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
