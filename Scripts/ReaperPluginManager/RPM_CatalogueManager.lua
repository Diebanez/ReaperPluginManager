-- @noindex

-- RPM_CatalogueManager.lua: the "ReaperPluginManager: Catalogue management"
-- action. The maintainer's ReaImGui window over the local catalogue draft:
-- every draft entry, what changed since the catalogue the draft started from,
-- the validation problems that block publishing, the three ways to add an
-- entry (from REAPER's installed plugins, by hand, or from a draft entry file),
-- the entry form that edits every field of an entry, attaches its installers
-- with their checksums, and removes it, and Publish, which sends the draft to
-- the server with per-file upload progress.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
if script_dir and not package.path:find(script_dir, 1, true) then
  package.path = script_dir .. "?.lua;" .. package.path
end

local rpm = require("rpm_reaper")
local core = require("rpm_core")

local TITLE = "ReaperPluginManager - Catalogue management"

local NO_IMGUI = "Catalogue management needs the ReaImGui extension, version 0.9 or later.\n\n"
  .. "Install it through ReaPack (Extensions > ReaPack > Browse packages, search for ReaImGui), "
  .. "restart REAPER and run this action again."

-- Colours are 0xRRGGBBAA.
local COLOURS = {
  added = 0x6FCF6FFF,
  changed = 0xE8C14AFF,
  removed = 0xE06C6CFF,
  problem = 0xFF6B6BFF,
  notice = 0xE8C14AFF,
}

local ImGui, ctx

-- The window state: the draft, its list rows and counts, and the lines shown
-- above the list.
local state = {
  draft = nil,
  rows = {},
  counts = { entries = 0, added = 0, changed = 0, removed = 0, problems = 0 },
  rejected = nil, -- why the whole draft catalogue is invalid, if it is
  notice = nil,   -- how the draft started, when that needs saying
  status = nil,   -- the outcome of the last button
  action = nil,   -- the button pressed this frame, run after the frame
  closing = false,
  panel = nil,    -- the open add panel: "installed", "hand" or "import"
  groups = {},    -- the installed-plugin groups Add from installed offers
  filter = "",    -- the text filtering those groups
  hand = { name = "", vendor = "", match = "" }, -- the Add by hand fields
  draft_files = {}, -- the file names Import draft offers
  form = nil,     -- the entry form, while one is open
  publishing = nil, -- the publish run, while one is running: its coroutine and last progress
}

local function message(text)
  reaper.ShowMessageBox(text, TITLE, 0)
end

local function confirm(text)
  return reaper.ShowMessageBox(text, TITLE, 4) == 6
end

-- The ReaImGui API pinned to version 0.9, or nil when ReaImGui is missing or
-- older than that.
local function load_imgui()
  if not reaper.ImGui_GetBuiltinPath then
    return nil
  end
  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  local ok, imgui = pcall(require, "imgui")
  if not ok then
    return nil
  end
  local vok, api = pcall(imgui, "0.9")
  if not vok then
    return nil
  end
  return api
end

---------------------------------------------------------------------------
-- The draft: open the stored one, or start one from the catalogue.
---------------------------------------------------------------------------

-- The decoded empty catalogue a draft starts from when none can be fetched.
local function empty_catalogue()
  return core.json.object({ version = core.catalogue.VERSION, plugins = core.json.array() })
end

-- Fetches the catalogue and starts a draft from it. Returns the draft and the
-- notice to show in the window (nil when there is none to show), or nil when
-- no draft was started.
local function start_draft()
  local _, source, reason, value = rpm.catalogue.fetch()
  local notice
  if source == "none" then
    if not confirm("The catalogue could not be fetched: " .. tostring(reason)
        .. "\n\nStart a draft from an empty catalogue?") then
      return nil
    end
    value = empty_catalogue()
  elseif source == "cache" then
    notice = "The draft started from the cached catalogue, because the server catalogue could not be used: "
      .. tostring(reason)
  end
  local draft, err = rpm.draft.create(value)
  if not draft then
    message(err)
    return nil
  end
  return draft, notice
end

-- Returns the stored draft, or a new one started from the catalogue, and the
-- notice to show; nil when there is no draft to edit.
local function open_draft()
  local draft, err = rpm.draft.load()
  if draft then
    return draft
  end
  if err then
    if not confirm(err .. "\n\nDiscard it and start a new draft from the catalogue?") then
      return nil
    end
    local ok, derr = rpm.draft.discard()
    if not ok then
      message(derr)
      return nil
    end
  end
  return start_draft()
end

---------------------------------------------------------------------------
-- The list: one row per draft entry, then one per base entry the draft no
-- longer has.
---------------------------------------------------------------------------

local function is_table(v)
  return type(v) == "table" and v ~= core.json.null
end

local function text_of(v)
  return type(v) == "string" and v or ""
end

local function plugins_of(catalogue)
  return is_table(catalogue) and is_table(catalogue.plugins) and catalogue.plugins or {}
end

local function encoded(entry)
  return core.json.encode(entry) or ""
end

-- What pairs a draft entry with its base entry: the `id`, or for an entry
-- without one, its whole content.
local function key_of(entry)
  if is_table(entry) and type(entry.id) == "string" and entry.id ~= "" then
    return entry.id
  end
  return "\0" .. encoded(entry)
end

-- The platforms the installers of `entry` cover, as the list shows them.
local function platforms_of(entry)
  local installers = is_table(entry) and is_table(entry.installers) and entry.installers or {}
  local function file(platform)
    local inst = installers[platform]
    local f = is_table(inst) and inst.file
    return type(f) == "string" and f:match("%S") and f or nil
  end
  local windows, macos = file("windows"), file("macos")
  if windows and windows == macos then
    return "Windows + macOS (shared)"
  elseif windows and macos then
    return "Windows, macOS"
  end
  return windows and "Windows" or macos and "macOS" or "-"
end

-- The activation method of `entry`; an absent one means "none".
local function activation_of(entry)
  local activation = is_table(entry) and entry.activation
  local method = is_table(activation) and activation.method
  return type(method) == "string" and method ~= "" and method or "none"
end

---------------------------------------------------------------------------
-- Installer files. Besides `catalogue` and `base`, the draft keeps `files`:
-- per installer server path, a record. `uploaded` is true once the file is
-- on the server, so publishing never uploads it; a local file attached in
-- the entry form also has `source` (its local path), `size` and `sha256`, and
-- `uploaded` false until publishing uploads it.
---------------------------------------------------------------------------

local PLATFORMS = { "windows", "macos" }

local SLOT_NAMES = { windows = "Windows", macos = "macOS", shared = "Shared package (Windows and macOS)" }

-- The installer types the form offers per slot; a shared package must suit
-- both platforms.
local SLOT_TYPES = { windows = { "exe", "msi", "zip" }, macos = { "pkg", "dmg", "zip" }, shared = { "zip" } }

local INSTALLER_TYPES = {
  windows = { exe = true, msi = true, zip = true },
  macos = { pkg = true, dmg = true, zip = true },
}

local DESTINATIONS = { vst3 = true, vst2 = true, clap = true, au = true }

local CHECKSUM_TIMEOUT_MS = 600000

local function file_exists(path)
  local f = io.open(path, "rb")
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

local function base_name(path)
  return path:match("([^\\/]+)$") or path
end

local function is_absolute(path)
  return path:match("^/") or path:match("^%a:[\\/]") or path:match("^\\\\")
end

-- The server path the local installer `source` gets in the entry `id`, for
-- the form slot `slot`: `<id>/windows/<file>`, `<id>/macos/<file>`, or
-- `<id>/<file>` for a package shared by both platforms.
local function server_path(id, slot, source)
  if slot == "shared" then
    return id .. "/" .. base_name(source)
  end
  return id .. "/" .. slot .. "/" .. base_name(source)
end

-- The record of the installer at the server path `path` in `files`, or nil.
local function record_of(files, path)
  local record = is_table(files) and files[path]
  return is_table(record) and record or nil
end

-- The local file a record still has to upload, or nil.
local function pending_source(record)
  if record and record.uploaded ~= true and type(record.source) == "string" and record.source ~= "" then
    return record.source
  end
  return nil
end

-- The SHA-256 digest in tool output: 64 hex digits on a line of their own,
-- which certutil may space out. Lower-case, or nil.
local function digest_in(output)
  for line in output:gmatch("[^\r\n]+") do
    local hex = line:gsub("%s", "")
    if #hex == 64 and not hex:find("%X") then
      return hex:lower()
    end
  end
  return nil
end

-- The output of `cmd` run through ExecProcess when it exits with 0, or nil.
local function exec_output(cmd)
  local ret = reaper.ExecProcess(cmd, CHECKSUM_TIMEOUT_MS)
  local code, output = (ret or ""):match("^(%-?%d+)\r?\n(.*)$")
  if code ~= "0" then
    return nil
  end
  return output
end

-- The SHA-256 of the file at `path`, computed with the OS tools: certutil,
-- then PowerShell, on Windows; `shasum -a 256` on macOS. Returns the
-- lower-case hex digest, or nil and why it could not be computed.
local function sha256_of(path)
  local p = rpm.platform()
  if p == "windows" then
    local output = exec_output('certutil.exe -hashfile "' .. path .. '" SHA256')
    local hex = output and digest_in(output)
    if hex then
      return hex
    end
    output = exec_output('powershell.exe -NoProfile -NonInteractive -Command "(Get-FileHash -Algorithm SHA256 -LiteralPath \''
      .. path:gsub("'", "''") .. '\').Hash"')
    hex = output and digest_in(output)
    if hex then
      return hex
    end
    return nil, "neither certutil nor PowerShell could hash the file"
  elseif p == "macos" then
    local f = io.popen("/usr/bin/shasum -a 256 " .. core.sh_quote(path) .. " 2>/dev/null", "r")
    local output = f and f:read("a") or ""
    if f then
      f:close()
    end
    local hex = output:match("^(%x+)%s")
    if hex and #hex == 64 then
      return hex:lower()
    end
    return nil, "shasum could not hash the file"
  end
  return nil, "checksums are computed only on Windows and macOS"
end

-- The problems of `entry` that catalogue validation does not see: an
-- installer whose type does not suit its platform or cannot be told from its
-- file extension, a destination that is neither a plugin folder nor an
-- absolute path, and an attached local file that is gone. `files` is the
-- draft's installer records.
local function entry_problems(entry, files)
  local out = {}
  local installers = is_table(entry) and is_table(entry.installers) and entry.installers or {}
  local seen = {}
  for _, platform in ipairs(PLATFORMS) do
    local inst = installers[platform]
    local file = is_table(inst) and inst.file
    if type(file) == "string" and file:match("%S") then
      local label = SLOT_NAMES[platform] .. " installer"
      local kind = text_of(inst.type)
      if kind == "" then
        local ext = file:match("%.(%w+)$")
        if not (ext and INSTALLER_TYPES[platform][ext:lower()]) then
          out[#out + 1] = label .. ": choose its type, the file extension does not tell it"
        end
      elseif not INSTALLER_TYPES[platform][kind] then
        out[#out + 1] = ('%s: type "%s" is not one of %s'):format(label, kind, table.concat(SLOT_TYPES[platform], ", "))
      end
      local dest = inst.dest
      if dest ~= nil and dest ~= core.json.null and dest ~= ""
          and not (type(dest) == "string" and (DESTINATIONS[dest] or is_absolute(dest))) then
        out[#out + 1] = ('%s: destination "%s" is not vst3, vst2, clap, au or an absolute path')
          :format(label, tostring(dest))
      end
      local source = not seen[file] and pending_source(record_of(files, file))
      seen[file] = true
      if source and not file_exists(source) then
        out[#out + 1] = ("the local file %s is gone: attach it again"):format(source)
      end
    end
  end
  return out
end

-- The validation problems of the draft, by entry position, and the reason
-- the whole catalogue is invalid, if it is.
local function problems_of(draft)
  local catalogue = draft.catalogue
  local valid, warnings = core.catalogue.validate(catalogue)
  if not valid then
    return {}, warnings
  end
  local found = {}
  for _, w in ipairs(warnings) do
    -- core.catalogue.validate words each one `entry <n>[ "<id>"] skipped: <reason>`.
    local n, why = w:match("^entry (%d+).- skipped: (.*)$")
    if n then
      found[tonumber(n)] = { why }
    end
  end
  for i, e in ipairs(plugins_of(catalogue)) do
    for _, why in ipairs(entry_problems(e, draft.files)) do
      found[i] = found[i] or {}
      found[i][#found[i] + 1] = why
    end
  end
  local problems = {}
  for i, list in pairs(found) do
    problems[i] = table.concat(list, "; ")
  end
  return problems
end

-- Rebuilds the list rows and counts from `draft`; each row has the entry,
-- its change since the base ("added", "changed", "removed" or nil) and its
-- validation problem.
local function set_draft(draft)
  local base_by_key = {}
  for _, e in ipairs(plugins_of(draft.base)) do
    local key = key_of(e)
    if base_by_key[key] == nil then
      base_by_key[key] = e
    end
  end

  local problems, rejected = problems_of(draft)
  local counts = { entries = 0, added = 0, changed = 0, removed = 0, problems = 0 }
  local rows, kept = {}, {}
  for i, e in ipairs(plugins_of(draft.catalogue)) do
    local key = key_of(e)
    local base = not kept[key] and base_by_key[key]
    local change
    if not base then
      change = "added"
    elseif encoded(e) ~= encoded(base) then
      change = "changed"
    end
    kept[key] = true
    rows[#rows + 1] = { entry = e, change = change, problem = problems[i] }
    counts.entries = counts.entries + 1
    if change then
      counts[change] = counts[change] + 1
    end
    if problems[i] then
      counts.problems = counts.problems + 1
    end
  end
  for _, e in ipairs(plugins_of(draft.base)) do
    local key = key_of(e)
    if not kept[key] then
      kept[key] = true
      rows[#rows + 1] = { entry = e, change = "removed" }
      counts.removed = counts.removed + 1
    end
  end

  state.draft = draft
  state.rows = rows
  state.counts = counts
  state.rejected = rejected
end

---------------------------------------------------------------------------
-- Adding entries
---------------------------------------------------------------------------

local SEP = package.config:sub(1, 1)

-- The folder the catalogue assistant writes draft entry files to.
local function drafts_dir()
  return rpm.data_dir() .. "drafts" .. SEP
end

local FORMAT_LABELS = { vst = "VST", vst3 = "VST3", au = "AU", clap = "CLAP", lv2 = "LV2", dx = "DX" }

-- The draft's entries, or nil, saying why in the status line, when the draft
-- catalogue is invalid as a whole and takes no new entry.
local function draft_plugins()
  local catalogue = state.draft.catalogue
  if state.rejected or not is_table(catalogue) or not is_table(catalogue.plugins) then
    state.status = "No entry can be added while the draft catalogue itself is invalid."
    return nil
  end
  return catalogue.plugins
end

-- Stores the changed draft and refreshes the list. Returns true, or false
-- after showing why in the status line.
local function save_draft()
  local ok, err = rpm.draft.save(state.draft)
  set_draft(state.draft)
  if not ok then
    state.status = err
  end
  return ok
end

local function added(entry)
  state.status = ('Added "%s" (id %s).'):format(entry.name, entry.id)
end

-- The group's base name and the formats it is installed in.
local function group_label(g)
  local formats, seen = {}, {}
  for _, p in ipairs(g.plugins) do
    local label = FORMAT_LABELS[core.split_name(p.name)]
    if label and not seen[label] then
      seen[label] = true
      formats[#formats + 1] = label
    end
  end
  if #formats == 0 then
    return g.base
  end
  return g.base .. "  [" .. table.concat(formats, ", ") .. "]"
end

local function refresh_groups()
  state.groups = core.editor.addable_groups(rpm.check.installed(), plugins_of(state.draft.catalogue))
  for _, g in ipairs(state.groups) do
    g.label = group_label(g)
  end
end

local function add_group(g)
  local plugins = draft_plugins()
  if not plugins then
    return
  end
  local entry = core.editor.entry_from_group(g, core.editor.ids(plugins))
  plugins[#plugins + 1] = entry
  if save_draft() then
    added(entry)
  end
  refresh_groups()
end

local function add_by_hand()
  local plugins = draft_plugins()
  if not plugins then
    return
  end
  local h = state.hand
  local entry, err = core.editor.manual_entry(h.name, h.vendor, h.match, core.editor.ids(plugins))
  if not entry then
    state.status = err
    return
  end
  plugins[#plugins + 1] = entry
  if save_draft() then
    added(entry)
    state.hand = { name = "", vendor = "", match = "" }
  end
end

local function refresh_draft_files()
  local dir, files = drafts_dir(), {}
  reaper.EnumerateFiles(dir, -1) -- forget REAPER's cached listing
  local i = 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then
      break
    end
    if name:lower():match("%.json$") then
      files[#files + 1] = name
    end
    i = i + 1
  end
  table.sort(files, function(a, b) return a:lower() < b:lower() end)
  state.draft_files = files
end

local function read_text(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("a")
  f:close()
  return text
end

-- Marks the installer files `entry` names as already on the server: an
-- imported entry's installers keep their server paths and are never uploaded.
local function mark_on_server(entry)
  local files = is_table(state.draft.files) and state.draft.files or core.json.object()
  state.draft.files = files
  for _, path in ipairs(core.editor.installer_paths(entry)) do
    files[path] = core.json.object({ uploaded = true })
  end
end

local open_form -- the entry form's constructor, defined with the form below

-- Imports the draft entry file `name`: adds its entry, or merges it into the
-- draft entry with the same id after confirmation, then removes the file.
local function import_draft(name)
  local plugins = draft_plugins()
  if not plugins then
    return
  end
  local path = drafts_dir() .. name
  local text = read_text(path)
  if not text then
    state.status = "Cannot read " .. path
    refresh_draft_files()
    return
  end
  local entry, why = core.editor.read_draft_entry(text)
  if not entry then
    state.status = ("%s cannot be imported: %s"):format(name, why)
    return
  end
  local existing
  for _, e in ipairs(plugins) do
    if is_table(e) and e.id == entry.id then
      existing = e
      break
    end
  end
  local editing = existing and state.form and state.form.entry == existing
  if existing then
    if not confirm(('The draft already has an entry with the id "%s" (%s).\n\n'
        .. "Merge %s into it? Its fields replace the entry's, its match strings are added to the entry's "
        .. "and its installers replace the entry's for the platforms it names.%s")
        :format(entry.id, text_of(existing.name), name,
          editing and state.form.dirty and "\n\nThe changes not yet saved in its entry form are lost." or "")) then
      return
    end
    core.editor.merge(existing, entry)
  else
    plugins[#plugins + 1] = entry
  end
  mark_on_server(entry)
  if editing then
    state.form = open_form(existing)
  end
  if not save_draft() then
    return
  end
  local verb = existing and "Merged" or "Imported"
  if os.remove(path) then
    state.status = ('%s "%s" (id %s) from %s.'):format(verb, text_of(entry.name), entry.id, name)
  else
    state.status = ('%s "%s" (id %s), but %s could not be removed: delete it by hand so it is not imported again.')
      :format(verb, text_of(entry.name), entry.id, path)
  end
  refresh_draft_files()
end

-- Opens the add panel `panel`, or closes it when it is the open one.
local function toggle_panel(panel)
  if state.panel == panel then
    state.panel = nil
    return
  end
  state.panel = panel
  if panel == "installed" then
    refresh_groups()
  elseif panel == "import" then
    refresh_draft_files()
  end
end

---------------------------------------------------------------------------
-- The entry form: an editable copy of one draft entry, written back on Save.
-- Its installer slots are `windows` and `macos`, or `shared` for one package
-- named under both installer keys.
---------------------------------------------------------------------------

local METHODS = { "none", "vendor-app", "serial", "sign-in" }

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function nonempty(s)
  s = trim(s)
  return s ~= "" and s or nil
end

local function copy_of(t)
  local c = core.json.object()
  if is_table(t) then
    for k, v in pairs(t) do
      c[k] = v
    end
  end
  return c
end

local function index_of(list, item)
  for i, v in ipairs(list) do
    if v == item then
      return i
    end
  end
  return nil
end

local function label_of(entry)
  if is_table(entry) then
    local name = text_of(entry.name)
    if name ~= "" then
      return name
    end
    if text_of(entry.id) ~= "" then
      return entry.id
    end
  end
  return "(unnamed)"
end

-- The form slot for the installer object `inst` (absent when it is not one):
-- its editable fields, the object itself so keys the form does not edit are
-- kept, and the local file still to upload (`attach`, as its record holds
-- it), with whether it is gone.
local function slot_of(inst)
  inst = is_table(inst) and inst or {}
  local slot = {
    orig = inst,
    file = text_of(inst.file),
    type = text_of(inst.type),
    args = text_of(inst.args),
    sha256 = text_of(inst.sha256),
    dest = text_of(inst.dest),
  }
  local record = slot.file ~= "" and record_of(state.draft.files, slot.file) or nil
  slot.source = pending_source(record)
  if slot.source then
    slot.attach = { source = slot.source, size = record.size, sha256 = record.sha256 }
    slot.missing = not file_exists(slot.source)
  end
  return slot
end

local function copy_slot(slot)
  local c = {}
  for k, v in pairs(slot) do
    c[k] = v
  end
  return c
end

-- Opens the form on the draft entry `entry`.
function open_form(entry)
  if not is_table(entry) then
    return { entry = entry, broken = true }
  end
  local installers = is_table(entry.installers) and entry.installers or {}
  local windows, macos = slot_of(installers.windows), slot_of(installers.macos)
  local activation = is_table(entry.activation) and entry.activation or {}
  local app = is_table(activation.app) and activation.app or {}
  local function app_of(platform)
    local a = is_table(app[platform]) and app[platform] or {}
    return { name = text_of(a.name), path = text_of(a.path) }
  end
  local match = {}
  for _, m in ipairs(is_table(entry.match) and entry.match or {}) do
    if type(m) == "string" then
      match[#match + 1] = m
    end
  end
  local method = trim(text_of(activation.method))
  local shared = windows.file ~= "" and windows.file == macos.file
  return {
    entry = entry,
    dirty = false,
    name = text_of(entry.name),
    vendor = text_of(entry.vendor),
    note = text_of(entry.note),
    match = table.concat(match, "\n"),
    shared = shared,
    slots = { windows = windows, macos = macos, shared = shared and copy_slot(windows) or slot_of(nil) },
    method = method ~= "" and method or "none",
    app = { windows = app_of("windows"), macos = app_of("macos") },
    url = text_of(activation.url),
    instructions = text_of(activation.instructions),
  }
end

-- The slots the form currently edits.
local function active_slots(form)
  if form.shared then
    return { "shared" }
  end
  return PLATFORMS
end

-- Switches the form between one installer per platform and one shared
-- package. The shared package starts from the Windows installer, else the
-- macOS one, and a local file it has moves to the shared folder; going back,
-- both platforms start from the shared package.
local function set_shared(form, shared)
  if form.shared == shared then
    return
  end
  local slots = form.slots
  if shared then
    local from = slots.windows.file ~= "" and slots.windows or slots.macos
    local slot = copy_slot(from)
    if slot.attach then
      slot.file = server_path(form.entry.id, "shared", slot.attach.source)
    end
    slots.shared = slot
  else
    slots.windows, slots.macos = copy_slot(slots.shared), copy_slot(slots.shared)
  end
  form.shared = shared
  form.dirty = true
end

-- Picks a local installer file for the slot `key`: computes its size and
-- SHA-256 and assigns its server path in the entry's folder. A checksum that
-- cannot be computed stays empty, and the status line says so.
local function attach(key)
  local form = state.form
  local id = text_of(form.entry.id)
  if id == "" or id:find("%s") then
    state.status = "This entry has no usable id, so its installers have no server folder: fix the id first."
    return
  end
  local ok, source = reaper.GetUserFileNameForRead("", "Attach the " .. SLOT_NAMES[key] .. " installer", "")
  if not ok or source == "" then
    return
  end
  local size = file_size(source)
  if not size then
    state.status = "Cannot read " .. source
    return
  end
  local hash, why = sha256_of(source)
  local slot = form.slots[key]
  slot.file = server_path(id, key, source)
  slot.type = "" -- from the new file's extension
  slot.sha256 = hash or ""
  slot.source, slot.missing = source, false
  slot.attach = { source = source, size = size, sha256 = hash }
  slot.checksum_error = not hash and why or nil
  form.dirty = true
  if hash then
    state.status = ("Attached %s as %s. Save to keep it."):format(source, slot.file)
  else
    state.status = ("Attached %s as %s, but its checksum could not be computed (%s), so it stays empty. Save to keep it.")
      :format(source, slot.file, why)
  end
end

-- Takes the installer out of the slot `key`.
local function clear_slot(key)
  state.form.slots[key] = slot_of(nil)
  state.form.dirty = true
end

-- The installer object of `slot`, or nil when it has no file.
local function installer_of(slot)
  if trim(slot.file) == "" then
    return nil
  end
  local inst = copy_of(slot.orig)
  inst.file = trim(slot.file)
  inst.type = nonempty(slot.type)
  inst.args = nonempty(slot.args)
  inst.sha256 = nonempty(slot.sha256)
  inst.dest = nonempty(slot.dest)
  return inst
end

-- The entry the form describes, keeping every key it does not edit.
local function entry_of(form)
  local entry = copy_of(form.entry)
  entry.name = trim(form.name)
  entry.vendor = nonempty(form.vendor)
  entry.note = nonempty(form.note)
  local match, seen = core.json.array(), {}
  for line in form.match:gmatch("[^\r\n]+") do
    local m = trim(line)
    local k = core.norm(m)
    if k ~= "" and not seen[k] then
      seen[k] = true
      match[#match + 1] = m
    end
  end
  entry.match = match

  local installers = copy_of(entry.installers)
  if form.shared then
    installers.windows, installers.macos = installer_of(form.slots.shared), installer_of(form.slots.shared)
  else
    installers.windows, installers.macos = installer_of(form.slots.windows), installer_of(form.slots.macos)
  end
  entry.installers = next(installers) ~= nil and installers or nil

  if form.method == "none" then
    entry.activation = nil
  else
    local activation = copy_of(entry.activation)
    activation.method = form.method
    activation.url = nonempty(form.url)
    activation.instructions = nonempty(form.instructions)
    activation.app = nil
    if form.method == "vendor-app" then
      local orig = is_table(entry.activation) and entry.activation.app
      local app = copy_of(orig)
      for _, platform in ipairs(PLATFORMS) do
        local a = copy_of(is_table(orig) and orig[platform])
        a.name, a.path = nonempty(form.app[platform].name), nonempty(form.app[platform].path)
        app[platform] = next(a) ~= nil and a or nil
      end
      activation.app = next(app) ~= nil and app or nil
    end
    entry.activation = activation
  end
  return entry
end

-- Drops the records of local files no draft installer names any more, so
-- publishing never uploads them; records of files already on the server stay.
local function prune_files()
  local files = state.draft.files
  if not is_table(files) then
    return
  end
  local named = {}
  for _, e in ipairs(plugins_of(state.draft.catalogue)) do
    for _, path in ipairs(core.editor.installer_paths(e)) do
      named[path] = true
    end
  end
  for path, record in pairs(files) do
    if not named[path] and pending_source(record_of(files, path)) then
      files[path] = nil
    end
  end
end

-- Writes the form back into the draft: the entry, and a record for every
-- local installer attached in it.
local function save_form()
  local form = state.form
  local plugins = draft_plugins()
  if not plugins then
    return
  end
  local pos = index_of(plugins, form.entry)
  if not pos then
    state.form = nil
    state.status = "The entry is no longer in the draft."
    return
  end
  local entry = entry_of(form)
  plugins[pos] = entry
  local files = is_table(state.draft.files) and state.draft.files or core.json.object()
  state.draft.files = files
  for _, key in ipairs(active_slots(form)) do
    local slot = form.slots[key]
    if slot.attach and trim(slot.file) ~= "" then
      files[trim(slot.file)] = core.json.object({
        source = slot.attach.source,
        size = slot.attach.size,
        sha256 = slot.attach.sha256,
        uploaded = false,
      })
    end
  end
  prune_files()
  if save_draft() then
    state.form = open_form(entry)
    state.status = ('Saved "%s".'):format(label_of(entry))
  end
end

-- True when the open form may be left: it has no unsaved change, or the user
-- agrees to lose it.
local function leave_form()
  local form = state.form
  return not (form and form.dirty)
    or confirm(('Discard the changes not yet saved to "%s"?'):format(label_of(form.entry)))
end

local function select_entry(entry)
  if state.form and state.form.entry == entry then
    return
  end
  if leave_form() then
    state.form = open_form(entry)
  end
end

local function close_form()
  if leave_form() then
    state.form = nil
  end
end

-- Removes the entry of the open form from the draft, after confirmation.
local function remove_entry()
  local entry = state.form.entry
  local plugins = draft_plugins()
  if not plugins then
    return
  end
  local pos = index_of(plugins, entry)
  if not pos then
    state.form = nil
    return
  end
  if not confirm(('Remove "%s" from the draft?'):format(label_of(entry))) then
    return
  end
  table.remove(plugins, pos)
  state.form = nil
  prune_files()
  if save_draft() then
    state.status = ('Removed "%s" from the draft.'):format(label_of(entry))
  end
end

---------------------------------------------------------------------------
-- Publish and Discard
---------------------------------------------------------------------------

-- Ends a publish run with its outcome: a cleared draft closes the window
-- after showing the report; otherwise the stored draft, with the uploads
-- already made, is shown again with the report in the status line.
local function finish_publish(ok, report)
  state.publishing = nil
  local text = type(report) == "string" and report
    or (ok and "The catalogue was published." or "Publishing failed.")
  local draft, err = rpm.draft.load()
  if draft then
    set_draft(draft)
    state.status = text
  elseif err then
    state.status = text .. "\n" .. err
  else
    message(text)
    state.closing = true
  end
end

-- Runs the publish coroutine up to its next progress report, once per
-- frame, so REAPER stays usable while installers upload.
local function step_publish()
  local run = state.publishing
  local ok, a, b = coroutine.resume(run.co, state.draft)
  if not ok then
    finish_publish(false, "Publishing stopped on an error: " .. tostring(a))
  elseif coroutine.status(run.co) == "dead" then
    finish_publish(a, b)
  else
    run.progress = a
  end
end

local function publish()
  if state.form and state.form.dirty then
    state.status = ('Save or revert the changes to "%s" before publishing.'):format(label_of(state.form.entry))
    return
  end
  set_draft(state.draft) -- looks again for attached local files that are gone
  if state.rejected or state.counts.problems > 0 then
    state.status = "Publishing is blocked: fix the problems shown in the list first."
    return
  end
  local warning = rpm.publish.check(state.draft)
  if warning and not confirm(warning .. "\n\nPublish over the server catalogue anyway? No stops publishing.") then
    state.status = "Publishing stopped: nothing was sent to the server."
    return
  end
  state.form = nil
  state.panel = nil
  state.status = nil
  state.publishing = { co = coroutine.create(rpm.publish.publish), progress = nil }
end

local function discard()
  if not confirm("Discard the catalogue draft? Every change not yet published is lost.") then
    return
  end
  local ok, err = rpm.draft.discard()
  if ok then
    state.closing = true
  else
    state.status = err
  end
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function wrapped(text, colour)
  if colour then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour)
  end
  ImGui.TextWrapped(ctx, text)
  if colour then
    ImGui.PopStyleColor(ctx)
  end
end

local function summary()
  local c = state.counts
  local text = string.format("%d %s in the draft. Since the catalogue it started from: %d added, %d changed, %d removed.",
    c.entries, c.entries == 1 and "entry" or "entries", c.added, c.changed, c.removed)
  if c.problems > 0 then
    text = text .. string.format(" %d with problems.", c.problems)
  end
  return text
end

-- One list row; picking a draft entry's row opens it in the entry form.
local function draw_row(row, i)
  local e = row.entry
  local removed = row.change == "removed"
  local function cell(text)
    ImGui.TableNextColumn(ctx)
    if removed then
      ImGui.TextDisabled(ctx, text)
    else
      ImGui.Text(ctx, text)
    end
  end
  ImGui.TableNextRow(ctx)
  ImGui.TableNextColumn(ctx)
  if removed then
    ImGui.TextDisabled(ctx, label_of(e))
  else
    local selected = state.form ~= nil and state.form.entry == e
    if ImGui.Selectable(ctx, label_of(e) .. "##row" .. i, selected, ImGui.SelectableFlags_SpanAllColumns) then
      state.action = function() select_entry(e) end
    end
  end
  cell(is_table(e) and text_of(e.vendor) or "")
  cell(platforms_of(e))
  cell(activation_of(e))
  ImGui.TableNextColumn(ctx)
  if row.change then
    ImGui.TextColored(ctx, COLOURS[row.change], row.change)
  end
  ImGui.TableNextColumn(ctx)
  if row.problem then
    wrapped(row.problem, COLOURS.problem)
  end
end

-- The list of entries, filling the window below the panels, or `height`
-- pixels when it is given.
local function draw_list(height)
  if #state.rows == 0 then
    ImGui.TextDisabled(ctx, "The draft has no entries.")
    return
  end
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
    | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingStretchProp
  if not ImGui.BeginTable(ctx, "entries", 6, flags, 0, height or 0) then
    return
  end
  local stretch = ImGui.TableColumnFlags_WidthStretch
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableSetupColumn(ctx, "Name", stretch, 3)
  ImGui.TableSetupColumn(ctx, "Vendor", stretch, 2)
  ImGui.TableSetupColumn(ctx, "Platforms", stretch, 2)
  ImGui.TableSetupColumn(ctx, "Activation", stretch, 1.2)
  ImGui.TableSetupColumn(ctx, "Change", stretch, 1)
  ImGui.TableSetupColumn(ctx, "Problem", stretch, 3)
  ImGui.TableHeadersRow(ctx)
  for i, row in ipairs(state.rows) do
    draw_row(row, i)
  end
  ImGui.EndTable(ctx)
end

local function draw_installed()
  wrapped("Pick an installed plugin to add it as a new entry. Plugins the draft already covers, "
    .. "Cockos plugins and JSFX are not listed.")
  local _, filter = ImGui.InputTextWithHint(ctx, "##filter", "Filter", state.filter)
  state.filter = filter
  if #state.groups == 0 then
    ImGui.TextDisabled(ctx, "Every installed plugin is already covered by the draft.")
    return
  end
  if ImGui.BeginChild(ctx, "installed", 0, 180, ImGui.ChildFlags_Border) then
    local needle = filter:lower()
    for i, g in ipairs(state.groups) do
      if needle == "" or g.label:lower():find(needle, 1, true) then
        if ImGui.Selectable(ctx, g.label .. "##group" .. i) then
          state.action = function() add_group(g) end
        end
      end
    end
    ImGui.EndChild(ctx)
  end
end

local function draw_by_hand()
  local h = state.hand
  local _
  _, h.name = ImGui.InputText(ctx, "Name", h.name)
  _, h.vendor = ImGui.InputText(ctx, "Vendor", h.vendor)
  wrapped("Match strings, one per line: the names the plugin goes by in projects - its display name "
    .. "without the format prefix, its file name, its AU or CLAP id.")
  _, h.match = ImGui.InputTextMultiline(ctx, "##match", h.match, 0, 90)
  if ImGui.Button(ctx, "Add entry") then
    state.action = add_by_hand
  end
end

local function draw_import()
  wrapped("Draft entry files in " .. drafts_dir() .. ". Pick one to import its entry; "
    .. "the file is removed once imported.")
  if ImGui.Button(ctx, "Refresh") then
    state.action = refresh_draft_files
  end
  if #state.draft_files == 0 then
    ImGui.TextDisabled(ctx, "There are no draft entry files.")
    return
  end
  for i, name in ipairs(state.draft_files) do
    if ImGui.Selectable(ctx, name .. "##file" .. i) then
      state.action = function() import_draft(name) end
    end
  end
end

local TYPE_LABELS = { [""] = "From the file extension" }

local METHOD_LABELS = {
  none = "none - no activation",
  ["vendor-app"] = "vendor-app - the vendor's app",
  serial = "serial - a serial on the vendor page",
  ["sign-in"] = "sign-in - signing in on the vendor page",
}

-- A combo choosing `value` among `options`, shown through `labels` where it
-- names them; a value not among the options is offered too, so it is never
-- lost. Returns whether it changed, and the value.
local function combo(label, value, options, labels)
  local shown = {}
  for _, o in ipairs(options) do
    shown[#shown + 1] = o
  end
  if value ~= "" and not index_of(shown, value) then
    shown[#shown + 1] = value
  end
  local function text(o)
    return labels and labels[o] or o
  end
  local changed = false
  if ImGui.BeginCombo(ctx, label, text(value)) then
    for _, o in ipairs(shown) do
      if ImGui.Selectable(ctx, text(o), o == value) then
        value, changed = o, true
      end
    end
    ImGui.EndCombo(ctx)
  end
  return changed, value
end

local function edited(form, changed)
  if changed then
    form.dirty = true
  end
end

-- The installer slot `key` of `form`: where its file is, its checksum, and
-- its type, arguments and destination.
local function draw_slot(form, key)
  local slot = form.slots[key]
  local rv
  ImGui.PushID(ctx, key)
  ImGui.SeparatorText(ctx, SLOT_NAMES[key])
  if slot.file == "" then
    ImGui.TextDisabled(ctx, "No installer.")
  else
    wrapped("Server path: " .. slot.file)
    if slot.missing then
      wrapped("Local file " .. slot.source .. " is gone: attach it again.", COLOURS.problem)
    elseif slot.source then
      wrapped("Local file " .. slot.source .. ", uploaded on Publish.")
    else
      wrapped("Already on the server: it keeps its path and is never uploaded.")
    end
    if slot.sha256 ~= "" then
      wrapped("SHA-256: " .. slot.sha256)
    elseif slot.checksum_error then
      wrapped("SHA-256: none, it could not be computed: " .. slot.checksum_error, COLOURS.problem)
    else
      ImGui.TextDisabled(ctx, "SHA-256: none")
    end
  end
  if ImGui.Button(ctx, slot.file == "" and "Attach file..." or "Attach another file...") then
    state.action = function() attach(key) end
  end
  if slot.file ~= "" then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Remove installer") then
      state.action = function() clear_slot(key) end
    end
  end
  local types = { "" }
  for _, t in ipairs(SLOT_TYPES[key]) do
    types[#types + 1] = t
  end
  rv, slot.type = combo("Type", slot.type, types, TYPE_LABELS)
  edited(form, rv)
  if key ~= "macos" then
    rv, slot.args = ImGui.InputTextWithHint(ctx, "Silent-install arguments", "Windows switches or MSI properties",
      slot.args)
    edited(form, rv)
  end
  rv, slot.dest = ImGui.InputTextWithHint(ctx, "Destination", "for archives: vst3, vst2, clap, au or an absolute path",
    slot.dest)
  edited(form, rv)
  ImGui.PopID(ctx)
end

local function draw_activation(form)
  local rv
  ImGui.SeparatorText(ctx, "Activation")
  rv, form.method = combo("Method", form.method, METHODS, METHOD_LABELS)
  edited(form, rv)
  if form.method == "none" then
    return
  end
  if form.method == "vendor-app" then
    for _, platform in ipairs(PLATFORMS) do
      local a = form.app[platform]
      ImGui.PushID(ctx, "app-" .. platform)
      rv, a.name = ImGui.InputText(ctx, SLOT_NAMES[platform] .. " app name", a.name)
      edited(form, rv)
      rv, a.path = ImGui.InputTextWithHint(ctx, SLOT_NAMES[platform] .. " app location",
        platform == "windows" and "path of the app's executable" or "path of the .app bundle", a.path)
      edited(form, rv)
      ImGui.PopID(ctx)
    end
  end
  rv, form.url = ImGui.InputTextWithHint(ctx, "URL",
    form.method == "vendor-app" and "the app's download page" or "the vendor page", form.url)
  edited(form, rv)
  rv, form.instructions = ImGui.InputTextMultiline(ctx, "Instructions", form.instructions, 0, 45)
  edited(form, rv)
end

local function draw_form()
  local form = state.form
  if form.broken then
    wrapped("This entry is not a catalogue entry object, so it cannot be edited: remove it.", COLOURS.problem)
    if ImGui.Button(ctx, "Remove entry") then
      state.action = remove_entry
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Close") then
      state.action = close_form
    end
    return
  end
  local rv
  ImGui.Text(ctx, "Entry " .. (text_of(form.entry.id) ~= "" and form.entry.id or "(no id)"))
  ImGui.SameLine(ctx, 0, 24)
  ImGui.BeginDisabled(ctx, not form.dirty)
  if ImGui.Button(ctx, "Save") then
    state.action = save_form
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Revert") then
    state.action = function() state.form = open_form(form.entry) end
  end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Remove entry") then
    state.action = remove_entry
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Close") then
    state.action = close_form
  end

  rv, form.name = ImGui.InputText(ctx, "Name", form.name)
  edited(form, rv)
  rv, form.vendor = ImGui.InputText(ctx, "Vendor", form.vendor)
  edited(form, rv)
  rv, form.note = ImGui.InputTextWithHint(ctx, "Note", "shown beside the name", form.note)
  edited(form, rv)
  wrapped("Match strings, one per line: the names the plugin goes by in projects.")
  rv, form.match = ImGui.InputTextMultiline(ctx, "##match", form.match, 0, 60)
  edited(form, rv)

  ImGui.SeparatorText(ctx, "Installers")
  if ImGui.RadioButton(ctx, "One installer per platform", not form.shared) then
    set_shared(form, false)
  end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "One package shared by both platforms", form.shared) then
    set_shared(form, true)
  end
  if form.shared then
    draw_slot(form, "shared")
  else
    draw_slot(form, "windows")
    draw_slot(form, "macos")
  end

  draw_activation(form)
end

local PANELS = {
  { key = "installed", button = "Add from installed", draw = draw_installed },
  { key = "hand", button = "Add by hand", draw = draw_by_hand },
  { key = "import", button = "Import draft", draw = draw_import },
}

-- `bytes` as the progress bar shows it.
local function size_text(bytes)
  bytes = tonumber(bytes) or 0
  if bytes >= 1048576 then
    return ("%.1f MB"):format(bytes / 1048576)
  elseif bytes >= 1024 then
    return ("%.0f KB"):format(bytes / 1024)
  end
  return ("%d bytes"):format(math.floor(bytes))
end

-- The window while a publish runs: what it is doing, with the current
-- upload's progress, above the list, which cannot be edited meanwhile.
local function draw_publishing()
  local p = state.publishing.progress
  wrapped("Publishing the draft. REAPER stays usable; this window stays open until publishing ends.")
  if not p then
    ImGui.Text(ctx, "Starting...")
  elseif p.phase == "upload" then
    wrapped(("Uploading installer %d of %d: %s"):format(p.index, p.count, p.path))
    local fraction = (p.total or 0) > 0 and (p.done or 0) / p.total or 0
    ImGui.ProgressBar(ctx, fraction, -1, 0, ("%s of %s"):format(size_text(p.done), size_text(p.total)))
  elseif p.phase == "catalogue" then
    ImGui.Text(ctx, "Replacing the catalogue on the server...")
  elseif p.phase == "cleanup" then
    wrapped(("Deleting installer files no longer referenced, %d of %d: %s"):format(p.index, p.count, p.path))
  end
  ImGui.Separator(ctx)
  ImGui.BeginDisabled(ctx)
  draw_list()
  ImGui.EndDisabled(ctx)
end

local function draw()
  wrapped(summary())
  if state.publishing then
    draw_publishing()
    return
  end
  if state.notice then
    wrapped(state.notice, COLOURS.notice)
  end
  if state.rejected then
    wrapped(state.rejected, COLOURS.problem)
  end
  for i, p in ipairs(PANELS) do
    if ImGui.Button(ctx, p.button) then
      state.action = function() toggle_panel(p.key) end
    end
    ImGui.SameLine(ctx, 0, i == #PANELS and 24 or -1)
  end
  if ImGui.Button(ctx, "Publish") then
    state.action = publish
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Discard") then
    state.action = discard
  end
  if state.status then
    wrapped(state.status)
  end
  for _, p in ipairs(PANELS) do
    if state.panel == p.key then
      ImGui.Separator(ctx)
      p.draw()
    end
  end
  ImGui.Separator(ctx)
  if not state.form then
    if #state.rows > 0 then
      ImGui.TextDisabled(ctx, "Pick an entry to edit or remove it.")
    end
    draw_list()
    return
  end
  draw_list(170)
  if ImGui.BeginChild(ctx, "form", 0, 0, ImGui.ChildFlags_Border) then
    draw_form()
    ImGui.EndChild(ctx)
  end
end

local function loop()
  ImGui.SetNextWindowSize(ctx, 860, 720, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, TITLE, true)
  if visible then
    draw()
    ImGui.End(ctx)
  end
  -- Buttons that open a dialog run between frames, never inside one.
  local action = state.action
  state.action = nil
  if state.publishing then
    step_publish()
  elseif action then
    action()
  end
  if not open and (state.publishing or not state.closing and not leave_form()) then
    open = true
  end
  if open and not state.closing then
    reaper.defer(loop)
  end
end

local function main()
  local guard = rpm.guard()
  if guard then
    message(guard)
    return
  end
  ImGui = load_imgui()
  if not ImGui then
    message(NO_IMGUI)
    return
  end
  local draft, notice = open_draft()
  if not draft then
    return
  end
  set_draft(draft)
  state.notice = notice
  ctx = ImGui.CreateContext(TITLE)
  reaper.defer(loop)
end

main()
