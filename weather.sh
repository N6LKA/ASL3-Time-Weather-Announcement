#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Weather Script for ASL3 Time and Weather Announcement
# https://github.com/N6LKA/ASL3-Time-Weather-Announcement
#
# Copyright 2025, Jory A. Pratt, W5GLE
# Based on original work by D. Crompton, WA3DSP
# Modified by:              Joe (KD2NFC)
# Modified by:              Larry K. Aycock, N6LKA
# Version:                  3.1.0
#
# Description:
#   Fetches current weather and writes cached output files for saytime.pl.
#   Supports NOAA METAR, Open-Meteo, and WeatherFlow Tempest.
#
#   Also serves as the Supermon weather.sh (symlinked by install.sh). When
#   called with the "v" argument, prints one line with temp/humidity/condition/
#   wind and writes no /tmp files (except the cached weather-display line) —
#   this is the same output Supermon's link.php displays via exec().
#
#   Caches coordinates to avoid repeated Nominatim lookups.
#   If /tmp/temperature is fresher than CACHE_MAX_AGE_MIN, exits immediately
#   so the systemd timer is the primary fetcher and saytime.pl internal calls
#   are no-ops when data is already fresh.
#
#   Config: /etc/asterisk/scripts/saytime-weather/weather.ini
#     DEFAULT_PROVIDER="auto"     # auto, metar, openmeteo, tempest
#     Temperature_mode="F"        # F or C
#     process_condition="YES"     # YES or NO
#     ANNOUNCE_FEELS_LIKE="no"    # yes or no
#     ANNOUNCE_HUMIDITY="no"      # yes or no
#     TempestToken=""             # WeatherFlow API token
#     TempestStationID=""         # WeatherFlow station ID
#     CACHE_MAX_AGE_MIN="12"      # skip fetch if cache is this fresh (minutes)
#
#   Output files (in /tmp):
#     temperature       - integer temp in configured unit
#     feels-like        - integer feels-like temp (if ANNOUNCE_FEELS_LIKE=yes)
#     humidity          - integer humidity percentage (if ANNOUNCE_HUMIDITY=yes)
#     condition.gsm     - GSM audio file for weather condition word
# ------------------------------------------------------------------------------

set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

VERSION="3.1.0"
DESTDIR="/tmp"
LOG="/tmp/weather-debug.log"

# ---------- Logging ----------
# Ensure log is world-writable so both asterisk (systemd) and root can append.
# Fall back to /dev/null if we can't create or chmod it.
touch "$LOG" 2>/dev/null && chmod 666 "$LOG" 2>/dev/null || LOG="/dev/null"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ---------- Command Line Options ----------
opt_config_file=""
opt_default_country=""
opt_temperature_mode=""
opt_no_cache=0
opt_no_condition=0
opt_verbose=0
opt_force=0
location_arg=""
display_mode=""

show_help(){
  cat <<EOF
weather.sh version $VERSION

Usage: weather.sh [OPTIONS] location_id [v]

Arguments:
  location_id    ZIP/postal code, ICAO airport code, or special location
                 (ignored when DEFAULT_PROVIDER=tempest and Tempest is configured)
  v              Display text only (verbose/test mode), no file output

Options:
  -c, --config FILE        Use alternate configuration file
  -d, --default-country CC Override default country (us, ca, fr, de, uk, etc.)
  -t, --temperature-mode M Override temperature mode (F or C)
  --no-cache               Force fresh fetch even if cache is recent
  --no-condition           Skip weather condition announcements
  -h, --help               Show this help message
  --version                Show version information

Examples:
  weather.sh 90210 v          # Test with US ZIP code
  weather.sh KJFK v           # Test with ICAO airport code
  weather.sh --no-cache 90210 # Force fresh fetch
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help ;;
    --version) echo "weather.sh version $VERSION"; exit 0 ;;
    -c|--config) opt_config_file="$2"; shift 2 ;;
    -d|--default-country) opt_default_country="$2"; shift 2 ;;
    -t|--temperature-mode) opt_temperature_mode="${2^^}"; shift 2 ;;
    --no-cache) opt_no_cache=1; shift ;;
    --no-condition) opt_no_condition=1; shift ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      if [ -z "$location_arg" ]; then
        location_arg="$1"
      else
        display_mode="$1"
      fi
      shift
      ;;
  esac
done

# ---------- Load Config ----------
process_condition="YES"
Temperature_mode="F"
default_country="us"
DEFAULT_PROVIDER="auto"
ANNOUNCE_FEELS_LIKE="no"
ANNOUNCE_HUMIDITY="no"
TempestToken=""
TempestStationID=""
CACHE_MAX_AGE_MIN="12"
COORD_CACHE=""

CONFIG_PATHS=(
  "/etc/asterisk/scripts/saytime-weather/weather.ini"
  "/etc/asterisk/local/weather.ini"
  "/etc/asterisk/weather.ini"
  "/usr/local/etc/weather.ini"
  "$HOME/.weather.ini"
)

