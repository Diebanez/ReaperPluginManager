-- RPM_Watcher.lua: the "ReaperPluginManager: Watcher" action, started from
-- REAPER's startup hook. Checks every saved project each time it is opened,
-- in the background, while automatic checking is on.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
if script_dir and not package.path:find(script_dir, 1, true) then
  package.path = script_dir .. "?.lua;" .. package.path
end

local rpm = require("rpm_reaper")

rpm.watcher.start()
