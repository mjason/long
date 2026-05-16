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

# uv installs to ~/.local/bin by default; PATH it for the release process.
export PATH="${HOME}/.local/bin:${PATH}"

export PHX_SERVER=true
exec "${SCRIPT_DIR}/bin/long" start
RUNEOF
chmod +x "$LAUNCHER"

info "安装完成! ${TAG}"
echo
echo "  配置: \$EDITOR ${CONFIG_FILE}"
echo "  启动: ${LAUNCHER}"
echo "  访问: http://localhost:\${PORT:-4000}"
