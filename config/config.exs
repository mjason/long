# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Enable the bundled IANA tzdata so DateTime.shift_zone/2 works — the agent
# converts the user's local times ("remind me at 8:30am") into the UTC stored
# on scheduled tasks (see Long.Agent.Schedule / Long.Agent.Server).
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Timezone the agent assumes for the user when converting local times to UTC.
config :long, :user_timezone, "Asia/Shanghai"

# Silent reflection (the autonomous "tidy your own memory" loop). `enabled`
# is the instance-wide kill switch checked in Workers.RunScheduledTask;
# `hour` is the off-peak UTC hour seeded reflection tasks fire at (the
# minute is jittered per-session to spread load across a fleet).
config :long, Long.Agent.Reflection, enabled: true, hour: 18

config :ash_oban, pro?: false

config :long, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10, agent: 5],
  repo: Long.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Long.Agent.Workers.SchedulerTick},
       {"0 */12 * * *", Long.Agent.Workers.L4Archive}
     ]}
  ]

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :long,
  ecto_repos: [Long.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Long.Agent]

config :long, Long.Agent,
  memory_root: Path.expand("../priv/agent/memory", __DIR__),
  skill_root: Path.expand("../priv/agent/skills", __DIR__),
  temp_root: Path.expand("../priv/agent/workspace", __DIR__),
  workspace_root: Path.expand("../priv/agent/workspace", __DIR__)

# Dashboard mounted at `/errors` in dev (see router.ex's dev_routes scope).
config :error_tracker,
  repo: Long.Repo,
  otp_app: :long,
  enabled: true

# ReqLLM's default Finch pool is 8 connections total (size: 1 × count: 8),
# which gets exhausted by concurrent agent loops (each holds a streaming
# connection for the duration of an LLM turn). Bump generously — pools
# are cheap (one TCP socket each, idle pools cost ~nothing), and we'd
# rather waste a few file descriptors than drop replies under bursty
# multi-user load (bot fan-out + scheduled-task fires + parallel tool
# dispatches inside each loop).
config :req_llm,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 128]
    }
  ]

# Headless browser for `web_scan` / `web_execute_js` / `Search.Cdp`.
# Backed by Obscura's CLI mode (`obscura fetch URL …`) — no CDP server
# is launched. The Engine just ensures the binary is on disk.
#
# Set `auto_install: false` if you'd rather install Obscura yourself
# (then drop the binary in `priv/agent/bin/` or anywhere on PATH).
config :long, Long.Agent.Browser,
  obscura_bin: "obscura",
  auto_install: true

# Deno runtime for `code_run` (the default code-exec engine). The Engine
# ensures the binary is on disk at boot, auto-downloading a managed copy
# (~40 MB, one-time) into `priv/agent/bin/` so the deployment stays
# self-contained. Set `auto_install: false` to install Deno yourself.
config :long, Long.Agent.Deno,
  deno_bin: "deno",
  auto_install: true

# Configure the endpoint
config :long, LongWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LongWeb.ErrorHTML, json: LongWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Long.PubSub,
  live_view: [signing_salt: "iOyjpcWR"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :long, Long.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  long: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  long: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
