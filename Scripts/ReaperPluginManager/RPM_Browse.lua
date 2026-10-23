-- @noindex

-- RPM_Browse.lua: the "Script: RPM_Browse.lua" action.
-- Lists every plugin the catalogue offers with its state on this machine and
-- installs the ones the member ticks, with no project needing them.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
if script_dir and not package.path:find(script_dir, 1, true) then
  package.path = script_dir .. "?.lua;" .. package.path
end

local rpm = require("rpm_reaper")

local TITLE = "ReaperPluginManager - Browse catalogue"

local function message(text)
  reaper.ShowMessageBox(text, TITLE, 0)
end

local function main()
  local blocked = rpm.guard()
  if blocked then
    message(blocked)
    return
  end
  if rpm.install.is_running() then
    message(rpm.browse.RUNNING_MESSAGE)
    return
  end

  local ok, result = pcall(rpm.browse.load)
  if not ok then
    message("Cannot read the catalogue: " .. tostring(result))
    return
  end
  if not result.catalogue then
    message("No catalogue is available, so nothing can be listed.\n\n" .. tostring(result.reason or "No reason was given."))
    return
  end
  if #result.rows == 0 then
    message("The catalogue lists no plugins.")
    return
  end

  local shown_ok, shown = pcall(rpm.browse.show, result)
  if not shown_ok then
    message("Cannot show the catalogue: " .. tostring(shown))
  end
end

main()
