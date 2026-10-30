-- @description ReaperPluginManager
-- @author Diebanez
-- @version 1.6.0-beta.1
-- @changelog
--   Catalogue Manager: a draft entry file can name a local installer by its
--   path (`source`); Import draft attaches it, computing its checksum, and
--   Publish uploads it, so nothing is left to attach by hand.
-- @about
--   Lists the plugins a REAPER project uses that are not installed, installs
--   the ones a group's private catalogue offers, and guides licence
--   activation. Windows and macOS; run *Script: RPM_Setup.lua* first.
--
--   Adds five actions: *Script: RPM_Setup.lua*, *Script: RPM_Watcher.lua*,
--   *Script: RPM_CheckProject.lua*, *Script: RPM_Browse.lua* (installs any
--   plugin the catalogue offers) and *Script: RPM_CatalogueManager.lua*
--   (the maintainer's catalogue editor, which needs ReaImGui).
-- @provides
--   [main] RPM_Watcher.lua
--   [main] RPM_CheckProject.lua
--   [main] RPM_Browse.lua
--   [main] RPM_CatalogueManager.lua
--   rpm_core.lua
--   rpm_reaper.lua
--   helpers/rpm-install.ps1
--   helpers/rpm-install.sh
--   helpers/rpm-secret.ps1
--   helpers/rpm-secret.sh
--   helpers/rpm-run-hidden.ps1
--   helpers/rpm-restart.ps1
--   helpers/rpm-restart.sh

-- RPM_Setup.lua: the "Script: RPM_Setup.lua" action. Collects the server
-- connection in one dialog, validates it, saves the settings and the server
-- credential, registers the tool's actions, installs the startup hook, starts
-- the watcher and tests the connection.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
if script_dir and not package.path:find(script_dir, 1, true) then
  package.path = script_dir .. "?.lua;" .. package.path
end

local rpm = require("rpm_reaper")

local TITLE = "ReaperPluginManager - Setup"

-- Captions are comma-separated; values use the newline separator, because
-- URLs and passwords may contain commas. A caption starting with `*` masks
-- its field.
local CAPTIONS = table.concat({
  "Server URL",
  "User (empty = anonymous)",
  "*Password (empty = unchanged)",
  "TLS (required / try / off)",
  "Automatic check (yes / no)",
  "separator=\n",
  "extrawidth=220",
}, ",")
local FIELD_COUNT = 5

local TLS_LEVELS = { required = true, try = true, off = true }
-- The automatic-check field is on unless it holds one of these "no" forms.
local NO = { no = true, n = true, ["0"] = true, ["false"] = true, off = true }

local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

local function message(text)
  reaper.ShowMessageBox(text, TITLE, 0)
end

-- The dialog's fields as typed: url, user, password, tls, auto.
local function fields_from(settings)
  return {
    url = settings.server.url,
    user = settings.server.user,
    password = "",
    tls = settings.server.tls,
    auto = settings.check.auto and "yes" or "no",
  }
end

-- Shows the dialog proposing `fields`; returns the typed fields, or nil when
-- it was cancelled.
local function ask(fields)
  local initial = table.concat({ fields.url, fields.user, fields.password, fields.tls, fields.auto }, "\n")
  local ok, csv = reaper.GetUserInputs(TITLE, FIELD_COUNT, CAPTIONS, initial)
  if not ok then
    return nil
  end
  local values = {}
  for v in (csv .. "\n"):gmatch("(.-)\n") do
    values[#values + 1] = v
  end
  return {
    url = values[1] or "",
    user = values[2] or "",
    password = values[3] or "",
    tls = values[4] or "",
    auto = values[5] or "",
  }
end

-- Returns the validated values { url, user, password, tls, auto }, or nil,
-- the reason and the fields to propose again.
local function validate(fields)
  local url = trim(fields.url)
  if not url:match("^%a[%w+.-]*://") then
    return nil, "The server URL must start with a scheme, for example ftps://server/folder/.", fields
  end
  if url:sub(-1) ~= "/" then
    url = url .. "/"
  end

  local password = fields.password
  local valid, reason = rpm.credentials.validate_password(password)
  if not valid then
    local again = {}
    for k, v in pairs(fields) do
      again[k] = v
    end
    again.password = ""
    return nil, reason, again
  end

  local tls = trim(fields.tls):lower()
  if not TLS_LEVELS[tls] then
    tls = "required"
  end

  return {
    url = url,
    user = trim(fields.user),
    password = password,
    tls = tls,
    auto = not NO[trim(fields.auto):lower()],
  }
end

local function main()
  local guard = rpm.guard()
  if guard then
    message(guard)
    return
  end

  local current = rpm.settings.load()
  local fields = fields_from(current)
  local values
  while not values do
    local typed = ask(fields)
    if not typed then
      return
    end
    local reason
    values, reason, fields = validate(typed)
    if not values then
      message(reason)
    end
  end

  -- Each step runs whether or not the earlier ones succeeded, where it can;
  -- the closing report lists every outcome.
  local report = {}
  local function add(line)
    report[#report + 1] = line
  end

  local saved, err = rpm.settings.save({
    server = { url = values.url, user = values.user, tls = values.tls },
    check = { auto = values.auto },
  })
  if saved then
    add("Settings saved.")
  else
    add("Settings not saved: " .. err)
  end
  local ok
  ok, err = rpm.credentials.update(current.server.url, current.server.user, values.url, values.user, values.password)
  if not ok then
    add("Password not saved: " .. err)
  end

  local watcher_id, failures = rpm.setup.register_actions()
  if #failures == 0 then
    add("Actions registered: Script: RPM_Watcher.lua, Script: RPM_CheckProject.lua, "
      .. "Script: RPM_Browse.lua, Script: RPM_CatalogueManager.lua, Script: RPM_Setup.lua.")
  else
    for _, failure in ipairs(failures) do
      add(failure)
    end
  end

  ok, err = rpm.setup.install_startup_hook()
  if ok then
    add("Startup hook installed: projects are checked from every REAPER start.")
  else
    add("Startup hook not written: " .. err)
  end

  if not watcher_id then
    add("Watcher not started: its action is not registered.")
  elseif not rpm.settings.load().check.auto then
    add("Watcher not started: automatic checking is off.")
  elseif rpm.watcher.is_running() then
    add("Watcher already running.")
  else
    reaper.Main_OnCommand(watcher_id, 0)
    add("Watcher started.")
  end

  if saved then
    local count, reason = rpm.setup.test_connection()
    if count then
      add(("Connection succeeded: the catalogue lists %d plugins."):format(count))
    else
      add("Connection failed: " .. reason)
    end
  else
    add("Connection not tested: the settings were not saved.")
  end

  message(table.concat(report, "\n"))
end

main()
