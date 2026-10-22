-- RPM_CatalogueManager.lua: the "ReaperPluginManager: Catalogue management"
-- action. The maintainer's ReaImGui window over the local catalogue draft:
-- every draft entry, what changed since the catalogue the draft started from,
-- and the validation problems that block publishing.

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

local function draw()
  wrapped(summary())
  if state.notice then
    wrapped(state.notice, COLOURS.notice)
  end
  if state.rejected then
    wrapped(state.rejected, COLOURS.problem)
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
