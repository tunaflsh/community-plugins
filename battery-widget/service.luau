--!nonstrict
-- Battery sampler: reads sysfs, keeps a long-window history, and publishes a
-- stable snapshot for the bar widget.
--
-- The point of this service is that a fuel gauge which only updates in coarse
-- steps (0.37 Wh on the HP PG03052XL) must never be differentiated over a short
-- interval. UPower does that internally and produces ~88 W / "15 min left"
-- spikes. Here the rate is a least-squares slope over a 20-minute window, so a
-- single step is averaged against the previous ones.

local battery = require("./lib/battery.luau")

local SNAPSHOT = "battery.snapshot"
local ACTIVE_STATUS = { Charging = true, Discharging = true }

local deviceDir = nil
local windowMin = 20
local autoDetect = false
local samples = {}
local lastGood = nil
local lastStatus = nil
local lastDesignCache = nil
local directSmbiosChecked = false
local detectInFlight = false
local serviceStartMs = nil

-- Give the session time to settle before an automatic polkit prompt, and do
-- not nag on every start if the prompt was missed.
local AUTO_DETECT_DELAY_MS = 120000
local DETECT_RETRY_SECONDS = 7 * 24 * 3600

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function loadCachedDesign()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return 0
  end
  local raw = noctalia.readFile(dir .. "/design.json")
  if type(raw) ~= "string" then
    return 0
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) == "table" and tonumber(decoded.design_mwh) then
    return tonumber(decoded.design_mwh)
  end
  return 0
end

local function saveCachedDesign(mwh, source)
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  noctalia.writeFile(
    dir .. "/design.json",
    noctalia.json.encode({ design_mwh = mwh, source = source, detected_at = os.time() })
  )
end

local function designDetectRecent()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return false
  end
  local raw = noctalia.readFile(dir .. "/design-detect.json")
  if type(raw) ~= "string" then
    return false
  end
  local decoded = noctalia.json.decode(raw)
  local attempted = type(decoded) == "table" and tonumber(decoded.attempted_at) or nil
  return attempted ~= nil and (os.time() - attempted) < DETECT_RETRY_SECONDS
end

local function markDesignDetectAttempt()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  noctalia.writeFile(
    dir .. "/design-detect.json",
    noctalia.json.encode({ attempted_at = os.time() })
  )
end

local function loadConfig()
  windowMin = clamp(tonumber(noctalia.getConfig("smoothing_window_min")) or 20, 10, 60)
  autoDetect = noctalia.getConfig("auto_detect_design") == true
end

-- Resolution order:
--   1. an explicit setting (wins),
--   2. a cached SMBIOS value from a previous direct read or polkit read,
--   3. a direct rootless SMBIOS read (works where DMI is readable),
--   4. the firmware's energy_full_design (possibly the HP "design = full" bug).
local function resolveDesign()
  local explicit = tonumber(noctalia.getConfig("design_capacity_mwh")) or 0
  if explicit > 0 then
    return explicit, "setting"
  end

  if lastDesignCache == nil then
    lastDesignCache = loadCachedDesign()
  end
  if lastDesignCache ~= nil and lastDesignCache > 0 then
    return lastDesignCache, "smbios-cache"
  end

  if not directSmbiosChecked then
    directSmbiosChecked = true
    local mwh, where = battery.readSmbiosDesign()
    if mwh ~= nil then
      lastDesignCache = mwh
      saveCachedDesign(mwh, "smbios:" .. tostring(where))
      return mwh, "smbios"
    end
  end

  return 0, "firmware"
end

local function resetHistory()
  samples = {}
  lastGood = nil
  lastStatus = nil
end

