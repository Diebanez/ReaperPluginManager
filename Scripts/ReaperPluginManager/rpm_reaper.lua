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

local sh_quote = core.sh_quote

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

-- The prefixes of the transient files a crash can leave in the data folder:
-- credentials files, secret hand-offs, curl error output, background upload
-- status files and catalogue downloads and cache writes.
local TRANSIENT_PREFIXES = { "netrc", "secret", "curl", "upload", "catalogue" }

-- Removes the transient files a crash left in the data folder. Runs once per
-- REAPER session, at the first load of this module.
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
    for _, prefix in ipairs(TRANSIENT_PREFIXES) do
      if name:match("^" .. prefix .. "%-.+%.tmp$") then
        stale[#stale + 1] = dir .. name
        break
      end
    end
    i = i + 1
  end
  for _, path in ipairs(stale) do
    os.remove(path)
  end
end

pcall(M.credentials.sweep)

---------------------------------------------------------------------------
-- Transfer: curl downloads, uploads, renames and deletes on the configured
-- server, and plain file operations for a file:// server.
---------------------------------------------------------------------------

M.transfer = {}

local CURL = { windows = "curl.exe", macos = "/usr/bin/curl" }
local COPY_CHUNK = 1048576
local ASYNC_START_TIMEOUT = 30
local STATUS_READ_WINDOW = 8192

local function file_exists(path)
  local f = path and io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local size = f:seek("end")
  f:close()
  return size
end

-- The last `window` bytes of the file at `path`, or nil when it cannot be read.
local function read_tail(path, window)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local size = f:seek("end") or 0
  f:seek("set", math.max(0, size - window))
  local text = f:read("a")
  f:close()
  return text
end

local function make_parent_dir(path)
  local dir = path:match("^(.*)[\\/][^\\/]*$")
  if dir and dir ~= "" then
    reaper.RecursiveCreateDirectory(dir, 0)
  end
end

-- Moves `src` to `dst`, replacing an existing `dst`.
local function move_file(src, dst)
  if os.rename(src, dst) then
    return true
  end
  if file_exists(src) and file_exists(dst) then
    os.remove(dst)
    if os.rename(src, dst) then
      return true
    end
  end
  return false, "Cannot move " .. src .. " to " .. dst
end

-- Copies `src` to `dst` through `dst`.part, so `dst` is never partial.
local function copy_file(src, dst)
  local fin = io.open(src, "rb")
  if not fin then
    return false, "Cannot read " .. src
  end
  make_parent_dir(dst)
  local part = dst .. ".part"
  local fout = io.open(part, "wb")
  if not fout then
    fin:close()
    return false, "Cannot write " .. dst
  end
  while true do
    local chunk = fin:read(COPY_CHUNK)
    if not chunk then
      break
    end
    if not fout:write(chunk) then
      fin:close()
      fout:close()
      os.remove(part)
      return false, "Cannot write " .. dst
    end
  end
  fin:close()
  fout:close()
  local ok, err = move_file(part, dst)
  if not ok then
    os.remove(part)
  end
  return ok, err
end

-- The configured server as { settings, url, kind }, or nil and the reason
-- no transfer can run.
local function server()
  local settings = M.settings.load()
  local url = settings.server.url
  if url == "" then
    return nil, "No server is configured; run Setup."
  end
  local kind = core.transfer.kind(url)
  if not kind then
    return nil, "The server address is not supported: " .. url
  end
  if kind ~= "file" and not CURL[platform()] then
    return nil, "Transfers work only on Windows and macOS."
  end
  return { settings = settings, url = url, kind = kind }
end

-- Materializes the credentials file `srv` transfers with, and remembers the
-- password so error text can mask it. Returns true, or false and an error.
local function open_session(srv)
  if srv.kind == "file" then
    return true
  end
  local path, err = M.credentials.acquire_file()
  if err then
    return false, err
  end
  srv.netrc = path
  if path then
    local _, password = M.credentials.get()
    srv.secret = password
  end
  return true
end

local function close_session(srv)
  M.credentials.release_file(srv.netrc)
  srv.netrc = nil
end

-- The filesystem path of `path` on the file:// server `srv`.
local function local_server_path(srv, path)
  return core.transfer.file_path(srv.url, path, platform() == "windows")
end

-- The common options for `srv` followed by `args`.
local function curl_args(srv, args, progress)
  local full = core.transfer.common_options(srv.settings, srv.netrc, progress)
  for _, a in ipairs(args) do
    full[#full + 1] = a
  end
  return full
end

-- Runs curl with the common options and `args`, waiting for it to end.
-- Returns true, or false and the one-line reason.
local function run_curl(srv, args)
  reaper.RecursiveCreateDirectory(M.data_dir(), 0)
  local errfile = temp_path("curl")
  local full = curl_args(srv, args)
  full[#full + 1] = "--stderr"
  full[#full + 1] = errfile
  local code
  if platform() == "windows" then
    local ret = reaper.ExecProcess(core.transfer.command(CURL.windows, full, "windows"), 0)
    code = ret and tonumber(ret:match("^%s*(%-?%d+)"))
  else
    local _, how, n = os.execute(core.transfer.command(CURL.macos, full, "macos") .. " >/dev/null 2>&1")
    if how == "exit" then
      code = n
    end
  end
  local stderr = read_tail(errfile, STATUS_READ_WINDOW)
  os.remove(errfile)
  if code == 0 then
    return true
  end
  return false, core.transfer.error_message(code, stderr, srv.secret)
end

local function op_download(srv, server_path, local_path)
  if srv.kind == "file" then
    local src = local_server_path(srv, server_path)
    if not file_exists(src) then
      return false, "Not found on the server: " .. server_path
    end
    return copy_file(src, local_path)
  end
  local part = local_path .. ".part"
  local ok, err = run_curl(srv, core.transfer.args("download", srv.url, platform(), server_path, part))
  if not ok then
    os.remove(part)
    return false, err
  end
  ok, err = move_file(part, local_path)
  if not ok then
    os.remove(part)
  end
  return ok, err
end

local function op_upload(srv, local_path, server_path)
  if srv.kind == "file" then
    return copy_file(local_path, local_server_path(srv, server_path))
  end
  return run_curl(srv, core.transfer.args("upload", srv.url, platform(), local_path, server_path))
end

local function op_rename(srv, from, to)
  if srv.kind == "file" then
    local src = local_server_path(srv, from)
    if not file_exists(src) then
      return false, "Not found on the server: " .. from
    end
    return move_file(src, local_server_path(srv, to))
  end
  return run_curl(srv, core.transfer.args("rename", srv.url, platform(), from, to))
end

local function op_delete(srv, server_path)
  if srv.kind == "file" then
    local path = local_server_path(srv, server_path)
    if not file_exists(path) then
      return false, "Not found on the server: " .. server_path
    end
    if not os.remove(path) then
      return false, "Cannot delete " .. path
    end
    return true
  end
  return run_curl(srv, core.transfer.args("delete", srv.url, platform(), server_path))
end

-- Upload under `<name>.uploading`, then rename over `<name>`; a failed
-- rename removes the temporary file.
local function op_replace(srv, local_path, server_path)
  local temp = server_path .. ".uploading"
  local ok, err = op_upload(srv, local_path, temp)
  if not ok then
    return false, err
  end
  ok, err = op_rename(srv, temp, server_path)
  if not ok then
    op_delete(srv, temp)
    return false, err
  end
  return true
end

-- Runs `op` on the configured server with a credentials file that lives
-- only for its duration. Returns ok, err.
local function blocking(op, ...)
  local srv, err = server()
  if not srv then
    return false, err
  end
  local ok, serr = open_session(srv)
  if not ok then
    return false, serr
  end
  local pok, res, rerr = pcall(op, srv, ...)
  close_session(srv)
  if not pok then
    return false, (tostring(res):gsub("%s+", " "))
  end
  return res, rerr
end

-- Downloads `server_path` to `local_path`, which is replaced only when the
-- whole file arrived. Returns ok, err.
function M.transfer.download(server_path, local_path)
  return blocking(op_download, server_path, local_path)
end

-- Uploads `local_path` to `server_path`, waiting for it to end. Returns ok, err.
function M.transfer.upload(local_path, server_path)
  return blocking(op_upload, local_path, server_path)
end

-- Renames `from` to `to` on the server, replacing `to`. Returns ok, err.
function M.transfer.rename(from, to)
  return blocking(op_rename, from, to)
end

-- Replaces `server_path` with `local_path` so readers never see a partial
-- file. Returns ok, err.
function M.transfer.replace(local_path, server_path)
  return blocking(op_replace, local_path, server_path)
end

-- Deletes `server_path` on the server. Returns ok, err.
function M.transfer.delete(server_path)
  return blocking(op_delete, server_path)
end

-- A handle whose poll() always reports the same result.
local function finished_handle(state, done, total, err)
  return {
    poll = function()
      return state, done, total, err
    end,
  }
end

-- Starts curl with `args` without waiting; its error output and progress
-- meter go to `status`, followed by `EXIT <code>` (`EXIT -` on Windows
-- failure) when it ends. Returns true when it started.
local function launch_background(args, status)
  if platform() == "windows" then
    local q = core.win_quote(status)
    local cmd = 'cmd.exe /d /s /c "' .. core.transfer.command(CURL.windows, args, "windows")
      .. " && (echo EXIT 0)>>" .. q .. " || (echo EXIT -)>>" .. q .. '"'
    return reaper.ExecProcess(cmd, -1) ~= nil
  end
  local cmd = "( " .. core.transfer.command(CURL.macos, args, "macos")
    .. ' >/dev/null 2>&1; echo "EXIT $?" >> ' .. sh_quote(status) .. " ) >/dev/null 2>&1 &"
  return os.execute(cmd) == true
end

-- The file:// background upload: each poll copies the next chunk.
local function file_upload_handle(srv, local_path, server_path, total)
  local dst = local_server_path(srv, server_path)
  make_parent_dir(dst)
  local part = dst .. ".part"
  local fin = io.open(local_path, "rb")
  local fout = fin and io.open(part, "wb")
  if not fout then
    if fin then
      fin:close()
    end
    return finished_handle("failed", 0, total, "Cannot write " .. dst)
  end
  local done, result = 0, nil
  -- Ends the copy: moves the part file into place unless `err` already
  -- failed it.
  local function finish(err)
    fin:close()
    fout:close()
    if not err then
      local ok, merr = move_file(part, dst)
      err = not ok and merr or nil
    end
    if err then
      os.remove(part)
      result = { "failed", done, total, err }
    else
      result = { "done", total, total }
    end
    return table.unpack(result)
  end
  return {
    poll = function()
      if result then
        return table.unpack(result)
      end
      local chunk = fin:read(COPY_CHUNK)
      if not chunk then
        return finish(nil)
      end
      if not fout:write(chunk) then
        return finish("Cannot write " .. dst)
      end
      done = done + #chunk
      return "running", done, total
    end,
  }
end

-- Starts uploading `local_path` to `server_path` without waiting. The handle's
-- poll() returns state ("running", "done" or "failed"), bytes done, bytes
-- total and, when failed, the one-line reason; call it from a defer loop.
-- The credentials file lives until poll() sees the upload end.
function M.transfer.upload_async(local_path, server_path)
  local total = file_size(local_path)
  if not total then
    return finished_handle("failed", 0, 0, "Cannot read " .. local_path)
  end
  local srv, err = server()
  if not srv then
    return finished_handle("failed", 0, total, err)
  end
  if srv.kind == "file" then
    return file_upload_handle(srv, local_path, server_path, total)
  end
  local ok, serr = open_session(srv)
  if not ok then
    return finished_handle("failed", 0, total, serr)
  end
  local status = temp_path("upload")
  local args = curl_args(srv, core.transfer.args("upload", srv.url, platform(), local_path, server_path), true)
  args[#args + 1] = "--stderr"
  args[#args + 1] = status
  if not launch_background(args, status) then
    close_session(srv)
    return finished_handle("failed", 0, total, "Cannot start curl.")
  end
  local started = reaper.time_precise()
  local done, result = 0, nil
  return {
    poll = function()
      if result then
        return table.unpack(result)
      end
      local text = read_tail(status, STATUS_READ_WINDOW)
      if not text then
        if reaper.time_precise() - started > ASYNC_START_TIMEOUT then
          close_session(srv)
          result = { "failed", 0, total, "The upload did not start." }
          return table.unpack(result)
        end
        return "running", 0, total
      end
      local st = core.transfer.parse_status(text)
      if st.bytes then
        done = math.min(total, math.max(done, st.bytes))
      end
      if not st.done then
        return "running", done, total
      end
      if st.code == 0 then
        result = { "done", total, total }
      else
        result = { "failed", done, total, core.transfer.error_message(st.code, st.text, srv.secret) }
      end
      close_session(srv)
      os.remove(status)
      return table.unpack(result)
    end,
  }
end

-- The transfer options of a detached install run: the credentials file
-- (only when the server needs one), the TLS level and the insecure switch.
-- The helper deletes the credentials file when it ends. Returns the options,
-- or nil and an error.
function M.transfer.helper_options()
  local settings = M.settings.load()
  local path, err = M.credentials.acquire_file()
  if err then
    return nil, err
  end
  return { netrc_path = path, tls = settings.server.tls, insecure = settings.server.insecure }
end

---------------------------------------------------------------------------
-- Catalogue: fetch from the server root, with the local cache as fallback.
---------------------------------------------------------------------------

M.catalogue = {}

local CATALOGUE_FILE = "manifest.json"

local function cache_path()
  return M.data_dir() .. "catalogue.json"
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("a")
  f:close()
  return text
end

local function one_line(s)
  return (tostring(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function console(msg)
  reaper.ShowConsoleMsg("ReaperPluginManager: " .. msg .. "\n")
end

local function report_warnings(warnings)
  for _, w in ipairs(warnings or {}) do
    console("catalogue " .. w)
  end
end

-- Replaces the cache with the decoded catalogue `value` served by `url`.
-- Returns true, or false and an error.
local function save_cache(url, value)
  local text, err = core.catalogue.cache_text(url, value)
  if not text then
    return false, err
  end
  reaper.RecursiveCreateDirectory(M.data_dir(), 0)
  local temp = temp_path("catalogue")
  local f = io.open(temp, "wb")
  if not f then
    return false, "Cannot write " .. temp
  end
  local ok = f:write(text)
  f:close()
  if not ok then
    os.remove(temp)
    return false, "Cannot write " .. temp
  end
  local moved, merr = move_file(temp, cache_path())
  if not moved then
    os.remove(temp)
  end
  return moved, merr
end

-- The cached catalogue and its warnings when the cache came from `url` and
-- is still valid, or nil.
local function load_cache(url)
  local text = read_file(cache_path())
  if not text then
    return nil
  end
  return core.catalogue.read_cache(text, url)
end

-- Downloads and validates the server catalogue and, when it is usable,
-- replaces the cache with it. Returns the catalogue and its warnings, or nil
-- and the one-line reason it cannot be used.
local function fetch_server(url)
  local temp = temp_path("catalogue")
  local ok, err = M.transfer.download(CATALOGUE_FILE, temp)
  if not ok then
    os.remove(temp)
    return nil, "Cannot download the catalogue: " .. one_line(err)
  end
  local text = read_file(temp)
  os.remove(temp)
  if not text then
    return nil, "Cannot read the downloaded catalogue."
  end
  local catalogue, warnings, value = core.catalogue.parse(text)
  if not catalogue then
    return nil, warnings
  end
  local saved, serr = save_cache(url, value)
  if not saved then
    console("cannot update the catalogue cache: " .. one_line(serr))
  end
  return catalogue, warnings
end

local function fetch(url)
  local catalogue, warnings = fetch_server(url)
  if catalogue then
    report_warnings(warnings)
    return catalogue, "server"
  end
  local reason = warnings
  local cached, cache_warnings = load_cache(url)
  if not cached then
    return nil, "none", reason
  end
  report_warnings(cache_warnings)
  return cached, "cache", reason
end

-- Fetches the catalogue from the server root. Returns catalogue, source and
-- reason: source is "server" (the cache was replaced), "cache" (the server
-- catalogue could not be used; reason says why) or "none" (no usable cache
-- either; the catalogue is nil). Validation warnings go to the REAPER
-- console. A cache from another server URL than the current setting is
-- ignored. Never raises.
function M.catalogue.fetch()
  local url = ""
  local ok, catalogue, source, reason = pcall(function()
    url = M.settings.load().server.url
    return fetch(url)
  end)
  if ok then
    return catalogue, source, reason
  end
  reason = "Cannot fetch the catalogue: " .. one_line(catalogue)
  local cok, cached, warnings = pcall(load_cache, url)
  if cok and cached then
    pcall(report_warnings, warnings)
    return cached, "cache", reason
  end
  return nil, "none", reason
end

return M
