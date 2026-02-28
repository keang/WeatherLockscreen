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
local logger = require("logger")

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
    logger.dbg("display_chart: create() called")
    logger.dbg("display_chart: weather_data: ", weather_data)
    local screen_width  = Screen:getWidth()
    local screen_height = Screen:getHeight()
    logger.dbg("display_chart: screen size: ", screen_width, screen_height)

    local base_hourly_icon_size   = 120
    local base_label_font_size    = 30
    local base_hour_font_size     = 24
    local base_bar_height         = 240
    local base_vertical_spacing   = 60
    local base_horizontal_spacing = 20

    local header_font_size = Screen:scaleBySize(10)
    local header_margin    = 10

    logger.dbg("display_chart: creating header widgets, font_size=", header_font_size, "margin=", header_margin)
    local header_group = DisplayHelper:createHeaderWidgets(
        header_font_size, header_margin, weather_data,
        Blitbuffer.COLOR_DARK_GRAY, weather_data.is_cached)
    logger.dbg("display_chart: header_group created: ", header_group)
    local header_height = header_group:getSize().h
    logger.dbg("display_chart: header_height=", header_height)

    -- Width cap is based on the number of displayed columns (FORECAST_HOURS), not total hourly entries
    local n_hours = #FORECAST_HOURS
    local row_w   = n_hours * base_hourly_icon_size
                  + (n_hours - 1) * base_horizontal_spacing
    local max_scale = screen_width / row_w
    logger.dbg("display_chart: n_hours=", n_hours, "row_w=", row_w, "max_scale=", max_scale)

    local function buildContent(scale)
        logger.dbg("display_chart: buildContent() scale=", scale)
        local hourly_icon_size   = math.floor(base_hourly_icon_size   * scale)
        local label_font_size    = math.floor(base_label_font_size    * scale)
        local hour_font_size     = math.floor(base_hour_font_size     * scale)
        local bar_height         = math.floor(base_bar_height         * scale)
        local vertical_spacing   = math.floor(base_vertical_spacing   * scale)
        local horizontal_spacing = math.floor(base_horizontal_spacing * scale)
        logger.dbg("display_chart: icon_size=", hourly_icon_size, "bar_height=", bar_height, "h_spacing=", horizontal_spacing)

        local widgets = {}

        local function addRow(hourly_data, label)
            logger.dbg("display_chart: addRow() label=", label, "hourly_data=", hourly_data)
            if not hourly_data or #hourly_data == 0 then
                logger.dbg("display_chart: addRow() skipped - empty data")
                return
            end
            logger.dbg("display_chart: addRow() #hourly_data=", #hourly_data)
            table.insert(widgets, TextWidget:new {
                text = label,
                face = Font:getFace("cfont", label_font_size),
                bold = true,
            })
            logger.dbg("display_chart: calling buildHourlyChartRow for label=", label)
            local row = DisplayHelper:buildHourlyChartRow(
                hourly_data, FORECAST_HOURS,
                hourly_icon_size, hour_font_size, horizontal_spacing, bar_height)
            logger.dbg("display_chart: buildHourlyChartRow returned: ", row)
            if row then
                table.insert(widgets, row)
            end
            table.insert(widgets, VerticalSpan:new { width = vertical_spacing })
            logger.dbg("display_chart: addRow() done for label=", label)
        end

        logger.dbg("display_chart: adding today row")
        addRow(weather_data.hourly_today_all,    todayLabel())
        logger.dbg("display_chart: adding tomorrow row")
        addRow(weather_data.hourly_tomorrow_all, tomorrowLabel())
        logger.dbg("display_chart: all rows added, #widgets=", #widgets)

        logger.dbg("display_chart: building VerticalGroup with #widgets=", #widgets)
        return VerticalGroup:new {
            align = "center",
            unpack(widgets),
        }
    end

    local available_height = screen_height - header_height
    logger.dbg("display_chart: available_height=", available_height)
    logger.dbg("display_chart: calling scaleToFit")
    local weather_group    = DisplayHelper:scaleToFit(
        buildContent, available_height, nil, max_scale)
    logger.dbg("display_chart: scaleToFit returned: ", weather_group)

    logger.dbg("display_chart: building CenterContainer")
    local main_content = CenterContainer:new {
        dimen = Screen:getSize(),
        weather_group,
    }

    logger.dbg("display_chart: building OverlapGroup")
    local result = OverlapGroup:new {
        dimen = Screen:getSize(),
        main_content,
        header_group,
    }
    logger.dbg("display_chart: create() complete, returning result")
    return result
end

return ChartDisplay
