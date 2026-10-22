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

return M
