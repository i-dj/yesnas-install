#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE="/etc/yesnas-install/config.env"
SERVER_SCRIPT="https://raw.githubusercontent.com/i-dj/yesnas-server/refs/heads/main/scripts/uninstall.sh"
WEB_SCRIPT="https://raw.githubusercontent.com/i-dj/yesnas/refs/heads/main/scripts/uninstall.sh"
log() { printf '\033[1;32m[YesNAS Uninstaller]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[YesNAS Uninstaller][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
run_root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

main() {
  [[ "$EUID" -eq 0 ]] || { command -v sudo >/dev/null || fail "sudo is required."; sudo -v; }
  DEVICE_NAME=yesnas RUN_USER="${SUDO_USER:-$(id -un)}" ACCESS_PORT=80 ORIGINAL_HOSTNAME=""
  if run_root test -r "$STATE_FILE"; then local state; state="$(run_root cat "$STATE_FILE")"; eval "$state"; fi
  local answer=""
  log "YesNAS device: ${DEVICE_NAME}"
  read -r -p "This will uninstall YesNAS. Type YESNAS to continue: " answer </dev/tty || true
  [[ "$answer" == YESNAS ]] || fail "Uninstall cancelled."
  local web_uninstaller server_uninstaller
  web_uninstaller="$(mktemp)"; server_uninstaller="$(mktemp)"
  trap 'rm -f "${web_uninstaller:-}" "${server_uninstaller:-}"' EXIT
  curl -fsSL --retry 3 "$WEB_SCRIPT" -o "$web_uninstaller"
  curl -fsSL --retry 3 "$SERVER_SCRIPT" -o "$server_uninstaller"
  log "Uninstalling YesNAS Web..."
  run_root env YESNAS_NONINTERACTIVE=1 bash "$web_uninstaller"
  log "Uninstalling YesNAS Server (data and shared system dependencies will be kept)..."
  run_root env \
    YESNAS_NONINTERACTIVE=1 \
    YESNAS_REMOVE_DATA=0 \
    YESNAS_REMOVE_DEPS=0 \
    bash "$server_uninstaller"
  run_root rm -f /etc/caddy/conf.d/yesnas.caddy
  if command -v caddy >/dev/null 2>&1 && run_root caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then run_root systemctl reload caddy; fi
  if [[ -n "$ORIGINAL_HOSTNAME" ]] && [[ "$(hostname)" == "$DEVICE_NAME" ]]; then run_root hostnamectl set-hostname "$ORIGINAL_HOSTNAME"; fi
  run_root rm -rf /etc/yesnas-install
  log "YesNAS was uninstalled. Caddy was kept because it may be used by other sites."
}
main "$@"
