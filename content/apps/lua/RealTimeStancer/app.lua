local ac = require('ac')
local ui = require('ui')
local json = require('json')

local csp = nil
local ok, mod = pcall(require, 'csp')
if ok then
  csp = mod
end

ui.InputTextFlags = ui.InputTextFlags or { None = 0 }
ui.SelectableFlags = ui.SelectableFlags or { None = 0 }
local uiVec2 = ui.vec2 or function(x, y)
  return { x = x, y = y }
end

local REQUIRED_PATCH_VERSION = '0.1.80'
local APP_NAME = 'Real Time Stancer'
local CONFIG_FILENAME = 'content/apps/lua/RealTimeStancer/config_presets.json'

local wheelMap = {
  { id = 0, label = 'Front Left', short = 'FL' },
  { id = 1, label = 'Front Right', short = 'FR' },
  { id = 2, label = 'Rear Left', short = 'RL' },
  { id = 3, label = 'Rear Right', short = 'RR' },
}

local defaultPerWheel = {}
for _, wheel in ipairs(wheelMap) do
  defaultPerWheel[wheel.id + 1] = {
    offset = 0.0,
    camber = 0.0,
    rideHeight = 0.0,
    track = 0.0,
  }
end

local function cloneTable(source)
  if type(source) ~= 'table' then return source end
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = cloneTable(value)
  end
  return copy
end

local state = {
  ready = false,
  errorMessage = nil,
  activeCar = -1,
  presets = {},
  presetInput = '',
  global = {
    offset = 0.0,
    rideHeight = 0.0,
    camber = 0.0,
    track = 0.0,
  },
  perWheel = cloneTable(defaultPerWheel),
}

local function parseVersion(value)
  if type(value) ~= 'string' then return { 0, 0, 0 } end
  local a, b, c = value:match('(%d+)%.(%d+)%.(%d+)')
  if not a then
    local x, y = value:match('(%d+)%.(%d+)')
    if x then
      return { tonumber(x) or 0, tonumber(y) or 0, 0 }
    end
    return { tonumber(value) or 0, 0, 0 }
  end
  return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 }
end

local function versionLessThan(a, b)
  for i = 1, 3 do
    if (a[i] or 0) < (b[i] or 0) then
      return true
    elseif (a[i] or 0) > (b[i] or 0) then
      return false
    end
  end
  return false
end

local function getPatchVersion()
  if csp and csp.getVersion then
    local okVersion, version = pcall(csp.getVersion)
    if okVersion and type(version) == 'table' and version.versionString then
      return version.versionString
    elseif okVersion and type(version) == 'string' then
      return version
    end
  end
  if ac and ac.getPatchVersion then
    local okVersion, version = pcall(ac.getPatchVersion)
    if okVersion and type(version) == 'string' then
      return version
    end
  end
  return '0.0.0'
end

local function fileExists(path)
  local f = io.open(path, 'r')
  if f then
    f:close()
    return true
  end
  return false
end

