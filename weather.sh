#!/usr/bin/env bash
# weather.sh — worldwide terminal weather station v1.1 (single file)
# ONE question: city / state / country / pin-zip code (entire planet, OpenStreetMap)
# Panels: NOW · next 12h · 7-day · month outlook · LAST MONTH (real archive)
# Data: open-meteo.com + nominatim.openstreetmap.org — free, NO API key
# Every report saved to ~/weather_logs/
# USAGE: ./weather.sh [place] | -u imperial | --selftest | --gen-files | -h | -V
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
VERSION="1.1.0"
UNITS="metric"; TIMEOUT=20; HOURLY_COUNT=12; SAVE_LOG=1
LOG_DIR="$HOME/weather_logs"
QUERY_TEXT=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
    GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'
    CYN=$'\033[1;36m'; MAG=$'\033[1;35m'
else
    R=""; B=""; DIM=""; GRN=""; YLW=""; RED=""; CYN=""; MAG=""
fi
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$R" "$1"; }
warn() { printf '  %s[!!] %s%s\n' "$YLW" "$1" "$R"; }
err()  { printf '  %s[XX] %s%s\n' "$RED" "$1" "$R" >&2; }
sect() { printf '\n%s%s── %s %s%s\n' "$B$MAG" "" "$1" "$(printf '─%.0s' $(seq 1 46))" "$R"; }
die()  { err "$2"; exit "$1"; }
unit_sym()   { [[ "$UNITS" == imperial ]] && printf '°F' || printf '°C'; }
wind_sym()   { [[ "$UNITS" == imperial ]] && printf 'mph' || printf 'km/h'; }

# ---------- JSON access via python3 (robust; arrays come back comma-joined) --
jget() { # jget <json> '<py-path e.g. ["current"]["temperature_2m"]>'
    printf '%s' "$1" | JPATH="$2" python3 -c '
import json,sys,os
try:
    v=json.load(sys.stdin)
    for k in os.environ["JPATH"].split("]["):
        k=k.strip("[]").replace("\"","").replace("\x27","")
        v=v[int(k)] if k.lstrip("-").isdigit() else v[k]
    print(",".join(map(str,v)) if isinstance(v,list) else v)
except Exception:
    pass'
}
arr_el() { # arr_el "a,b,c" 1 → b
    local IFS=','; local -a a; read -r -a a <<< "$1"; printf '%s' "${a[$2]:-}"
}

# ---------- WMO weather codes → words + icon ---------------------------------
wx_desc() { case "$1" in
    0) echo "Clear sky";; 1) echo "Mainly clear";; 2) echo "Partly cloudy";;
    3) echo "Overcast";; 45|48) echo "Fog";;
    51) echo "Light drizzle";; 53) echo "Drizzle";; 55) echo "Heavy drizzle";;
    56|57) echo "Freezing drizzle";; 61) echo "Light rain";; 63) echo "Rain";;
    65) echo "Heavy rain";; 66|67) echo "Freezing rain";;
    71) echo "Light snow";; 73) echo "Snow";; 75) echo "Heavy snow";;
    77) echo "Snow grains";; 80) echo "Rain showers";; 81) echo "Heavy showers";;
    82) echo "Violent showers";; 85|86) echo "Snow showers";;
    95) echo "Thunderstorm";; 96|99) echo "Thunderstorm + hail";;
    *) echo "Unknown";; esac; }
wx_icon() { case "$1" in
    0) printf '%s☀%s' "$YLW" "$R";; 1|2) printf '%s🌤%s' "$YLW" "$R";;
    3) printf '%s☁%s' "$DIM" "$R";; 45|48) printf '%s🌫%s' "$DIM" "$R";;
    5[1-7]) printf '%s🌦%s' "$CYN" "$R";;
    6[1-7]|8[0-2]) printf '%s🌧%s' "$CYN" "$R";;
    7[1-7]) printf '%s❄%s' "$CYN" "$R";;
    9[5-9]) printf '%s⛈%s' "$MAG" "$R";;
    *) printf '%s•%s' "$DIM" "$R";; esac; }
