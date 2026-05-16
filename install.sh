#!/bin/bash
# Long installer.
#
#   gh api "repos/mjason/long/contents/install.sh" --jq '.content' | base64 -d | bash
#
# Pulls the latest release tarball matching this host's OS/arch, extracts
# it to $LONG_INSTALL_DIR (default ~/.long), creates an env file + `run`
# launcher, and installs `uv` if missing.
set -euo pipefail

INSTALL_DIR="${LONG_INSTALL_DIR:-$HOME/.long}"
REPO="mjason/long"

info()  { echo "==> $*"; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

# ── deps ─────────────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || error "需要 gh (GitHub CLI): brew install gh / apt install gh"
gh auth status >/dev/null 2>&1 || error "请先登录: gh auth login"

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
      x86_64) TARGET="linux-x64" ;;
      aarch64|arm64) TARGET="linux-arm64" ;;
      *) error "不支持的 Linux 架构: $ARCH" ;;
    esac
    ;;
  *)
    error "不支持的操作系统: $OS"
    ;;
esac

info "检测到平台: $TARGET"

# ── fetch latest release ────────────────────────────────────────────────
info "获取最新版本..."
TAG=$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null) \
  || error "未找到发布版本"
VERSION=${TAG#v}
TARBALL="long-${VERSION}-${TARGET}.tar.gz"

info "下载 ${TAG} → ${TARBALL}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
gh release download "$TAG" --repo "$REPO" --pattern "$TARBALL" --dir "$TMPDIR" \
  || error "下载失败: $TARBALL"

# ── extract ─────────────────────────────────────────────────────────────
info "安装到 ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"

# Wipe the previous release files (binaries + libs + erts) but keep
# `env`, `long.db`, and the `agent/` workspace so upgrades preserve user data.
rm -rf "${INSTALL_DIR}"/bin "${INSTALL_DIR}"/lib "${INSTALL_DIR}"/releases "${INSTALL_DIR}"/erts-*
tar xzf "${TMPDIR}/${TARBALL}" -C "$INSTALL_DIR" --strip-components=1

# ── ensure uv is installed (needed for `code_run` tool) ─────────────────
if ! command -v uv >/dev/null 2>&1; then
  info "未检测到 uv (Python 工具)，自动安装..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # uv installs to ~/.local/bin; export for current shell so verification works
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || warn "uv 安装可能未生效，重启 shell 后再试"
fi

# ── first-run config ────────────────────────────────────────────────────
CONFIG_FILE="${INSTALL_DIR}/env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  if command -v openssl >/dev/null 2>&1; then
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
