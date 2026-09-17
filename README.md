weather
Worldwide terminal weather station in one bash file. Ask ONE thing — a city,state, country, or pin/zip code — and get a full report:

NOW — temp, feels-like, humidity, wind, sky (timestamped)
NEXT 12 HOURS — hourly temp / rain% / sky from the current hour
7-DAY FORECAST — max/min/rain%/sky per day
COMING WEEK vs LAST MONTH — real historical archive comparison,including a trend line (e.g. "this week runs −2° vs last month")
Every report auto-saves to ~/weather_logs/.

worldwide by design
Geocoding runs on OpenStreetMap (Nominatim): every country, state, city,village and postal code on the planet. Indian PIN codes, US zips, anything:

./weather.sh mumbai          # India./weather.sh 400001          # Indian PIN code → Mumbai./weather.sh maharashtra     # a whole state./weather.sh hyderabad       # duplicate name? it lists matches, you pick./weather.sh "new york,US"./weather.sh -u imperial tokyo
data
Open-Meteo (forecast + historical archive) and OpenStreetMap — free,no API key, no signup. WMO weather codes mapped to words + icons.

self-test (offline)
./weather.sh --selftest
bash 4+, curl, python3, coreutils. Linux + WSL2. MIT licensed.

