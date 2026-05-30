#!/usr/bin/env bash
# XHTTP Installer - fast relay mode
# Keeps Vercel/Netlify relay. Vercel uses REST API; Netlify uses Git/manual deploy files.
set -euo pipefail

LOG_FILE="/tmp/xhttp-relay-fast-install.log"
STATE_DIR="/etc/xhttp-installer"
STATE_FILE="${STATE_DIR}/info.env"
XRAY_CFG="/usr/local/etc/xray/config.json"
WORK_DIR="${XHTTP_WORK_DIR:-/opt/xhttp-relay-fast}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo ".")"
TEMPLATE_DIR="${SCRIPT_DIR}/relay-templates"

exec > >(tee -a "$LOG_FILE") 2>&1

C_RESET="\033[0m"; C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"; C_GRAY="\033[0;90m"; C_WHITE="\033[1;37m"

step() { echo -e "\n${C_CYAN}>> $1${C_RESET}"; }
ok() { echo -e "${C_GREEN}   OK${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}   WARN${C_RESET} $1"; }
fail() { echo -e "${C_RED}   FAIL${C_RESET} $1"; exit 1; }
info() { echo -e "${C_GRAY}   $1${C_RESET}"; }

confirm_uninstall() {
  if [[ "${XHTTP_FORCE_UNINSTALL:-0}" == "1" ]]; then
    return 0
  fi
  local answer
  echo -ne "${C_YELLOW}This will remove Xray, xhttp command, configs, logs, certificates, and installer files. Continue? [y/N]: ${C_RESET}"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || fail "Uninstall cancelled"
}

uninstall_xhttp() {
  echo -e "${C_CYAN}XHTTP Installer - Uninstall${C_RESET}"
  require_root
  confirm_uninstall

  step "Stop services"
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  step "Remove systemd units"
  rm -f /etc/systemd/system/xray.service
  rm -rf /etc/systemd/system/xray.service.d
  systemctl daemon-reload

  step "Remove binaries and commands"
  rm -f /usr/local/bin/xray
  rm -f /usr/local/bin/xhttp

  step "Remove configuration, logs, certificates, and work directories"
  rm -rf /usr/local/etc/xray
  rm -rf /var/log/xray
  rm -rf /etc/xhttp-installer
  rm -rf /opt/xhttp-installer
  rm -rf /opt/xhttp-relay-fast
  rm -rf /etc/ssl/xhttp
  rm -rf /root/.acme.sh

  if [[ -f /swapfile-xhttp ]]; then
    step "Remove optional swapfile"
    swapoff /swapfile-xhttp 2>/dev/null || true
    sed -i '\|/swapfile-xhttp|d' /etc/fstab 2>/dev/null || true
    rm -f /swapfile-xhttp
  fi

  ok "Uninstall complete"
  warn "Vercel/Netlify/GitHub relay projects are not removed from provider dashboards."
}

read_default() {
  local prompt="$1" default="$2" value
  read -rp "$(echo -e "${C_WHITE}${prompt}${C_RESET} ${C_GRAY}[${default}]${C_RESET}: ")" value
  echo "${value:-$default}"
}

read_secret() {
  local prompt="$1" value
  while true; do
    echo -ne "${C_WHITE}${prompt}${C_RESET}: " >&2
    read -rs value
    echo >&2
    [[ -n "${value// }" ]] && { echo "$value"; return; }
    warn "Required."
  done
}

load_previous_state() {
  PREV_MODE=""
  PREV_CFG_PLATFORM=""
  PREV_CFG_DOMAIN=""
  PREV_CFG_DOMAIN_AUTO=""
  PREV_CFG_EMAIL=""
  PREV_CFG_PORT=""
  PREV_CFG_RELAY_PATH=""
  PREV_CFG_PUBLIC_PATH=""
  PREV_CFG_PROJECT_NAME=""
  PREV_RELAY_HOST=""
  PREV_INBOUND_UUID=""
  PREV_VLESS_DECRYPTION=""
  PREV_VLESS_ENCRYPTION=""
  PREV_VLESS_ENC_AUTH=""

  [[ -f "$STATE_FILE" ]] || return 0
  # shellcheck source=/dev/null
  source "$STATE_FILE" || true
  PREV_MODE="${MODE:-}"
  PREV_CFG_PLATFORM="${CFG_PLATFORM:-}"
  PREV_CFG_DOMAIN="${CFG_DOMAIN:-}"
  PREV_CFG_DOMAIN_AUTO="${CFG_DOMAIN_AUTO:-}"
  PREV_CFG_EMAIL="${CFG_EMAIL:-}"
  PREV_CFG_PORT="${CFG_INBOUND_PORT:-}"
  PREV_CFG_RELAY_PATH="${CFG_RELAY_PATH:-}"
  PREV_CFG_PUBLIC_PATH="${CFG_PUBLIC_PATH:-}"
  PREV_CFG_PROJECT_NAME="${CFG_PROJECT_NAME:-}"
  PREV_RELAY_HOST="${RELAY_HOST:-}"
  PREV_INBOUND_UUID="${INBOUND_UUID:-}"
  PREV_VLESS_DECRYPTION="${VLESS_DECRYPTION:-}"
  PREV_VLESS_ENCRYPTION="${VLESS_ENCRYPTION:-}"
  PREV_VLESS_ENC_AUTH="${VLESS_ENC_AUTH:-}"
  if [[ -n "$PREV_CFG_DOMAIN" || -n "$PREV_CFG_PLATFORM" ]]; then
    ok "Loaded previous config from $STATE_FILE"
  fi
}

json_escape() {
  jq -Rn --arg v "$1" '$v'
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

sed_escape_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

render_template_file() {
  local file="$1" target_json public_json relay_json public_plain
  target_json="$(sed_escape_replacement "$(json_escape "https://${CFG_DOMAIN}:${CFG_PORT}")")"
  public_json="$(sed_escape_replacement "$(json_escape "$CFG_PUBLIC_PATH")")"
  relay_json="$(sed_escape_replacement "$(json_escape "$CFG_RELAY_PATH")")"
  public_plain="$(sed_escape_replacement "$CFG_PUBLIC_PATH")"

  sed -i \
    -e "s/__TARGET_BASE_JSON__/${target_json}/g" \
    -e "s/__PUBLIC_PATH_JSON__/${public_json}/g" \
    -e "s/__RELAY_PATH_JSON__/${relay_json}/g" \
    -e "s/__PUBLIC_PATH__/${public_plain}/g" \
    "$file"
}

render_template_tree() {
  local dir="$1"
  while IFS= read -r file; do
    render_template_file "$file"
  done < <(find "$dir" -type f)
}

normalize_path() {
  local value="$1"
  [[ "$value" == /* ]] || value="/$value"
  [[ "$value" != "/" ]] || fail "Path cannot be /"
  echo "$value"
}

random_xhttp_path() {
  local prefix="$1"
  printf '/%s-%s-%s' "$prefix" "$(openssl rand -hex 4)" "$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 18)"
}

uuid_v4() {
  cat /proc/sys/kernel/random/uuid
}

is_uuid_v4() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

sanitize_domain() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  value="${value%.}"
  echo "$value" | tr '[:upper:]' '[:lower:]'
}

public_ipv4() {
  local ip
  ip="$(curl -4 -fsS --max-time 6 https://api4.ipify.org 2>/dev/null || true)"
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  echo "$ip"
}

auto_upstream_domain() {
  local ip
  ip="$(public_ipv4)" || fail "Cannot detect this server public IPv4 for auto domain"
  echo "${ip}.sslip.io"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash Deploy-Relay-Fast.sh"
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

install_base_packages() {
  step "Install minimal dependencies"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates openssl socat lsof jq dnsutils uuid-runtime zip unzip
  ok "Base dependencies installed"
}

xray_local_version() {
  command -v xray >/dev/null 2>&1 || return 1
  xray version 2>/dev/null | awk 'NR==1 {print $2}'
}

normalize_version() {
  local value="$1"
  value="${value#v}"
  value="${value#V}"
  echo "$value"
}

xray_latest_official_version() {
  local tag
  tag="$(curl -fsSL --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | jq -r '.tag_name // empty' 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    tag="$(curl -fsSIL -o /dev/null -w '%{url_effective}' --max-time 10 \
      https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null \
      | awk -F/ '{print $NF}' || true)"
  fi
  [[ -n "$tag" ]] || return 1
  echo "$tag"
}

install_xray() {
  step "Install Xray"

  local requested="${XHTTP_XRAY_VERSION:-latest}"
  local local_version="" official_version="" target_version="" install_version_arg=()

  local_version="$(xray_local_version || true)"

  case "$requested" in
    keep)
      [[ -n "$local_version" ]] || fail "XHTTP_XRAY_VERSION=keep was set, but xray is not installed"
      XRAY_OFFICIAL_VERSION=""
      XRAY_INSTALLED_VERSION="$local_version"
      ok "Keeping installed Xray: $(xray version | head -1)"
      return 0
      ;;
    latest|"")
      official_version="$(xray_latest_official_version || true)"
      [[ -n "$official_version" ]] || warn "Could not query official Xray latest release; falling back to official installer default"
      target_version="$official_version"
      ;;
    v*|V*|[0-9]*)
      target_version="$requested"
      install_version_arg=(--version "$requested")
      ;;
    *)
      fail "Invalid XHTTP_XRAY_VERSION: $requested (use latest, keep, or vX.Y.Z)"
      ;;
  esac

  XRAY_OFFICIAL_VERSION="$official_version"

  if [[ -n "$local_version" && -n "$target_version" ]]; then
    if [[ "$(normalize_version "$local_version")" == "$(normalize_version "$target_version")" ]]; then
      XRAY_INSTALLED_VERSION="$local_version"
      ok "Xray is synced with requested version: $(xray version | head -1)"
      return 0
    fi
    warn "Xray version mismatch: local=${local_version}, target=${target_version}; updating"
  elif [[ -n "$local_version" && -z "$target_version" && "$requested" == "latest" ]]; then
    ok "Xray already installed: $(xray version | head -1)"
    return 0
  fi

  if [[ "$requested" == "latest" || -z "$requested" ]]; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  else
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install "${install_version_arg[@]}"
  fi
  command -v xray >/dev/null 2>&1 || fail "Xray install failed"
  XRAY_INSTALLED_VERSION="$(xray_local_version || true)"
  ok "Xray installed: $(xray version | head -1)"
  [[ -n "${XRAY_OFFICIAL_VERSION:-}" ]] && ok "Official latest release: ${XRAY_OFFICIAL_VERSION}"
  return 0
}

collect_config() {
  step "Collect config"
  local random_relay_path random_public_path domain_default domain_input uuid_default
  random_relay_path="$(random_xhttp_path "relay")"
  random_public_path="$(random_xhttp_path "edge")"
  while [[ "$random_public_path" == "$random_relay_path" ]]; do
    random_public_path="$(random_xhttp_path "edge")"
  done

  echo "Choose relay platform:"
  echo "  1) Vercel"
  echo "  2) Netlify"
  local choice platform_default
  case "${PREV_CFG_PLATFORM:-}" in
    vercel) platform_default="1" ;;
    netlify) platform_default="2" ;;
    *) platform_default="1" ;;
  esac
  choice="$(read_default "Platform" "$platform_default")"
  case "$choice" in
    1|vercel|Vercel) CFG_PLATFORM="vercel" ;;
    2|netlify|Netlify) CFG_PLATFORM="netlify" ;;
    *) fail "Invalid platform: $choice" ;;
  esac

  CFG_DOMAIN="${XHTTP_DOMAIN:-}"
  CFG_EMAIL="${XHTTP_EMAIL:-${PREV_CFG_EMAIL:-}}"
  CFG_PORT="${XHTTP_PORT:-${PREV_CFG_PORT:-443}}"
  CFG_RELAY_PATH="${XHTTP_PATH:-${PREV_CFG_RELAY_PATH:-$random_relay_path}}"
  CFG_PUBLIC_PATH="${XHTTP_PUBLIC_PATH:-${PREV_CFG_PUBLIC_PATH:-$random_public_path}}"
  CFG_PROJECT_NAME="${XHTTP_PROJECT_NAME:-${PREV_CFG_PROJECT_NAME:-netfix-$(openssl rand -hex 3)}}"
  CFG_RELAY_HOST="${XHTTP_RELAY_HOST:-${PREV_RELAY_HOST:-}}"
  CFG_UUID="${XHTTP_UUID:-${PREV_INBOUND_UUID:-}}"

  if [[ -z "$CFG_DOMAIN" ]]; then
    if [[ -n "${PREV_CFG_DOMAIN:-}" && "${PREV_CFG_DOMAIN_AUTO:-false}" != "true" ]]; then
      domain_default="$PREV_CFG_DOMAIN"
    else
      domain_default="auto"
    fi
    domain_input="$(read_default "VPS upstream domain (auto or own domain)" "$domain_default")"
  else
    domain_input="$CFG_DOMAIN"
  fi
  domain_input="$(sanitize_domain "$domain_input")"
  if [[ -z "$domain_input" || "$domain_input" == "auto" ]]; then
    CFG_DOMAIN="$(auto_upstream_domain)"
    CFG_DOMAIN_AUTO="true"
  else
    CFG_DOMAIN="$domain_input"
    CFG_DOMAIN_AUTO="false"
  fi
  [[ -n "$CFG_EMAIL" ]] || CFG_EMAIL="$(read_default "Email for Let's Encrypt" "admin@example.com")"
  CFG_PORT="$(read_default "Xray listen port" "$CFG_PORT")"
  CFG_RELAY_PATH="$(normalize_path "$(read_default "Server XHTTP path" "$CFG_RELAY_PATH")")"
  CFG_PUBLIC_PATH="$(normalize_path "$(read_default "Relay public path" "$CFG_PUBLIC_PATH")")"
  [[ "$CFG_RELAY_PATH" != "$CFG_PUBLIC_PATH" ]] || fail "Server XHTTP path and Relay public path must be different"
  if [[ -z "${XHTTP_UUID:-}" ]]; then
    uuid_default="${CFG_UUID:-$(uuid_v4)}"
    CFG_UUID="$(read_default "UUID v4" "$uuid_default")"
  fi
  CFG_UUID="$(echo "$CFG_UUID" | tr '[:upper:]' '[:lower:]')"
  is_uuid_v4 "$CFG_UUID" || fail "UUID must be standard UUID v4 format"
  CFG_PROJECT_NAME="$(read_default "Relay project name" "$CFG_PROJECT_NAME")"
  if [[ "$CFG_PLATFORM" == "netlify" ]]; then
    CFG_RELAY_HOST="$(sanitize_domain "$(read_default "Netlify site domain after Git deploy, or leave placeholder" "${CFG_RELAY_HOST:-xhttp-git-xxxxxx.netlify.app}")")"
  elif [[ -n "${XHTTP_RELAY_HOST:-}" ]]; then
    CFG_RELAY_HOST="$(sanitize_domain "$XHTTP_RELAY_HOST")"
  fi

  [[ "$CFG_DOMAIN" != "xhttp.example.com" ]] || fail "Please enter your real domain, or use auto"

  if [[ "$CFG_PLATFORM" == "vercel" ]]; then
    CFG_TOKEN="${VERCEL_TOKEN:-}"
    [[ -n "$CFG_TOKEN" ]] || CFG_TOKEN="$(read_secret "Vercel token")"
  fi

  ok "Platform: $CFG_PLATFORM"
  ok "Domain: $CFG_DOMAIN"
  [[ "${CFG_DOMAIN_AUTO:-false}" == "true" ]] && ok "Domain mode: auto (no own domain required)"
  ok "Server path: $CFG_RELAY_PATH"
  ok "Public path: $CFG_PUBLIC_PATH"
  ok "UUID: $CFG_UUID"
  [[ "$CFG_PLATFORM" == "netlify" ]] && ok "Netlify host: $CFG_RELAY_HOST"
  [[ "$CFG_PLATFORM" == "vercel" && -n "${CFG_RELAY_HOST:-}" ]] && ok "Vercel client host override: $CFG_RELAY_HOST"
  return 0
}

configure_xhttp_tuning() {
  XPADDING="100-1000"
  XPADDING_OBFS="false"
  XPADDING_KEY=""
  XPADDING_HEADER=""
  SC_MAX_POST_BYTES=""

  if [[ "${CFG_PLATFORM:-}" == "netlify" ]]; then
    XPADDING="10-50"
    XPADDING_OBFS="true"
    SC_MAX_POST_BYTES="1000000"
    XPADDING_KEY="$(LC_ALL=C tr -dc 'a-z' </dev/urandom 2>/dev/null | head -c 7 || true)"
    XPADDING_HEADER="$(LC_ALL=C tr -dc 'A-Za-z' </dev/urandom 2>/dev/null | head -c 7 || true)"
    [[ -n "$XPADDING_KEY" ]] || XPADDING_KEY="k$(printf '%06d' "$RANDOM")"
    [[ -n "$XPADDING_HEADER" ]] || XPADDING_HEADER="H$(printf '%06d' "$RANDOM")"
    ok "Netlify XHTTP obfuscation enabled"
    info "xPaddingKey: ${XPADDING_KEY}"
    info "xPaddingHeader: ${XPADDING_HEADER}"
  fi
  return 0
}

configure_vless_encryption() {
  step "Configure VLESS Encryption"
  local mode="${XHTTP_VLESS_ENCRYPTION:-auto}" auth="${XHTTP_VLESS_ENC_AUTH:-${PREV_VLESS_ENC_AUTH:-x25519}}"
  local section output

  case "$mode" in
    none|off|false|0)
      VLESS_DECRYPTION="none"
      VLESS_ENCRYPTION="none"
      VLESS_ENC_AUTH="none"
      ok "VLESS Encryption disabled"
      return 0
      ;;
  esac

  case "$auth" in
    x25519|X25519) section="X25519"; VLESS_ENC_AUTH="x25519" ;;
    mlkem768|ML-KEM-768|mlkem|pq) section="ML-KEM-768"; VLESS_ENC_AUTH="mlkem768" ;;
    *) fail "Invalid XHTTP_VLESS_ENC_AUTH: $auth (use x25519 or mlkem768)" ;;
  esac

  VLESS_DECRYPTION="${XHTTP_VLESS_DECRYPTION:-${PREV_VLESS_DECRYPTION:-}}"
  VLESS_ENCRYPTION="${XHTTP_VLESS_ENCRYPTION_CLIENT:-${PREV_VLESS_ENCRYPTION:-}}"

  if [[ -z "$VLESS_DECRYPTION" || -z "$VLESS_ENCRYPTION" || "${PREV_VLESS_ENC_AUTH:-}" != "$VLESS_ENC_AUTH" ]]; then
    command -v xray >/dev/null 2>&1 || fail "xray is required to generate VLESS Encryption"
    output="$(xray vlessenc)"
    VLESS_DECRYPTION="$(printf '%s\n' "$output" | awk -F'"' -v section="$section" '$0 ~ "Authentication: " section {flag=1; next} flag && /"decryption":/ {print $4; exit}')"
    VLESS_ENCRYPTION="$(printf '%s\n' "$output" | awk -F'"' -v section="$section" '$0 ~ "Authentication: " section {flag=1; next} flag && /"encryption":/ {print $4; exit}')"
  fi

  [[ -n "$VLESS_DECRYPTION" && -n "$VLESS_ENCRYPTION" ]] || fail "Failed to generate VLESS Encryption values"
  ok "VLESS Encryption enabled: $VLESS_ENC_AUTH"
  return 0
}

check_dns() {
  step "Check DNS"
  local server_ip domain_ip raw_dns

  if [[ "${XHTTP_SKIP_DNS_CHECK:-0}" == "1" ]]; then
    warn "Skipping DNS preflight because XHTTP_SKIP_DNS_CHECK=1"
    return 0
  fi

  server_ip="$(public_ipv4 2>/dev/null || true)"
  raw_dns="$(
    {
      dig +short "$CFG_DOMAIN" A 2>/dev/null || true
      dig +short @1.1.1.1 "$CFG_DOMAIN" A 2>/dev/null || true
      dig +short @8.8.8.8 "$CFG_DOMAIN" A 2>/dev/null || true
    } | awk 'NF && !seen[$0]++'
  )"
  domain_ip="$(echo "$raw_dns" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 || true)"
  if [[ -z "$domain_ip" ]]; then
    warn "Raw DNS answer for ${CFG_DOMAIN}:"
    if [[ -n "$raw_dns" ]]; then
      echo "$raw_dns" | sed 's/^/     /'
    else
      warn "No answer from system resolver, 1.1.1.1, or 8.8.8.8"
    fi
    fail "No IPv4 A record found for ${CFG_DOMAIN}. If DNS is correct but this VPS resolver is blocked/stale, rerun with XHTTP_SKIP_DNS_CHECK=1."
  fi
  info "$CFG_DOMAIN -> $domain_ip"
  [[ -n "$server_ip" ]] && info "This server public IPv4 -> $server_ip"
  if [[ -n "$server_ip" && "$domain_ip" != "$server_ip" ]]; then
    warn "DNS does not match this server IP. Certificate issuance may fail."
    warn "Fix DNS A record: ${CFG_DOMAIN} -> ${server_ip}"
  fi
  return 0
}

open_firewall_if_needed() {
  step "Firewall"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow "${CFG_PORT}/tcp" >/dev/null 2>&1 || true
    ok "UFW rules added: 22, 80, $CFG_PORT"
  else
    ok "UFW is not active; skipped"
  fi
}

stop_port_80_services() {
  for svc in nginx apache2 caddy haproxy; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl stop "$svc" || true
      warn "Stopped $svc to free port 80"
    fi
  done
}

install_acme_and_cert() {
  step "Issue TLS certificate"
  SSL_DIR="/etc/ssl/xhttp/${CFG_DOMAIN}"
  SSL_CERT="${SSL_DIR}/fullchain.pem"
  SSL_KEY="${SSL_DIR}/privkey.pem"
  mkdir -p "$SSL_DIR"

  local acme="${HOME}/.acme.sh/acme.sh"
  if [[ ! -x "$acme" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="$CFG_EMAIL"
  fi
  acme="${HOME}/.acme.sh/acme.sh"
  [[ -x "$acme" ]] || fail "acme.sh install failed"

  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  stop_port_80_services

  if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
    "$acme" --issue --standalone -d "$CFG_DOMAIN" --keylength ec-256 --force
  else
    ok "Existing certificate found"
  fi

  "$acme" --installcert -d "$CFG_DOMAIN" --ecc \
    --cert-file "${SSL_DIR}/cert.pem" \
    --key-file "$SSL_KEY" \
    --fullchain-file "$SSL_CERT" \
    --reloadcmd "systemctl restart xray 2>/dev/null || true"

  chmod 644 "$SSL_CERT" 2>/dev/null || true
  chmod 640 "$SSL_KEY" 2>/dev/null || true
  chgrp root "$SSL_KEY" 2>/dev/null || true
  ok "Certificate installed: $SSL_CERT"
}

configure_xray() {
  step "Configure Xray"
  mkdir -p "$(dirname "$XRAY_CFG")" /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  chmod 755 /var/log/xray
  chmod 666 /var/log/xray/access.log /var/log/xray/error.log

  INBOUND_UUID="$CFG_UUID"
  [[ -f "$XRAY_CFG" ]] && cp "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%Y%m%d%H%M%S)" || true

  cat > "$XRAY_CFG" <<JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": ["geoip:cn"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": ["geosite:cn"],
        "outboundTag": "blocked"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "xhttp-in",
      "listen": "0.0.0.0",
      "port": ${CFG_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${INBOUND_UUID}", "flow": "" }],
        "decryption": "${VLESS_DECRYPTION}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2", "http/1.1"],
          "certificates": [
            { "certificateFile": "${SSL_CERT}", "keyFile": "${SSL_KEY}" }
          ]
        },
        "xhttpSettings": {
          "path": "${CFG_RELAY_PATH}",
          "host": "${CFG_DOMAIN}",
          "mode": "auto",
          "xPaddingBytes": "${XPADDING}"$(if [[ "${XPADDING_OBFS}" == "true" ]]; then printf ',
          "xPaddingObfsMode": true,
          "xPaddingKey": "%s",
          "xPaddingHeader": "%s",
          "scMaxEachPostBytes": "%s"' "$XPADDING_KEY" "$XPADDING_HEADER" "$SC_MAX_POST_BYTES"; fi)
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
JSON

  xray -test -config "$XRAY_CFG"
  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/override.conf <<'OVERRIDE'
[Service]
User=root
Group=root
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=false
OVERRIDE
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray || {
    journalctl -u xray -n 30 --no-pager || true
    fail "Xray failed to start"
  }
  ok "Xray running on port $CFG_PORT"
}

write_vercel_project() {
  local src="${TEMPLATE_DIR}/vercel"
  [[ -d "$src" ]] || fail "Missing template directory: $src"
  mkdir -p "$WORK_DIR"
  cp -R "$src" "$WORK_DIR/vercel"
  render_template_tree "$WORK_DIR/vercel"
}

deploy_vercel() {
  step "Deploy Vercel relay via REST API"
  rm -rf "$WORK_DIR"
  write_vercel_project

  local api_js pkg vercel_json payload response url
  api_js="$(jq -Rs . < "$WORK_DIR/vercel/api/index.js")"
  pkg="$(jq -Rs . < "$WORK_DIR/vercel/package.json")"
  vercel_json="$(jq -Rs . < "$WORK_DIR/vercel/vercel.json")"

  payload="$(cat <<JSON
{
  "name": "${CFG_PROJECT_NAME}",
  "target": "production",
  "projectSettings": { "framework": null },
  "files": [
    { "file": "api/index.js", "data": ${api_js}, "encoding": "utf-8" },
    { "file": "package.json", "data": ${pkg}, "encoding": "utf-8" },
    { "file": "vercel.json", "data": ${vercel_json}, "encoding": "utf-8" }
  ]
}
JSON
)"

  response="$(curl -fsS -X POST "https://api.vercel.com/v13/deployments" \
    -H "Authorization: Bearer ${CFG_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload")" || fail "Vercel deployment API failed"

  url="$(echo "$response" | jq -r '.url // empty')"
  [[ -n "$url" ]] || { echo "$response"; fail "Vercel did not return deployment URL"; }
  VERCEL_DEPLOY_HOST="$url"
  VERCEL_DEPLOY_URL="https://${url}"
  if [[ -n "${CFG_RELAY_HOST:-}" ]]; then
    RELAY_HOST="$CFG_RELAY_HOST"
    VERCEL_URL="https://${CFG_RELAY_HOST}"
    ok "Vercel relay deployed: ${VERCEL_DEPLOY_URL}"
    ok "Client relay host: ${RELAY_HOST}"
  else
    RELAY_HOST="$url"
    VERCEL_URL="https://${url}"
    ok "Vercel relay deployed: $VERCEL_URL"
  fi
}

write_netlify_project() {
  local src="${TEMPLATE_DIR}/netlify"
  [[ -d "$src" ]] || fail "Missing template directory: $src"
  mkdir -p "$WORK_DIR"
  cp -R "$src" "$WORK_DIR/netlify"
  render_template_tree "$WORK_DIR/netlify"
}

deploy_netlify() {
  step "Prepare Netlify relay for Git/manual deploy"
  rm -rf "$WORK_DIR"
  write_netlify_project

  local zip_path="${WORK_DIR}/netlify-relay.zip"
  (cd "$WORK_DIR/netlify" && zip -qr "$zip_path" .)

  RELAY_HOST="$CFG_RELAY_HOST"
  VERCEL_URL="https://${RELAY_HOST}"
  NETLIFY_PROJECT_DIR="${WORK_DIR}/netlify"
  NETLIFY_PROJECT_ZIP="$zip_path"

  ok "Netlify relay files generated: ${NETLIFY_PROJECT_DIR}"
  ok "Netlify relay zip generated: ${NETLIFY_PROJECT_ZIP}"
  warn "No Netlify CLI is used on this VPS."
  info "Deploy ${NETLIFY_PROJECT_DIR} from GitHub/Netlify UI, then make sure the Netlify site domain is: ${RELAY_HOST}"
}

deploy_relay() {
  if [[ "$CFG_PLATFORM" == "vercel" ]]; then
    deploy_vercel
  else
    deploy_netlify
  fi
}

build_client_link() {
  local encoded_path encoded_extra encoded_vless_encryption extra_json tag
  encoded_path="$(urlencode "$CFG_PUBLIC_PATH")"
  encoded_vless_encryption="$(urlencode "${VLESS_ENCRYPTION:-none}")"
  if [[ "${CFG_PLATFORM:-}" == "netlify" ]]; then
    extra_json="$(jq -cn \
      --arg pad "${XPADDING:-10-50}" \
      --arg key "${XPADDING_KEY:-}" \
      --arg header "${XPADDING_HEADER:-}" \
      --arg maxPost "${SC_MAX_POST_BYTES:-1000000}" \
      '{xPaddingBytes:$pad,xPaddingObfsMode:true,xPaddingKey:$key,xPaddingHeader:$header,scMaxEachPostBytes:$maxPost}')"
  else
    extra_json="$(jq -cn --arg pad "${XPADDING:-100-1000}" '{xPaddingBytes:$pad}')"
  fi
  encoded_extra="$(urlencode "$extra_json")"
  tag="XHTTP-${CFG_PLATFORM}-fast"
  CLIENT_LINK="vless://${INBOUND_UUID}@${RELAY_HOST}:443?encryption=${encoded_vless_encryption}&security=tls&sni=${RELAY_HOST}&fp=chrome&alpn=h2&type=xhttp&host=${RELAY_HOST}&path=${encoded_path}&mode=auto&extra=${encoded_extra}#${tag}"
}

install_panel() {
  step "Install xhttp management command"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  build_client_link

  cat > "$STATE_FILE" <<STATE
INSTALL_DATE="$(date -Iseconds)"
MODE="fast-relay"
STATE_INSTALLER="${SCRIPT_DIR}/Deploy-Relay-Fast.sh"
CFG_PLATFORM="${CFG_PLATFORM}"
CFG_DOMAIN="${CFG_DOMAIN}"
CFG_DOMAIN_AUTO="${CFG_DOMAIN_AUTO:-false}"
CFG_EMAIL="${CFG_EMAIL}"
CFG_INBOUND_PORT="${CFG_PORT}"
CFG_RELAY_PATH="${CFG_RELAY_PATH}"
CFG_PUBLIC_PATH="${CFG_PUBLIC_PATH}"
CFG_PROJECT_NAME="${CFG_PROJECT_NAME}"
INBOUND_UUID="${INBOUND_UUID}"
XRAY_INSTALLED_VERSION="${XRAY_INSTALLED_VERSION:-}"
XRAY_OFFICIAL_VERSION="${XRAY_OFFICIAL_VERSION:-}"
XPADDING="${XPADDING:-}"
XPADDING_OBFS="${XPADDING_OBFS:-false}"
XPADDING_KEY="${XPADDING_KEY:-}"
XPADDING_HEADER="${XPADDING_HEADER:-}"
SC_MAX_POST_BYTES="${SC_MAX_POST_BYTES:-}"
VLESS_DECRYPTION="${VLESS_DECRYPTION:-none}"
VLESS_ENCRYPTION="${VLESS_ENCRYPTION:-none}"
VLESS_ENC_AUTH="${VLESS_ENC_AUTH:-none}"
RELAY_URL="${VERCEL_URL}"
RELAY_HOST="${RELAY_HOST}"
NETLIFY_PROJECT_DIR="${NETLIFY_PROJECT_DIR:-}"
NETLIFY_PROJECT_ZIP="${NETLIFY_PROJECT_ZIP:-}"
SSL_CERT="${SSL_CERT}"
SSL_KEY="${SSL_KEY}"
CLIENT_LINK="${CLIENT_LINK}"
LOG_FILE="${LOG_FILE}"
STATE
  chmod 600 "$STATE_FILE"

  cat > /usr/local/bin/xhttp <<'PANEL'
#!/usr/bin/env bash
set -u
STATE_FILE="/etc/xhttp-installer/info.env"
[[ -f "$STATE_FILE" ]] || { echo "XHTTP is not installed."; exit 1; }
# shellcheck source=/dev/null
source "$STATE_FILE"

case "${1:-}" in
  status) systemctl status xray --no-pager -n 12 ;;
  link) echo "$CLIENT_LINK" ;;
  logs) journalctl -u xray -n 80 --no-pager ;;
  restart) systemctl restart xray && systemctl status xray --no-pager -n 8 ;;
  uninstall)
    SCRIPT="${STATE_INSTALLER:-/opt/xhttp-installer/Deploy-Relay-Fast.sh}"
    [[ -f "$SCRIPT" ]] || { echo "Installer script not found: $SCRIPT"; exit 1; }
    exec bash "$SCRIPT" uninstall
    ;;
  *)
    echo "XHTTP fast-relay"
    echo "Platform : ${CFG_PLATFORM}"
    echo "Relay    : ${RELAY_URL}"
    [[ -n "${NETLIFY_PROJECT_DIR:-}" ]] && echo "Netlify files: ${NETLIFY_PROJECT_DIR}"
    echo "Domain   : ${CFG_DOMAIN}:${CFG_INBOUND_PORT}"
    [[ "${CFG_DOMAIN_AUTO:-false}" == "true" ]] && echo "Domain mode: auto"
    echo "Path     : ${CFG_RELAY_PATH}"
    echo "VLESS enc: ${VLESS_ENC_AUTH:-none}"
    echo "Xray     : ${XRAY_INSTALLED_VERSION:-unknown}"
    [[ -n "${XRAY_OFFICIAL_VERSION:-}" ]] && echo "Official : ${XRAY_OFFICIAL_VERSION}"
    echo
    echo "$CLIENT_LINK"
    echo
    echo "Commands: xhttp status | xhttp link | xhttp logs | xhttp restart | xhttp uninstall"
    ;;
esac
PANEL
  chmod +x /usr/local/bin/xhttp
  ok "Installed: /usr/local/bin/xhttp"
}

health_check() {
  step "Health check"
  local upstream relay
  upstream="$(curl -sk --max-time 8 -o /dev/null -w "%{http_code}" "https://${CFG_DOMAIN}:${CFG_PORT}${CFG_RELAY_PATH}" 2>/dev/null || echo "000")"
  info "Upstream HTTP: $upstream"
  if [[ "${CFG_PLATFORM:-}" == "netlify" && "$RELAY_HOST" == *xxxxxx* ]]; then
    warn "Relay probe skipped. Deploy the generated Netlify project, then rerun with XHTTP_RELAY_HOST=your-site.netlify.app."
    return 0
  fi
  relay="$(curl -sk --max-time 12 -o /dev/null -w "%{http_code}" "${VERCEL_URL}${CFG_PUBLIC_PATH}" 2>/dev/null || echo "000")"
  info "Relay HTTP: $relay"
  [[ "$relay" != "000" ]] || warn "Relay probe failed. Check platform deployment logs and VPS firewall/security group."
}

summary() {
  build_client_link
  echo
  echo -e "${C_GREEN}============================================================${C_RESET}"
  echo -e "${C_GREEN} XHTTP fast relay installation complete${C_RESET}"
  echo -e "${C_GREEN}============================================================${C_RESET}"
  echo
  echo "Platform : $CFG_PLATFORM"
  echo "Relay    : $VERCEL_URL"
  [[ -n "${NETLIFY_PROJECT_DIR:-}" ]] && echo "Netlify files: ${NETLIFY_PROJECT_DIR}"
  [[ -n "${NETLIFY_PROJECT_ZIP:-}" ]] && echo "Netlify zip  : ${NETLIFY_PROJECT_ZIP}"
  echo "Upstream : https://${CFG_DOMAIN}:${CFG_PORT}${CFG_RELAY_PATH}"
  echo "VLESS enc: ${VLESS_ENC_AUTH:-none}"
  echo "Xray     : ${XRAY_INSTALLED_VERSION:-unknown}"
  [[ -n "${XRAY_OFFICIAL_VERSION:-}" ]] && echo "Official : ${XRAY_OFFICIAL_VERSION}"
  echo
  echo "Client link:"
  echo "$CLIENT_LINK"
  echo
  echo "Manage: xhttp"
  echo "Log   : $LOG_FILE"
  if [[ "${CFG_PLATFORM:-}" == "netlify" ]]; then
    echo
    echo "Netlify deploy without CLI:"
    echo "1. Upload/push the generated Netlify files to a GitHub repo."
    echo "2. In Netlify, import that GitHub repo and deploy from branch main."
    echo "3. If the Netlify domain changes, rerun with XHTTP_RELAY_HOST=your-site.netlify.app."
  fi
}

main() {
  echo -e "${C_CYAN}XHTTP Installer - Fast Relay Mode${C_RESET}"
  echo "Keeps Vercel/Netlify relay. Netlify path does not install Node.js, npm, or Netlify CLI."
  require_root
  load_previous_state
  detect_os
  collect_config
  configure_xhttp_tuning
  install_base_packages
  check_dns
  open_firewall_if_needed
  install_xray
  configure_vless_encryption
  install_acme_and_cert
  configure_xray
  deploy_relay
  install_panel
  health_check
  summary
}

case "${1:-}" in
  uninstall|--uninstall)
    uninstall_xhttp
    ;;
  *)
    main "$@"
    ;;
esac
