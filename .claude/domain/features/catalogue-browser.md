# Catalogue browser

A member-facing action that lists every plugin the group's catalogue offers,
with its state on this machine, and installs the ones the member ticks —
without a project needing them. It is the project check's install path
started from the catalogue instead of from a project.

## Purpose

Implements [product-design.md § Catalogue browser](../product-design.md#catalogue-browser):
a member who wants a plugin before any project uses it opens one window,
sees what is installed, what can be installed here and what has no installer
for this platform, ticks what they want and installs it through the same run,
activation walk-through and restart message as the project check.

## Scope and non-goals

In scope:
- The action "Script: RPM_Browse.lua": guard, the refusal while an install
  runs, the catalogue fetch with cached fallback.
- Working out each catalogue entry's state on this machine.
- The browser window: list, checkboxes, scrolling, the search field, Install
  and Close.
- The install hand-off: the unmanaged confirmation, then
  `plugin-installation.start` with no project to reopen.
- The extensions to existing features this needs (§ Architecture, *Shared
  with existing features*).

Non-goals:
- Reinstalling or updating an installed plugin: installed entries are shown,
  never selectable.
- Activation-pending reminders: the project check owns them.
- Instances to replace, unknown plugins and anything else tied to a project.
- Reopening a project after the restart.
- Registration beyond what setup does for every action, and releasing:
  the ReaPack `@version` and tag belong to the release step.

## Architecture

Lua ReaScripts with a `gfx` window, per
[technical-direction.md](../technical-direction.md): members need no
ReaImGui. The pure parts live in the pure-logic module, the window and the
hand-off in the REAPER-side module, and the action script only calls them,
as the check action does.

- **Browse action** — runs the guard (REAPER 7, Windows or macOS), then
  refuses with "An install is already running. Try again when it has
  finished." when `plugin-installation.is_running()` is true. Otherwise it
  enumerates installed plugins (the check's `EnumInstalledFX` listing),
  fetches the catalogue, builds the rows and opens the window. No catalogue
  at all (no server and no cache) → a message carrying the fetch reason and
  no window; a catalogue with no plugins → "The catalogue lists no plugins."
- **Entry states** (pure) — one row per valid catalogue entry, sorted by
  name case-insensitively:
  - `installed` — the entry is *present*: some installed plugin associates
    with it through the match index, exactly as `plugin-detection` decides
    presence for the project check; installed wins over every other state;
  - `installable` — not installed, and the entry has an installer for this
    platform;
  - `no_installer` — not installed, and no installer for this platform.
  Each row also carries the entry's unmanaged flag for this platform
  (`plugin-catalogue.unmanaged`) and its platform installer, so an
  installable row is directly an install item.
- **Filter** (pure) — a case-insensitive plain substring match of the typed
  text against the entry name; an empty text shows every row.
- **Browser window** — one scrollable `gfx` window. A heading counts the
  catalogue's plugins, how many are installed and how many are installable;
  the catalogue-source banner of the summary window states when the cached
  catalogue was used and why. Under it the search field, then the rows:
  installable rows carry a checkbox, toggled by a click anywhere on the row;
  installed and no-installer rows carry no checkbox and show their state
  ("installed", "no installer for Windows/macOS") instead. A row reads
  `Name (Vendor)`, with "unmanaged installer" beside the name of an
  unmanaged entry and the maintainer's note after it, as the summary window
  writes them. Ticks are kept by entry id, so filtering never drops a tick
  on a hidden row. Buttons: "Install N plugins", counting every ticked
  entry, shown only when N > 0, and "Close".
- **Keyboard** — printable characters append to the search text, Backspace
  removes the last character, Escape clears a non-empty search and
  otherwise closes the window; arrow, page and Home/End keys and the wheel
  scroll the list, as in the summary window.
- **Install hand-off** — on Install: when `is_running()` has become true
  while the window was open, the refusal message is shown and the window
  stays open. Otherwise the unmanaged confirmation runs over the ticked
  entries; declining keeps the window and its ticks. Once confirmed, the
  window closes and the ticked rows go to `plugin-installation.start` with
  no project to reopen. A refusal from `start` is shown as a message. From
  there the run is plugin-installation's: progress window, summary, licence
  activation's walk-through, the restart message.

### Shared with existing features

What the browser shares is extracted once and called by both callers, never
copied:

- **Presence detection** (`plugin-detection`) — the classifier's inline
  "entry present" step becomes a pure function returning the set of entries
  some installed plugin associates with; the classifier and the entry states
  both call it.
- **Platform installer** (`plugin-catalogue`) — the "installer for this
  platform, absent when missing or null" lookup the classifier does inline
  becomes a catalogue function beside `unmanaged`; the classifier and the
  entry states both call it.
- **Unmanaged confirmation** (`project-watcher`) — the one-prompt warning of
  the install hand-off becomes a shared function taking the entries to
  install, the platform and the window title, with its platform wording
  unchanged; the summary window and the browser both call it.
- **List primitives** (`project-watcher`) — the summary window's text
  wrapping, button drawing and hit-testing, scrolling keys and wheel,
  scrollbar and catalogue-source banner are shared by the browser window
  rather than duplicated.
- **Install start without reopen** (`plugin-installation`) — `start` gains
  an option saying the run has no project to reopen: no reopen record is
  written, and the restart message drops its "this project reopens" clause
  ("Restart REAPER: it detects the new plugins at startup. If a plugin does
  not appear: Preferences > Plug-ins > VST > Re-scan."). Without the option
  the project check's behaviour is unchanged.
- **Install running across scripts** (`plugin-installation`) — every REAPER
  action runs in its own Lua state, so a run's in-memory flag is invisible to
  the browse action when the run was started by the watcher or the check
  action. The running state is published as a non-persistent ExtState
  heartbeat, refreshed each defer cycle of the run and deleted when it ends;
  `is_running()` is true for the script's own run or a heartbeat younger than
  3 s, as the watcher's single-instance heartbeat works. `start` refuses on
  it, so two scripts never share the job and status files at once, and the
  watcher's pause during an install covers runs the browser starts.
- **Action registration** (`setup-action`) — setup registers
  "Script: RPM_Browse.lua" with the other actions and names it in its
  report; the package ships it as a `[main]` file in `RPM_Setup.lua`'s
  `@provides`, and its `@about` lists five actions.

## Data and state

- In memory, for the window's life: the fetched catalogue and its source
  and reason, the rows, the search text, the set of ticked entry ids, the
  scroll position.
- Non-persistent ExtState `ReaperPluginManager/install_heartbeat` — the
  heartbeat time of a running install, owned by `plugin-installation`.
- Nothing persisted by the browser; no reopen record is ever written for a
  browser run.

## Interfaces and contracts

- Exposed: the REAPER action "Script: RPM_Browse.lua".
- Pure: `browse.rows(catalogue, installed, platform) → rows[]`, each
  `{ entry, state, installer, unmanaged }` with `state` one of `installed`,
  `installable`, `no_installer`; `browse.filter(rows, text) → rows[]`.
- Shared, extracted as above: `present_entries(installed, lookup) → set`,
  `catalogue.installer(entry, platform) → installer | nil`,
  `confirm_unmanaged(items, platform, title) → bool`.
- Expects: `plugin-catalogue.fetch`, `plugin-catalogue.index`,
  `plugin-catalogue.unmanaged`, the check's installed-plugin listing,
  `plugin-installation.start(entries, { reopen = false })`,
  `plugin-installation.is_running()`.
- Failure contract: the guard and the running refusal open no window; a
  fetch failure falls back to the cache and says so in the banner; no
  catalogue opens no window; a malformed entry is already dropped by
  catalogue validation; an error in a window cycle goes to the REAPER
  console and closes the window, as the summary window does.

## Dependencies

- `plugin-catalogue` — fetch with cached fallback, the match index, the
  unmanaged flag, the platform installer.
- `plugin-detection` — presence of an entry among installed plugins.
- `plugin-installation` — `start` without reopen, the cross-script
  `is_running`, the run itself and its hand-off to licence activation.
- `licence-activation` — reached through plugin-installation's completion;
  nothing called directly.
- `project-watcher` — the unmanaged confirmation and the list primitives it
  shares.
- `setup-action` — registers the action.

## Open questions

- Whether `gfx.getchar` delivers non-ASCII characters typed in the search
  field, and in which encoding — to be checked in REAPER on both platforms;
  ASCII typing does not depend on it.
