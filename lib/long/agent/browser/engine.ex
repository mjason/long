defmodule Long.Agent.Browser.Engine do
  @moduledoc """
  Ensures the Obscura binary is on disk so `web_scan` / `web_execute_js` /
  `Long.Agent.Search.Cdp` have something to shell out to. Boots without
  blocking the supervisor: if the binary is missing it kicks off a
  background download (~50 MB, one-time) via `Browser.Installer`.

  `status/0` reports the resolved state:

    * `{:ok, :ready, path}`
    * `{:ok, :installing}`
    * `{:error, :failed}`
  """

  use GenServer
  require Logger

  alias Long.Agent.Browser.Installer

  @name __MODULE__

  defstruct [:reply, :task_ref]

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ @name), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{reply: {:ok, :installing}}, {:continue, {:boot, opts}}}
  end

  @impl true
  def handle_continue({:boot, opts}, state) do
    cfg = config()
    bin_name = Keyword.get(cfg, :obscura_bin, "obscura")
    bin_dir = Keyword.get(cfg, :obscura_bin_dir, default_bin_dir())
    auto_install? = Keyword.get(opts, :auto_install, Keyword.get(cfg, :auto_install, true))

    case Installer.locate(bin_name, bin_dir) do
      path when is_binary(path) ->
        Logger.info("Browser.Engine: Obscura already installed at #{path}")
        {:noreply, %{state | reply: {:ok, :ready, path}}}

      nil when auto_install? ->
        Logger.info(
          "Browser.Engine: Obscura not installed; starting auto-install in background " <>
            "(~50 MB, one-time)."
        )

        installer = Keyword.get(opts, :installer, &Installer.ensure_installed/1)
        task = Task.async(fn -> installer.(bin_dir: bin_dir, bin_name: bin_name) end)
        {:noreply, %{state | reply: {:ok, :installing}, task_ref: task.ref}}

      nil ->
        Logger.warning(
          "Browser.Engine: Obscura not installed and auto_install: false. " <>
            "web_scan/web_execute_js will return errors until you install manually."
        )

        {:noreply, %{state | reply: {:error, :failed}}}
    end
  end

  # `Task.async` already monitors and sends both the result message and
  # the `:DOWN`. We accept the result and demonitor; the subsequent
  # `:DOWN` is then a noop.
  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task_ref: nil, reply: install_reply(result)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.warning("Browser.Engine: installer task exited: #{inspect(reason)}")
    {:noreply, %{state | task_ref: nil, reply: {:error, :failed}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.reply, state}

  defp install_reply({:ok, path}) when is_binary(path) do
    Logger.info("Browser.Engine: Obscura install complete at #{path}")
    {:ok, :ready, path}
  end

  defp install_reply({:error, reason}) do
    Logger.warning(
      "Browser.Engine: Obscura auto-install failed (#{inspect(reason)}). " <>
        "Run `mix long.obscura.install` to retry."
    )

    {:error, :failed}
  end

  defp config, do: Application.get_env(:long, Long.Agent.Browser, [])

  defp default_bin_dir do
    Application.app_dir(:long, "priv/agent/bin")
  rescue
    _ -> Path.expand("priv/agent/bin", File.cwd!())
  end
end
