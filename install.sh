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
#
# Usage (stable):
#   curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/N6LKA/ASL3-Time-Weather-Announcement/main/install.sh | sudo bash
#
# Usage (develop):
#   curl -fsSL "https://github.com/N6LKA/ASL3-Time-Weather-Announcement/archive/refs/heads/develop.tar.gz" \
#     | tar -xzO ASL3-Time-Weather-Announcement-develop/install.sh \
#     | sudo bash -s -- --branch develop
#   (tarball form bypasses raw.githubusercontent.com CDN cache for install.sh itself;
#    --branch is passed as an arg, not an env var, because env vars before sudo don't
#    reliably survive the sudo call on all systems)

BRANCH="main"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

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

# --- Download repo as single tarball (codeload bypasses CDN cache) ---
REPO_TMP_DIR="$(mktemp -d /tmp/saytime-install.XXXXXX)"
trap 'rm -rf "$REPO_TMP_DIR"' EXIT

echo "Downloading ASL3-Time-Weather-Announcement (${BRANCH})..."
if ! curl -fsSL \
    "https://github.com/N6LKA/ASL3-Time-Weather-Announcement/archive/refs/heads/${BRANCH}.tar.gz" \
    -o "$REPO_TMP_DIR/repo.tar.gz"; then
    echo -e "${RED}ERROR: Could not download repo archive for branch '${BRANCH}'.${NC}"
    exit 1
fi
tar -xzf "$REPO_TMP_DIR/repo.tar.gz" -C "$REPO_TMP_DIR" --strip-components=1

fetch_repo_file() {
    local path="$1" dest="$2"
    cp "$REPO_TMP_DIR/$path" "$dest"
}

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
# Read from /dev/tty so prompts work when this script is piped (curl|tar|bash).
# Falls back to existing value silently if no controlling terminal is available.
if [[ -n "$EXISTING_LOCATION" ]]; then
    read -rp "ZIP code or Airport/ICAO code [$EXISTING_LOCATION]: " LOC_INPUT < /dev/tty || true
    WEATHER_LOCATION="${LOC_INPUT:-$EXISTING_LOCATION}"
else
    while true; do
        read -rp "Enter your ZIP code or Airport/ICAO code (e.g. 90210 or KJFK): " WEATHER_LOCATION < /dev/tty || true
        WEATHER_LOCATION=$(echo "$WEATHER_LOCATION" | tr -d ' ')
        [[ -n "$WEATHER_LOCATION" ]] && break
        echo -e "${RED}Location is required.${NC}"
    done
fi

# --- Node number ---
if [[ -n "$EXISTING_NODE" ]]; then
    read -rp "ASL3 node number [$EXISTING_NODE]: " NODE_INPUT < /dev/tty || true
    NODE_NUMBER="${NODE_INPUT:-$EXISTING_NODE}"
else
    while true; do
        read -rp "Enter your ASL3 node number: " NODE_NUMBER < /dev/tty || true
        NODE_NUMBER=$(echo "$NODE_NUMBER" | tr -d ' ')
        [[ -n "$NODE_NUMBER" ]] && break
        echo -e "${RED}Node number is required.${NC}"
    done
fi

# --- Time format ---
read -rp "Time format - 12-hour or 24-hour? [$EXISTING_TIME_FORMAT]: " TF_INPUT < /dev/tty || true
TIME_FORMAT="${TF_INPUT:-$EXISTING_TIME_FORMAT}"
[[ "$TIME_FORMAT" != "24" ]] && TIME_FORMAT="12"

# --- Tempest (optional) ---
echo ""
echo -e "${CYAN}--- Tempest Weather Station (optional) ---${NC}"
echo "If you have a WeatherFlow Tempest station, enter your API token and"
echo "station ID to use your personal weather data instead of public APIs."
echo "Get your token at: https://tempestwx.com/settings/tokens"
echo "Leave blank to keep existing / skip (uses NOAA METAR / Open-Meteo instead)."
echo ""

