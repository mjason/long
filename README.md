# Long

[![Elixir](https://img.shields.io/badge/elixir-1.15%2B-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.8-orange.svg)](https://phoenixframework.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**English** · [简体中文](README.zh-CN.md)

> A single-process LLM agent runtime on Elixir/OTP. Phoenix for the UI, Ash for the data layer, Oban for scheduled tasks, ReqLLM for provider abstraction.

Long *started* as a port of the Python [GenericAgent](https://github.com/lsdefine/GenericAgent) to Elixir, borrowing its core shape — *one session → ReAct loop → tools + memory + skills*. The design has since diverged substantially: on the BEAM it gets real concurrency, fault tolerance, and long-lived push messaging natively (one supervised GenServer per session rather than a bolted-on Python process model), and the agent's capability layer has been rebuilt on **mature, standard technology rather than a bespoke tool protocol** — most notably **GraphQL as the agent's primary skill** (see below).

It's **web-first**: you don't run a CLI to talk to it. Open the browser, and chat, configuration, memory, channels, and scheduled tasks are all just pages.

## Design philosophy

Long is built to install and run **like a personal CLI tool, not like server infrastructure.** Everything below follows from that one decision.

- **One self-contained binary.** `mix release` bundles the Erlang VM (ERTS) and every BEAM dependency into a single tarball. The target machine needs neither Erlang nor Elixir installed — just untar and run. No Docker image to build, no base image to track.
- **Installs into one directory, owns nothing else.** `curl | bash` drops everything under `~/.long/` — the binary, the VM, the SQLite database, the config, the agent workspace, the skills. Uninstall is `rm -rf ~/.long`. Upgrades wipe only `bin/ lib/ releases/ erts-*` and **preserve your `env`, `long.db`, and `agent/` data**.
- **No external services to provision.** Storage is SQLite (a file) plus the filesystem (skills, workspace). No Postgres, no Redis, no message broker. The whole runtime is *one OS process* — the BEAM — internally supervising sessions, bots, the scheduler, and even the headless-browser subprocess.
- **Userspace, no root.** Install and autostart run entirely as your user. `~/.long/service install` wires up launchd (macOS) or a systemd **user** unit (Linux) so the agent survives reboot — you never write a unit file or `sudo` anything.
- **No language runtime to provision.** `code_run` executes TypeScript/JavaScript in a sandboxed [Deno](https://deno.land/) binary that the app downloads and manages itself on first use — no Python, Node, or `uv` to install (`bash` is available for shell commands). The optional headless browser, Obscura, is fetched the same way.
- **LAN-first, not internet-hardened.** Binds `0.0.0.0`, `check_origin` off, no forced SSL — so a freshly installed node is reachable from any device on your home network by IP. Internet exposure is opt-in (`LONG_CHECK_ORIGIN`, a reverse proxy, etc.), never the default that locks you out on first run. In the same spirit, `code_run`'s `bash` mode runs with the server's full host access (only the Deno engine — the default — is sandboxed per-member); that's fine for a trusted household, not for untrusted members.
- **Open-source-friendly delivery.** The installer pulls release tarballs straight from GitHub Releases over plain `curl` — no `gh` CLI, no GitHub account, no auth. Anyone can install with one line.

The result: getting Long onto a Mac mini or a Linux box in the corner is `curl | bash` + paste an API key, and it behaves like an appliance from there.

## GraphQL as the agent's primary skill

Most agent frameworks invent a bespoke tool protocol — one narrow tool per capability (`schedule_task`, `remember_fact`, `update_checkpoint`, …), each with a hand-maintained schema the model has to be taught.

Long takes a different route: **the agent's main capability is a single `graphql` tool** over the entire Ash data layer — sessions, messages, both memory tiers, working checkpoints, scheduled tasks, secrets, LLM/search configs — for **read *and* write** through one uniform interface.

- **The model already speaks it.** GraphQL is in every model's pretraining; there's no custom DSL to explain.
- **It's self-describing.** The schema is introspectable (`{ __schema { queryType { fields { name } } } }`), so the agent discovers its own capabilities at runtime instead of us maintaining a wall of tool descriptions.
- **One tool replaces ~10.** Adding a new Ash resource automatically grants the agent CRUD over it — no new tool to write, register, or document.

This is the core bet: lean on mature, introspectable, widely-understood technology (GraphQL) as the agent's capability surface, and let the model's existing fluency do the rest. File-based **Skills** (`SKILL.md` + scripts, below) remain for packaged, code-carrying capabilities; GraphQL is how the agent reads and writes its own world.

## Web UI

Everything is a page — there's no separate CLI you have to learn to operate the agent day to day.

| Page | What it is |
|---|---|
| `/chat` | the agent. Streaming replies, live tool-call display, a memory side-rail, AI-named sessions. |
| `/manage` | everything else. LLMs, memory, skills, sessions, search providers, channels, scheduled tasks — each a LiveView. |

## Features

- **GraphQL capability layer** — one introspectable `graphql` tool gives the agent read/write over its whole data world (see above).
- **Web-first LiveView UI** — `/chat` (streaming output + tool-call display + live memory side-rail + AI-generated session titles) and `/manage` for everything else.
- **Four-tier memory:**
  - L1 `WorkingCheckpoint` (one `key_info` row per session)
  - L2 `GlobalMemory` / `SessionMemory` (fact / preference / goal / decision, with importance + recency decay)
  - L3 **Anthropic-compatible Skills** (`SKILL.md` + scripts/references/assets; the filesystem is the source of truth, a watcher drives an ETS index)
  - L4 `SessionArchive` (session archival + LLM summary)
- **Multi-provider LLM routing** — ReqLLM speaks 20+ providers natively (openai / anthropic / google / groq / deepseek / openrouter / mistral / ollama / xai / bedrock / …); wire protocol is configurable, one alias is the default.
- **Unified admin at `/manage`** — LLM configs, memory editing, skill browsing, session management, search providers, channels, scheduled tasks, secrets — all LiveView, no ash_admin dependency.
- **Scheduled tasks** — Oban-driven; the LLM schedules its own via GraphQL `createScheduledTask`, or you create them by hand at `/manage/scheduled`.
- **Channels** — WeChat (PCHook) and Telegram, behind a unified `Bots.Outbound` dispatch layer, managed in one place at `/manage/credentials`.
- **Web search aggregation** — Tavily / Brave API + SERP scrapers, RRF multi-source merge, providers configured at `/manage/search`.
- **Real headless browsing** — the Obscura CLI (a Rust Chromium fork) powers the `web_scan` / `web_execute_js` tools.
- **Error observability** — ErrorTracker dashboard, a `:logger` crash backstop, transparent exponential-backoff retry on LLM calls.
- **In-conversation control** — `/clear` wipes a session, `/status` asks what the agent is doing, `/btw <note>` interjects mid-run.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Phoenix LiveView ─ /chat ─ /manage ─ navigation hub            │
├─────────────────────────────────────────────────────────────────┤
│  Long.Agent.Server (GenServer per session)  ──►  ReAct loop     │
│   │                                │                            │
│   ├── persist messages → DB       ├── tools (file/web/memory/…) │
│   └── PubSub stream → LiveView    └── ReqLLM streaming          │
├─────────────────────────────────────────────────────────────────┤
│  Memory  L1 WorkingCheckpoint   L2 Global + Session             │
│          L3 Skill.Store (FS + watcher + ETS)                    │
│          L4 SessionArchive                                      │
├─────────────────────────────────────────────────────────────────┤
│  Long.Agent.Bots ─ WeChat │ Telegram                           │
│  Oban ─ ScheduledTask runner    ErrorTracker ─ /errors          │
├─────────────────────────────────────────────────────────────────┤
│  Storage:  SQLite (Ash) + filesystem (skills, workspace)        │
└─────────────────────────────────────────────────────────────────┘
```

Core stack:

| Dependency | Role |
|---|---|
| Elixir 1.15+, Phoenix 1.8, Ash 3, AshSqlite | App / data layer |
| Oban + AshOban + Oban Web | Background job scheduling |
| ReqLLM | Unified multi-provider LLM access |
| Jido + Jido.AI | Tool system (Zoi schema + auto JSONSchema) |
| Mishka Chelekom | 70+ Tailwind LiveView components |
| Obscura | Rust headless-browser CLI |
| ErrorTracker | In-app exception aggregation |

## Quick start

### One-line install (macOS / Linux)

Prebuilt releases cover `macos-arm64`, `linux-x64`, and `linux-arm64`:

```bash
curl -fsSL https://raw.githubusercontent.com/mjason/long/main/install.sh | bash
```

The script:

- pulls the latest tarball from GitHub Releases and extracts it to `~/.long/`,
- on first run generates `~/.long/env` (with an auto-generated `SECRET_KEY_BASE`, `DATABASE_PATH`, …),
- writes the `~/.long/run` launcher and the `~/.long/service` autostart controller.

```bash
$EDITOR ~/.long/env     # usually nothing to change
~/.long/run             # start; open http://localhost:4000
```

Make it start on boot (no root, no unit-file editing):

```bash
~/.long/service install     # enable autostart (launchd / systemd-user)
~/.long/service status      # is it registered + running?
~/.long/service logs        # tail run.log
~/.long/service uninstall   # disable autostart
```

Installer environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `LONG_INSTALL_DIR` | `~/.long` | install target |
| `LONG_VERSION` | latest | pin a version, e.g. `v0.2.9` |

### Run from source

Requirements:

- Elixir 1.15+ / Erlang 26+
- SQLite 3
- (Deno and the optional Obscura browser are auto-downloaded at runtime — nothing to pre-install.)

```bash
git clone https://github.com/mjason/long.git
cd long
mix setup            # deps.get + ecto.create + migrate + seeds + asset build
mix phx.server
```

Open <http://localhost:4000/> and enter `/chat` or `/manage/llms` from the navigation hub.

### Configure your first LLM

Open `/manage/llms` → **New LLM**:

| Field | Example |
|---|---|
| Alias | `claude_main` |
| Provider | `anthropic` |
| Wire protocol | `anthropic_messages` |
| Model | `claude-sonnet-4` |
| API base | `https://api.anthropic.com` (or a proxy) |
| API key | `sk-ant-…`, or leave blank to use `api_key_env_var` |
| Set as default | ✓ |

Save, go back to `/chat`, and new sessions bind to this alias automatically. The same flow works for OpenAI / Google / Groq / DeepSeek / any ReqLLM-supported provider.

### Install your first Skill (optional)

```bash
mkdir -p priv/agent/skills/hello-world/scripts

cat > priv/agent/skills/hello-world/SKILL.md <<'MD'
---
name: hello-world
description: Demo skill — takes a `name` arg, returns a greeting string.
tags: [demo]
---

# hello-world

Run `scripts/hello.py "<name>"`.
MD

cat > priv/agent/skills/hello-world/scripts/hello.py <<'PY'
import json, sys
name = (json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}).get("name", "world")
print(json.dumps({"greeting": f"hello, {name}"}, ensure_ascii=False))
PY

mix long.skill reindex   # or restart the server; the watcher also picks it up
```

Next conversation, the LLM sees `hello-world` under `# Available skills` and can `skill_read` then `code_run` it. The format is fully compatible with [Anthropic Agent Skills](https://code.claude.com/docs/en/skills), so you can `git clone https://github.com/anthropics/skills priv/agent/skills/` to grab the official repo wholesale.

## Channels (platform bots)

Two channels are supported today, both onboarded entirely from the web at **`/manage/credentials`** (the "Channels" page) — no env vars, no restart.

- **WeChat** — click *扫码登录* (scan to log in) to open an inline QR and bind a WeChat account via Tencent's iLink bot API (no desktop hook needed); the credential is stored in the DB and the worker hot-reloads on connect.
- **Telegram** — paste a [@BotFather](https://t.me/BotFather) token; the worker starts long-polling immediately. Replies render as Telegram HTML, with typing indicators and inbound/outbound media (photos, documents).

## CLI tools

| Command | Purpose |
|---|---|
| `mix phx.server` | start the web server (default port 4000) |
| `mix long.skill list / reindex / remove NAME` | skill index management |
| `mix long.wechat.login` | WeChat QR login + buf persistence |
| `iex -S mix` | REPL: `Long.Agent.list_sessions()`, etc. |
| `mix test` | test suite |
| `mix precommit` | `compile --warnings-as-errors + format + test` |

## Configuration

**Configure from the web, not from files.** Almost everything — LLMs, search providers, channels, scheduled tasks, memory, secrets — lives in the DB and is edited at `/manage`. There's no config file to redeploy for day-to-day changes.

The only file-level config is a handful of filesystem roots, under `:long, Long.Agent` in `config/config.exs` (the installed release reads these from `~/.long/env` instead):

```elixir
config :long, Long.Agent,
  memory_root: "priv/agent/memory",      # legacy GenericAgent-compatible path
  skill_root:  "priv/agent/skills",      # L3 skill dir (SKILL.md lives here)
  workspace_root: "priv/agent/workspace" # root for code_run / file_* tools
```

Everything else is a page in `/manage` (or, if you prefer, an IEx call like `Long.Agent.register_llm/1`).

## Development

```bash
mix test                                # unit + LiveView tests
mix test test/long/jido                 # run one group
mix format
mix precommit                           # compile --warnings-as-errors + format + test
mix usage_rules.docs Ash.Resource       # look up dependency docs
```

`CLAUDE.md` carries project-level AI-agent guidance (usage rules + skill entry points), auto-loaded if you use Claude Code / Cursor / similar IDE agents.

## Status

**Alpha — single-user.** This project currently runs as one person's (mine) daily AI assistant.

- No multi-tenancy / permission isolation.
- The schema changes occasionally; no backward-compat promise.
- Some paths (mixin LLM, full WeChat / Telegram chains) have light test coverage.
- Deployment docs are single-node only.

Issues and PRs welcome, but there's no committed release cadence.

## Roadmap

Near-term:

- [ ] Memory editor on Mishka form components (`<.text_field>` etc.) instead of hand-rolled `<input>`s
- [ ] AshPhoenix.Form to replace the hand-rolled LLM modal conversion
- [ ] Multi-user / session isolation (auth + per-user namespace)

Longer-term:

- [ ] CRDT-based multi-client session sync
- [ ] Extract the ReAct loop into a standalone hex lib so Loop / Memory / Skill can be reused outside Phoenix

## Acknowledgements

- The Python [GenericAgent](https://github.com/lsdefine/GenericAgent) was the original starting point.
- [Ash Framework](https://ash-hq.org) lets data + domain logic be described together.
- [ReqLLM](https://hexdocs.pm/req_llm/) makes onboarding a new LLM provider a one-line alias.
- [Mishka Chelekom](https://mishka.tools/chelekom/) provides the full LiveView component library.
- [Anthropic Agent Skills](https://github.com/anthropics/skills) defines the SKILL.md format.
- [Obscura](https://github.com/h4ckf0r0day/obscura) forked Chromium into a clean CLI.

## License

MIT — see [LICENSE](LICENSE).
