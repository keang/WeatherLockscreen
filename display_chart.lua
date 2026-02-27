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

-- Match all possible hours so every entry in hourly_data is shown
local ALL_HOURS = {}
for i = 0, 23 do ALL_HOURS[#ALL_HOURS + 1] = i end

function ChartDisplay:create(weather_lockscreen, weather_data)
    local screen_width  = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local base_hourly_icon_size   = 120
    local base_label_font_size    = 30
    local base_hour_font_size     = 24
    local base_bar_height         = 80
    local base_vertical_spacing   = 30
    local base_horizontal_spacing = 20

    local header_font_size = Screen:scaleBySize(20)
    local header_margin    = 10

    local header_group = DisplayHelper:createHeaderWidgets(
        header_font_size, header_margin, weather_data,
        Blitbuffer.COLOR_DARK_GRAY, weather_data.is_cached)
    local header_height = header_group:getSize().h

    -- Count actual hourly entries to derive width-based scale cap
    local n_today    = weather_data.hourly_today_all    and #weather_data.hourly_today_all    or 0
    local n_tomorrow = weather_data.hourly_tomorrow_all and #weather_data.hourly_tomorrow_all or 0
    local n_hours    = math.max(n_today, n_tomorrow)

    local max_scale
    if n_hours > 0 then
        local row_w = n_hours * base_hourly_icon_size
                    + (n_hours - 1) * base_horizontal_spacing
        max_scale = math.min(1.0, screen_width / row_w)
    end

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
                hourly_data, ALL_HOURS,
                hourly_icon_size, hour_font_size, horizontal_spacing, bar_height)
            if row then
                table.insert(widgets, row)
            end
            table.insert(widgets, VerticalSpan:new { width = vertical_spacing })
        end

        addRow(weather_data.hourly_today_all,    _("Today"))
        addRow(weather_data.hourly_tomorrow_all, _("Tomorrow"))

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
