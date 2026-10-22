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

---------------------------------------------------------------------------
-- JSON
---------------------------------------------------------------------------

M.json = {}

-- The value JSON `null` decodes to, and the one that encodes as `null`.
M.json.null = setmetatable({}, { __tostring = function() return "null" end })

-- Decoded arrays and objects carry one of these metatables, so an empty one
-- encodes back as the same kind.
local ARRAY_MT, OBJECT_MT = {}, {}

-- Marks `t` (a new table when nil) as a JSON array for the encoder.
function M.json.array(t)
  return setmetatable(t or {}, ARRAY_MT)
end

-- Marks `t` (a new table when nil) as a JSON object for the encoder.
function M.json.object(t)
  return setmetatable(t or {}, OBJECT_MT)
end

-- Decoding errors are raised as { pos, msg } and returned by json.decode.
local function parse_fail(pos, msg)
  error({ pos = pos, msg = msg }, 0)
end

local function parse_expected(text, pos, what)
  if pos > #text then
    parse_fail(pos, "unexpected end of input")
  end
  parse_fail(pos, "expected " .. what .. ", found '" .. text:sub(pos, pos) .. "'")
end

local function skip_ws(text, pos)
  return text:find("[^ \t\r\n]", pos) or #text + 1
end

local UNESCAPE = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

-- Reads the four hex digits of the `\uXXXX` escape starting at `pos`.
local function read_hex4(text, pos)
  local hex = text:match("^\\u(%x%x%x%x)", pos)
  if not hex then
    parse_fail(pos, "invalid \\u escape")
  end
  return tonumber(hex, 16)
end

-- Decodes the `\uXXXX` escape at `pos`, joining a surrogate pair into one
-- code point. Returns the code point and the position after the escape(s).
local function read_codepoint(text, pos)
  local cp = read_hex4(text, pos)
  if cp >= 0xD800 and cp <= 0xDBFF then
    local lo = text:match("^\\u", pos + 6) and read_hex4(text, pos + 6)
    if not lo or lo < 0xDC00 or lo > 0xDFFF then
      parse_fail(pos, "unpaired surrogate")
    end
    return 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00), pos + 12
  elseif cp >= 0xDC00 and cp <= 0xDFFF then
    parse_fail(pos, "unpaired surrogate")
  end
  return cp, pos + 6
end

