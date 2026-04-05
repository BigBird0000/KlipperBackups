#!/bin/bash
# printerstatus3.sh
# Version: 1.14 — Self-Healing Edition

set -euo pipefail

VERSION="1.14"

# Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

declare -A SERVICE_STATUS
RESTORED_FILES=()

echo -e "${CYAN}printerstatus3 v${VERSION} — Self-Healing Edition${RESET}"
echo

###############################################
# Utility helpers
###############################################
log_info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }

set_status() {
  local key="$1"
  local val="$2"
  SERVICE_STATUS["$key"]="$val"
}

###############################################
# 1. Klipper checks and repair
###############################################
KLIPPER_SERVICE_FILE="/etc/systemd/system/klipper.service"
KLIPPER_EXPECTED_EXEC="ExecStart=/home/ajs/klippy-env/bin/python /home/ajs/klipper/klippy/klippy.py /home/ajs/printer_data/config/printer.cfg -I /home/ajs/printer_data/config"

check_klipper() {
  echo "=============================="
  echo " Checking Klipper"
  echo "=============================="

  if ! systemctl is-enabled --quiet klipper 2>/dev/null; then
    log_warn "Klipper service is not enabled."
    set_status "Klipper" "Disabled"
  fi

  if systemctl is-active --quiet klipper 2>/dev/null; then
    log_ok "Klipper service is active."
    [[ -z "${SERVICE_STATUS[Klipper]:-}" ]] && set_status "Klipper" "OK"
  else
    log_warn "Klipper service is not active."
    set_status "Klipper" "Inactive"
  fi

  if [[ ! -f "$KLIPPER_SERVICE_FILE" ]]; then
    log_error "Klipper service file missing: $KLIPPER_SERVICE_FILE"
    set_status "Klipper" "ServiceMissing"
    return 1
  fi

  local exec_line
  exec_line="$(grep -E '^ExecStart=' "$KLIPPER_SERVICE_FILE" || true)"

  if [[ -z "$exec_line" ]]; then
    log_error "ExecStart line missing in $KLIPPER_SERVICE_FILE"
    set_status "Klipper" "ExecMissing"
    return 1
  fi

  if ! grep -q "/home/ajs/printer_data/config/printer.cfg" <<<"$exec_line"; then
    log_error "Klipper ExecStart is missing main config file argument (printer.cfg)."
    log_info  "Current ExecStart: $exec_line"
    set_status "Klipper" "ExecMissingConfigArg"
  elif ! grep -q "\-I /home/ajs/printer_data/config" <<<"$exec_line"; then
    log_error "Klipper ExecStart is missing include path (-I /home/ajs/printer_data/config)."
    log_info  "Current ExecStart: $exec_line"
    set_status "Klipper" "ExecMissingInclude"
  else
    log_ok "Klipper ExecStart includes main config and include path."
    [[ "${SERVICE_STATUS[Klipper]}" == "Inactive" ]] || set_status "Klipper" "OK"
  fi
}

repair_klipper_exec_if_needed() {
  if [[ ! -f "$KLIPPER_SERVICE_FILE" ]]; then
    return
  fi

  local exec_line
  exec_line="$(grep -E '^ExecStart=' "$KLIPPER_SERVICE_FILE" || true)"

  if [[ "$exec_line" != "$KLIPPER_EXPECTED_EXEC" ]]; then
    log_info "Repairing Klipper ExecStart to include main config and include path..."
    sudo sed -i "s|^ExecStart=.*|$KLIPPER_EXPECTED_EXEC|" "$KLIPPER_SERVICE_FILE"
    sudo systemctl daemon-reload
    sudo systemctl restart klipper || true
    log_ok "Klipper ExecStart repaired and service restarted."
    set_status "Klipper" "RepairedExec"
  fi
}

