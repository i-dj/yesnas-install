#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_REPO="${YESNAS_INSTALL_REPO:-i-dj/yesnas-install}"
SERVER_SCRIPT="https://raw.githubusercontent.com/i-dj/yesnas-server/main/scripts/install.sh"
WEB_SCRIPT="https://raw.githubusercontent.com/i-dj/yesnas/main/scripts/install.sh"
STATE_DIR="/etc/yesnas-install"
STATE_FILE="${STATE_DIR}/config.env"
CADDY_WAS_INSTALLED=0

log() { printf '\033[1;32m[YesNAS Installer]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[YesNAS Installer][WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[YesNAS Installer][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
run_root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
prompt() { local value=""; [[ -r /dev/tty ]] && read -r -p "$1 [$2]: " value </dev/tty || true; printf '%s\n' "${value:-$2}"; }
pause_for_enter() { [[ -r /dev/tty ]] && read -r -p "Press Enter to begin setup..." </dev/tty || true; printf '\n'; }
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
port_busy() { ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

latest_version() {
  local version
  version="$(curl -fsSL --retry 3 "https://api.github.com/repos/${INSTALL_REPO}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || true
  printf '%s\n' "${version:-unreleased}"
}

show_welcome() {
  local version="$1"
  printf '\033[1;36m'
  cat <<'EOF'
 __   __        _   _    _    ____
 \ \ / /__  ___| \ | |  / \  / ___|
  \ V / _ \/ __|  \| | / _ \ \___ \
   | |  __/\__ \ |\  |/ ___ \ ___) |
   |_|\___||___/_| \_/_/   \_\____/
EOF
  printf '\033[0m\n'
  printf '\033[1;32mWelcome to YesNAS!\033[0m\n'
  printf 'You are about to install YesNAS %s.\n\n' "$version"
}

install_caddy() {
  if ! command -v caddy >/dev/null 2>&1; then
    CADDY_WAS_INSTALLED=1
    log "Installing Caddy..."
    export DEBIAN_FRONTEND=noninteractive
    run_root apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
    local tmp_key tmp_keyring tmp_list
    tmp_key="$(mktemp)"; tmp_keyring="$(mktemp)"; tmp_list="$(mktemp)"
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$tmp_key"
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$tmp_list"
    gpg --dearmor --yes --output "$tmp_keyring" "$tmp_key"
    run_root install -m 0644 "$tmp_keyring" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    run_root install -m 0644 "$tmp_list" /etc/apt/sources.list.d/caddy-stable.list
    rm -f "$tmp_key" "$tmp_keyring" "$tmp_list"
    run_root apt-get update
    run_root apt-get install -y caddy
  fi
}

write_caddy_config() {
  local site="http://${DEVICE_NAME}"
  [[ "$ACCESS_PORT" == 80 ]] || site="${site}:${ACCESS_PORT}"
  run_root mkdir -p /etc/caddy/conf.d
  printf '%s {\n    request_body {\n        max_size 100GB\n    }\n\n    handle /api/* {\n        reverse_proxy 127.0.0.1:28080\n    }\n\n    handle {\n        reverse_proxy 127.0.0.1:23000\n    }\n}\n' "$site" | run_root tee /etc/caddy/conf.d/yesnas.caddy >/dev/null
  if [[ "$CADDY_WAS_INSTALLED" == 1 ]]; then
    printf 'import /etc/caddy/conf.d/*.caddy\n' | run_root tee /etc/caddy/Caddyfile >/dev/null
  else
    run_root touch /etc/caddy/Caddyfile
    grep -Fqx 'import /etc/caddy/conf.d/*.caddy' /etc/caddy/Caddyfile || printf '\nimport /etc/caddy/conf.d/*.caddy\n' | run_root tee -a /etc/caddy/Caddyfile >/dev/null
  fi
  run_root caddy validate --config /etc/caddy/Caddyfile
  run_root systemctl enable --now caddy
  run_root systemctl reload caddy
}

main() {
  command -v curl >/dev/null 2>&1 || fail "curl is required."
  command -v sed >/dev/null 2>&1 || fail "sed is required."
  command -v ss >/dev/null 2>&1 || fail "ss is required (install the iproute2 package)."
  command -v setsid >/dev/null 2>&1 || fail "setsid is required (install the util-linux package)."
  command -v apt-get >/dev/null 2>&1 || fail "Only Debian/Ubuntu systems with apt-get are supported."
  [[ "$EUID" -eq 0 ]] || command -v sudo >/dev/null 2>&1 || fail "sudo is required."

  local current_user version original_hostname
  version="$(latest_version)"
  show_welcome "$version"
  pause_for_enter

  current_user="${SUDO_USER:-$(id -un)}"
  original_hostname="$(hostname)"
  DEVICE_NAME="$(prompt "Enter the YesNAS device name" "yesnas")"
  valid_hostname "$DEVICE_NAME" || fail "Invalid device name. Use letters, numbers, and hyphens only."
  RUN_USER="$(prompt "Enter the Linux user that will run YesNAS" "$current_user")"
  id "$RUN_USER" >/dev/null 2>&1 || fail "Linux user '$RUN_USER' does not exist."
  ACCESS_PORT="$(prompt "Enter the YesNAS HTTP access port" "80")"
  valid_port "$ACCESS_PORT" || fail "Invalid port: $ACCESS_PORT"
  if port_busy "$ACCESS_PORT"; then
    if [[ "$ACCESS_PORT" == 80 ]] && ! port_busy 81; then
      warn "Port 80 is already in use; using port 81 instead."
      ACCESS_PORT=81
    else
      fail "Port $ACCESS_PORT is already in use. Choose another port."
    fi
  fi

  [[ "$EUID" -eq 0 ]] || sudo -v
  local server_installer web_installer
  server_installer="$(mktemp)"; web_installer="$(mktemp)"
  trap 'rm -f "${server_installer:-}" "${web_installer:-}"' EXIT
  curl -fsSL --retry 3 "$SERVER_SCRIPT" -o "$server_installer"
  curl -fsSL --retry 3 "$WEB_SCRIPT" -o "$web_installer"

  log "Installing YesNAS Server..."
  run_root env YESNAS_USER="$RUN_USER" YESNAS_HOSTNAME="$DEVICE_NAME" setsid bash "$server_installer" </dev/null
  run_root systemctl is-active --quiet yesnas-server || fail "YesNAS Server is not running."
  log "YesNAS Server is running."

  log "Installing YesNAS Web..."
  run_root env YESNAS_WEB_USER="$RUN_USER" setsid bash "$web_installer" </dev/null
  run_root systemctl is-active --quiet yesnas-web || fail "YesNAS Web is not running."

  install_caddy
  write_caddy_config
  run_root mkdir -p "$STATE_DIR"
  printf 'DEVICE_NAME=%q\nRUN_USER=%q\nACCESS_PORT=%q\nORIGINAL_HOSTNAME=%q\nINSTALLER_VERSION=%q\n' "$DEVICE_NAME" "$RUN_USER" "$ACCESS_PORT" "$original_hostname" "$version" | run_root tee "$STATE_FILE" >/dev/null
  run_root chmod 0600 "$STATE_FILE"

  local url="http://${DEVICE_NAME}"
  [[ "$ACCESS_PORT" == 80 ]] || url="${url}:${ACCESS_PORT}"
  log "Installation completed."
  log "Access URL: $url"
  log "Default username: admin"
  log "Default password: admin"
  warn "Change the default password immediately after signing in."
}

main "$@"
