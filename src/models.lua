-- Model registry plus data shared by design-time and runtime code.
--
-- Both displays use one shared EQ3 command set (see commands.lua); a model
-- here carries only identity data. The "Auto" choice accepts whichever model
-- the display reports in its QID reply.
local Models = {
  ById = {},
  Ids = { "TH-43EQ3W", "TH-55EQ3W" },
  Choices = { "Auto", "TH-43EQ3W", "TH-55EQ3W" },
  Default = "Auto",
}

Models.ById["TH-43EQ3W"] = {
  Id = "TH-43EQ3W",
  Name = "Panasonic TH-43EQ3W",
  Family = "EQ3",
  SizeInches = 43,
  QueryId = "43EQ3W",
  DefaultPort = 1024,
}

Models.ById["TH-55EQ3W"] = {
  Id = "TH-55EQ3W",
  Name = "Panasonic TH-55EQ3W",
  Family = "EQ3",
  SizeInches = 55,
  QueryId = "55EQ3W",
  DefaultPort = 1024,
}

Models.Auto = {
  Id = "Auto",
  Name = "Panasonic EQ3",
  Family = "EQ3",
  DefaultPort = 1024,
}

-- The configured model, or the generic EQ3 entry for "Auto".
function Models.Get(id)
  return Models.ById[id] or Models.Auto
end

-- Maps a QID reply such as "55EQ3W" (or "TH-55EQ3W") to a model, or nil.
function Models.FromQueryId(text)
  local upper = tostring(text or ""):upper():gsub("^TH%-", "")
  for _, id in ipairs(Models.Ids) do
    local model = Models.ById[id]
    if upper:find(model.QueryId, 1, true) then return model end
  end
  return nil
end

return Models
