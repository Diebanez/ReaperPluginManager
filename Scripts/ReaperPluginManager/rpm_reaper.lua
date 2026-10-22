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
-- status files, catalogue downloads and cache writes, draft writes and
-- pending-record writes.
local TRANSIENT_PREFIXES = { "netrc", "secret", "curl", "upload", "catalogue", "draft", "activation" }

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

-- Replaces the file at `path` in the data folder with `text`, written first
-- to a transient file named after `prefix`, so `path` is never partial.
-- Returns true, or false and an error.
local function write_replace(path, text, prefix)
  reaper.RecursiveCreateDirectory(M.data_dir(), 0)
  local temp = temp_path(prefix)
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
  local moved, merr = move_file(temp, path)
  if not moved then
    os.remove(temp)
  end
  return moved, merr
end

-- Replaces the cache with the decoded catalogue `value` served by `url`.
-- Returns true, or false and an error.
local function save_cache(url, value)
  local text, err = core.catalogue.cache_text(url, value)
  if not text then
    return false, err
  end
  return write_replace(cache_path(), text, "catalogue")
end

-- The cached catalogue, its warnings and the decoded catalogue as cached when
-- the cache came from `url` and is still valid, or nil.
local function load_cache(url)
  local text = read_file(cache_path())
  if not text then
    return nil
  end
  local catalogue, warnings = core.catalogue.read_cache(text, url)
  if not catalogue then
    return nil
  end
  return catalogue, warnings, core.json.decode(text).catalogue
end

-- Downloads and validates the server catalogue and, when it is usable,
-- replaces the cache with it. Returns the catalogue, its warnings and the
-- decoded catalogue as served, or nil and the one-line reason it cannot be
-- used.
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
  return catalogue, warnings, value
end

local function fetch(url)
  local catalogue, warnings, value = fetch_server(url)
  if catalogue then
    report_warnings(warnings)
    return catalogue, "server", nil, value
  end
  local reason = warnings
  local cached, cache_warnings, cached_value = load_cache(url)
  if not cached then
    return nil, "none", reason
  end
  report_warnings(cache_warnings)
  return cached, "cache", reason, cached_value
end

-- Fetches the catalogue from the server root. Returns catalogue, source,
-- reason and value: source is "server" (the cache was replaced), "cache" (the
-- server catalogue could not be used; reason says why) or "none" (no usable
-- cache either; the catalogue is nil); value is the decoded catalogue before
-- validation, as served or cached, entries validation skipped included.
-- Validation warnings go to the REAPER console. A cache from another server
-- URL than the current setting is ignored. Never raises.
function M.catalogue.fetch()
  local url = ""
  local ok, catalogue, source, reason, value = pcall(function()
    url = M.settings.load().server.url
    return fetch(url)
  end)
  if ok then
    return catalogue, source, reason, value
  end
  reason = "Cannot fetch the catalogue: " .. one_line(catalogue)
  local cok, cached, warnings, cached_value = pcall(load_cache, url)
  if cok and cached then
    pcall(report_warnings, warnings)
    return cached, "cache", reason, cached_value
  end
  return nil, "none", reason
end

---------------------------------------------------------------------------
-- Catalogue draft: the maintainer's local working copy of the catalogue and
-- the base it started from, kept until it is published or discarded.
---------------------------------------------------------------------------

M.draft = {}

function M.draft.path()
  return M.data_dir() .. "draft.json"
end

local function is_table(v)
  return type(v) == "table" and v ~= core.json.null
end

-- Returns the stored draft, or nil when there is none, or nil and an error
-- when it cannot be read. The draft is decoded JSON: `catalogue`, the draft
-- in the catalogue format, and `base`, the catalogue it started from; any
-- other key is kept as stored.
function M.draft.load()
  local path = M.draft.path()
  local text = read_file(path)
  if not text then
    return nil
  end
  local draft, err = core.json.decode(text)
  if draft == nil then
    return nil, "The catalogue draft " .. path .. " is not valid JSON: " .. (err:gsub("^json: ", ""))
  end
  if not is_table(draft) or not is_table(draft.base) or not is_table(draft.catalogue) then
    return nil, "The catalogue draft " .. path .. " is damaged: it lacks the draft catalogue or its base."
  end
  return draft
end

-- Stores `draft`, replacing the stored one in one step. Returns true, or
-- false and an error.
function M.draft.save(draft)
  local text, err = core.json.encode(draft)
  if not text then
    return false, "Cannot encode the catalogue draft: " .. err
  end
  return write_replace(M.draft.path(), text, "draft")
end

-- Starts a draft from the decoded catalogue `value`, which becomes the
-- draft's base, and stores it. Returns the draft, or nil and an error.
function M.draft.create(value)
  local text, err = core.json.encode(value)
  if not text then
    return nil, "Cannot copy the catalogue into a draft: " .. err
  end
  local draft = core.json.object({ base = value, catalogue = core.json.decode(text) })
  local ok, serr = M.draft.save(draft)
  if not ok then
    return nil, serr
  end
  return draft
end

-- Deletes the stored draft; deleting one that is not there succeeds.
-- Returns true, or false and an error.
function M.draft.discard()
  local path = M.draft.path()
  if not file_exists(path) then
    return true
  end
  if not os.remove(path) then
    return false, "Cannot delete " .. path
  end
  return true
end

---------------------------------------------------------------------------
-- Licence activation: the entry's activation field, the record of the
-- entries still pending activation (`activation.ini`), and the walk-through
-- window that opens each vendor's app or page.
---------------------------------------------------------------------------

M.activation = {}

function M.activation.path()
  return M.data_dir() .. "activation.ini"
end

local activation_warned = {}

-- The activation field of the catalogue entry `entry`, as
-- `core.activation.read` returns it. An unknown method reads as `none` and is
-- reported to the REAPER console once per entry and method.
function M.activation.read(entry)
  local activation, warning = core.activation.read(entry)
  if warning and not activation_warned[warning] then
    activation_warned[warning] = true
    console("catalogue " .. warning)
  end
  return activation
