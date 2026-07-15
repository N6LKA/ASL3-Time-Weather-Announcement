#!/bin/bash
#
# install.sh - ASL3 Time and Weather Announcement Installer
# https://github.com/N6LKA/ASL3-Time-Weather-Announcement
#
# Originally by Freddie Mac (KD5FMU) and Jory A. Pratt (W5GLE)
# Modified and updated by Larry K. Aycock (N6LKA)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# On the develop branch this defaults to develop; on main it defaults to main.
BRANCH="${BRANCH:-develop}"
REPO="https://raw.githubusercontent.com/N6LKA/ASL3-Time-Weather-Announcement/${BRANCH}"
SOUND_ZIP_URL="${REPO}/sound_files.zip"

INSTALL_DIR="/etc/asterisk/scripts/saytime-weather"
SOUNDS_DIR="/usr/local/share/asterisk/sounds/custom"
SYSTEMD_DIR="/etc/systemd/system"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "=============================================="
echo "  ASL3 Time and Weather Announcement"
echo "  https://github.com/N6LKA/ASL3-Time-Weather-Announcement"
[ "$BRANCH" != "main" ] && echo "  Branch: ${BRANCH}"
echo "=============================================="
echo ""

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This installer must be run as root or with sudo.${NC}"
    exit 1
fi

# --- Detect existing install ---
EXISTING_INSTALL=false
EXISTING_LOCATION=""
EXISTING_NODE=""
EXISTING_TIME_FORMAT="12"
EXISTING_TEMPEST_TOKEN=""
EXISTING_TEMPEST_STATION=""

if [[ -f "$INSTALL_DIR/saytime.pl" ]]; then
    EXISTING_INSTALL=true
    echo -e "${YELLOW}Existing installation detected in $INSTALL_DIR${NC}"

    # Read existing location from the environment file
    if [[ -f "$INSTALL_DIR/weather-location.env" ]]; then
        EXISTING_LOCATION=$(grep -oP 'WEATHER_LOCATION=\K\S+' "$INSTALL_DIR/weather-location.env" 2>/dev/null || true)
    fi

    # Read existing node from asterisk crontab
    EXISTING_NODE=$(crontab -u asterisk -l 2>/dev/null | \
        grep -oP 'saytime\.pl \S+ \K[0-9]+' | head -1 || true)

    # Read existing config values
    if [[ -f "$INSTALL_DIR/weather.ini" ]]; then
        EXISTING_TIME_FORMAT=$(grep -oP 'TIME_FORMAT="\K[^"]+' "$INSTALL_DIR/weather.ini" 2>/dev/null || echo "12")
        EXISTING_TEMPEST_TOKEN=$(grep -oP 'TempestToken="\K[^"]+' "$INSTALL_DIR/weather.ini" 2>/dev/null || true)
        EXISTING_TEMPEST_STATION=$(grep -oP 'TempestStationID="\K[^"]+' "$INSTALL_DIR/weather.ini" 2>/dev/null || true)
    fi
else
    echo "New installation."
fi

echo ""
echo "--- Configuration ---"

# --- Location ---
if [[ -n "$EXISTING_LOCATION" ]]; then
    read -rp "ZIP code or Airport/ICAO code [$EXISTING_LOCATION]: " LOC_INPUT
    WEATHER_LOCATION="${LOC_INPUT:-$EXISTING_LOCATION}"
else
    while true; do
        read -rp "Enter your ZIP code or Airport/ICAO code (e.g. 90210 or KJFK): " WEATHER_LOCATION
        WEATHER_LOCATION=$(echo "$WEATHER_LOCATION" | tr -d ' ')
        [[ -n "$WEATHER_LOCATION" ]] && break
        echo -e "${RED}Location is required.${NC}"
    done
fi

# --- Node number ---
if [[ -n "$EXISTING_NODE" ]]; then
    read -rp "ASL3 node number [$EXISTING_NODE]: " NODE_INPUT
    NODE_NUMBER="${NODE_INPUT:-$EXISTING_NODE}"
else
    while true; do
        read -rp "Enter your ASL3 node number: " NODE_NUMBER
        NODE_NUMBER=$(echo "$NODE_NUMBER" | tr -d ' ')
        [[ -n "$NODE_NUMBER" ]] && break
        echo -e "${RED}Node number is required.${NC}"
    done
fi

# --- Time format ---
read -rp "Time format - 12-hour or 24-hour? [$EXISTING_TIME_FORMAT]: " TF_INPUT
TIME_FORMAT="${TF_INPUT:-$EXISTING_TIME_FORMAT}"
[[ "$TIME_FORMAT" != "24" ]] && TIME_FORMAT="12"

# --- Tempest (optional) ---
echo ""
echo -e "${CYAN}--- Tempest Weather Station (optional) ---${NC}"
echo "If you have a WeatherFlow Tempest station, enter your API token and"
echo "station ID to use your personal weather data instead of public APIs."
echo "Get your token at: https://tempestwx.com/settings/tokens"
echo "Leave blank to skip (uses NOAA METAR / Open-Meteo instead)."
echo ""

