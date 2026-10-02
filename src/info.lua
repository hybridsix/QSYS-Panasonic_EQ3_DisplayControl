-- =============================================================
-- info.lua -- Panasonic EQ3 Display Control
--
-- Plugin identity block. Embedded in the .qplug file and read by
-- Q-SYS Designer when loading the plugin.
--
-- Version is injected from package.json by build.js. Do not edit
-- it here.
--
-- Id is a stable GUID that uniquely identifies this plugin.
-- Do not change it after the plugin has been deployed, or
-- existing designs will lose the reference and need to be
-- manually reconnected.
-- =============================================================

PluginInfo = {
  Name = "Hybridsix Software~Panasonic EQ3 Display Control",
  Version = "@VERSION@",
  BuildVersion = "@VERSION@.0",
  Id = "cbf8b894-fffe-4b09-bca8-837fd4070978",
  Author = "Michael King",
  Description = "Control Panasonic TH-43EQ3W and TH-55EQ3W professional displays from Q-SYS: power, input, volume, audio mute, backlight, aspect and picture mode over Panasonic LAN command control (TCP) with SHA-256 / MD5 command protect, and live status feedback.",
}