if [ -n "$opt_config_file" ]; then
  if [ -f "$opt_config_file" ]; then
    # shellcheck source=/dev/null
    . "$opt_config_file" 2>/dev/null || true
  else
    echo "ERROR: Config file not found: $opt_config_file" >&2
    exit 1
  fi
else
  for config_file in "${CONFIG_PATHS[@]}"; do
    if [ -f "$config_file" ]; then
      # shellcheck source=/dev/null
      . "$config_file" 2>/dev/null || true
      break
    fi
  done
fi

# Apply command line overrides
[ -n "$opt_default_country" ] && default_country="$opt_default_country"
[ -n "$opt_temperature_mode" ] && Temperature_mode="$opt_temperature_mode"
[ "$opt_no_condition" -eq 1 ] && process_condition="NO"

case "${DEFAULT_PROVIDER:-}" in
  auto|openmeteo|metar|tempest) : ;;
  *) DEFAULT_PROVIDER="auto" ;;
esac
provider="${DEFAULT_PROVIDER}"

# COORD_CACHE defaults to inside the config directory if not set
if [ -z "$COORD_CACHE" ]; then
  COORD_CACHE="/etc/asterisk/scripts/saytime-weather/weather-coords.cache"
fi

# ---------- Cache Freshness Check ----------
# The systemd timer is the primary updater. When the cache is fresh:
#   - Normal mode (saytime.pl): skip fetch entirely
#   - Verbose mode (Supermon): serve /tmp/weather-display without an API call
if [ "$opt_no_cache" -eq 0 ] && [ -f "$DESTDIR/temperature" ]; then
  age_min=$(( ( $(date +%s) - $(date -r "$DESTDIR/temperature" +%s) ) / 60 ))
  if [ "$age_min" -lt "${CACHE_MAX_AGE_MIN:-12}" ]; then
    if [ "$display_mode" = "v" ] && [ -f "$DESTDIR/weather-display" ]; then
      cat "$DESTDIR/weather-display"
      exit 0
    elif [ "$display_mode" != "v" ]; then
      log "Cache is ${age_min}m old (< ${CACHE_MAX_AGE_MIN}m), skipping fetch"
      exit 0
    fi
  fi
fi

# ---------- Helpers ----------
toupper(){ tr '[:lower:]' '[:upper:]'; }
round(){ awk -v x="$1" 'BEGIN{printf "%.0f", x+0}'; }

to_cardinal(){
  local deg idx
  deg="$(round "$1")"
  while [ "$deg" -lt 0 ]; do deg=$((deg + 360)); done
  while [ "$deg" -ge 360 ]; do deg=$((deg - 360)); done
  idx=$(( (deg * 100 + 1125) / 2250 ))
  [ "$idx" -ge 16 ] && idx=0
  case "$idx" in
    0)  echo "N"   ;; 1)  echo "NNE" ;; 2)  echo "NE"  ;; 3)  echo "ENE" ;;
    4)  echo "E"   ;; 5)  echo "ESE" ;; 6)  echo "SE"  ;; 7)  echo "SSE" ;;
    8)  echo "S"   ;; 9)  echo "SSW" ;; 10) echo "SW"  ;; 11) echo "WSW" ;;
    12) echo "W"   ;; 13) echo "WNW" ;; 14) echo "NW"  ;; 15) echo "NNW" ;;
    *)  echo "N"   ;;
  esac
}

is_icao_code(){
  local code="$1"
  [[ "$code" =~ ^[A-Z]{4}$ ]] && return 0
  return 1
}

is_special_location(){
  local loc
  loc="$(echo "$1" | toupper | tr -d ' ')"
  case "$loc" in
    SOUTHPOLE|MCMURDO|PALMER|VOSTOK|CASEY|MAWSON|DAVIS|SCOTTBASE|SYOWA|CONCORDIA|HALLEY|DUMONT|SANAE|\
    ALERT|EUREKA|THULE|LONGYEARBYEN|BARROW|RESOLUTE|GRISE|\
    ASCENSION|STHELENA|TRISTAN|BOUVET|HEARD|KERGUELEN|CROZET|AMSTERDAM|MACQUARIE|\
    MIDWAY|WAKE|JOHNSTON|PALMYRA|JARVIS|HOWLAND|BAKER|KINGMAN|\
    DIEGO|CHAGOS|COCOS|CHRISTMAS|\
    FALKLANDS|SOUTHGEORGIA|SOUTHSANDWICH|\
    MARQUESAS|EASTER|PITCAIRN|CLIPPERTON|GALAPAGOS|\
    MAUNA|JUNGFRAUJOCH|MCMURDODRY|ATACAMA|GOUGH|MARION|PRINCE|CAMPBELL|AUCKLAND|KERMADEC|CHATHAM)
      return 0 ;;
    *) return 1 ;;
  esac
}