read -rp "Tempest API token [${EXISTING_TEMPEST_TOKEN:-none}]: " TEMPEST_TOKEN_INPUT
TEMPEST_TOKEN="${TEMPEST_TOKEN_INPUT:-$EXISTING_TEMPEST_TOKEN}"

TEMPEST_STATION=""
if [[ -n "$TEMPEST_TOKEN" ]]; then
    read -rp "Tempest station ID [${EXISTING_TEMPEST_STATION:-auto-detect}]: " TEMPEST_STATION_INPUT
    TEMPEST_STATION="${TEMPEST_STATION_INPUT:-$EXISTING_TEMPEST_STATION}"
fi

echo ""
echo "  Location    : $WEATHER_LOCATION"
echo "  Node        : $NODE_NUMBER"
echo "  Time format : ${TIME_FORMAT}-hour"
if [[ -n "$TEMPEST_TOKEN" ]]; then
    echo "  Tempest     : token set, station=${TEMPEST_STATION:-auto-detect}"
else
    echo "  Tempest     : not configured (using NOAA/Open-Meteo)"
fi
echo ""

# --- Install required packages ---
echo "--- Installing required packages ---"
apt-get install -y -q bc zip unzip plocate perl curl 2>/dev/null || {
    echo -e "${RED}ERROR: Failed to install required packages.${NC}"
    exit 1
}

# --- Create install directory ---
echo ""
echo "--- Setting up $INSTALL_DIR ---"
mkdir -p "$INSTALL_DIR"
chown asterisk:asterisk "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

# --- Download scripts ---
echo "Downloading saytime.pl..."
curl -fsSL -H "Cache-Control: no-cache" "$REPO/saytime.pl" -o "$INSTALL_DIR/saytime.pl" || {
    echo -e "${RED}ERROR: Failed to download saytime.pl${NC}"; exit 1; }
chmod +x "$INSTALL_DIR/saytime.pl"
chown asterisk:asterisk "$INSTALL_DIR/saytime.pl"

echo "Downloading weather.sh..."
curl -fsSL -H "Cache-Control: no-cache" "$REPO/weather.sh" -o "$INSTALL_DIR/weather.sh" || {
    echo -e "${RED}ERROR: Failed to download weather.sh${NC}"; exit 1; }
chmod +x "$INSTALL_DIR/weather.sh"
chown asterisk:asterisk "$INSTALL_DIR/weather.sh"

echo "Downloading uninstall.sh..."
curl -fsSL -H "Cache-Control: no-cache" "$REPO/uninstall.sh" -o "$INSTALL_DIR/uninstall.sh" || {
    echo -e "${YELLOW}WARNING: Failed to download uninstall.sh (non-fatal)${NC}"; }
[[ -f "$INSTALL_DIR/uninstall.sh" ]] && chmod +x "$INSTALL_DIR/uninstall.sh" && \
    chown asterisk:asterisk "$INSTALL_DIR/uninstall.sh"

# --- Write location environment file (used by systemd service) ---
cat > "$INSTALL_DIR/weather-location.env" <<EOF
WEATHER_LOCATION=${WEATHER_LOCATION}
EOF
chown asterisk:asterisk "$INSTALL_DIR/weather-location.env"
chmod 644 "$INSTALL_DIR/weather-location.env"

# --- Write or update weather.ini ---
if [[ ! -f "$INSTALL_DIR/weather.ini" ]]; then
    echo "Downloading weather.ini..."
    curl -fsSL -H "Cache-Control: no-cache" "$REPO/weather.ini" -o "$INSTALL_DIR/weather.ini" || {
        echo -e "${RED}ERROR: Failed to download weather.ini${NC}"; exit 1; }
    chown asterisk:asterisk "$INSTALL_DIR/weather.ini"
    chmod 644 "$INSTALL_DIR/weather.ini"
    echo -e "${GREEN}Configuration file created: $INSTALL_DIR/weather.ini${NC}"
else
    echo "Existing weather.ini preserved."
fi

# Apply settings to weather.ini
sed -i "s|^TIME_FORMAT=.*|TIME_FORMAT=\"${TIME_FORMAT}\"|" "$INSTALL_DIR/weather.ini"

if [[ -n "$TEMPEST_TOKEN" ]]; then
    sed -i "s|^TempestToken=.*|TempestToken=\"${TEMPEST_TOKEN}\"|" "$INSTALL_DIR/weather.ini"
    sed -i "s|^TempestStationID=.*|TempestStationID=\"${TEMPEST_STATION}\"|" "$INSTALL_DIR/weather.ini"
    sed -i "s|^DEFAULT_PROVIDER=.*|DEFAULT_PROVIDER=\"tempest\"|" "$INSTALL_DIR/weather.ini"
else
    # Clear any existing Tempest config if user left it blank
    sed -i 's|^TempestToken=.*|TempestToken=""|' "$INSTALL_DIR/weather.ini"
    sed -i 's|^TempestStationID=.*|TempestStationID=""|' "$INSTALL_DIR/weather.ini"
    # Only reset provider if it was tempest (don't override user's custom choice)
    current_provider=$(grep -oP 'DEFAULT_PROVIDER="\K[^"]+' "$INSTALL_DIR/weather.ini" 2>/dev/null || echo "auto")
    [[ "$current_provider" == "tempest" ]] && \
        sed -i 's|^DEFAULT_PROVIDER=.*|DEFAULT_PROVIDER="auto"|' "$INSTALL_DIR/weather.ini"
