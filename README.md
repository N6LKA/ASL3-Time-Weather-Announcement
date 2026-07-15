# ASL3 Time and Weather Announcement

![Release Version](https://img.shields.io/github/v/release/N6LKA/ASL3-Time-Weather-Announcement?label=Version&color=f15d24)
![Release Date](https://img.shields.io/github/release-date/N6LKA/ASL3-Time-Weather-Announcement?label=Released&color=f15d24)
![Hits](https://img.shields.io/endpoint?url=https%3A%2F%2Fhits.dwyl.com%2FN6LKA%2FASL3-Time-Weather-Announcement.json&label=Hits&color=f15d24)
![GitHub Repo Size](https://img.shields.io/github/repo-size/N6LKA/ASL3-Time-Weather-Announcement?label=Size&color=f15d24)

<img src="TimeWeather.png" alt="Time and Weather Logo" height="120">

---

An automated top-of-the-hour time and current weather conditions announcement system for [AllStar](https://allstarlink.org/) nodes running ASL3 on Debian.

Supports US ZIP codes, ICAO airport codes, Canadian postal codes, international locations, and personal WeatherFlow Tempest weather stations.

---

## Requirements

- AllStar ASL3 on Debian 12 (Bookworm) or Debian 13 (Trixie)
- `curl`, `perl` — pre-installed on most ASL3 systems
- `bc`, `unzip`, `plocate` — installed automatically during setup

---

## Installation

### Stable (recommended)

```bash
curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/N6LKA/ASL3-Time-Weather-Announcement/main/install.sh | sudo bash
```

### Development / Testing (develop branch)

> ⚠️ **Warning:** `develop` may contain incomplete or untested changes. Only use this on a system you can afford to break.

```bash
curl -fsSL "https://github.com/N6LKA/ASL3-Time-Weather-Announcement/archive/refs/heads/develop.tar.gz" \
  | tar -xzO ASL3-Time-Weather-Announcement-develop/install.sh \
  | sudo bash -s -- --branch develop
```

The tarball form is used instead of the raw GitHub URL because `raw.githubusercontent.com` is CDN-cached and can serve a stale `install.sh`; the tarball goes through GitHub's codeload service which always returns the current commit.

The installer will prompt for:
- **ZIP code or ICAO airport code** — your location (e.g. `90210` or `KJFK`)
- **AllStar node number** — your ASL3 node number
- **Time format** — 12-hour or 24-hour
- **Tempest credentials** — optional; leave blank to use NOAA/Open-Meteo

**Updating:** Run the same install command again. Your existing `weather.ini` is preserved and only the changed settings are updated.

---

## What It Does

- Announces the current local time at the top of every hour
- Retrieves current weather conditions and temperature
- Optionally announces feels-like temperature and humidity
- Plays announcements using pre-recorded GSM audio files
- Keeps weather data fresh via a systemd timer (every 10 minutes)
- Pre-built audio is always available for on-demand DTMF playback

---

## Files

All program files are installed to `/etc/asterisk/scripts/saytime-weather/`:

| File | Description |
|---|---|
| `saytime.pl` | Main script — builds and plays time+weather announcement |
| `weather.sh` | Weather fetcher — writes `/tmp/temperature`, `/tmp/condition.gsm` |
| `weather.ini` | Configuration file |
| `weather-location.env` | Location setting for the systemd service |
| `uninstall.sh` | Clean removal script |

Sound files are installed to `/usr/local/share/asterisk/sounds/custom/` (shared with other ASL3 programs).

---

## Configuration

Edit `/etc/asterisk/scripts/saytime-weather/weather.ini`:

| Setting | Default | Description |
|---|---|---|
| `DEFAULT_PROVIDER` | `auto` | Weather source: `auto`, `metar`, `openmeteo`, or `tempest` |
| `Temperature_mode` | `F` | `F` for Fahrenheit, `C` for Celsius |
| `TIME_FORMAT` | `12` | `12` for 12-hour with AM/PM, `24` for 24-hour |
| `process_condition` | `YES` | Announce weather conditions (cloudy, rain, etc.) |
| `ANNOUNCE_FEELS_LIKE` | `no` | Also announce feels-like temperature |
| `ANNOUNCE_HUMIDITY` | `no` | Also announce humidity percentage |
| `TempestToken` | _(blank)_ | WeatherFlow API token (required for Tempest) |
| `TempestStationID` | _(blank)_ | Tempest station ID (blank = auto-detect) |
| `CACHE_MAX_AGE_MIN` | `12` | Skip fetch if cache is this fresh (minutes) |

---

## Tempest Weather Station

If you have a [WeatherFlow Tempest](https://weatherflow.com/tempest-weather-system/) personal weather station, set `DEFAULT_PROVIDER="tempest"` and fill in your API token and station ID. This uses your station's data directly — the announced temperature matches what displays on Allmon3 and Supermon.

Get your API token at: https://tempestwx.com/settings/tokens

---

## Testing

```bash
# Test weather fetch (no files written)
/etc/asterisk/scripts/saytime-weather/weather.sh 90210 v

# Force a fresh fetch (bypass cache)
/etc/asterisk/scripts/saytime-weather/weather.sh --no-cache 90210 v

# Test full announcement (plays to node)
perl /etc/asterisk/scripts/saytime-weather/saytime.pl 90210 <NodeNumber>

# Check weather timer
systemctl status asl3-saytime-weather.timer

# View weather fetch logs
cat /tmp/weather-debug.log
journalctl -u asl3-saytime-weather
```

---

## Uninstalling

```bash
sudo /etc/asterisk/scripts/saytime-weather/uninstall.sh
```

Removes scripts, config, systemd timer, and cron entry. Sound files are left in place (shared with other programs).

---

## Credits

| Script | Author(s) |
|---|---|
| `saytime.pl` | D. Crompton (WA3DSP) — original author |
| `weather.sh` | Jory A. Pratt (W5GLE), based on original work by D. Crompton (WA3DSP), modified by Joe (KD2NFC) |
| `install.sh` | Freddie Mac (KD5FMU) and Jory A. Pratt (W5GLE) — original; modified and updated by Larry K. Aycock (N6LKA) |

---

## License

GNU General Public License version 3 (GPL-3.0)

See [LICENSE](LICENSE) for details.
