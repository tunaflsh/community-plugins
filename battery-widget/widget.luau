--!nonstrict
-- Bar widget: mirrors the built-in battery widget's glyph mode (same glyph
-- thresholds, warning colour, hide rules, label content and tooltip order),
-- but reads the snapshot from the sampler service instead of UPower's derived
-- rate/time. The visible difference is a health figure that uses a real design
-- capacity and a rate that does not jump by 80 W.

local battery = require("./lib/battery.luau")

local SNAPSHOT = "battery.snapshot"
local snapshot = noctalia.state.get(SNAPSHOT)
local lastVertical = nil

local config = {}

local function loadConfig()
  config.show_label = noctalia.getConfig("show_label") ~= false
  config.label_content = noctalia.getConfig("label_content") or "percent"
  config.hide_when_plugged = noctalia.getConfig("hide_when_plugged") == true
  config.hide_when_full = noctalia.getConfig("hide_when_full") == true
  config.warning_color = tostring(noctalia.getConfig("warning_color") or "error")
  config.show_health = noctalia.getConfig("show_health") ~= false
  config.warning_threshold = tonumber(noctalia.getSetting("battery.warning_threshold")) or 10
end

local function percentOf(bat)
  local pct = math.floor((bat.capacity or 0) + 0.5)
  if pct < 0 then
    pct = 0
  elseif pct > 100 then
    pct = 100
  end
  return pct
end

local function labelText(pct)
  if not config.show_label then
    return ""
  end
  -- Vertical bars are too narrow for rate/time; the built-in widget shows the
  -- bare number there and leaves the detail to the tooltip.
  if barWidget.isVertical() then
    return tostring(pct)
  end
  if config.label_content == "time" and snapshot.timeSeconds ~= nil and snapshot.timeSeconds > 0 then
    return battery.formatDuration(snapshot.timeSeconds) or (pct .. "%")
  elseif config.label_content == "rate" and snapshot.rateW ~= nil and snapshot.rateW > 0 then
    return battery.formatRate(snapshot.rateW) or (pct .. "%")
  end
  return pct .. "%"
end

local function tooltipRows(pct)
  local rows = {
    { key = noctalia.tr("tooltip.battery"), value = pct .. "%" },
    { key = noctalia.tr("tooltip.status"), value = noctalia.tr(battery.statusKey(snapshot.status)) },
  }

  if snapshot.timeSeconds ~= nil and snapshot.timeSeconds > 0 then
    local key = snapshot.timeKind == "full" and "tooltip.time_to_full" or "tooltip.time_left"
    rows[#rows + 1] = {
      key = noctalia.tr(key),
      value = battery.formatDuration(snapshot.timeSeconds),
    }
  end

  if snapshot.rateW ~= nil and snapshot.rateW > 0.1 then
    rows[#rows + 1] = { key = noctalia.tr("tooltip.rate"), value = battery.formatRate(snapshot.rateW) }
  end

  if config.show_health and snapshot.healthPct ~= nil then
    local health = string.format("%d%%", math.floor(snapshot.healthPct + 0.5))
    if snapshot.healthSuspect then
      health = health .. " (" .. noctalia.tr("tooltip.design_unreported") .. ")"
    end
    rows[#rows + 1] = { key = noctalia.tr("tooltip.health"), value = health }
  end

  if snapshot.designWh ~= nil and snapshot.designWh > 0 then
    local design = string.format("%.1f Wh", snapshot.designWh)
    if snapshot.designSource == "smbios" or snapshot.designSource == "smbios-cache" then
      design = design .. " (SMBIOS)"
    elseif snapshot.designSource == "setting" then
      design = design .. " (setting)"
    elseif snapshot.designSource == "firmware" then
      design = design .. " (firmware)"
    end
    rows[#rows + 1] = {
      key = noctalia.tr("tooltip.design"),
      value = design,
    }
  end

  if snapshot.cycles ~= nil and snapshot.cycles > 0 then
    rows[#rows + 1] = { key = noctalia.tr("tooltip.cycles"), value = tostring(snapshot.cycles) }
  end

  return rows
end

local function render()
  if snapshot == nil or not snapshot.present then
    barWidget.setVisible(false)
    barWidget.clearTooltip()
    return
  end

  local pct = percentOf(snapshot)
  local plugged = snapshot.plugged == true
  local hide = (config.hide_when_plugged and plugged)
      or (config.hide_when_full and battery.isFull(snapshot.status))

  barWidget.setVisible(not hide)
  if hide then
    return
  end

  local warning = config.warning_threshold > 0 and pct <= config.warning_threshold and not plugged
  local color = warning and config.warning_color or "on_surface"

  barWidget.setGlyph(battery.glyphFor(pct, snapshot.status))
  barWidget.setColor(color)
  barWidget.setGlyphColor(color)
  barWidget.setText(labelText(pct))
  barWidget.setTooltip(tooltipRows(pct))
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function update()
  local vertical = barWidget.isVertical()
  if lastVertical ~= vertical then
    lastVertical = vertical
    render()
  end
end

function onConfigChanged()
  loadConfig()
  render()
end

loadConfig()
noctalia.setUpdateInterval(60000)
render()
