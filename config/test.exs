import Config
config :long, Oban, testing: :manual
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Tests don't auto-install Obscura — we don't want a 50 MB download
# kicking off in CI. The Engine GenServer will report :failed status
# and the browser-backed tools return `{:error, :not_installed}`.
config :long, Long.Agent.Browser, auto_install: false

# Same for Deno — no ~40 MB download in CI; the Engine reports :failed and
# code_run (deno) errors gracefully (tests use type: "bash" or stubs).
config :long, Long.Agent.Deno, auto_install: false

# Don't pollute the test sandbox with captured errors.
config :error_tracker, enabled: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :long, Long.Repo,
  database: Path.expand("../long_test.db", __DIR__),
  pool_size: 5,
  # Wait out SQLite's single-writer lock instead of raising "Database busy"
  # under concurrent async-test writes (default is only 2s). See dev.exs.
  busy_timeout: 15_000,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :long, LongWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "nsaKWFN/Sdgp2sHadY5WHr04vdIF7TNDPbbI+PpDn+gFbo6AwdZiQkgRaH/N9hLx",
  server: false

# In test we don't send emails
config :long, Long.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
