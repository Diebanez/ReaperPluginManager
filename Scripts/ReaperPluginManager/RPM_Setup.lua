-- RPM_Setup.lua: the "ReaperPluginManager: Setup" action. Collects the server
-- connection in one dialog, validates it and saves the settings and the
-- server credential.

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

  local errors = {}
  local ok, err = rpm.settings.save({
    server = { url = values.url, user = values.user, tls = values.tls },
    check = { auto = values.auto },
  })
  if not ok then
    errors[#errors + 1] = err
  end
  ok, err = rpm.credentials.update(current.server.url, current.server.user, values.url, values.user, values.password)
  if not ok then
    errors[#errors + 1] = err
  end

  if #errors == 0 then
    message("Settings saved.")
  else
    message("Saving failed:\n- " .. table.concat(errors, "\n- "))
  end
end

main()
