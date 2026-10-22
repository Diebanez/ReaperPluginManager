-- RPM_CatalogueManager.lua: the "ReaperPluginManager: Catalogue management"
-- action. The maintainer's ReaImGui window over the local catalogue draft:
-- every draft entry, what changed since the catalogue the draft started from,
-- the validation problems that block publishing, and the three ways to add an
-- entry: from REAPER's installed plugins, by hand, or from a draft entry file.

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

-- The validation problems of the draft catalogue, by entry position, and the
-- reason the whole catalogue is invalid, if it is.
local function problems_of(catalogue)
  local valid, warnings = core.catalogue.validate(catalogue)
  if not valid then
    return {}, warnings
  end
  local problems = {}
  for _, w in ipairs(warnings) do
    -- core.catalogue.validate words each one `entry <n>[ "<id>"] skipped: <reason>`.
    local n, why = w:match("^entry (%d+).- skipped: (.*)$")
    if n then
      problems[tonumber(n)] = why
    end
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

  local problems, rejected = problems_of(draft.catalogue)
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
-- Adding entries. Besides `catalogue` and `base`, the draft keeps `files`:
-- per installer server path, a record whose `uploaded` is true once the file
-- is on the server, so publishing never uploads it.
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
  if existing then
    if not confirm(('The draft already has an entry with the id "%s" (%s).\n\n'
        .. "Merge %s into it? Its fields replace the entry's, its match strings are added to the entry's "
        .. "and its installers replace the entry's for the platforms it names.")
        :format(entry.id, text_of(existing.name), name)) then
      return
    end
    core.editor.merge(existing, entry)
  else
    plugins[#plugins + 1] = entry
  end
  mark_on_server(entry)
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
-- Publish and Discard
---------------------------------------------------------------------------

-- catalogue-publish's `publish(draft)`, or nil while that feature is absent.
local function publisher()
  local publish = rpm.publish
  if type(publish) == "table" and type(publish.publish) == "function" then
    return publish.publish
  end
  return nil
end

local function publish()
  if state.rejected or state.counts.problems > 0 then
    state.status = "Publishing is blocked: fix the problems shown in the list first."
    return
  end
  local run = publisher()
  if not run then
    state.status = "Publishing is not available in this version of ReaperPluginManager."
    return
  end
  local ok, report = run(state.draft)
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

local function draw_row(row)
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
  cell(is_table(e) and (text_of(e.name) ~= "" and e.name or text_of(e.id)) or "")
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

local function draw_list()
  if #state.rows == 0 then
    ImGui.TextDisabled(ctx, "The draft has no entries.")
    return
  end
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_Resizable
    | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingStretchProp
  if not ImGui.BeginTable(ctx, "entries", 6, flags) then
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
  for _, row in ipairs(state.rows) do
    draw_row(row)
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

local PANELS = {
  { key = "installed", button = "Add from installed", draw = draw_installed },
  { key = "hand", button = "Add by hand", draw = draw_by_hand },
  { key = "import", button = "Import draft", draw = draw_import },
}

local function draw()
  wrapped(summary())
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
  draw_list()
end

local function loop()
  ImGui.SetNextWindowSize(ctx, 820, 480, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, TITLE, true)
  if visible then
    draw()
    ImGui.End(ctx)
  end
  -- Buttons that open a dialog run between frames, never inside one.
  local action = state.action
  state.action = nil
  if action then
    action()
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
