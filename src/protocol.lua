-- Panasonic native LAN protocol: framing, authentication and error codes.
--
-- Wire format (from the EQ3 operating instructions):
--   display  -> NTCONTROL <mode> <8-character challenge>\r
--   plugin   -> <hash>00<command>\r
--   display  -> 00<reply>\r      success
--   display  -> ERR1 ... ERRA    error
-- <hash> is MD5 (mode 1, 32 hex) or SHA-256 (mode 2, 64 hex) of
-- "username:password:challenge". Mode 0 (command protect off) is framed
-- without a hash: 00<command>\r.
--
-- Everything that touches the wire goes through this module, so command
-- handlers never deal with authentication or framing. The authentication
-- source string and the hash are never logged.
local Hash = require("hash")

local Protocol = {}

Protocol.Framing = {
  Prefix = "00",
  Terminator = "\r",
}

Protocol.AuthModes = {
  [0] = "None",
  [1] = "MD5",
  [2] = "SHA-256",
}

-- `prefix` is the per-connection hash ("" when command protect is off).
function Protocol.Frame(prefix, command)
  return (prefix or "") .. Protocol.Framing.Prefix .. command .. Protocol.Framing.Terminator
end

-- Strips the line terminator and the leading "00" success marker.
function Protocol.Unframe(line)
  local text = tostring(line):gsub("[\r\n]+$", "")
  local body = text:match("^00(.*)$")
  return body or text
end

-- Returns { mode = <number>, challenge = <string or nil> }, or nil if the
-- text is not an NTCONTROL greeting.
function Protocol.ParseGreeting(text)
  local mode, challenge = text:match("^NTCONTROL%s+(%d+)%s*(%S*)")
  if not mode then return nil end
  return { mode = tonumber(mode), challenge = (challenge ~= "") and challenge or nil }
end

-- Returns the hex hash for the greeting's mode, or nil and a reason.
function Protocol.AuthHash(mode, username, password, challenge)
  if not challenge or challenge == "" then return nil, "greeting has no challenge" end
  local source = username .. ":" .. password .. ":" .. challenge
  if mode == 2 then return Hash.sha256(source) end
  if mode == 1 then return Hash.md5(source) end
  return nil, "unsupported authentication mode " .. tostring(mode)
end

-- Native protocol errors. Note that nothing else a display sends begins "ERR".
Protocol.Errors = {
  ERR1 = "Unsupported Command",
  ERR2 = "Invalid Parameter",
  ERR3 = "Display Busy",
  ERR4 = "Command Timeout / Invalid State",
  ERR5 = "Invalid Frame",
  ERRA = "Authentication Error",
}

-- Returns "ERR1".."ERR5" / "ERRA" (or another ERR<x>), or nil.
function Protocol.ErrorCode(text)
  local code = text:match("^ERR(%w)$")
  if code then return "ERR" .. code end
  return nil
end

function Protocol.ErrorText(code)
  return Protocol.Errors[code] or "Unknown Error"
end

return Protocol
