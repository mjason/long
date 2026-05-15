defmodule Mix.Tasks.Long.Wechat.Login do
  @shortdoc "Run the WeChat iLink bot QR-code login flow."
  @moduledoc """
  Fetch a QR code from `ilink/bot/get_bot_qrcode`, render it both to
  the terminal and as a PNG file on disk, then poll until the user
  scans + confirms in their WeChat client. On success, the bot token
  is persisted via `Long.Agent.Bots.Wechat.TokenStore` (default
  `~/.wxbot/token.json`).

  Usage:

      mix long.wechat.login
      mix long.wechat.login --png /tmp/wxqr.png

  The QR refreshes every few minutes. If you see `expired`, just rerun
  the task.
  """

  use Mix.Task

  alias Long.Agent.Bots.Wechat.{Client, Credential}

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [png: :string])
    png_path = Keyword.get(opts, :png, Path.join(System.tmp_dir!(), "long_wechat_qr.png"))

    Mix.Task.run("app.start")

    case Client.get_qrcode() do
      {:ok, %{qr_id: qr_id, qr_url: url}} when is_binary(url) and url != "" ->
        display_qr(url, png_path)
        poll(qr_id)

      {:ok, _} ->
        Mix.shell().error("iLink response missing qrcode_img_content; aborting.")
        exit({:shutdown, 1})

      {:error, e} ->
        Mix.shell().error("get_qrcode failed: #{inspect(e)}")
        exit({:shutdown, 1})
    end
  end

  defp display_qr(url, png_path) do
    matrix = EQRCode.encode(url)

    File.write!(png_path, EQRCode.png(matrix, width: 320))

    Mix.shell().info([
      :green,
      "请用微信扫描下方二维码登录 (iLink Bot)\n",
      :reset,
      "已保存 PNG 到: #{png_path}\n"
    ])

    EQRCode.render(matrix)
    Mix.shell().info("")
  end

  defp poll(qr_id, last_status \\ "") do
    Process.sleep(2_000)

    case Client.get_qrcode_status(qr_id) do
      {:ok, %{"status" => "confirmed"} = body} ->
        {:ok, _row} =
          Credential.save(%{
            bot_token: Map.get(body, "bot_token", ""),
            ilink_bot_id: Map.get(body, "ilink_bot_id", ""),
            updates_buf: ""
          })

        Mix.shell().info([
          :green,
          "登录成功! bot_id=#{Map.get(body, "ilink_bot_id", "")}\n",
          :reset,
          "Credential saved to agent_wechat_credentials (Ash).\n",
          "现在可以重启 Phoenix 服务，worker 会自动连接。"
        ])

      {:ok, %{"status" => "expired"}} ->
        Mix.shell().error("二维码已过期，请重新运行 `mix long.wechat.login`")
        exit({:shutdown, 1})

      {:ok, %{"status" => status}} when is_binary(status) ->
        if status != last_status, do: Mix.shell().info("状态: #{status}")
        poll(qr_id, status)

      {:ok, body} ->
        Mix.shell().error("unexpected status response: #{inspect(body)}")
        exit({:shutdown, 1})

      {:error, e} ->
        Mix.shell().error("status poll failed: #{inspect(e)}; 重试中...")
        poll(qr_id, last_status)
    end
  end
end
