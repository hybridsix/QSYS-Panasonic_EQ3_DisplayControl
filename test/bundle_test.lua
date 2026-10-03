local T = require("helpers")

local BUNDLE_PATH = "dist/PanasonicEQ3DisplayControl.qplug"
local HASH = "aade6e0a88ae17960064dd516cd835af889f2882072741cf08b89d900f13f41f" -- admin1:secret:23181e1e

local function loadBundle()
  local source = __read(BUNDLE_PATH)
  T.truthy(source, "bundle not built")
  local fn, err = load(source, "@bundle")
  if not fn then error(err, 0) end
  fn()
end

-- ---------------------------------------------------------------------------
-- Design time (Controls is nil)
-- ---------------------------------------------------------------------------
loadBundle()

local function propsFromDefaults(overrides)
  local props = {}
  for _, p in ipairs(GetProperties()) do props[p.Name] = { Value = p.Value } end
  for name, value in pairs(overrides or {}) do props[name].Value = value end
  return props
end

T.test("PluginInfo is complete", function()
  T.eq(PluginInfo.Name, "Hybridsix Software~Displays~Panasonic~EQ3 Display Control")
  T.truthy(PluginInfo.Id:match("^%x+%-%x+%-%x+%-%x+%-%x+$"))
  T.truthy(PluginInfo.Version:match("^%d+%.%d+%.%d+$"), "version placeholder not replaced")
end)
T.test("the Name property replaces the block title when set", function()
  local props = propsFromDefaults()
  T.truthy(GetPrettyName(props):find("Control", 1, true))
  props["Name"].Value = "PRJ 201"
  local label = GetPrettyName(props)
  T.truthy(label:find("PRJ\xC2\xA0201", 1, true))
  T.falsy(label:find("Control", 1, true))
  props["Name"].Value = "  "
  T.truthy(GetPrettyName(props):find("Control", 1, true))
end)

T.test("property names are unique and defaults are valid", function()
  local seen = {}
  for _, p in ipairs(GetProperties()) do
    T.falsy(seen[p.Name], "duplicate property " .. p.Name)
    seen[p.Name] = true
    if p.Type == "enum" then
      local found = false
      for _, c in ipairs(p.Choices) do if c == p.Value then found = true end end
      T.truthy(found, p.Name .. " default is not a choice")
    end
  end
  for _, name in ipairs({ "Model", "IP Address", "Port", "Username", "Password", "Normal Poll Interval (s)",
    "High Poll Interval (s)", "High Poll Timeout (s)", "Debug Print" }) do
    T.truthy(seen[name], "missing property " .. name)
  end
  T.falsy(seen["Authentication Mode"], "authentication mode is taken from the display, not configured")
end)

T.test("model choices are Auto, TH-43EQ3W and TH-55EQ3W, defaulting to Auto", function()
  for _, p in ipairs(GetProperties()) do
    if p.Name == "Model" then
      T.eq(table.concat(p.Choices, ","), "Auto,TH-43EQ3W,TH-55EQ3W")
      T.eq(p.Value, "Auto")
    end
    if p.Name == "Port" then
      T.eq(p.Value, 1024)
      T.eq(p.Min, 1024)
      T.eq(p.Max, 65535)
    end
  end
end)