end

-- The pending record as { [entry id] = date recorded }; empty when there is
-- none or it cannot be read.
function M.activation.pending()
  return core.activation.parse_pending(read_file(M.activation.path()))
end

local function save_pending(record)
  return write_replace(M.activation.path(), core.activation.pending_text(record), "activation")
end

-- Records the catalogue entries `entries` as pending activation, dated
-- today; an entry already pending keeps its date. Called only for the entries
-- entering the walk-through, so a plugin the tool did not install is never
-- tracked. Returns true, or false and an error.
function M.activation.mark_pending(entries)
  local record = M.activation.pending()
  local today = os.date("%Y-%m-%d")
  local changed = false
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and type(entry.id) == "string" and not record[entry.id] then
      record[entry.id] = today
      changed = true
    end
  end
  if not changed then
    return true
  end
  return save_pending(record)
end

-- Removes the catalogue entries `entries` from the pending record. Returns
-- true, or false and an error.
function M.activation.clear(entries)
  local record = M.activation.pending()
  local changed = false
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and record[entry.id] then
      record[entry.id] = nil
      changed = true
    end
  end
  if not changed then
    return true
  end
  return save_pending(record)
end

-- Returns the pending entries of `catalogue` that any of `installed_refs`
-- (each { name, ident }) associates with; an empty list with no catalogue.
function M.activation.pending_for(installed_refs, catalogue)
  if not catalogue then
    return {}
  end
  return core.activation.pending_among(installed_refs, catalogue, M.activation.pending())
end

-- Opens `target`, an application path or a URL, without waiting: Windows
-- `start "" "<target>"`, macOS `open -a "<app>"` when `as_app`, else
-- `open "<url>"`. Returns true when the opener started.
local function open_target(target, as_app)
  local p = platform()
  if p == "windows" then
    local cmd = 'cmd.exe /d /c start "" "' .. (target:gsub('"', "")) .. '"'
    return reaper.ExecProcess(cmd, -1) ~= nil
  elseif p == "macos" then
    local cmd = (as_app and "open -a " or "open ") .. sh_quote(target) .. " >/dev/null 2>&1"
    return os.execute(cmd) == true
  end
  return false
end

-- True when the vendor app is at its recorded location: an executable on
-- Windows, an `.app` bundle on macOS.
local function app_found(app)
  if not app or not app.path then
    return false
  end
  if platform() == "macos" then
    return os.execute("test -d " .. sh_quote(app.path)) == true
  end
  return file_exists(app.path)
end

