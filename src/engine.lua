-- Transport state machine with a serialized command queue.
--
-- The engine is transport-agnostic. It is driven by:
--   Tick(now)            called periodically (seconds, monotonic)
--   OnConnected()        socket connected
--   OnLine(text)         one received line
--   OnClosed(reason)     socket closed or errored
-- and talks to the outside through deps:
--   send(string), connect(), disconnect(), log(kind, msg), onState(state, detail)
--
-- States: Disconnected, Connecting, Greeting, Ready, AuthError.
--
-- The display greets every connection with "NTCONTROL <mode> <challenge>".
-- Mode 0 means command protect is off and frames carry no hash. Modes 1 / 2
-- need Username and Password (options); the hash is derived once per
-- connection and thrown away when the connection closes.
--
-- Only one request is ever in flight. UI commands go ahead of queued polls.
local Protocol = require("protocol")

local Engine = {}
Engine.__index = Engine

Engine.Defaults = {
  ResponseTimeout = 2.0, -- seconds to wait for a reply
  GreetingTimeout = 2.0, -- seconds to wait for NTCONTROL after connecting
  ConnectTimeout = 10.0, -- seconds to wait for the socket to connect
  MaxFailures = 3,       -- consecutive timeouts before reconnecting
  MaxQueue = 50,
  ReconnectMin = 5.0,    -- first reconnect delay; doubles up to ReconnectMax
  ReconnectMax = 30.0,
  AuthRetry = 60.0,      -- delay before retrying after an authentication error
  Username = "",
  Password = "",
}

function Engine.New(deps, options)
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.opt = {}
  for k, v in pairs(Engine.Defaults) do self.opt[k] = v end
  for k, v in pairs(options or {}) do self.opt[k] = v end
  self.state = "Disconnected"
  self.queue = {}
  self.inflight = nil
  self.failures = 0
  self.now = 0
  self.nextConnectAt = 0
  self.backoff = self.opt.ReconnectMin
  self.enabled = false
  self.session = false
  self.prefix = ""
  return self
end

function Engine:_log(kind, message)
  if self.deps.log then self.deps.log(kind, message) end
end

function Engine:_setState(state, detail)
  self.state = state
  self.detail = detail
  if self.deps.onState then self.deps.onState(state, detail) end
end

function Engine:IsReady()
  return self.state == "Ready"
end

function Engine:QueueDepth()
  return #self.queue + (self.inflight and 1 or 0)
end

function Engine:Start(now)
  self.enabled = true
  self.now = now or self.now
  self.nextConnectAt = self.now
end

function Engine:Stop()
  self.enabled = false
  if self.session then
    self.deps.disconnect()
    self:_closed("stopped")
  end
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------
function Engine:_resolve(req, ok, value, raw)
  if req.callback then req.callback(ok, value, raw) end
end