local function addSample(now, energyWh)
  if energyWh == nil then
    return
  end
  local last = samples[#samples]
  -- A suspend/resume or a clock jump must not become a huge fake slope.
  if last ~= nil and (now - last.t) > 300000 then
    samples = {}
  end
  samples[#samples + 1] = { t = now, e = energyWh }
  local cutoff = now - windowMin * 60000
  while #samples > 2 and samples[1].t < cutoff do
    table.remove(samples, 1)
  end
end

-- Returns a signed rate (negative = discharging) or nil when the window does
-- not yet contain enough real movement to be trusted.
local function regressionRate(now)
  local cutoff = now - windowMin * 60000
  local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
  local first, last = nil, nil
  for _, sample in ipairs(samples) do
    if sample.t >= cutoff then
      n = n + 1
      sx = sx + sample.t
      sy = sy + sample.e
      sxx = sxx + sample.t * sample.t
      sxy = sxy + sample.t * sample.e
      first = first or sample
      last = sample
    end
  end
  if n < 5 or first == nil or last == nil then
    return nil
  end
  local span = (last.t - first.t) / 1000
  if span < math.max(300, windowMin * 60 * 0.4) then
    return nil
  end
  if math.abs(last.e - first.e) < 0.2 then
    return nil
  end
  local denominator = n * sxx - sx * sx
  if denominator == 0 then
    return nil
  end
  local slope = (n * sxy - sx * sy) / denominator
  local signed = slope * 3600000
  if math.abs(signed) < 0.3 then
    return nil
  end
  return signed
end

local function pickRate(now, state)
  if state.powerW ~= nil and state.powerW > 0.5 then
    return state.powerW
  end

  local signed = regressionRate(now)
  if signed ~= nil then
    if state.status == "Discharging" and signed < 0 then
      return -signed
    elseif state.status == "Charging" and signed > 0 then
      return signed
    end
    return nil
  end

  if lastGood ~= nil and lastGood.status == state.status and (now - lastGood.at) <= 900000 then
    return lastGood.rate
  end
  return nil
end

local startDetect
local refresh

startDetect = function(manual)
  if detectInFlight then
    return
  end
  if not manual and designDetectRecent() then
    return
  end
  if not noctalia.commandExists("pkexec") or not noctalia.commandExists("dmidecode") then
    markDesignDetectAttempt()
    if manual then
      noctalia.notifyError(
        noctalia.tr("notify.detect_title"),
        noctalia.tr("notify.detect_missing")
      )
    end
    return
  end

  detectInFlight = true
  markDesignDetectAttempt()
  local started = noctalia.runAsync({ "pkexec", "dmidecode", "-t", "22" }, function(result)
    detectInFlight = false
    local mwh = nil
    if result.exitCode == 0 then
      mwh = tonumber(result.stdout:match("Design Capacity:%s*(%d+)%s*mWh"))
    end
    if mwh == nil or mwh <= 0 then
      if manual then
        noctalia.notifyError(
          noctalia.tr("notify.detect_title"),
          noctalia.tr("notify.detect_failed")
        )
      end
      return
    end

    lastDesignCache = mwh
    saveCachedDesign(mwh, "dmidecode")
    refresh()
    noctalia.notify(
      noctalia.tr("notify.detect_title"),
      noctalia.tr("notify.detect_ok", { capacity = string.format("%.1f", mwh / 1000) })
    )
  end)

  if not started then
    detectInFlight = false
    if manual then
      noctalia.notifyError(
        noctalia.tr("notify.detect_title"),
        noctalia.tr("notify.detect_failed")
      )
    end
  end
end

local function publish(now, state, source)
  local snapshot = {
    present = true,
    capacity = state.capacity,
    status = state.status,
    plugged = state.plugged,
    energyWh = state.energyWh,
    fullWh = state.fullWh,
    designWh = state.designWh,
    designSource = source,
    cycles = state.cycles,
    deviceDir = state.dir,
  }

  if state.fullWh ~= nil and state.designWh ~= nil then
    snapshot.healthPct = battery.health(state.fullWh, state.designWh)
    snapshot.healthSuspect = source == "firmware"
        and battery.designLooksUnreported(state.designWh, state.fullWh)
  end

  if ACTIVE_STATUS[state.status] then
    local rate = pickRate(now, state)
    if rate ~= nil and rate > 0 then
      snapshot.rateW = rate
      if state.powerW == nil or state.powerW <= 0.5 then
        lastGood = { rate = rate, status = state.status, at = now }
      end

      local seconds = nil
      if state.status == "Discharging" and state.energyWh ~= nil then
        seconds = state.energyWh / rate * 3600
        snapshot.timeKind = "empty"
      elseif state.status == "Charging" and state.fullWh ~= nil and state.energyWh ~= nil then
        seconds = math.max(0, state.fullWh - state.energyWh) / rate * 3600
        snapshot.timeKind = "full"
      end

      if seconds ~= nil and seconds > 0 and seconds < 172800 then
        snapshot.timeSeconds = seconds
      end
    end
  else
    lastGood = nil
  end

  noctalia.state.set(SNAPSHOT, snapshot)
end

refresh = function()
  loadConfig()

  local selector = noctalia.getConfig("device") or "auto"
  if deviceDir == nil or not noctalia.fileExists(deviceDir .. "/capacity") then
    deviceDir = battery.resolveDevice(selector)
  end

  local overrideMwh, source = resolveDesign()
  local state = battery.read(deviceDir, overrideMwh)
  if state == nil or not state.present then
    deviceDir = nil
    resetHistory()
    noctalia.state.set(SNAPSHOT, { present = false })
    return
  end

  local now = noctalia.nowMs()

  if lastStatus ~= nil and lastStatus ~= state.status then
    -- Charging <-> discharging: old samples describe the other direction.
    resetHistory()
  end
  lastStatus = state.status

  addSample(now, state.energyWh)
  publish(now, state, source)

  -- Only ask for a privileged SMBIOS read when the firmware value is the
  -- "design = full" lie. The marker file stops it from nagging every start.
  if source == "firmware"
      and autoDetect
      and serviceStartMs ~= nil
      and (now - serviceStartMs) >= AUTO_DETECT_DELAY_MS
      and state.fullWh ~= nil
      and state.designWh ~= nil
      and battery.designLooksUnreported(state.designWh, state.fullWh) then
    startDetect(false)
  end
end

function update()
  refresh()
end

function onConfigChanged()
  lastDesignCache = nil
  directSmbiosChecked = false
  refresh()
end

function onIpc(event)
  if event == "detect-design" then
    startDetect(true)
  end
end

serviceStartMs = noctalia.nowMs()
noctalia.setUpdateInterval(30000)
refresh()