local function readFile(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

local function writeFile(path, content)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function ensureConfigFile()
  if fileExists(CONFIG_FILENAME) then
    return true
  end
  local defaultContent = json.encode({
    version = 1,
    presets = {},
  }, true)
  return writeFile(CONFIG_FILENAME, defaultContent or '{"version":1,"presets":[]}')
end

local function loadPresets()
  if not fileExists(CONFIG_FILENAME) then
    ensureConfigFile()
  end
  local content = readFile(CONFIG_FILENAME)
  if not content or content == '' then
    state.presets = {}
    return
  end
  local okData, decoded = pcall(json.decode, content)
  if okData and decoded and type(decoded.presets) == 'table' then
    state.presets = decoded.presets
  else
    state.presets = {}
  end
end

local function savePresets()
  local payload = {
    version = 1,
    presets = state.presets,
  }
  writeFile(CONFIG_FILENAME, json.encode(payload, true))
end

local function findPresetIndex(name)
  for i, preset in ipairs(state.presets) do
    if preset.name == name then
      return i
    end
  end
  return nil
end

local function serializeCurrentSettings()
  return {
    global = cloneTable(state.global),
    perWheel = cloneTable(state.perWheel),
  }
end

local function applyPresetData(data)
  if not data then return end
  if data.global then
    state.global = cloneTable(data.global)
  end
  if data.perWheel then
    for i = 1, #state.perWheel do
      state.perWheel[i] = cloneTable(data.perWheel[i] or defaultPerWheel[i])
    end
  end
end

local function saveCurrentAsPreset(name)
  if not name or name == '' then return end
  local preset = {
    name = name,
    data = serializeCurrentSettings(),
  }
  local idx = findPresetIndex(name)
  if idx then
    state.presets[idx] = preset
  else
    table.insert(state.presets, preset)
  end
  savePresets()
end

local function loadPresetByName(name)
  local idx = findPresetIndex(name)
  if not idx then return end
  applyPresetData(state.presets[idx].data)
end

local function deletePresetByName(name)
  local idx = findPresetIndex(name)
  if not idx then return end
  table.remove(state.presets, idx)
  savePresets()
end

local function resetCurrentSettings()
  state.global = {
    offset = 0.0,
    rideHeight = 0.0,
    camber = 0.0,
    track = 0.0,
  }
  for i = 1, #state.perWheel do
    state.perWheel[i] = cloneTable(defaultPerWheel[i])
  end
end

local cachedWheelBaselines = {}

local function fetchWheelBaselines(carIndex)
  if cachedWheelBaselines[carIndex] then
    return cachedWheelBaselines[carIndex]
  end
  local result = {}
  for _, wheel in ipairs(wheelMap) do
    result[wheel.id] = {
      camber = 0.0,
      offset = 0.0,
      rideHeight = 0.0,
      track = 0.0,
    }
    if csp and csp.getWheelSetup then
      local okWheel, info = pcall(csp.getWheelSetup, carIndex, wheel.id)
      if okWheel and info then
        result[wheel.id] = {
          camber = info.camber or 0.0,
          offset = info.offset or 0.0,
          rideHeight = info.rideHeight or 0.0,
          track = info.track or 0.0,
        }
      end
    end
  end
  cachedWheelBaselines[carIndex] = result
  return result
end

local function ensureReady()
  if state.ready then return end
  local currentVersion = parseVersion(getPatchVersion())
  local requiredVersion = parseVersion(REQUIRED_PATCH_VERSION)
  if versionLessThan(currentVersion, requiredVersion) then
    state.errorMessage = string.format('Requires CSP %s or newer', REQUIRED_PATCH_VERSION)
    return
  end
  if csp and csp.isLuaEnabled and not csp.isLuaEnabled() then
    state.errorMessage = 'CSP Lua scripting is disabled'
    return
  end
  ensureConfigFile()
  loadPresets()
  state.ready = true
end

local function getFocusedCarIndex()
  if ac and ac.getSim then
    local okSim, sim = pcall(ac.getSim)
    if okSim and sim and sim.focusedCar ~= nil then
      return sim.focusedCar
    end
  end
  if ac and ac.getCarState then
    return 0
  end
  return 0
end

local function applyWheelChanges(carIndex, wheelId, baseline, wheelState)
  if not baseline then return end
  local effective = {
    offset = baseline.offset + state.global.offset + wheelState.offset,
    track = baseline.track + state.global.track + wheelState.track,
    camber = baseline.camber + state.global.camber + wheelState.camber,
    rideHeight = baseline.rideHeight + state.global.rideHeight + wheelState.rideHeight,
  }

  if csp and csp.setWheelSetup then
    csp.setWheelSetup(carIndex, wheelId, {
      offset = effective.offset,
      track = effective.track,
      camber = effective.camber,
      rideHeight = effective.rideHeight,
    })
    return
  end

  if ac and ac.setWheelAlignment then
    ac.setWheelAlignment(carIndex, wheelId, {
      offset = effective.offset,
      track = effective.track,
      camber = math.rad(effective.camber),
      rideHeight = effective.rideHeight,
    })
    return
  end
end

local function applyAllWheels()
  local focusedCar = getFocusedCarIndex()
  if focusedCar == nil then return end
  if state.activeCar ~= focusedCar then
    state.activeCar = focusedCar
    cachedWheelBaselines[focusedCar] = nil
  end

  local baseline = fetchWheelBaselines(focusedCar)
  for _, wheel in ipairs(wheelMap) do
    local wheelBaseline = baseline[wheel.id]
    local wheelState = state.perWheel[wheel.id + 1]
    applyWheelChanges(focusedCar, wheel.id, wheelBaseline, wheelState)
  end
end

local function drawWheelControls(wheelIndex)
  local wheel = wheelMap[wheelIndex]
  if not wheel then return end
  local id = wheel.id + 1
  local wheelState = state.perWheel[id]

  ui.columns(2, false)
  ui.setColumnWidth(0, 140)
  ui.text(wheel.label)
  ui.nextColumn()

  ui.pushID(wheel.short .. '_offset')
  local changed, value = ui.sliderFloat('Offset (mm)', wheelState.offset, -50.0, 50.0, '%.1f')
  if changed then wheelState.offset = value end
  ui.popID()

  ui.pushID(wheel.short .. '_track')
  changed, value = ui.sliderFloat('Track (mm)', wheelState.track, -50.0, 50.0, '%.1f')
  if changed then wheelState.track = value end
  ui.popID()

  ui.pushID(wheel.short .. '_camber')
  changed, value = ui.sliderFloat('Camber (°)', wheelState.camber, -10.0, 10.0, '%.1f')
  if changed then wheelState.camber = value end
  ui.popID()

  ui.pushID(wheel.short .. '_ride')
  changed, value = ui.sliderFloat('Ride Height (mm)', wheelState.rideHeight, -40.0, 40.0, '%.1f')
  if changed then wheelState.rideHeight = value end
  ui.popID()

  ui.columns(1)
  ui.separator()
end

local function drawPresetManager()
  ui.text('Presets')
  ui.separator()

  ui.pushItemWidth(-1)
  local changed, name = ui.inputText('Preset Name', state.presetInput, ui.InputTextFlags.None)
  if changed then state.presetInput = name end
  ui.popItemWidth()

  if ui.button('Save Preset', uiVec2(150, 26)) then
    if state.presetInput ~= '' then
      saveCurrentAsPreset(state.presetInput)
    end
  end
  ui.sameLine()
  if ui.button('Reset Values', uiVec2(150, 26)) then
    resetCurrentSettings()
  end

  ui.separator()

  if ui.beginChild('PresetList', uiVec2(-1, 150), true) then
    for _, preset in ipairs(state.presets) do
      ui.pushID(preset.name)
      if ui.selectable(preset.name, false, ui.SelectableFlags.None, uiVec2(-1, 22)) then
        loadPresetByName(preset.name)
        state.presetInput = preset.name
      end
      ui.sameLine()
      if ui.button('Load', uiVec2(60, 22)) then
        loadPresetByName(preset.name)
        state.presetInput = preset.name
      end
      ui.sameLine()
      if ui.button('Delete', uiVec2(60, 22)) then
        deletePresetByName(preset.name)
        if state.presetInput == preset.name then
          state.presetInput = ''
        end
      end
      ui.popID()
    end
    ui.endChild()
  end
end

local function drawGlobalControls()
  ui.text('Global Adjustments')
  ui.separator()

  ui.pushID('global_offset')
  local changed, value = ui.sliderFloat('Wheel Offset (mm)', state.global.offset, -50.0, 50.0, '%.1f')
  if changed then state.global.offset = value end
  ui.popID()

  ui.pushID('global_track')
  changed, value = ui.sliderFloat('Track Width (mm)', state.global.track, -50.0, 50.0, '%.1f')
  if changed then state.global.track = value end
  ui.popID()

  ui.pushID('global_camber')
  changed, value = ui.sliderFloat('Camber (°)', state.global.camber, -10.0, 10.0, '%.1f')
  if changed then state.global.camber = value end
  ui.popID()

  ui.pushID('global_rideheight')
  changed, value = ui.sliderFloat('Ride Height (mm)', state.global.rideHeight, -40.0, 40.0, '%.1f')
  if changed then state.global.rideHeight = value end
  ui.popID()

  ui.separator()
end

function script.update(dt)
  ensureReady()
  if not state.ready then return end
  applyAllWheels()
end

function script.windowTitle()
  return APP_NAME
end

function script.windowWidth()
  return 360
end

function script.windowHeight()
  return 480
end

function script.drawUI()
  ensureReady()

  if not state.ready then
    ui.text(state.errorMessage or 'CSP requirement not met.')
    return
  end

  drawGlobalControls()

  ui.text('Per Wheel')
  ui.separator()
  for i = 1, #wheelMap do
    drawWheelControls(i)
  end

  drawPresetManager()
end
