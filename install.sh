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

BRANCH="${BRANCH:-main}"
REPO="https://raw.githubusercontent.com/N6LKA/ASL3-Time-Weather-Announcement/${BRANCH}"
SOUND_ZIP_URL="${REPO}/sound_files.zip"

BIN_DIR="/usr/local/sbin"
LOCAL_DIR="/etc/asterisk/local"
SOUNDS_DIR="/usr/local/share/asterisk/sounds/custom"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "=============================================="
echo "  Time and Weather Announcement - Installer"
echo "  https://github.com/N6LKA/ASL3-Time-Weather-Announcement"
echo "=============================================="
echo ""

# --- Check for root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This installer must be run as root or with sudo.${NC}"
    exit 1
fi

# --- Detect existing install ---
EXISTING_INSTALL=false
EXISTING_ZIP=""
EXISTING_NODE=""

if [[ -f "$BIN_DIR/saytime.pl" ]]; then
    EXISTING_INSTALL=true
    EXISTING_CRON=$(crontab -l 2>/dev/null | grep "saytime.pl" | head -1)
    if [[ -n "$EXISTING_CRON" ]]; then
        SAYTIME_ARGS=$(echo "$EXISTING_CRON" | sed -n 's/.*saytime\.pl \([^ )]*\) \([0-9]*\).*/\1 \2/p')
        EXISTING_ZIP=$(echo "$SAYTIME_ARGS" | awk '{print $1}')
        EXISTING_NODE=$(echo "$SAYTIME_ARGS" | awk '{print $2}')
    fi
    echo -e "${YELLOW}Existing installation detected. Updating...${NC}"
else
    echo "New installation."
fi

# --- Location and node prompts ---
echo ""
echo "--- Configuration ---"

if [[ -n "$EXISTING_ZIP" ]]; then
    read -rp "ZIP code or Airport/ICAO code [$EXISTING_ZIP]: " ZIP_INPUT
    ZIP_CODE="${ZIP_INPUT:-$EXISTING_ZIP}"
else
    while true; do
        read -rp "Enter your ZIP code or Airport/ICAO code (e.g. 90210 or KJFK): " ZIP_CODE
        ZIP_CODE=$(echo "$ZIP_CODE" | tr -d ' ')
        [[ -n "$ZIP_CODE" ]] && break
        echo -e "${RED}ZIP/Airport code is required.${NC}"
    done
fi

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

echo ""
echo "  Location : $ZIP_CODE"
echo "  Node     : $NODE_NUMBER"
echo ""

# --- Install required packages ---
echo "--- Installing required packages ---"
apt install -y bc zip plocate 2>/dev/null || {
    echo -e "${RED}ERROR: Failed to install required packages.${NC}"
    echo "Ensure you have an active internet connection and try again."
    exit 1
}

# --- Download scripts ---
echo ""
echo "--- Downloading files ---"
mkdir -p "$BIN_DIR"

echo "Downloading saytime.pl..."
curl -fsSL -H "Cache-Control: no-cache" "$REPO/saytime.pl" -o "$BIN_DIR/saytime.pl"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}ERROR: Failed to download saytime.pl${NC}"
    exit 1
fi
chmod +x "$BIN_DIR/saytime.pl"
chown asterisk:asterisk "$BIN_DIR/saytime.pl"

echo "Downloading weather.sh..."
curl -fsSL -H "Cache-Control: no-cache" "$REPO/weather.sh" -o "$BIN_DIR/weather.sh"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}ERROR: Failed to download weather.sh${NC}"
    exit 1
fi
chmod +x "$BIN_DIR/weather.sh"
chown asterisk:asterisk "$BIN_DIR/weather.sh"

# Adjust sound file path in saytime.pl
echo "Adjusting sound file path in saytime.pl..."
sed -i.bak 's|/var/lib/asterisk/sounds|/usr/local/share/asterisk/sounds/custom|' "$BIN_DIR/saytime.pl"
rm -f "$BIN_DIR/saytime.pl.bak"

