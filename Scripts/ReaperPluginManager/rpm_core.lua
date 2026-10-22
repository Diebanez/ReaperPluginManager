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

---------------------------------------------------------------------------
-- Name normalization, installed check and installed grouping
---------------------------------------------------------------------------

-- An installed plugin is { name, ident }: REAPER's display name and
-- identifier, the same two fields a project reference carries.

-- Lower-cases `s` and keeps only ASCII letters, digits and `.`.
function M.norm(s)
  return (tostring(s or ""):lower():gsub("[^a-z0-9.]", ""))
end

-- The display-name prefix before `:`, lower-cased, to its format.
local FORMATS = {
  vst = "vst", vsti = "vst",
  vst3 = "vst3", vst3i = "vst3",
  au = "au", aui = "au",
  clap = "clap", clapi = "clap",
  lv2 = "lv2", lv2i = "lv2",
  dx = "dx", dxi = "dx",
  js = "js",
}

-- Returns `s` without its last parenthesised group and the spaces before it,
-- or `s` itself when it does not end with `)`.
local function drop_last_paren(s)
  if s:sub(-1) ~= ")" then
    return s
  end
  local depth = 0
  for i = #s, 1, -1 do
    local c = s:sub(i, i)
    if c == ")" then
      depth = depth + 1
    elseif c == "(" then
      depth = depth - 1
      if depth == 0 then
        return trim(s:sub(1, i - 1))
      end
    end
  end
  return s
end

-- Splits a display name such as `VST3: Kontakt 7 (Native Instruments) (64
-- out)` into its format (`vst3`, or nil for an unknown or missing prefix),
-- base name (`Kontakt 7 (Native Instruments)`: trailing `(N out)` and `(Nch)`
-- removed repeatedly) and bare name (`Kontakt 7`: the base name without its
-- last parenthesis, the vendor).
function M.split_name(display)
  local rest = trim(tostring(display or ""))
  local prefix, after = rest:match("^(%w+):%s*(.*)$")
  local format = prefix and FORMATS[prefix:lower()]
  if format then
    rest = after
  end
  local base = rest
  repeat
    local before = base
    base = trim((base:gsub("%(%d+ out%)$", "")))
    base = trim((base:gsub("%(%d+ch%)$", "")))
  until base == before
  return format, base, drop_last_paren(base)
end

-- Identifiers ending in one of these name a plugin file or bundle.
local PLUGIN_EXTENSIONS = {
  dll = true, vst3 = true, vst = true, component = true,
  clap = true, so = true, dylib = true, lv2 = true,
}

-- Returns the identifier key of `ident`: everything from `<` dropped; for a
-- plugin file identifier (full path or file name) only the file name kept;
-- then `norm`. Other identifiers, AU ids among them, are normalized whole.
function M.ident_key(ident)
  local s = trim((tostring(ident or ""):gsub("<.*$", "")))
  local ext = s:match("%.([%w]+)$")
  if ext and PLUGIN_EXTENSIONS[ext:lower()] then
    s = s:match("([^/\\]*)$")
  end
  return M.norm(s)
end

-- The `format:norm(base name)` key of a display name.
local function format_key(display)
  local format, base = M.split_name(display)
  local n = M.norm(base)
  if n == "" then
    return nil
  end
  return (format or "") .. ":" .. n
end

