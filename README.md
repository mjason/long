# Long

[![Elixir](https://img.shields.io/badge/elixir-1.15%2B-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.8-orange.svg)](https://phoenixframework.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> 一个跑在 Elixir/OTP 上的单进程 LLM Agent 运行时。Phoenix 做 UI，Ash 做数据层，Oban 跑定时任务，ReqLLM 做 provider 抽象。

Long 是把原先用 Python 写的 GenericAgent 整套搬到 Elixir 的版本——保留了「一个会话 → ReAct 循环 → 工具 + 记忆 + 技能」的核心架构，但落到 BEAM 上后获得了真正的并发 / 容错 / 长连接消息推送能力，不用再围绕 Python 的进程模型自己造监督树。

## 核心能力

- **LiveView 聊天 UI** —— 流式渲染 + 工具调用展示 + 实时记忆侧栏 + AI 自动生成会话标题
- **四层记忆** ——
  - L1 `WorkingCheckpoint`（每会话一行 key_info）
  - L2 `GlobalMemory` / `SessionMemory`（fact / preference / goal / decision，带 importance + recency 衰减）
  - L3 **Anthropic 兼容 Skills**（`SKILL.md` + scripts/references/assets，文件系统是 source of truth，watcher 驱动的 ETS 索引）
  - L4 `SessionArchive`（会话归档 + LLM 摘要）
- **多 Provider LLM 路由** —— ReqLLM 原生 20+ provider（openai / anthropic / google / groq / deepseek / openrouter / mistral / ollama / xai / bedrock / …），wire protocol 可配，单条 alias 设为默认
- **统一管理后台 `/manage`** —— LLM 配置、记忆编辑、技能浏览、会话管理、搜索 provider、平台凭据、定时任务，全部 LiveView，不依赖 ash_admin
- **定时任务** —— Oban 驱动，LLM 通过 `schedule_task` 工具自己排，或者在 `/manage/scheduled` 手动建
- **多平台 Bot** —— WeChat（PCHook）、Telegram、Feishu，统一的 `Bots.Outbound` 调度层
- **Web 搜索聚合** —— Tavily / Brave API + SERP scraper，RRF 多源合并，provider 通过 `/manage/search` 配置
- **真实头(headless) 浏览** —— Obscura CLI（Rust 写的 Chromium fork）驱动 `web_scan` / `web_execute_js` 工具
- **错误可观测** —— ErrorTracker dashboard，`:logger` crash backstop，LLM 调用透明指数退避重试
- **对话级控制** —— `/clear` 清会话、`/status` 查问 Agent 在干啥、`/btw <note>` 中途插话

## 架构一览

```
┌─────────────────────────────────────────────────────────────────┐
│  Phoenix LiveView ─ /chat ─ /manage ─ navigation hub            │
├─────────────────────────────────────────────────────────────────┤
│  Long.Jido.SessionRunner  ────►  Long.Jido.Loop  (ReAct)        │
│   │                                │                            │
│   ├── on_message → DB persist     ├── tools (file/web/memory/…) │
│   └── PubSub stream → LiveView    └── ReqLLM streaming          │
├─────────────────────────────────────────────────────────────────┤
│  Memory  L1 WorkingCheckpoint   L2 Global + Session             │
│          L3 Skill.Store (FS + watcher + ETS)                    │
│          L4 SessionArchive                                      │
├─────────────────────────────────────────────────────────────────┤
│  Long.Agent.Bots ─ WeChat │ Telegram │ Feishu                   │
│  Oban  ─ ScheduledTask runner   ErrorTracker ─ /errors          │
├─────────────────────────────────────────────────────────────────┤
│  Storage:  SQLite (Ash) + filesystem (skills, workspace)        │
└─────────────────────────────────────────────────────────────────┘
```

依赖核心栈：

| 依赖 | 用途 |
|---|---|
| Elixir 1.15+, Phoenix 1.8, Ash 3, AshSqlite | 应用 / 数据层 |
| Oban + AshOban + Oban Web | 后台任务调度 |
| ReqLLM | 多 provider LLM 统一接入 |
| Jido + Jido.AI | Tool 系统 (Zoi 描述 + 自动 JSONSchema) |
| Mishka Chelekom | 70+ Tailwind LiveView 组件 |
| Obscura | Rust 编写的无头浏览器 CLI |
| ErrorTracker | 应用内异常聚合 |

## 快速开始

### 一键安装 (macOS / Linux)

预编译版本支持 `macos-arm64`、`linux-x64`、`linux-arm64`。需要先装并登录 [GitHub CLI](https://cli.github.com/)：

```bash
brew install gh        # 或 apt install gh
gh auth login
```

然后一行安装：

```bash
gh api "repos/mjason/long/contents/install.sh" --jq '.content' | base64 -d | bash
```

脚本会：

- 拉取最新 release tarball，解压到 `~/.long/`
- 检测不到 `uv` 时自动装一份（[Astral uv](https://docs.astral.sh/uv/)，`code_run` 工具需要）
- 首次运行生成 `~/.long/env`，里面有 `SECRET_KEY_BASE`、`DATABASE_PATH` 等
- 生成启动脚本 `~/.long/run`

```bash
$EDITOR ~/.long/env    # 通常无需修改
~/.long/run            # 启动，访问 http://localhost:4000
```

> 默认安装目录 `~/.long`，可用 `LONG_INSTALL_DIR` 环境变量覆盖。

### 从源码运行

依赖：

- Elixir 1.15+ / Erlang 26+
- SQLite 3
- `uv`（[Astral uv](https://docs.astral.sh/uv/)，给 Skill 的 Python 脚本提供运行时；不用 Python skill 可以不装）

```bash
git clone https://github.com/mjason/long.git
cd long
mix setup            # deps.get + ecto.create + migrate + seeds + 资产构建
mix phx.server
```

浏览器打开 <http://localhost:4004/>，从导航中心进入 `/chat` 或 `/manage/llms`。

### 配置第一个 LLM

打开 `/manage/llms` → **New LLM**：

| 字段 | 例 |
|---|---|
| Alias | `claude_main` |
| Provider | `anthropic` |
| Wire protocol | `anthropic_messages` |
| Model | `claude-sonnet-4` |
| API base | `https://api.anthropic.com`（或代理） |
| API key | `sk-ant-…` 或留空走 `api_key_env_var` |
| Set as default | ✓ |

保存后回到 `/chat`，新会话会自动绑这个 alias。同样的流程适用 OpenAI / Google / Groq / DeepSeek 等任意 ReqLLM 支持的 provider。

### 安装第一个 Skill（可选）

```bash
mkdir -p priv/agent/skills/hello-world/scripts

cat > priv/agent/skills/hello-world/SKILL.md <<'MD'
---
name: hello-world
description: 演示 Skill 接入，接受 `name` 参数，返回问候字符串。
tags: [demo]
---

# hello-world

运行 `scripts/hello.py "<name>"` 即可。
MD

cat > priv/agent/skills/hello-world/scripts/hello.py <<'PY'
import json, sys
name = (json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}).get("name", "world")
print(json.dumps({"greeting": f"hello, {name}"}, ensure_ascii=False))
PY

mix long.skill reindex   # 或者重启 server,watcher 也会自动捕获
```

下次对话里 LLM 看到 `# Available skills` 里的 `hello-world` 就能 `skill_search` / `skill_read` 然后 `code_run` 执行。Skill 格式完整兼容 [Anthropic Agent Skills](https://code.claude.com/docs/en/skills)，可以直接 `git clone https://github.com/anthropics/skills priv/agent/skills/` 白嫖官方仓库。

## CLI 工具

| 命令 | 用途 |
|---|---|
| `mix phx.server` | 启动 web 服务（端口默认 4004） |
| `mix long.skill list / reindex / remove NAME` | Skill 索引管理 |
| `mix long.wechat.login` | WeChat 扫码登录 + buf 持久化 |
| `iex -S mix` | REPL：`Long.Agent.list_sessions()` / `Long.Jido.Loop.run(…)` 等 |
| `mix test` | 测试套件 |
| `mix precommit` | `compile --warnings-as-errors + format + test` |

## 配置

主要配置项在 `config/config.exs` 下的 `:long, Long.Agent`：

```elixir
config :long, Long.Agent,
  memory_root: "priv/agent/memory",      # 历史 GenericAgent 兼容路径
  skill_root:  "priv/agent/skills",      # L3 Skill 目录(SKILL.md 在这里)
  workspace_root: "priv/agent/workspace" # code_run / file_* 工具的根
```

LLM / search / bot 等配置走 DB，通过 `/manage` 编辑或 IEx 调用 `Long.Agent.register_llm/1` 等。

## 平台 Bot

### WeChat

需要[启明 PCHook](https://www.fudankw.cn/)。`mix long.wechat.login` 扫码后凭据存进 DB（`/manage/credentials`）。`Long.Agent.Bots.Wechat.Worker` 自动 attach 一个 session 给每个聊天用户。

### Telegram

`config/dev.exs`：

```elixir
config :long, :telegram,
  bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  enabled: true
```

### Feishu

`POST /webhooks/feishu` 已经接好，配置在 `LongWeb.FeishuController`。

## 开发

```bash
mix test                                # 单元 + LiveView 测试
mix test test/long/jido                 # 跑某一组
mix format
mix precommit                           # compile --warnings-as-errors + format + test
mix usage_rules.docs Ash.Resource       # 查依赖文档
```

`CLAUDE.md` 里有项目级 AI agent 指引（usage rules + skill 入口），如果你在用 Claude Code / Cursor 等 IDE agent 工具会自动加载。

## 状态

**Alpha — 单用户使用。** 这个项目目前为一个用户（我自己）的日常 AI 助手运行。

- 没有多租户 / 权限隔离
- schema 偶尔会变化，没承诺向后兼容
- 部分功能（mixin LLM、Feishu / Telegram 全链路）测试覆盖率较低
- 部署文档目前只跑 single-node

欢迎 issue 报问题、PR 提改进，但目前没有承诺的发布节奏。

## Roadmap

短期：

- [ ] Memory editor 改用 `<.text_field>` 等 Mishka 表单组件（目前手写 `<input>`）
- [ ] AshPhoenix.Form 替换 LLM modal 的手卷转换
- [ ] 多用户 / 会话隔离（auth + per-user namespace）

中长期：

- [ ] CRDT-based 多客户端会话同步
- [ ] 把 `Long.Jido.Loop` 抽成独立 hex lib，让 Loop / Memory / Skill 可以被 Phoenix 之外的项目复用

## 致谢

- Python 版 GenericAgent 提供了所有架构原型
- [Ash Framework](https://ash-hq.org) 让数据 + 域逻辑可以一起描述
- [ReqLLM](https://hexdocs.pm/req_llm/) 让接入新 LLM provider 只需要一行 alias
- [Mishka Chelekom](https://mishka.tools/chelekom/) 提供了完整的 LiveView 组件库
- [Anthropic Agent Skills](https://github.com/anthropics/skills) 定义了 SKILL.md 格式
- [Obscura](https://github.com/h4ckf0r0day/obscura) 把 Chromium fork 成了一个干净的 CLI

## License

MIT — 见 [LICENSE](LICENSE)。
