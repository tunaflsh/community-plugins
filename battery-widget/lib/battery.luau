--!nonstrict
-- Shared sysfs battery reader and formatters.
--
-- Everything here is deliberately sysfs-only: it stays cheap enough to poll
-- every 30 s and it does not depend on UPower's derived EnergyRate/TimeToEmpty,
-- which are unusable on batteries whose fuel gauge only moves in coarse steps.

local M = {}

local ROOT = "/sys/class/power_supply"

local function readText(path)
  local value = noctalia.readFile(path)
  if type(value) ~= "string" then
    return nil
  end
  value = value:gsub("%s+$", "")
  if value == "" then
    return nil
  end
  return value
end

local function readNumber(path)
  local value = readText(path)
  if value == nil then
    return nil
  end
  return tonumber(value)
end

M.readText = readText
M.readNumber = readNumber

-- SMBIOS Type 22, "Portable Battery": the design capacity lives at offset
-- 0x0A as a little-endian WORD, scaled by the multiplier at 0x15. This is the
-- only place the real design capacity exists when the EC misreports
-- energy_full_design (HP does exactly that).
function M.parseSmbiosEntry(raw)
  if type(raw) ~= "string" or #raw < 23 or raw:byte(1) ~= 22 then
    return nil
  end
  local design = raw:byte(11) + raw:byte(12) * 256
  local multiplier = raw:byte(22)
  if multiplier == 0 then
    multiplier = 1
  end
  local mwh = design * multiplier
  if mwh <= 0 or mwh > 1000000 then
    return nil
  end
  return mwh
end

