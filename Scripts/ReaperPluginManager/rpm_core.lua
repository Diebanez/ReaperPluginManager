-- rpm_core.lua: the pure logic of ReaperPluginManager.
-- No reaper.* calls, so it runs under plain Lua 5.4 outside REAPER.

local M = {}

local BOM = "\239\187\191"

local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

-- Splits text into lines, accepting LF and CRLF endings.
local function split_lines(text)
  local lines, pos = {}, 1
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    local line
    if nl then
      line = text:sub(pos, nl - 1)
      pos = nl + 1
    else
      line = text:sub(pos)
      pos = #text + 1
    end
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    lines[#lines + 1] = line
  end
  return lines
end

---------------------------------------------------------------------------
-- INI
---------------------------------------------------------------------------

M.ini = {}

-- A comment starts at a `;` or `#` that opens the line or follows whitespace,
-- so a `#` inside a value such as a URL fragment is kept.
local function split_comment(s)
  local p = 1
  while true do
    p = s:find("[;#]", p)
    if not p then
      return s, ""
    end
    if p == 1 or s:sub(p - 1, p - 1):match("%s") then
      return s:sub(1, p - 1), s:sub(p)
    end
    p = p + 1
  end
end

-- Returns { section = name } for a header, { key, value } for a pair, or nil
-- for a blank, comment-only or unrecognised line; the comment as second value.
local function parse_line(raw)
  local content, comment = split_comment(raw)
  content = trim(content)
  if content == "" then
    return nil, comment
  end
  local section = content:match("^%[(.-)%]$")
  if section then
    return { section = trim(section):lower() }, comment
  end
  local key, value = content:match("^([^=]-)=(.*)$")
  if key then
    key = trim(key)
    if key ~= "" then
      return { key = key, value = trim(value) }, comment
    end
  end
  return nil, comment
end

-- Parses INI text into { [section] = { [key] = value } }. Section and key
-- names are lowercased; keys before any section header go under "".
-- Never raises: anything but a string yields an empty table.
function M.ini.parse(text)
  local data = {}
  if type(text) ~= "string" then
    return data
  end
  if text:sub(1, 3) == BOM then
    text = text:sub(4)
  end
  local section = ""
  for _, raw in ipairs(split_lines(text)) do
    local item = parse_line(raw)
    if item then
      if item.section then
        section = item.section
        data[section] = data[section] or {}
      else
        data[section] = data[section] or {}
        data[section][item.key:lower()] = item.value
      end
    end
  end
  return data
end

local function encode_value(v)
  if v == true then
    return "1"
  elseif v == false then
    return "0"
  end
  return (tostring(v):gsub("[\r\n]", " "))
end

-- Returns `text` with `changes` applied, keeping every other line as it is:
-- comments, blank lines, unknown keys, the BOM and the line ending style.
-- `changes` is an ordered list of { section, key, value }; a boolean value is
-- written as 1/0 and a nil value is skipped. An existing key is rewritten in
-- place, keeping its trailing comment; a new key goes after the last pair of
-- its section; a new section is appended at the end of the file.
function M.ini.update(text, changes)
  text = type(text) == "string" and text or ""
  local bom = ""
  if text:sub(1, 3) == BOM then
    bom = BOM
    text = text:sub(4)
  end
  local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"

  local order, pending, lookup = {}, {}, {}
  for _, c in ipairs(changes or {}) do
    if c[3] ~= nil then
      local s, k = c[1]:lower(), c[2]
      if not lookup[s] then
        lookup[s], pending[s] = {}, {}
        order[#order + 1] = s
      end
      local e = lookup[s][k:lower()]
      if e then
        e.value = encode_value(c[3])
      else
        e = { key = k, value = encode_value(c[3]) }
        lookup[s][k:lower()] = e
        pending[s][#pending[s] + 1] = e
      end
    end
  end

  local out, last, seen = {}, {}, {}
  local section = ""
  for _, raw in ipairs(split_lines(text)) do
    local item, comment = parse_line(raw)
    local line = raw
    if item and item.section then
      section = item.section
      seen[section] = true
    elseif item then
      local e = lookup[section] and lookup[section][item.key:lower()]
      if e then
        e.written = true
        line = item.key .. "=" .. e.value
        if comment ~= "" then
          line = line .. " " .. comment
        end
      end
    end
    out[#out + 1] = line
    if item then
      last[section] = #out
    end
  end

  local inserts = {}
  for _, s in ipairs(order) do
    local lines = {}
    for _, e in ipairs(pending[s]) do
      if not e.written then
        lines[#lines + 1] = e.key .. "=" .. e.value
      end
    end
    if #lines > 0 then
      if seen[s] then
        inserts[#inserts + 1] = { at = last[s], lines = lines }
      else
        if #out > 0 and trim(out[#out]) ~= "" then
          out[#out + 1] = ""
        end
        out[#out + 1] = "[" .. s .. "]"
        for _, l in ipairs(lines) do
          out[#out + 1] = l
        end
      end
    end
  end
  table.sort(inserts, function(a, b) return a.at > b.at end)
  for _, ins in ipairs(inserts) do
    for i = #ins.lines, 1, -1 do
      table.insert(out, ins.at + 1, ins.lines[i])
    end
  end

  if #out == 0 then
    return bom
  end
  return bom .. table.concat(out, eol) .. eol
end

---------------------------------------------------------------------------
-- Settings (config.ini)
---------------------------------------------------------------------------

M.settings = {}

local TLS_LEVELS = { required = true, try = true, off = true }

-- Each decoder returns the setting's value, or nil when the raw text is
-- invalid and the default applies.
local DECODE = {
  string = function(v)
    return v
  end,
  url = function(v)
    if v ~= "" and v:sub(-1) ~= "/" then
      return v .. "/"
    end
    return v
  end,
  tls = function(v)
    v = v:lower()
    if TLS_LEVELS[v] then
      return v
    end
  end,
  switch = function(v)
    if v == "1" then
      return true
    elseif v == "0" then
      return false
    end
  end,
}

-- The settings file schema, in file order. Switches are booleans in the
-- settings value and 1/0 in the file.
local SCHEMA = {
  { section = "server", keys = {
    { name = "url", kind = "url", default = "" },
    { name = "user", kind = "string", default = "" },
    { name = "tls", kind = "tls", default = "required" },
    { name = "insecure", kind = "switch", default = false },
  } },
  { section = "install", keys = {
    { name = "vst2_dir", kind = "string", default = "" },
  } },
  { section = "check", keys = {
    { name = "auto", kind = "switch", default = true },
    { name = "notify_unknown", kind = "switch", default = true },
  } },
}

-- Returns a complete settings value holding every default.
function M.settings.defaults()
  local s = {}
  for _, sec in ipairs(SCHEMA) do
    s[sec.section] = {}
    for _, k in ipairs(sec.keys) do
      s[sec.section][k.name] = k.default
    end
  end
  return s
end

-- Builds a complete settings value from parsed INI data, falling back to the
-- default for every missing or invalid key.
function M.settings.from_ini(data)
  local s = M.settings.defaults()
  if type(data) ~= "table" then
    return s
  end
  for _, sec in ipairs(SCHEMA) do
    local raw_sec = data[sec.section]
    if type(raw_sec) == "table" then
      for _, k in ipairs(sec.keys) do
        local raw = raw_sec[k.name]
        if type(raw) == "string" then
          local v = DECODE[k.kind](raw)
          if v ~= nil then
            s[sec.section][k.name] = v
          end
        end
      end
    end
  end
  return s
end

function M.settings.from_text(text)
  return M.settings.from_ini(M.ini.parse(text))
end

-- Reads the settings file at `path`. Never raises: a missing or unreadable
-- file yields all defaults.
function M.settings.load(path)
  local ok, s = pcall(function()
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local text = f:read("a")
    f:close()
    return M.settings.from_text(text)
  end)
  if ok and s then
    return s
  end
  return M.settings.defaults()
end

-- Returns the settings file text `text` with the keys present in `values` (a
-- settings value, complete or partial) written over it; every key it does not
-- name is kept. Used by setup-action to save the settings file.
function M.settings.to_ini(text, values)
  local changes = {}
  for _, sec in ipairs(SCHEMA) do
    local v = type(values) == "table" and values[sec.section]
    if type(v) == "table" then
      for _, k in ipairs(sec.keys) do
        if v[k.name] ~= nil then
          changes[#changes + 1] = { sec.section, k.name, v[k.name] }
        end
      end
    end
  end
  return M.ini.update(text, changes)
end

return M
