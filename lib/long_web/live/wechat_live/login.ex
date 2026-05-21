defmodule LongWeb.WechatLive.Login do
  @moduledoc """
  Browser-based replacement for `mix long.wechat.login`. Fetches an
  iLink bot QR, renders it inline as SVG, polls the status endpoint,
  saves the resulting credential to the database, and (if the worker
  is already running) hot-reloads it so chat resumes without a server
  restart.
  """

  use LongWeb, :live_view

  alias Long.Agent.Bots.Wechat.{Client, Credential, Worker}

  @poll_interval_ms 2_000

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "WeChat 登录")
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
        {:noreply, assign(socket, :error, "iLink 响应里没有 qrcode_img_content")}

      {:error, e} ->
        {:noreply, assign(socket, :error, "拉取二维码失败: #{inspect(e)}")}
    end
  end

  def handle_event("retry", _params, socket) do
    handle_event("start_login", %{}, reset(socket))
  end

  def handle_event("logout", _params, socket) do
    :ok = Credential.delete()
    {:noreply, socket |> reset() |> assign_credential() |> put_flash(:info, "凭证已删除")}
  end

  @impl true
  def handle_info(:poll_qr, %{assigns: %{qr_id: nil}} = socket), do: {:noreply, socket}

  def handle_info(:poll_qr, socket) do
    case Client.get_qrcode_status(socket.assigns.qr_id) do
      {:ok, %{"status" => "confirmed"} = body} ->
        save_and_reload(body)

        {:noreply,
         socket
         |> assign(:flow, :done)
         |> assign(:status, "confirmed")
         |> assign_credential()
         |> put_flash(:info, "登录成功！bot_id=#{Map.get(body, "ilink_bot_id", "")}")}

      {:ok, %{"status" => "expired"}} ->
        {:noreply,
         socket
         |> assign(:flow, :idle)
         |> assign(:status, "expired")
         |> assign(:qr_svg, nil)
         |> assign(:qr_id, nil)
         |> assign(:error, "二维码已过期，请重新生成")}

      {:ok, %{"status" => status}} ->
        Process.send_after(self(), :poll_qr, @poll_interval_ms)
        {:noreply, assign(socket, :status, status || "new")}

      {:error, e} ->
        Process.send_after(self(), :poll_qr, @poll_interval_ms)
        {:noreply, assign(socket, :error, "状态轮询失败: #{inspect(e)}; 重试中…")}
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
    assign(socket, :credential, Credential.load())
  end

  defp save_and_reload(body) do
    {:ok, _} =
      Credential.save(%{
        bot_token: Map.get(body, "bot_token", ""),
        ilink_bot_id: Map.get(body, "ilink_bot_id", ""),
        updates_buf: ""
      })

    Worker.reload()
    Credential.broadcast_connected()
  end

  defp qr_svg(url) do
    url
    |> EQRCode.encode()
    |> EQRCode.svg(width: 256, color: "#000", background_color: "#fff")
  end

  defp status_label("new"), do: "等待扫码…"
  defp status_label("scanned"), do: "已扫码，等待手机确认…"
  defp status_label("confirmed"), do: "已确认！"
  defp status_label("expired"), do: "二维码已过期"
  defp status_label(other), do: other

  # ── view ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={if @embedded?, do: "", else: "mx-auto max-w-2xl px-4 py-10"}>
      <header :if={!@embedded?} class="mb-8">
        <h1 class="text-2xl font-semibold">微信 iLink Bot 登录</h1>
        <p class="mt-2 text-sm text-zinc-500">
          扫码绑定一个微信账号，之后所有发到这个号的私信都会进入 agent。
        </p>
      </header>

      <%= if @credential do %>
        <section class="rounded-lg border border-zinc-200 bg-white p-5 shadow-sm">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-zinc-500">当前已登录</p>
              <p class="font-mono text-sm mt-1">
                bot_id: <span class="text-zinc-900">{@credential.ilink_bot_id}</span>
              </p>
              <p class="text-xs text-zinc-400 mt-1">Worker 正在 long-poll iLink</p>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="start_login"
                class="rounded-md bg-zinc-100 px-3 py-1.5 text-sm font-medium hover:bg-zinc-200"
              >
                重新登录
              </button>
              <button
                phx-click="logout"
                data-confirm="确定要删除凭证吗？删除后需要重新扫码。"
                class="rounded-md bg-red-50 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-100"
              >
                退出登录
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
                  还未登录任何微信账号。点下面按钮生成扫码二维码。
                </p>
                <button
                  phx-click="start_login"
                  class="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
                >
                  开始登录
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
                用想绑定的微信号 → 扫一扫上面的二维码 → 在手机上确认
              </p>
              <p class="mt-3 text-xs text-zinc-400">
                二维码大约 5 分钟过期。过期后点
                <button phx-click="retry" class="underline">重新生成</button>。
              </p>
            </div>
          <% :done -> %>
            <div class="rounded-lg border border-emerald-200 bg-emerald-50 p-6 shadow-sm text-center">
              <p class="text-emerald-900 font-medium">登录成功！</p>
              <p class="mt-2 text-sm text-emerald-700">
                凭证已保存。Worker 已自动重载，可以直接给微信发消息了。
              </p>
              <p class="mt-4">
                <.link navigate={~p"/chat"} class="text-sm font-medium text-emerald-900 underline">
                  去 chat 页面 →
                </.link>
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