for _, model in ipairs({ "Auto", "TH-43EQ3W", "TH-55EQ3W" }) do
  T.test(model .. ": every laid-out control is defined, with no duplicates", function()
    local props = propsFromDefaults({ Model = model })
    local defined = {}
    for _, c in ipairs(GetControls(props)) do
      T.falsy(defined[c.Name], "duplicate control " .. c.Name)
      defined[c.Name] = true
    end
    local layout, graphics = GetControlLayout(props)
    for name in pairs(layout) do
      T.truthy(defined[name], "layout has undefined control " .. name)
    end
    for name in pairs(defined) do
      T.truthy(layout[name], "control missing from layout: " .. name)
    end
    T.truthy(#graphics > 0)
    T.eq(#GetPages(props), 1)
    T.truthy(GetPrettyName(props):find(model == "Auto" and "Panasonic\xC2\xA0EQ3" or model, 1, true))
  end)
end

T.test("level controls carry the documented ranges", function()
  local byName = {}
  for _, c in ipairs(GetControls(propsFromDefaults())) do byName[c.Name] = c end
  T.eq(byName.Volume.Min, 0)
  T.eq(byName.Volume.Max, 100)
  T.eq(byName.Backlight.Min, 0)
  T.eq(byName.Backlight.Max, 50)
end)

T.test("credentials are never exposed as controls", function()
  for _, c in ipairs(GetControls(propsFromDefaults())) do
    T.falsy(c.Name:lower():find("password", 1, true), c.Name)
    T.falsy(c.Name:lower():find("hash", 1, true), c.Name)
  end
end)

-- ---------------------------------------------------------------------------
-- Runtime, against a mocked Q-SYS environment
-- ---------------------------------------------------------------------------
local mocks = {}

local function installMocks(overrides)
  mocks.printed, mocks.timers, mocks.logs, mocks.socket = {}, {}, {}, nil
  mocks.answered = 0
  mocks.replies = {}

  Properties = propsFromDefaults(overrides)

  Controls = setmetatable({}, {
    __index = function(t, name)
      -- Like Q-SYS, assigning a new Boolean/String/Value fires EventHandler,
      -- including when the plugin itself does the assigning.
      local raw = { Name = name, Boolean = false, String = "", Value = 0, Choices = {} }
      local control = setmetatable({}, {
        __index = raw,
        __newindex = function(self, key, value)
          local old = raw[key]
          raw[key] = value
          local watched = key == "Boolean" or key == "String" or key == "Value"
          if watched and old ~= value and raw.EventHandler then raw.EventHandler(self) end
        end,
      })
      rawset(t, name, control)
      return control
    end,
  })

  TcpSocket = {
    Events = { Connected = "Connected", Reconnect = "Reconnect", Data = "Data", Closed = "Closed", Error = "Error", Timeout = "Timeout" },
    EOL = { Custom = "Custom" },
    New = function()
      local s = { written = {}, lines = {}, connectCalls = 0, disconnectCalls = 0 }
      function s:Connect(ip, port) self.connectCalls = self.connectCalls + 1; self.ip, self.port = ip, port end
      function s:Disconnect() self.disconnectCalls = self.disconnectCalls + 1 end
      function s:Write(data) self.written[#self.written + 1] = data end
      function s:ReadLine() return table.remove(self.lines, 1) end
      mocks.socket = s
      return s
    end,
  }

  Timer = {
    New = function()
      local t = { running = false }
      function t:Start(interval) self.running, self.interval = true, interval end
      function t:Stop() self.running = false end
      mocks.timers[#mocks.timers + 1] = t
      return t
    end,
  }

  Log = {
    Message = function(m) mocks.logs[#mocks.logs + 1] = m end,
    Error = function(m) mocks.logs[#mocks.logs + 1] = "ERROR " .. m end,
  }

  mocks.realPrint = mocks.realPrint or print
  print = function(...) mocks.printed[#mocks.printed + 1] = table.concat({ ... }, " ") end

  loadBundle()
end

local function removeMocks()
  Controls, Properties, TcpSocket, Timer, Log = nil, nil, nil, nil, nil
  print = mocks.realPrint
end

local function mainTimer()
  for _, t in ipairs(mocks.timers) do
    if t.interval == 0.1 then return t end
  end
end

local function tick(n)
  for _ = 1, n or 1 do mainTimer().EventHandler() end
end

local function feed(...)
  local sock = mocks.socket
  for _, line in ipairs({ ... }) do sock.lines[#sock.lines + 1] = line end
  sock.EventHandler(sock, TcpSocket.Events.Data)
end

local function lastWritten()
  local w = mocks.socket.written
  return w[#w]
end

-- Reaches the Ready state (command protect off) and answers the first power
-- poll with the given reply.
local function connect(powerReply)
  tick(1)
  local sock = mocks.socket
  T.eq(sock.connectCalls, 1)
  sock.EventHandler(sock, TcpSocket.Events.Connected)
  feed("NTCONTROL 0")
  T.eq(Controls.Status.String, "OK")
  tick(1)
  T.eq(lastWritten(), "00QPW\r")
  feed(powerReply)
  mocks.answered = #sock.written
end

-- A mock display: answers every unanswered write, using `replies` (command ->
-- reply) first, then the defaults. Commands with no entry are acknowledged.
local DEFAULT_REPLIES = {
  QPW = "00QPW:1", QMI = "00QMI:HM1", QAV = "00QAV:050", QAM = "00QAM:0",
  ["QPC:BLT"] = "00QPC:BLT025", QAS = "00QAS:NORM", ["QPC:MEN"] = "00QPC:MENSTD",
  QID = "00QID:55EQ3W", QSN = "00QSN:ABC123456",
}

local function drain(replies)
  local sock = mocks.socket
  local guard = 0
  while mocks.answered < #sock.written do
    mocks.answered = mocks.answered + 1
    local cmd = sock.written[mocks.answered]:gsub("^00", ""):gsub("\r$", "")
    local reply = (replies and replies[cmd]) or mocks.replies[cmd] or DEFAULT_REPLIES[cmd] or ("00" .. cmd)
    feed(reply)
    guard = guard + 1
    if guard > 500 then error("drain did not settle") end
  end
end

-- Queues every due poll and answers them all.
local function settle(replies)
  tick(1)
  drain(replies)
end

local function countWritten(cmd)
  local n = 0
  for _, w in ipairs(mocks.socket.written) do
    if w == "00" .. cmd .. "\r" then n = n + 1 end
  end
  return n
end

local ok, runtimeErr = pcall(function()

  T.test("runtime start-up populates static controls and connects to the configured address", function()
    installMocks({ Model = "Auto", ["IP Address"] = "10.1.2.3", Port = 1024 })
    T.eq(Controls.Model.String, "Panasonic EQ3")
    T.eq(Controls.IPAddress.String, "10.1.2.3:1024")
    T.eq(Controls.Status.String, "Disconnected")
    T.eq(#Controls.Input.Choices, 5)
    T.eq(Controls.Input.Choices[1], "HDMI 1")
    T.eq(Controls.Input.Choices[5], "USB")
    T.eq(table.concat(Controls.Aspect.Choices, ","), "Full,Normal,Native,Zoom")
    T.eq(table.concat(Controls.PictureMode.Choices, ","), "Dynamic,Graphic,Sports,Standard")
    T.eq(mocks.socket.ReconnectTimeout, 0)
    tick(1)
    T.eq(mocks.socket.connectCalls, 1)
    T.eq(mocks.socket.ip, "10.1.2.3")
    T.eq(mocks.socket.port, 1024)
    T.eq(Controls.Status.String, "Connecting...")
  end)

  T.test("a configured model is shown straight away", function()
    installMocks({ Model = "TH-43EQ3W" })
    T.eq(Controls.Model.String, "Panasonic TH-43EQ3W")
  end)

  T.test("no command protect: handshake, then polling with full feedback", function()
    installMocks()
    connect("00QPW:1")
    T.eq(Controls.Connected.Boolean, true)
    T.eq(Controls.PowerState.Boolean, true)
    T.eq(Controls.PowerText.String, "On")
    T.eq(Controls.LastResponse.String, "QPW:1")
    T.eq(Controls.LastCommand.String, "QPW")
    tick(1)
    T.eq(lastWritten(), "00QMI\r")
    drain({
      QMI = "00QMI:HM2", QAV = "00QAV:042", QAM = "00QAM:1", ["QPC:BLT"] = "00QPC:BLT035",
      QAS = "00QAS:ZOOM", ["QPC:MEN"] = "00QPC:MENDYN", QID = "00QID:55EQ3W", QSN = "00QSN:ABC123456",
    })
    T.eq(Controls.Input.String, "HDMI 2")
    T.eq(Controls.Volume.Value, 42)
    T.eq(Controls.AudioMute.Boolean, true)
    T.eq(Controls.MuteState.Boolean, true)
    T.eq(Controls.Backlight.Value, 35)
    T.eq(Controls.Aspect.String, "Zoom")
    T.eq(Controls.PictureMode.String, "Dynamic")
    T.eq(Controls.Model.String, "Panasonic TH-55EQ3W")
    T.eq(Controls.SerialNumber.String, "ABC123456")
  end)

  T.test("standby is shown and polling slows to power only", function()
    installMocks()
    connect("00QPW:0")
    T.eq(Controls.PowerState.Boolean, false)
    T.eq(Controls.PowerText.String, "Standby")
    local before = #mocks.socket.written
    tick(50) -- 5 seconds
    T.eq(#mocks.socket.written, before, "nothing but power is polled in standby")
  end)

  T.test("button presses are queued, not written directly", function()
    installMocks()
    connect("00QPW:1")
    tick(1)
    T.eq(lastWritten(), "00QMI\r")
    local before = #mocks.socket.written
    Controls.PowerOff.EventHandler(Controls.PowerOff)
    T.eq(#mocks.socket.written, before, "must wait for the in-flight reply")
    feed("00QMI:HM1")
    T.eq(lastWritten(), "00POF\r")
    feed("00POF")
  end)

  T.test("power on sends PON and does not claim success before feedback", function()
    installMocks()
    connect("00QPW:0")
    Controls.PowerOn.EventHandler(Controls.PowerOn)
    T.eq(lastWritten(), "00PON\r")
    T.eq(Controls.PowerState.Boolean, false)
    feed("00PON")
    T.eq(lastWritten(), "00QPW\r")
    T.eq(Controls.PowerState.Boolean, false)
    feed("00QPW:1")
    T.eq(Controls.PowerState.Boolean, true)
    T.eq(Controls.PowerText.String, "On")
  end)

  T.test("input selection sends the model code and re-polls", function()
    installMocks()
    connect("00QPW:1")
    settle()
    Controls.Input.String = "USB"
    T.eq(lastWritten(), "00IMS:UD1\r")
    feed("00IMS:UD1")
    T.eq(lastWritten(), "00QMI\r")
    feed("00QMI:UD1")
    T.eq(Controls.Input.String, "USB")
  end)

  T.test("aspect and picture mode send their codes", function()
    installMocks()
    connect("00QPW:1")
    settle()
    Controls.Aspect.String = "Native"
    T.eq(lastWritten(), "00DAM:NATV\r")
    feed("00DAM:NATV")
    feed("00QAS:NATV")
    Controls.PictureMode.String = "Sports"
    T.eq(lastWritten(), "00VPC:MENSPT\r")
  end)

  T.test("volume sends a zero-padded absolute value and shows the reported value", function()
    installMocks()
    connect("00QPW:1")
    settle()
    Controls.Volume.Value = 40
    T.eq(lastWritten(), "00AVL:040\r")
    feed("00AVL:040")
    T.eq(lastWritten(), "00QAV\r")
    feed("00QAV:040")
    T.eq(Controls.Volume.Value, 40)
  end)

  T.test("a volume drag is coalesced: intermediate values are not sent", function()
    installMocks()
    connect("00QPW:1")
    settle()
    for _, v in ipairs({ 10, 20, 30, 40 }) do Controls.Volume.Value = v end
    T.eq(countWritten("AVL:010"), 1)
    T.eq(countWritten("AVL:020"), 0)
    T.eq(countWritten("AVL:030"), 0)
    feed("00AVL:010")
    T.eq(lastWritten(), "00AVL:040\r")
    feed("00AVL:040")
    feed("00QAV:040")
    T.eq(Controls.Volume.Value, 40)
  end)

  T.test("backlight sends VPC:BLT with three digits", function()
    installMocks()
    connect("00QPW:1")
    settle()
    Controls.Backlight.Value = 35
    T.eq(lastWritten(), "00VPC:BLT035\r")
  end)

  T.test("audio mute sends the explicit state and shows feedback on the LED", function()
    installMocks()
    connect("00QPW:1")
    settle()
    Controls.AudioMute.Boolean = true
    T.eq(lastWritten(), "00AMT:1\r")
    T.eq(Controls.MuteState.Boolean, false, "LED follows feedback, not the request")
    feed("00AMT:1")
    T.eq(lastWritten(), "00QAM\r")
    feed("00QAM:1")
    T.eq(Controls.MuteState.Boolean, true)
    Controls.AudioMute.Boolean = false
    T.eq(lastWritten(), "00AMT:0\r")
  end)

  T.test("feedback updates do not echo back as commands", function()
    installMocks()
    connect("00QPW:1")
    settle({
      QMI = "00QMI:HM3", QAV = "00QAV:070", QAM = "00QAM:1", ["QPC:BLT"] = "00QPC:BLT010",
      QAS = "00QAS:FULL", ["QPC:MEN"] = "00QPC:MENGRH",
    })
    T.eq(Controls.Input.String, "HDMI 3")
    T.eq(Controls.Volume.Value, 70)
    T.eq(Controls.AudioMute.Boolean, true)
    T.eq(Controls.Backlight.Value, 10)
    for _, written in ipairs(mocks.socket.written) do
      for _, bad in ipairs({ "IMS", "AVL", "AMT", "DAM", "VPC", "PON", "POF" }) do
        T.falsy(written:find(bad, 1, true), "unexpected command: " .. written)
      end
    end
  end)

  T.test("a failed mute command reverts the control and reports the display error", function()
    installMocks()
    connect("00QPW:1")
    settle()
    Controls.AudioMute.Boolean = true
    feed("ERR3")
    T.eq(Controls.AudioMute.Boolean, false)
    T.truthy(Controls.LastError.String:find("Display Busy", 1, true))
    T.truthy(Controls.LastError.String:find("ERR3", 1, true))
    T.truthy(Controls.DetailText.String:find("Audio mute failed", 1, true))
  end)

  T.test("a failed volume command snaps the slider back to the reported value", function()
    installMocks()
    connect("00QPW:1")
    settle()
    T.eq(Controls.Volume.Value, 50)
    Controls.Volume.Value = 77
    feed("ERR2")
    T.eq(Controls.Volume.Value, 50)
    T.truthy(Controls.LastError.String:find("Invalid Parameter", 1, true))
  end)

  T.test("every documented display error is normalised", function()
    local expected = {
      ERR1 = "Unsupported Command", ERR2 = "Invalid Parameter", ERR3 = "Display Busy",
      ERR4 = "Command Timeout / Invalid State", ERR5 = "Invalid Frame",
    }
    for code, text in pairs(expected) do
      installMocks()
      connect("00QPW:1")
      settle()
      Controls.Aspect.String = "Zoom"
      feed(code)
      T.truthy(Controls.LastError.String:find(text, 1, true), code)
    end
  end)

  T.test("losing the connection resets feedback and reports status", function()
    installMocks()
    connect("00QPW:1")
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Closed)
    T.eq(Controls.Connected.Boolean, false)
    T.eq(Controls.Status.String, "Disconnected")
    T.eq(Controls.PowerText.String, "Unknown")
    T.eq(Controls.PowerState.Boolean, false)
    tick(40)
    T.eq(sock.connectCalls, 1)
    tick(20)
    T.eq(sock.connectCalls, 2)
  end)

  T.test("silence from the display surfaces a communication error", function()
    installMocks()
    tick(1)
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 0")
    tick(100)
    T.eq(Controls.Status.String, "Communication error")
    T.eq(Controls.Status.Value, 2)
    T.truthy(sock.disconnectCalls >= 1)
  end)

  T.test("command protect without credentials is reported clearly", function()
    installMocks()
    tick(1)
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 2 a1b2c3d4")
    T.eq(Controls.Status.Value, 2)
    T.truthy(Controls.Status.String:find("Username and Password", 1, true))
    T.eq(Controls.Connected.Boolean, false)
  end)

  T.test("command protect with credentials sends the hash on every command", function()
    installMocks({ Username = "admin1", Password = "secret", ["Debug Print"] = "All" })
    tick(1)
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 2 23181e1e")
    T.eq(Controls.Status.String, "OK")
    tick(1)
    T.eq(lastWritten(), HASH .. "00QPW\r")
    feed("00QPW:1")
    -- Neither the password nor the hash may reach the debug output or controls.
    for _, line in ipairs(mocks.printed) do
      T.falsy(line:find("secret", 1, true), line)
      T.falsy(line:find(HASH, 1, true), line)
    end
    T.falsy(Controls.LastCommand.String:find(HASH, 1, true))
  end)

  T.test("wrong credentials (ERRA) show an authentication error", function()
    installMocks({ Username = "admin1", Password = "wrong" })
    tick(1)
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 2 23181e1e")
    tick(1)
    feed("ERRA")
    T.eq(Controls.Status.Value, 2)
    T.truthy(Controls.Status.String:find("Authentication Error", 1, true))
    T.eq(Controls.Connected.Boolean, false)
    T.truthy(sock.disconnectCalls >= 1)
  end)

  T.test("a new connection after a drop is authenticated with a fresh hash", function()
    installMocks({ Username = "admin1", Password = "secret" })
    tick(1)
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 2 23181e1e")
    tick(1)
    T.eq(lastWritten(), HASH .. "00QPW\r")
    sock.EventHandler(sock, TcpSocket.Events.Closed)
    tick(60)
    T.eq(sock.connectCalls, 2)
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 2 deadbeef")
    tick(1)
    local frame = lastWritten()
    T.eq(#frame, 64 + #"00QPW\r")
    T.truthy(frame ~= HASH .. "00QPW\r")
  end)

  T.test("an unset IP address does not start connecting", function()
    installMocks({ ["IP Address"] = "" })
    T.eq(Controls.Status.String, "Set the IP Address property")
    T.eq(mainTimer(), nil)
    T.eq(mocks.socket.connectCalls, 0)
  end)

  T.test("an unrecognised input reply is shown rather than hidden", function()
    installMocks()
    connect("00QPW:1")
    settle({ QMI = "00QMI:ZZ9" })
    T.eq(Controls.Input.String, "ZZ9")
    T.truthy(Controls.DetailText.String:find("Unrecognized input", 1, true))
  end)

  T.test("a model mismatch is flagged", function()
    installMocks({ Model = "TH-43EQ3W" })
    connect("00QPW:1")
    settle({ QID = "00QID:55EQ3W" })
    T.eq(Controls.Model.String, "Panasonic TH-55EQ3W")
    T.truthy(Controls.DetailText.String:find("mismatch", 1, true))
  end)

  T.test("a matching model raises no warning", function()
    installMocks({ Model = "TH-55EQ3W" })
    connect("00QPW:1")
    settle({ QID = "00QID:55EQ3W" })
    T.falsy(Controls.DetailText.String:find("mismatch", 1, true))
  end)

  T.test("model and serial are queried once after connect", function()
    installMocks()
    connect("00QPW:1")
    settle()
    for _ = 1, 700 do tick(1); drain() end
    T.eq(countWritten("QID"), 1)
    T.eq(countWritten("QSN"), 1)
  end)

  T.test("an unparsable reply keeps the last good value and shows the raw reply", function()
    installMocks()
    connect("00QPW:1")
    settle()
    mocks.replies.QAV = "00QAV:999"
    for _ = 1, 100 do tick(1); drain() end
    T.eq(Controls.Volume.Value, 50)
    T.truthy(Controls.DetailText.String:find("QAV:999", 1, true))
  end)

  T.test("the raw command is never retried and shows the reply", function()
    installMocks()
    connect("00QPW:1")
    settle()
    Controls.CustomCommand.String = "QSN"
    Controls.CustomSend.EventHandler(Controls.CustomSend)
    T.eq(lastWritten(), "00QSN\r")
    feed("00QSN:XYZ")
    T.eq(Controls.CustomReply.String, "QSN:XYZ")
  end)

  T.test("queue depth is reported", function()
    installMocks()
    connect("00QPW:1")
    tick(1)
    T.truthy(tonumber(Controls.QueueDepth.String) > 0)
    drain()
    tick(1)
    T.eq(Controls.QueueDepth.String, "0")
  end)

  T.test("debug print is off by default and logs traffic when enabled", function()
    installMocks()
    connect("00QPW:1")
    T.eq(#mocks.printed, 0)
    installMocks({ ["Debug Print"] = "Tx/Rx" })
    connect("00QPW:1")
    T.truthy(#mocks.printed > 0)
  end)

end)

removeMocks()
if not ok then error(runtimeErr, 0) end

return T.finish()
