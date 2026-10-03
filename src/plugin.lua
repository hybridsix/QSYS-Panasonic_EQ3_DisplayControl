-- =============================================================
-- plugin.lua
-- Panasonic EQ3 Display Control
-- Author: Michael King
--
-- Design-time definition (properties, controls, layout, pages)
-- plus the runtime hook. Runtime logic lives in runtime.lua and
-- only executes on a running Core. build.js bundles src/ into
-- the single .qplug file that Q-SYS Designer loads.
-- =============================================================

local Models = require("models")
local Commands = require("commands")

local function modelOf(props)
  return Models.Get(props["Model"].Value)
end

-- Colour bar on the plugin block in the schematic.
-- Clair Global "Patch of Blue" brand colour (#15a3d5 family).
function GetColor(props)
  return { 0, 210, 255 }
end

-- Device name from the Name property (e.g. "PRJ-201"); spaces become
-- non-breaking so the block face does not word-wrap it.
local function deviceName(props, default)
  local p = props["Name"]
  local name = p and p.Value or ""
  if name:match("^%s*$") then return default end
  return (name:gsub(" ", "\xC2\xA0"))
end

-- Block face label. Non-breaking spaces (U+00A0) stop Q-SYS from
-- word-wrapping the title. The Name property replaces the title when set;
-- the selected model is shown underneath.
function GetPrettyName(props)
  local nbsp = "\xC2\xA0"
  local title = "EQ3" .. nbsp .. "Display" .. nbsp .. "Control"
  return deviceName(props, title) .. "\n" .. modelOf(props).Name
end

function GetProperties()
  return {
    { Name = "Name", Type = "string", Value = "" },
    { Name = "Model", Type = "enum", Choices = Models.Choices, Value = Models.Default },
    { Name = "IP Address", Type = "string", Value = "192.168.10.100" },
    { Name = "Port", Type = "integer", Min = 1024, Max = 65535, Value = 1024 },
    -- Only needed when the display has command protect (password) turned on.
    { Name = "Username", Type = "string", Value = "" },
    { Name = "Password", Type = "string", Value = "" },
    { Name = "Normal Poll Interval (s)", Type = "integer", Min = 1, Max = 60, Value = 2 },
    { Name = "High Poll Interval (s)", Type = "integer", Min = 1, Max = 10, Value = 1 },
    { Name = "High Poll Timeout (s)", Type = "integer", Min = 5, Max = 180, Value = 30 },
    { Name = "Debug Print", Type = "enum", Choices = { "None", "Tx/Rx", "All" }, Value = "None" },
  }
end

function GetControls(props)
  local ctrls = {}

  local function add(c) ctrls[#ctrls + 1] = c end
  local function trigger(name)
    add({ Name = name, ControlType = "Button", ButtonType = "Trigger", PinStyle = "Input", UserPin = true })
  end
  local function toggle(name)
    add({ Name = name, ControlType = "Button", ButtonType = "Toggle", PinStyle = "Both", UserPin = true })
  end
  local function text(name)
    add({ Name = name, ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true })
  end
  local function led(name)
    add({ Name = name, ControlType = "Indicator", IndicatorType = "Led", PinStyle = "Output", UserPin = true })
  end
  local function choice(name)
    add({ Name = name, ControlType = "Text", PinStyle = "Both", UserPin = true })
  end
  local function level(name, range)
    add({
      Name = name, ControlType = "Knob", ControlUnit = "Integer",
      Min = range.Min, Max = range.Max, Count = 1, PinStyle = "Both", UserPin = true,
    })
  end

  trigger("PowerOn")
  trigger("PowerOff")
  led("PowerState")
  text("PowerText")

  choice("Input")
  level("Volume", Commands.VolumeRange)
  toggle("AudioMute")
  led("MuteState")
  level("Backlight", Commands.BacklightRange)
  choice("Aspect")
  choice("PictureMode")

  led("Connected")
  add({ Name = "Status", ControlType = "Indicator", IndicatorType = "Status", PinStyle = "Output", UserPin = true })
  text("Model")
  text("SerialNumber")
  text("IPAddress")

  text("DetailText")
  text("LastCommand")
  text("LastResponse")
  text("LastError")
  text("QueueDepth")

  add({ Name = "CustomCommand", ControlType = "Text", PinStyle = "Both", UserPin = true })
  add({ Name = "CustomReply", ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true })
  trigger("CustomSend")

  return ctrls
end

function GetControlLayout(props)
  local layout, graphics = {}, {}
  local TEXT = { 60, 60, 60 }
  local PRETTY = {
    Model = "Status~Model", SerialNumber = "Status~Serial Number", Connected = "Status~Connected",
    IPAddress = "Status~IP Address", Status = "Status~Connection",
    PowerOn = "Power~On", PowerOff = "Power~Off", PowerState = "Power~State", PowerText = "Power~State Text",
    Input = "Input~Select",
    Aspect = "Picture~Aspect", PictureMode = "Picture~Picture Mode", Backlight = "Picture~Backlight",
    Volume = "Audio~Volume", AudioMute = "Audio~Mute", MuteState = "Audio~Mute LED",
    DetailText = "Diagnostics~Detail", LastCommand = "Diagnostics~Last Command",
    LastResponse = "Diagnostics~Last Reply", LastError = "Diagnostics~Last Error",
    QueueDepth = "Diagnostics~Queue Depth",
    CustomCommand = "Raw~Command", CustomSend = "Raw~Send", CustomReply = "Raw~Reply",
  }

  -- Panel width 500px: boxes at x=5, w=490, 5px grid.
  local function box(title, x, y, w, h)
    graphics[#graphics + 1] = {
      Type = "GroupBox", Text = title, Fill = { 195, 195, 195 }, StrokeWidth = 2,
      StrokeColor = { 0, 210, 255 }, CornerRadius = 8, Position = { x, y }, Size = { w, h },
    }
  end
  local function label(title, x, y, w)
    graphics[#graphics + 1] = {
      Type = "Text", Text = title, Position = { x, y }, Size = { w, 20 }, FontSize = 11,
      HTextAlign = "Right", Color = TEXT,
    }
  end
  local function control(name, style, x, y, w, h, extra)
    local c = { PrettyName = PRETTY[name] or name, Style = style, Position = { x, y }, Size = { w, h }, FontSize = 12 }
    for k, v in pairs(extra or {}) do c[k] = v end
    layout[name] = c
  end
  local function button(name, legend, x, y, w, h, color)
    control(name, "Button", x, y, w, h, { Legend = legend, Color = color })
  end

  -- Connection
  box("Connection", 5, 5, 490, 110)
  label("Model:", 10, 30, 75)
  control("Model", "Text", 90, 28, 195, 22)
  label("Connected:", 295, 30, 75)
  control("Connected", "Led", 375, 28, 22, 22)
  label("IP Address:", 10, 58, 75)
  control("IPAddress", "Text", 90, 56, 195, 22)
  label("Serial:", 295, 58, 75)
  control("SerialNumber", "Text", 375, 56, 115, 22)
  label("Status:", 10, 86, 75)
  control("Status", "Text", 90, 84, 390, 22)

  -- Power
  box("Power", 5, 120, 490, 60)
  button("PowerOn", "Power On", 10, 145, 130, 28, { 0, 200, 220 })
  button("PowerOff", "Power Off", 145, 145, 130, 28, { 255, 140, 0 })
  control("PowerState", "Led", 290, 148, 22, 22)
  control("PowerText", "Text", 317, 148, 140, 22)

  -- Input
  box("Input", 5, 185, 490, 55)
  control("Input", "ComboBox", 10, 210, 250, 24)

  -- Picture
  box("Picture", 5, 245, 490, 110)
  label("Aspect:", 10, 272, 75)
  control("Aspect", "ComboBox", 90, 270, 195, 24)
  label("Mode:", 10, 300, 75)
  control("PictureMode", "ComboBox", 90, 298, 195, 24)
  label("Backlight:", 10, 328, 75)
  control("Backlight", "Fader", 90, 326, 300, 24, { ShowTextbox = true })

  -- Audio
  box("Audio", 5, 360, 490, 55)
  label("Volume:", 10, 387, 75)
  control("Volume", "Fader", 90, 385, 240, 24, { ShowTextbox = true })
  button("AudioMute", "Mute", 340, 385, 90, 26)
  control("MuteState", "Led", 440, 387, 22, 22)

  -- Diagnostics
  box("Diagnostics", 5, 420, 490, 160)
  label("Detail:", 10, 445, 75)
  control("DetailText", "Text", 90, 443, 390, 22)
  label("Last Cmd:", 10, 471, 75)
  control("LastCommand", "Text", 90, 469, 390, 22)
  label("Last Reply:", 10, 497, 75)
  control("LastResponse", "Text", 90, 495, 390, 22)
  label("Last Error:", 10, 523, 75)
  control("LastError", "Text", 90, 521, 390, 22)
  label("Queue:", 10, 549, 75)
  control("QueueDepth", "Text", 90, 547, 60, 22)

  -- Raw command testing
  box("Raw Command", 5, 585, 490, 75)
  control("CustomCommand", "TextBox", 15, 611, 270, 24)
  button("CustomSend", "Send", 290, 609, 60, 28, { 0, 200, 220 })
  control("CustomReply", "Text", 355, 611, 130, 22)

  return layout, graphics
end

function GetPages(props)
  return { { name = "Control" } }
end

-- Runtime only: Controls does not exist at design time.
if Controls then
  require("runtime")()
end
