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

M.settings = {}

-- Returns a complete settings value from config.ini; never raises.
function M.settings.load()
  local ok, path = pcall(M.config_path)
  if not ok then
    return core.settings.defaults()
  end
  return core.settings.load(path)
end

---------------------------------------------------------------------------
-- Credentials: the server password in the OS secret store, and the
-- short-lived netrc credentials file a transfer reads it from.
---------------------------------------------------------------------------

M.credentials = {}

local EXT_SECTION = "ReaperPluginManager"
local SERVICE_PREFIX = "ReaperPluginManager:"
local HELPER_TIMEOUT_MS = 30000

local function platform()
  local os_name = reaper.GetOS()
  if os_name:match("^Win") then
    return "windows"
  elseif os_name:match("^OSX") or os_name:match("^macOS") then
    return "macos"
  end
  return "other"
end

local STORE_NAMES = {
  windows = "Windows DPAPI",
  macos = "Portachiavi di macOS",
  other = "archivio segreto",
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
    return nil, "piattaforma non supportata"
  end

  local output
  if p == "windows" then
    local ret = reaper.ExecProcess(cmd, HELPER_TIMEOUT_MS)
    if not ret then
      return nil, "impossibile avviare PowerShell"
    end
    output = ret:match("^[^\n]*\n(.*)$") or ""
  else
    local f = io.popen(cmd .. " 2>/dev/null", "r")
    if not f then
      return nil, "impossibile avviare il comando security"
    end
    output = f:read("a") or ""
    f:close()
  end
  for line in output:gmatch("[^\r\n]+") do
    if line:match("^OK") or line == "NOTFOUND" or line:match("^ERROR") then
      return line
    end
  end
  return nil, "nessuna risposta dallo script di supporto"
end

local cache = {}

-- Returns true when `password` can go into the credentials file, or false
-- and the reason it cannot: the netrc format cannot hold whitespace. An
-- empty password passes (setup-action reads it as "keep the stored one").
function M.credentials.validate_password(password)
  if type(password) ~= "string" then
    return false, "La password non è valida."
  end
  if password:find("%s") then
    return false, "La password non può contenere spazi, tabulazioni o a capo."
  end
  return true
end

-- Returns user, password for the configured server; password is nil for an
-- empty user (anonymous access). On a secret-store failure returns user, nil
-- and an error naming the store. The password is read from the store once
-- and then kept in memory for the rest of the session.
function M.credentials.get()
  local settings = M.settings.load()
  local user = settings.server.user
  if user == "" then
    return user, nil
  end
  local host = url_host(settings.server.url) or ""
  local key = key_of(host, user)
  if cache[key] then
    return user, cache[key]
  end
  local line, err = run_helper("get", host, user)
  if not line then
    return user, nil, store_error(err)
  elseif line == "NOTFOUND" then
    return user, nil, store_error("nessuna password salvata per l'utente " .. user .. "; esegui il Setup.")
  elseif line:match("^ERROR") then
    return user, nil, store_error(line:match("^ERROR (.*)$") or line)
  end
  local password = from_hex(line:match("^OK%s*(%x*)$") or "")
  if password == "" then
    return user, nil, store_error("la password salvata è vuota; esegui il Setup.")
  end
  cache[key] = password
  return user, password
end

-- Stores `password` for `user` on the server at `url`, replacing any stored
-- one. Returns true, or false and an error naming the store.
function M.credentials.store(url, user, password)
  if type(user) ~= "string" or user == "" then
    return false, store_error("nessun utente indicato.")
  end
  if type(password) ~= "string" or password == "" then
    return false, store_error("la password è vuota.")
  end
  local valid, invalid = M.credentials.validate_password(password)
  if not valid then
    return false, invalid
  end
  local host = url_host(url) or ""
  local infile = temp_path("secret")
  if not write_private(infile, password) then
    return false, store_error("impossibile scrivere il file temporaneo.")
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
    return nil, "Impossibile scrivere il file delle credenziali in " .. M.data_dir()
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