get_special_coordinates(){
  local loc
  loc="$(echo "$1" | toupper | tr -d ' ')"
  case "$loc" in
    SOUTHPOLE)    echo "-90.0|0.0" ;;
    MCMURDO)      echo "-77.85|166.67" ;;
    PALMER)       echo "-64.77|-64.05" ;;
    VOSTOK)       echo "-78.46|106.84" ;;
    CASEY)        echo "-66.28|110.53" ;;
    MAWSON)       echo "-67.60|62.87" ;;
    DAVIS)        echo "-68.58|77.97" ;;
    SCOTTBASE)    echo "-77.85|166.76" ;;
    SYOWA)        echo "-69.00|39.58" ;;
    CONCORDIA)    echo "-75.10|123.33" ;;
    HALLEY)       echo "-75.58|-26.66" ;;
    DUMONT)       echo "-66.66|140.01" ;;
    SANAE)        echo "-71.67|-2.84" ;;
    ALERT)        echo "82.50|-62.35" ;;
    EUREKA)       echo "79.99|-85.93" ;;
    THULE)        echo "76.53|-68.70" ;;
    LONGYEARBYEN) echo "78.22|15.65" ;;
    BARROW)       echo "71.29|-156.79" ;;
    RESOLUTE)     echo "74.72|-94.83" ;;
    GRISE)        echo "76.42|-82.90" ;;
    ASCENSION)    echo "-7.95|-14.36" ;;
    STHELENA)     echo "-15.97|-5.72" ;;
    TRISTAN)      echo "-37.11|-12.28" ;;
    BOUVET)       echo "-54.42|3.38" ;;
    HEARD)        echo "-53.10|73.51" ;;
    KERGUELEN)    echo "-49.35|70.22" ;;
    CROZET)       echo "-46.43|51.86" ;;
    AMSTERDAM)    echo "-37.83|77.57" ;;
    MACQUARIE)    echo "-54.62|158.86" ;;
    MIDWAY)       echo "28.21|-177.38" ;;
    WAKE)         echo "19.28|166.65" ;;
    JOHNSTON)     echo "16.73|-169.53" ;;
    PALMYRA)      echo "5.89|-162.08" ;;
    JARVIS)       echo "-0.37|-159.99" ;;
    HOWLAND)      echo "0.81|-176.62" ;;
    BAKER)        echo "0.19|-176.48" ;;
    KINGMAN)      echo "6.38|-162.42" ;;
    DIEGO|CHAGOS) echo "-7.26|72.40" ;;
    COCOS)        echo "-12.19|96.83" ;;
    CHRISTMAS)    echo "-10.49|105.62" ;;
    FALKLANDS)    echo "-51.70|-59.52" ;;
    SOUTHGEORGIA) echo "-54.28|-36.51" ;;
    SOUTHSANDWICH) echo "-59.43|-26.35" ;;
    MARQUESAS)    echo "-9.00|-140.00" ;;
    EASTER)       echo "-27.11|-109.36" ;;
    PITCAIRN)     echo "-25.07|-130.10" ;;
    CLIPPERTON)   echo "10.30|-109.22" ;;
    GALAPAGOS)    echo "-0.95|-90.97" ;;
    MAUNA)        echo "19.54|-155.58" ;;
    JUNGFRAUJOCH) echo "46.55|7.98" ;;
    MCMURDODRY)   echo "-77.85|163.00" ;;
    ATACAMA)      echo "-24.50|-69.25" ;;
    GOUGH)        echo "-40.35|-9.88" ;;
    MARION|PRINCE) echo "-46.88|37.86" ;;
    CAMPBELL)     echo "-52.55|169.15" ;;
    AUCKLAND)     echo "-50.73|166.09" ;;
    KERMADEC)     echo "-29.25|-177.92" ;;
    CHATHAM)      echo "-43.95|-176.55" ;;
    *) return 1 ;;
  esac
}

# ---------- Condition Word Mapping ----------
metar_condition_word(){
  local m
  m="$(printf '%s' "$1" | tr -s ' ')"
  [[ "$m" =~ (\+|-)?TS ]]          && { echo "thunderstorm"; return; }
  [[ "$m" =~ FZRA|FZDZ|\+RA|-RA|RA ]] && { echo "rain"; return; }
  [[ "$m" =~ SN ]]                  && { echo "snow"; return; }
  [[ "$m" =~ PL ]]                  && { echo "hail"; return; }
  [[ "$m" =~ FG ]]                  && { echo "fog"; return; }
  [[ "$m" =~ BR|HZ|FU|DU|SA ]]     && { echo "mist"; return; }
  [[ "$m" =~ OVC|BKN|SCT ]]        && { echo "cloudy"; return; }
  echo "clear"
}

