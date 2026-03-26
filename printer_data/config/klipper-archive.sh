#!/bin/bash
set -euo pipefail
#   klipper-archive.sh
########################################
# Usage
########################################
MODE="$1"          # pre | post
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ "$MODE" != "pre" && "$MODE" != "post" ]]; then
  echo "Usage: $0 {pre|post} [--dry-run]"
  exit 1
fi

########################################
# Helper
########################################
run() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

########################################
# State / lock
########################################
STATE_FILE="$HOME/.klipper_archive_state"
LOCK_FILE="$HOME/.klipper_archive_lock"

cleanup() {
  [[ "$MODE" == "pre" ]] && rm -f "$LOCK_FILE"
}
trap cleanup ERR INT

########################################
#            Detect printer_data
########################################
detect_printer_data() {
  for p in "$HOME/printer_data" "$HOME/klipper_data" "/home/pi/printer_data" "/home/*/printer_data"; do
    for d in $p; do
      if [[ -d "$d/config" && -d "$d/logs" ]]; then
        echo "$d"
        return
      fi
    done
  done
}
PRINTER_DATA="$(detect_printer_data)"
[[ -z "$PRINTER_DATA" ]] && { echo "ERROR: Could not detect printer_data"; exit 1; }

########################################
# Detect UI service
########################################
UI_SERVICE=""
if systemctl is-enabled --quiet mainsail 2>/dev/null; then
  UI_SERVICE="mainsail"
elif systemctl is-enabled --quiet fluidd 2>/dev/null; then
  UI_SERVICE="fluidd"
elif systemctl is-enabled --quiet nginx 2>/dev/null; then
  UI_SERVICE="nginx"
fi

SERVICES=(klipper moonraker)
[[ -n "$UI_SERVICE" ]] && SERVICES+=("$UI_SERVICE")

########################################
# Detect swap
########################################
SWAP_ACTIVE=false
if swapon --noheadings --summary | grep -q .; then
  SWAP_ACTIVE=true
fi

########################################
# PRE-ARCHIVE
########################################
if [[ "$MODE" == "pre" ]]; then
  [[ -f "$LOCK_FILE" ]] && { echo "Warning: Pre-archive already run, skipping"; exit 0; }
  touch "$LOCK_FILE"
  > "$STATE_FILE"

  echo "SWAP_ACTIVE=$SWAP_ACTIVE" >> "$STATE_FILE"

  for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
      echo "$svc=active" >> "$STATE_FILE"
      run sudo systemctl stop "$svc"
    else
      echo "$svc=inactive" >> "$STATE_FILE"
    fi
  done

  $SWAP_ACTIVE && run sudo swapoff -a

  # Clean caches and logs
  run sudo apt clean || true
  run sudo apt autoremove --purge -y || true
  run rm -rf ~/.cache/* || true
  run sudo rm -rf /root/.cache/* /tmp/* /var/tmp/* /var/crash/* || true
  run rm -f "$PRINTER_DATA"/logs/*.log* || true
  run sudo journalctl --vacuum-size=50M || true

  echo "Klipper pre-archive complete."
fi

########################################
# POST-ARCHIVE
########################################
if [[ "$MODE" == "post" ]]; then
  [[ ! -f "$STATE_FILE" ]] && { echo "ERROR: State file not found"; exit 1; }

  SWAP_WAS_ACTIVE=false
  while IFS='=' read -r key value; do
    [[ "$key" == "SWAP_ACTIVE" && "$value" == "true" ]] && SWAP_WAS_ACTIVE=true
  done < "$STATE_FILE"

  $SWAP_WAS_ACTIVE && run sudo swapon -a

  while IFS='=' read -r svc state; do
    [[ "$svc" == "SWAP_ACTIVE" ]] && continue
    [[ "$state" == "active" ]] && run sudo systemctl start "$svc"
  done < "$STATE_FILE"

  rm -f "$STATE_FILE" "$LOCK_FILE"

  echo "Klipper post-archive complete."
fi
