#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE="/etc/yesnas-install/config.env"
SERVER_SCRIPT="https://raw.githubusercontent.com/i-dj/yesnas-server/refs/heads/main/scripts/upgrade.sh"
WEB_SCRIPT="https://raw.githubusercontent.com/i-dj/yesnas/refs/heads/main/scripts/upgrade.sh"
INSTALL_REPO="${YESNAS_INSTALL_REPO:-i-dj/yesnas-install}"
log() { printf '\033[1;32m[YesNAS Updater]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[YesNAS Updater][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
run_root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
prompt() { local value=""; [[ -r /dev/tty ]] && read -r -p "$1 [$2]: " value </dev/tty || true; printf '%s\n' "${value:-$2}"; }
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
latest_version() { curl -fsSL --retry 3 "https://api.github.com/repos/${INSTALL_REPO}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; }

main() {
  [[ "$EUID" -eq 0 ]] || { command -v sudo >/dev/null || fail "sudo is required."; sudo -v; }
  DEVICE_NAME=yesnas RUN_USER="${SUDO_USER:-$(id -un)}" ACCESS_PORT=80 ORIGINAL_HOSTNAME="$(hostname)"
  if run_root test -r "$STATE_FILE"; then
    local state; state="$(run_root cat "$STATE_FILE")"; eval "$state"
  fi
  DEVICE_NAME="$(prompt "Enter the YesNAS device name" "$DEVICE_NAME")"
  valid_hostname "$DEVICE_NAME" || fail "Invalid device name."
  RUN_USER="$(prompt "Enter the Linux user that will run YesNAS" "$RUN_USER")"
  id "$RUN_USER" >/dev/null 2>&1 || fail "Linux user '$RUN_USER' does not exist."
  ACCESS_PORT="$(prompt "Enter the YesNAS HTTP access port" "$ACCESS_PORT")"
  valid_port "$ACCESS_PORT" || fail "Invalid port: $ACCESS_PORT"
  local version server_updater web_updater site
  version="$(latest_version)"; version="${version:-unreleased}"
  log "YesNAS will be updated to installer version ${version}."
  server_updater="$(mktemp)"; web_updater="$(mktemp)"
  trap 'rm -f "${server_updater:-}" "${web_updater:-}"' EXIT
  curl -fsSL --retry 3 "$SERVER_SCRIPT" -o "$server_updater"
  curl -fsSL --retry 3 "$WEB_SCRIPT" -o "$web_updater"
  YESNAS_USER="$RUN_USER" YESNAS_HOSTNAME="$DEVICE_NAME" bash "$server_updater"
  run_root systemctl is-active --quiet yesnas-server || fail "YesNAS Server is not running after the update."
  YESNAS_WEB_USER="$RUN_USER" bash "$web_updater"
  run_root systemctl is-active --quiet yesnas-web || fail "YesNAS Web is not running after the update."
  local run_group
  run_group="$(id -gn "$RUN_USER")"
  run_root sed -i "s/^User=.*/User=${RUN_USER}/; s/^Group=.*/Group=${run_group}/" /etc/systemd/system/yesnas-server.service
  run_root sed -i "s/^User=.*/User=${RUN_USER}/; s/^Group=.*/Group=${run_group}/" /etc/systemd/system/yesnas-web.service
  run_root chown -R "${RUN_USER}:${run_group}" /opt/yesnas/server /opt/yesnas-web
  run_root test ! -d /srv/yesnas || run_root chown -R "${RUN_USER}:${run_group}" /srv/yesnas
  run_root chown "root:${run_group}" /etc/yesnas-server/yesnas.env /etc/yesnas-web/yesnas-web.env
  run_root hostnamectl set-hostname "$DEVICE_NAME"
  if run_root test -f /etc/yesnas-server/yesnas.env; then
    run_root sed -i "s/^OAUTH_BROKER_DEVICE_NAME=.*/OAUTH_BROKER_DEVICE_NAME=${DEVICE_NAME}/" /etc/yesnas-server/yesnas.env
  fi
  run_root systemctl daemon-reload
  run_root systemctl restart yesnas-server yesnas-web
  run_root systemctl is-active --quiet yesnas-server || fail "YesNAS Server failed after applying the configuration."
  run_root systemctl is-active --quiet yesnas-web || fail "YesNAS Web failed after applying the configuration."
  site="http://${DEVICE_NAME}"; [[ "$ACCESS_PORT" == 80 ]] || site="${site}:${ACCESS_PORT}"
  printf '%s {\n    request_body {\n        max_size 100GB\n    }\n\n    handle /api/* {\n        reverse_proxy 127.0.0.1:28080\n    }\n\n    handle {\n        reverse_proxy 127.0.0.1:23000\n    }\n}\n' "$site" | run_root tee /etc/caddy/conf.d/yesnas.caddy >/dev/null
  run_root caddy validate --config /etc/caddy/Caddyfile
  run_root systemctl reload caddy
  printf 'DEVICE_NAME=%q\nRUN_USER=%q\nACCESS_PORT=%q\nORIGINAL_HOSTNAME=%q\nINSTALLER_VERSION=%q\n' "$DEVICE_NAME" "$RUN_USER" "$ACCESS_PORT" "$ORIGINAL_HOSTNAME" "$version" | run_root tee "$STATE_FILE" >/dev/null
  log "Update completed. Open $site"
}
main "$@"
