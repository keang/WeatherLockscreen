--[[
    Tomorrow.io Weather API Module for Weather Lockscreen

    Drop-in replacement for weather_api.lua using the Tomorrow.io API.
    Same public interface: fetchWeatherData, processWeatherData, searchLocations,
    getIconCode, getIconPath.

    API KEY SETUP (no UI needed):
      SSH into the device and create a plain text file containing just your key:

        Kindle:  echo "YOUR_KEY" > /mnt/us/koreader/tomorrowio_key.txt
        Kobo:    echo "YOUR_KEY" > /mnt/onboard/.adds/koreader/tomorrowio_key.txt

      Get a free API key at: https://app.tomorrow.io/

    Location search uses Nominatim (OpenStreetMap) — no additional key needed.

    Tomorrow.io free tier: 500 requests/day, 25 requests/hour, 5-day forecast.
--]]

local DataStorage = require("datastorage")
local logger = require("logger")
local WeatherUtils = require("weather_utils")
local _ = require("l10n/gettext")

local TomorrowioAPI = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function urlEncode(str)
    if str then
        str = str:gsub("([^%w%-%.%_%~ ])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = str:gsub(" ", "+")
    end
    return str
end

local function http_request(url, sink_table, headers)
    local ltn12 = require("ltn12")
    local sink = ltn12.sink.table(sink_table)

    local ok_ssl, https = pcall(require, "ssl.https")
    if ok_ssl and https and https.request then
        local _, code = https.request {
            url     = url,
            sink    = sink,
            headers = headers,
        }
        return code
    end

    local ok_http, http = pcall(require, "socket.http")
    if not ok_http or not http or not http.request then
        return nil, "no http client available"
    end
    local _, code = http.request { url = url, sink = sink }
    return code
end

-- Read the API key from a plain text file (first non-empty line).
local function readApiKey()
    local path = DataStorage:getDataDir() .. "/tomorrowio_key.txt"
    local f = io.open(path, "r")
    if not f then
        logger.dbg("WeatherLockscreen (tomorrow.io): key file not found:", path)
        return nil
    end
    local key = f:read("*l")
    f:close()
    if key then key = key:match("^%s*(.-)%s*$") end  -- trim whitespace
    return (key and key ~= "") and key or nil
end

-- Degrees → 16-point compass string.
local COMPASS = { "N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW" }
local function degToCompass(deg)
    if not deg then return nil end
    return COMPASS[ math.floor((deg % 360) / 22.5 + 0.5) % 16 + 1 ]
end

-- Extract UTC hour (0-23) from Tomorrow.io ISO-8601 timestamp "2024-01-01T14:00:00Z".
local function isoUTCHour(iso)
    return iso and tonumber(iso:match("T(%d+):")) or 12
end

-- Extract YYYY-MM-DD from an ISO timestamp.
local function isoDate(iso)
    return iso and iso:match("^(%d+%-%d+%-%d+)") or ""
end

-- Extract YYYY-MM-DD in device-local time from a UTC ISO-8601 timestamp.
-- Uses the cached UTC offset from localHour; falls back to AEDT (UTC+11) if
-- the device clock cannot be queried.
local function localDate(iso)
    if not iso then return "" end
    -- Ensure _utc_offset_h is populated (mirrors localHour init logic).
    local offset
    if _utc_offset_h ~= nil then
        offset = _utc_offset_h
    else
        local t = os.time()
        if t then
            local lu = os.date("!*t", t)
            local ll = os.date("*t",  t)
            offset = ll.hour - lu.hour
            if ll.day ~= lu.day then
                offset = offset + (ll.day > lu.day and 24 or -24)
            end
            _utc_offset_h = offset
        else
            offset = 11  -- AEDT (UTC+11) fallback
        end
    end

    local y, mo, d, h = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):")
    if not y then return isoDate(iso) end
    y, mo, d, h = tonumber(y), tonumber(mo), tonumber(d), tonumber(h)

    local lh = h + offset
    if lh >= 24 then
        local base = os.time({ year = y, month = mo, day = d, hour = 12, min = 0, sec = 0 })
        return os.date("%Y-%m-%d", base + 86400)
    elseif lh < 0 then
        local base = os.time({ year = y, month = mo, day = d, hour = 12, min = 0, sec = 0 })
        return os.date("%Y-%m-%d", base - 86400)
    else
        return string.format("%04d-%02d-%02d", y, mo, d)
    end
end

