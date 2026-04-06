#!/bin/bash

# wifi.sh
# program to connect pcie wifi adapter to an SSID given the pw


SSID="$1"
PW="$2"

if [[ -z "$SSID" || -z "$PW" ]]; then
    echo "Error: Missing argument(s)"
    echo "Usage: $0 <SSID> <PASSWORD>"
    exit 1
fi

echo "Connecting to WiFi network: $SSID"
sudo nmcli device wifi connect "$SSID" password "$PW"

if [[ $? -eq 0 ]]; then
    echo "Connected successfully."
else
    echo "Connection failed."
fi
