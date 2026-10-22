# Project watcher

What the member sees of the project check: the automatic check every time a
project is opened, the on-demand check action, and the single summary window
that lists everything missing and offers to install it.

## Purpose

Implements the user-facing half of
[product-design.md § Project check](../product-design.md#project-check):
the member opens a project and, if anything is missing, sees one window
listing all of it — installable, no installer, unknown, to replace by hand,
activation pending — with the choice to install.

## Scope and non-goals

In scope:
- The background watcher: single instance, open-event detection, error
  isolation, pausing during an install.
- The "Check project" action.
- Assembling a check: installed list, project scan, catalogue fetch,
  classification, activation-pending reminders.
- The summary window and the install hand-off.
- Calling installation's reopen-after-restart once at start.

Non-goals:
- Matching logic (`plugin-detection`), catalogue format and fetch
  (`plugin-catalogue`).
- Running or tracking an install, and the reopen logic itself
  (`plugin-installation`).
- Deciding which plugins are activation-pending (`licence-activation`).

## Architecture

Lua ReaScripts with a `gfx` window, per
[technical-direction.md](../technical-direction.md).

- **Watcher loop** — started from the startup hook; exits at once when
  automatic checking is off. A `defer` loop writes a heartbeat to a
  non-persistent ExtState each cycle; an instance that finds a heartbeat
  younger than 3 s at start exits, so only one runs. Every second it lists
  the open project tabs as (project, path) pairs. A pair present now but not
  in the previous poll with a non-empty path is an open event; it is checked
  on the following poll, so the project has finished loading. Switching tabs
  changes no pair and triggers nothing; closing and reopening a project
  does. Each check runs inside `pcall`: an error goes to the REAPER console
  and the loop continues. While an install runs, open events queue and are
  checked after it ends.
- **Check assembly** — reads the saved project file from disk, enumerates
  installed plugins with `EnumInstalledFX`, fetches the catalogue, runs
  `plugin-detection`, and asks `licence-activation` which of the project's
  installed plugins are activation-pending.
- **Summary window** — one `gfx` window per check, scrollable, listing every
  finding without truncation, grouped: to install (`Name (Vendor) — note`),
  no installer for this platform, not in the catalogue (`Name (Vendor)
  [FORMAT] ×instances`, only when `notify_unknown` is on), instances to
  replace by hand, activation pending. A banner line states when the server
  was unreachable and the cached catalogue was used, and why. Buttons:
  "Install N plugins" (only with something installable) and "Close".
- **Check action** — runs the same assembly on the current project, always
  shows a result: the summary window, "All N plugins are installed", or
  "Save the project first".
- **Install hand-off** — on "Install", passes the installable entries to
  `plugin-installation` and closes the window.

## Data and state

- Non-persistent ExtState `ReaperPluginManager/watcher_heartbeat` — the
  heartbeat time.
- In memory — the previous poll's open (project, path) pairs, and the queue
  of open events deferred during an install.
- No persisted state of its own.

## Interfaces and contracts

- Exposed: the REAPER actions "ReaperPluginManager: Watcher" and
  "ReaperPluginManager: Check project".
- Expects: `plugin-catalogue.fetch`, `plugin-detection.*`,
  `licence-activation.pending_for(installed_refs)`,
  `plugin-installation.start(entries)`, `plugin-installation.is_running()`,
  `plugin-installation.reopen_after_restart()`.
- Failure contract: an unsaved project is never checked automatically; a
  missing project file is reported by the check action and ignored by the
  watcher; a failed check never stops the loop.

## Dependencies

- `plugin-detection`, `plugin-catalogue` — the check itself.
- `plugin-installation` — install start, running state, reopen after
  restart.
- `licence-activation` — the activation-pending list.
- `setup-action` — starts the watcher and installs the startup hook.

## Open questions

- Reloading a project in its own tab keeps the same (project, path) pair
  and is not detected as an open event; whether REAPER exposes a cheap
  signal for it (a project state change count, or the project pointer
  changing on reload) — to be checked in REAPER.
