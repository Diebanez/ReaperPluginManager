# Plugin installation

The REAPER side of installing plugins: it turns the member's confirmed list
into a job for the platform helper, follows the helper's progress without
blocking REAPER, reports the outcome, hands over to licence activation,
guides the member through REAPER's plugin scan so the new plugins work
without a restart, and reloads the project once they do — or reopens it
after a restart when the scan does not find them. It also owns the contract
both helpers implement.

## Purpose

Implements [product-design.md § Plugin installation](../product-design.md#plugin-installation):
installs run in the background, a progress window shows each plugin, a run
asks for administrator rights at most once, and the new plugins become usable
through a guided scan in the running REAPER, with a restart as the fallback.
A run started from a project reloads it once the plugins are detected, or
reopens it on its own after the restart. A run is started from a project by
`project-watcher` or from the catalogue by `catalogue-browser`, which has no
project to reload or reopen.

## Scope and non-goals

In scope:
- The helper contract: job file, status file, helper arguments, routing of
  extracted plugins, running script installers.
- Starting an install run, with or without a project to reopen, one at a
  time across every REAPER script.
- The progress window and the final summary.
- The hand-off to licence activation.
- The guided scan: opening REAPER's FX browser, waiting for the installed
  plugins to be detected, reloading the project.
- Reopening the project after restart, when the guided scan does not detect
  the plugins.

Non-goals:
- Download and install mechanics — `install-helper-windows`,
  `install-helper-macos`.
- Deciding what to install — `project-watcher`, `catalogue-browser`.
- Running the plugin scan itself: REAPER has no action or API for it, only
  the FX browser's "Scan for new plugins" menu item, which the member
  chooses.

## Architecture

Lua ReaScripts with a `gfx` window, per
[technical-direction.md](../technical-direction.md); the helpers are separate
processes.

- **Job writer** — writes one job line per installable entry and clears the
  previous status file.
- **Launcher** — prepares the credentials file and options through
  `server-access`, then starts the platform helper without waiting: on
  Windows `reaper.ExecProcess` with timeout `-2` (no wait, minimized)
  running `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle
  Hidden -File …`, which shows no window (launch constraints:
  [install-helper-windows.md](./install-helper-windows.md#interfaces-and-contracts));
  on macOS `/bin/bash … >/dev/null 2>&1 &`. Paths are passed
  without a trailing backslash, and arguments with no value are omitted.
- **Status reader** — parses the status file each `defer` cycle, counting
  only complete lines.
- **Progress window** — one line per plugin: `Name — queued / downloading… /
  verifying… / installing… / installed / failed` (green installed, red
  failed); an installed plugin's note shows under its line. Closing it
  leaves the run going; the final summary appears anyway. Nothing in the status file 30 s after launch → the helper is
  reported as not started.
- **Completion** — at `DONE`: a summary of installed and failed plugins
  with each failure's message; the installed entries go to
  `licence-activation`; then, when anything was installed, the reopen record
  is written (none for a run started with no project to reopen) and the
  guided scan starts. With nothing installed the run ends after the summary.
- **Guided scan** — a `gfx` window, never a modal message box, because the
  member works in the FX browser while it is open and REAPER must stay
  usable:
  - It opens the FX browser with the main action "View: Show FX browser
    window", only when that toggle action is off, since running it on an
    open browser closes it.
  - The window, "Scan for the new plugins", tells the member to choose "Scan
    for new plugins" in the FX browser (its FX menu, or a right-click on its
    filter field) and lists each installed plugin as `Name — waiting for the
    scan`, or `Name — detected` in green; while a plugin is waiting, a line
    at the bottom says that closing the window falls back to restarting
    REAPER.
  - Each second it re-reads REAPER's installed plugins (`EnumInstalledFX`)
    and marks an entry detected when `plugin-detection`'s presence step
    finds it, as the check does.
  - Every installed entry detected → the reopen record is deleted and the
    window reads "The new plugins are ready to use". A run with a project to
    reopen adds "REAPER detected every new plugin. Reload the project so
    they load in it." and offers "Reload project" and "Not now"; a run with
    no project says "REAPER detected every new plugin." and offers "Close".
    Closing the window, or Escape, answers "Not now". The run ends when the
    member answers, and "Reload project" then opens the recorded project,
    when its file still exists, with `Main_openProject` (REAPER asks to save
    unsaved changes as on any open), so its offline FX load and the watcher
    checks it as on any opening.
  - The member closes the window (or presses Escape), or 3 minutes pass,
    with an entry still waiting → the window gives way to the restart
    message ("Restart REAPER: it detects the new plugins at startup and this
    project reopens. If a plugin does not appear: Preferences > Plug-ins >
    VST > Re-scan."), the reopen record stays, and the run ends. A run
    started with no project to reopen drops the "and this project reopens"
    clause ("Restart REAPER: it detects the new plugins at startup. If a
    plugin does not appear: …").
- **Reopen after restart** — called by the watcher at start: when a reopen
  record exists, it waits 2 s (REAPER finishes loading its own startup
  project), deletes the record, and opens the recorded project if it is not
  already the active one and the file still exists.

### Helper contract

- **Arguments** — job file, status file, work folder, credentials file (only
  when one exists), TLS level, insecure flag; plus platform options
  (destination folders, test switches) defined by each helper.
- **Per job line** — `ITEM <id> download` → download into `work/<id>/` (file
  name = last URL segment, decoded) → with a checksum, `ITEM <id> verify`
  (case-insensitive SHA-256 compare) → `ITEM <id> install` → optionally
  `NOTE <id> <message>` → `OK <id>` or `FAIL <id> <message>`. A failure stops
  only that plugin. `work/<id>` is deleted after success and kept after
  failure.
- **Notes** — `NOTE <id> <message>`, written before the entry's `OK`, tells
  the member something about a plugin that still installed, and leaves the
  item's state unchanged. The Windows helper uses it to name the VST2 files
  it skipped because `vst2_dir` is not set.
- **Routing of extracted plugins** (zip, or dmg without a package) — copy
  only the outermost plugin items, without descending into an item already
  found (a `.vst3` bundle contains a `.vst3` file of the same name); delete
  an existing destination item of the same name before copying, since
  copying a folder over an existing one nests it. An entry's `dest`
  overrides the routing by extension.
- **Script installers** (`type` `script`, schema in
  [plugin-catalogue.md](./plugin-catalogue.md#data-and-state)) — the zip is
  downloaded and verified as usual, unpacked into the work folder, and the
  platform's script runs from the unpacked folder under the `ITEM <id>
  install` step, with the status-file protocol unchanged. On Windows
  `install.ps1` runs inside the elevated helper with the administrator
  rights the run already has, because the plugin folders under Common Files
  need them. On macOS `install.sh` runs as the member, outside the
  administrator prompt, so it writes only where the member can
  ([install-helper-macos.md](./install-helper-macos.md#architecture)). The
  script receives `RPM_PAYLOAD_DIR` (the unpacked folder), `RPM_VST3_DIR`,
  `RPM_CLAP_DIR`, `RPM_VST2_DIR` (empty when the helper has no VST2 folder,
  i.e. `vst2_dir` is not set) and, on macOS, `RPM_AU_DIR` — the helper's
  plugin folders, on macOS those under the member's plugins root. Exit code 0 → `OK <id>`; any other exit code →
  `FAIL <id>` with the script's last non-empty output line, or, when it
  printed nothing, `install script exited with code <n>`. No time limit.
- **End** — `DONE <ok> <failed>`, then delete the credentials file.

## Data and state

- **Job file** (`job.tsv`, local data folder) — UTF-8, one line per plugin,
  tab-separated: `id name type url sha256 args dest`. No field contains a tab
  or a newline (replaced by a space). `url` is complete and percent-encoded:
  server URL + `file` with `\` → `/`, leading `/` removed, every character
  outside `[A-Za-z0-9-._~/]` encoded as `%XX`.
- **Status file** (`status.txt`) — appended by the helper: `START <n>`,
  `ITEM <id> download|verify|install`, `NOTE <id> <message>`, `OK <id>`,
  `FAIL <id> <message>`, `DONE <ok> <failed>`. Only lines ending in `\n`
  count (`\r\n` tolerated); a leading BOM is ignored; `START` may appear
  twice (Windows elevation); unknown lines are skipped.
  `core.install.parse_status` keeps a `NOTE` on its item as `note` without
  changing the item's state. Deleted before every run.
- **Work folder** (`work/`) — downloads, per plugin id.
- **Reopen record** — persistent ExtState `ReaperPluginManager/reopen` = the
  project path, written when a run with a project to reopen installed
  anything and deleted when the guided scan detects every installed entry;
  it stays for the restart otherwise, so quitting REAPER during the scan
  still reopens the project.
- **Install heartbeat** — non-persistent ExtState
  `ReaperPluginManager/install_heartbeat` = the time of the running install's
  last defer cycle, written each cycle from `start` until the run ends and
  then deleted. Every REAPER action runs in its own Lua state, so this is
  how a run is seen by the other scripts.
- **In memory** — the script's own run, the per-plugin progress state, and
  during the guided scan each installed entry's detected flag and the
  scan's start time.

## Interfaces and contracts

- `start(entries, opts) → ok, err` — `entries` are install items, each
  `{ entry, installer }`. `opts.reopen == false` starts a run with no
  project to reopen: no reopen record, no reload offer after the guided
  scan, and the restart message without its reopen clause; without the
  option the active project is recorded for reopening. Refuses while
  `is_running()` is true, so two scripts never share the job and status
  files.
- `is_running() → bool` — true for this script's own run, from `start`
  until its summary, licence activation and guided scan (with its reload
  offer or restart message) are done, or for another script's run whose
  install heartbeat is younger than 3 s.
- `reopen_after_restart()` — idempotent; does nothing without a record.
- Expects: `server-access.helper_options()`,
  `licence-activation.after_install(installed_entries)`,
  `plugin-detection`'s `present_entries(installed, lookup)`.
- Failure contract: a launch failure or a silent helper is reported in the
  progress window and the summary; a run with zero successes writes no
  reopen record and opens no guided scan; a guided scan that does not detect
  every installed entry falls back to the restart message; an error in a
  guided-scan cycle goes to the REAPER console, closes the window and ends
  the run with the reopen record kept.

## Dependencies

- `server-access` — credentials file and transfer options for the helper.
- `plugin-catalogue` — the installer specs and the match index of the
  entries.
- `plugin-detection` — presence of the installed entries during the guided
  scan.
- `install-helper-windows`, `install-helper-macos` — implement the contract.
- `licence-activation` — takes over after a run.
- `project-watcher` — calls `start`, `is_running`, `reopen_after_restart`.
- `catalogue-browser` — calls `start(entries, { reopen = false })` and
  `is_running`.

## Open questions

- Whether REAPER on macOS, with default preferences, detects newly installed
  plugins at startup; on Windows it does.
- Whether `EnumInstalledFX` lists plugins added by an FX-browser scan in the
  same session, and whether the FX browser offers "Scan for new plugins" in
  the same places on macOS — to be checked in REAPER before the guided scan
  is relied on.
