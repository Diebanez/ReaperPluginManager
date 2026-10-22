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

return M
