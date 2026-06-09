# Long

[![Elixir](https://img.shields.io/badge/elixir-1.15%2B-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.8-orange.svg)](https://phoenixframework.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) · **简体中文**

> 一个跑在 Elixir/OTP 上的单进程、多用户 LLM Agent 运行时——面向家庭或小团队。Phoenix 做 UI，Ash 做数据层，Oban 跑定时任务，ReqLLM 做 provider 抽象。

Long *最初* 是把 Python 写的 [GenericAgent](https://github.com/lsdefine/GenericAgent) 搬到 Elixir，借用了「一个会话 → ReAct 循环 → 工具 + 记忆 + 技能」的基本形态。但后来设计思路已经和原版相去甚远：落到 BEAM 上之后原生拿到了真正的并发 / 容错 / 长连接推送（每个会话一个受监督的 GenServer，而不是在 Python 进程模型上硬接监督树），更关键的是 Agent 的能力层被**用成熟的标准技术重做，而不是自造一套工具协议**——最突出的就是**用 GraphQL 做 Agent 的主要技能**（见下文）。

它是 **web 优先**的：不用敲 CLI 跟它对话。打开浏览器，聊天、配置、记忆、通道、定时任务全是网页。

## 设计理念

Long 的目标是**像装一个个人 CLI 工具那样安装和运行，而不是像部署服务器基础设施。** 下面所有取舍都来自这一个决定。

- **单个自包含产物。** `mix release` 把 Erlang 虚拟机（ERTS）和所有 BEAM 依赖打进一个 tarball。目标机器既不用装 Erlang 也不用装 Elixir——解压即跑。没有 Docker 镜像要构建，没有 base image 要维护。
- **只占一个目录，不碰别处。** `curl | bash` 把所有东西放进 `~/.long/`——二进制、虚拟机、SQLite 数据库、配置、Agent 工作区、技能。卸载就是 `rm -rf ~/.long`。升级只清 `bin/ lib/ releases/ erts-*`，**保留你的 `env`、`long.db` 和 `agent/` 数据**。
- **零外部服务依赖。** 存储就是 SQLite（一个文件）+ 文件系统（技能、工作区）。没有 Postgres、没有 Redis、没有消息队列。整个运行时是*一个操作系统进程*——BEAM——在内部用监督树管住会话、bot、定时器，连无头浏览器子进程都一起管。
- **用户态，不需要 root。** 安装和开机自启全程以你自己的用户身份运行。`~/.long/service install` 会帮你接好 launchd（macOS）或 systemd **user** 单元（Linux），重启后自动拉起——你不用写 unit 文件，也不用 `sudo`。
- **不需要预装任何语言运行时。** `code_run` 在一个沙箱化的 [Deno](https://deno.land/) 二进制里跑 TypeScript/JavaScript，这个二进制由 App 在首次使用时自己下载并托管——不用装 Python、Node 或 `uv`（要执行 shell 命令则用 `bash`）。可选的无头浏览器 Obscura 也是同样方式自动获取。
- **局域网优先，默认不做公网加固。** 绑 `0.0.0.0`、`check_origin` 关、不强制 SSL——刚装好的节点就能被局域网里任意设备用 IP 直接访问。公网暴露是按需开启的（`LONG_CHECK_ORIGIN`、反向代理等），绝不会出现「首次运行就把自己锁在外面」。同理，`code_run` 的 `bash` 模式拥有服务进程的完整主机权限（只有默认的 Deno 引擎按成员做了沙箱隔离）——这对信任的家庭场景没问题，但不适合不受信任的成员。
- **对开源友好的分发方式。** 安装脚本直接用普通 `curl` 从 GitHub Releases 拉 tarball——不依赖 `gh` CLI，不需要 GitHub 账号，不需要鉴权。任何人一行命令就能装。

最终效果：把 Long 装到角落里那台 Mac mini 或 Linux 小主机上，就是 `curl | bash` + 粘一个 API key，之后它就像个家电一样自己跑着。

## 用 GraphQL 做 Agent 的主要技能

大多数 agent 框架会自造一套工具协议——每个能力一个窄工具（`schedule_task`、`remember_fact`、`update_checkpoint`……），每个都得手写一份 schema 教给模型。

Long 走了另一条路：**Agent 的主要能力是一个 `graphql` 工具**，覆盖整个 Ash 数据层——会话、消息、两层记忆、working checkpoint、定时任务、密钥、LLM / 搜索配置——通过同一个统一接口做**读 *和* 写**。

- **模型本来就会。** GraphQL 在每个模型的预训练里都有，不用解释自造 DSL。
- **schema 自描述。** schema 可内省（`{ __schema { queryType { fields { name } } } }`），Agent 运行时自己发现能力，我们不用维护一大堆工具描述。
- **一个工具顶十个。** 新加一个 Ash 资源，Agent 自动获得对它的 CRUD——不用再写、注册、文档化新工具。

这是核心赌注：把成熟、可内省、人人都懂的技术（GraphQL）当作 Agent 的能力面，剩下的交给模型已有的熟练度。文件式 **Skill**（`SKILL.md` + 脚本，见下文）继续承担打包的、带代码的能力；GraphQL 则是 Agent 读写自己世界的方式。

## Web 界面

一切都是网页——日常操作 Agent 不需要另学一套 CLI。

| 页面 | 是什么 |
|---|---|
| `/chat` | Agent 本体。流式回复、实时工具调用展示、记忆侧栏、AI 自动命名会话。 |
| `/manage` | 其它一切。LLM、记忆、技能、**组与成员**、会话、搜索 provider、通道、定时任务、**话术(i18n)**，每个都是 LiveView。 |

## 核心能力

- **GraphQL 能力层** —— 一个可内省的 `graphql` 工具让 Agent 读写自己的整个数据世界（见上文）
- **组与成员（多租户）** —— 一个部署托管一个或多个**组**（一个家庭、一个小团队）。每个**成员**用 `/bind <绑定码>` 接入自己的微信 / Telegram，拿到独立的 per-member 代码工作区 + 个人技能，还能给组里其他成员发消息（「通知…」）。一个 owner，多个成员。
- **沙箱化代码执行** —— `code_run` 在托管的 [Deno](https://deno.land/) 二进制上跑 TypeScript/JavaScript，读写沙箱限定在调用者的 per-member 工作区；`bash` 用于 shell。没有 Python——Deno 首次使用时自动下载。
- **逐聊天语言（i18n）** —— 每条 bot 文案按回退链解析（渠道 → 成员 → 组 → 平台探测 → 系统默认），都能在 `/manage/phrases` 覆盖；系统默认语言一键设置。
- **Web 优先的 LiveView UI** —— `/chat`（流式渲染 + 工具调用展示 + 实时记忆侧栏 + AI 自动生成会话标题）+ `/manage` 管一切
- **四层记忆** ——
  - L1 `WorkingCheckpoint`（每会话一行 key_info）
  - L2 `GlobalMemory` / `SessionMemory`（fact / preference / goal / decision，带 importance + recency 衰减）
  - L3 **Anthropic 兼容 Skills**（`SKILL.md` + scripts/references/assets），**按成员私有或组内共享**（在 `/manage/skills` 把个人技能提升为全局，或查看技能完整 `SKILL.md`）；文件系统是 source of truth，watcher 驱动的 ETS 索引
  - L4 `SessionArchive`（会话归档 + LLM 摘要）
- **多 Provider LLM 路由** —— ReqLLM 原生 20+ provider（openai / anthropic / google / groq / deepseek / openrouter / mistral / ollama / xai / bedrock / …），wire protocol 可配，单条 alias 设为默认
- **统一管理后台 `/manage`** —— LLM 配置、记忆编辑、技能浏览、**组与成员、通道、话术(i18n)**、会话管理、搜索 provider、定时任务、密钥，全部 LiveView，不依赖 ash_admin
- **定时任务** —— Oban 驱动，LLM 通过 GraphQL `createScheduledTask` 自己排，或者在 `/manage/scheduled` 手动建
- **多账号通道** —— 同时托管多个微信号和/或 Telegram bot，每个绑定不同成员；入站自动标记发送者，出站精确路由回这条聊天到达的那个账号。在 `/manage/credentials` 接入。
- **Web 搜索聚合** —— Tavily / Brave API + SERP scraper，RRF 多源合并，provider 通过 `/manage/search` 配置
- **真实头(headless) 浏览** —— Obscura CLI（Rust 写的 Chromium fork）驱动 `web_scan` / `web_execute_js` 工具
- **错误可观测** —— ErrorTracker dashboard，`:logger` crash backstop，LLM 调用透明指数退避重试
- **对话级控制** —— `/clear` 清会话、`/status` 查问 Agent 在干啥、`/btw <note>` 中途插话、`/bind <绑定码>` 把这条聊天绑到成员

## 架构一览

```
┌─────────────────────────────────────────────────────────────────┐
│  Phoenix LiveView ─ /chat ─ /manage ─ navigation hub            │
├─────────────────────────────────────────────────────────────────┤
│  Long.Agent.Server (每会话一个 GenServer)  ──►  ReAct 循环       │
│   │                                │                            │
│   ├── 消息持久化 → DB             ├── tools (file/web/memory/…) │
│   └── PubSub 流 → LiveView        └── ReqLLM streaming          │
├─────────────────────────────────────────────────────────────────┤
│  Memory  L1 WorkingCheckpoint   L2 Global + Session             │
│          L3 Skill.Store (FS + watcher + ETS)                    │
│          L4 SessionArchive                                      │
├─────────────────────────────────────────────────────────────────┤
│  Long.Agent.Bots ─ WeChat │ Telegram                           │
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

预编译版本支持 `macos-arm64`、`linux-x64`、`linux-arm64`。一行安装：

```bash
curl -fsSL https://raw.githubusercontent.com/mjason/long/main/install.sh | bash
```

脚本会：

- 从 GitHub Releases 拉取最新 tarball，解压到 `~/.long/`
- 首次运行生成 `~/.long/env`（含自动生成的 `SECRET_KEY_BASE`、`DATABASE_PATH` 等）
- 生成启动脚本 `~/.long/run` 和开机自启控制器 `~/.long/service`

```bash
$EDITOR ~/.long/env     # 通常无需修改
~/.long/run             # 启动，访问 http://localhost:4000
```

设置开机自启（不需要 root，不用写 unit 文件）：

```bash
~/.long/service install     # 启用开机自启（launchd / systemd-user）
~/.long/service status      # 是否注册 + 在跑？
~/.long/service logs        # tail run.log
~/.long/service uninstall   # 取消开机自启
```

安装脚本环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `LONG_INSTALL_DIR` | `~/.long` | 安装目录 |
| `LONG_VERSION` | latest | 指定版本，例如 `v0.2.9` |

### Docker

自包含镜像把 `mix release` **连同** Deno 和 Obscura 一起打进去——首次运行不下载任何东西。仓库自带现成的 `docker-compose.yml`：

```yaml
services:
  long:
    build: .                              # 或：image: ghcr.io/mjason/long:latest
    ports: ["4000:4000"]
    environment:
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}  # 生成一次：openssl rand -base64 48
      PHX_HOST: ${PHX_HOST:-localhost}
      # LONG_CHECK_ORIGIN: "true"          # 公网暴露时设
    volumes: ["long_data:/data"]          # SQLite 库 + 技能 + 工作区 + 记忆
    restart: unless-stopped
volumes:
  long_data:
```

在 clone 下来的仓库目录里：

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 48)
docker compose up -d          # 构建并运行
# → http://localhost:4000
```

数据（SQLite 库、技能、Agent 工作区、记忆）持久化在 `long_data` 卷里，重启/升级不丢。想要纯镜像？`docker build -t long .`。

### 从源码运行

依赖：

- Elixir 1.15+ / Erlang 26+
- SQLite 3
-（Deno 和可选的 Obscura 浏览器都会在运行时自动下载，无需预装。）

```bash
git clone https://github.com/mjason/long.git
cd long
mix setup            # deps.get + ecto.create + migrate + seeds + 资产构建
mix phx.server
```

浏览器打开 <http://localhost:4000/>，从导航中心进入 `/chat` 或 `/manage/llms`。

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

mix long.skill reindex   # 或者重启 server，watcher 也会自动捕获
```

下次对话里 LLM 看到 `# Available skills` 里的 `hello-world` 就能 `skill_read` 然后 `code_run` 执行。Skill 格式完整兼容 [Anthropic Agent Skills](https://code.claude.com/docs/en/skills)，可以直接 `git clone https://github.com/anthropics/skills priv/agent/skills/` 白嫖官方仓库。

## 通道与成员

一个部署服务一个或多个**组**；每个组有若干**成员**（人），每个成员接入自己的聊天账号。owner 在 **`/manage/credentials`** 一次性配好通道——不用配 env，不用重启：

- **WeChat** —— 点「扫码登录」弹出内嵌二维码，用微信号扫码托管（走腾讯 iLink bot 接口，不需要桌面 hook）。支持**多账号**——一个成员/角色托管一个；连上后 worker 自动热重载。
- **Telegram** —— 粘一个 [@BotFather](https://t.me/BotFather) token，bot 立即 long-poll。回复走 Telegram HTML，带「正在输入」状态和图片/文件双向收发。支持**多 bot**，一个成员一个。

然后成员自己接入：每个成员有一个 `/bind <绑定码>`（在 `/manage/groups` 显示），发给共享 bot，这个聊天账号就绑到他名下。绑定后成员之间可以互相寻址——「通知老张 …」——Agent 会推送到该成员接入的每个通道，并用**他的**语言（见上文 i18n）。出站永远精确路由回这条聊天到达的那个账号。

## CLI 工具

| 命令 | 用途 |
|---|---|
| `mix phx.server` | 启动 web 服务（默认端口 4000） |
| `mix long.skill list / reindex / remove NAME` | Skill 索引管理 |
| `mix long.wechat.login` | WeChat 扫码登录 + buf 持久化 |
| `iex -S mix` | REPL：`Long.Agent.list_sessions()` 等 |
| `mix test` | 测试套件 |
| `mix precommit` | `compile --warnings-as-errors + format + test` |

## 配置

**优先用网页配置，而不是改文件。** 几乎所有东西——LLM、搜索 provider、通道、定时任务、记忆、密钥——都存在 DB 里，在 `/manage` 编辑。日常改动不需要重新发布配置文件。

唯一的文件级配置是几个文件系统根路径，在 `config/config.exs` 的 `:long, Long.Agent` 下（安装版的 release 改从 `~/.long/env` 读）：

```elixir
config :long, Long.Agent,
  memory_root: "priv/agent/memory",      # 历史 GenericAgent 兼容路径
  skill_root:  "priv/agent/skills",      # L3 Skill 目录(SKILL.md 在这里)
  workspace_root: "priv/agent/workspace" # code_run / file_* 工具的根
```

其它一切都是 `/manage` 里的一个页面（或者你愿意的话，IEx 调用 `Long.Agent.register_llm/1` 之类）。

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

**Beta — 小型多用户。** 作为一个家庭 / 小工作组的日常 AI 助手运行（几个成员，局域网里一台机器）。

- 按**组 + 成员**做多租户——per-member 代码工作区、个人/共享技能、逐通道绑定——但**还没有硬性鉴权/RBAC**：成员是受信任的，`bash` 不沙箱（只有 Deno 引擎按成员沙箱）。适合家庭/团队；不适合不受信任的成员或公网暴露。
- schema 偶尔会变化，没承诺向后兼容
- 部分功能（mixin LLM、WeChat / Telegram 全链路）测试覆盖率较低
- 部署文档目前只跑 single-node

欢迎 issue 报问题、PR 提改进，但目前没有承诺的发布节奏。

## Roadmap

短期：

- [x] 多用户：组 + 成员（per-member 工作区、个人/共享技能、通道绑定）
- [ ] 组级 RBAC —— 成员角色在数据层强制（面向工作组 / 半信任成员）
- [ ] 整合双 ReAct loop + 工具族（退役遗留的 `Long.Agent.Loop` / `Long.Agent.Tools`）
- [ ] 给 Deno / Obscura 下载钉版本 + SHA256 校验（供应链）

中长期：

- [ ] PubSub 重连补发 —— 缓存最近的 turn 事件，重连的客户端不丢中途输出
- [ ] 时区感知的定时任务（目前 UTC-only）
- [ ] 观测面板 —— 工具错误率、LLM 重试、Deno / Obscura 安装状态

Backlog（nice-to-have，不算 roadmap）：

- `/manage` 表单改用框架组件（Mishka `<.text_field>` / AshPhoenix.Form），替换手写 `<input>`

## 致谢

- Python 版 [GenericAgent](https://github.com/lsdefine/GenericAgent) 是最初的起点
- [Ash Framework](https://ash-hq.org) 让数据 + 域逻辑可以一起描述
- [ReqLLM](https://hexdocs.pm/req_llm/) 让接入新 LLM provider 只需要一行 alias
- [Mishka Chelekom](https://mishka.tools/chelekom/) 提供了完整的 LiveView 组件库
- [Anthropic Agent Skills](https://github.com/anthropics/skills) 定义了 SKILL.md 格式
- [Obscura](https://github.com/h4ckf0r0day/obscura) 把 Chromium fork 成了一个干净的 CLI

## License

MIT — 见 [LICENSE](LICENSE)。