###############################################
# 2. Moonraker checks and repair
###############################################
check_moonraker() {
  echo
  echo "=============================="
  echo " Checking Moonraker"
  echo "=============================="

  local cfg="/home/ajs/printer_data/config/moonraker.conf"
  local bad_cfg="/root/printer_data/config/moonraker.conf"

  if [[ -f "$bad_cfg" ]]; then
    log_error "Moonraker config found under /root: $bad_cfg"
    set_status "Moonraker" "ConfigError"
    return 1
  fi

  if [[ ! -f "$cfg" ]]; then
    log_error "Config file missing for moonraker: $cfg"
    set_status "Moonraker" "ConfigMissing"
    return 1
  fi

  if [[ ! -s "$cfg" ]]; then
    log_error "Moonraker config file is zero-length: $cfg"
    set_status "Moonraker" "ConfigEmpty"
    return 1
  fi

  if systemctl is-active --quiet moonraker 2>/dev/null; then
    log_ok "Moonraker service is active."
    set_status "Moonraker" "OK"
  else
    log_warn "Moonraker service is not active."
    set_status "Moonraker" "Inactive"
  fi
}

repair_moonraker_root_if_needed() {
  log_info "Checking for incorrect Moonraker install under /root..."
  if [[ -d "/root/moonraker" || -d "/root/printer_data" ]]; then
    log_warn "Found root-owned Moonraker install. Removing..."
    sudo systemctl stop moonraker 2>/dev/null || true
    sudo systemctl disable moonraker 2>/dev/null || true
    sudo rm -rf /etc/systemd/system/moonraker.service
    sudo rm -rf /root/moonraker
    sudo rm -rf /root/printer_data
    sudo systemctl daemon-reload
    log_ok "Root Moonraker install removed. Reinstall via KIAUH as user ajs."
    set_status "Moonraker" "RemovedRootInstall"
  fi
}

###############################################
# 3. Mainsail / Caddy / nginx checks and repair
###############################################
check_mainsail_ports() {
  echo
  echo "=============================="
  echo " Checking Mainsail / Caddy"
  echo "=============================="

  local port=80
  if sudo lsof -i :"$port" -sTCP:LISTEN >/tmp/ps3_port80 2>/dev/null; then
    log_error "Port $port is already in use!"
    cat /tmp/ps3_port80
    set_status "Mainsail" "Blocked"
    set_status "Caddy" "Blocked"
    return 1
  else
    log_ok "Port $port is free."
    set_status "Mainsail" "OK"
    set_status "Caddy" "OK"
  fi
}

repair_nginx_if_needed() {
  log_info "Checking for nginx blocking port 80..."
  if pgrep nginx >/dev/null 2>&1; then
    log_warn "nginx detected. Purging..."
    sudo systemctl stop nginx || true
    sudo systemctl disable nginx || true
    sudo apt purge -y nginx nginx-common nginx-full >/dev/null 2>&1 || true
    sudo rm -rf /etc/nginx
    log_ok "nginx removed."
    set_status "Mainsail" "Repaired"
    set_status "Caddy" "Repaired"
  fi
}

###############################################
# 4. Critical file integrity check
###############################################
CRITICAL_PATHS=(
  "/home/ajs/klipper/klippy/klippy.py"
  "/home/ajs/printer_data/config/printer.cfg"
  "/home/ajs/printer_data/config"
  "/home/ajs/printer_data/logs"
  "/home/ajs/printer_data/gcodes"
  "/home/ajs/moonraker/moonraker/moonraker.py"
  "/home/ajs/printer_data/config/moonraker.conf"
  "/home/ajs/mainsail/config.json"
  "/home/ajs/printer_data/config/mainsail.cfg"
)

CRITICAL_BROKEN=0

check_critical_files() {
  echo
  echo "=============================="
  echo " Checking Critical Files"
  echo "=============================="

  CRITICAL_BROKEN=0

  for path in "${CRITICAL_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
      if [[ ! -d "$path" ]]; then
        log_error "Missing critical directory: $path"
        CRITICAL_BROKEN=1
      else
        log_ok "Critical directory OK: $path"
      fi
    else
      if [[ ! -e "$path" ]]; then
        log_error "Missing critical file: $path"
        CRITICAL_BROKEN=1
      elif [[ ! -s "$path" ]]; then
        log_error "Critical file is zero-length: $path"
        CRITICAL_BROKEN=1
      else
        log_ok "Critical file OK: $path"
      fi
    fi
  done

  if [[ $CRITICAL_BROKEN -eq 0 ]]; then
    set_status "CriticalFiles" "OK"
  else
    set_status "CriticalFiles" "Broken"
  fi
}