openmeteo_condition_word(){
  local code="$1" is_day="${2:-1}"
  case "$code" in
    0)                  echo "clear" ;;
    1|2) [ "$is_day" = "1" ] && echo "sunny" || echo "clear" ;;
    3)                  echo "cloudy" ;;
    45|48)              echo "fog" ;;
    51|53|55|56|57)     echo "rain" ;;
    61|63|65|66|67|80|81|82) echo "rain" ;;
    71|73|75|77|85|86)  echo "snow" ;;
    95|96|99)           echo "thunderstorm" ;;
    *)                  echo "clear" ;;
  esac
}

# Map WeatherFlow condition text to a single word (or two words like "partly cloudy")
tempest_condition_word(){
  local cond
  cond="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$cond" in
    *thunderstorm*|*thunder*)  echo "thunderstorm" ;;
    *heavy*rain*|*rain*heavy*) echo "rain" ;;
    *drizzle*)                 echo "rain" ;;
    *rain*)                    echo "rain" ;;
    *snow*|*sleet*|*blizzard*) echo "snow" ;;
    *hail*)                    echo "hail" ;;
    *fog*|*mist*)              echo "fog" ;;
    *partly*cloud*)            echo "partly cloudy" ;;
    *mostly*cloud*)            echo "cloudy" ;;
    *overcast*|*cloud*)        echo "cloudy" ;;
    *sunny*|*clear*)           echo "clear" ;;
    *fair*)                    echo "clear" ;;
    *)                         echo "clear" ;;
  esac
}

# ---------- Write Condition Sound File ----------
write_condition_gsm(){
  local phrase="$1"
  local sound_dirs=(
    /usr/local/share/asterisk/sounds/custom
    /usr/share/asterisk/sounds/en/wx
    /var/lib/asterisk/sounds
    /usr/share/asterisk/sounds/en
  )

  find_sound_file(){
    local w="$1"
    for dir in "${sound_dirs[@]}"; do
      [ -f "${dir}/${w}.gsm"  ] && { echo "${dir}/${w}.gsm";  return 0; }
      [ -f "${dir}/${w}.ulaw" ] && { echo "${dir}/${w}.ulaw"; return 0; }
    done
    return 1
  }

  # Handle multi-word conditions (e.g. "partly cloudy") by concatenating each word's file
  local files=()
  for word in $phrase; do
    local f
    f="$(find_sound_file "$word" || true)"
    if [ -n "$f" ]; then
      files+=("$f")
    else
      log "No sound file found for condition word: $word"
    fi
  done

  if [ "${#files[@]}" -gt 0 ]; then
    cat "${files[@]}" > "$DESTDIR/condition.gsm.new" && mv "$DESTDIR/condition.gsm.new" "$DESTDIR/condition.gsm"
  else
    log "No sound file found for any word in condition: $phrase"
    rm -f "$DESTDIR/condition.gsm"
  fi
}

# ---------- Coordinate Cache ----------
get_cached_coords(){
  local location="$1"
  if [ -f "$COORD_CACHE" ] && [ "$opt_no_cache" -eq 0 ]; then
    local cached_loc cached_coords
    cached_loc="$(awk -F'|' 'NR==1{print $1}' "$COORD_CACHE" 2>/dev/null || true)"
    cached_coords="$(awk -F'|' 'NR==1{print $2"|"$3}' "$COORD_CACHE" 2>/dev/null || true)"
    if [ "$cached_loc" = "$location" ] && [ -n "$cached_coords" ]; then
      echo "$cached_coords"
      return 0
    fi
  fi
  return 1
}

save_coords(){
  local location="$1" lat="$2" lon="$3"
  local cache_dir
  cache_dir="$(dirname "$COORD_CACHE")"
  if [ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null; then
    echo "${location}|${lat}|${lon}" > "$COORD_CACHE" 2>/dev/null || true
  fi
}

# ---------- Canadian FSA Mapping ----------
get_canadian_city(){
  local fsa="$1"
  case "$fsa" in
    N7L)                  echo "Chatham-Kent, Ontario" ;;
    N7M|N7T)              echo "Sarnia, Ontario" ;;
    N6A|N6B|N6C|N6E|N6G|N6H|N6J|N6K) echo "London, Ontario" ;;
    N8A|N8H|N8N|N8P|N8R|N8S|N8T|N8V|N8W|N8X|N8Y|\
    N9A|N9B|N9C|N9E|N9G|N9H|N9J|N9K|N9Y) echo "Windsor, Ontario" ;;
    N1G|N1H|N1K|N1L)      echo "Guelph, Ontario" ;;
    N3C|N3E|N3H)          echo "Cambridge, Ontario" ;;
    N2C|N2E|N2G|N2H|N2J|N2K|N2L|N2M|N2N|N2P|N2R) echo "Kitchener, Ontario" ;;
    M*)                   echo "Toronto, Ontario" ;;
    V*)                   echo "Vancouver, British Columbia" ;;
    H*)                   echo "Montreal, Quebec" ;;
    T*)                   echo "Calgary, Alberta" ;;
    R*)                   echo "Winnipeg, Manitoba" ;;
    K*)                   echo "Ottawa, Ontario" ;;
    L*)                   echo "Mississauga, Ontario" ;;
    N*)                   echo "London, Ontario" ;;
    P*)                   echo "Thunder Bay, Ontario" ;;
    S*)                   echo "Regina, Saskatchewan" ;;
    E*)                   echo "Moncton, New Brunswick" ;;
    B*)                   echo "Halifax, Nova Scotia" ;;
    *)                    return 1 ;;
  esac
}