-- `pos` is at the opening quote.
local function decode_string(text, pos)
  local parts, i = {}, pos + 1
  while true do
    local j = text:find('[\0-\31\\"]', i)
    if not j then
      parse_fail(pos, "unterminated string")
    end
    parts[#parts + 1] = text:sub(i, j - 1)
    local c = text:sub(j, j)
    if c == '"' then
      return table.concat(parts), j + 1
    elseif c == "\\" then
      local e = text:sub(j + 1, j + 1)
      if e == "u" then
        local cp
        cp, i = read_codepoint(text, j)
        parts[#parts + 1] = utf8.char(cp)
      elseif UNESCAPE[e] then
        parts[#parts + 1] = UNESCAPE[e]
        i = j + 2
      elseif e == "" then
        parse_fail(pos, "unterminated string")
      else
        parse_fail(j, "invalid escape '\\" .. e .. "'")
      end
    else
      parse_fail(j, "control character in string")
    end
  end
end

-- Follows the JSON number grammar strictly. A number with no fraction or
-- exponent decodes as a Lua integer when it fits, otherwise as a float.
local function decode_number(text, pos)
  local int = text:match("^-?%d+", pos)
  if not int or int:match("^-?0%d") then
    parse_fail(pos, "invalid number")
  end
  local e = pos + #int
  local frac = text:match("^%.%d*", e)
  if frac then
    if #frac == 1 then
      parse_fail(pos, "invalid number")
    end
    e = e + #frac
  end
  local exp = text:match("^[eE][+-]?%d*", e)
  if exp then
    if not exp:match("%d$") then
      parse_fail(pos, "invalid number")
    end
    e = e + #exp
  end
  return tonumber(text:sub(pos, e - 1)), e
end

local LITERALS = { ["true"] = true, ["false"] = false, null = M.json.null }

local decode_value

local function decode_array(text, pos)
  local arr = setmetatable({}, ARRAY_MT)
  pos = skip_ws(text, pos + 1)
  if text:sub(pos, pos) == "]" then
    return arr, pos + 1
  end
  while true do
    local v
    v, pos = decode_value(text, pos)
    arr[#arr + 1] = v
    pos = skip_ws(text, pos)
    local c = text:sub(pos, pos)
    if c == "]" then
      return arr, pos + 1
    elseif c ~= "," then
      parse_expected(text, pos, "',' or ']'")
    end
    pos = pos + 1
  end
end

local function decode_object(text, pos)
  local obj = setmetatable({}, OBJECT_MT)
  pos = skip_ws(text, pos + 1)
  if text:sub(pos, pos) == "}" then
    return obj, pos + 1
  end
  while true do
    if text:sub(pos, pos) ~= '"' then
      parse_expected(text, pos, "a string key")
    end
    local key, v
    key, pos = decode_string(text, pos)
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) ~= ":" then
      parse_expected(text, pos, "':'")
    end
    v, pos = decode_value(text, pos + 1)
    obj[key] = v
    pos = skip_ws(text, pos)
    local c = text:sub(pos, pos)
    if c == "}" then
      return obj, pos + 1
    elseif c ~= "," then
      parse_expected(text, pos, "',' or '}'")
    end
    pos = skip_ws(text, pos + 1)
  end
end

decode_value = function(text, pos)
  pos = skip_ws(text, pos)
  local c = text:sub(pos, pos)
  if c == "{" then
    return decode_object(text, pos)
  elseif c == "[" then
    return decode_array(text, pos)
  elseif c == '"' then
    return decode_string(text, pos)
  elseif c:match("^[-%d]$") then
    return decode_number(text, pos)
  end
  for word, value in pairs(LITERALS) do
    if text:sub(pos, pos + #word - 1) == word then
      return value, pos + #word
    end
  end
  parse_expected(text, pos, "a value")
end

local function decode_document(text)
  local value, pos = decode_value(text, 1)
  pos = skip_ws(text, pos)
  if pos <= #text then
    parse_fail(pos, "unexpected trailing characters")
  end
  return value
end

-- Parses JSON text, tolerating a leading UTF-8 BOM. Returns the value, or nil
-- and an error naming the byte position in `text`. Arrays and objects come
-- back marked (json.array / json.object) and `null` as json.null. Never
-- raises.
function M.json.decode(text)
  if type(text) ~= "string" then
    return nil, "json: input is not a string"
  end
  local offset = 0
  if text:sub(1, 3) == BOM then
    text, offset = text:sub(4), 3
  end
  local ok, result = pcall(decode_document, text)
  if ok then
    return result
  elseif type(result) == "table" then
    return nil, ("json: %s at byte %d"):format(result.msg, result.pos + offset)
  end
  return nil, "json: " .. tostring(result)
end

-- Object keys in this order first, then any other key alphabetically.
local KEY_RANK = {}
for i, k in ipairs({ "id", "name", "vendor", "note", "match", "installers",
    "file", "type", "args", "sha256", "dest", "activation" }) do
  KEY_RANK[k] = i
end

-- Keys whose value the catalogue schema defines as an array, so an unmarked
-- empty table under them encodes as `[]`; elsewhere it encodes as `{}`.
local ARRAY_KEYS = { plugins = true, match = true }

local function key_before(a, b)
  local ra, rb = KEY_RANK[a], KEY_RANK[b]
  if ra and rb then
    return ra < rb
  elseif ra or rb then
    return ra ~= nil
  end
  return a < b
end

local function encode_fail(msg)
  error({ msg = msg }, 0)
end

local ESCAPE = {
  ['"'] = '\\"', ["\\"] = "\\\\",
  ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
  local body = s:gsub('[\0-\31\\"]', function(c)
    return ESCAPE[c] or ("\\u%04x"):format(c:byte())
  end)
  return '"' .. body .. '"'
end

-- Integers stay integers; a float takes the shortest form that reads back
-- equal and keeps a fraction or exponent, so it decodes as a float again.
local function encode_number(n)
  if math.type(n) == "integer" then
    return ("%d"):format(n)
  elseif n ~= n or n == math.huge or n == -math.huge then
    encode_fail("cannot encode " .. tostring(n))
  end
  local s
  for precision = 15, 17 do
    s = ("%." .. precision .. "g"):format(n):gsub(",", ".")
    if tonumber(s) == n then
      break
    end
  end
  if not s:find("[.e]") then
    s = s .. ".0"
  end
  return s
end

-- Returns the length of `t` as an array, or fails when it has any key but
-- 1..n.
local function array_length(t)
  local n, count = #t, 0
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 or k > n then
      encode_fail("an array has a key that is not 1..n")
    end
    count = count + 1
  end
  if count ~= n then
    encode_fail("an array has holes")
  end
  return n
end

local function is_array(t, key)
  local mt = getmetatable(t)
  if mt == ARRAY_MT then
    return true
  elseif mt == OBJECT_MT then
    return false
  elseif next(t) == nil then
    return ARRAY_KEYS[key] == true
  end
  return t[1] ~= nil
end

-- Appends the encoding of `v` to `buf`; `key` is the object key `v` sits
-- under, if any, and `indent` the indentation of its line.
local function encode_into(v, key, indent, buf)
  local tv = type(v)
  if v == M.json.null then
    buf[#buf + 1] = "null"
  elseif tv == "string" then
    buf[#buf + 1] = encode_string(v)
  elseif tv == "number" then
    buf[#buf + 1] = encode_number(v)
  elseif tv == "boolean" then
    buf[#buf + 1] = tostring(v)
  elseif tv == "table" then
    local inner = indent .. "  "
    if is_array(v, key) then
      local n = array_length(v)
      if n == 0 then
        buf[#buf + 1] = "[]"
        return
      end
      buf[#buf + 1] = "[\n"
      for i = 1, n do
        buf[#buf + 1] = inner
        encode_into(v[i], nil, inner, buf)
        buf[#buf + 1] = i < n and ",\n" or "\n"
      end
      buf[#buf + 1] = indent .. "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then
          encode_fail("an object has a key that is not a string")
        end
        keys[#keys + 1] = k
      end
      if #keys == 0 then
        buf[#buf + 1] = "{}"
        return
      end
      table.sort(keys, key_before)
      buf[#buf + 1] = "{\n"
      for i, k in ipairs(keys) do
        buf[#buf + 1] = inner .. encode_string(k) .. ": "
        encode_into(v[k], k, inner, buf)
        buf[#buf + 1] = i < #keys and ",\n" or "\n"
      end
      buf[#buf + 1] = indent .. "}"
    end
  else
    encode_fail("cannot encode a " .. tv)
  end
end

-- Encodes `value` as JSON indented by two spaces, with no trailing newline.
-- Object keys follow KEY_RANK, then alphabetical order. Returns the text, or
-- nil and an error for a value JSON cannot hold (a function, NaN, a table
-- mixing array and object keys). Never raises.
function M.json.encode(value)
  local buf = {}
  local ok, err = pcall(encode_into, value, nil, "", buf)
  if not ok then
    return nil, "json: " .. (type(err) == "table" and err.msg or tostring(err))
  end
  return table.concat(buf)
end

---------------------------------------------------------------------------
-- Project scanner (.rpp)
---------------------------------------------------------------------------

-- The chunk tags that open a plugin reference; `<JS` is not one of them.
local PLUGIN_TAGS = { VST = true, AU = true, CLAP = true, LV2 = true, DX = true }

local QUOTES = { ['"'] = true, ["'"] = true, ["`"] = true }

-- Reads up to `max` tokens of an .rpp line: tokens are separated by spaces,
-- and one that opens with ", ' or ` runs to the next same quote. Returns the
-- tokens, or nil when a quoted token among them is never closed.
local function rpp_tokens(line, max)
  local tokens, pos = {}, 1
  while #tokens < max do
    pos = line:find("[^ \t]", pos)
    if not pos then
      break
    end
    local q = line:sub(pos, pos)
    if QUOTES[q] then
      local close = line:find(q, pos + 1, true)
      if not close then
        return nil
      end
      tokens[#tokens + 1] = line:sub(pos + 1, close - 1)
      pos = close + 1
    else
      local stop = line:find("[ \t]", pos) or #line + 1
      tokens[#tokens + 1] = line:sub(pos, stop - 1)
      pos = stop
    end
  end
  return tokens
end

-- Returns every plugin reference in the project file text: each distinct
-- (tag, display name, identifier) once, as { tag, name, ident, count }, in
-- order of first appearance. A line whose trimmed text opens with `<VST `,
-- `<AU `, `<CLAP `, `<LV2 ` or `<DX ` is a reference wherever it sits (track
-- chains, master, take FX, containers). A malformed line is skipped. Never
-- raises.
function M.scan_project(text)
  local refs, index = {}, {}
  if type(text) ~= "string" then
    return refs
  end
  for _, raw in ipairs(split_lines(text)) do
    local line = trim(raw)
    local tag = line:match("^<(%w+) ")
    if tag and PLUGIN_TAGS[tag] then
      local tokens = rpp_tokens(line, 3)
      local name, ident = tokens and tokens[2], tokens and tokens[3]
      if name and ident and name ~= "" then
        local key = tag .. "\0" .. name .. "\0" .. ident
        local ref = index[key]
        if ref then
          ref.count = ref.count + 1
        else
          ref = { tag = tag, name = name, ident = ident, count = 1 }
          index[key] = ref
          refs[#refs + 1] = ref
        end
      end
    end
  end
  return refs
end

return M
