--[[
    Chart Display Mode for Weather Lockscreen
    Shows temperature line and precipitation bars for Today and Tomorrow
--]]

local Widget = require("ui/widget/widget")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
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

--- Draw a line on a blitbuffer using Bresenham's algorithm with a given thickness.
local function drawLine(bb, x0, y0, x1, y1, color, thickness)
    thickness = thickness or 2
    local half = math.floor(thickness / 2)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy
    while true do
        bb:paintRect(x0 - half, y0 - half, thickness, thickness, color)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x0 = x0 + sx end
        if e2 < dx then err = err + dx; y0 = y0 + sy end
    end
end

--- ChartCanvas: custom widget that renders temperature line + precipitation bars.
--- Layout (top to bottom inside the widget bounds):
---   [icon zone]  icon_size px  — icons for icon_hours
---   [temp zone]  font_size+4 px — temperature labels for icon_hours
---   [chart area] — temperature line, precip bars, grid, y-axis labels
---   [hour zone]  font_size+4 px — hour labels for label_hours
local ChartCanvas = Widget:extend {
    width        = 0,
    height       = 0,
    hourly_data  = nil,
    font_size    = 16,
    icon_size    = 44,
    use_celsius  = true,
    label_hours  = { 0, 6, 12, 18 },  -- show hour text at these hours
    icon_hours   = { 6, 12, 18 },     -- show icons + temp labels at these hours
}

function ChartCanvas:getSize()
    return { w = self.width, h = self.height }
end

function ChartCanvas:paintTo(bb, x, y)
    if not self.hourly_data or #self.hourly_data == 0 then return end

    local data    = self.hourly_data
    local n       = #data
    local fs      = self.font_size
    local face    = Font:getFace("cfont", fs)
    local icon_sz = self.icon_size

    -- Padding zones
    local pl = fs * 2 + 6           -- left:   Y-axis labels
    local pr = 4                    -- right:  margin
    local pt = icon_sz + fs + 8    -- top:    icon zone + temp-label zone
    local pb = fs + 6              -- bottom: hour-label zone

    local chart_w = self.width  - pl - pr
    local chart_h = self.height - pt - pb
    if chart_w < 20 or chart_h < 20 then return end

    -- Collect temperature range and max precipitation
    local min_temp, max_temp, max_precip = math.huge, -math.huge, 0
    for _, h in ipairs(data) do
        local t = self.use_celsius and h.temp_c or h.temp_f
        if t < min_temp then min_temp = t end
        if t > max_temp then max_temp = t end
        local p = h.precip_mm or 0
        if p > max_precip then max_precip = p end
    end

    -- Ensure a minimum range with padding
    local range = max_temp - min_temp
    if range < 4 then
        local mid = (min_temp + max_temp) / 2
        min_temp = mid - 2
        max_temp = mid + 2
        range = 4
    else
        local pad = math.max(1, math.floor(range * 0.1))
        min_temp = min_temp - pad
        max_temp = max_temp + pad
        range = max_temp - min_temp
    end

    -- Precipitation bars occupy the bottom fraction of the chart area
    local precip_zone_h = (max_precip > 0) and math.floor(chart_h * 0.28) or 0

    -- Coordinate helpers
    local function cx(i)   -- horizontal center of column i (1-based)
        return x + pl + math.floor((i - 0.5) * chart_w / n)
    end
    local function ty(temp)  -- vertical position for a temperature value
        local frac = (temp - min_temp) / range
        return y + pt + chart_h - math.floor(frac * chart_h)
    end

    -- Chart border
    bb:paintBorder(x + pl, y + pt, chart_w, chart_h, 1, Blitbuffer.COLOR_DARK_GRAY)

    -- Horizontal grid lines with Y-axis temperature labels
    local step
    if     range <= 6  then step = 1
    elseif range <= 12 then step = 2
    elseif range <= 25 then step = 4
    else                    step = 5 end

    local grid_t = math.ceil(min_temp / step) * step
    while grid_t <= max_temp do
        local gy = ty(grid_t)
        if gy >= y + pt and gy <= y + pt + chart_h then
            -- Dotted horizontal line
            local gx = x + pl + 1
            while gx < x + pl + chart_w - 1 do
                bb:paintRect(gx, gy, 2, 1, Blitbuffer.COLOR_GRAY)
                gx = gx + 5
            end
            -- Y-axis label (right-aligned against the chart left edge)
            local lbl = tostring(math.floor(grid_t)) .. "°"
            local lw = TextWidget:new { text = lbl, face = face }:getSize().w
            local tw = TextWidget:new { text = lbl, face = face }
            tw:paintTo(bb, x + pl - lw - 2, gy - math.floor(fs * 0.6))
            tw:free()
        end
        grid_t = grid_t + step
    end

    -- Precipitation bars (filled upward from bottom of chart)
    if max_precip > 0 then
        local col_w = chart_w / n
        for i, h in ipairs(data) do
            local p = h.precip_mm or 0
            if p > 0 then
                local bar_h = math.max(1, math.floor(p / max_precip * precip_zone_h))
                local bx = x + pl + math.floor((i - 1) * col_w) + 1
                local bw = math.max(1, math.floor(col_w) - 2)
                local by = y + pt + chart_h - bar_h
                bb:paintRect(bx, by, bw, bar_h, Blitbuffer.COLOR_GRAY)
            end
        end
    end

    -- Temperature line
    local prev_x, prev_y
    for i, h in ipairs(data) do
        local t  = self.use_celsius and h.temp_c or h.temp_f
        local px = cx(i)
        local py = ty(t)
        if prev_x then
            drawLine(bb, prev_x, prev_y, px, py, Blitbuffer.COLOR_BLACK, 2)
        end
        -- Small solid dot at each hour
        bb:paintRect(px - 1, py - 1, 3, 3, Blitbuffer.COLOR_BLACK)
        prev_x, prev_y = px, py
    end

    -- Build fast lookup sets
    local label_set, icon_set = {}, {}
    for _, h in ipairs(self.label_hours) do label_set[h] = true end
    for _, h in ipairs(self.icon_hours)  do icon_set[h]  = true end

    for i, h in ipairs(data) do
        local px = cx(i)

        -- Hour label below chart
        if label_set[h.hour_num] then
            local lw_tw = TextWidget:new { text = h.hour, face = face }
            local lw    = lw_tw:getSize().w
            lw_tw:paintTo(bb, px - math.floor(lw / 2), y + pt + chart_h + 3)
            lw_tw:free()
        end

        -- Icon + temperature label above chart
        if icon_set[h.hour_num] then
            -- Icon
            if h.icon_path then
                local iw = ImageWidget:new {
                    file = h.icon_path,
                    width = icon_sz, height = icon_sz,
                    alpha = true, original_in_nightmode = false,
                }
                iw:paintTo(bb, px - math.floor(icon_sz / 2), y + 2)
                iw:free()
            end
            -- Temperature label just below the icon
            local t       = self.use_celsius and h.temp_c or h.temp_f
            local temp_str = tostring(t) .. "°"
            local tw_lbl  = TextWidget:new { text = temp_str, face = face }
            local tw_w    = tw_lbl:getSize().w
            tw_lbl:paintTo(bb, px - math.floor(tw_w / 2), y + icon_sz + 4)
            tw_lbl:free()
        end
    end