-- Returns the references in `refs` that are not installed: those whose
-- identifier key matches no installed plugin's and whose `format:norm(base
-- name)` matches none either. Order is kept.
function M.missing(refs, installed)
  local idents, formats = {}, {}
  for _, p in ipairs(installed or {}) do
    local k = M.ident_key(p.ident)
    if k ~= "" then
      idents[k] = true
    end
    local f = format_key(p.name)
    if f then
      formats[f] = true
    end
  end
  local out = {}
  for _, ref in ipairs(refs or {}) do
    local f = format_key(ref.name)
    if not idents[M.ident_key(ref.ident)] and not (f and formats[f]) then
      out[#out + 1] = ref
    end
  end
  return out
end

-- Groups the installed plugins by `norm(base name)`, so the VST2, VST3, AU
-- and CLAP of one plugin form one group. Returns { key, base, bare, plugins }
-- per group in order of first appearance, `base` and `bare` taken from the
-- group's first plugin; a plugin whose base name normalizes to nothing is
-- left out.
function M.group_installed(installed)
  local groups, index = {}, {}
  for _, p in ipairs(installed or {}) do
    local _, base, bare = M.split_name(p.name)
    local key = M.norm(base)
    if key ~= "" then
      local g = index[key]
      if not g then
        g = { key = key, base = base, bare = bare, plugins = {} }
        index[key] = g
        groups[#groups + 1] = g
      end
      g.plugins[#g.plugins + 1] = p
    end
  end
  return groups
end

---------------------------------------------------------------------------
-- Catalogue validation and match index
---------------------------------------------------------------------------

M.catalogue = {}

-- The highest catalogue format version this tool understands.
M.catalogue.VERSION = 1

-- The installer types of each platform; a missing `type` is derived from the
-- file extension when it names one of them.
local INSTALLER_TYPES = {
  windows = { exe = true, msi = true, zip = true },
  macos = { pkg = true, dmg = true, zip = true },
}

-- True for a JSON array: a table marked json.array, or an unmarked one whose
-- keys are exactly 1..n.
local function is_json_array(v)
  if type(v) ~= "table" or v == M.json.null then
    return false
  end
  local mt = getmetatable(v)
  if mt == ARRAY_MT then
    return true
  elseif mt ~= nil then
    return false
  end
  local n, count = #v, 0
  for k in pairs(v) do
    if math.type(k) ~= "integer" or k < 1 or k > n then
      return false
    end
    count = count + 1
  end
  return count == n
end

local function is_json_object(v)
  return type(v) == "table" and v ~= M.json.null and not is_json_array(v)
end

local function has_text(v)
  return type(v) == "string" and trim(v) ~= ""
end

-- A shallow copy of the JSON object `t`, still marked as an object.
local function copy_object(t)
  local c = {}
  for k, v in pairs(t) do
    c[k] = v
  end
  return setmetatable(c, getmetatable(t) or OBJECT_MT)
end

-- Returns the installer `inst` for `platform` ready to use, or nil when it
-- counts as absent: not an object, or an empty `file`.
local function check_installer(inst, platform)
  if not is_json_object(inst) or not has_text(inst.file) then
    return nil
  end
  inst = copy_object(inst)
  if not has_text(inst.type) then
    local ext = inst.file:match("%.(%w+)$")
    ext = ext and ext:lower()
    inst.type = INSTALLER_TYPES[platform][ext] and ext or nil
  end
  return inst
end

local function check_match(m)
  if not is_json_array(m) or #m == 0 then
    return false
  end
  for _, s in ipairs(m) do
    if type(s) ~= "string" then
      return false
    end
  end
  return true
end

-- Returns a usable copy of the catalogue entry `e`, or nil and the reason it
-- is skipped. `activation` and unknown keys are carried through untouched.
local function check_entry(e)
  if not is_json_object(e) then
    return nil, "not an object"
  elseif not has_text(e.id) then
    return nil, 'missing "id"'
  elseif e.id:find("%s") then
    return nil, '"id" contains spaces'
  elseif not has_text(e.name) then
    return nil, 'missing "name"'
  elseif not check_match(e.match) then
    return nil, 'missing "match"'
  end
  local entry = copy_object(e)
  entry.installers = nil
  if is_json_object(e.installers) then
    local installers = copy_object(e.installers)
    for platform in pairs(INSTALLER_TYPES) do
      installers[platform] = check_installer(e.installers[platform], platform)
    end
    entry.installers = installers
  end
  return entry
end

-- Validates a decoded catalogue against the format. Returns a copy holding
-- only the usable entries plus the list of warnings for the skipped ones, or
-- nil and an error when the whole catalogue is rejected: `version` missing or
-- higher than VERSION, or `plugins` not an array. An installer with an empty
-- `file` is removed as absent, and one with no `type` gets it from the file
-- extension. The input is not modified. Never raises.
function M.catalogue.validate(value)
  if not is_json_object(value) then
    return nil, "invalid catalogue: not a JSON object"
  end
  local v = value.version
  if v == nil then
    return nil, 'invalid catalogue: missing "version"'
  elseif type(v) ~= "number" or v ~= math.floor(v) or v < 1 then
    return nil, 'invalid catalogue: "version" is not a version number'
  elseif v > M.catalogue.VERSION then
    return nil, ("unsupported catalogue format version %s: this version of "
      .. "ReaperPluginManager reads up to %d")
      :format(tostring(math.tointeger(v) or v), M.catalogue.VERSION)
  end
  if not is_json_array(value.plugins) then
    return nil, 'invalid catalogue: "plugins" is not an array'
  end

  local plugins, warnings, seen = M.json.array(), {}, {}
  for i, e in ipairs(value.plugins) do
    local entry, why = check_entry(e)
    if entry and seen[entry.id] then
      entry, why = nil, 'repeated "id"'
    end
    if entry then
      seen[entry.id] = true
      plugins[#plugins + 1] = entry
    else
      local label = ""
      if is_json_object(e) and has_text(e.id) then
        label = (' "%s"'):format(e.id)
      end
      warnings[#warnings + 1] = ("entry %d%s skipped: %s"):format(i, label, why)
    end
  end
  local catalogue = copy_object(value)
  catalogue.plugins = plugins
  return catalogue, warnings
end

-- Builds the match index of a validated catalogue: `norm(m)` for every match
-- string `m` of every entry, to that entry; when two entries share a
-- normalized string the first keeps it. Returns lookup(normalized) → entry or
-- nil.
function M.catalogue.index(catalogue)
  local map = {}
  local plugins = type(catalogue) == "table" and catalogue.plugins
  for _, entry in ipairs(type(plugins) == "table" and plugins or {}) do
    for _, m in ipairs(entry.match or {}) do
      local k = M.norm(m)
      if k ~= "" and map[k] == nil then
        map[k] = entry
      end
    end
  end
  return function(s)
    return map[s]
  end
end

---------------------------------------------------------------------------
-- Catalogue association and classification
---------------------------------------------------------------------------

-- The plugin formats REAPER can load on each platform.
local LOADABLE = {
  windows = { vst = true, vst3 = true, clap = true, lv2 = true, dx = true },
  macos = { vst = true, vst3 = true, au = true, clap = true, lv2 = true },
}

-- The format of a project reference: from its display-name prefix, else from
-- its chunk tag, a `<VST` whose identifier names a .vst3 file being VST3.
local function ref_format(ref)
  local format = M.split_name(ref.name)
  if format then
    return format
  end
  local tag = tostring(ref.tag or ""):lower()
  if tag == "vst" and tostring(ref.ident or ""):lower():match("%.vst3") then
    return "vst3"
  end
  return FORMATS[tag]
end

-- Returns the catalogue entry `plugin` (a reference or an installed plugin,
-- { name, ident }) associates with: the first hit of its identifier key,
-- `norm(base name)` and `norm(bare name)` in `lookup`, or nil. A nil
-- `lookup` (no catalogue) associates nothing.
local function associate(plugin, lookup)
  if not lookup then
    return nil
  end
  local _, base, bare = M.split_name(plugin.name)
  for _, k in ipairs({ M.ident_key(plugin.ident), M.norm(base), M.norm(bare) }) do
    if k ~= "" then
      local entry = lookup(k)
      if entry then
        return entry
      end
    end
  end
  return nil
end

-- Sorts the missing references into the summary groups for `platform`
-- (`windows` or `macos`), against the catalogue match index `lookup` (nil
-- when there is no catalogue, so nothing is installable). With `p` the entry
-- a reference associates with and `spec` its installer for `platform`:
-- - `p` present (some installed plugin associates with it) → replace;
-- - `spec` → installable, and also replace when the format cannot load here;
-- - `p` without `spec` → no_installer;
-- - no `p` and a format that cannot load here → replace;
-- - no `p` → unknown.
-- `installable` holds one { entry, installer, count, refs } per entry in order
-- of first appearance, `count` summing the instances of its references. The
-- other groups hold { ref, entry, format } per reference, and `replace` items
-- also a `reason`: "present" or "unloadable".
function M.classify(missing_refs, installed, lookup, platform)
  local result = { installable = {}, no_installer = {}, unknown = {}, replace = {} }
  local loadable = LOADABLE[platform] or {}

  local present = {}
  for _, p in ipairs(installed or {}) do
    local entry = associate(p, lookup)
    if entry then
      present[entry] = true
    end
  end

  local groups = {}
  for _, ref in ipairs(missing_refs or {}) do
    local format = ref_format(ref)
    local can_load = format ~= nil and loadable[format] == true
    local entry = associate(ref, lookup)
    local spec = entry and type(entry.installers) == "table"
      and entry.installers[platform] or nil
    if spec == M.json.null then
      spec = nil
    end
    local item = { ref = ref, entry = entry, format = format }

    if entry and present[entry] then
      item.reason = "present"
      result.replace[#result.replace + 1] = item
    elseif spec then
      local g = groups[entry]
      if not g then
        g = { entry = entry, installer = spec, count = 0, refs = {} }
        groups[entry] = g
        result.installable[#result.installable + 1] = g
      end
      g.count = g.count + (ref.count or 1)
      g.refs[#g.refs + 1] = ref
      if not can_load then
        item.reason = "unloadable"
        result.replace[#result.replace + 1] = item
      end
    elseif entry then
      result.no_installer[#result.no_installer + 1] = item
    elseif not can_load then
      item.reason = "unloadable"
      result.replace[#result.replace + 1] = item
    else
      result.unknown[#result.unknown + 1] = item
    end
  end
  return result
end

---------------------------------------------------------------------------
-- Command lines
---------------------------------------------------------------------------

-- Quotes `s` as one argument for a POSIX shell.
function M.sh_quote(s)
  return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Quotes `s` as one argument for a Windows program that splits its command
-- line by the C runtime rules: backslashes are doubled only before a quote
-- or the closing quote.
function M.win_quote(s)
  local out = tostring(s):gsub('(\\*)"', function(bs)
    return bs .. bs .. '\\"'
  end)
  out = out:gsub("(\\+)$", "%1%1")
  return '"' .. out .. '"'
end

---------------------------------------------------------------------------
-- Transfer: curl options and arguments, server URLs, error reasons and the
-- background upload's status file
---------------------------------------------------------------------------

M.transfer = {}

-- Seconds curl may take to connect, and seconds a transfer may run below one
-- byte per second before curl gives up.
M.transfer.CONNECT_TIMEOUT = 30
M.transfer.STALL_TIMEOUT = 60

local SCHEME_KINDS = { ftp = "ftp", ftps = "ftp", http = "http", https = "http", file = "file" }

-- Returns how the server at `url` is reached: "ftp" (ftp, ftps), "http"
-- (http, https) or "file"; nil for any other address.
function M.transfer.kind(url)
  local scheme = type(url) == "string" and url:match("^(%a[%w+.-]*)://")
  return scheme and SCHEME_KINDS[scheme:lower()] or nil
end

-- The server path `path` with `/` separators and no leading slash.
local function clean_path(path)
  return (tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""))
end

local function percent_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- Returns the server path `path` in URL form: `\` becomes `/`, leading
-- slashes go, and every byte outside [A-Za-z0-9-._~/] is percent-encoded.
function M.transfer.encode_path(path)
  return (clean_path(path):gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- The URL of `path` on the server at `base_url` (which ends with `/`).
function M.transfer.url(base_url, path)
  return base_url .. M.transfer.encode_path(path)
end

-- Returns the filesystem path of `path` on the file:// server at `base_url`,
-- with `\` separators when `windows`; nil when `base_url` is not file://.
-- Accepts file:///C:/dir/, file:///Users/dir/, file://localhost/... and
-- file://host/share/ (a UNC path).
function M.transfer.file_path(base_url, path, windows)
  local rest = type(base_url) == "string" and base_url:match("^[Ff][Ii][Ll][Ee]://(.*)$")
  if not rest then
    return nil
  end
  rest = rest:gsub("\\", "/")
  local p
  if rest:sub(1, 1) == "/" or rest:match("^%a:") then
    p = rest
  elseif rest:lower():sub(1, 10) == "localhost/" then
    p = rest:sub(10)
  else
    p = "//" .. rest
  end
  if p:match("^/%a:") then
    p = p:sub(2)
  end
  p = percent_decode(p)
  if p:sub(-1) ~= "/" then
    p = p .. "/"
  end
  p = p .. clean_path(path)
  if windows then
    p = p:gsub("/", "\\")
  end
  return p
end

-- Returns the curl options every transfer shares, from the settings value
-- `settings`: fail on server errors, silent but for errors, follow redirects,
-- passive FTP, the timeouts, the TLS level, the insecure switch and, when
-- `netrc_path` is given, the credentials file. `progress` drops `--silent`,
-- keeping the progress meter a background upload reads its byte count from.
function M.transfer.common_options(settings, netrc_path, progress)
  local server = type(settings) == "table" and type(settings.server) == "table"
    and settings.server or {}
  local opts = { "--fail" }
  if not progress then
    opts[#opts + 1] = "--silent"
  end
  for _, o in ipairs({ "--show-error", "--location", "--ftp-pasv",
      "--connect-timeout", tostring(M.transfer.CONNECT_TIMEOUT),
      "--speed-limit", "1", "--speed-time", tostring(M.transfer.STALL_TIMEOUT) }) do
    opts[#opts + 1] = o
  end
  local tls = server.tls or "required"
  if tls == "required" then
    opts[#opts + 1] = "--ssl-reqd"
  elseif tls == "try" then
    opts[#opts + 1] = "--ssl"
  end
  if server.insecure == true then
    opts[#opts + 1] = "--insecure"
  end
  if netrc_path then
    opts[#opts + 1] = "--netrc-file"
    opts[#opts + 1] = netrc_path
  end
  return opts
end

-- Returns the curl arguments, after the common options, of operation `op`
-- on the server at `base_url`, or nil for a file:// server; `platform` names
-- the null device. The operations and their `a`, `b`:
-- - "download" server path, local path;
-- - "upload" local path, server path (missing FTP folders are created);
-- - "rename" server path, new server path: RNFR/RNTO over FTP, WebDAV MOVE
--   over HTTP;
-- - "delete" server path: DELE over FTP, WebDAV DELETE over HTTP.
function M.transfer.args(op, base_url, platform, a, b)
  local kind = M.transfer.kind(base_url)
  if kind ~= "ftp" and kind ~= "http" then
    return nil
  end
  local null = platform == "windows" and "NUL" or "/dev/null"
  if op == "download" then
    return { "--output", b, M.transfer.url(base_url, a) }
  elseif op == "upload" then
    return { "--ftp-create-dirs", "--output", null, "--upload-file", a,
      M.transfer.url(base_url, b) }
  elseif op == "rename" then
    if kind == "ftp" then
      return { "--list-only", "--output", null, "--quote", "RNFR " .. clean_path(a),
        "--quote", "RNTO " .. clean_path(b), base_url }
    end
    return { "--output", null, "--request", "MOVE",
      "--header", "Destination: " .. M.transfer.url(base_url, b),
      "--header", "Overwrite: T", M.transfer.url(base_url, a) }
  elseif op == "delete" then
    if kind == "ftp" then
      return { "--list-only", "--output", null, "--quote", "DELE " .. clean_path(a), base_url }
    end
    return { "--output", null, "--request", "DELETE", M.transfer.url(base_url, a) }
  end
  return nil
end

-- Returns the command line running `program` with `args`, each quoted for
-- `platform` ("windows", or a POSIX shell for any other).
function M.transfer.command(program, args, platform)
  local quote = platform == "windows" and M.win_quote or M.sh_quote
  local parts = { quote(program) }
  for _, a in ipairs(args or {}) do
    parts[#parts + 1] = quote(a)
  end
  return table.concat(parts, " ")
end

local LOGIN_FAILED = "Login failed: check the user name and password"
local NOT_FOUND = "Not found on the server"
local PERMISSION_DENIED = "Permission denied on the server"

local CURL_REASONS = {
  [1] = "The server address uses a protocol curl does not support",
  [2] = "curl could not start",
  [3] = "The server address is malformed",
  [5] = "Cannot resolve the proxy",
  [6] = "Cannot find the server: its host name does not resolve",
  [7] = "The server is unreachable",
  [8] = "The server's reply was not understood",
  [9] = PERMISSION_DENIED,
  [18] = "The transfer ended before the whole file arrived",
  [21] = "The server refused the command: the file is missing or permission is denied",
  [23] = "Cannot write the local file",
  [25] = "The server refused the upload: permission denied",
  [26] = "Cannot read the local file",
  [28] = "The transfer timed out",
  [35] = "The TLS handshake with the server failed",
  [37] = "Cannot read the file",
  [47] = "Too many redirects",
  [51] = "The server's TLS certificate is not trusted",
  [52] = "The server sent no reply",
  [55] = "Sending to the server failed",
  [56] = "Receiving from the server failed",
  [60] = "The server's TLS certificate is not trusted",
  [64] = "The server refused TLS",
  [67] = LOGIN_FAILED,
  [77] = "Cannot read the TLS certificate store",
  [78] = NOT_FOUND,
  [127] = "curl was not found",
}

local HTTP_REASONS = {
  [401] = LOGIN_FAILED,
  [403] = PERMISSION_DENIED,
  [404] = NOT_FOUND,
  [405] = "The server does not accept this operation: writing over HTTPS needs WebDAV",
  [409] = "The server folder does not exist",
  [501] = "The server does not accept this operation: writing over HTTPS needs WebDAV",
  [507] = "The server is out of storage space",
}

-- Replaces every plain occurrence of `find` in `s` with `with`.
local function replace_plain(s, find, with)
  local out, pos = {}, 1
  while true do
    local i, j = s:find(find, pos, true)
    if not i then
      break
    end
    out[#out + 1] = s:sub(pos, i - 1)
    out[#out + 1] = with
    pos = j + 1
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

-- Returns the one-line reason for a failed curl run, from its exit code
-- `code` (nil when unknown) and its error output `stderr`, whose last
-- `curl: (N) text` line supplies the detail. Every occurrence of `secret`
-- is masked.
function M.transfer.error_message(code, stderr, secret)
  local detail, detail_code
  for line in tostring(stderr or ""):gmatch("[^\r\n]+") do
    local c, text = line:match("^curl: %((%d+)%)%s*(.*)$")
    if c then
      detail_code, detail = tonumber(c), trim(text)
    end
  end
  code = code or detail_code
  local reason
  if code == 22 then
    local status = detail and tonumber(detail:match("(%d%d%d)"))
    reason = HTTP_REASONS[status]
      or (status and "The server answered with HTTP error " .. status)
      or "The server answered with an HTTP error"
  else
    reason = CURL_REASONS[code] or "The transfer failed"
  end
  local msg = reason
  if code then
    msg = msg .. " (curl " .. code
    if detail and detail ~= "" then
      msg = msg .. ": " .. detail
    end
    msg = msg .. ")"
  end
  msg = msg:gsub("%c+", " ")
  if type(secret) == "string" and secret ~= "" then
    msg = replace_plain(msg, secret, "***")
  end
  return msg
end

local SIZE_UNITS = { [""] = 1, k = 1024, M = 1024 ^ 2, G = 1024 ^ 3, T = 1024 ^ 4, P = 1024 ^ 5 }

-- Bytes of a progress-meter size such as `512`, `1024k` or `12.3M`.
local function meter_size(token)
  local n, unit = token:match("^(%d+%.?%d*)([kMGTP]?)$")
  if not n then
    return nil
  end
  return math.floor(tonumber(n) * SIZE_UNITS[unit])
end

-- Parses the status file of a background upload: curl's error output with
-- its progress meter, then, once curl has ended, a line `EXIT <code>`
-- (`EXIT -` when the code is unknown). Returns { done, code, bytes, text }:
-- `bytes` is the byte count sent per the last complete meter row (nil before
-- the first), `code` the exit code once done (taken from the `curl: (N)` line
-- when the EXIT line has none), `text` the `curl:` error lines.
function M.transfer.parse_status(text)
  local result = { done = false }
  local errors = {}
  for seg in tostring(text or ""):gmatch("[^\r\n]+") do
    local exit = seg:match("^EXIT%s+(%S+)%s*$")
    if exit then
      result.done = true
      result.code = tonumber(exit)
    elseif seg:match("^curl: ") then
      errors[#errors + 1] = seg
    else
      local tokens = {}
      for t in seg:gmatch("%S+") do
        tokens[#tokens + 1] = t
      end
      if #tokens >= 12 and tokens[1]:match("^%d+$") and tokens[5]:match("^%d+$") then
        result.bytes = meter_size(tokens[6]) or result.bytes
      end
    end
  end
  result.text = table.concat(errors, "\n")
  if result.done and not result.code then
    result.code = tonumber(result.text:match("curl: %((%d+)%)"))
  end
  return result
end

return M