feel_emoji() { # $1=number, $2=unit symbol
    local t="${1%%.*}" u="$2"
    if [[ "$u" == "°F" ]]; then
        (( t <= 32 )) && { printf '🥶'; return; }
        (( t <= 50 )) && { printf '🧥'; return; }
        (( t <= 80 )) && { printf '🙂'; return; }
        (( t <= 95 )) && { printf '😅'; return; }
        printf '🥵'
    else
        (( t <= 0 ))  && { printf '🥶'; return; }
        (( t <= 10 )) && { printf '🧥'; return; }
        (( t <= 27 )) && { printf '🙂'; return; }
        (( t <= 35 )) && { printf '😅'; return; }
        printf '🥵'
    fi
}

# ---------- GEOCODING: OpenStreetMap Nominatim — worldwide -------------------
GEO_NAME=""; GEO_COUNTRY=""; GEO_LAT=""; GEO_LON=""
geocode() {
    local q="$1" raw enc count i lat lon label
    printf '\n%s▸ Looking up: %s%s\n' "$CYN$B" "$q" "$R"
    enc="$(printf '%s' "$q" | sed 's/ /%20/g; s/,/%2C/g')"
    raw="$(curl -fsS --max-time "$TIMEOUT" \
        -H 'User-Agent: weather-bash/1.1 (personal terminal weather tool)' \
        "https://nominatim.openstreetmap.org/search?q=${enc}&format=json&limit=8" 2>/dev/null)" \
        || die 1 "cannot reach OpenStreetMap geocoder — check internet"
    [[ -z "$raw" || "$raw" == "[]" ]] \
        && die 1 "nothing found for '${q}' — try a city, state, country, or pin/zip code"

    local -a lats=() lons=() labels=()
    count="$(printf '%s' "$raw" | grep -o '"lat"' | wc -l)"
    for (( i=0; i<count; i++ )); do
        lat="$(printf '%s' "$raw" | tr '{' '\n' | grep '"lat"' | sed -n "$((i+1))p" | sed 's/.*"lat":"//; s/".*//')"
        lon="$(printf '%s' "$raw" | tr '{' '\n' | grep '"lon"' | sed -n "$((i+1))p" | sed 's/.*"lon":"//; s/".*//')"
        label="$(printf '%s' "$raw" | tr '{' '\n' | grep '"display_name"' | sed -n "$((i+1))p" | sed 's/.*"display_name":"//; s/",".*//')"
        [[ -z "$lat" || -z "$lon" || -z "$label" ]] && continue
        lats+=("$lat"); lons+=("$lon"); labels+=("$label")
    done
    (( ${#lats[@]} == 0 )) && die 1 "matches found but could not be parsed"

    if (( ${#lats[@]} == 1 )); then
        GEO_LAT="${lats[0]}"; GEO_LON="${lons[0]}"
        GEO_NAME="${labels[0]%%,*}"; GEO_COUNTRY="${labels[0]##*, }"
        ok "found: ${labels[0]}"
        return 0
    fi
    printf '  %s found %s matches — pick one:%s\n' "$B" "${#lats[@]}" "$R"
    local i2
    for i2 in "${!labels[@]}"; do printf '   %2d) %s\n' $(( i2+1 )) "${labels[$i2]}"; done
    local choice
    read -r -p "$(printf '  number [1-%d]: ' "${#lats[@]}")" choice || die 2 "aborted"
    [[ "$choice" =~ ^[0-9]+$ ]] || die 2 "not a number"
    (( choice >= 1 && choice <= ${#lats[@]} )) || die 2 "out of range"
    local idx=$(( choice - 1 ))
    GEO_LAT="${lats[$idx]}"; GEO_LON="${lons[$idx]}"
    GEO_NAME="${labels[$idx]%%,*}"; GEO_COUNTRY="${labels[$idx]##*, }"
    ok "selected: ${labels[$idx]}"
}

# ---------- FETCH -------------------------------------------------------------
WX=""; ARC=""
fetch_all() {
    sect "Fetching forecast"
    local url="https://api.open-meteo.com/v1/forecast?latitude=${GEO_LAT}&longitude=${GEO_LON}"
    url+="&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"
    url+="&hourly=temperature_2m,weather_code,precipitation_probability"
    url+="&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
    url+="&timezone=auto&forecast_days=7"
    [[ "$UNITS" == imperial ]] && url+="&temperature_unit=fahrenheit&wind_speed_unit=mph"
    WX="$(curl -fsS --max-time "$TIMEOUT" "$url" 2>/dev/null)" \
        || die 1 "weather fetch failed — check internet"
    ok "forecast received"

    local y m from to
    y="$(date -d 'last month' +%Y)"; m="$(date -d 'last month' +%m)"
    from="${y}-${m}-01"
    to="$(date -d "$from +1 month -1 day" +%Y-%m-%d)"
    local aurl="https://archive-api.open-meteo.com/v1/archive?latitude=${GEO_LAT}&longitude=${GEO_LON}"
    aurl+="&daily=temperature_2m_max,temperature_2m_min&start_date=${from}&end_date=${to}&timezone=auto"
    [[ "$UNITS" == imperial ]] && aurl+="&temperature_unit=fahrenheit"
    ARC="$(curl -fsS --max-time "$TIMEOUT" "$aurl" 2>/dev/null)" || ARC=""
    [[ -n "$ARC" ]] && ok "last-month archive received" || warn "archive unavailable (panel will skip)"
}

# ---------- PANELS -------------------------------------------------------------
p_now() {
    sect "NOW — $(date '+%A %d %B %Y · %H:%M %Z')"
    local t f h w c ts
    t="$(jget "$WX" '["current"]["temperature_2m"]')"
    f="$(jget "$WX" '["current"]["apparent_temperature"]')"
    h="$(jget "$WX" '["current"]["relative_humidity_2m"]')"
    w="$(jget "$WX" '["current"]["wind_speed_10m"]')"
    c="$(jget "$WX" '["current"]["weather_code"]')"
    ts="$(jget "$WX" '["current"]["time"]')"
    local u; u="$(unit_sym)"
    printf '\n   %s %s%s%s   %s\n' "$(wx_icon "$c")" "$B" "$t" "$R$u" "$(feel_emoji "$t" "$u")"
    printf '   %s — feels like %s%s\n' "$(wx_desc "$c")" "$f" "$u"
    printf '   humidity %s%%  ·  wind %s %s\n' "$h" "$w" "$(wind_sym)"
    printf '   %s%s, %s\n' "$B" "$GEO_NAME" "$GEO_COUNTRY"
    printf '   observed at: %s\n' "$ts"
}
p_hourly() {
    sect "NEXT ${HOURLY_COUNT} HOURS"
    local times temps codes probs
    times="$(jget "$WX" '["hourly"]["time"]')"
    temps="$(jget "$WX" '["hourly"]["temperature_2m"]')"
    codes="$(jget "$WX" '["hourly"]["weather_code"]')"
    probs="$(jget "$WX" '["hourly"]["precipitation_probability"]')"
    [[ -z "$times" ]] && { warn "hourly data missing"; return 0; }
    local now_key start=0 i
    now_key="$(date '+%Y-%m-%dT%H')"
    local -a TA; IFS=',' read -r -a TA <<< "$times"
    for i in "${!TA[@]}"; do [[ "${TA[$i]}" == *"$now_key"* ]] && { start=$i; break; }; done
    local u; u="$(unit_sym)"
    printf '\n  %-7s %6s  %5s  %s\n' "TIME" "TEMP" "RAIN%" "SKY"
    local j end hh tt cc pp
    end=$(( start + HOURLY_COUNT ))
    for (( j=start; j<end && j<${#TA[@]}; j++ )); do
        hh="$(arr_el "$times" "$j")"; hh="${hh##*T}"
        tt="$(arr_el "$temps" "$j")"
        cc="$(arr_el "$codes" "$j")"
        pp="$(arr_el "$probs" "$j")"
        printf '  %-7s %5s%s  %4s%%  %s %s\n' "$hh" "$tt" "$u" "${pp:-0}" "$(wx_icon "$cc")" "$(wx_desc "$cc")"
    done
}
p_daily() {
    sect "7-DAY FORECAST"
    local dts maxs mins codes prs count i d mx mn cc pp
    dts="$(jget "$WX" '["daily"]["time"]')"
    maxs="$(jget "$WX" '["daily"]["temperature_2m_max"]')"
    mins="$(jget "$WX" '["daily"]["temperature_2m_min"]')"
    codes="$(jget "$WX" '["daily"]["weather_code"]')"
    prs="$(jget "$WX" '["daily"]["precipitation_probability_max"]')"
    [[ -z "$dts" ]] && { warn "daily data missing"; return 0; }
    IFS=',' read -r -a _t <<< "$dts"; count=${#_t[@]}
    local u; u="$(unit_sym)"
    printf '\n  %-12s %6s %6s  %5s  %s\n' "DAY" "MAX" "MIN" "RAIN%" "SKY"
    for (( i=0; i<count; i++ )); do
        d="$(arr_el "$dts" "$i")";  mx="$(arr_el "$maxs" "$i")"
        mn="$(arr_el "$mins" "$i")"; cc="$(arr_el "$codes" "$i")"
        pp="$(arr_el "$prs" "$i")"
        printf '  %-12s %5s%s %5s%s  %4s%%  %s %s\n' \
            "$(date -d "$d" '+%a %d %b' 2>/dev/null || echo "$d")" \
            "$mx" "$u" "$mn" "$u" "${pp:-0}" "$(wx_icon "$cc")" "$(wx_desc "$cc")"
    done
}
p_month() {
    sect "COMING WEEK vs LAST MONTH"
    local maxs mins count i mx mn sum=0 n=0 hot=-9999 cold=9999
    maxs="$(jget "$WX" '["daily"]["temperature_2m_max"]')"
    mins="$(jget "$WX" '["daily"]["temperature_2m_min"]')"
    if [[ -n "$maxs" ]]; then
        IFS=',' read -r -a _m <<< "$maxs"; count=${#_m[@]}
        for (( i=0; i<count; i++ )); do
            mx="$(arr_el "$maxs" "$i")"; mx="${mx%%.*}"; mx="${mx:-0}"
            sum=$(( sum + mx )); n=$(( n + 1 ))
            (( mx > hot )) && hot=$mx
        done
    fi
    local u; u="$(unit_sym)"
    [[ $n -gt 0 ]] && printf '\n  coming 7 days: avg high %s%s · peak %s%s\n' \
        "$(( sum / n ))" "$u" "$hot" "$u"
    if [[ -n "$ARC" ]]; then
        local amax amins acount amx amn asum=0 an=0 ahot=-9999 acold=9999
        amax="$(jget "$ARC" '["daily"]["temperature_2m_max"]')"
        amins="$(jget "$ARC" '["daily"]["temperature_2m_min"]')"
        if [[ -n "$amax" ]]; then
            IFS=',' read -r -a _am <<< "$amax"; acount=${#_am[@]}
            for (( i=0; i<acount; i++ )); do
                amx="$(arr_el "$amax" "$i")"; amx="${amx%%.*}"; amx="${amx:-0}"
                amn="$(arr_el "$amins" "$i")"; amn="${amn%%.*}"; amn="${amn:-0}"
                asum=$(( asum + amx )); an=$(( an + 1 ))
                (( amx > ahot )) && ahot=$amx
                (( amn < acold )) && acold=$amn
            done
            printf '  last month   : %s days · avg high %s%s · peak %s%s · coldest %s%s\n' \
                "$an" "$(( asum / an ))" "$u" "$ahot" "$u" "$acold" "$u"
            (( n > 0 )) && printf '  trend        : coming week vs last month avg: %+d%s\n' \
                "$(( (sum / n) - (asum / an) ))" "$u"
        fi
    else
        warn "last-month archive unavailable"
    fi
}
render_all() { p_now; p_hourly; p_daily; p_month; }

# ---------- LOG ----------------------------------------------------------------
REPORT=""
save_log() {
    [[ "$SAVE_LOG" -eq 1 ]] || return 0
    mkdir -p "$LOG_DIR"
    local stamp; stamp="$(date '+%Y%m%d_%H%M%S')"
    local label; label="$(printf '%s_%s' "$GEO_NAME" "$GEO_COUNTRY" | tr -c 'A-Za-z0-9._-' '_')"
    REPORT="$LOG_DIR/${label}_${stamp}.txt"
    {
        printf 'WEATHER REPORT — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'location: %s, %s (%s, %s)\n\n' "$GEO_NAME" "$GEO_COUNTRY" "$GEO_LAT" "$GEO_LON"
    } > "$REPORT"
    R=""; B=""; DIM=""; GRN=""; YLW=""; RED=""; CYN=""; MAG=""
    render_all >> "$REPORT"
    ok "report saved: $REPORT"
    printf '\n%sdata: open-meteo.com + openstreetmap.org (free, no key)%s\n\n' "$DIM" "$R"
}

# ---------- SELF-TEST (offline) --------------------------------------------------
self_test() {
    local pass=0 fail=0 out
    oks()  { printf '  %sPASS%s %s\n' "$GRN" "$R" "$1"; pass=$((pass+1)); }
    bads() { printf '  %sFAIL%s %s\n' "$RED" "$R" "$1"; fail=$((fail+1)); }
    printf '%sWEATHER SELF-TEST (offline)%s\n' "$CYN" "$R"

    command -v python3 > /dev/null 2>&1 && oks "python3 present" || bads "python3 missing (sudo apt install python3)"
    out="$(jget '{"a":{"b":42}}' '["a"]["b"]')"
    [[ "$out" == "42" ]] && oks "jget nested number" || bads "jget number ('$out')"
    out="$(jget '{"t":["x","y","z"]}' '["t"]')"
    [[ "$out" == "x,y,z" ]] && oks "jget array → comma list" || bads "jget array ('$out')"
    out="$(arr_el "10,20,30" 1)"
    [[ "$out" == "20" ]] && oks "arr_el [1]" || bads "arr_el ('$out')"
    out="$(wx_desc 0)";  [[ "$out" == "Clear sky" ]] && oks "wx_desc 0" || bads "wx_desc 0"
    out="$(wx_desc 95)"; [[ "$out" == "Thunderstorm" ]] && oks "wx_desc 95" || bads "wx_desc 95"
    out="$(wx_desc 123)"; [[ "$out" == "Unknown" ]] && oks "wx_desc unknown" || bads "wx_desc unknown"
    UNITS=metric;  out="$(feel_emoji 40 "$(unit_sym)");" ; [[ -n "$out" ]] && oks "feel_emoji metric" || bads "feel_emoji metric"
    UNITS=imperial; out="$(feel_emoji 100 "$(unit_sym)");"; [[ -n "$out" ]] && oks "feel_emoji imperial" || bads "feel_emoji imperial"
    UNITS=metric
    out="$(unit_sym)"; [[ "$out" == "°C" ]] && oks "unit_sym metric" || bads "unit_sym"

    printf '%sRESULT: pass=%d fail=%d%s\n' "$CYN" "$pass" "$fail" "$R"
    (( fail > 0 )) && exit 1
    printf '%sSELF-TEST OK%s\n' "$GRN" "$R"
}

# ---------- GEN-FILES -------------------------------------------------------------
gen_repo_files() {
    [[ -e README.md ]] || { cat > README.md <<'WR1'
# weather

Worldwide terminal weather station in one bash file. Ask ONE thing — a city,
state, country, or **pin/zip code** — and get:

- **NOW** — temp, feels-like, humidity, wind, sky (timestamped)
- **NEXT 12 HOURS** — hourly temp / rain% / sky from the current hour
- **7-DAY FORECAST** — max/min/rain%/sky per day
- **COMING WEEK vs LAST MONTH** — real historical archive comparison + trend

Every report auto-saves to `~/weather_logs/`.

## worldwide by design

Geocoding runs on OpenStreetMap (Nominatim): every country, state, city,
village and postal code on Earth. Indian PIN codes, US zips, anything:

    ./weather.sh mumbai          # India
    ./weather.sh 400001          # Indian PIN code → Mumbai
    ./weather.sh maharashtra     # a whole state
    ./weather.sh hyderabad       # duplicate name? it lists India/Pakistan, you pick
    ./weather.sh "new york,US"
    ./weather.sh -u imperial tokyo

## data

Open-Meteo (forecast + historical archive) and OpenStreetMap — free, no API
key, no signup. Weather codes mapped to words + icons.

## self-test (offline)

    ./weather.sh --selftest

bash 4+, curl, python3, coreutils. Linux + WSL2. MIT licensed.
WR1
    printf '  [ok] README.md\n'; }
    [[ -e LICENSE ]] || { cat > LICENSE <<'WR2'
MIT License

Copyright (c) 2025 YOUR NAME HERE

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
WR2
    printf '  [ok] LICENSE (add your name!)\n'; }
    [[ -e requirements.txt ]] || { cat > requirements.txt <<'WR3'
# weather — tiny dependency list

bash        (4.0+)   required
curl                 required — API calls
python3              required — safe JSON parsing
coreutils            required — date, grep, sed, awk

# data sources: open-meteo.com + nominatim.openstreetmap.org
# both free, no API key, no signup
WR3
    printf '  [ok] requirements.txt\n'; }
    [[ -e .gitignore ]] || { printf 'weather_logs/\n*.log\n.DS_Store\n' > .gitignore; printf '  [ok] .gitignore\n'; }
    printf '\nDone — edit LICENSE (your name), then upload.\n'
}

# ---------- CLI + MAIN -------------------------------------------------------------
usage() {
    cat <<WU
weather v$VERSION — worldwide terminal weather (open-meteo + openstreetmap, no key)

USAGE
  $SCRIPT_NAME                 interactive — asks "where?"
  $SCRIPT_NAME mumbai          city
  $SCRIPT_NAME 400001          pin/zip code
  $SCRIPT_NAME hyderabad       ambiguous → interactive picker
  $SCRIPT_NAME -u imperial tokyo

OPTIONS
  -u, --units M|I   metric (default) or imperial
  -t, --top N       hours in hourly panel (default $HOURLY_COUNT)
  --no-log          don't save report file
  --selftest        offline checks
  --gen-files       README/LICENSE/requirements/.gitignore
  -h help · -V version
WU
}
parse_args() {
    local -a rest=()
    while (( $# > 0 )); do
        case "$1" in
            -u|--units) case "${2,,}" in
                    m|metric) UNITS="metric" ;; i|imperial) UNITS="imperial" ;;
                    *) die 2 "-u needs metric or imperial" ;; esac; shift ;;
            -t|--top) [[ "${2:-}" =~ ^[0-9]+$ ]] || die 2 "-t needs a number"
                HOURLY_COUNT="$2"; shift ;;
            --no-log) SAVE_LOG=0 ;;
            --selftest) self_test; exit $? ;;
            --gen-files) gen_repo_files; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            -*) die 2 "unknown option '$1' — try --help" ;;
            *) rest+=("$1") ;;
        esac
        shift
    done
    (( ${#rest[@]} > 0 )) && QUERY_TEXT="${rest[0]}"
}
parse_args "$@"

printf '%s weather %s — worldwide, one question: where? %s\n' "$CYN$B" "$R$DIM" "$R"
command -v curl > /dev/null 2>&1 || die 1 "curl missing — sudo apt install curl"
command -v python3 > /dev/null 2>&1 || die 1 "python3 missing — sudo apt install python3"

if [[ -z "$QUERY_TEXT" ]]; then
    read -r -p 'City / state / country / pin-zip code: ' QUERY_TEXT || die 2 "no input"
fi
QUERY_TEXT="${QUERY_TEXT#"${QUERY_TEXT%%[![:space:]]*}"}"
QUERY_TEXT="${QUERY_TEXT%"${QUERY_TEXT##*[![:space:]]}"}"
[[ -n "$QUERY_TEXT" ]] || die 2 "empty location"

geocode "$QUERY_TEXT"
fetch_all
render_all
save_log
