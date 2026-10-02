local T = require("helpers")
local Protocol = require("protocol")
local Commands = require("commands")
local Models = require("models")

-- ---------------------------------------------------------------------------
-- Framing
-- ---------------------------------------------------------------------------
T.test("frame without command protect is 00<command>CR", function()
  T.eq(Protocol.Frame("", "PON"), "00PON\r")
  T.eq(Protocol.Frame(nil, "QPW"), "00QPW\r")
end)

T.test("frame with a hash is <hash>00<command>CR", function()
  local hash = string.rep("a", 64)
  T.eq(Protocol.Frame(hash, "PON"), hash .. "00PON\r")
end)

T.test("unframe strips the terminator and the 00 success marker", function()
  T.eq(Protocol.Unframe("00QPW:1\r"), "QPW:1")
  T.eq(Protocol.Unframe("00PON"), "PON")
  T.eq(Protocol.Unframe("ERR3\r"), "ERR3")
  T.eq(Protocol.Unframe("NTCONTROL 2 abcdef12\r"), "NTCONTROL 2 abcdef12")
end)

-- ---------------------------------------------------------------------------
-- Greeting and authentication
-- ---------------------------------------------------------------------------
T.test("greeting parses mode and challenge", function()
  local g = Protocol.ParseGreeting("NTCONTROL 2 abcdef12")
  T.eq(g.mode, 2)
  T.eq(g.challenge, "abcdef12")
  g = Protocol.ParseGreeting("NTCONTROL 1 23181e1e")
  T.eq(g.mode, 1)
  g = Protocol.ParseGreeting("NTCONTROL 0")
  T.eq(g.mode, 0)
  T.eq(g.challenge, nil)
  T.eq(Protocol.ParseGreeting("QPW:1"), nil)
end)

T.test("auth hash is SHA-256 for mode 2 and MD5 for mode 1 of user:password:challenge", function()
  T.eq(Protocol.AuthHash(2, "admin1", "secret", "23181e1e"),
    "aade6e0a88ae17960064dd516cd835af889f2882072741cf08b89d900f13f41f")
  T.eq(Protocol.AuthHash(1, "admin1", "secret", "23181e1e"), "980a8884e5b88829f9df782f2cdde066")
end)