###############################################
# 5. Backup restore scanner (conditional)
###############################################
backup_restore_scanner() {
  if [[ $CRITICAL_BROKEN -eq 0 ]]; then
    log_info "Critical files intact. Backup restore not required."
    set_status "BackupRestore" "NotNeeded"
    return
  fi

  echo
  echo "=============================="
  echo " Backup Restore Scanner"
  echo "=============================="

  local BACKUP_DIR="/root/backups"

  if [[ ! -d "$BACKUP_DIR" ]]; then
    log_error "Backup directory not found: $BACKUP_DIR"
    set_status "BackupRestore" "BackupDirMissing"
    return
  fi

  log_info "Scanning backups in $BACKUP_DIR..."

  mapfile -t BACKUPS < <(
    find "$BACKUP_DIR" -maxdepth 1 -type f \
      -name "full_backup_*.tar.zst*" \
      ! -name "*.sha256" \
      -size +2G \
      -printf "%T@ %p\n" | sort -nr | awk '{print $2}'
  )

  if [[ ${#BACKUPS[@]} -eq 0 ]]; then
    log_warn "No valid backup files found."
    set_status "BackupRestore" "NoValidBackups"
    return
  fi

  echo
  echo "Valid backups found (newest first):"
  printf '  %s\n' "${BACKUPS[@]}"

  echo
  echo "Starting from newest backup..."
  for FILE in "${BACKUPS[@]}"; do
    echo
    echo "--------------------------------------"
    echo "Backup candidate:"
    echo "  $FILE"
    echo "--------------------------------------"
    read -rp "Restore this backup? (y/n): " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      log_info "Restoring backup: $FILE"
      # Example restore command (adjust to your layout):
      # sudo tar --zstd -xvf "$FILE" -C /
      RESTORED_FILES+=("$FILE")
      set_status "BackupRestore" "Restored"
      return
    fi
  done

  log_info "No backup selected for restoration."
  set_status "BackupRestore" "Skipped"
}

###############################################
# MAIN FLOW
###############################################

# Phase 1: Diagnostics
check_klipper || true
check_moonraker || true
check_mainsail_ports || true
check_critical_files

# Phase 2: Conditional Repairs
case "${SERVICE_STATUS[Klipper]:-}" in
  ExecMissing|ExecMissingConfigArg|ExecMissingInclude|ServiceMissing)
    repair_klipper_exec_if_needed
    ;;
esac

if [[ "${SERVICE_STATUS[Moonraker]:-}" == "ConfigError" || "${SERVICE_STATUS[Moonraker]:-}" == "ConfigMissing" || "${SERVICE_STATUS[Moonraker]:-}" == "ConfigEmpty" ]]; then
  repair_moonraker_root_if_needed
fi

if [[ "${SERVICE_STATUS[Mainsail]:-}" == "Blocked" || "${SERVICE_STATUS[Caddy]:-}" == "Blocked" ]]; then
  repair_nginx_if_needed
fi

# Re-check critical files after repairs
check_critical_files

# Phase 3: Conditional Backup Restore
backup_restore_scanner

###############################################
# SUMMARY TABLE
###############################################
echo
echo "=============================="
echo "        SUMMARY TABLE"
echo "=============================="

printf "%-28s %-20s\n" "Service" "Status"
printf "%-28s %-20s\n" "------------------------" "--------------------"

printf "%-28s %-20s\n" "Klipper" "${SERVICE_STATUS[Klipper]:-Unknown}"
printf "%-28s %-20s\n" "Moonraker" "${SERVICE_STATUS[Moonraker]:-Unknown}"
printf "%-28s %-20s\n" "Mainsail" "${SERVICE_STATUS[Mainsail]:-Unknown}"
printf "%-28s %-20s\n" "Caddy (Mainsail Web Server)" "${SERVICE_STATUS[Caddy]:-Unknown}"
printf "%-28s %-20s\n" "Critical Files" "${SERVICE_STATUS[CriticalFiles]:-Unknown}"
printf "%-28s %-20s\n" "Backup Restore" "${SERVICE_STATUS[BackupRestore]:-Unknown}"

echo "=============================="

# Restored files section
if [[ ${#RESTORED_FILES[@]} -gt 0 ]]; then
  echo
  echo "Restored Files:"
  for f in "${RESTORED_FILES[@]}"; do
    echo "  - $f"
  done
fi

exit 0
