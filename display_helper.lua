--[[
    Display Helper Functions for Weather Lockscreen Plugin

    Provides utility functions for creating various widget types.

    Author: Andreas Lösel
    License: GNU AGPL v3
--]]

local Device = require("device")
local Screen = Device.screen
local DataStorage = require("datastorage")
local util = require("util")
local Widget = require("ui/widget/widget")
local ImageWidget = require("ui/widget/imagewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local logger = require("logger")
local WeatherUtils = require("weather_utils")
local WeatherIconMap = require("weather_icon_map")

-- Defined once at module level so each call to buildHourlyChartRow reuses the same class.
local BarWidget = Widget:extend {}
function BarWidget:getSize() return { w = self.width, h = self.height } end
function BarWidget:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, self.color)
end

local DisplayHelper = {}

function DisplayHelper:createHeaderWidgets(header_font_size, header_margin, weather_data, text_color, is_cached)
    local header_widgets = {}
    local show_header = G_reader_settings:nilOrTrue("weather_show_header")

    if show_header and weather_data.current.location then
        table.insert(header_widgets, LeftContainer:new {
            dimen = { w = Screen:getWidth(), h = header_font_size + header_margin * 2 },
            FrameContainer:new {
                padding = header_margin,
                margin = 0,
                bordersize = 0,
                TextWidget:new {
                    text = weather_data.current.location,
                    face = Font:getFace("cfont", header_font_size),
                    fgcolor = text_color,
                },
            },
        })
    end

    if show_header and weather_data.current.timestamp then
        local timestamp = weather_data.current.timestamp
        local year, month, day, hour, min = timestamp:match("(%d+)-(%d+)-(%d+) (%d+):(%d+)")
        local formatted_time = ""
        if year and month and day and hour and min then
            -- Use os.date for localized month abbreviation
            local time_obj = os.time { year = tonumber(year), month = tonumber(month), day = tonumber(day) }
            local date_str = os.date("%b %d", time_obj)
            local twelve_hour_clock = G_reader_settings:isTrue("twelve_hour_clock")
            local hour_num = tonumber(hour)
            local time_str
            if twelve_hour_clock then
                local period = hour_num >= 12 and "PM" or "AM"
                local display_hour = hour_num % 12
                if display_hour == 0 then display_hour = 12 end
                time_str = display_hour .. ":" .. min .. " " .. period
            else
                time_str = hour .. ":" .. min
            end
            formatted_time = date_str .. ", " .. time_str
        else
            formatted_time = timestamp
        end

        -- Add asterisk if data is cached
        if is_cached then
            formatted_time = formatted_time .. " *"
        end

        table.insert(header_widgets, RightContainer:new {
            dimen = { w = Screen:getWidth(), h = header_font_size + header_margin * 2 },
            FrameContainer:new {
                padding = header_margin,
                margin = 0,
                bordersize = 0,
                TextWidget:new {
                    text = formatted_time,
                    face = Font:getFace("cfont", header_font_size),
                    fgcolor = text_color,
                },
            },
        })
    end

    return OverlapGroup:new {
        dimen = { w = Screen:getWidth(), h = header_font_size + header_margin * 2 },
        unpack(header_widgets)
    }
end

--- Build content with a build function, measure it, and rescale to fit available height.
--- @param buildFunc function(scale_factor) → widget  Builder that creates the content widget at the given scale.
--- @param available_height number  The pixel height the content should fit into.
--- @param default_fill number|nil  Default fill percentage when override is off (default 90).
--- @param max_scale number|nil  Optional upper bound on the scale factor (e.g. derived from available width).
--- @return widget, number  The final widget and the scale factor used.
function DisplayHelper:scaleToFit(buildFunc, available_height, default_fill, max_scale)
    default_fill = default_fill or 90

    local probe = buildFunc(1.0)
    local content_height = probe:getSize().h

    local fill_percent = G_reader_settings:readSetting("weather_override_scaling")
        and tonumber(G_reader_settings:readSetting("weather_fill_percent"))
        or default_fill
    local min_fill = math.max(50, fill_percent - 5)
    local max_fill = math.min(100, fill_percent + 5)

    local min_target = available_height * (min_fill / 100)
    local max_target = available_height * (max_fill / 100)

    local scale = 1.0
    if content_height > max_target then
        scale = max_target / content_height
    elseif content_height < min_target then
        scale = min_target / content_height
    end

    -- Width constraint takes priority: cap scale so content never exceeds available width
    if max_scale and scale > max_scale then
        scale = max_scale
    end

    local widget
    if scale ~= 1.0 then
        widget = buildFunc(scale)
    else
        widget = probe
    end

    return widget, scale
