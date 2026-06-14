defmodule Long.MixProject do
  use Mix.Project

  def project do
    [
      app: :long,
      version: "0.3.25",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules(),
      description: description(),
      package: package(),
      releases: releases(),
      source_url: "https://github.com/mjason/long"
    ]
  end

  defp releases do
    [
      long: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        # Strip beam files to shrink the tarball ~30%.
        strip_beams: Mix.env() == :prod,
        # `priv/agent/` is the runtime workspace (Deno sandbox dirs,
        # skills, AI scratch). Dev runs accumulate hundreds of MB there; the
        # installer recreates whatever's needed under `~/.long/agent`.
        steps: [:assemble, &strip_agent_workspace/1]
      ]
    ]
  end

  defp strip_agent_workspace(release) do
    agent_dir =
      Path.join([release.path, "lib", "long-#{release.version}", "priv", "agent"])

    if File.exists?(agent_dir), do: File.rm_rf!(agent_dir)
    release
  end

  defp description do
    "Self-hosted LLM agent runtime on Elixir/OTP — built-in web UI, four-tier memory, " <>
      "scheduled tasks, 20+ LLM providers, and WeChat / Telegram bots, all in one " <>
      "self-contained binary you install like a CLI."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/mjason/long"}
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Long.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:mishka_chelekom, "~> 0.0", only: [:dev]},
      {:live_debugger, "~> 1.0", only: [:dev]},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_admin, "~> 1.0"},
      {:ash_sqlite, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_graphql, "~> 1.9"},
      {:ash, "~> 3.0"},
      {:absinthe_plug, "~> 1.5"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:floki, "~> 0.36"},
      {:mint_web_socket, "~> 1.0"},
      {:jido, "~> 2.2"},
      {:jido_ai, "~> 2.1"},
      {:eqrcode, "~> 0.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:error_tracker, "~> 0.9"},
      {:yaml_elixir, "~> 2.12"},
      {:file_system, "~> 1.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind long", "esbuild long"],
      "assets.deploy": [
        "tailwind long --minify",
        "esbuild long --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "ash.setup": ["ash.setup", "run priv/repo/seeds.exs"]
    ]
  end

  defp usage_rules do
    # Example for those using claude.
    [
      file: "CLAUDE.md",
      # rules to include directly in CLAUDE.md
      usage_rules: ["usage_rules:all"],
      skills: [
        location: ".claude/skills",
        # build skills that combine multiple usage rules
        build: [
          "ash-framework": [
            # The description tells people how to use this skill.
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            # Include all Ash dependencies
            usage_rules: [:ash, ~r/^ash_/]
          ],
          "phoenix-framework": [
            description:
              "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            # Include all Phoenix dependencies
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ]
        ]
      ]
    ]
  end
end