-- Approximate local hour from a UTC ISO timestamp using the device's UTC offset.
local _utc_offset_h  -- cached
local function localHour(iso)
    if not _utc_offset_h then
        local t = os.time()
        local lu = os.date("!*t", t)
        local ll = os.date("*t",  t)
        _utc_offset_h = ll.hour - lu.hour
        if ll.day ~= lu.day then
            _utc_offset_h = _utc_offset_h + (ll.day > lu.day and 24 or -24)
        end
    end
    return (isoUTCHour(iso) + _utc_offset_h) % 24
end

-- Format an ISO-8601 UTC timestamp as a local "HH:MM" or "H:MM AM/PM" string.
local function isoToTimeStr(iso, twelve_hour)
    if not iso then return nil end
    -- Use local hour; minutes stay the same (offsets are whole hours for most zones)
    local h = localHour(iso)
    local m = tonumber(iso:match("T%d+:(%d+):")) or 0
    if twelve_hour then
        local suffix = h < 12 and "AM" or "PM"
        h = h % 12; if h == 0 then h = 12 end
        return string.format("%d:%02d %s", h, m, suffix)
    else
        return string.format("%02d:%02d", h, m)
    end
end

-- ---------------------------------------------------------------------------
-- Tomorrow.io weather code tables
-- ---------------------------------------------------------------------------

-- Map Tomorrow.io codes → nearest WeatherAPI code string.
-- This keeps compatibility with weather_icon_map.lua which expects WeatherAPI codes.
local WCODE_TO_WAPI = {
    [1000] = "113", -- Clear
    [1100] = "116", -- Mostly Clear
    [1101] = "116", -- Partly Cloudy
    [1102] = "119", -- Mostly Cloudy
    [1001] = "122", -- Cloudy / Overcast
    [2000] = "248", -- Fog
    [2100] = "143", -- Light Fog / Mist
    [3000] = "116", -- Light Wind  (no direct WeatherAPI equivalent)
    [3001] = "116", -- Wind
    [3002] = "119", -- Strong Wind
    [4000] = "263", -- Drizzle
    [4200] = "296", -- Light Rain
    [4001] = "302", -- Rain
    [4201] = "308", -- Heavy Rain
    [5001] = "326", -- Flurries / Patchy light snow
    [5100] = "326", -- Light Snow
    [5000] = "338", -- Snow
    [5101] = "338", -- Heavy Snow
    [6000] = "281", -- Freezing Drizzle
    [6200] = "311", -- Light Freezing Rain
    [6001] = "311", -- Freezing Rain
    [6201] = "314", -- Heavy Freezing Rain
    [7102] = "350", -- Light Ice Pellets
    [7000] = "350", -- Ice Pellets
    [7101] = "356", -- Heavy Ice Pellets
    [8000] = "386", -- Thunderstorm
}

-- English condition text for Tomorrow.io codes (Tomorrow.io returns codes, not text).
local WCODE_TEXT = {
    [1000] = "Clear",
    [1100] = "Mostly Clear",
    [1101] = "Partly Cloudy",
    [1102] = "Mostly Cloudy",
    [1001] = "Cloudy",
    [2000] = "Fog",
    [2100] = "Light Fog",
    [3000] = "Light Wind",
    [3001] = "Windy",
    [3002] = "Strong Wind",
    [4000] = "Drizzle",
    [4200] = "Light Rain",
    [4001] = "Rain",
    [4201] = "Heavy Rain",
    [5001] = "Flurries",
    [5100] = "Light Snow",
    [5000] = "Snow",
    [5101] = "Heavy Snow",
    [6000] = "Freezing Drizzle",
    [6200] = "Light Freezing Rain",
    [6001] = "Freezing Rain",
    [6201] = "Heavy Freezing Rain",
    [7102] = "Light Ice Pellets",
    [7000] = "Ice Pellets",
    [7101] = "Heavy Ice Pellets",
    [8000] = "Thunderstorm",
}

-- ---------------------------------------------------------------------------
-- Public interface (same as weather_api.lua)
-- ---------------------------------------------------------------------------

-- Returns (wapi_code_string, is_day_bool) for a Tomorrow.io weatherCode + local hour.
function TomorrowioAPI:getIconCode(tomorrow_code, hour_num)
    local wapi = WCODE_TO_WAPI[tomorrow_code] or "116"
    local is_day = (hour_num == nil) or (hour_num >= 6 and hour_num < 20)
    return wapi, is_day
end

-- Tomorrow.io has no icon URLs; font-based icons are used instead.
function TomorrowioAPI:getIconPath()
    return nil
end