end

-- ---------------------------------------------------------------------------

function ChartDisplay:create(weather_lockscreen, weather_data)
    local screen_height = Screen:getHeight()
    local screen_width  = Screen:getWidth()
    local use_celsius   = WeatherUtils:getTempScale() == "C"

    local header_font_size = Screen:scaleBySize(20)
    local header_margin    = 10
    local header_group     = DisplayHelper:createHeaderWidgets(
        header_font_size, header_margin, weather_data,
        Blitbuffer.COLOR_DARK_GRAY, weather_data.is_cached)
    local header_height = header_group:getSize().h

    local available_height = screen_height - header_height

    local function buildContent(scale)
        local label_font  = math.floor(26 * scale)
        local chart_font  = math.floor(16 * scale)
        local icon_size   = math.floor(44 * scale)
        local spacing     = math.floor(8  * scale)
        local h_margin    = math.floor(12 * scale)

        local chart_width = screen_width - 2 * h_margin

        -- Height budget: two labels + two charts + three gaps
        local label_h = label_font + 4
        local chart_height = math.floor(
            (available_height - 2 * label_h - 3 * spacing) / 2)
        if chart_height < 60 then chart_height = 60 end

        local widgets = {}

        local function addChart(hourly_data, label)
            if not hourly_data or #hourly_data == 0 then return end
            table.insert(widgets, TextWidget:new {
                text = label,
                face = Font:getFace("cfont", label_font),
                bold = true,
            })
            table.insert(widgets, VerticalSpan:new { width = spacing })
            local canvas = ChartCanvas:new {
                width       = chart_width,
                height      = chart_height,
                hourly_data = hourly_data,
                font_size   = chart_font,
                icon_size   = icon_size,
                use_celsius = use_celsius,
                label_hours = { 0, 6, 12, 18 },
                icon_hours  = { 6, 12, 18 },
            }
            table.insert(widgets, CenterContainer:new {
                dimen = { w = screen_width, h = chart_height },
                canvas,
            })
            table.insert(widgets, VerticalSpan:new { width = spacing })
        end

        addChart(weather_data.hourly_today_all,    _("Today"))
        addChart(weather_data.hourly_tomorrow_all, _("Tomorrow"))

        return VerticalGroup:new {
            align = "center",
            unpack(widgets),
        }
    end

    local weather_group = DisplayHelper:scaleToFit(buildContent, available_height)

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