-- The walk-through steps for `entries`: one per vendor app on this platform,
-- listing every entry that shares it, otherwise one per entry. Each step is
-- { entries, method, app, url, instructions }; `instructions` holds each
-- distinct instruction of its entries, in order.
local function walk_steps(entries)
  local p = platform()
  local steps, by_app = {}, {}
  for _, entry in ipairs(entries) do
    local a = M.activation.read(entry)
    local app = a.method == "vendor-app" and a.app[p] or nil
    local key = app and (app.path or app.name):lower()
    local step = key and by_app[key]
    if not step then
      step = { entries = {}, method = a.method, app = app, instructions = {}, seen = {} }
      steps[#steps + 1] = step
      if key then
        by_app[key] = step
      end
    end
    step.entries[#step.entries + 1] = entry
    step.url = step.url or a.url
    if a.instructions and not step.seen[a.instructions] then
      step.seen[a.instructions] = true
      step.instructions[#step.instructions + 1] = a.instructions
    end
  end
  return steps
end

-- Opens what Activate opens for `step`. Returns the line the window shows
-- under the step: what was opened, or why nothing was.
local function activate_step(step)
  if step.method == "vendor-app" and app_found(step.app) then
    local name = step.app.name or step.app.path
    if open_target(step.app.path, true) then
      return "Opened " .. name .. "."
    end
    return "Cannot open " .. name .. "."
  end
  if not step.url then
    return "No vendor page is recorded: follow the instructions above."
  end
  if not open_target(step.url, false) then
    return "Cannot open " .. step.url
  end
  if step.method == "vendor-app" then
    return "The vendor app was not found: opened its download page."
  end
  return "Opened the vendor page."
end

local WALK_TITLE = "ReaperPluginManager - Licence activation"
local WALK_W, WALK_H = 520, 320
local PAD, BUTTON_W, BUTTON_H = 16, 96, 28
local BUTTONS = { "Activate", "Done", "Later" }

-- The open walk-through, or nil: { steps, index, note, on_close, pressed,
-- was_down }.
local walk = nil

local function step_heading(step)
  if step.method == "vendor-app" then
    local name = step.app and step.app.name
    return name and ("Activate in " .. name) or "Activate in the vendor app"
  elseif step.method == "serial" then
    return "Activate with your serial number"
  elseif step.method == "sign-in" then
    return "Activate by signing in to your vendor account"
  end
  return "Activate"
end

local function step_names(step)
  local names = {}
  for _, entry in ipairs(step.entries) do
    names[#names + 1] = type(entry.name) == "string" and entry.name or tostring(entry.id)
  end
  return (#names > 1 and "Plugins: " or "Plugin: ") .. table.concat(names, ", ")
end

-- Splits `text` into lines no wider than `width` in the current font.
local function wrap(text, width)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local try = line == "" and word or line .. " " .. word
      if line ~= "" and gfx.measurestr(try) > width then
        lines[#lines + 1] = line
        line = word
      else
        line = try
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

local function draw_lines(lines, y)
  local _, h = gfx.measurestr("Ag")
  for _, line in ipairs(lines) do
    gfx.x, gfx.y = PAD, y
    gfx.drawstr(line)
    y = y + h + 2
  end
  return y
end

local function button_rects()
  local rects, x = {}, PAD
  local y = gfx.h - PAD - BUTTON_H
  for i, label in ipairs(BUTTONS) do
    rects[i] = { label = label, x = x, y = y, w = BUTTON_W, h = BUTTON_H }
    x = x + BUTTON_W + 8
  end
  return rects
end

local function hit(rects, mx, my)
  for _, r in ipairs(rects) do
    if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
      return r.label
    end
  end
  return nil
end

local function draw_walk(state, rects)
  local step = state.steps[state.index]
  local width = gfx.w - 2 * PAD
  gfx.set(0.15, 0.15, 0.16)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gfx.setfont(1, "Arial", 15)
  gfx.set(0.6, 0.6, 0.62)
  gfx.x, gfx.y = PAD, PAD
  gfx.drawstr(("Step %d of %d"):format(state.index, #state.steps))
  local y = PAD + 24

  gfx.setfont(2, "Arial", 18, string.byte("b"))
  gfx.set(0.92, 0.92, 0.94)
  y = draw_lines(wrap(step_heading(step), width), y) + 6

  gfx.setfont(1)
  y = draw_lines(wrap(step_names(step), width), y) + 8
  local instructions = #step.instructions > 0 and table.concat(step.instructions, "\n")
    or "No instructions were given for this plugin."
  gfx.set(0.8, 0.8, 0.82)
  y = draw_lines(wrap(instructions, width), y) + 8
  if state.note then
    gfx.set(0.55, 0.75, 0.95)
    draw_lines(wrap(state.note, width), y)
  end

  gfx.set(0.6, 0.6, 0.62)
  draw_lines(wrap("Done: the plugin is activated. Later: keep it flagged as pending.", width),
    gfx.h - PAD - BUTTON_H - 26)

  local hover = hit(rects, gfx.mouse_x, gfx.mouse_y)
  for _, r in ipairs(rects) do
    local shade = r.label == hover and 0.38 or 0.28
    gfx.set(shade, shade, shade + 0.02)
    gfx.rect(r.x, r.y, r.w, r.h, 1)
    gfx.set(0.92, 0.92, 0.94)
    local tw, th = gfx.measurestr(r.label)
    gfx.x, gfx.y = r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2
    gfx.drawstr(r.label)
  end
  gfx.update()
end

local function close_walk(state)
  if walk ~= state then
    return
  end
  walk = nil
  gfx.quit()
  if state.on_close then
    state.on_close()
  end
end

local function next_step(state)
  state.index = state.index + 1
  state.note = nil
  if state.index > #state.steps then
    close_walk(state)
  end
end

local function click(state, label)
  local step = state.steps[state.index]
  if label == "Activate" then
    state.note = activate_step(step)
  elseif label == "Done" then
    local ok, err = M.activation.clear(step.entries)
    if not ok then
      console("cannot update the activation-pending record: " .. one_line(err))
    end
    next_step(state)
  elseif label == "Later" then
    next_step(state)
  end
end

-- Opens the walk-through window for `entries` and calls `on_close` when it
-- closes. It takes over the script's one `gfx` window: an open walk-through
-- is closed first (its own `on_close` runs), and any other window of this
-- script is replaced.
local function open_walk(entries, on_close)
  if walk then
    close_walk(walk)
  end
  local state = { steps = walk_steps(entries), index = 1, on_close = on_close }
  if #state.steps == 0 then
    if on_close then
      on_close()
    end
    return
  end
  walk = state
  gfx.quit()
  gfx.init(WALK_TITLE, WALK_W, WALK_H)
  local function loop()
    if walk ~= state then
      return
    end
    local c = gfx.getchar()
    if c < 0 or c == 27 then
      close_walk(state)
      return
    end
    local rects = button_rects()
    local down = gfx.mouse_cap & 1 == 1
    if down and not state.was_down then
      state.pressed = hit(rects, gfx.mouse_x, gfx.mouse_y)
    elseif not down and state.was_down then
      local label = hit(rects, gfx.mouse_x, gfx.mouse_y)
      if label and label == state.pressed then
        click(state, label)
      end
      state.pressed = nil
    end
    state.was_down = down
    if walk ~= state then
      return
    end
    draw_walk(state, rects)
    reaper.defer(loop)
  end
  loop()
end

-- Called by plugin-installation after a run with the entries it installed:
-- records every entry whose activation method is not `none` as pending, then
-- opens the walk-through for them. `on_close` runs when the window closes,
-- so installation can then show its restart message; with nothing to
-- activate it runs at once. Done clears a step's entries from the pending
-- record; Later and closing the window leave them pending.
function M.activation.after_install(entries, on_close)
  local needed = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and M.activation.read(entry).method ~= "none" then
      needed[#needed + 1] = entry
    end
  end
  if #needed > 0 then
    local ok, err = M.activation.mark_pending(needed)
    if not ok then
      console("cannot update the activation-pending record: " .. one_line(err))
    end
  end
  open_walk(needed, on_close)
end

-- Reopens the walk-through for the catalogue entries `entries`, such as the
-- pending ones the summary window lists; `on_close` runs when it closes.
function M.activation.activate(entries, on_close)
  local list = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" then
      list[#list + 1] = entry
    end
  end
  open_walk(list, on_close)
end

---------------------------------------------------------------------------
-- Install run: the job for the platform helper, its detached launch, the
-- progress window that follows the status file, the summary, the hand-off
-- to licence activation, and the project reopened after REAPER restarts.
---------------------------------------------------------------------------

M.install = {}

local HELPER_START_TIMEOUT = 30
local REOPEN_KEY = "reopen"
local REOPEN_DELAY = 2
local INSTALL_TITLE = "ReaperPluginManager - Installing plugins"
local INSTALL_W = 520
local RESTART_MESSAGE = "Restart REAPER: it detects the new plugins at startup and this project reopens. "
  .. "If a plugin does not appear: Preferences > Plug-ins > VST > Re-scan."

local STATE_TEXT = {
  queued = "queued",
  download = "downloading…",
  verify = "verifying…",
  install = "installing…",
  ok = "installed",
  failed = "failed",
}

-- The run in progress, or nil: { items, status_path, netrc, project,
-- launched, heard, finished, ok, failed, note, window, scroll, pressed,
-- was_down }. Each item is { id, name, entry, installer, state, message }.
local install = nil

-- Starts the platform helper on `job`, `status` and `work` with the transfer
-- options `opts`, without waiting. Returns true when it started.
local function launch_helper(job, status, work, opts)
  if platform() == "windows" then
    local q = core.win_quote
    local cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "
      .. q(helpers_dir() .. "rpm-install.ps1")
      .. " -JobFile " .. q(job) .. " -StatusFile " .. q(status) .. " -WorkDir " .. q(work)
    if opts.netrc_path then
      cmd = cmd .. " -NetrcFile " .. q(opts.netrc_path)
    end
    if opts.tls and opts.tls ~= "" then
      cmd = cmd .. " -Tls " .. q(opts.tls)
    end
    if opts.insecure == true then
      cmd = cmd .. " -Insecure"
    end
    return reaper.ExecProcess(cmd, -2) ~= nil
  end
  local cmd = "/bin/bash " .. sh_quote(helpers_dir() .. "rpm-install.sh")
    .. " --job " .. sh_quote(job) .. " --status " .. sh_quote(status) .. " --workdir " .. sh_quote(work)
  if opts.netrc_path then
    cmd = cmd .. " --netrc " .. sh_quote(opts.netrc_path)
  end
  if opts.tls and opts.tls ~= "" then
    cmd = cmd .. " --tls " .. sh_quote(opts.tls)
  end
  if opts.insecure == true then
    cmd = cmd .. " --insecure"
  end
  return os.execute(cmd .. " >/dev/null 2>&1 &") == true
end

-- Ends the run's progress: every item without an outcome fails with
-- `message`, and the counts are taken.
local function finish_run(state, message)
  state.finished = true
  state.ok, state.failed = 0, 0
  for _, item in ipairs(state.items) do
    if item.state ~= "ok" and item.state ~= "failed" then
      item.state, item.message = "failed", message
    end
    if item.state == "ok" then
      state.ok = state.ok + 1
    else
      state.failed = state.failed + 1
    end
  end
end

-- Fails every item of a run whose helper never ran, with `reason`, and
-- removes the credentials file the helper would have deleted.
local function fail_run(state, reason)
  M.credentials.release_file(state.netrc)
  state.note = reason
  finish_run(state, reason)
end

-- Reads the status file into the items; at DONE the run is finished.
local function poll_status(state)
  local st = core.install.parse_status(read_file(state.status_path))
  if st.started or st.done or #st.order > 0 then
    state.heard = true
  end
  for _, item in ipairs(state.items) do
    local s = st.items[item.id]
    if s then
      item.state, item.message = s.state, s.message
    end
  end
  if st.done then
    finish_run(state, "the installer helper reported no result")
  elseif not state.heard and reaper.time_precise() - state.launched > HELPER_START_TIMEOUT then
    fail_run(state, "the installer helper did not start")
  end
end

local function install_heading(state)
  if not state.finished then
    if not state.heard then
      return "Starting the installer helper…"
    end
    return ("Installing %d plugin%s"):format(#state.items, #state.items == 1 and "" or "s")
  end
  return ("Install finished: %d installed, %d failed"):format(state.ok, state.failed)
end

-- The progress lines as { text, r, g, b, indent }: one per plugin, then its
-- failure message, wrapped to `width`.
local function install_rows(state, width)
  local rows = {}
  for _, item in ipairs(state.items) do
    local r, g, b = 0.85, 0.85, 0.87
    if item.state == "ok" then
      r, g, b = 0.45, 0.8, 0.45
    elseif item.state == "failed" then
      r, g, b = 0.92, 0.4, 0.4
    end
    for _, line in ipairs(wrap(item.name .. " — " .. (STATE_TEXT[item.state] or item.state), width)) do
      rows[#rows + 1] = { line, r, g, b, 0 }
    end
    if item.state == "failed" and item.message and item.message ~= "" then
      for _, line in ipairs(wrap(item.message, width - 16)) do
        rows[#rows + 1] = { line, 0.75, 0.5, 0.5, 16 }
      end
    end
  end
  return rows
end

local function close_button_rect()
  return { label = "Close", x = gfx.w - PAD - BUTTON_W, y = gfx.h - PAD - BUTTON_H, w = BUTTON_W, h = BUTTON_H }
end

local function draw_install(state, button)
  local width = gfx.w - 2 * PAD
  gfx.set(0.15, 0.15, 0.16)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gfx.setfont(2, "Arial", 18, string.byte("b"))
  gfx.set(0.92, 0.92, 0.94)
  local top = draw_lines(wrap(install_heading(state), width), PAD) + 4
  gfx.setfont(1, "Arial", 15)
  if state.note then
    gfx.set(0.92, 0.4, 0.4)
    top = draw_lines(wrap(state.note, width), top) + 4
  end
  top = top + 4

  local _, lh = gfx.measurestr("Ag")
  lh = lh + 2
  local bottom
  if button then
    bottom = button.y - 8
  else
    bottom = gfx.h - PAD - lh - 4
    gfx.set(0.6, 0.6, 0.62)
    draw_lines({ "Closing this window does not stop the install." }, gfx.h - PAD - lh)
  end

  local rows = install_rows(state, width)
  local visible = math.max(1, math.floor((bottom - top) / lh))
  local max_scroll = math.max(0, #rows - visible)
  if gfx.mouse_wheel ~= 0 then
    state.scroll = state.scroll - (gfx.mouse_wheel > 0 and 3 or -3)
    gfx.mouse_wheel = 0
  end
  state.scroll = math.max(0, math.min(state.scroll, max_scroll))
  for i = 1, visible do
    local row = rows[state.scroll + i]
    if not row then
      break
    end
    gfx.set(row[2], row[3], row[4])
    gfx.x, gfx.y = PAD + row[5], top + (i - 1) * lh
    gfx.drawstr(row[1])
  end

  if button then
    local hover = hit({ button }, gfx.mouse_x, gfx.mouse_y)
    local shade = hover and 0.38 or 0.28
    gfx.set(shade, shade, shade + 0.02)
    gfx.rect(button.x, button.y, button.w, button.h, 1)
    gfx.set(0.92, 0.92, 0.94)
    local tw, th = gfx.measurestr(button.label)
    gfx.x, gfx.y = button.x + (button.w - tw) / 2, button.y + (button.h - th) / 2
    gfx.drawstr(button.label)
  end
  gfx.update()
end

local function open_install_window(state)
  local h = math.max(220, math.min(520, 130 + 22 * #state.items))
  gfx.quit()
  gfx.init(INSTALL_TITLE, INSTALL_W, h)
  state.window = true
  state.pressed, state.was_down = nil, false
end

-- After the summary closes: the installed entries go to licence activation,
-- and when its walk-through closes, a run that installed anything records
-- the project to reopen and asks for the restart. The run ends there.
local function hand_off(state)
  local installed = {}
  for _, item in ipairs(state.items) do
    if item.state == "ok" then
      installed[#installed + 1] = item.entry
    end
  end
  local ended = false
  local function after_activation()
    if ended then
      return
    end
    ended = true
    if #installed > 0 then
      if state.project ~= "" then
        reaper.SetExtState(EXT_SECTION, REOPEN_KEY, state.project, true)
      end
      reaper.ShowMessageBox(RESTART_MESSAGE, INSTALL_TITLE, 0)
    end
    if install == state then
      install = nil
    end
  end
  local ok, err = pcall(M.activation.after_install, installed, after_activation)
  if not ok then
    console("licence activation failed: " .. one_line(err))
    after_activation()
  end
end

-- One defer cycle of the run: read the status file, then draw the window, or
-- reopen it for the summary once the run is finished. Closing the summary
-- hands over to licence activation.
local function install_cycle(state)
  if not state.finished then
    poll_status(state)
  end
  if not state.window then
    if not state.finished then
      return true
    end
    open_install_window(state)
  end
  local c = gfx.getchar()
  if c < 0 or c == 27 then
    gfx.quit()
    state.window = false
    if state.finished then
      hand_off(state)
      return false
    end
    return true
  end
  local button = state.finished and close_button_rect() or nil
  if button then
    local down = gfx.mouse_cap & 1 == 1
    if down and not state.was_down then
      state.pressed = hit({ button }, gfx.mouse_x, gfx.mouse_y)
    elseif not down and state.was_down then
      local label, pressed = hit({ button }, gfx.mouse_x, gfx.mouse_y), state.pressed
      state.pressed = nil
      if label and label == pressed then
        gfx.quit()
        state.window = false
        hand_off(state)
        return false
      end
    end
    state.was_down = down
  end
  draw_install(state, button)
  return true
end

local function install_loop(state)
  local function loop()
    if install ~= state then
      return
    end
    local ok, again = pcall(install_cycle, state)
    if not ok then
      console("install window failed: " .. one_line(again))
      if state.window then
        gfx.quit()
      end
      install = nil
      return
    end
    if again then
      reaper.defer(loop)
    end
  end
  loop()
end

-- Starts an install run for `entries`, the installable items of a check
-- (each { entry, installer }), and opens the progress window. Writes the job,
-- deletes the old status file, prepares the transfer options and launches
-- the platform helper without waiting. Returns true once the window is open
-- (a helper that cannot be launched is reported there and in the summary),
-- or false and the reason nothing started: a run already in progress,
-- nothing to install, no server, or the job or credentials file.
function M.install.start(entries)
  if install then
    return false, "An install is already running."
  end
  local items, by_id = {}, {}
  for _, g in ipairs(entries or {}) do
    if type(g) == "table" and type(g.entry) == "table" and type(g.installer) == "table" then
      local id = tostring(g.entry.id)
      if not by_id[id] then
        local name = type(g.entry.name) == "string" and g.entry.name or id
        local item = { id = id, name = name, entry = g.entry, installer = g.installer, state = "queued" }
        items[#items + 1] = item
        by_id[id] = item
      end
    end
  end
  if #items == 0 then
    return false, "There is nothing to install."
  end
  local p = platform()
  if p ~= "windows" and p ~= "macos" then
    return false, "Installing works only on Windows and macOS."
  end
  local base_url = M.settings.load().server.url
  if base_url == "" then
    return false, "No server is configured; run Setup."
  end

  local dir = M.data_dir()
  reaper.RecursiveCreateDirectory(dir, 0)
  local job, status, work = dir .. "job.tsv", dir .. "status.txt", dir .. "work"
  local f = io.open(job, "wb")
  local written = f and f:write(core.install.job_text(items, base_url))
  if f then
    f:close()
  end
  if not written then
    return false, "Cannot write the job file to " .. job
  end
  os.remove(status)
  if file_exists(status) then
    return false, "Cannot delete the old status file " .. status
  end
  reaper.RecursiveCreateDirectory(work, 0)
  local opts, err = M.transfer.helper_options()
  if not opts then
    return false, err
  end

  local state = {
    items = items,
    status_path = status,
    netrc = opts.netrc_path,
    project = M.check.project_path(),
    launched = reaper.time_precise(),
    heard = false,
    finished = false,
    scroll = 0,
  }
  install = state
  if not launch_helper(job, status, work, opts) then
    fail_run(state, "the installer helper could not be launched")
  end
  open_install_window(state)
  install_loop(state)
  return true
end

-- True from start until the run's summary, licence activation and restart
-- message are done.
function M.install.is_running()
  return install ~= nil
end

local reopen_waiting = false

local function same_path(a, b)
  if platform() == "windows" then
    return a:gsub("/", "\\"):lower() == b:gsub("/", "\\"):lower()
  end
  return a == b
end

-- Called once by the watcher at start: when a reopen record exists, waits
-- 2 s so REAPER finishes loading its own startup project, deletes the
-- record, and opens the recorded project unless it is the active one or the
-- file is gone. Does nothing without a record.
function M.install.reopen_after_restart()
  if reopen_waiting or reaper.GetExtState(EXT_SECTION, REOPEN_KEY) == "" then
    return
  end
  reopen_waiting = true
  local started = reaper.time_precise()
  local function wait()
    if reaper.time_precise() - started < REOPEN_DELAY then
      reaper.defer(wait)
      return
    end
    reopen_waiting = false
    local path = reaper.GetExtState(EXT_SECTION, REOPEN_KEY)
    reaper.DeleteExtState(EXT_SECTION, REOPEN_KEY, true)
    if path == "" or same_path(path, M.check.project_path()) or not file_exists(path) then
      return
    end
    reaper.Main_openProject(path)
  end
  reaper.defer(wait)
end

---------------------------------------------------------------------------
-- Project check: installed plugins, the saved project file, the catalogue
-- and the classification, assembled into one result.
---------------------------------------------------------------------------

M.check = {}

-- Returns every installed plugin as { name, ident }, from EnumInstalledFX.
function M.check.installed()
  local installed, i = {}, 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then
      break
    end
    installed[#installed + 1] = { name = name, ident = ident }
    i = i + 1
  end
  return installed
end

-- The file path of the project `proj` (nil for the current project), or ""
-- when it has never been saved or is not open.
function M.check.project_path(proj)
  if not proj then
    local _, path = reaper.EnumProjects(-1)
    return path or ""
  end
  local i = 0
  while true do
    local p, path = reaper.EnumProjects(i)
    if not p then
      return ""
    end
    if p == proj then
      return path or ""
    end
    i = i + 1
  end
end

-- Checks the project `proj` (nil for the current project) as saved on disk.
-- Returns one result whose `status` is:
-- - "not_saved": the project has no file path; `path` is "";
-- - "file_missing": the project file cannot be read; `path` names it;
-- - "checked": every other field is set:
--   `path`; `platform`; `total`, the number of distinct plugin references in
--   the project; `refs`, `missing` and `installed_refs`, the project's
--   references, those not installed and those installed; `groups`, the
--   classification (installable, no_installer, unknown, replace);
--   `pending`, the activation-pending entries among `installed_refs`;
--   `catalogue` (nil when none could be used), `source` ("server", "cache"
--   or "none") and `reason`, why the server catalogue was not used.
function M.check.run(proj)
  local path = M.check.project_path(proj)
  if path == "" then
    return { status = "not_saved", path = path }
  end
  local text = read_file(path)
  if not text then
    return { status = "file_missing", path = path }
  end

  local refs = core.scan_project(text)
  local installed = M.check.installed()
  local missing = core.missing(refs, installed)
  local is_missing = {}
  for _, ref in ipairs(missing) do
    is_missing[ref] = true
  end
  local installed_refs = {}
  for _, ref in ipairs(refs) do
    if not is_missing[ref] then
      installed_refs[#installed_refs + 1] = ref
    end
  end

  local catalogue, source, reason = M.catalogue.fetch()
  local lookup = catalogue and core.catalogue.index(catalogue) or nil
  local p = platform()
  return {
    status = "checked",
    path = path,
    platform = p,
    total = #refs,
    refs = refs,
    missing = missing,
    installed_refs = installed_refs,
    groups = core.classify(missing, installed, lookup, p),
    pending = M.activation.pending_for(installed_refs, catalogue),
    catalogue = catalogue,
    source = source,
    reason = reason,
  }
end

---------------------------------------------------------------------------
-- Summary window: one scrollable gfx window per check listing every finding
-- without truncation, the install hand-off and the activation reminders.
---------------------------------------------------------------------------

local SUMMARY_TITLE = "ReaperPluginManager - Project check"
local SUMMARY_W = 600
local ACTIVATE_W = 80
local SCROLLBAR_W = 6
local PLATFORM_NAMES = { windows = "Windows", macos = "macOS" }

-- gfx.getchar codes of the scrolling keys.
local KEY_UP, KEY_DOWN = 30064, 1685026670
local KEY_PGUP, KEY_PGDN = 1885828464, 1885824110
local KEY_HOME, KEY_END = 1752132965, 6647396

-- The open summary, or nil: { result, groups, show_unknown, scroll, page,
-- rects, gen, window, pressed, was_down }.
local summary = nil

local function text_of(v)
  return type(v) == "string" and v:match("^%s*(.-)%s*$") or ""
end

-- `Name (Vendor)` of a catalogue entry; the vendor is left out when empty.
local function entry_label(entry)
  local name = text_of(entry.name)
  if name == "" then
    name = tostring(entry.id)
  end
  local vendor = text_of(entry.vendor)
  return vendor ~= "" and (name .. " (" .. vendor .. ")") or name
end

-- `Name (Vendor) [FORMAT] ×instances` of a classified reference item.
local function ref_label(item)
  local _, base = core.split_name(item.ref.name)
  if base == "" then
    base = tostring(item.ref.name)
  end
  local format = item.format and item.format:upper() or "?"
  return ("%s [%s] ×%d"):format(base, format, item.ref.count or 1)
end

-- The window's groups for the checked `result`, each { title, items }, an
-- item being { text, entry } with `entry` set only on an activation-pending
-- item. Empty groups are left out, and "Not in the catalogue" unless
-- `show_unknown`.
local function summary_groups(result, show_unknown)
  local groups = {}
  local function add(title, items)
    if #items > 0 then
      groups[#groups + 1] = { title = ("%s (%d)"):format(title, #items), items = items }
    end
  end
  local g = result.groups

  local to_install = {}
  for _, it in ipairs(g.installable) do
    local note = text_of(it.entry.note)
    local text = entry_label(it.entry)
    to_install[#to_install + 1] = { text = note ~= "" and (text .. " — " .. note) or text }
  end
  add("To install", to_install)

  local no_installer, seen = {}, {}
  for _, it in ipairs(g.no_installer) do
    if not seen[it.entry] then
      seen[it.entry] = true
      no_installer[#no_installer + 1] = { text = entry_label(it.entry) }
    end
  end
  add("No installer for " .. (PLATFORM_NAMES[result.platform] or "this platform"), no_installer)

  if show_unknown then
    local unknown = {}
    for _, it in ipairs(g.unknown) do
      unknown[#unknown + 1] = { text = ref_label(it) }
    end
    add("Not in the catalogue", unknown)
  end

  local replace = {}
  local platform_name = PLATFORM_NAMES[result.platform] or "this system"
  for _, it in ipairs(g.replace) do
    local why = it.reason == "present" and "the plugin is installed in another format"
      or ("this format does not load on " .. platform_name)
    replace[#replace + 1] = { text = ref_label(it) .. " — " .. why }
  end
  add("Instances to replace by hand", replace)

  local pending = {}
  for _, entry in ipairs(result.pending or {}) do
    pending[#pending + 1] = { text = entry_label(entry), entry = entry }
  end
  add("Activation pending", pending)
  return groups
end

local function summary_heading(result)
  local name = result.path:match("([^/\\]+)$") or result.path
  local missing = #result.missing
  if missing == 0 then
    return name .. ": every plugin is installed"
  end
  return ("%s: %d of %d plugins not installed"):format(name, missing, result.total)
end

-- The banner line when the server catalogue was not used, or nil.
local function summary_banner(result)
  local reason = result.reason and one_line(result.reason) or "no reason was given"
  if result.source == "cache" then
    return "The server catalogue could not be used, so the cached one was. " .. reason
  elseif result.source == "none" then
    return "No catalogue is available, so nothing can be installed. " .. reason
  end
  return nil
end

-- The scrolling rows of `groups` wrapped to `width`, each { text, indent,
-- header, entry }: a group's title, then its items, a blank row between
-- groups. `entry` marks the first row of an activation-pending item, which
-- carries an Activate button.
local function summary_rows(groups, width)
  local rows = {}
  for gi, group in ipairs(groups) do
    if gi > 1 then
      rows[#rows + 1] = { text = "" }
    end
    rows[#rows + 1] = { text = group.title, header = true, indent = 0 }
    for _, item in ipairs(group.items) do
      local w = width - 12 - (item.entry and ACTIVATE_W + 8 or 0)
      for i, line in ipairs(wrap(item.text, w)) do
        rows[#rows + 1] = { text = line, indent = i == 1 and 12 or 24, entry = i == 1 and item.entry or nil }
      end
    end
  end
  return rows
end

-- The bottom buttons, right-aligned: "Install N plugins" when anything is
-- installable, then "Close".
local function summary_buttons(state)
  local labels = {}
  local n = #state.result.groups.installable
  if n > 0 then
    labels[#labels + 1] = { key = "install", label = ("Install %d plugin%s"):format(n, n == 1 and "" or "s") }
  end
  labels[#labels + 1] = { key = "close", label = "Close" }
  local rects, x = {}, gfx.w - PAD
  for i = #labels, 1, -1 do
    local w = math.max(BUTTON_W, gfx.measurestr(labels[i].label) + 24)
    x = x - w
    rects[#rects + 1] = { key = labels[i].key, label = labels[i].label, x = x, y = gfx.h - PAD - BUTTON_H, w = w, h = BUTTON_H }
    x = x - 8
  end
  return rects
end

local function hit_rect(rects, mx, my)
  for _, r in ipairs(rects or {}) do
    if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
      return r
    end
  end
  return nil
end

local function draw_button(r, hover)
  local shade = hover and 0.38 or 0.28
  gfx.set(shade, shade, shade + 0.02)
  gfx.rect(r.x, r.y, r.w, r.h, 1)
  gfx.set(0.92, 0.92, 0.94)
  local tw, th = gfx.measurestr(r.label)
  gfx.x, gfx.y = r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2
  gfx.drawstr(r.label)
end

-- Draws the window and returns its clickable rectangles: the bottom buttons
-- and the Activate buttons of the visible rows.
local function draw_summary(state)
  local width = gfx.w - 2 * PAD
  gfx.set(0.15, 0.15, 0.16)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gfx.setfont(2, "Arial", 18, string.byte("b"))
  gfx.set(0.92, 0.92, 0.94)
  local top = draw_lines(wrap(summary_heading(state.result), width), PAD) + 4
  gfx.setfont(1, "Arial", 15)
  local banner = summary_banner(state.result)
  if banner then
    gfx.set(0.95, 0.75, 0.35)
    top = draw_lines(wrap(banner, width), top) + 4
  end
  top = top + 4

  local rects = summary_buttons(state)
  local bottom = rects[1].y - 8
  local _, th = gfx.measurestr("Ag")
  local lh = th + 6
  local list_w = width - SCROLLBAR_W - 6
  local rows = summary_rows(state.groups, list_w)
  local visible = math.max(1, math.floor((bottom - top) / lh))
  local max_scroll = math.max(0, #rows - visible)
  state.page = visible
  state.scroll = math.max(0, math.min(state.scroll, max_scroll))

  local mx, my = gfx.mouse_x, gfx.mouse_y
  for i = 1, visible do
    local row = rows[state.scroll + i]
    if not row then
      break
    end
    local y = top + (i - 1) * lh
    if row.header then
      gfx.setfont(3, "Arial", 15, string.byte("b"))
      gfx.set(0.92, 0.92, 0.94)
    else
      gfx.setfont(1)
      gfx.set(0.8, 0.8, 0.82)
    end
    gfx.x, gfx.y = PAD + (row.indent or 0), y + 3
    gfx.drawstr(row.text)
    gfx.setfont(1)
    if row.entry then
      local r = { key = "activate:" .. (state.scroll + i), entry = row.entry, label = "Activate",
        x = PAD + list_w - ACTIVATE_W, y = y, w = ACTIVATE_W, h = lh - 1 }
      rects[#rects + 1] = r
      draw_button(r, hit_rect({ r }, mx, my) ~= nil)
    end
  end

  if max_scroll > 0 then
    local track_h = visible * lh
    local thumb_h = math.max(20, track_h * visible / #rows)
    local thumb_y = top + (track_h - thumb_h) * state.scroll / max_scroll
    local x = PAD + width - SCROLLBAR_W
    gfx.set(0.22, 0.22, 0.24)
    gfx.rect(x, top, SCROLLBAR_W, track_h, 1)
    gfx.set(0.45, 0.45, 0.48)
    gfx.rect(x, thumb_y, SCROLLBAR_W, thumb_h, 1)
  end

  for _, r in ipairs(rects) do
    if not r.entry then
      draw_button(r, hit_rect({ r }, mx, my) ~= nil)
    end
  end
  gfx.update()
  return rects
end

local function open_summary_window(state)
  local n = 0
  for _, group in ipairs(state.groups) do
    n = n + #group.items + 2
  end
  local h = math.max(260, math.min(560, 150 + 22 * n))
  gfx.quit()
  gfx.init(SUMMARY_TITLE, SUMMARY_W, h)
  state.window = true
  state.rects, state.pressed, state.was_down = {}, nil, false
end

local function close_summary(state)
  if state.window then
    gfx.quit()
    state.window = false
  end
  if summary == state then
    summary = nil
  end
end

local summary_loop

-- After the walk-through opened from the summary closes: the pending list is
-- asked again, so entries marked Done leave it, and the window reopens unless
-- another check replaced it or nothing is left to list.
local function reopen_summary(state)
  if summary ~= state then
    return
  end
  state.result.pending = M.activation.pending_for(state.result.installed_refs, state.result.catalogue)
  state.groups = summary_groups(state.result, state.show_unknown)
  if #state.groups == 0 then
    summary = nil
    return
  end
  open_summary_window(state)
  summary_loop(state)
end

-- Acts on a clicked rectangle. Returns false when the summary's loop ends:
-- the window was closed or handed to the install run or the walk-through.
local function summary_click(state, r)
  if r.key == "close" then
    close_summary(state)
    return false
  elseif r.key == "install" then
    close_summary(state)
    local ok, err = M.install.start(state.result.groups.installable)
    if not ok then
      reaper.ShowMessageBox(err, SUMMARY_TITLE, 0)
    end
    return false
  elseif r.entry then
    state.window = false
    local ok, err = pcall(M.activation.activate, { r.entry }, function()
      reopen_summary(state)
    end)
    if not ok then
      console("licence activation failed: " .. one_line(err))
      reopen_summary(state)
    end
    return false
  end
  return true
end

-- One defer cycle: keys, wheel and clicks, then the drawing. Returns false
-- when the loop ends.
local function summary_cycle(state)
  local c = gfx.getchar()
  if c < 0 or c == 27 then
    close_summary(state)
    return false
  end
  local page = math.max(1, (state.page or 1) - 1)
  if c == KEY_UP then
    state.scroll = state.scroll - 1
  elseif c == KEY_DOWN then
    state.scroll = state.scroll + 1
  elseif c == KEY_PGUP then
    state.scroll = state.scroll - page
  elseif c == KEY_PGDN then
    state.scroll = state.scroll + page
  elseif c == KEY_HOME then
    state.scroll = 0
  elseif c == KEY_END then
    state.scroll = math.huge
  end
  if gfx.mouse_wheel ~= 0 then
    state.scroll = state.scroll - (gfx.mouse_wheel > 0 and 3 or -3)
    gfx.mouse_wheel = 0
  end

  local down = gfx.mouse_cap & 1 == 1
  if down and not state.was_down then
    local r = hit_rect(state.rects, gfx.mouse_x, gfx.mouse_y)
    state.pressed = r and r.key
  elseif not down and state.was_down then
    local r, pressed = hit_rect(state.rects, gfx.mouse_x, gfx.mouse_y), state.pressed
    state.pressed = nil
    state.was_down = false
    if r and r.key == pressed and not summary_click(state, r) then
      return false
    end
  end
  state.was_down = down
  state.rects = draw_summary(state)
  return true
end

summary_loop = function(state)
  state.gen = (state.gen or 0) + 1
  local gen = state.gen
  local function loop()
    if summary ~= state or state.gen ~= gen or not state.window then
      return
    end
    local ok, again = pcall(summary_cycle, state)
    if not ok then
      console("summary window failed: " .. one_line(again))
      close_summary(state)
      return
    end
    if again and summary == state and state.gen == gen then
      reaper.defer(loop)
    end
  end
  loop()
end

-- Opens the summary window for `result`, a "checked" result of `run`,
-- listing every finding without truncation, grouped: to install, no
-- installer for this platform, not in the catalogue (only when
-- `notify_unknown` is on), instances to replace by hand, activation pending
-- (each with an Activate button that reopens the walk-through for that
-- entry). A banner states when the server catalogue was not used and why.
-- "Install N plugins" hands the installable entries to `install.start` and
-- closes the window. It takes over the script's one `gfx` window: an open
-- summary or walk-through is closed first. Returns true when the window
-- opened, false when the result holds nothing to list.
function M.check.show(result)
  if type(result) ~= "table" or result.status ~= "checked" then
    return false
  end
  local show_unknown = M.settings.load().check.notify_unknown
  local groups = summary_groups(result, show_unknown)
  if #groups == 0 then
    return false
  end
  local state = { result = result, groups = groups, show_unknown = show_unknown, scroll = 0 }
  summary = state
  if walk then
    close_walk(walk)
  end
  open_summary_window(state)
  summary_loop(state)
  return true
end

return M
