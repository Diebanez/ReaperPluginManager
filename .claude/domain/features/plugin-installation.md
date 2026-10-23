# Plugin installation

The REAPER side of installing plugins: it turns the member's confirmed list
into a job for the platform helper, follows the helper's progress without
blocking REAPER, reports the outcome, hands over to licence activation, and
reopens the project after REAPER restarts. It also owns the contract both
helpers implement.

## Purpose

Implements [product-design.md § Plugin installation](../product-design.md#plugin-installation):
installs run in the background, a progress window shows each plugin, a run
asks for administrator rights at most once, and the project reopens on its
own after the restart REAPER needs to see new plugins.

## Scope and non-goals

In scope:
- The helper contract: job file, status file, helper arguments, routing of
  extracted plugins, running script installers.
- Starting an install run, one at a time.
- The progress window and the final summary.
- The hand-off to licence activation.
- Reopening the project after restart.

Non-goals:
- Download and install mechanics — `install-helper-windows`,
  `install-helper-macos`.
- Deciding what to install — `project-watcher`.
- Rescanning plugins without a restart (REAPER has no API for it).

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
  message ("Restart REAPER: it detects the new plugins at startup and this
  project reopens. If a plugin does not appear: Preferences > Plug-ins > VST
  > Re-scan.") and the reopen record.
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
  platform's script (`install.ps1` or `install.sh`) runs from the unpacked
  folder with the administrator rights the run already has, under the
  `ITEM <id> install` step; the run's elevation prompt and the status-file
  protocol are unchanged. The script receives `RPM_PAYLOAD_DIR` (the
  unpacked folder), `RPM_VST3_DIR`, `RPM_CLAP_DIR`, `RPM_VST2_DIR` (empty
  when the helper has no VST2 folder, i.e. `vst2_dir` is not set) and, on
  macOS, `RPM_AU_DIR`. Exit code 0 → `OK <id>`; any other exit code →
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
  project path.
- **In memory** — the running flag and the per-plugin progress state.

## Interfaces and contracts

- `start(entries) → ok, err` — refuses while a run is in progress.
- `is_running() → bool`
- `reopen_after_restart()` — idempotent; does nothing without a record.
- Expects: `server-access.helper_options()`,
  `licence-activation.after_install(installed_entries)`.
- Failure contract: a launch failure or a silent helper is reported in the
  progress window and the summary; a run with zero successes writes no
  reopen record.

## Dependencies

- `server-access` — credentials file and transfer options for the helper.
- `plugin-catalogue` — the installer specs in the entries.
- `install-helper-windows`, `install-helper-macos` — implement the contract.
- `licence-activation` — takes over after a run.
- `project-watcher` — calls `start`, `is_running`, `reopen_after_restart`.

## Open questions

- Whether REAPER on macOS, with default preferences, detects newly installed
  plugins at startup; on Windows it does.