read -rp "Tempest API token [${EXISTING_TEMPEST_TOKEN:-none}]: " TEMPEST_TOKEN_INPUT < /dev/tty || true
TEMPEST_TOKEN="${TEMPEST_TOKEN_INPUT:-$EXISTING_TEMPEST_TOKEN}"

TEMPEST_STATION=""
if [[ -n "$TEMPEST_TOKEN" ]]; then
    read -rp "Tempest station ID [${EXISTING_TEMPEST_STATION:-auto-detect}]: " TEMPEST_STATION_INPUT < /dev/tty || true
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

# --- Install scripts ---
echo "Installing saytime.pl..."
fetch_repo_file "saytime.pl" "$INSTALL_DIR/saytime.pl"
chmod +x "$INSTALL_DIR/saytime.pl"
chown asterisk:asterisk "$INSTALL_DIR/saytime.pl"

echo "Installing weather.sh..."
fetch_repo_file "weather.sh" "$INSTALL_DIR/weather.sh"
chmod +x "$INSTALL_DIR/weather.sh"
chown asterisk:asterisk "$INSTALL_DIR/weather.sh"

echo "Installing uninstall.sh..."
fetch_repo_file "uninstall.sh" "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true
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
    echo "Installing weather.ini..."
    fetch_repo_file "weather.ini" "$INSTALL_DIR/weather.ini"
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
elif [[ "$EXISTING_INSTALL" != "true" ]]; then
    # Fresh install with no Tempest configured — ensure fields start blank
    sed -i 's|^TempestToken=.*|TempestToken=""|' "$INSTALL_DIR/weather.ini"
    sed -i 's|^TempestStationID=.*|TempestStationID=""|' "$INSTALL_DIR/weather.ini"
fi
# On an existing install with no new token entered, leave the ini untouched —
# never wipe credentials the user already has configured.

# --- Sound files ---
echo ""
echo "--- Installing sound files ---"
mkdir -p "$SOUNDS_DIR"
chown asterisk:asterisk "$SOUNDS_DIR"

echo "Extracting sound files..."
unzip -o "$REPO_TMP_DIR/sound_files.zip" -d "$SOUNDS_DIR" > /dev/null 2>&1

find "$SOUNDS_DIR" -type f -name "*.gsm"  -exec chown asterisk:asterisk {} \; -exec chmod 644 {} \;
find "$SOUNDS_DIR" -type d -exec chown asterisk:asterisk {} \; -exec chmod 755 {} \;
echo "Sound files installed."

# --- systemd service and timer ---
echo ""
echo "--- Setting up systemd weather timer ---"

# Install systemd units
fetch_repo_file "systemd/asl3-saytime-weather.service" "$SYSTEMD_DIR/asl3-saytime-weather.service"
fetch_repo_file "systemd/asl3-saytime-weather.timer"   "$SYSTEMD_DIR/asl3-saytime-weather.timer"

systemctl daemon-reload
systemctl enable --now asl3-saytime-weather.timer
echo -e "${GREEN}Weather timer enabled (runs every 10 minutes).${NC}"

# Run an immediate weather fetch so files are ready now
# Remove any stale /tmp cache files (may be owned by a different user from
# previous runs) so the asterisk-owned systemd service starts with a clean slate.
rm -f /tmp/temperature /tmp/condition.gsm /tmp/feels-like /tmp/humidity \
       /tmp/temperature.new /tmp/condition.gsm.new /tmp/weather-display /tmp/weather-display.new

echo "Running initial weather fetch..."
systemctl start asl3-saytime-weather.service 2>/dev/null || \
    su -s /bin/bash asterisk -c "$INSTALL_DIR/weather.sh $WEATHER_LOCATION" 2>/dev/null || true

