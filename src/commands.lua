-- Panasonic EQ3 command strings and reply parsers.
--
-- Every string here comes from Panasonic's EQ3 command list (see
-- EQ3_COMMAND_REFERENCE.md). Do not add commands unless they are verified
-- against Panasonic documentation or a real display. The command set is shared
-- by TH-43EQ3W and TH-55EQ3W.
--
-- Parsers receive the reply body with the transport framing already removed
-- (for example "QPW:1") and return the decoded value, or nil if the reply is
-- not in the documented format.
local Commands = {}

-- ---------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------
Commands.Inputs = {
  { Label = "HDMI 1", Code = "HM1" },
  { Label = "HDMI 2", Code = "HM2" },
  { Label = "HDMI 3", Code = "HM3" },
  { Label = "PC", Code = "PC1" },
  { Label = "USB", Code = "UD1" },
}

Commands.Aspects = {
  { Label = "Full", Code = "FULL" },
  { Label = "Normal", Code = "NORM" },
  { Label = "Native", Code = "NATV" },
  { Label = "Zoom", Code = "ZOOM" },
}

Commands.PictureModes = {
  { Label = "Dynamic", Code = "DYN" },
  { Label = "Graphic", Code = "GRH" },
  { Label = "Sports", Code = "SPT" },
  { Label = "Standard", Code = "STD" },
}

Commands.VolumeRange = { Min = 0, Max = 100 }
Commands.BacklightRange = { Min = 0, Max = 50 }

function Commands.Labels(list)
  local labels = {}
  for _, item in ipairs(list) do labels[#labels + 1] = item.Label end
  return labels
end

function Commands.CodeForLabel(list, label)
  for _, item in ipairs(list) do
    if item.Label == label then return item.Code end
  end
  return nil
end

function Commands.LabelForCode(list, code)
  for _, item in ipairs(list) do
    if item.Code == code then return item.Label end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Commands. `idempotent` means a retry after a timeout cannot double-trigger
-- anything. `coalesce` means a newer request with the same key replaces one
-- that is still waiting in the queue (used for slider drags).
-- ---------------------------------------------------------------------------
Commands.PowerOn = { line = "PON", idempotent = true }
Commands.PowerOff = { line = "POF", idempotent = true }

local function clamp(value, range)
  local n = math.floor((tonumber(value) or range.Min) + 0.5)
  if n < range.Min then n = range.Min end
  if n > range.Max then n = range.Max end
  return n
end

function Commands.Input(code)
  return { line = "IMS:" .. code, idempotent = true }
end

function Commands.Volume(level)
  return {
    line = string.format("AVL:%03d", clamp(level, Commands.VolumeRange)),
    idempotent = true,
    coalesce = true,
  }
end

function Commands.Mute(on)
  return { line = "AMT:" .. (on and "1" or "0"), idempotent = true }
end

function Commands.Aspect(code)
  return { line = "DAM:" .. code, idempotent = true }
end

function Commands.PictureMode(code)
  return { line = "VPC:MEN" .. code, idempotent = true }
end

function Commands.Backlight(level)
  return {
    line = string.format("VPC:BLT%03d", clamp(level, Commands.BacklightRange)),
    idempotent = true,
    coalesce = true,
  }
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------
local function trim(text)
  return (text:match("^%s*(.-)%s*$"))
end

local function parseLevel(pattern, range)
  return function(text)
    local digits = text:match(pattern)
    if not digits then return nil end
    local n = tonumber(digits)
    if n < range.Min or n > range.Max then return nil end
    return n
  end
end

-- Enumerated replies return the raw code; the runtime maps it to a label and
-- shows an unrecognized code as-is rather than hiding it.
local function parseCode(pattern)
  return function(text)
    return text:match(pattern)
  end
end

Commands.Queries = {
  power = {
    line = "QPW",
    parse = function(text)
      local state = text:match("^QPW:([01])$")
      if state == "1" then return "On" end
      if state == "0" then return "Standby" end
      return nil
    end,
  },
  input = { line = "QMI", parse = parseCode("^QMI:(%w+)$") },
  volume = { line = "QAV", parse = parseLevel("^QAV:(%d%d%d)$", Commands.VolumeRange) },
  mute = {
    line = "QAM",
    parse = function(text)
      local state = text:match("^QAM:([01])$")
      if state == "1" then return true end
      if state == "0" then return false end
      return nil
    end,
  },
  aspect = { line = "QAS", parse = parseCode("^QAS:(%u+)$") },
  picture = { line = "QPC:MEN", parse = parseCode("^QPC:MEN(%u+)$") },
  backlight = { line = "QPC:BLT", parse = parseLevel("^QPC:BLT(%d%d%d)$", Commands.BacklightRange) },
  model = {
    line = "QID",
    parse = function(text)
      local id = text:match("^QID:(.+)$")
      return id and trim(id) or nil
    end,
  },
  serial = {
    line = "QSN",
    parse = function(text)
      local serial = text:match("^QSN:(.+)$")
      return serial and trim(serial) or nil
    end,
  },
}

return Commands
