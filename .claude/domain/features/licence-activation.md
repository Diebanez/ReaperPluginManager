# Licence activation

Guides the member through activating each newly installed plugin with their
own licence, remembers which plugins are still pending, and makes a
reactivation as fast as the law allows by keeping the member's own serials
in the OS secret store.

## Purpose

Implements [product-design.md § Licence activation](../product-design.md#licence-activation):
after an install, each plugin that needs it is activated through the
vendor's own app or page with the member's own account; skipped activations
are flagged and remembered until confirmed. The tool never shares, stores
remotely or bypasses a licence.

## Scope and non-goals

In scope:
- The content of a catalogue entry's `activation` field.
- The walk-through window after an install run.
- The activation-pending record and the pending list the project check
  shows.
- Saving a member's own serial on their machine and copying it to the
  clipboard on Activate.

Non-goals:
- Verifying that a plugin is actually activated — the tool trusts the
  member's confirmation.
- Signing in to vendor accounts, filling in vendor forms, or storing vendor
  account credentials.
- Tracking plugins the tool did not install.
- A way to silence reminders for a pending plugin.

## Architecture

Lua ReaScripts with a `gfx` window, per
[technical-direction.md](../technical-direction.md).

- **Walk-through window** — opened by `plugin-installation` after a run,
  before the restart message, for the installed entries whose method is not
  `none`. One step per vendor app (entries sharing an app are one step,
  listing every plugin in it), otherwise one step per entry. Each step shows
  the plugin name(s) and the maintainer's instruction, with three buttons:
  - **Activate** — for `vendor-app`, opens the app when it is found at its
    recorded location, else its download page; for `serial` and `sign-in`,
    opens the vendor page. When a serial is saved for the entry, also copies
    it to the clipboard.
  - **Done** — clears the pending flag for the step's entries; for a
    `serial` entry with no saved serial, then offers to save one.
  - **Later** — leaves the step's entries pending.
  Closing the window counts as Later for every step not marked Done.
- **Pending record** — every entry entering the walk-through is recorded
  pending until Done.
- **Pending query** — answers the watcher with the pending entries among a
  project's installed plugins; the watcher shows them as a group, each
  entry with an Activate button that reopens the walk-through for it.
- **Opener** — Windows `start "" "<target>"` through `ExecProcess`, run
  under `conhost.exe --headless` so no console window shows (launch
  constraints:
  [install-helper-windows.md](./install-helper-windows.md#interfaces-and-contracts));
  macOS `open -a "<app>"` or `open "<url>"`.
- **Serial store** — the same platform back ends as `server-access`'s
  credential store (Windows DPAPI current-user, macOS Keychain), under
  per-entry keys. The serial is entered through a masked REAPER dialog,
  never placed on a command line, and copied to the clipboard by a process
  that reads it from the secret store directly (PowerShell `Set-Clipboard`,
  `security … -w | pbcopy`).

## Data and state

- **Catalogue `activation` field** (inside each entry, owned here, carried
  by `plugin-catalogue`):
  - `method` — `none` | `vendor-app` | `serial` | `sign-in`; absent means
    `none`;
  - `app` — for `vendor-app`: `windows` and `macos` objects with the app's
    display name and its expected location (executable path; `.app` bundle
    path);
  - `url` — the vendor page, or the app's download page;
  - `instructions` — one or two lines from the maintainer.
- **Pending record** (`activation.ini`, local data folder) — one key per
  pending entry id, valued with the date it entered the walk-through.
  Source of truth for "activation pending".
- **Saved serials** — OS secret store only, keyed by entry id; never in a
  file, never sent anywhere.

## Interfaces and contracts

- `after_install(entries)` — opens the walk-through for those needing
  activation; returns when the window closes, so installation can show its
  restart message.
- `pending_for(installed_refs, catalogue) → entries[]`
- `activate(entries)` — reopens the walk-through for specific entries.
- Failure contract: a missing vendor app falls back to its download page; a
  missing `url` leaves Activate showing only the instructions; a
  secret-store failure skips the clipboard copy and says so; none of these
  changes the pending record.

## Dependencies

- `plugin-installation` — calls `after_install`.
- `project-watcher` — calls `pending_for` and `activate`.
- `plugin-catalogue` — carries the `activation` field.
- `server-access` — the secret-store back ends.
- `catalogue-management` — writes the `activation` field.

## Open questions

- How a vendor app's location is recorded when it is not at a fixed path
  (per-user installs, renamed bundles) — blocks reliable "app found" checks;
  the download-page fallback covers it meanwhile.
