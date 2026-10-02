-- Runtime wiring: Q-SYS controls <-> engine/poller <-> TCP socket.
--
-- Called once from plugin.lua when `Controls` exists. All display traffic
-- goes through the engine queue; control handlers never write to the socket.
-- Controls show what the display reports, never what was merely requested.
return function()
  local Models = require("models")
  local Protocol = require("protocol")
  local Commands = require("commands")
  local Engine = require("engine")
  local Poller = require("poller")

  local TICK = 0.1

  local configured = Models.Get(Properties["Model"].Value)
  local ip = Properties["IP Address"].Value
  local port = Properties["Port"].Value
  local debugMode = Properties["Debug Print"].Value
  local normalPoll = tonumber(Properties["Normal Poll Interval (s)"].Value) or 2
  local highPoll = tonumber(Properties["High Poll Interval (s)"].Value) or 1
  local highTimeout = tonumber(Properties["High Poll Timeout (s)"].Value) or 30

  local function dbg(kind, message)
    if debugMode == "All" or (debugMode == "Tx/Rx" and (kind == "tx" or kind == "rx")) then
      print(string.format("[Panasonic EQ3 %s] %s", kind, tostring(message)))
    end
  end

  -- -------------------------------------------------------------------------
  -- Control helpers. Programmatic changes also fire EventHandlers, so
  -- feedback writes are wrapped to keep them from being sent back out.
  -- -------------------------------------------------------------------------
  local updating = false

  local function setText(control, value)
    if control.String ~= value then control.String = value end
  end

  local function setFlag(control, value)
    updating = true
    control.Boolean = value
    updating = false
  end

  local function setNumber(control, value)
    updating = true
    control.Value = value
    updating = false
  end

  local function setChoice(control, value)
    updating = true
    control.String = value
    updating = false
  end

  local function detail(message)
    setText(Controls.DetailText, message or "")
  end

  local function setError(code)
    setText(Controls.LastError, string.format("%s (%s)", Protocol.ErrorText(code), code))
  end

  -- A failed request: show a documented display error in LastError, anything
  -- else (timeout, unparsable reply) in Detail.
  local function failed(label, reason, raw)
    if Protocol.Errors[reason] then
      setError(reason)
      detail(label .. " failed: " .. Protocol.ErrorText(reason))
    elseif raw then
      detail(label .. " reply not understood: " .. tostring(raw))
    elseif reason ~= "superseded" then
      detail(label .. " failed: " .. tostring(reason))
    end
  end

  -- -------------------------------------------------------------------------
  -- Engine and socket
  -- -------------------------------------------------------------------------
  local sock = TcpSocket.New()
  sock.ReconnectTimeout = 0 -- reconnects are driven by the engine

  local poller -- assigned below; handlers refer to it
  local known = { mute = false, volume = 0, backlight = 0 }
  -- Slider changes still waiting for a reply; poll results are ignored while
  -- any are outstanding so a drag does not snap back to an older value.
  local pending = { volume = 0, backlight = 0 }

  -- After a command, the affected key is polled at the high rate until the
  -- display reports the expected value or the high-rate timeout passes.
  local waiting = {}

  local function expect(key, test)
    waiting[key] = test
    poller:Boost(key, highTimeout)
    poller:PollNow(key)
  end

  local function settled(key, value)
    local test = waiting[key]
    if test and test(value) then
      waiting[key] = nil
      poller:EndBoost(key)
    end
  end

  local COMM_ERRORS = { ["no response"] = true, ["connect timeout"] = true, ["socket error"] = true, ["no greeting"] = true }

  local function showPowerUnknown()
    setFlag(Controls.PowerState, false)
    setText(Controls.PowerText, "Unknown")
  end

  local function onState(state, why)
    if state == "Ready" then
      Controls.Connected.Boolean = true
      Controls.Status.Value = 0
      Controls.Status.String = "OK"
      detail("")
      Log.Message("Panasonic EQ3 connected: " .. ip)
      return
    end

    Controls.Connected.Boolean = false
    if poller then poller:Reset() end
    showPowerUnknown()

    if state == "Connecting" then
      Controls.Status.Value = 5
      Controls.Status.String = "Connecting..."
    elseif state == "Greeting" then
      Controls.Status.Value = 5
      Controls.Status.String = "Authenticating..."
    elseif state == "AuthError" then
      Controls.Status.Value = 2
      Controls.Status.String = tostring(why or "Authentication error")
      setText(Controls.LastError, tostring(why or "Authentication error"))
      Log.Error("Panasonic EQ3: " .. tostring(why))
    elseif COMM_ERRORS[why] then
      Controls.Status.Value = 2
      Controls.Status.String = "Communication error"
      detail(tostring(why))
    else
      Controls.Status.Value = 4
      Controls.Status.String = "Disconnected"
      detail(why and tostring(why) or "")
    end
  end

  local engine = Engine.New({
    send = function(data) sock:Write(data) end,
    connect = function() sock:Connect(ip, port) end,
    disconnect = function() sock:Disconnect() end,
    log = function(kind, message)
      dbg(kind, message)
      if kind == "tx" then setText(Controls.LastCommand, message) end
      if kind == "rx" then setText(Controls.LastResponse, message) end
    end,
    onState = onState,
  }, {
    Username = Properties["Username"].Value,
    Password = Properties["Password"].Value,
  })

  -- -------------------------------------------------------------------------
  -- Poll feedback
  -- -------------------------------------------------------------------------
  local handlers = {}

  function handlers.power(ok, value, raw)
    if not ok then
      showPowerUnknown()
      poller:SetPower(nil)
      failed("Power", value, raw)
      return
    end
    setFlag(Controls.PowerState, value == "On")
    setText(Controls.PowerText, value)
    poller:SetPower(value)
    settled("power", value)
  end

  -- Enumerated feedback (input, aspect, picture mode): map the code to a
  -- label; an unrecognized code is shown as-is with a note in Detail.
  local function enumHandler(key, controlName, list, label)
    return function(ok, value, raw)
      if not ok then
        failed(label, value, raw)
        return
      end
      local text = Commands.LabelForCode(list, value)
      if text then
        setChoice(Controls[controlName], text)
      else
        setChoice(Controls[controlName], value)
        detail("Unrecognized " .. label:lower() .. " reply: " .. value)
      end
      settled(key, text or value)
    end
  end

  handlers.input = enumHandler("input", "Input", Commands.Inputs, "Input")
  handlers.aspect = enumHandler("aspect", "Aspect", Commands.Aspects, "Aspect")
  handlers.picture = enumHandler("picture", "PictureMode", Commands.PictureModes, "Picture mode")

  local function levelHandler(key, controlName, label)
    return function(ok, value, raw)
      if not ok then
        failed(label, value, raw)
        return
      end
      known[key] = value
      if pending[key] > 0 then return end
      setNumber(Controls[controlName], value)
      settled(key, value)
    end
  end

  handlers.volume = levelHandler("volume", "Volume", "Volume")
  handlers.backlight = levelHandler("backlight", "Backlight", "Backlight")

  function handlers.mute(ok, value, raw)
    if not ok then
      failed("Audio mute", value, raw)
      return
    end
    known.mute = value
    setFlag(Controls.AudioMute, value)
    setFlag(Controls.MuteState, value)
    settled("mute", value)
  end

  -- QID: show what the display says it is, and warn if it is not the model
  -- chosen in Properties.
  function handlers.model(ok, value, raw)
    if not ok then
      failed("Model", value, raw)
      return
    end
    local found = Models.FromQueryId(value)
    setText(Controls.Model, found and found.Name or ("Panasonic " .. value))
    if configured ~= Models.Auto and found ~= configured then
      detail(string.format("Model mismatch: set to %s, display reports %s", configured.Id, value))
    end
  end

  function handlers.serial(ok, value, raw)
    if not ok then
      failed("Serial number", value, raw)
      return
    end
    setText(Controls.SerialNumber, value)
  end

  poller = Poller.New(engine, handlers, {
    NormalInterval = normalPoll,
    HighRateInterval = highPoll,
  })

  -- -------------------------------------------------------------------------
  -- Socket events
  -- -------------------------------------------------------------------------
  sock.EventHandler = function(_, event, err)
    if event == TcpSocket.Events.Connected then
      engine:OnConnected()
    elseif event == TcpSocket.Events.Data then
      local line = sock:ReadLine(TcpSocket.EOL.Custom, "\r")
      while line do
        engine:OnLine(line)
        line = sock:ReadLine(TcpSocket.EOL.Custom, "\r")
      end
    elseif event == TcpSocket.Events.Closed then
      engine:OnClosed("closed")
    elseif event == TcpSocket.Events.Error or event == TcpSocket.Events.Timeout then
      engine:OnClosed("socket error")
    end
  end

  -- -------------------------------------------------------------------------
  -- Control handlers (enqueue only)
  -- -------------------------------------------------------------------------
  -- Coalescing commands (slider drags) use their name as the queue key.
  local function send(name, spec, after)
    engine:Command(spec.coalesce and name or nil, spec, function(ok, reason, raw)
      if not ok then failed(name, reason, nil) end
      if after then after(ok, reason) end
    end)
  end

  Controls.PowerOn.EventHandler = function()
    send("Power on", Commands.PowerOn, function(ok)
      if ok then expect("power", function(v) return v == "On" end) end
    end)
  end
  Controls.PowerOff.EventHandler = function()
    send("Power off", Commands.PowerOff, function(ok)
      if ok then expect("power", function(v) return v == "Standby" end) end
    end)
  end

  local function bindChoice(controlName, key, list, build, label)
    Controls[controlName].Choices = Commands.Labels(list)
    Controls[controlName].EventHandler = function(control)
      if updating then return end
      local wanted = control.String
      local code = Commands.CodeForLabel(list, wanted)
      if not code then
        detail("Unknown " .. label:lower() .. ": " .. tostring(wanted))
        return
      end
      send(label, build(code), function(ok)
        if ok then expect(key, function(v) return v == wanted end) end
      end)
    end
  end

  bindChoice("Input", "input", Commands.Inputs, Commands.Input, "Input")
  bindChoice("Aspect", "aspect", Commands.Aspects, Commands.Aspect, "Aspect")
  bindChoice("PictureMode", "picture", Commands.PictureModes, Commands.PictureMode, "Picture mode")

  local function bindLevel(controlName, key, build, label)
    Controls[controlName].EventHandler = function(control)
      if updating then return end
      local wanted = math.floor((tonumber(control.Value) or 0) + 0.5)
      pending[key] = pending[key] + 1
      send(label, build(wanted), function(ok, reason)
        pending[key] = pending[key] - 1
        if reason == "superseded" then return end
        if ok then
          expect(key, function(v) return v == wanted end)
        elseif pending[key] == 0 then
          setNumber(Controls[controlName], known[key])
        end
      end)
    end
  end

  bindLevel("Volume", "volume", Commands.Volume, "Volume")
  bindLevel("Backlight", "backlight", Commands.Backlight, "Backlight")

  Controls.AudioMute.EventHandler = function(control)
    if updating then return end
    local wanted = control.Boolean
    send("Audio mute", Commands.Mute(wanted), function(ok)
      if ok then
        expect("mute", function(v) return v == wanted end)
      else
        setFlag(Controls.AudioMute, known.mute)
      end
    end)
  end

  Controls.CustomCommand.String = "QPW"
  Controls.CustomReply.String = "Ready"
  Controls.CustomSend.EventHandler = function()
    local command = tostring(Controls.CustomCommand.String or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if command == "" then
      setText(Controls.CustomReply, "Empty")
      return
    end
    -- Not idempotent: an arbitrary command must never be sent twice.
    engine:Command("custom", { line = command, idempotent = false }, function(ok, value, raw)
      if ok then
        setText(Controls.CustomReply, raw or "OK")
      else
        setText(Controls.CustomReply, tostring(raw or value or "Failed"))
      end
    end)
  end

  -- -------------------------------------------------------------------------
  -- Static info and start-up
  -- -------------------------------------------------------------------------
  Controls.Model.String = configured.Name
  Controls.IPAddress.String = tostring(ip) .. ":" .. tostring(port)
  Controls.Connected.Boolean = false
  Controls.QueueDepth.String = "0"
  showPowerUnknown()

  local clock = 0
  local lastDepth = 0
  local ticker = Timer.New()
  ticker.EventHandler = function()
    clock = clock + TICK
    engine:Tick(clock)
    poller:Tick(clock)
    local depth = engine:QueueDepth()
    if depth ~= lastDepth then
      lastDepth = depth
      setText(Controls.QueueDepth, tostring(depth))
    end
  end

  if ip == nil or ip == "" or ip == "0.0.0.0" then
    Controls.Status.Value = 2
    Controls.Status.String = "Set the IP Address property"
    return
  end

  Controls.Status.Value = 4
  Controls.Status.String = "Disconnected"
  engine:Start(clock)
  ticker:Start(TICK)
end
