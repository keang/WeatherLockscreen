--[[
    Chart Display Mode for Weather Lockscreen
    Shows hourly forecast rows with temperature bar chart for Today and Tomorrow.
    Layout per column: icon → temperature → proportional bar → hour label.
--]]

local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local _ = require("l10n/gettext")
local WeatherUtils = require("weather_utils")
local DisplayHelper = require("display_helper")

local ChartDisplay = {}

-- Show only these hours in the chart
local FORECAST_HOURS = {6, 9, 12, 15, 18, 21}

local function formatDayLabel(t)
    local day    = os.date("%A", t)
    local d      = tonumber(os.date("%d", t))
    local month  = os.date("%b", t)
    local suffix
    if     d == 1 or d == 21 or d == 31 then suffix = "st"
    elseif d == 2 or d == 22             then suffix = "nd"
    elseif d == 3 or d == 23             then suffix = "rd"
    else                                      suffix = "th" end
    return string.format("%s, %d%s %s", day, d, suffix, month)
end

local function todayLabel()    return formatDayLabel(os.time()) end
local function tomorrowLabel() return formatDayLabel(os.time() + 86400) end

function ChartDisplay:create(weather_lockscreen, weather_data)
    local screen_width  = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local base_hourly_icon_size   = 120
    local base_label_font_size    = 30
    local base_hour_font_size     = 24
    local base_bar_height         = 240
    local base_vertical_spacing   = 30
    local base_horizontal_spacing = 20

    local header_font_size = Screen:scaleBySize(20)
    local header_margin    = 10

    local header_group = DisplayHelper:createHeaderWidgets(
        header_font_size, header_margin, weather_data,
        Blitbuffer.COLOR_DARK_GRAY, weather_data.is_cached)
    local header_height = header_group:getSize().h

    -- Width cap is based on the number of displayed columns (FORECAST_HOURS), not total hourly entries
    local n_hours = #FORECAST_HOURS
    local row_w   = n_hours * base_hourly_icon_size
                  + (n_hours - 1) * base_horizontal_spacing
    local max_scale = screen_width / row_w

    local function buildContent(scale)
        local hourly_icon_size   = math.floor(base_hourly_icon_size   * scale)
        local label_font_size    = math.floor(base_label_font_size    * scale)
        local hour_font_size     = math.floor(base_hour_font_size     * scale)
        local bar_height         = math.floor(base_bar_height         * scale)
        local vertical_spacing   = math.floor(base_vertical_spacing   * scale)
        local horizontal_spacing = math.floor(base_horizontal_spacing * scale)

        local widgets = {}

        local function addRow(hourly_data, label)
            if not hourly_data or #hourly_data == 0 then return end
            table.insert(widgets, TextWidget:new {
                text = label,
                face = Font:getFace("cfont", label_font_size),
                bold = true,
            })
            local row = DisplayHelper:buildHourlyChartRow(
                hourly_data, FORECAST_HOURS,
                hourly_icon_size, hour_font_size, horizontal_spacing, bar_height)
            if row then
                table.insert(widgets, row)
            end
            table.insert(widgets, VerticalSpan:new { width = vertical_spacing })
        end

        addRow(weather_data.hourly_today_all,    todayLabel())
        addRow(weather_data.hourly_tomorrow_all, tomorrowLabel())

        return VerticalGroup:new {
            align = "center",
            unpack(widgets),
        }
    end

    local available_height = screen_height - header_height
    local weather_group    = DisplayHelper:scaleToFit(buildContent, available_height, nil, max_scale)

    local main_content = CenterContainer:new {
        dimen = Screen:getSize(),
        weather_group,
    }

    return OverlapGroup:new {
        dimen = Screen:getSize(),
        main_content,
        header_group,
    }
end

return ChartDisplay