# --- Configuration file ---
echo "Downloading weather.ini..."
mkdir -p "$LOCAL_DIR"
if [[ ! -f "$LOCAL_DIR/weather.ini" ]]; then
    curl -fsSL -H "Cache-Control: no-cache" "$REPO/weather.ini" -o "$LOCAL_DIR/weather.ini"
    echo "Configuration file created: $LOCAL_DIR/weather.ini"
else
    echo "Existing weather.ini preserved."
fi

# --- Sound files ---
echo ""
echo "--- Installing sound files ---"

if [[ ! -d "$SOUNDS_DIR" ]]; then
    mkdir -p "$SOUNDS_DIR"
    chown asterisk:asterisk "$SOUNDS_DIR"
    echo "Created sounds directory: $SOUNDS_DIR"
fi

ZIP_FILE=$(mktemp /tmp/sound_files.XXXXXX.zip)
echo "Downloading sound_files.zip..."
curl -fsSL -H "Cache-Control: no-cache" "$SOUND_ZIP_URL" -o "$ZIP_FILE"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}ERROR: Failed to download sound_files.zip${NC}"
    rm -f "$ZIP_FILE"
    exit 1
fi

echo "Extracting sound files..."
unzip -o "$ZIP_FILE" -d "$SOUNDS_DIR" > /dev/null 2>&1
rm -f "$ZIP_FILE"

echo "Setting permissions..."
find "$SOUNDS_DIR" -type d -exec chown asterisk:asterisk {} \;
find "$SOUNDS_DIR" -type d -exec chmod 775 {} \;
find "$SOUNDS_DIR" -name "*.gsm" -exec chmod 644 {} \;
find "$SOUNDS_DIR" -name "*.gsm" -exec chown asterisk:asterisk {} \;
echo "Sound files installed."

# --- Cron job (root crontab) ---
echo ""
echo "--- Setting up cron job ---"

CRON_COMMENT="# Hourly Time and Weather Announcement"
CRON_JOB="00 00-23 * * * (/usr/bin/nice -19 /usr/bin/perl ${BIN_DIR}/saytime.pl $ZIP_CODE $NODE_NUMBER >/dev/null)"
CURRENT_CRON=$(crontab -l 2>/dev/null)

if echo "$CURRENT_CRON" | grep -q "saytime.pl"; then
    # Entry exists — update the cron line and its preceding comment in-place
    NEW_CRON=$(echo "$CURRENT_CRON" | awk -v comment="$CRON_COMMENT" -v job="$CRON_JOB" '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (lines[i] ~ /saytime\.pl/) {
                    if (i > 1 && lines[i-1] ~ /[Tt]ime and [Ww]eather/) {
                        lines[i-1] = comment
                    }
                    lines[i] = job
                }
            }
            for (i = 1; i <= NR; i++) print lines[i]
        }')
    echo "$NEW_CRON" | crontab -
    echo -e "${GREEN}Cron job updated.${NC}"
else
    # No existing entry — append with blank line, comment, and cron line
    (crontab -l 2>/dev/null; echo ""; echo "$CRON_COMMENT"; echo "$CRON_JOB") | crontab -
    echo -e "${GREEN}Cron job added (runs hourly at top of the hour).${NC}"
fi

# --- Check for stale sounds directory ---
dir_to_check="/var/lib/asterisk/sounds"
dir_count=$(find "$dir_to_check" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if [[ "$dir_count" -gt 2 ]]; then
    echo ""
    echo -e "${YELLOW}NOTE: Extra directories found in $dir_to_check.${NC}"
    echo "You may want to clean these up:"
    echo "  rm -r $dir_to_check/*"
    echo "  mkdir -p $dir_to_check/{en,custom}"
    echo "  chown asterisk:asterisk -R $dir_to_check/*"
fi

# --- Update plocate ---
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
echo "Configuration : $LOCAL_DIR/weather.ini"
echo "Sound files   : $SOUNDS_DIR"
echo ""
echo "Test with:"
echo "  /usr/local/sbin/saytime.pl $ZIP_CODE $NODE_NUMBER"
echo "=============================================="
echo ""
