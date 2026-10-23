# Plugin installation

The REAPER side of installing plugins: it turns the member's confirmed list
into a job for the platform helper, follows the helper's progress without
blocking REAPER, reports the outcome, hands over to licence activation,
offers to restart REAPER so it detects the new plugins, and reopens the
projects after the restart. It also owns the contract both install helpers
implement.

## Purpose

Implements [product-design.md § Plugin installation](../product-design.md#plugin-installation):
installs run in the background, a progress window shows each plugin, a run
asks for administrator rights at most once, and REAPER, which detects new
plugins only when it starts, is restarted on the member's confirmation with
the projects that were open reopened. A run is started from a project by
`project-watcher` or from the catalogue by `catalogue-browser`.

## Scope and non-goals

In scope:
- The helper contract: job file, status file, helper arguments, routing of
  extracted plugins, running script installers.
- Starting an install run, with or without a project to reopen, one at a
  time across every REAPER script.
- The progress window and the final summary.
- The hand-off to licence activation.
- The restart offer: quitting REAPER and starting it again through a
  detached restart helper.
- Reopening the recorded projects after the restart.

Non-goals:
- Download and install mechanics — `install-helper-windows`,
  `install-helper-macos`.
- Deciding what to install — `project-watcher`, `catalogue-browser`.
- Rescanning plugins without a restart (REAPER has no action or API for it).

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
  `licence-activation`; then, when anything was installed, the restart
  offer. With nothing installed the run ends after the summary.
- **Restart offer** — a Yes/No message box: "<N> plugin(s) installed.
  REAPER detects new plugins only when it starts. Restart REAPER now? The
  projects open now reopen after the restart." The run ends with the answer.
  - **Yes** — the reopen record is written with every open project tab that
    has a file, in tab order with the active one last, or deleted when no
    tab has one; the restart helper is launched detached with REAPER's
    executable; then the main action "File: Quit REAPER" runs. REAPER asks to save unsaved changes as on any quit; a
    project never saved has no file and is not reopened. When the member
    cancels the quit, REAPER keeps running, the helper gives up, and the
    record waits for the next start.
  - **No** — the restart message as a reminder ("Restart REAPER: it detects
    the new plugins at startup and this project reopens. If a plugin does
    not appear: Preferences > Plug-ins > VST > Re-scan."), and a run with a
    project to reopen records that project alone. A run started with no
    project to reopen records nothing and drops the "and this project
    reopens" clause ("Restart REAPER: it detects the new plugins at startup.
    If a plugin does not appear: …").
- **Restart helper** — a small platform script, beside the install helpers,
  started like them without waiting (on Windows hidden through PowerShell,
  on macOS `/bin/bash … >/dev/null 2>&1 &` under `nohup`), so it outlives
  REAPER. It polls every 0.5 s until no process runs REAPER's executable
  (Windows: the `reaper.exe` in the folder `GetExePath()` returns, compared
  by full path; macOS: any executable inside the app bundle that contains
  `GetExePath()`), so another REAPER installation running at the same time
  is ignored, then starts REAPER again (Windows: that `reaper.exe`, from its
  own folder; macOS: `open` on the bundle). When REAPER is still running
  after 60 s, it exits without starting anything.
- **Reopen after restart** — called by the watcher at start: when a reopen
  record exists, it waits 2 s (REAPER finishes loading its own startup
  project), deletes the record, and opens each recorded project whose file
  exists and that is not already open: into the current tab when that tab
  has no file and no unsaved changes, as REAPER's empty startup project
  does, otherwise into a new tab ("File: New project tab", then
  `Main_openProject`). The recorded active project ends as the selected
  tab.

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
  project paths in the order to open them, the one to leave selected last,
  on one line: REAPER keeps persistent ExtStates in `reaper-extstate.ini`,
  where a newline would cut the value. Each path has `%` escaped as `%25`,
  and the paths are joined by `%0A` (`core.install.encode_reopen`);
  `core.install.decode_reopen` also splits on raw newlines, so a record
  written one path per line still reads. Written by the restart offer,
  deleted by the reopen after the restart.
- **Install heartbeat** — non-persistent ExtState
  `ReaperPluginManager/install_heartbeat` = the time of the running install's
  last defer cycle, written each cycle from `start` until the run ends and
  then deleted. Every REAPER action runs in its own Lua state, so this is
  how a run is seen by the other scripts.
- **In memory** — the script's own run and the per-plugin progress state.

## Interfaces and contracts

- `start(entries, opts) → ok, err` — `entries` are install items, each
  `{ entry, installer }`. `opts.reopen == false` starts a run with no
  project to reopen: a No to the restart offer records nothing and its
  restart message has no reopen clause, while a Yes still reopens the
  projects that were open; without the option a No records the active
  project. Refuses while `is_running()` is true, so two scripts never share
  the job and status files.
- `is_running() → bool` — true for this script's own run, from `start`
  until its summary, licence activation and restart offer are done, or for
  another script's run whose install heartbeat is younger than 3 s.
- `reopen_after_restart()` — idempotent; does nothing without a record.
- Restart helper: `rpm-restart.ps1 -Exe <reaper.exe>` on Windows,
  `rpm-restart.sh <REAPER.app>` on macOS; no output, no status file.
- Expects: `server-access.helper_options()`,
  `licence-activation.after_install(installed_entries)`.
- Failure contract: a launch failure or a silent helper is reported in the
  progress window and the summary; a run with zero successes offers no
  restart and writes no reopen record; a restart helper that cannot be
  launched is reported in a message, REAPER does not quit, and the record
  stays for the next start.

## Dependencies

- `server-access` — credentials file and transfer options for the helper.
- `plugin-catalogue` — the installer specs in the entries.
- `install-helper-windows`, `install-helper-macos` — implement the contract.
- `licence-activation` — takes over after a run.
- `project-watcher` — calls `start`, `is_running`, `reopen_after_restart`.
- `catalogue-browser` — calls `start(entries, { reopen = false })` and
  `is_running`.

## Open questions

- Whether REAPER on macOS, with default preferences, detects newly installed
  plugins at startup; on Windows it does.
- Whether a process REAPER started survives REAPER quitting on macOS, and
  which path `GetExePath()` gives there (the app bundle or a folder inside
  it) — to be checked in REAPER; on Windows the restart helper survives and
  the restart reopens the projects.
