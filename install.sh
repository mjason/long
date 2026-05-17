#!/bin/bash
# Long installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/long/main/install.sh | bash
#
# Pulls the release tarball matching this host's OS/arch from GitHub
# Releases, extracts it to $LONG_INSTALL_DIR (default ~/.long), creates
# an env file + `run` launcher, and installs `uv` if missing.
#
# Env vars:
#   LONG_INSTALL_DIR  install target  (default $HOME/.long)
#   LONG_VERSION      pin a specific release  (default: latest)
set -euo pipefail

INSTALL_DIR="${LONG_INSTALL_DIR:-$HOME/.long}"
REPO="mjason/long"

info()  { echo "==> $*"; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

# ── deps ─────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

if have curl;  then DL="curl -fsSL"
elif have wget; then DL="wget -qO-"
else error "需要 curl 或 wget"; fi

# Capability check for whichever downloader is in use.
fetch() { $DL "$1"; }
fetch_to() {
  if [[ "${DL%% *}" == "curl" ]]; then
    curl -fsSL -o "$2" "$1"
  else
    wget -qO "$2" "$1"
  fi
}

# ── platform detection ──────────────────────────────────────────────────
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  darwin)
    [[ "$ARCH" == "arm64" ]] || error "目前 macOS 仅提供 arm64 (Apple Silicon) 版本"
    TARGET="macos-arm64"
    ;;
  linux)
    case "$ARCH" in
      x86_64)        TARGET="linux-x64" ;;
      aarch64|arm64) TARGET="linux-arm64" ;;
      *) error "不支持的 Linux 架构: $ARCH" ;;
    esac
    ;;
  *) error "不支持的操作系统: $OS" ;;
esac

info "检测到平台: $TARGET"

