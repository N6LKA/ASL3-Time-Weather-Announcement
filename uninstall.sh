#!/bin/bash
#
# uninstall.sh - ASL3 Time and Weather Announcement Uninstaller
# https://github.com/N6LKA/ASL3-Time-Weather-Announcement
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

INSTALL_DIR="/etc/asterisk/scripts/saytime-weather"
SYSTEMD_DIR="/etc/systemd/system"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "=============================================="
echo "  ASL3 Time and Weather Announcement"
echo "  Uninstaller"
echo "=============================================="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This uninstaller must be run as root or with sudo.${NC}"
    exit 1
fi

echo -e "${YELLOW}This will remove:${NC}"
echo "  - $INSTALL_DIR/ (all scripts and config)"
echo "  - systemd timer: asl3-saytime-weather.timer"
echo "  - systemd service: asl3-saytime-weather.service"
echo "  - saytime.pl cron entry from asterisk crontab"
echo ""
echo -e "${YELLOW}This will NOT remove:${NC}"
echo "  - Sound files in /usr/local/share/asterisk/sounds/custom/"
echo "    (shared with other programs)"
echo ""
read -rp "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborted."; exit 0; }

echo ""

# --- Stop and remove systemd timer and service ---
echo "Stopping and removing systemd timer..."
systemctl stop asl3-saytime-weather.timer 2>/dev/null || true
systemctl disable asl3-saytime-weather.timer 2>/dev/null || true
rm -f "$SYSTEMD_DIR/asl3-saytime-weather.timer"
rm -f "$SYSTEMD_DIR/asl3-saytime-weather.service"
systemctl daemon-reload
echo -e "${GREEN}Systemd units removed.${NC}"

# --- Remove cron entries (asterisk and root) ---
echo "Removing saytime.pl cron entries..."

remove_saytime_from_crontab() {
    local label="$1"
    shift
    local current
    current=$(crontab "$@" -l 2>/dev/null || true)
    if echo "$current" | grep -q "saytime\.pl"; then
        echo "$current" | awk '
            /[Tt]ime and [Ww]eather/ { skip=1; next }
            /saytime\.pl/            { skip=0; next }
            skip                     { next }
            { print }
        ' | crontab "$@" -
        echo -e "${GREEN}Removed from ${label} crontab.${NC}"
    else
        echo "No saytime.pl entry in ${label} crontab."
    fi
}

remove_saytime_from_crontab "asterisk" -u asterisk
remove_saytime_from_crontab "root"


# --- Restore Supermon weather.sh (if we created the symlink) ---
SUPERMON_WEATHER="/usr/local/sbin/supermon/weather.sh"
if [ -L "$SUPERMON_WEATHER" ]; then
    echo "Removing Supermon weather.sh symlink..."
    rm -f "$SUPERMON_WEATHER"
    if [ -f "${SUPERMON_WEATHER}.bak" ]; then
        mv "${SUPERMON_WEATHER}.bak" "$SUPERMON_WEATHER"
        echo -e "${GREEN}Supermon weather.sh restored from backup.${NC}"
    else
        echo -e "${YELLOW}NOTE: No backup found for Supermon weather.sh.${NC}"
        echo "Supermon weather display will be unavailable until Supermon is reinstalled."
    fi
fi

# --- Remove install directory ---
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}Install directory removed.${NC}"
else
    echo "Install directory not found: $INSTALL_DIR"
fi

# --- Clean up /tmp files ---
echo "Cleaning up /tmp cache files..."
rm -f /tmp/temperature /tmp/condition.gsm /tmp/feels-like /tmp/humidity \
       /tmp/current-time.gsm /tmp/weather-debug.log /tmp/weather-display
echo -e "${GREEN}Temp files removed.${NC}"

echo ""
echo "=============================================="
echo -e "${GREEN}Uninstall complete.${NC}"
echo ""
echo "Sound files were left in place:"
echo "  /usr/local/share/asterisk/sounds/custom/"
echo "Remove them manually if they are no longer needed."
echo "=============================================="
echo ""
