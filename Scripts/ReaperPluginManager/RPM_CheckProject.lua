-- @noindex

-- RPM_CheckProject.lua: the "ReaperPluginManager: Check project" action.
-- Checks the current project as saved on disk and always shows a result: the
-- summary window, "All N plugins are installed", or why it could not check.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
if script_dir and not package.path:find(script_dir, 1, true) then
  package.path = script_dir .. "?.lua;" .. package.path
end

local rpm = require("rpm_reaper")

local TITLE = "ReaperPluginManager - Check project"

local function message(text)
  reaper.ShowMessageBox(text, TITLE, 0)
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local function main()
  local blocked = rpm.guard()
  if blocked then
    message(blocked)
    return
  end

  local ok, result = pcall(rpm.check.run)
  if not ok then
    message("The check failed: " .. tostring(result))
    return
  end
  if result.status == "not_saved" then
    message("Save the project first.")
    return
  end
  if result.status == "file_missing" then
    message("Cannot read the project file:\n" .. result.path)
    return
  end

  local shown_ok, shown = pcall(rpm.check.show, result)
  if not shown_ok then
    message("Cannot show the check result: " .. tostring(shown))
    return
  end
  if shown then
    return
  end

  local missing = #result.missing
  if result.total == 0 then
    message("The project uses no plugins.")
  elseif missing == 0 then
    message(("All %s %s installed."):format(plural(result.total, "plugin"), result.total == 1 and "is" or "are"))
  else
    -- Only plugins not in the catalogue are left, and notify_unknown hides them.
    message(("%d of the project's %s %s not installed and not in the catalogue. "
      .. "They are not listed because notify_unknown is off in config.ini.")
      :format(missing, plural(result.total, "plugin"), missing == 1 and "is" or "are"))
  end
end

main()
