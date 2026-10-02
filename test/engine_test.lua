local T = require("helpers")
local Engine = require("engine")
local Protocol = require("protocol")

local HASH = Protocol.AuthHash(2, "admin1", "secret", "23181e1e")

-- Builds an engine with recording dependencies.
local function setup(options)
  local ctx = { sent = {}, connects = 0, disconnects = 0, states = {}, logs = {} }
  ctx.engine = Engine.New({
    send = function(data) ctx.sent[#ctx.sent + 1] = data end,
    connect = function() ctx.connects = ctx.connects + 1 end,
    disconnect = function() ctx.disconnects = ctx.disconnects + 1 end,
    log = function(kind, message) ctx.logs[#ctx.logs + 1] = kind .. ":" .. tostring(message) end,
    onState = function(state, detail) ctx.states[#ctx.states + 1] = state .. (detail and (":" .. detail) or "") end,
  }, options)
  return ctx
end

-- Drives the engine to Ready at time 0 against a display with command protect off.
local function ready(options)
  local ctx = setup(options)
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 0\r")
  return ctx
end

local power = { line = "QPW", parse = function(t) if t == "QPW:1" then return "On" end end }
local mute = { line = "QAM", parse = function(t) if t == "QAM:0" then return false end end }

T.test("connect, greeting, ready", function()
  local ctx = setup()
  ctx.engine:Start(0)
  T.eq(ctx.engine.state, "Disconnected")
  ctx.engine:Tick(0)
  T.eq(ctx.connects, 1)
  T.eq(ctx.engine.state, "Connecting")
  ctx.engine:OnConnected()
  T.eq(ctx.engine.state, "Greeting")
  ctx.engine:OnLine("NTCONTROL 0\r")
  T.eq(ctx.engine.state, "Ready")
end)

T.test("a display that never greets is dropped and retried", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:Tick(1.9)
  T.eq(ctx.engine.state, "Greeting")
  ctx.engine:Tick(2.0)
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.disconnects, 1)
  T.eq(ctx.states[#ctx.states], "Disconnected:no greeting")
end)

T.test("requests are rejected when not Ready", function()
  local ctx = setup()
  local result
  local queued = ctx.engine:Query("power", power, function(ok, reason) result = { ok, reason } end)
  T.falsy(queued)
  T.eq(result[1], false)
  T.eq(result[2], "not connected")
  T.eq(#ctx.sent, 0)
end)

T.test("with command protect off, frames carry no hash", function()
  local ctx = ready()
  ctx.engine:Query("power", power)
  T.eq(ctx.sent[1], "00QPW\r")
end)

T.test("a SHA-256 greeting hashes username:password:challenge into every frame", function()
  local ctx = setup({ Username = "admin1", Password = "secret" })
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 2 23181e1e\r")
  T.eq(ctx.engine.state, "Ready")
  ctx.engine:Command(nil, { line = "PON" })
  T.eq(ctx.sent[1], HASH .. "00PON\r")
  ctx.engine:OnLine("00PON")
  ctx.engine:Query("power", power)
  T.eq(ctx.sent[2], HASH .. "00QPW\r")
end)

T.test("an MD5 greeting uses MD5", function()
  local ctx = setup({ Username = "admin1", Password = "secret" })
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 1 23181e1e")
  ctx.engine:Command(nil, { line = "PON" })
  T.eq(ctx.sent[1], "980a8884e5b88829f9df782f2cdde066" .. "00PON\r")
end)

T.test("each connection derives a fresh hash from its own challenge", function()
  local ctx = setup({ Username = "admin1", Password = "secret" })
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 2 23181e1e")
  ctx.engine:Command(nil, { line = "PON" })
  ctx.engine:OnClosed("closed")
  T.eq(ctx.engine.prefix, "", "hash must be cleared on disconnect")
  ctx.engine:Tick(5)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 2 deadbeef")
  ctx.engine:Command(nil, { line = "PON" })
  local second = ctx.sent[#ctx.sent]
  T.eq(second, Protocol.AuthHash(2, "admin1", "secret", "deadbeef") .. "00PON\r")
  T.truthy(second ~= HASH .. "00PON\r")
end)

T.test("command protect without credentials is an authentication error", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 2 23181e1e")
  T.eq(ctx.engine.state, "AuthError")
  T.truthy(ctx.states[#ctx.states]:find("Username and Password", 1, true))
  T.eq(ctx.disconnects, 1)
  ctx.engine:Tick(59.9)
  T.eq(ctx.connects, 1)
  ctx.engine:Tick(60.0)
  T.eq(ctx.connects, 2)
end)

T.test("ERRA from the display is an authentication error and drops the connection", function()
  local ctx = setup({ Username = "admin1", Password = "wrong" })
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 2 23181e1e")
  local got
  ctx.engine:Query("power", power, function(ok, value) got = { ok, value } end)
  ctx.engine:OnLine("ERRA")
  T.eq(got[1], false)
  T.eq(got[2], "ERRA")
  T.eq(ctx.engine.state, "AuthError")
  T.eq(ctx.disconnects, 1)
end)

T.test("credentials never appear in the log", function()
  local ctx = setup({ Username = "admin1", Password = "secret" })
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 2 23181e1e")
  ctx.engine:Command(nil, { line = "PON" })
  ctx.engine:OnLine("00PON")
  for _, line in ipairs(ctx.logs) do
    T.falsy(line:find("secret", 1, true), line)
    T.falsy(line:find(HASH, 1, true), line)
  end
end)

T.test("only one request is in flight; the next goes out on the reply", function()
  local ctx = ready()
  local results = {}
  ctx.engine:Query("power", power, function(ok, v) results[#results + 1] = "power:" .. tostring(v) end)
  ctx.engine:Query("mute", mute, function(ok, v) results[#results + 1] = "mute:" .. tostring(v) end)
  T.eq(#ctx.sent, 1)
  T.eq(ctx.sent[1], "00QPW\r")
  ctx.engine:OnLine("00QPW:1\r")
  T.eq(#ctx.sent, 2)
  T.eq(ctx.sent[2], "00QAM\r")
  ctx.engine:OnLine("00QAM:0\r")
  T.eq(results[1], "power:On")
  T.eq(results[2], "mute:false")
end)

T.test("commands jump ahead of queued queries but keep their own order", function()
  local ctx = ready()
  ctx.engine:Query("power", power)
  ctx.engine:Query("mute", mute)
  ctx.engine:Command(nil, { line = "IMS:HM1" })
  ctx.engine:Command(nil, { line = "IMS:HM2" })
  T.eq(ctx.sent[1], "00QPW\r")
  ctx.engine:OnLine("00QPW:1")
  T.eq(ctx.sent[2], "00IMS:HM1\r")
  ctx.engine:OnLine("00IMS:HM1")
  T.eq(ctx.sent[3], "00IMS:HM2\r")
  ctx.engine:OnLine("00IMS:HM2")
  T.eq(ctx.sent[4], "00QAM\r")
end)

T.test("a keyed request is dropped while one with the same key is pending", function()
  local ctx = ready()
  T.truthy(ctx.engine:Query("power", power))
  T.falsy(ctx.engine:Query("power", power))
  ctx.engine:Query("mute", mute)
  T.falsy(ctx.engine:Query("mute", mute))
  T.eq(#ctx.sent, 1)
end)

T.test("a coalescing command replaces a queued one and supersedes its callback", function()
  local ctx = ready()
  ctx.engine:Query("power", power) -- in flight, so the volumes below queue
  local results = {}
  local function cb(name) return function(ok, value) results[#results + 1] = name .. ":" .. tostring(ok) .. ":" .. tostring(value) end end
  ctx.engine:Command("volume", { line = "AVL:010", coalesce = true }, cb("a"))
  ctx.engine:Command("volume", { line = "AVL:020", coalesce = true }, cb("b"))
  ctx.engine:Command("volume", { line = "AVL:030", coalesce = true }, cb("c"))
  T.eq(#ctx.engine.queue, 1)
  T.eq(results[1], "a:false:superseded")
  T.eq(results[2], "b:false:superseded")
  ctx.engine:OnLine("00QPW:1")
  T.eq(ctx.sent[2], "00AVL:030\r")
  ctx.engine:OnLine("00AVL:030")
  T.eq(results[3], "c:true:nil")
end)

T.test("a coalescing command is queued normally while the previous one is in flight", function()
  local ctx = ready()
  ctx.engine:Command("volume", { line = "AVL:010", coalesce = true })
  ctx.engine:Command("volume", { line = "AVL:020", coalesce = true })
  T.eq(ctx.sent[1], "00AVL:010\r")
  T.eq(#ctx.engine.queue, 1)
  ctx.engine:OnLine("00AVL:010")
  T.eq(ctx.sent[2], "00AVL:020\r")
end)

T.test("a reply that does not parse fails the request but not the link", function()
  local ctx = ready()
  local got
  ctx.engine:Query("power", power, function(ok, value, raw) got = { ok, value, raw } end)
  ctx.engine:OnLine("garbage")
  T.eq(got[1], false)
  T.eq(got[2], "unexpected reply")
  T.eq(got[3], "garbage")
  T.eq(ctx.engine.state, "Ready")
end)

T.test("display error replies fail the request with the code", function()
  for _, code in ipairs({ "ERR1", "ERR2", "ERR3", "ERR4", "ERR5" }) do
    local ctx = ready()
    local got
    ctx.engine:Command(nil, { line = "PON" }, function(ok, value, raw) got = { ok, value, raw } end)
    ctx.engine:OnLine(code)
    T.eq(got[1], false)
    T.eq(got[2], code)
    T.eq(got[3], code)
    T.eq(ctx.engine.failures, 0)
    T.eq(ctx.engine.state, "Ready", code .. " must not drop the link")
  end
end)

T.test("a command with no parser succeeds on any non-error reply", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, { line = "PON" }, function(ok) got = ok end)
  ctx.engine:OnLine("00PON")
  T.eq(got, true)
end)

T.test("a timed-out query is retried once, then fails", function()
  local ctx = ready()
  local got
  ctx.engine:Query("power", power, function(ok, reason) got = { ok, reason } end)
  T.eq(#ctx.sent, 1)
  ctx.engine:Tick(1.9)
  T.eq(#ctx.sent, 1)
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 2)
  T.eq(got, nil)
  ctx.engine:Tick(4.0)
  T.eq(got[1], false)
  T.eq(got[2], "timeout")
  T.eq(ctx.engine.state, "Ready")
end)

T.test("a timed-out non-idempotent command is not resent", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, { line = "AMT" }, function(ok, reason) got = { ok, reason } end)
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 1)
  T.eq(got[2], "timeout")
end)

T.test("an idempotent command is retried once", function()
  local ctx = ready()
  ctx.engine:Command(nil, { line = "PON", idempotent = true })
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 2)
  T.eq(ctx.sent[2], "00PON\r")
end)

T.test("repeated timeouts drop the connection and reconnect after the delay", function()
  local ctx = ready()
  local function cb() end
  ctx.engine:Query("power", power, cb)   -- timeout 1 at t=2, retried
  ctx.engine:Tick(2.0)
  ctx.engine:Tick(4.0)                   -- timeout 2, fails
  ctx.engine:Query("mute", mute, cb)
  ctx.engine:Tick(6.0)                   -- timeout 3 -> drop
  T.eq(ctx.disconnects, 1)
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.states[#ctx.states], "Disconnected:no response")
  ctx.engine:Tick(10.9)
  T.eq(ctx.connects, 1, "must wait the reconnect delay")
  ctx.engine:Tick(11.0)
  T.eq(ctx.connects, 2)
  T.eq(ctx.engine.state, "Connecting")
end)

T.test("reconnect delay doubles up to the cap and resets after a reply", function()
  local ctx = setup()
  ctx.engine:Start(0)
  local delays, now = {}, 0
  for _ = 1, 6 do
    ctx.engine:Tick(now)
    T.eq(ctx.engine.state, "Connecting")
    ctx.engine:OnClosed("socket error")
    delays[#delays + 1] = ctx.engine.nextConnectAt - now
    now = ctx.engine.nextConnectAt
  end
  T.eq(delays[1], 5)
  T.eq(delays[2], 10)
  T.eq(delays[3], 20)
  T.eq(delays[4], 30)
  T.eq(delays[5], 30)
  T.eq(delays[6], 30)

  ctx.engine:Tick(now)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 0")
  ctx.engine:Query("power", power)
  ctx.engine:OnLine("00QPW:1")
  local t = now + 1
  ctx.engine:Tick(t)
  ctx.engine:OnClosed("closed")
  T.eq(ctx.engine.nextConnectAt - t, 5)
end)

T.test("a connect that never completes is abandoned", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:Tick(9.9)
  T.eq(ctx.engine.state, "Connecting")
  ctx.engine:Tick(10.0)
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.disconnects, 1)
  T.eq(ctx.engine.nextConnectAt, 15)
end)

T.test("a socket close fails the in-flight and queued requests", function()
  local ctx = ready()
  local reasons = {}
  local function cb(ok, reason) reasons[#reasons + 1] = tostring(ok) .. ":" .. tostring(reason) end
  ctx.engine:Query("power", power, cb)
  ctx.engine:Query("mute", mute, cb)
  ctx.engine:OnClosed("closed")
  T.eq(#reasons, 2)
  T.eq(reasons[1], "false:closed")
  T.eq(ctx.engine.state, "Disconnected")
end)

T.test("a duplicate close event does not push the reconnect out further", function()
  local ctx = ready()
  ctx.engine:Tick(1)
  ctx.engine:OnClosed("closed")
  local first = ctx.engine.nextConnectAt
  ctx.engine:OnClosed("closed")
  T.eq(ctx.engine.nextConnectAt, first)
end)

T.test("Stop disconnects and does not reconnect", function()
  local ctx = ready()
  ctx.engine:Stop()
  T.eq(ctx.disconnects, 1)
  ctx.engine:Tick(100)
  T.eq(ctx.connects, 1)
end)

T.test("unsolicited replies are ignored", function()
  local ctx = ready()
  ctx.engine:OnLine("00QPW:1")
  T.eq(ctx.engine.state, "Ready")
  T.eq(#ctx.sent, 0)
end)

T.test("the queue is bounded", function()
  local ctx = ready({ MaxQueue = 2 })
  local full
  ctx.engine:Command(nil, { line = "A" })               -- in flight
  ctx.engine:Command(nil, { line = "B" })
  ctx.engine:Command(nil, { line = "C" })
  ctx.engine:Command(nil, { line = "D" }, function(ok, reason) full = reason end)
  T.eq(full, "queue full")
end)

T.test("QueueDepth counts the in-flight request", function()
  local ctx = ready()
  T.eq(ctx.engine:QueueDepth(), 0)
  ctx.engine:Command(nil, { line = "A" })
  ctx.engine:Command(nil, { line = "B" })
  T.eq(ctx.engine:QueueDepth(), 2)
end)

return T.finish()