# ---------- Postal Code to Coordinates (Nominatim with cache) ----------
postal_to_coordinates(){
  local postal="$1"
  local country="${default_country:-us}"
  local postal_upper
  postal_upper="$(echo "$postal" | toupper)"

  # Check coordinate cache first
  local cached
  cached="$(get_cached_coords "$postal_upper" || true)"
  if [ -n "$cached" ]; then
    log "Using cached coords for $postal_upper: $cached"
    echo "$cached"
    return 0
  fi

  local url=""
  if [[ "$postal_upper" =~ ^[0-9]{5}$ ]]; then
    url="https://nominatim.openstreetmap.org/search?postalcode=${postal}&country=${country}&format=json&limit=1"
  elif [[ "$postal_upper" =~ ^[A-Z][0-9][A-Z][0-9][A-Z][0-9]$ ]] || \
       [[ "$postal_upper" =~ ^[A-Z][0-9][A-Z].?[0-9][A-Z][0-9]$ ]]; then
    local normalized
    normalized="$(echo "$postal_upper" | tr -d ' ' | sed 's/^\([A-Z][0-9][A-Z]\)\([0-9][A-Z][0-9]\)$/\1 \2/')"
    url="https://nominatim.openstreetmap.org/search?postalcode=${normalized}&country=ca&format=json&limit=1"
  else
    url="https://nominatim.openstreetmap.org/search?postalcode=${postal}&format=json&limit=1"
  fi

  log "Calling Nominatim for $postal_upper"
  local response lat lon
  response="$(curl -fsS --connect-timeout 10 -A "ASL3-Time-Weather/3.0 (github.com/N6LKA/ASL3-Time-Weather-Announcement)" \
    "$url" 2>/dev/null || true)"

  if [ -n "$response" ] && [ "$response" != "[]" ]; then
    lat="$(echo "$response" | grep -oP '"lat":"\K[^"]+' | head -n1 || true)"
    lon="$(echo "$response" | grep -oP '"lon":"\K[^"]+' | head -n1 || true)"

    if [ -n "$lat" ] && [ -n "$lon" ]; then
      save_coords "$postal_upper" "$lat" "$lon"
      echo "$lat|$lon"
      return 0
    fi
  fi

  # Canadian FSA fallback
  if [[ "$postal_upper" =~ ^[A-Z][0-9][A-Z] ]]; then
    local fsa="${postal_upper:0:3}"
    local city
    city="$(get_canadian_city "$fsa" || true)"
    if [ -n "$city" ]; then
      sleep 1
      response="$(curl -fsS --connect-timeout 10 \
        -A "ASL3-Time-Weather/3.0 (github.com/N6LKA/ASL3-Time-Weather-Announcement)" \
        "https://nominatim.openstreetmap.org/search?q=$(echo "$city" | sed 's/ /%20/g')&format=json&limit=1" \
        2>/dev/null || true)"
      if [ -n "$response" ] && [ "$response" != "[]" ]; then
        lat="$(echo "$response" | grep -oP '"lat":"\K[^"]+' | head -n1 || true)"
        lon="$(echo "$response" | grep -oP '"lon":"\K[^"]+' | head -n1 || true)"
        if [ -n "$lat" ] && [ -n "$lon" ]; then
          save_coords "$postal_upper" "$lat" "$lon"
          echo "$lat|$lon"
          return 0
        fi
      fi
    fi
  fi

  log "Nominatim lookup failed for $postal_upper"
  return 1
}

# ---------- Provider: NOAA METAR ----------
fetch_metar(){
  local icao
  icao="$(echo "$1" | toupper)"
  local metar temp_f cond

  metar="$(curl --connect-timeout 15 -fsS \
    "https://aviationweather.gov/api/data/metar?ids=${icao}&format=raw&hours=0&taf=false" \
    2>/dev/null | head -n1 || true)"

  if [ -z "$metar" ]; then
    metar="$(curl --connect-timeout 15 -fsS \
      "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${icao}.TXT" \
      2>/dev/null | tail -n1 || true)"
  fi

  [ -z "$metar" ] && { log "METAR: no data for $icao"; return 1; }

  local pair chunk sign num t_c_raw
  pair="$(printf '%s' "$metar" | grep -oE ' [M]?[0-9]{2}/[M]?[0-9]{2} ' | head -n1 || true)"
  [ -z "$pair" ] && { log "METAR: no temp in report for $icao"; return 1; }

  pair="$(printf '%s' "$pair" | tr -d ' ')"
  chunk="${pair%%/*}"
  if [ "${chunk#M}" != "$chunk" ]; then sign='-'; num="${chunk#M}"; else sign=''; num="$chunk"; fi
  num="${num##0}"; [ -z "$num" ] && num=0
  t_c_raw="${sign}${num}"
  temp_f="$(awk -v c="$t_c_raw" 'BEGIN{printf "%.0f", (c*9/5)+32}')"

  cond="$(metar_condition_word "$metar")"

  # Wind: e.g. "18005KT" (dir=180, 5kt) or "18005G13KT" (gust 13kt) or "VRB03KT"
  local wind_field wind_dir_deg speed_gust wind_spd_kt wind_gust_kt wind_mph wind_gust_mph
  wind_field="$(printf '%s' "$metar" | grep -oE '(VRB|[0-9]{3})[0-9]{2,3}(G[0-9]{2,3})?KT' | head -n1 || true)"
  wind_dir_deg=""; wind_mph=""; wind_gust_mph=""
  if [ -n "$wind_field" ]; then
    local dir_raw="${wind_field:0:3}"
    [ "$dir_raw" != "VRB" ] && wind_dir_deg="$((10#$dir_raw))"
    speed_gust="${wind_field:3}"
    speed_gust="${speed_gust%KT}"
    wind_spd_kt="${speed_gust%%G*}"
    if [[ "$speed_gust" == *G* ]]; then wind_gust_kt="${speed_gust#*G}"; else wind_gust_kt=""; fi
    wind_mph="$(awk -v k="$wind_spd_kt" 'BEGIN{printf "%.0f", k*1.15078}')"
    [ -n "$wind_gust_kt" ] && wind_gust_mph="$(awk -v k="$wind_gust_kt" 'BEGIN{printf "%.0f", k*1.15078}')"
  fi

  log "METAR: ${icao} temp=${temp_f}F cond=${cond} wind=${wind_mph:-none}mph"
  # format: temp_f|cond|feels_like_f|humidity|wind_mph|wind_dir_deg|gust_mph
  # (METAR does not provide feels-like or humidity)
  echo "${temp_f}|${cond}|||${wind_mph}|${wind_dir_deg}|${wind_gust_mph}"
}

# ---------- Provider: Open-Meteo ----------
fetch_openmeteo(){
  local location="$1"
  local coords lat lon

  if is_special_location "$location"; then
    coords="$(get_special_coordinates "$location")"
  elif is_icao_code "$(echo "$location" | toupper)"; then
    # Fetch ICAO station coords via aviationweather
    local icao
    icao="$(echo "$location" | toupper)"
    local info
    info="$(curl --connect-timeout 10 -fsS \
      "https://aviationweather.gov/api/data/airport?ids=${icao}&format=json" \
      2>/dev/null || true)"
    lat="$(echo "$info" | grep -oP '"lat":\K[-0-9.]+' | head -n1 || true)"
    lon="$(echo "$info" | grep -oP '"lon":\K[-0-9.]+' | head -n1 || true)"
    [ -n "$lat" ] && [ -n "$lon" ] && coords="${lat}|${lon}" || coords=""
  else
    coords="$(postal_to_coordinates "$location" || true)"
  fi

  [ -z "$coords" ] && { log "OpenMeteo: could not resolve coords for $location"; return 1; }

  lat="${coords%%|*}"
  lon="${coords##*|}"

  local data temp code isday feels humidity wind_speed wind_dir wind_gust
  data="$(curl -fsS --connect-timeout 15 \
    "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m,wind_gusts_10m&temperature_unit=fahrenheit&wind_speed_unit=mph&timezone=auto" \
    2>/dev/null || true)"

  [ -z "$data" ] && { log "OpenMeteo: empty response for $location"; return 1; }

  temp="$(echo "$data"      | grep -oP '"temperature_2m":\K[-0-9.]+' | head -n1 || true)"
  feels="$(echo "$data"     | grep -oP '"apparent_temperature":\K[-0-9.]+' | head -n1 || true)"
  humidity="$(echo "$data"  | grep -oP '"relative_humidity_2m":\K[0-9]+' | head -n1 || true)"
  code="$(echo "$data"      | grep -oP '"weather_code":\K[0-9]+' | head -n1 || true)"
  isday="$(echo "$data"     | grep -oP '"is_day":\K[01]' | head -n1 || true)"
  wind_speed="$(echo "$data"| grep -oP '"wind_speed_10m":\K[-0-9.]+' | head -n1 || true)"
  wind_dir="$(echo "$data"  | grep -oP '"wind_direction_10m":\K[-0-9.]+' | head -n1 || true)"
  wind_gust="$(echo "$data" | grep -oP '"wind_gusts_10m":\K[-0-9.]+' | head -n1 || true)"

  [ -z "$temp" ] && { log "OpenMeteo: could not parse temperature for $location"; return 1; }

  local tf fl wm wd wg
  tf="$(round "$temp")"
  fl="$([ -n "$feels" ] && round "$feels" || echo "")"
  wm="$([ -n "$wind_speed" ] && round "$wind_speed" || echo "")"
  wd="$([ -n "$wind_dir" ] && round "$wind_dir" || echo "")"
  wg="$([ -n "$wind_gust" ] && round "$wind_gust" || echo "")"
  [ -z "$isday" ] && isday="1"
  local cond
  cond="$(openmeteo_condition_word "${code:-0}" "${isday}")"

  log "OpenMeteo: $location temp=${tf}F feels=${fl}F humidity=${humidity}% cond=${cond} wind=${wm}mph"
  echo "${tf}|${cond}|${fl}|${humidity}|${wm}|${wd}|${wg}"
}

# ---------- Provider: WeatherFlow Tempest ----------
fetch_tempest(){
  local token="${TempestToken:-}"
  local station="${TempestStationID:-}"

  if [ -z "$token" ]; then
    log "Tempest: TempestToken not configured"
    return 1
  fi

  # Auto-detect station if not set
  if [ -z "$station" ]; then
    log "Tempest: TempestStationID not set, attempting auto-detect"
    local stations_json
    stations_json="$(curl -fsS --connect-timeout 10 \
      "https://swd.weatherflow.com/swd/rest/stations?token=${token}" \
      2>/dev/null || true)"
    station="$(echo "$stations_json" | grep -oP '"station_id":\K[0-9]+' | head -n1 || true)"
    if [ -z "$station" ]; then
      log "Tempest: could not auto-detect station ID"
      return 1
    fi
    log "Tempest: auto-detected station $station"
  fi

  local data
  data="$(curl -fsS --connect-timeout 15 \
    "https://swd.weatherflow.com/swd/rest/better_forecast?station_id=${station}&units_temp=f&units_wind=mph&units_pressure=mb&units_precip=in&units_distance=mi&token=${token}" \
    2>/dev/null || true)"

  [ -z "$data" ] && { log "Tempest: empty response for station $station"; return 1; }

  local temp feels humidity cond_text cond wind_speed wind_dir wind_gust
  temp="$(echo "$data"      | grep -oP '"air_temperature":\K[-0-9.]+' | head -n1 || true)"
  feels="$(echo "$data"     | grep -oP '"feels_like":\K[-0-9.]+' | head -n1 || true)"
  humidity="$(echo "$data"  | grep -oP '"relative_humidity":\K[0-9]+' | head -n1 || true)"
  cond_text="$(echo "$data" | grep -oP '"conditions":"\K[^"]+' | head -n1 || true)"
  wind_speed="$(echo "$data"| grep -oP '"wind_avg":\K[-0-9.]+' | head -n1 || true)"
  wind_dir="$(echo "$data"  | grep -oP '"wind_direction":\K[-0-9.]+' | head -n1 || true)"
  wind_gust="$(echo "$data" | grep -oP '"wind_gust":\K[-0-9.]+' | head -n1 || true)"

  [ -z "$temp" ] && { log "Tempest: could not parse temperature for station $station"; return 1; }

  local tf fl wm wd wg
  tf="$(round "$temp")"
  fl="$([ -n "$feels" ] && round "$feels" || echo "")"
  wm="$([ -n "$wind_speed" ] && round "$wind_speed" || echo "")"
  wd="$([ -n "$wind_dir" ] && round "$wind_dir" || echo "")"
  wg="$([ -n "$wind_gust" ] && round "$wind_gust" || echo "")"
  cond="$(tempest_condition_word "${cond_text:-clear}")"

  log "Tempest: station=$station temp=${tf}F feels=${fl}F humidity=${humidity}% cond=${cond} wind=${wm}mph raw_cond='${cond_text}'"
  echo "${tf}|${cond}|${fl}|${humidity}|${wm}|${wd}|${wg}"
}

