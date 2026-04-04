#!/bin/bash

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

SERVICES=()
STATUSES=()

# Required ports for each service
declare -A PORTS
PORTS["moonraker"]="7125"
PORTS["mainsail"]="80"
PORTS["mainsail-web"]="80"
PORTS["caddy"]="80"
PORTS["klipper"]=""

# -----------------------------
# PORT CHECKER
# -----------------------------
check_port() {
    local SERVICE="$1"
    local PORT="${PORTS[$SERVICE]}"

    if [ -z "$PORT" ]; then
        return 0
    fi

    if sudo lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
        echo -e "${RED}Port $PORT is already in use!${RESET}"
        echo -e "${YELLOW}Process using port $PORT:${RESET}"
        sudo lsof -iTCP:$PORT -sTCP:LISTEN
        return 1
    fi

    return 0
}

# -----------------------------
# SELF-HEALING LOGIC
# -----------------------------
auto_fix_service() {
    local SERVICE="$1"

    echo -e "${BLUE}Running self-healing for $SERVICE...${RESET}"

    # 1. Ensure systemd directory exists
    if [ ! -d "/etc/systemd/system" ]; then
        sudo mkdir -p /etc/systemd/system
    fi

    # 2. Ensure log directory exists
    LOG_DIR="/var/log/$SERVICE"
    if [ ! -d "$LOG_DIR" ]; then
        sudo mkdir -p "$LOG_DIR"
        sudo chmod 755 "$LOG_DIR"
    fi

    # 3. Ensure log file exists
    LOG_FILE="$LOG_DIR/$SERVICE.log"
    if [ ! -f "$LOG_FILE" ]; then
        sudo touch "$LOG_FILE"
        sudo chmod 644 "$LOG_FILE"
    fi

    # 4. Klipper socket fix
    if [ "$SERVICE" = "klipper" ]; then
        if [ ! -S "/tmp/klippy_uds" ]; then
            echo -e "${YELLOW}Recreating missing Klipper socket placeholder...${RESET}"
            sudo touch /tmp/klippy_uds
        fi
    fi

    # 5. Moonraker socket fix
    if [ "$SERVICE" = "moonraker" ]; then
        if [ ! -d "/run/moonraker" ]; then
            sudo mkdir -p /run/moonraker
        fi
    fi

    sudo systemctl daemon-reload
}

# -----------------------------
# SERVICE CHECKER
# -----------------------------
check_service() {
    local SERVICE="$1"
    local DISPLAY_NAME="$2"

    echo -e "\n=============================="
    echo -e " Checking ${DISPLAY_NAME}"
    echo -e "=============================="

    SERVICES+=("$DISPLAY_NAME")

    # Port conflict check
    if ! check_port "$SERVICE"; then
        STATUSES+=("Blocked")
        return
    fi

    # If service missing → attempt self-heal
    if ! systemctl list-unit-files | grep -q "^${SERVICE}.service"; then
        echo -e "${YELLOW}${DISPLAY_NAME} service missing — attempting self-heal...${RESET}"
        auto_fix_service "$SERVICE"
        sudo systemctl start "$SERVICE"
        sleep 1
    fi

    # First status check
    STATUS=$(systemctl is-active "$SERVICE")

    if [ "$STATUS" = "active" ]; then
        echo -e "${GREEN}${DISPLAY_NAME} is running${RESET}"
        STATUSES+=("Running")
        return
    fi

    echo -e "${RED}${DISPLAY_NAME} is NOT running${RESET}"
    echo -e "${YELLOW}Attempting self-heal + restart...${RESET}"

    auto_fix_service "$SERVICE"
    sudo systemctl restart "$SERVICE"
    sleep 1

    # Second status check
    STATUS=$(systemctl is-active "$SERVICE")

    if [ "$STATUS" = "active" ]; then
        echo -e "${GREEN}${DISPLAY_NAME} recovered successfully${RESET}"
        STATUSES+=("Recovered")
    else
        echo -e "${RED}${DISPLAY_NAME} failed to start${RESET}"
        STATUSES+=("Failed")
        echo -e "${YELLOW}Reason:${RESET}"
        journalctl -u "$SERVICE" -n 20 --no-pager
    fi
}

# -----------------------------
# RUN CHECKS
# -----------------------------
check_service "klipper" "Klipper"
check_service "moonraker" "Moonraker"
check_service "mainsail" "Mainsail"
check_service "mainsail-web" "Mainsail-Web (alt)"
check_service "caddy" "Caddy (Mainsail Web Server)"

# -----------------------------
# SUMMARY TABLE
# -----------------------------
echo -e "\n\n=============================="
echo -e "        SUMMARY TABLE"
echo -e "=============================="

printf "%-25s %-15s\n" "Service" "Status"
printf "%-25s %-15s\n" "------------------------" "---------------"

for i in "${!SERVICES[@]}"; do
    printf "%-25s %-15s\n" "${SERVICES[$i]}" "${STATUSES[$i]}"
done

echo -e "==============================\n"
