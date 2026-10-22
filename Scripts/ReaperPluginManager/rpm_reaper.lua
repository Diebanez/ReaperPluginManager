-- rpm_reaper.lua: the REAPER side of ReaperPluginManager.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
if script_dir and not package.path:find(script_dir, 1, true) then
  package.path = script_dir .. "?.lua;" .. package.path
end

local core = require("rpm_core")

local M = {}

local SEP = package.config:sub(1, 1)

-- The tool's local data folder, with a trailing separator.
function M.data_dir()
  return reaper.GetResourcePath() .. SEP .. "ReaperPluginManager" .. SEP
end

function M.config_path()
  return M.data_dir() .. "config.ini"
end

-- "windows", "macos" or "other"; the tool does nothing on "other".
local function platform()
  local os_name = reaper.GetOS()
  if os_name:match("^Win") then
    return "windows"
  elseif os_name:match("^OSX") or os_name:match("^macOS") then
    return "macos"
  end
  return "other"
end

M.platform = platform

-- Returns nil when the tool can run here, or the message that says why not:
-- REAPER older than 7 (no EnumInstalledFX) or a platform other than Windows
-- and macOS.
function M.guard()
  if not reaper.EnumInstalledFX then
    return "REAPER 7 or later is required."
  end
  if platform() == "other" then
    return "ReaperPluginManager works only on Windows and macOS: it does nothing on this system."
  end
  return nil
end

M.settings = {}

-- Returns a complete settings value from config.ini; never raises.
function M.settings.load()
  local ok, path = pcall(M.config_path)
  if not ok then
    return core.settings.defaults()
  end
  return core.settings.load(path)
end

-- Writes the keys present in `values` (a settings value, complete or
-- partial) into config.ini, keeping every key, comment and line it does not
-- name. Returns true, or false and the reason.
function M.settings.save(values)
  local path = M.config_path()
  local text = ""
  local f = io.open(path, "rb")
  if f then
    text = f:read("a") or ""
    f:close()
  end
  reaper.RecursiveCreateDirectory(M.data_dir(), 0)
  local out = core.settings.to_ini(text, values)
  f = io.open(path, "wb")
  if not f then
    return false, "Cannot write the settings to " .. path
  end
  local ok = f:write(out)
  f:close()
  if not ok then
    return false, "Cannot write the settings to " .. path
  end
  return true
end

---------------------------------------------------------------------------
-- Credentials: the server password in the OS secret store, and the
-- short-lived netrc credentials file a transfer reads it from.
---------------------------------------------------------------------------

M.credentials = {}

local EXT_SECTION = "ReaperPluginManager"
local SERVICE_PREFIX = "ReaperPluginManager:"
local HELPER_TIMEOUT_MS = 30000

local STORE_NAMES = {
  windows = "Windows DPAPI",
  macos = "macOS Keychain",
  other = "secret store",
}

local function store_error(detail)
  return STORE_NAMES[platform()] .. ": " .. detail
end

local function helpers_dir()
  return (script_dir or "") .. "helpers" .. SEP
end

local function to_hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