-- Walk a full SMBIOS table (`/sys/firmware/dmi/tables/DMI`) and return the
-- first Type 22 design capacity. Used when the per-entry files are absent.
function M.parseSmbiosTable(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local index = 1
  while index + 3 <= #raw do
    local structureType = raw:byte(index)
    local length = raw:byte(index + 1)
    if length < 4 or index + length - 1 > #raw then
      break
    end
    if structureType == 22 then
      local mwh = M.parseSmbiosEntry(raw:sub(index, index + length - 1))
      if mwh ~= nil then
        return mwh
      end
    end
    local cursor = index + length
    while cursor <= #raw do
      if raw:byte(cursor) == 0 then
        if cursor + 1 > #raw or raw:byte(cursor + 1) == 0 then
          cursor = cursor + 2
          break
        end
      end
      cursor = cursor + 1
    end
    index = cursor
  end
  return nil
end

-- Read the design capacity straight from sysfs. Returns nil when the DMI files
-- are root-only (the common case on Arch), so callers can fall back to a
-- one-time privileged read.
function M.readSmbiosDesign()
  local entries = noctalia.listDir("/sys/firmware/dmi/entries")
  if entries then
    for _, name in ipairs(entries) do
      if name:match("^22%-") then
        local raw = noctalia.readFile("/sys/firmware/dmi/entries/" .. name .. "/raw")
        local mwh = M.parseSmbiosEntry(raw)
        if mwh ~= nil then
          return mwh, "entries/" .. name
        end
      end
    end
  end

  local raw = noctalia.readFile("/sys/firmware/dmi/tables/DMI")
  local mwh = M.parseSmbiosTable(raw)
  if mwh ~= nil then
    return mwh, "tables/DMI"
  end
  return nil
end

local function acOnline()
  local names = noctalia.listDir(ROOT)
  if not names then
    return false
  end
  for _, name in ipairs(names) do
    local dir = ROOT .. "/" .. name
    if readText(dir .. "/type") == "Mains" then
      return readText(dir .. "/online") == "1"
    end
  end
  return false
end

-- `auto` picks the first present BAT* device. A selector may also be a bare
-- sysfs name ("BAT0") or an absolute sysfs directory.
function M.resolveDevice(selector)
  if type(selector) ~= "string" or selector == "" or selector == "auto" then
    local names = noctalia.listDir(ROOT)
    if not names then
      return nil
    end
    local fallback = nil
    for _, name in ipairs(names) do
      if name:match("^BAT") then
        local dir = ROOT .. "/" .. name
        local present = readText(dir .. "/present")
        if present == "1" then
          return dir
        end
        if present == nil and readText(dir .. "/capacity") ~= nil then
          fallback = fallback or dir
        end
      end
    end
    return fallback
  end

  local dir = selector:gsub("/+$", "")
  if not dir:match("^/") then
    dir = ROOT .. "/" .. dir
  end
  if noctalia.fileExists(dir .. "/capacity") then
    return dir
  end
  return nil
end

function M.isPlugged(status)
  if status == "Charging" or status == "Full" or status == "Not charging" then
    return true
  end
  if status == "Discharging" or status == "Empty" then
    return false
  end
  return acOnline()
end

function M.isFull(status)
  return status == "Full" or status == "Not charging"
end

function M.read(dir, designOverrideMwh)
  if dir == nil then
    return nil
  end

  local present = readText(dir .. "/present")
  if present == "0" then
    return { present = false, dir = dir }
  end

  local capacity = readNumber(dir .. "/capacity")
  if capacity == nil then
    return nil
  end

  local status = readText(dir .. "/status") or "Unknown"
  local energyUwh = readNumber(dir .. "/energy_now")
  local fullUwh = readNumber(dir .. "/energy_full")
  local designUwh = readNumber(dir .. "/energy_full_design")
  local voltageUv = readNumber(dir .. "/voltage_now")
  local powerUw = readNumber(dir .. "/power_now")
  local currentUa = readNumber(dir .. "/current_now")

  -- Prefer the driver's power sensor when it actually reports one; fall back
  -- to I * V, then to the service's own long-window estimate.
  local powerW = nil
  if powerUw ~= nil and powerUw > 0 then
    powerW = powerUw / 1000000
  elseif currentUa ~= nil and voltageUv ~= nil and currentUa ~= 0 and voltageUv ~= 0 then
    powerW = math.abs(currentUa * voltageUv) / 1000000000000
  end

  local designWh = nil
  local designFromSetting = false
  if designOverrideMwh ~= nil and designOverrideMwh > 0 then
    designWh = designOverrideMwh / 1000
    designFromSetting = true
  elseif designUwh ~= nil and designUwh > 0 then
    designWh = designUwh / 1000000
  end

  local fullWh = nil
  if fullUwh ~= nil and fullUwh > 0 then
    fullWh = fullUwh / 1000000
  end

  local energyWh = nil
  if energyUwh ~= nil then
    energyWh = energyUwh / 1000000
  end

  return {
    present = true,
    dir = dir,
    capacity = capacity,
    status = status,
    plugged = M.isPlugged(status),
    energyWh = energyWh,
    fullWh = fullWh,
    designWh = designWh,
    designFromSetting = designFromSetting,
    voltageV = voltageUv ~= nil and voltageUv / 1000000 or nil,
    powerW = powerW,
    cycles = readNumber(dir .. "/cycle_count"),
  }
end

function M.health(fullWh, designWh)
  if fullWh == nil or designWh == nil or designWh <= 0 or fullWh <= 0 then
    return nil
  end
  local pct = fullWh / designWh * 100
  if pct > 100 then
    pct = 100
  elseif pct < 0 then
    pct = 0
  end
  return pct
end

-- A design capacity exactly equal to the learned full capacity is the HP-style
-- firmware bug: `_BIX` publishes the current full charge as the design value,
-- so any health figure computed from it is meaningless.
function M.designLooksUnreported(designWh, fullWh)
  if designWh == nil or fullWh == nil then
    return false
  end
  return math.abs(designWh - fullWh) < 0.01
end

function M.glyphFor(pct, status)
  if status == "Charging" then
    return "battery-charging"
  end
  if status == "Full" or status == "Not charging" then
    return "battery-plugged"
  end
  if status == "Unknown" and pct <= 0 then
    return "battery-exclamation"
  end
  if pct >= 85 then
    return "battery-4"
  elseif pct >= 55 then
    return "battery-3"
  elseif pct >= 30 then
    return "battery-2"
  elseif pct >= 10 then
    return "battery-1"
  end
  return "battery-0"
end

function M.statusKey(status)
  if status == "Charging" then
    return "status.charging"
  elseif status == "Discharging" then
    return "status.discharging"
  elseif status == "Full" or status == "Not charging" then
    return "status.plugged_in"
  elseif status == "Empty" then
    return "status.empty"
  end
  return "status.unknown"
end

function M.formatRate(watts)
  if watts == nil or watts <= 0 then
    return nil
  end
  return string.format("%.1f W", watts)
end

function M.formatDuration(seconds)
  if seconds == nil or seconds <= 0 then
    return nil
  end
  seconds = math.floor(seconds + 0.5)
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  if hours > 0 and minutes > 0 then
    return noctalia.tr("time.hours_minutes", { hours = hours, minutes = minutes })
  elseif hours > 0 then
    return noctalia.tr("time.hours", { hours = hours })
  elseif minutes > 0 then
    return noctalia.tr("time.minutes", { minutes = minutes })
  end
  return noctalia.tr("time.less_than_minute")
end

return M