T.test("auth hash refuses a missing challenge or unknown mode", function()
  local hash, why = Protocol.AuthHash(2, "u", "p", nil)
  T.eq(hash, nil)
  T.truthy(why)
  hash, why = Protocol.AuthHash(9, "u", "p", "abcdef12")
  T.eq(hash, nil)
  T.truthy(why:find("unsupported", 1, true))
end)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------
T.test("every documented error code is recognised and normalised", function()
  local expected = {
    ERR1 = "Unsupported Command", ERR2 = "Invalid Parameter", ERR3 = "Display Busy",
    ERR4 = "Command Timeout / Invalid State", ERR5 = "Invalid Frame", ERRA = "Authentication Error",
  }
  for code, text in pairs(expected) do
    T.eq(Protocol.ErrorCode(code), code)
    T.eq(Protocol.ErrorText(code), text)
  end
  T.eq(Protocol.ErrorCode("QPW:1"), nil)
  T.eq(Protocol.ErrorCode("ERRORS"), nil)
  T.eq(Protocol.ErrorText("ERRZ"), "Unknown Error")
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
T.test("fixed commands", function()
  T.eq(Commands.PowerOn.line, "PON")
  T.eq(Commands.PowerOff.line, "POF")
  T.eq(Commands.Input("HM2").line, "IMS:HM2")
  T.eq(Commands.Mute(true).line, "AMT:1")
  T.eq(Commands.Mute(false).line, "AMT:0")
  T.eq(Commands.Aspect("NATV").line, "DAM:NATV")
  T.eq(Commands.PictureMode("STD").line, "VPC:MENSTD")
end)

T.test("volume and backlight are zero-padded to three digits and clamped", function()
  T.eq(Commands.Volume(0).line, "AVL:000")
  T.eq(Commands.Volume(25).line, "AVL:025")
  T.eq(Commands.Volume(100).line, "AVL:100")
  T.eq(Commands.Volume(150).line, "AVL:100")
  T.eq(Commands.Volume(-5).line, "AVL:000")
  T.eq(Commands.Volume(49.6).line, "AVL:050")
  T.eq(Commands.Backlight(35).line, "VPC:BLT035")
  T.eq(Commands.Backlight(50).line, "VPC:BLT050")
  T.eq(Commands.Backlight(99).line, "VPC:BLT050")
  T.truthy(Commands.Volume(1).coalesce)
  T.truthy(Commands.Backlight(1).coalesce)
end)

T.test("input, aspect and picture mode lists match the command reference", function()
  local codes = {}
  for _, i in ipairs(Commands.Inputs) do codes[#codes + 1] = i.Code end
  T.eq(table.concat(codes, ","), "HM1,HM2,HM3,PC1,UD1")
  codes = {}
  for _, i in ipairs(Commands.Aspects) do codes[#codes + 1] = i.Code end
  T.eq(table.concat(codes, ","), "FULL,NORM,NATV,ZOOM")
  codes = {}
  for _, i in ipairs(Commands.PictureModes) do codes[#codes + 1] = i.Code end
  T.eq(table.concat(codes, ","), "DYN,GRH,SPT,STD")
end)

local Q = Commands.Queries

T.test("query lines", function()
  T.eq(Q.power.line, "QPW")
  T.eq(Q.input.line, "QMI")
  T.eq(Q.volume.line, "QAV")
  T.eq(Q.mute.line, "QAM")
  T.eq(Q.aspect.line, "QAS")
  T.eq(Q.picture.line, "QPC:MEN")
  T.eq(Q.backlight.line, "QPC:BLT")
  T.eq(Q.model.line, "QID")
  T.eq(Q.serial.line, "QSN")
end)

T.test("query parsers decode documented replies", function()
  T.eq(Q.power.parse("QPW:1"), "On")
  T.eq(Q.power.parse("QPW:0"), "Standby")
  T.eq(Q.input.parse("QMI:PC1"), "PC1")
  T.eq(Q.volume.parse("QAV:050"), 50)
  T.eq(Q.volume.parse("QAV:100"), 100)
  T.eq(Q.mute.parse("QAM:1"), true)
  T.eq(Q.mute.parse("QAM:0"), false)
  T.eq(Q.aspect.parse("QAS:NATV"), "NATV")
  T.eq(Q.picture.parse("QPC:MENDYN"), "DYN")
  T.eq(Q.backlight.parse("QPC:BLT035"), 35)
  T.eq(Q.model.parse("QID:55EQ3W"), "55EQ3W")
  T.eq(Q.serial.parse("QSN:ABC123456"), "ABC123456")
end)

T.test("query parsers reject malformed and out-of-range replies", function()
  T.eq(Q.power.parse("QPW:2"), nil)
  T.eq(Q.power.parse("garbage"), nil)
  T.eq(Q.volume.parse("QAV:101"), nil)
  T.eq(Q.volume.parse("QAV:5"), nil)
  T.eq(Q.backlight.parse("QPC:BLT051"), nil)
  T.eq(Q.mute.parse("QAM:"), nil)
  T.eq(Q.picture.parse("QPC:BLT035"), nil)
  T.eq(Q.backlight.parse("QPC:MENDYN"), nil)
end)

-- ---------------------------------------------------------------------------
-- Models
-- ---------------------------------------------------------------------------
T.test("QID replies map to models", function()
  T.eq(Models.FromQueryId("43EQ3W").Id, "TH-43EQ3W")
  T.eq(Models.FromQueryId("55EQ3W").Id, "TH-55EQ3W")
  T.eq(Models.FromQueryId("TH-55EQ3W").Id, "TH-55EQ3W")
  T.eq(Models.FromQueryId("65EQ3W"), nil)
end)

T.test("Auto is the default and Get never returns nil", function()
  T.eq(Models.Default, "Auto")
  T.eq(Models.Get("Auto").Id, "Auto")
  T.eq(Models.Get("nonsense").Id, "Auto")
  T.eq(Models.Get("TH-43EQ3W").SizeInches, 43)
end)

return T.finish()
