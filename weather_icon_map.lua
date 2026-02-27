--[[
    Weather Icon Map for Weather Lockscreen Plugin

    Maps (icon_code, is_day) -> UTF-8 character from Weather Icons font (U+F000+).
    WeatherAPI icon numbers sourced from:
      https://www.weatherapi.com/docs/weather_conditions.json
    Codepoints sourced from Weather Icons by Erik Flowers:
      https://erikflowers.github.io/weather-icons/
--]]

local M = {}

-- Day icon codepoints (Weather Icons font, Unicode Private Use Area)
local day = {
    ["113"] = 0xF00D,  -- Sunny
    ["116"] = 0xF002,  -- Partly cloudy
    ["119"] = 0xF013,  -- Cloudy
    ["122"] = 0xF013,  -- Overcast
    ["143"] = 0xF003,  -- Mist/Fog day
    ["176"] = 0xF009,  -- Patchy rain possible
    ["179"] = 0xF00A,  -- Patchy snow possible
    ["182"] = 0xF0B5,  -- Patchy sleet possible
    ["185"] = 0xF0B5,  -- Patchy freezing drizzle possible
    ["200"] = 0xF010,  -- Thundery outbreaks possible
    ["227"] = 0xF065,  -- Blowing snow
    ["230"] = 0xF065,  -- Blizzard
    ["248"] = 0xF014,  -- Fog
    ["260"] = 0xF014,  -- Freezing fog
    ["263"] = 0xF00B,  -- Patchy light drizzle
    ["266"] = 0xF00B,  -- Light drizzle
    ["281"] = 0xF0B5,  -- Freezing drizzle
    ["284"] = 0xF0B5,  -- Heavy freezing drizzle
    ["293"] = 0xF008,  -- Patchy light rain
    ["296"] = 0xF008,  -- Light rain
    ["299"] = 0xF019,  -- Moderate rain at times
    ["302"] = 0xF019,  -- Moderate rain
    ["305"] = 0xF019,  -- Heavy rain at times
    ["308"] = 0xF019,  -- Heavy rain
    ["311"] = 0xF0B5,  -- Light freezing rain
    ["314"] = 0xF0B5,  -- Heavy freezing rain
    ["317"] = 0xF0B5,  -- Light sleet
    ["320"] = 0xF0B5,  -- Moderate or heavy sleet
    ["323"] = 0xF00A,  -- Patchy light snow
    ["326"] = 0xF00A,  -- Light snow
    ["329"] = 0xF01B,  -- Patchy moderate snow
    ["332"] = 0xF01B,  -- Moderate snow
    ["335"] = 0xF01B,  -- Patchy heavy snow
    ["338"] = 0xF01B,  -- Heavy snow
    ["350"] = 0xF015,  -- Ice pellets
    ["353"] = 0xF009,  -- Light rain shower
    ["356"] = 0xF009,  -- Moderate or heavy rain shower
    ["359"] = 0xF009,  -- Torrential rain shower
    ["362"] = 0xF0B5,  -- Light sleet showers
    ["365"] = 0xF0B5,  -- Moderate or heavy sleet showers
    ["368"] = 0xF00A,  -- Light snow showers
    ["371"] = 0xF01B,  -- Moderate or heavy snow showers
    ["374"] = 0xF015,  -- Light showers of ice pellets
    ["377"] = 0xF015,  -- Moderate or heavy showers of ice pellets
    ["386"] = 0xF010,  -- Patchy light rain with thunder
    ["389"] = 0xF010,  -- Moderate or heavy rain with thunder
    ["392"] = 0xF06B,  -- Patchy light snow with thunder
    ["395"] = 0xF06B,  -- Moderate or heavy snow with thunder
}

-- Night icon codepoints (explicit night variants; others fall back to day)
local night = {
    ["113"] = 0xF02E,  -- Clear night
    ["116"] = 0xF086,  -- Partly cloudy night
    ["119"] = 0xF013,  -- Cloudy (same glyph)
    ["122"] = 0xF013,  -- Overcast (same glyph)
    ["143"] = 0xF04A,  -- Mist/Fog night
    ["176"] = 0xF029,  -- Patchy rain night
    ["179"] = 0xF02A,  -- Patchy snow night
    ["182"] = 0xF0B3,  -- Patchy sleet night
    ["185"] = 0xF0B3,  -- Patchy freezing drizzle night
    ["200"] = 0xF02D,  -- Thundery outbreaks night
    ["263"] = 0xF02B,  -- Patchy light drizzle night
    ["266"] = 0xF02B,  -- Light drizzle night
    ["293"] = 0xF028,  -- Patchy light rain night
    ["296"] = 0xF028,  -- Light rain night
    ["323"] = 0xF02A,  -- Patchy light snow night
    ["326"] = 0xF02A,  -- Light snow night
    ["353"] = 0xF029,  -- Light rain shower night
    ["356"] = 0xF029,  -- Heavy rain shower night
    ["368"] = 0xF02A,  -- Light snow shower night
    ["386"] = 0xF02D,  -- Light rain + thunder night
    ["389"] = 0xF02D,  -- Heavy rain + thunder night
}
-- All other night codes fall back to the day table (neutral/symmetric icons)

local FALLBACK = 0xF07B  -- wi-na (not available)

-- Convert a Unicode codepoint to a UTF-8 encoded string.
local function cpToUtf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 64),
            0x80 + (cp % 64))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + math.floor((cp % 4096) / 64),
            0x80 + (cp % 64))
    else
        return string.char(
            0xF0 + math.floor(cp / 262144),
            0x80 + math.floor((cp % 262144) / 4096),
            0x80 + math.floor((cp % 4096) / 64),
            0x80 + (cp % 64))
    end
end

--- Return the Weather Icons font character for a WeatherAPI icon code.
--- @param icon_code string  Numeric string extracted from the CDN URL (e.g. "113").
--- @param is_day boolean    True for daytime icons, false for night.
--- @return string  UTF-8 character from the Weather Icons font.
function M.getChar(icon_code, is_day)
    local map = is_day and day or night
    local cp = map[icon_code] or day[icon_code] or FALLBACK
    return cpToUtf8(cp)
end

return M
