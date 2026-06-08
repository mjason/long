defmodule LongWeb.WechatLive.Login do
  @moduledoc """
  Browser-based replacement for `mix long.wechat.login`. Fetches an
  iLink bot QR, renders it inline as SVG, polls the status endpoint, and
  saves the resulting credential under the account `name` it was opened
  for (default `"default"`). On confirm it reconciles the workers so the
  new account starts polling without a server restart.

  Embedded into `/manage` Channels as a nested LiveView; `name` is passed
  through the session so one page can connect several accounts.
  """

  use LongWeb, :live_view

  alias Long.Agent.Bots.Wechat.{Client, Credential, Manager}

  @poll_interval_ms 2_000

  @impl true
  def mount(_params, session, socket) do
    name = session["name"] || "default"

    {:ok,
     socket
     |> assign(:page_title, "WeChat login")
     |> assign(:name, name)
     |> assign(:embedded?, session["embedded"] == true)
     |> assign_credential()
     |> assign(:flow, :idle)
     |> assign(:qr_id, nil)
     |> assign(:qr_svg, nil)
     |> assign(:status, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("start_login", _params, socket) do
    case Client.get_qrcode() do
      {:ok, %{qr_id: qr_id, qr_url: url}} when is_binary(url) and url != "" ->
        Process.send_after(self(), :poll_qr, @poll_interval_ms)

        {:noreply,
         socket
         |> assign(:flow, :scanning)
         |> assign(:qr_id, qr_id)
         |> assign(:qr_svg, qr_svg(url))
         |> assign(:status, "new")
         |> assign(:error, nil)}

      {:ok, _} ->
        {:noreply, assign(socket, :error, "iLink response had no qrcode image")}

      {:error, e} ->
        {:noreply, assign(socket, :error, "Failed to fetch QR code: #{inspect(e)}")}
    end
  end

  def handle_event("retry", _params, socket) do
    handle_event("start_login", %{}, reset(socket))
  end

  def handle_event("logout", _params, socket) do
    :ok = Credential.delete(socket.assigns.name)
    {:noreply, socket |> reset() |> assign_credential() |> put_flash(:info, "Credential removed")}
  end

  @impl true
  def handle_info(:poll_qr, %{assigns: %{qr_id: nil}} = socket), do: {:noreply, socket}

  def handle_info(:poll_qr, socket) do
    case Client.get_qrcode_status(socket.assigns.qr_id) do
      {:ok, %{"status" => "confirmed"} = body} ->
        save_and_reload(socket.assigns.name, body)

        {:noreply,
         socket
         |> assign(:flow, :done)
         |> assign(:status, "confirmed")
         |> assign_credential()
         |> put_flash(:info, "Logged in! bot_id=#{Map.get(body, "ilink_bot_id", "")}")}

      {:ok, %{"status" => "expired"}} ->
        {:noreply,
         socket
         |> assign(:flow, :idle)
         |> assign(:status, "expired")
         |> assign(:qr_svg, nil)
         |> assign(:qr_id, nil)
         |> assign(:error, "QR code expired — generate a new one")}

      {:ok, %{"status" => status}} ->
        Process.send_after(self(), :poll_qr, @poll_interval_ms)
        {:noreply, assign(socket, :status, status || "new")}

      {:error, e} ->
        Process.send_after(self(), :poll_qr, @poll_interval_ms)
        {:noreply, assign(socket, :error, "Status poll failed: #{inspect(e)}; retrying…")}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ── helpers ──────────────────────────────────────────────────────────

  defp reset(socket) do
    socket
    |> assign(:flow, :idle)
    |> assign(:qr_id, nil)
    |> assign(:qr_svg, nil)
    |> assign(:status, nil)
    |> assign(:error, nil)
  end

  defp assign_credential(socket) do
    assign(socket, :credential, Credential.load(socket.assigns.name))
  end

  defp save_and_reload(name, body) do
    {:ok, _} =
      Credential.save(
        %{
          bot_token: Map.get(body, "bot_token", ""),
          ilink_bot_id: Map.get(body, "ilink_bot_id", ""),
          updates_buf: ""
        },
        name
      )

    Manager.reconcile()
    Credential.broadcast_connected()
  end

  defp qr_svg(url) do
    url
    |> EQRCode.encode()
    |> EQRCode.svg(width: 256, color: "#000", background_color: "#fff")
  end

  defp status_label("new"), do: "Waiting for scan…"
  defp status_label("scanned"), do: "Scanned — confirm on your phone…"
  defp status_label("confirmed"), do: "Confirmed!"
  defp status_label("expired"), do: "QR code expired"
  defp status_label(other), do: other

  # ── view ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={if @embedded?, do: "", else: "mx-auto max-w-2xl px-4 py-10"}>
      <header :if={!@embedded?} class="mb-8">
        <h1 class="text-2xl font-semibold">WeChat iLink bot login</h1>
        <p class="mt-2 text-sm text-zinc-500">
          Scan to connect a WeChat account; messages sent to it flow into the agent.
        </p>
      </header>

      <p class="text-xs text-zinc-400 mb-3">
        Account: <span class="font-mono text-zinc-600">{@name}</span>
      </p>

      <%= if @credential do %>
        <section class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-zinc-500">Connected</p>
              <p class="font-mono text-sm mt-1">
                bot_id: <span class="text-zinc-900">{@credential.ilink_bot_id}</span>
              </p>
              <p class="text-xs text-zinc-400 mt-1">Worker is long-polling iLink</p>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="start_login"
                class="rounded-md bg-zinc-100 px-3 py-1.5 text-sm font-medium hover:bg-zinc-200"
              >
                Re-login
              </button>
              <button
                phx-click="logout"
                data-confirm="Remove this credential? You'll need to scan again."
                class="rounded-md bg-red-50 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-100"
              >
                Log out
              </button>
            </div>
          </div>
        </section>
      <% end %>

      <section class="mt-6">
        <%= case @flow do %>
          <% :idle -> %>
            <%= if is_nil(@credential) do %>
              <div class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm text-center">
                <p class="text-sm text-zinc-600 mb-4">
                  No WeChat account connected yet. Click below to generate a QR code.
                </p>
                <button
                  phx-click="start_login"
                  class="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
                >
                  Start login
                </button>
              </div>
            <% end %>
          <% :scanning -> %>
            <div class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm text-center">
              <div class="inline-block rounded-md bg-white p-3 shadow-inner">
                {Phoenix.HTML.raw(@qr_svg)}
              </div>
              <p class="mt-4 text-sm font-medium">{status_label(@status)}</p>
              <p class="mt-1 text-xs text-zinc-500">
                Open the WeChat account you want to connect → Scan → confirm on your phone
              </p>
              <p class="mt-3 text-xs text-zinc-400">
                The QR expires in ~5 minutes. After that, click
                <button phx-click="retry" class="underline">regenerate</button>.
              </p>
            </div>
          <% :done -> %>
            <div class="rounded-lg border border-emerald-200 bg-emerald-50 p-6 shadow-sm text-center">
              <p class="text-emerald-900 font-medium">Logged in!</p>
              <p class="mt-2 text-sm text-emerald-700">
                Credential saved and the worker started — this account is live.
              </p>
            </div>
        <% end %>

        <%= if @error do %>
          <div class="mt-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{@error}</div>
        <% end %>
      </section>
    </div>
    """
  end
end