function Engine:_failAll(reason)
  local pending = {}
  if self.inflight then
    pending[#pending + 1] = self.inflight
    self.inflight = nil
  end
  for _, req in ipairs(self.queue) do pending[#pending + 1] = req end
  self.queue = {}
  for _, req in ipairs(pending) do self:_resolve(req, false, reason) end
end

function Engine:_enqueue(req)
  if self.state ~= "Ready" then
    self:_resolve(req, false, "not connected")
    return false
  end
  if req.key then
    if req.coalesce then
      -- A newer value replaces one still waiting in the queue. The replaced
      -- request is resolved as "superseded" so callers can keep their books.
      for _, queued in ipairs(self.queue) do
        if queued.key == req.key then
          local old = queued.callback
          queued.line = req.line
          queued.callback = req.callback
          if old then old(false, "superseded") end
          return true
        end
      end
    else
      -- A request with a key is dropped if one with the same key is pending.
      if self.inflight and self.inflight.key == req.key then return false end
      for _, queued in ipairs(self.queue) do
        if queued.key == req.key then return false end
      end
    end
  end
  if #self.queue >= self.opt.MaxQueue then
    self:_resolve(req, false, "queue full")
    return false
  end
  if req.kind == "command" then
    -- Commands go after earlier commands but ahead of queued queries.
    local pos = 1
    while pos <= #self.queue and self.queue[pos].kind == "command" do pos = pos + 1 end
    table.insert(self.queue, pos, req)
  else
    self.queue[#self.queue + 1] = req
  end
  self:_dispatch()
  return true
end

-- spec: { line = "PON", idempotent = true, coalesce = false }
-- callback(ok, value, raw): ok=false carries a reason string in `value`.
function Engine:Command(key, spec, callback)
  return self:_enqueue({
    key = key,
    line = spec.line,
    kind = "command",
    retries = spec.idempotent and 1 or 0,
    coalesce = spec.coalesce,
    callback = callback,
  })
end

-- spec: { line = "QPW", parse = function(text) -> value|nil }
function Engine:Query(key, spec, callback)
  return self:_enqueue({
    key = key,
    line = spec.line,
    parse = spec.parse,
    kind = "query",
    retries = 1,
    callback = callback,
  })
end

function Engine:_dispatch()
  if self.state ~= "Ready" or self.inflight then return end
  local req = table.remove(self.queue, 1)
  if not req then return end
  req.attempts = (req.attempts or 0) + 1
  req.sentAt = self.now
  self.inflight = req
  self:_log("tx", req.line)
  self.deps.send(Protocol.Frame(self.prefix, req.line))
end

function Engine:_checkTimeout()
  local req = self.inflight
  if not req or self.now - req.sentAt < self.opt.ResponseTimeout then return end
  self.inflight = nil
  self.failures = self.failures + 1
  self:_log("warn", "timeout waiting for " .. req.line)
  if self.failures >= self.opt.MaxFailures then
    self:_resolve(req, false, "timeout")
    self.deps.disconnect()
    self:_closed("no response")
    return
  end
  if req.attempts <= req.retries then
    table.insert(self.queue, 1, req)
  else
    self:_resolve(req, false, "timeout")
  end
  self:_dispatch()
end

-- ---------------------------------------------------------------------------
-- Connection lifecycle
-- ---------------------------------------------------------------------------
function Engine:_closed(reason)
  if not self.session then return end
  self.session = false
  self.prefix = "" -- the hash is only valid for the connection it was made for
  if self.state ~= "AuthError" then
    self:_setState("Disconnected", reason)
  end
  self:_failAll(reason)
  self.failures = 0
  self.nextConnectAt = self.now + self.backoff
  self:_log("info", string.format("reconnect in %.0fs (%s)", self.backoff, tostring(reason)))
  self.backoff = math.min(self.backoff * 2, self.opt.ReconnectMax)
end

function Engine:_ready()
  self:_setState("Ready")
  self:_dispatch()
end

function Engine:_authError(message)
  self:_log("warn", message)
  self.backoff = self.opt.AuthRetry
  self:_setState("AuthError", message)
  self.deps.disconnect()
  self:_closed("auth error")
end

-- Uses whatever the display announced; nothing needs configuring unless the
-- display has command protect turned on.
function Engine:_authenticate(greeting)
  if greeting.mode == 0 then
    self.prefix = ""
    self:_ready()
    return
  end
  local username, password = self.opt.Username or "", self.opt.Password or ""
  if username == "" or password == "" then
    self:_authError("Command protect is on: set Username and Password")
    return
  end
  local hash, why = Protocol.AuthHash(greeting.mode, username, password, greeting.challenge)
  if not hash then
    self:_authError("Authentication failed: " .. tostring(why))
    return
  end
  self.prefix = hash
  self:_ready()
end

function Engine:OnConnected()
  self.session = true
  self.failures = 0
  self.greetingDeadline = self.now + self.opt.GreetingTimeout
  self:_setState("Greeting")
end

function Engine:OnClosed(reason)
  self:_closed(reason or "closed")
end

function Engine:Tick(now)
  self.now = now
  local state = self.state
  if state == "Disconnected" or state == "AuthError" then
    if self.enabled and now >= self.nextConnectAt then
      self.session = true
      self.connectDeadline = now + self.opt.ConnectTimeout
      self:_setState("Connecting")
      self.deps.connect()
    end
  elseif state == "Connecting" then
    if now >= self.connectDeadline then
      self.deps.disconnect()
      self:_closed("connect timeout")
    end
  elseif state == "Greeting" then
    if now >= self.greetingDeadline then
      self.deps.disconnect()
      self:_closed("no greeting")
    end
  elseif state == "Ready" then
    self:_checkTimeout()
    self:_dispatch()
  end
end

-- ---------------------------------------------------------------------------
-- Receive path
-- ---------------------------------------------------------------------------
function Engine:OnLine(raw)
  local text = Protocol.Unframe(raw)
  if text == "" then return end
  self:_log("rx", text)

  local greeting = Protocol.ParseGreeting(text)
  if greeting then
    if self.state == "Greeting" then self:_authenticate(greeting) end
    return
  end

  local req = self.inflight
  if not req then
    self:_log("warn", "unsolicited reply: " .. text)
    return
  end
  self.inflight = nil

  -- Any reply, even an error, proves the link works.
  self.failures = 0
  self.backoff = self.opt.ReconnectMin

  local errorCode = Protocol.ErrorCode(text)
  if errorCode then
    self:_resolve(req, false, errorCode, text)
    if errorCode == "ERRA" then
      self:_authError("Authentication Error: check Username and Password")
      return
    end
  elseif req.parse then
    local value = req.parse(text)
    if value == nil then
      self:_resolve(req, false, "unexpected reply", text)
    else
      self:_resolve(req, true, value, text)
    end
  else
    self:_resolve(req, true, nil, text)
  end
  self:_dispatch()
end

return Engine