# ---------- Main ----------
if [ -z "$location_arg" ] && [ "$provider" != "tempest" ]; then
  show_help
fi

arg="${location_arg:-}"
result=""

log "Starting weather fetch: provider=$provider location='$arg'"

if [ "$provider" = "tempest" ]; then
  result="$(fetch_tempest || true)"
  if [ -z "$result" ]; then
    log "Tempest failed, falling back to openmeteo"
    [ -n "$arg" ] && result="$(fetch_openmeteo "$arg" || true)"
  fi
elif is_icao_code "$(echo "$arg" | toupper)"; then
  if [ "$provider" = "openmeteo" ]; then
    result="$(fetch_openmeteo "$arg" || true)"
    [ -z "$result" ] && result="$(fetch_metar "$arg" || true)"
  else
    result="$(fetch_metar "$arg" || true)"
    [ -z "$result" ] && result="$(fetch_openmeteo "$arg" || true)"
  fi
elif is_special_location "$arg"; then
  result="$(fetch_openmeteo "$arg" || true)"
else
  # Postal code
  if [ "$provider" = "metar" ]; then
    result="$(fetch_metar "$arg" || true)"
    [ -z "$result" ] && result="$(fetch_openmeteo "$arg" || true)"
  else
    result="$(fetch_openmeteo "$arg" || true)"
    [ -z "$result" ] && result="$(fetch_metar "$arg" || true)"
  fi
