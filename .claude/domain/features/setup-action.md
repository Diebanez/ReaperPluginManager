# Setup action

The one action a user runs to put the tool to work on a machine: it collects
the server connection, saves it, installs the tool into REAPER's actions and
startup, and proves the connection works.

## Purpose

Members and the maintainer both start here. Implements
[product-design.md § Setup](../product-design.md#setup): after one run the
tool checks projects automatically from every REAPER start, and re-running
it changes values without duplicating anything.

## Scope and non-goals

In scope:
- Version and platform guard.
- The setup dialog: server address, user, password, encryption level and
  the automatic-check switch, prefilled with the current values.
- Validation and saving of settings and credentials.
- Registering the tool's actions in REAPER.
- The startup hook in REAPER's `Scripts/__startup.lua`.
- Starting the watcher right away and testing the connection.

Non-goals:
- Editing the less common settings (`insecure`, `vst2_dir`,
  `notify_unknown`) — they stay in the settings file.
- Any maintainer-specific setup: catalogue management uses the same single
  server account.
- Installing ReaImGui or any other dependency.

## Architecture

Built on Lua ReaScripts with REAPER's native dialogs, per
[technical-direction.md](../technical-direction.md).

- **Guard** — refuses REAPER versions without `EnumInstalledFX` ("REAPER 7
  or later is required"); on Linux, says the tool does nothing there and
  exits.
- **Setup dialog** — one `GetUserInputs` dialog with five fields: URL, user,
  password (masked), TLS level, automatic check. Uses a newline field
  separator, because URLs and passwords may contain commas. Proposes the
  current values; the password field starts empty.
- **Validation** — the URL must carry a scheme (`xxx://`) and gains a
  trailing `/`; an invalid TLS value becomes `required`; the automatic-check
  field accepts yes/no forms and defaults to on; a password containing
  whitespace is rejected (the credentials file cannot hold it) and the
  dialog reopens with the other values kept.
- **Save** — writes the settings file and, through `server-access`'s
  credential store, the password. Empty user → anonymous: the stored secret
  is removed. Empty password with the same user → the stored password is
  kept.
- **Action registration** — registers the four action scripts with
  `AddRemoveReaScript`, which is idempotent for an already-registered path.
- **Startup hook** — creates `Scripts/` if missing and writes, into
  `__startup.lua`, a block between `-- >>> ReaperPluginManager` and
  `-- <<< ReaperPluginManager` markers that runs the watcher inside `pcall`
  and reports a failure to the REAPER console. An existing block is replaced
  in place; the rest of the file is left untouched. A failed write is
  reported to the user, not swallowed.
- **Start and test** — starts the watcher at once (by the command id the
  registration returned), then fetches the catalogue and reports
  "Connection succeeded: the catalogue lists N plugins" or the failure
  reason.

## Data and state

- Writes the settings file and the server credential (`server-access` owns
  both formats).
- Writes `__startup.lua`'s marked block; owns nothing else in that file.
- No state of its own: every value it shows is read back from settings and
  credentials.

## Interfaces and contracts

- Exposed: the REAPER action "ReaperPluginManager: Setup".
- Expects from `server-access`: settings load, credential store write and
  delete, and its validation limits for passwords.
- Expects from the catalogue fetch (project-check documents): fetch the
  current catalogue and report its plugin count or a reason.
- Failure contract: a cancelled dialog changes nothing; a failed settings,
  credential or startup-hook write is reported and the remaining steps still
  run where they can; a failed connection test leaves the saved settings in
  place, so the user can fix the server side and re-test by re-running.

## Dependencies

- `server-access` — settings, credentials, transfers.
- The catalogue feature from the project check (catalogue format and
  fetch) — for the connection test.
- The watcher from the project check — started by this action and launched
  by the startup hook.
- REAPER 7+ (`EnumInstalledFX`, `GetUserInputs`, `AddRemoveReaScript`).

## Open questions

None beyond those recorded in `server-access`.