local function from_hex(h)
  return (h:gsub("%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function sh_quote(s)
  return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- The host of a server URL, lowercased, or nil when it has none (file://).
local function url_host(url)
  local rest = type(url) == "string" and url:match("^%a[%w+.-]*://(.*)$")
  if not rest then
    return nil
  end
  local authority = rest:match("^[^/?#]*")
  authority = authority:match("@([^@]*)$") or authority
  local host = authority:match("^(%[.-%])") or authority:match("^[^:]*")
  if host == "" then
    return nil
  end
  return host:lower()
end

local function key_of(host, user)
  return host .. "\n" .. user
end

-- A fresh name in the data folder for a transient file.
local function temp_path(prefix)
  return M.data_dir() .. string.format("%s-%d-%06d.tmp", prefix, os.time(), math.random(0, 999999))
end

-- Writes `text` to a new file that only the current user can read.
local function write_private(path, text)
  reaper.RecursiveCreateDirectory(M.data_dir(), 0)
  if platform() == "macos" then
    os.execute("(umask 077; : > " .. sh_quote(path) .. ")")
  end
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  local ok = f:write(text)
  f:close()
  if not ok then
    os.remove(path)
    return false
  end
  return true
end

-- Runs the platform helper and returns its result line: "OK [hex]",
-- "NOTFOUND" or "ERROR <reason>"; nil and a reason when it did not run.
local function run_helper(action, host, user, infile)
  local p = platform()
  local cmd
  if p == "windows" then
    local store = M.data_dir() .. "secrets" .. SEP .. to_hex(SERVICE_PREFIX .. key_of(host, user)) .. ".bin"
    cmd = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'
      .. helpers_dir() .. 'rpm-secret.ps1" -Action ' .. action .. ' -Store "' .. store .. '"'
    if infile then
      cmd = cmd .. ' -InFile "' .. infile .. '"'
    end
  elseif p == "macos" then
    cmd = "/bin/bash " .. sh_quote(helpers_dir() .. "rpm-secret.sh") .. " " .. action
      .. " " .. sh_quote(SERVICE_PREFIX .. host) .. " " .. sh_quote(user)
    if infile then
      cmd = cmd .. " " .. sh_quote(infile)
    end
  else
    return nil, "unsupported platform"
  end

  local output
  if p == "windows" then
    local ret = reaper.ExecProcess(cmd, HELPER_TIMEOUT_MS)
    if not ret then
      return nil, "cannot start PowerShell"
    end
    output = ret:match("^[^\n]*\n(.*)$") or ""
  else
    local f = io.popen(cmd .. " 2>/dev/null", "r")
    if not f then
      return nil, "cannot start the security command"
    end
    output = f:read("a") or ""
    f:close()
  end
  for line in output:gmatch("[^\r\n]+") do
    if line:match("^OK") or line == "NOTFOUND" or line:match("^ERROR") then
      return line
    end
  end
  return nil, "no answer from the helper script"
end

local cache = {}

-- Returns true when `password` can go into the credentials file, or false
-- and the reason it cannot: the netrc format cannot hold whitespace. An
-- empty password passes (setup-action reads it as "keep the stored one").
function M.credentials.validate_password(password)
  if type(password) ~= "string" then
    return false, "The password is not valid."
  end
  if password:find("%s") then
    return false, "The password cannot contain spaces, tabs or line breaks."
  end
  return true
end

-- Returns the stored password of `user` on `host`, read from the store once
-- and then kept in memory for the rest of the session; or nil, an error
-- naming the store and, when nothing is stored, true.
local function read_password(host, user)
  local key = key_of(host, user)
  if cache[key] then
    return cache[key]
  end
  local line, err = run_helper("get", host, user)
  if not line then
    return nil, store_error(err)
  elseif line == "NOTFOUND" then
    return nil, store_error("no password stored for user " .. user .. "; run Setup."), true
  elseif line:match("^ERROR") then
    return nil, store_error(line:match("^ERROR (.*)$") or line)
  end
  local password = from_hex(line:match("^OK%s*(%x*)$") or "")
  if password == "" then
    return nil, store_error("the stored password is empty; run Setup.")
  end
  cache[key] = password
  return password
end

-- Returns user, password for the configured server; password is nil for an
-- empty user (anonymous access). On a secret-store failure returns user, nil
-- and an error naming the store.
function M.credentials.get()
  local settings = M.settings.load()
  local user = settings.server.user
  if user == "" then
    return user, nil
  end
  local password, err = read_password(url_host(settings.server.url) or "", user)
  return user, password, err
end

-- Stores `password` for `user` on the server at `url`, replacing any stored
-- one. Returns true, or false and an error naming the store.
function M.credentials.store(url, user, password)
  if type(user) ~= "string" or user == "" then
    return false, store_error("no user given.")
  end
  if type(password) ~= "string" or password == "" then
    return false, store_error("the password is empty.")
  end
  local valid, invalid = M.credentials.validate_password(password)
  if not valid then
    return false, invalid
  end
  local host = url_host(url) or ""
  local infile = temp_path("secret")
  if not write_private(infile, password) then
    return false, store_error("cannot write the temporary file.")
  end
  local line, err = run_helper("set", host, user, infile)
  os.remove(infile)
  if not line then
    return false, store_error(err)
  elseif line ~= "OK" then
    return false, store_error(line:match("^ERROR (.*)$") or line)
  end
  cache[key_of(host, user)] = password
  return true
end

-- Removes the stored password of `user` on the server at `url`; removing
-- one that is not there succeeds. An empty user is what triggers this.
-- Returns true, or false and an error naming the store.
function M.credentials.remove(url, user)
  if type(user) ~= "string" or user == "" then
    return true
  end
  local host = url_host(url) or ""
  cache[key_of(host, user)] = nil
  local line, err = run_helper("delete", host, user)
  if not line then
    return false, store_error(err)
  elseif line ~= "OK" then
    return false, store_error(line:match("^ERROR (.*)$") or line)
  end
  return true
end

-- Applies the setup dialog's credential rules when the server account goes
-- from `old_user` on `old_url` to `user` on `url`: an empty user removes the
-- previous user's stored password; a password replaces the stored one; an
-- empty password with the same user keeps the stored one, carried over to
-- the new host when the server host changed. Returns true, or false and an
-- error naming the store.
function M.credentials.update(old_url, old_user, url, user, password)
  if user == "" then
    return M.credentials.remove(old_url, old_user)
  end
  if password ~= "" then
    return M.credentials.store(url, user, password)
  end
  if user ~= old_user then
    return true
  end
  local old_host, host = url_host(old_url) or "", url_host(url) or ""
  if old_host == host then
    return true
  end
  local stored, err, missing = read_password(old_host, user)
  if not stored then
    if missing then
      return true
    end
    return false, err
  end
  return M.credentials.store(url, user, stored)
end

-- Writes the netrc credentials file for the configured server and returns
-- its path; the caller removes it with release_file once the transfer ends.
-- Returns nil with no error when no file is needed (anonymous access or a
-- server without a host), or nil and an error.
function M.credentials.acquire_file()
  local settings = M.settings.load()
  local host = url_host(settings.server.url)
  if not host then
    return nil
  end
  local user, password, err = M.credentials.get()
  if err then
    return nil, err
  end
  if not password then
    return nil
  end
  local path = temp_path("netrc")
  local text = "machine " .. host .. "\nlogin " .. user .. "\npassword " .. password .. "\n"
  if not write_private(path, text) then
    return nil, "Cannot write the credentials file to " .. M.data_dir()
  end
  return path
end

function M.credentials.release_file(path)
  if path then
    os.remove(path)
  end
end

-- Removes the transient credential files a crash left in the data folder.
-- Runs once per REAPER session, at the first load of this module.
function M.credentials.sweep()
  if reaper.GetExtState(EXT_SECTION, "credentials_swept") == "1" then
    return
  end
  reaper.SetExtState(EXT_SECTION, "credentials_swept", "1", false)
  local dir = M.data_dir()
  local stale, i = {}, 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then
      break
    end
    if name:match("^netrc%-.+%.tmp$") or name:match("^secret%-.+%.tmp$") then
      stale[#stale + 1] = dir .. name
    end
    i = i + 1
  end
  for _, path in ipairs(stale) do
    os.remove(path)
  end
end

pcall(M.credentials.sweep)

return M