function TomorrowioAPI:fetchWeatherData(weather_lockscreen)
    local refresh_required = weather_lockscreen.refresh or false
    -- local location = G_reader_settings:readSetting("weather_location") or weather_lockscreen.default_location
    -- TODO: implement location selection UI and use real location instead of hardcoded one. For now, use Melbourne, Australia as a test location with variable weather.
    local location = "-37.882346560026356,145.06533160923226"

    if not refresh_required then
        local cached = WeatherUtils:loadWeatherCache(WeatherUtils:getMinDelayBetweenUpdates())
        if cached then
            logger.dbg("WeatherLockscreen (tomorrow.io): Using cache")
            cached.is_cached = true
            return cached
        end
    end

    local api_key = readApiKey()
    if not api_key then
        logger.warn("WeatherLockscreen (tomorrow.io): No API key. Create tomorrowio_key.txt in KOReader data dir.")
        local cached = WeatherUtils:loadWeatherCache(WeatherUtils:getCacheMaxAge())
        if cached then cached.is_cached = true end
        return cached
    end

    local json = require("json")
    local url = string.format(
        "https://api.tomorrow.io/v4/weather/forecast?location=%s&apikey=%s&timesteps=1h&units=metric",
        urlEncode(location),
        api_key
    )

    logger.info("WeatherLockscreen (tomorrow.io): Fetching forecast for", location)

    local sink_table = {}
    local code, err = http_request(url, sink_table)
    if not code then
        logger.warn("WeatherLockscreen (tomorrow.io): HTTP failed:", err or "unknown")
        local cached = WeatherUtils:loadWeatherCache(WeatherUtils:getCacheMaxAge())
        if cached then cached.is_cached = true end
        return cached
    end

    if code == 200 then
        local ok, result = pcall(json.decode, table.concat(sink_table))
        if ok and result and result.timelines then
            local weather_data = self:processWeatherData(result)
            WeatherUtils:saveWeatherCache(weather_data)
            weather_data.is_cached = false
            weather_lockscreen.refresh = false
            logger.info("WeatherLockscreen (tomorrow.io): weather data: ", weather_data)
            return weather_data
        else
            logger.warn("WeatherLockscreen (tomorrow.io): Failed to parse response")
        end
    else
        logger.warn("WeatherLockscreen (tomorrow.io): HTTP code:", code)
    end

    local cached = WeatherUtils:loadWeatherCache(WeatherUtils:getCacheMaxAge())
    if cached then cached.is_cached = true end
    return cached
end