fi

if [ -z "$result" ]; then
  log "All providers failed for location='$arg'"
  echo "No weather data available"
  exit 1
fi

# Parse result: temp_f|cond|feels_like_f|humidity|wind_mph|wind_dir_deg|gust_mph
IFS='|' read -r temp_f cond feels_f humidity wind_mph wind_dir gust_mph <<< "$result"

ctemp="$(awk -v f="$temp_f" 'BEGIN{printf "%.0f", (f-32)*5/9}')"

# Feels-like in C
if [ -n "$feels_f" ]; then
  feels_c="$(awk -v f="$feels_f" 'BEGIN{printf "%.0f", (f-32)*5/9}')"
else
  feels_c=""
fi

# ---------- Build Display Line (Supermon-compatible) ----------
cond_display="$(echo "$cond" | sed -e 's/\b\(.\)/\u\1/g')"
display_line="${temp_f}°F, ${ctemp}°C"
[ -n "$humidity" ] && display_line="${display_line}, ${humidity}% RH"
display_line="${display_line} / ${cond_display}"
if [ -n "$wind_mph" ] && [ "$wind_mph" != "0" ]; then
  wind_dir_word=""
  [ -n "$wind_dir" ] && wind_dir_word="$(to_cardinal "$wind_dir")"
  wind_part="Wind ${wind_mph} mph"
  [ -n "$wind_dir_word" ] && wind_part="${wind_part} ${wind_dir_word}"
  if [ -n "$gust_mph" ] && [ "$gust_mph" -gt "$wind_mph" ] 2>/dev/null; then
    wind_part="${wind_part} (gust ${gust_mph})"
  fi
  display_line="${display_line}, ${wind_part}"