end

--- Build a weather icon TextWidget (Weather Icons font) for the given hour entry.
--- Falls back to a VerticalSpan placeholder if the font is unavailable.
--- @param icon_code string|nil
--- @param is_day boolean|nil
--- @param icon_size number  Pixel size used for both width and height.
--- @param text_color table|nil  Blitbuffer colour; defaults to COLOR_BLACK.
local function buildIconWidget(icon_code, is_day, icon_size, text_color)
    local font_name = "weathericons-regular-webfont"
    local face = Font:getFace(font_name, icon_size)
    if face and icon_code then
        return TextWidget:new {
            text    = WeatherIconMap.getChar(icon_code, is_day ~= false),
            face    = face,
            fgcolor = text_color or Blitbuffer.COLOR_BLACK,
        }
    end
    return VerticalSpan:new { width = icon_size }
end

--- Build a horizontal row of hourly forecast columns (hour label, icon, temperature).
--- @param hourly_data table  Array of hour entries (each with hour, hour_num, icon_code, is_day, temp_c, temp_f).
--- @param target_hours table  Array of hour numbers to include (e.g. {6, 12, 18}).
--- @param icon_size number  Pixel size for the weather icons.
--- @param font_size number  Font size for the hour label and temperature text.
--- @param spacing number  Horizontal spacing between columns.
--- @return widget|nil  HorizontalGroup widget, or nil if no hours matched.
function DisplayHelper:buildHourlyRow(hourly_data, target_hours, icon_size, font_size, spacing)
    if not hourly_data or #hourly_data == 0 then return nil end

    -- Build a fast lookup set from target_hours
    local target_set = {}
    for _, h in ipairs(target_hours) do target_set[h] = true end

    local row = {}
    for _, hour_data in ipairs(hourly_data) do
        if target_set[hour_data.hour_num] then
            if #row > 0 then
                table.insert(row, HorizontalSpan:new { width = spacing })
            end

            local col = {}
            table.insert(col, TextWidget:new {
                text = hour_data.hour,
                face = Font:getFace("cfont", font_size),
            })
            table.insert(col, buildIconWidget(hour_data.icon_code, hour_data.is_day, icon_size))
            table.insert(col, TextWidget:new {
                text = WeatherUtils:getHourlyTemp(hour_data, false),
                face = Font:getFace("cfont", font_size),
            })

            table.insert(row, VerticalGroup:new {
                align = "center",
                unpack(col),
            })
        end
    end

    if #row == 0 then return nil end
    return HorizontalGroup:new { align = "center", unpack(row) }
end