# ── resolve version ─────────────────────────────────────────────────────
TAG="${LONG_VERSION:-}"
if [[ -z "$TAG" ]]; then
  info "获取最新版本..."
  TAG=$(fetch "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' \
        || true)
  [[ -n "$TAG" ]] || error "未找到发布版本"
fi

VERSION=${TAG#v}
TARBALL="long-${VERSION}-${TARGET}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"

info "下载 ${TAG} → ${TARBALL}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
fetch_to "$URL" "${TMPDIR}/${TARBALL}" || error "下载失败: $URL"

# ── extract ─────────────────────────────────────────────────────────────
info "安装到 ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"

# Wipe previous release files (binaries + libs + erts), keep env / db /
# agent workspace so upgrades preserve user data.
rm -rf "${INSTALL_DIR}"/bin "${INSTALL_DIR}"/lib "${INSTALL_DIR}"/releases "${INSTALL_DIR}"/erts-*
tar xzf "${TMPDIR}/${TARBALL}" -C "$INSTALL_DIR" --strip-components=1

# ── ensure uv is installed (needed for `code_run` tool) ─────────────────
if ! have uv; then
  info "未检测到 uv (Python 工具)，自动安装..."
  $DL https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  have uv || warn "uv 安装可能未生效，重启 shell 后再试"
fi

# ── first-run config ────────────────────────────────────────────────────
CONFIG_FILE="${INSTALL_DIR}/env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  if have openssl; then
    SECRET=$(openssl rand -base64 48 | tr -d '\n')
  else
    SECRET=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
  fi

  cat > "$CONFIG_FILE" << ENVEOF
# Long 配置文件 — 编辑后重启 ${INSTALL_DIR}/run 生效

# 数据库路径
DATABASE_PATH=${INSTALL_DIR}/long.db

# 密钥 (自动生成，请保密)
SECRET_KEY_BASE=${SECRET}

# 监听端口 + 主机名
PORT=4000
PHX_HOST=localhost

# Agent 工作区根目录 (uv venv / skills / temp / memory)
LONG_WORKSPACE_ROOT=${INSTALL_DIR}/agent
ENVEOF
  info "已生成配置: ${CONFIG_FILE}"
fi

# ── launcher ────────────────────────────────────────────────────────────
LAUNCHER="${INSTALL_DIR}/run"
cat > "$LAUNCHER" << 'RUNEOF'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: 配置文件不存在: ${ENV_FILE}" >&2; exit 1; }

set -a; source "$ENV_FILE"; set +a

mkdir -p "${LONG_WORKSPACE_ROOT:-${SCRIPT_DIR}/agent}"

# macOS default maxfiles is 256 per process — way too low for a
# BEAM running Bandit + Obscura + Python subprocesses. Bumps to
# 10240, capped at the system hard limit. (Linux default is much
# higher, so this is mostly a no-op there.)
ulimit -n 10240 2>/dev/null || true

# uv installs to ~/.local/bin by default; PATH it for the release process.
export PATH="${HOME}/.local/bin:${PATH}"

export PHX_SERVER=true
exec "${SCRIPT_DIR}/bin/long" start
RUNEOF
chmod +x "$LAUNCHER"

# ── service controller (launchd on macOS, systemd-user on Linux) ────────
SERVICE="${INSTALL_DIR}/service"
cat > "$SERVICE" << 'SVCEOF'
#!/bin/bash
# Long service controller — install/uninstall autostart, start/stop, status.
#
#   ~/.long/service install     enable autostart (writes to OS service mgr)
#   ~/.long/service uninstall   disable autostart (cleans up)
#   ~/.long/service start|stop  one-off control of the running unit
#   ~/.long/service status      is the service registered + running?
#   ~/.long/service logs        tail run.log
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.mjason.long"
RUN="${INSTALL_DIR}/run"
LOG="${INSTALL_DIR}/run.log"

err() { echo "ERROR: $*" >&2; exit 1; }

OS=$(uname -s)
case "$OS" in
  Darwin)
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST="$PLIST_DIR/${LABEL}.plist"
    UID_NUM=$(id -u)
    # `gui/<uid>` requires an active GUI login (Console.app session).
    # Over SSH there is no GUI session, so we use `user/<uid>` for the
    # actual bootstrap. The plist file itself in ~/Library/LaunchAgents/
    # is auto-loaded by launchd on the next GUI login regardless of
    # which domain we bootstrap into now.
    if launchctl print "gui/${UID_NUM}" >/dev/null 2>&1; then
      DOMAIN="gui/${UID_NUM}"
    else
      DOMAIN="user/${UID_NUM}"
    fi

    write_plist() {
      mkdir -p "$PLIST_DIR"
      cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUN}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG}</string>
  <key>StandardErrorPath</key>
  <string>${LOG}</string>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLISTEOF
    }

    case "${1:-status}" in
      install)
        write_plist
        # If something is already loaded under this label, bail out and
        # ask the user to uninstall first — bootstrap fails noisily on a
        # double-load and we don't want to leave a half-state.
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/tmp/.long_launch.err; then
          echo "WARN: launchctl bootstrap 失败:" >&2
          cat /tmp/.long_launch.err >&2
          echo "plist 已写入 ${PLIST}，下次 GUI 登录会自动加载。" >&2
          rm -f /tmp/.long_launch.err
          exit 0
        fi
        rm -f /tmp/.long_launch.err
        echo "==> 已注册开机自启: $PLIST"
        echo "    立即启动: $0 start"
        ;;
      uninstall)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null \
          || launchctl unload "$PLIST" 2>/dev/null \
          || true
        rm -f "$PLIST"
        echo "==> 已取消开机自启 ($PLIST 已删除)"
        ;;
      start)
        [[ -f "$PLIST" ]] || err "服务未注册，先跑 $0 install"
        launchctl kickstart -k "$DOMAIN/$LABEL"
        echo "==> 已启动"
        ;;
      stop)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        echo "==> 已停止 (uninstall 才会移除自启)"
        ;;
      status)
        if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
          launchctl print "$DOMAIN/$LABEL" | grep -E "^\s*(state|pid|program)" | head -5
        else
          echo "未注册 (跑 $0 install 启用)"
        fi
        ;;
      logs) tail -f "$LOG" ;;
      *) err "用法: $0 {install|uninstall|start|stop|status|logs}" ;;
    esac
    ;;

  Linux)
    UNIT="$HOME/.config/systemd/user/long.service"

    write_unit() {
      mkdir -p "$(dirname "$UNIT")"
      cat > "$UNIT" << UNITEOF
[Unit]
Description=Long agent runtime
After=network.target

[Service]
ExecStart=${RUN}
Restart=on-failure
RestartSec=5
WorkingDirectory=${INSTALL_DIR}
StandardOutput=append:${LOG}
StandardError=append:${LOG}

[Install]
WantedBy=default.target
UNITEOF
    }

    case "${1:-status}" in
      install)
        command -v systemctl >/dev/null || err "需要 systemd"
        write_unit
        systemctl --user daemon-reload
        systemctl --user enable --now long.service
        # User services need linger to survive logout / start at boot.
        if command -v loginctl >/dev/null 2>&1; then
          loginctl enable-linger "$USER" 2>/dev/null || true
        fi
        echo "==> 已注册开机自启: $UNIT"
        ;;
      uninstall)
        systemctl --user disable --now long.service 2>/dev/null || true
        rm -f "$UNIT"
        systemctl --user daemon-reload || true
        echo "==> 已取消开机自启 ($UNIT 已删除)"
        ;;
      start)  systemctl --user start  long.service ;;
      stop)   systemctl --user stop   long.service ;;
      status) systemctl --user status long.service --no-pager 2>&1 | head -10 ;;
      logs)   journalctl --user -u long.service -f ;;
      *) err "用法: $0 {install|uninstall|start|stop|status|logs}" ;;
    esac
    ;;

  *) err "不支持的操作系统: $OS" ;;
esac
SVCEOF
chmod +x "$SERVICE"

info "安装完成! ${TAG}"
echo
echo "  配置: \$EDITOR ${CONFIG_FILE}"
echo "  启动: ${LAUNCHER}"
echo "  开机自启: ${SERVICE} install   (uninstall 取消)"
echo "  访问: http://localhost:\${PORT:-4000}"