fi

# ---------- Output ----------
if [ "$display_mode" = "v" ]; then
  # Single-line output — Supermon reads this via PHP exec() which returns only
  # the last line, so verbose mode must always be exactly one line.
  echo "$display_line" > "$DESTDIR/weather-display.new" 2>/dev/null && \
    mv "$DESTDIR/weather-display.new" "$DESTDIR/weather-display" 2>/dev/null || true
  echo "$display_line"
  # Log extra detail for debugging without breaking the single-line guarantee
  [ -n "$feels_f" ] && log "Feels like: ${feels_f}°F, ${feels_c}°C"
  exit 0
fi

# Write temperature atomically
if [ "${Temperature_mode:-F}" = "C" ]; then
  echo "$ctemp" > "$DESTDIR/temperature.new" && mv "$DESTDIR/temperature.new" "$DESTDIR/temperature"
else
  echo "$temp_f" > "$DESTDIR/temperature.new" && mv "$DESTDIR/temperature.new" "$DESTDIR/temperature"
fi

# Write feels-like atomically (if enabled and available)
if [ "${ANNOUNCE_FEELS_LIKE:-no}" = "yes" ] && [ -n "$feels_f" ]; then
  if [ "${Temperature_mode:-F}" = "C" ]; then
    echo "$feels_c" > "$DESTDIR/feels-like.new" && mv "$DESTDIR/feels-like.new" "$DESTDIR/feels-like"
  else
    echo "$feels_f" > "$DESTDIR/feels-like.new" && mv "$DESTDIR/feels-like.new" "$DESTDIR/feels-like"
  fi
else
  rm -f "$DESTDIR/feels-like"
fi

# Write humidity atomically (if enabled and available)
if [ "${ANNOUNCE_HUMIDITY:-no}" = "yes" ] && [ -n "$humidity" ]; then
  echo "$humidity" > "$DESTDIR/humidity.new" && mv "$DESTDIR/humidity.new" "$DESTDIR/humidity"
else
  rm -f "$DESTDIR/humidity"
fi

# Write condition sound file
if [ "${process_condition:-YES}" = "YES" ]; then
  write_condition_gsm "$cond"
fi

# Write one-line display string so Supermon can serve it from cache without an API call
echo "$display_line" > "$DESTDIR/weather-display.new" && \
  mv "$DESTDIR/weather-display.new" "$DESTDIR/weather-display" 2>/dev/null || true

log "Weather written: temp=${temp_f}F cond=${cond}"
exit 0