--- Build a horizontal row of hourly forecast columns with a temperature bar chart.
--- Each column shows: icon (top), temperature, proportional bar, hour label (bottom).
--- Bar height is proportional to temperature within (min_temp - 5) to (max_temp + 5).
--- @param hourly_data table  Array of hour entries.
--- @param target_hours table  Array of hour numbers to include (e.g. {6, 12, 18}).
--- @param icon_size number  Pixel size for the weather icons.
--- @param font_size number  Font size for hour and temperature labels.
--- @param spacing number  Horizontal spacing between columns.
--- @param bar_max_h number  Maximum bar height in pixels (tallest bar = this height).
--- @return widget|nil  HorizontalGroup widget, or nil if no hours matched.
function DisplayHelper:buildHourlyChartRow(hourly_data, target_hours, icon_size, font_size, spacing, bar_max_h)
    if not hourly_data or #hourly_data == 0 then return nil end

    local use_celsius = WeatherUtils:getTempScale() == "C"
    local target_set = {}
    for _, h in ipairs(target_hours) do target_set[h] = true end

    -- Fixed temperature scale: 0°C–45°C (converted to °F when needed)
    local range_min, range_max
    if use_celsius then
        range_min, range_max = 0, 45
    else
        range_min, range_max = 32, 113
    end
    local range = range_max - range_min

    -- Ensure at least one target hour is present
    local any_match = false
    for _, h in ipairs(hourly_data) do
        if target_set[h.hour_num] then any_match = true; break end
    end
    if not any_match then return nil end
    local bar_w     = math.max(4, math.floor(icon_size * 0.45))
    local face      = Font:getFace("cfont", font_size)

    local row = {}
    for _, hour_data in ipairs(hourly_data) do
        if target_set[hour_data.hour_num] then
            if #row > 0 then
                table.insert(row, HorizontalSpan:new { width = spacing })
            end

            local t           = use_celsius and hour_data.temp_c or hour_data.temp_f
            local out_of_range = t < range_min or t > range_max
            local frac        = math.max(0, math.min(1, (t - range_min) / range))
            local bar_h       = math.max(2, math.floor(frac * bar_max_h))
            local empty_h     = bar_max_h - bar_h

            local col = {}

            -- Icon via Weather Icons font (no image I/O, no blitbuffer lifetime concerns)
            table.insert(col, CenterContainer:new {
                dimen = { w = icon_size, h = icon_size },
                buildIconWidget(hour_data.icon_code, hour_data.is_day, icon_size),
            })

            -- Temperature
            table.insert(col, CenterContainer:new {
                dimen = { w = icon_size, h = font_size + 4 },
                TextWidget:new {
                    text = WeatherUtils:getHourlyTemp(hour_data, false),
                    face = face,
                },
            })

            -- Bar growing from bottom: empty space above, then filled bar
            local bar_group = {}
            if empty_h > 0 then
                table.insert(bar_group, VerticalSpan:new { width = empty_h })
            end
            table.insert(bar_group, CenterContainer:new {
                dimen = { w = icon_size, h = bar_h },
                BarWidget:new {
                    width = bar_w, height = bar_h,
                    color = out_of_range and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
                },
            })
            table.insert(col, VerticalGroup:new {
                align = "center",
                unpack(bar_group),
            })

            table.insert(col, VerticalSpan:new { width = math.floor(font_size / 2) })
            -- Hour label
            table.insert(col, CenterContainer:new {
                dimen = { w = icon_size, h = font_size + 4 },
                TextWidget:new { text = hour_data.hour, face = face },
            })

            table.insert(row, VerticalGroup:new {
                align = "center",
                unpack(col),
            })
        end
    end

    if #row == 0 then return nil end
    return HorizontalGroup:new { align = "center", unpack(row) }
end

function DisplayHelper:createLoadingWidget()
    logger.dbg("WeatherLockscreen: Creating loading icon")

    local icon_size = Screen:scaleBySize(200)

    local icon_filename = "hourglass.svg"
    local icon_path = DataStorage:getDataDir() .. "/icons/" .. icon_filename

    if not util.pathExists(icon_path) then
        logger.warn("WeatherLockscreen: Loading icon file not found:", icon_path)
        return nil
    end

    local icon_widget = ImageWidget:new {
        file = icon_path,
        width = icon_size,
        height = icon_size,
        alpha = true,
        original_in_nightmode = false
    }

    return FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        CenterContainer:new {
            dimen = Screen:getSize(),
            VerticalGroup:new {
                align = "center",
                icon_widget,
            },
        },
    }
end

return DisplayHelper