fi

# --- Sound files ---
echo ""
echo "--- Installing sound files ---"
mkdir -p "$SOUNDS_DIR"
chown asterisk:asterisk "$SOUNDS_DIR"

ZIP_FILE=$(mktemp /tmp/sound_files.XXXXXX.zip)
echo "Downloading sound_files.zip..."
curl -fsSL -H "Cache-Control: no-cache" "$SOUND_ZIP_URL" -o "$ZIP_FILE" || {
    echo -e "${RED}ERROR: Failed to download sound_files.zip${NC}"
    rm -f "$ZIP_FILE"; exit 1; }

echo "Extracting sound files..."
unzip -o "$ZIP_FILE" -d "$SOUNDS_DIR" > /dev/null 2>&1
rm -f "$ZIP_FILE"

find "$SOUNDS_DIR" -type f -name "*.gsm"  -exec chown asterisk:asterisk {} \; -exec chmod 644 {} \;
find "$SOUNDS_DIR" -type d -exec chown asterisk:asterisk {} \; -exec chmod 755 {} \;
echo "Sound files installed."

# --- systemd service and timer ---
echo ""
echo "--- Setting up systemd weather timer ---"

# Download and install systemd units
curl -fsSL -H "Cache-Control: no-cache" \
    "$REPO/systemd/asl3-saytime-weather.service" \
    -o "$SYSTEMD_DIR/asl3-saytime-weather.service" || {
    echo -e "${RED}ERROR: Failed to download systemd service unit${NC}"; exit 1; }

curl -fsSL -H "Cache-Control: no-cache" \
    "$REPO/systemd/asl3-saytime-weather.timer" \
    -o "$SYSTEMD_DIR/asl3-saytime-weather.timer" || {
    echo -e "${RED}ERROR: Failed to download systemd timer unit${NC}"; exit 1; }

systemctl daemon-reload
systemctl enable --now asl3-saytime-weather.timer
echo -e "${GREEN}Weather timer enabled (runs every 10 minutes).${NC}"

# Run an immediate weather fetch so files are ready now
echo "Running initial weather fetch..."
systemctl start asl3-saytime-weather.service 2>/dev/null || \
    su -s /bin/bash asterisk -c "$INSTALL_DIR/weather.sh $WEATHER_LOCATION" 2>/dev/null || true

# --- Asterisk crontab: hourly saytime.pl announcement ---
echo ""
echo "--- Setting up hourly announcement cron ---"

CRON_COMMENT="# Hourly Time and Weather Announcement"
CRON_JOB="00 00-23 * * * /usr/bin/nice -19 /usr/bin/perl ${INSTALL_DIR}/saytime.pl ${WEATHER_LOCATION} ${NODE_NUMBER} >/dev/null 2>&1"

CURRENT_ASTERISK_CRON=$(crontab -u asterisk -l 2>/dev/null || true)

if echo "$CURRENT_ASTERISK_CRON" | grep -q "saytime\.pl"; then
    echo -e "${YELLOW}Existing saytime.pl cron entry found — skipping (no changes made).${NC}"
    echo "To update the cron entry manually, run: crontab -u asterisk -e"
else
    (echo "$CURRENT_ASTERISK_CRON"; echo ""; echo "$CRON_COMMENT"; echo "$CRON_JOB") | \
        crontab -u asterisk -
    echo -e "${GREEN}Cron job added to asterisk crontab (runs hourly at top of the hour).${NC}"
fi

# --- Update plocate database ---
echo ""
echo "Updating plocate database..."
updatedb 2>/dev/null || true

# --- Done ---
echo ""
echo "=============================================="
if [[ "$EXISTING_INSTALL" == "true" ]]; then
    echo -e "${GREEN}Update complete!${NC}"
else
    echo -e "${GREEN}Installation complete!${NC}"
fi
echo ""
echo "Install directory : $INSTALL_DIR"
echo "Sound files       : $SOUNDS_DIR"
echo "Config file       : $INSTALL_DIR/weather.ini"
echo "Debug log         : /tmp/weather-debug.log"
echo ""
echo "Test weather fetch:"
echo "  $INSTALL_DIR/weather.sh $WEATHER_LOCATION v"
echo ""
echo "Test full announcement (plays to node):"
echo "  perl $INSTALL_DIR/saytime.pl $WEATHER_LOCATION $NODE_NUMBER"
echo ""
echo "Check weather timer status:"
echo "  systemctl status asl3-saytime-weather.timer"
echo "  journalctl -u asl3-saytime-weather"
echo ""
if [[ -n "$TEMPEST_TOKEN" ]]; then
    echo -e "${CYAN}NOTE: Tempest provider configured. Edit $INSTALL_DIR/weather.ini"
    echo -e "to adjust settings or switch providers.${NC}"
    echo ""
fi
echo "=============================================="
echo ""