function TomorrowioAPI:processWeatherData(result)
    local twelve_hour_clock = G_reader_settings:isTrue("twelve_hour_clock")

    local hourly = (result.timelines and result.timelines.hourly) or {}
    local daily  = (result.timelines and result.timelines.daily)  or {}
    local loc    = result.location or {}

    -- ---- Current conditions from first hourly entry -------------------------
    local cur_entry = (hourly[1] and hourly[1].values) or {}
    local cur_code  = cur_entry.weatherCode
    local cur_lhour = localHour(hourly[1] and hourly[1].time)
    local cur_icon_code, cur_is_day = self:getIconCode(cur_code, cur_lhour)

    local temp_c      = math.floor((cur_entry.temperature         or 0) + 0.5)
    local feelslike_c = math.floor((cur_entry.temperatureApparent or temp_c) + 0.5)
    local wind_ms     = cur_entry.windSpeed    or 0
    local wind_kph    = math.floor(wind_ms * 3.6 + 0.5)

    local current_data = {
        icon_path   = nil,
        icon_code   = cur_icon_code,
        is_day      = cur_is_day,
        temp_c      = temp_c,
        temp_f      = math.floor(temp_c * 9/5 + 32 + 0.5),
        condition   = WCODE_TEXT[cur_code] or "Unknown",
        location    = loc.name or nil,
        timestamp   = os.date("%Y-%m-%d %H:%M"),
        feelslike_c = feelslike_c,
        feelslike_f = math.floor(feelslike_c * 9/5 + 32 + 0.5),
        humidity    = cur_entry.humidity and (math.floor(cur_entry.humidity + 0.5) .. "%") or nil,
        wind        = wind_kph .. " km/h",
        wind_dir    = degToCompass(cur_entry.windDirection),
    }

    -- ---- Astronomy from first daily entry -----------------------------------
    local astronomy = nil
    if daily[1] and daily[1].values then
        local dv = daily[1].values
        astronomy = {
            sunrise    = isoToTimeStr(dv.sunriseTime, twelve_hour_clock),
            sunset     = isoToTimeStr(dv.sunsetTime,  twelve_hour_clock),
            moonrise   = nil,   -- not provided by Tomorrow.io
            moonset    = nil,
            moon_phase = nil,
        }
    end

    -- ---- Hourly data split into today / tomorrow ----------------------------
    -- "Today" = entries sharing the same local-calendar date as the first entry.
    -- "Tomorrow" = entries on the next local date. Capped at 24 hours each.
    local today_date    = localDate(hourly[1] and hourly[1].time)
    local hourly_today  = {}
    local hourly_tomorrow = {}
    local tomorrow_date = nil   -- determined dynamically

    for _, entry in ipairs(hourly) do
        local edate = localDate(entry.time)
        local lhour = localHour(entry.time)
        local ev    = entry.values or {}
        local h_code = ev.weatherCode
        local h_icon_code, h_is_day = self:getIconCode(h_code, lhour)
        local h_tc = math.floor((ev.temperatureApparent or ev.temperature or 0) + 0.5)

        local row = {
            hour          = WeatherUtils:formatHourLabel(lhour, twelve_hour_clock),
            hour_num      = lhour,
            icon_path     = nil,
            icon_code     = h_icon_code,
            is_day        = h_is_day,
            temp_c        = h_tc,
            temp_f        = math.floor(h_tc * 9/5 + 32 + 0.5),
            condition     = WCODE_TEXT[h_code] or "Unknown",
            precip_mm     = ev.rainAccumulation or 0,
            precip_chance = math.floor((ev.precipitationProbability or 0) + 0.5),
        }

        if edate == today_date then
            if #hourly_today < 24 then
                table.insert(hourly_today, row)
            end
        else
            if not tomorrow_date then tomorrow_date = edate end
            if edate == tomorrow_date and #hourly_tomorrow < 24 then
                table.insert(hourly_tomorrow, row)
            end
        end
    end

    -- ---- Daily forecast (up to 3 days) --------------------------------------
    local forecast_days = {}
    for i, day_entry in ipairs(daily) do
        if i > 3 then break end
        local dv = day_entry.values or {}

        local day_name
        if i == 1 then
            day_name = _("Today")
        elseif i == 2 then
            day_name = _("Tomorrow")
        else
            local date_str = isoDate(day_entry.time)
            local y, mo, d = date_str:match("(%d+)-(%d+)-(%d+)")
            if y then
                day_name = os.date("%a", os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d) }))
            else
                day_name = "Day " .. i
            end
        end

        local d_code = dv.weatherCodeMax or dv.weatherCode or 1000
        local fd_icon_code, _ = self:getIconCode(d_code, 12)  -- noon = daytime
        local high_c = math.floor((dv.temperatureMax or 0) + 0.5)
        local low_c  = math.floor((dv.temperatureMin or 0) + 0.5)

        table.insert(forecast_days, {
            day_name  = day_name,
            icon_path = nil,
            icon_code = fd_icon_code,
            is_day    = true,
            high_c    = high_c,
            high_f    = math.floor(high_c * 9/5 + 32 + 0.5),
            low_c     = low_c,
            low_f     = math.floor(low_c * 9/5 + 32 + 0.5),
            condition = WCODE_TEXT[d_code] or "Unknown",
        })
    end

    return {
        lang                = "en",     -- Tomorrow.io returns codes; text is our own
        current             = current_data,
        hourly_today_all    = hourly_today,
        hourly_tomorrow_all = hourly_tomorrow,
        forecast_days       = forecast_days,
        astronomy           = astronomy,
    }
end

-- Search locations via Nominatim (OpenStreetMap) — no API key required.
-- Returns the same {name, region, country, lat, lon} format as weather_api.lua.
-- The api_key argument is accepted for interface compatibility but ignored.
function TomorrowioAPI:searchLocations(query, _api_key)
    local json = require("json")
    local url = string.format(
        "https://nominatim.openstreetmap.org/search?q=%s&format=json&limit=5&addressdetails=1",
        urlEncode(query)
    )

    -- Nominatim requires a descriptive User-Agent (usage policy).
    local sink_table = {}
    local code, err = http_request(url, sink_table, {
        ["User-Agent"] = "WeatherLockscreen/KOReader (koreader-plugin)",
    })
    if not code then
        return nil, _("API error") .. " (" .. (err or "unknown") .. ")"
    end

    if code ~= 200 then
        return nil, _("API error") .. " (" .. code .. ")"
    end

    local ok, result = pcall(json.decode, table.concat(sink_table))
    if not ok or not result then
        return nil, _("Failed to parse response")
    end

    if #result == 0 then
        return nil, _("No location found")
    end

    local locations = {}
    for _, loc in ipairs(result) do
        local addr    = loc.address or {}
        local name    = addr.city or addr.town or addr.village or addr.county or loc.name or loc.display_name
        local region  = addr.state or addr.region or ""
        local country = addr.country or ""
        table.insert(locations, {
            name    = name,
            region  = region,
            country = country,
            lat     = tonumber(loc.lat),
            lon     = tonumber(loc.lon),
        })
    end

    return locations
end

return TomorrowioAPI
