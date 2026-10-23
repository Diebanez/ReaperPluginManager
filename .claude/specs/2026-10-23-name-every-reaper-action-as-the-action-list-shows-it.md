# Name every REAPER action as the Action list shows it

## Goal
Wherever a user-facing text names one of the four REAPER actions so that a
reader would look it up in REAPER's Action list, it uses the name the Action
list shows — *Script: RPM_Setup.lua*, *Script: RPM_Watcher.lua*,
*Script: RPM_CheckProject.lua*, *Script: RPM_CatalogueManager.lua* — instead
of a short or invented name, so the reader can search for it. A sentence that
describes what an action does (the watcher checks each project, Setup asks
for the connection) may keep a plain descriptive noun; window titles stay.

## Acceptance criteria
- `README.md` names the actions by their Action-list names where it calls
  them actions or tells the reader to run them: the maintainer's ReaImGui
  note, the list of the four actions Setup registers, the instructions to run
  the check on demand, and the instructions to run Setup again (in *What
  Setup does*, *Turning automatic checks off* and *Settings*).
- `server/README.md`'s opening paragraph names the catalogue editor as the
  **Script: RPM_CatalogueManager.lua** action.
- `RPM_Setup.lua`'s ReaPack `@about` text names the four actions, and the
  action to run first, by their Action-list names; `@version` and the
  `@provides` list are unchanged, and `index.xml` is not edited.
- Setup's result line on success reads
  "Actions registered: Script: RPM_Watcher.lua, Script: RPM_CheckProject.lua,
  Script: RPM_CatalogueManager.lua, Script: RPM_Setup.lua."
- Setup's registration failure lines in `rpm_reaper.lua` name the action
  that failed as "Script: <file>".
- The "run Setup." hints in `rpm_reaper.lua`'s error messages, and in the
  catalogue assistant's `fetch-installer.sh`, read "run Script: RPM_Setup.lua".
- Window titles, the "ReaperPluginManager: " console prefix, descriptive
  mentions (the watcher's status lines in Setup's report, the section
  headings, "Setup asks ...") and the catalogue editor's own ReaImGui message
  are unchanged.
- Every edited Lua file passes the syntax check.

## Decisions
- REAPER names a script action after its file name (*Script: <file>*);
  neither REAPER nor ReaPack lets a script set its own name, so renaming the
  files was rejected (user decision).
- Changing Setup's result message is an approved user-facing text change
  (user decision).
- The new `@about` reaches `index.xml` only at the next release: no
  `index.xml` edit, no `@version` bump, no tag (user decision).
- The console-message prefix "ReaperPluginManager: " stays (user decision).
- The catalogue editor's "Catalogue management needs the ReaImGui extension"
  message stays: that action shows it itself, so the reader has nothing to
  look up.
- The registration failure lines take the name from the file
  ("Script: " .. file), so the action table no longer carries a second name.

## Hints
- README.md (lines ~42, ~86-87, ~99, ~103, ~106-107, ~135, ~313)
- server/README.md (line ~5)
- Scripts/ReaperPluginManager/RPM_Setup.lua (`@about`; the "Actions
  registered" line)
- Scripts/ReaperPluginManager/rpm_reaper.lua (`ACTIONS` and
  `M.setup.register_actions`; the "run Setup." messages)
- .claude/skills/catalogue-assistant/fetch-installer.sh (the "run Setup"
  failure messages)

## Drift
- `.claude/domain/features/setup-action.md` § Architecture (Action
  registration) — settles: Setup's report names the registered actions, and
  any that failed to register, by their Action-list names.
