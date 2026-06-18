defmodule Long.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Long.ErrorTrackerLogger.install()

    children = [
      LongWeb.Telemetry,
      Long.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:long, :ecto_repos), skip: skip_migrations?()},
      # Liveness registry — started before Oban so the scheduler tick can beat
      # into it and the watchdog / `/healthz` can read freshness.
      Long.Heartbeat,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:long, :ash_domains),
         Application.fetch_env!(:long, Oban)
       )},
      # Detect + recover a silently-hung scheduler (an alive-but-idle Oban Cron
      # GenServer that OTP supervision can't see). Sits right after Oban but is
      # an independent process so it doesn't share fate with the cron timer.
      Long.Agent.SchedulerWatchdog,
      {Task.Supervisor, name: Long.Agent.TaskSup},
      {Registry, keys: :unique, name: Long.Agent.Server.Registry},
      Long.Agent.Server.Supervisor,
      # Owns Activity's ETS tables so they survive an Activity crash; must start
      # before Activity (which adopts + re-monitors the survivors on restart).
      Long.Agent.Activity.Tables,
      Long.Agent.Activity,
      Long.Agent.Skill.Store,
      Long.Agent.Browser.Cli.Limiter,
      Long.Agent.Browser.Engine,
      Long.Agent.Deno.Engine,
      # Telegram workers — one per enabled bot credential, keyed by name.
      {Registry, keys: :unique, name: Long.Agent.Bots.Telegram.Registry},
      Long.Agent.Bots.Telegram.WorkerSupervisor,
      Long.Agent.Bots.Telegram.Manager,
      # Start to serve requests, typically the last entry
      {DNSCluster, query: Application.get_env(:long, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Long.PubSub},
      # WeChat workers (one per hosted account) subscribe to PubSub on
      # boot via the Manager, so they must start after Long.PubSub.
      {Registry, keys: :unique, name: Long.Agent.Bots.Wechat.Registry},
      Long.Agent.Bots.Wechat.WorkerSupervisor,
      Long.Agent.Bots.Wechat.Manager,
      LongWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options.
    #
    # max_restarts/max_seconds are raised above the OTP default (3/5): under
    # :one_for_one, a child that exceeds the *supervisor's* intensity takes down
    # ALL siblings — including LongWeb.Endpoint — so a transient crash-loop in a
    # background child (e.g. a Skill.Store FS hiccup) would blank the web. 10/60
    # keeps a genuinely unrecoverable loop bounded while riding out a blip.
    # Mirrors the 5/30 already set on Long.Agent.Server.Supervisor.
    opts = [strategy: :one_for_one, name: Long.Supervisor, max_restarts: 10, max_seconds: 60]
    result = Supervisor.start_link(children, opts)
    log_oban_peer()
    result
  end

  # Canary: this app runs Oban's Lite engine, which defaults to the Isolated
  # peer (leader? is hardcoded true — no election, nothing to "lose"). If a
  # future change ever flips this to the Database/Global peer, a whole class of
  # leadership-loss failure modes becomes live again — this one line is how
  # you'd notice at boot.
  defp log_oban_peer do
    require Logger
    Logger.info("Oban peer: #{inspect(Oban.config().peer)}")
  rescue
    _ -> :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LongWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