# --- Supermon integration ---
SUPERMON_WEATHER="/usr/local/sbin/supermon/weather.sh"
if [ -d "/usr/local/sbin/supermon" ]; then
    echo ""
    echo "--- Supermon integration ---"
    if [ -L "$SUPERMON_WEATHER" ]; then
        ln -sf "$INSTALL_DIR/weather.sh" "$SUPERMON_WEATHER"
        echo -e "${GREEN}Supermon weather.sh symlink updated.${NC}"
    elif [ -f "$SUPERMON_WEATHER" ]; then
        echo "Backing up existing Supermon weather.sh..."
        cp "$SUPERMON_WEATHER" "${SUPERMON_WEATHER}.bak"
        ln -sf "$INSTALL_DIR/weather.sh" "$SUPERMON_WEATHER"
        echo -e "${GREEN}Supermon weather.sh linked (original backed up to .bak).${NC}"
    fi
fi

# --- Asterisk crontab: hourly saytime.pl announcement ---
echo ""
echo "--- Setting up hourly announcement cron ---"

CRON_COMMENT="# Hourly Time and Weather Announcement"
CRON_JOB="00 00-23 * * * /usr/bin/nice -19 /usr/bin/perl ${INSTALL_DIR}/saytime.pl ${WEATHER_LOCATION} ${NODE_NUMBER} >/dev/null 2>&1"

# Remove any legacy saytime.pl entry from the root crontab (old installer put it there)
ROOT_CRON=$(crontab -l 2>/dev/null || true)
if echo "$ROOT_CRON" | grep -q "saytime\.pl"; then
    echo -e "${YELLOW}Removing legacy saytime.pl entry from root crontab...${NC}"
    NEW_ROOT_CRON=$(echo "$ROOT_CRON" | awk '
        /[Tt]ime and [Ww]eather/ { skip=1; next }
        /saytime\.pl/            { skip=0; next }
        skip                     { next }
        { print }
    ')
    echo "$NEW_ROOT_CRON" | crontab -
    echo -e "${GREEN}Legacy root crontab entry removed.${NC}"
fi

# Add to asterisk crontab if not already present
# Use a temp file approach — more reliable than piping on all systems
ASTERISK_CRONTAB_FILE=$(mktemp /tmp/asterisk-cron.XXXXXX)
crontab -u asterisk -l 2>/dev/null > "$ASTERISK_CRONTAB_FILE" || true

if grep -q "saytime\.pl" "$ASTERISK_CRONTAB_FILE" 2>/dev/null; then
    echo -e "${YELLOW}Existing saytime.pl entry found in asterisk crontab — skipping.${NC}"
    echo "To update it manually: crontab -u asterisk -e"
else
    {
        cat "$ASTERISK_CRONTAB_FILE"
        echo ""
        echo "$CRON_COMMENT"
        echo "$CRON_JOB"
    } > "${ASTERISK_CRONTAB_FILE}.new"
    crontab -u asterisk "${ASTERISK_CRONTAB_FILE}.new"
    # Verify it actually landed there
    if crontab -u asterisk -l 2>/dev/null | grep -q "saytime\.pl"; then
        echo -e "${GREEN}Cron job added to asterisk crontab (runs hourly at top of the hour).${NC}"
    else
        echo -e "${RED}WARNING: Could not write to asterisk crontab automatically.${NC}"
        echo "Add the following line manually with: crontab -u asterisk -e"
        echo ""
        echo "  $CRON_JOB"
        echo ""
    fi
fi
rm -f "$ASTERISK_CRONTAB_FILE" "${ASTERISK_CRONTAB_FILE}.new"

# --- Update plocate database ---
echo ""
echo "Updating plocate database..."
updatedb 2>/dev/null || true

# --- Done ---
VERSION=$(grep -oP '^\d+\.\d+\.\d+' "$REPO_TMP_DIR/version.txt" 2>/dev/null || echo "")
echo ""
echo "=============================================="
if [[ "$EXISTING_INSTALL" == "true" ]]; then
    echo -e "${GREEN}Update complete!${VERSION:+ (v${VERSION})}${NC}"
else
    echo -e "${GREEN}Installation complete!${VERSION:+ (v${VERSION})}${NC}"
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
