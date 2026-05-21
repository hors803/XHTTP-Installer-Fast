#!/usr/bin/env bash
# XHTTP Installer bootstrap
# One-line usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hors803/XHTTP-Installer-Fast/main/install.sh)

set -euo pipefail

REPO_URL="${XHTTP_REPO_URL:-https://github.com/hors803/XHTTP-Installer-Fast.git}"
BRANCH="${XHTTP_BRANCH:-main}"
TARGET_DIR="${XHTTP_TARGET_DIR:-/opt/xhttp-installer}"

C_RESET="\033[0m"
C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"

info() { echo -e "${C_CYAN}>>${C_RESET} $*"; }
ok() { echo -e "${C_GREEN}OK${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}WARN${C_RESET} $*"; }
fail() { echo -e "${C_RED}FAIL${C_RESET} $*"; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash <(curl -fsSL ...)"
}

detect_os() {
  local os_id="" version_id="" major=0 pretty="Linux"
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    major="${version_id%%.*}"
    pretty="${PRETTY_NAME:-${NAME:-Linux}}"
    [[ "$major" =~ ^[0-9]+$ ]] || major=0
  fi

  case "$os_id" in
    ubuntu) (( major >= 20 )) || fail "Ubuntu 20.04+ required, detected: $pretty" ;;
    debian) (( major >= 12 )) || fail "Debian 12+ required, detected: $pretty" ;;
    *) warn "Unsupported OS: $pretty. Continuing best-effort." ;;
  esac
  ok "OS: $pretty"
}

install_bootstrap_deps() {
  info "Installing bootstrap dependencies"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates
  ok "Bootstrap dependencies installed"
}

sync_repo() {
  info "Syncing installer repository"
  if [[ -d "$TARGET_DIR/.git" ]]; then
    git -C "$TARGET_DIR" fetch --depth=1 origin "$BRANCH"
    git -C "$TARGET_DIR" reset --hard "origin/$BRANCH"
  else
    if [[ -e "$TARGET_DIR" ]]; then
      local backup="${TARGET_DIR}.bak.$(date +%Y%m%d%H%M%S)"
      warn "$TARGET_DIR exists and is not a git repository. Moving it to $backup"
      mv "$TARGET_DIR" "$backup"
    fi
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
  fi
  ok "Repository ready: $TARGET_DIR"
}

run_installer() {
  cd "$TARGET_DIR"
  [[ -f Deploy-Relay-Fast.sh ]] || fail "Missing Deploy-Relay-Fast.sh"
  [[ -d relay-templates ]] || fail "Missing relay-templates directory"
  chmod +x Deploy-Relay-Fast.sh
  info "Starting fast relay installer"
  exec bash Deploy-Relay-Fast.sh "$@"
}

main() {
  echo -e "${C_CYAN}XHTTP Installer - One Click Bootstrap${C_RESET}"
  require_root
  detect_os
  install_bootstrap_deps
  sync_repo
  run_installer "$@"
}

main "$@"
