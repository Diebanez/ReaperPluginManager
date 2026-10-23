# Name the REAPER actions as the Action list shows them

## Goal
The documentation and the scripts' header comments call the four REAPER
actions "ReaperPluginManager: Setup", "ReaperPluginManager: Watcher",
"ReaperPluginManager: Check project" and "ReaperPluginManager: Catalogue
management", names REAPER never shows. REAPER's Action list names a script
after its file, so the actions are *Script: RPM_Setup.lua*,
*Script: RPM_Watcher.lua*, *Script: RPM_CheckProject.lua* and
*Script: RPM_CatalogueManager.lua*. The change names them that way wherever
the non-existent names appear outside the domain layer, so a member searching
the Action list finds what the guide names. Wording only.

## Acceptance criteria
- `README.md` § When a project is checked names the watcher action
  *Script: RPM_Watcher.lua* and the on-demand check action
  *Script: RPM_CheckProject.lua*.
- `server/README.md` § Curating the catalogue names the editor action
  **Script: RPM_CatalogueManager.lua**.
- The header comments of `RPM_Setup.lua`, `RPM_Watcher.lua`,
  `RPM_CheckProject.lua` and `RPM_CatalogueManager.lua` name their action
  "Script: RPM_Setup.lua", "Script: RPM_Watcher.lua",
  "Script: RPM_CheckProject.lua" and "Script: RPM_CatalogueManager.lua".
- No file outside `.claude/` and `index.xml` contains "ReaperPluginManager:
  Setup", "ReaperPluginManager: Watcher", "ReaperPluginManager: Check
  project" or "ReaperPluginManager: Catalogue management".
- No code changes: the console-message prefix `"ReaperPluginManager: "` in
  `rpm_reaper.lua`, the window titles and the `@version 1.0.0` header stay as
  they are; the four edited Lua files pass the syntax check.

## Decisions
- **Evidence (user's install):** RPM 1.0.0 installed from ReaPack works;
  `reaper-kb.ini` registers the scripts as `"Custom: RPM_Setup.lua"` and so
  on, and REAPER's Action list shows them as *Script: <file name>*. REAPER
  derives the name from the file name; neither REAPER nor ReaPack lets a
  script set its own action name. `README.md` § Installing already says
  *Script: RPM_Setup.lua*.
- **Rejected (user decision):** renaming the script files to readable names —
  it needs a new release and changes the install paths.
- **`index.xml` is not edited:** the release workflow generates it and picks
  up `README.md` at the next release.
- **No `@version` bump and no tag:** header-comment edits after the 1.0.0
  bump are allowed on master; the next release bumps the version.
- **The console prefix stays:** `"ReaperPluginManager: " .. msg` in
  `rpm_reaper.lua` is a message prefix, not an action name.
- **Short names stay:** the informal short names (*Watcher*, *Check project*,
  *Catalogue management*, *Setup*) in running text and in `RPM_Setup.lua`'s
  `@about` and result message are not presented as Action-list names and are
  outside this change.

## Hints
- `README.md` (~lines 130 and 141, § When a project is checked; line 23
  already uses the real name)
- `server/README.md` (~line 37, § Curating the catalogue)
- `Scripts/ReaperPluginManager/RPM_Setup.lua` (header comment ~line 23)
- `Scripts/ReaperPluginManager/RPM_Watcher.lua` (header comment line 3)
- `Scripts/ReaperPluginManager/RPM_CheckProject.lua` (header comment line 3)
- `Scripts/ReaperPluginManager/RPM_CatalogueManager.lua` (header comment
  line 3)

## Drift
- `.claude/domain/features/setup-action.md` § Interfaces and contracts —
  diverges: names the exposed action "ReaperPluginManager: Setup"; the
  change names it *Script: RPM_Setup.lua* (owner `/architect`).
- `.claude/domain/features/project-watcher.md` § Interfaces and contracts —
  diverges: names the exposed actions "ReaperPluginManager: Watcher" and
  "ReaperPluginManager: Check project"; the change names them
  *Script: RPM_Watcher.lua* and *Script: RPM_CheckProject.lua* (owner
  `/architect`).
- `.claude/domain/features/catalogue-editor.md` § Interfaces and contracts —
  diverges: names the exposed action "ReaperPluginManager: Catalogue
  management"; the change names it *Script: RPM_CatalogueManager.lua* (owner
  `/architect`).
