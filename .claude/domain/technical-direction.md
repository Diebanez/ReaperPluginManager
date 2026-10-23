# Technical direction — ReaperPluginManager

ReaperPluginManager is a set of REAPER scripts plus one install helper per
platform, with no compiled code of its own. Everything runs on the user's
machine; the only shared infrastructure is the group's own file server, which
holds the catalogue and the installers. The stack is a greenfield choice that
confirms SPEC.md's: Lua inside REAPER, platform scripts outside it, `curl` for
every transfer.

## Stack

- **Inside REAPER — Lua ReaScripts** (REAPER 7 or later, Lua 5.4,
  `reaper.EnumInstalledFX` required). Covers setup, project check, the
  progress window, licence activation and catalogue management.
- **Catalogue editor UI — ReaImGui.** Needed only on the maintainer's
  machine, for catalogue management; members never need it. Every other
  window uses REAPER's own dialogs and `gfx`.
- **Install helpers — Windows PowerShell 5.1** (`powershell.exe`, ASCII-only
  source) on Windows, **bash 3.2** on macOS. They download, verify, unpack and
  install, driven by plugin installation and catalogue upload.
- **Transfers — `curl`**, as shipped with Windows 10+ and macOS, for
  downloads and the maintainer's uploads alike.
- No other runtime dependency: no Python, no compiled helper, no SWS.

## Topology / architecture

A single product with two halves:

- **Lua side** — a pure-logic module with no `reaper.*` calls (catalogue
  JSON, settings, project-file parsing, plugin matching, classification, job
  and status files), a REAPER-side module (configuration, catalogue fetch,
  project check, helper launch, windows), and one script per REAPER action:
  watcher, check project, catalogue management, setup.
- **Helper side** — one platform helper, launched detached by the Lua side
  for each install run, so REAPER never blocks.

Lua decides and shows; the helper performs downloads and installs. Uploads
for catalogue management are run by `curl` from the Lua side, without
elevation.

## Data and storage

- **Catalogue** — one JSON file at the root of the group's server, beside the
  installers it points at, carrying a format version that older tools refuse.
  Each entry holds the plugin's identity in projects (match strings), one
  installer per platform or one shared package, install options, an optional
  checksum, a note, and the activation method with its link or vendor app.
  It is replaced on the server by upload-then-rename, so members never read
  a half-written file; where the server's rename will not overwrite, the old
  file is deleted just before the rename, and a member checking in that
  instant uses the cached copy.
- **Local data** — under `<REAPER resource path>/ReaperPluginManager/`:
  settings (`config.ini`), server credentials (a `netrc` file, `chmod 600` on
  macOS), the cached catalogue, job and status files, the download work
  folder, and the per-plugin activation-pending record.
- **Members' own licence details** — in the OS secret store only (Windows
  DPAPI, current-user scope; the macOS Keychain), never in a plain file and
  never on the server.

## Async / queueing

The install run is the only work outside the user's interaction: the helper
runs as a separate process, and the Lua side follows it by polling the status
file from REAPER's `defer` loop. The watcher is a `defer` loop too. There is
no queue or scheduler beyond these.

## Hosting and deployment

- **Runtime** — the user's Windows 10/11 or macOS machine, inside REAPER.
- **Server** — whatever the group runs: FTP with explicit TLS, FTPS, HTTPS,
  or a local, network or cloud-synced folder reached by `file://`. No central
  service exists.
- **Release** — a ReaPack package holding the scripts and the helpers,
  indexed by this repository's `index.xml`, which a GitHub Action regenerates
  on every version tag. Users install ReaPack, import the repository, install
  the package and run setup. The example catalogue, the server folder layout
  and a server setup guide that includes the shared-synced-folder option stay
  in the public repository's `server/` folder. The Claude-based catalogue
  assistant lives in this repository's `.claude/` and is left out of the
  package.

## Inter-component protocols

- **Lua ↔ helper** — files only: a tab-separated job file (input) and an
  append-only status file (output), as SPEC.md §3.4–3.5 define them.
- **Tool ↔ server** — `curl` over the configured scheme, credentials passed
  with `--netrc-file`, TLS level from the settings.
- **REAPER start ↔ tool** — a marked block in `Scripts/__startup.lua` that
  launches the watcher; REAPER ExtStates carry the watcher heartbeat and the
  project to reopen after a restart.

## Cross-cutting concerns

- **Identity and roles** — server accounts are the only identity. Members get
  a read-only account, the maintainer a write account; the tool does not
  enforce roles.
- **Elevation** — one UAC prompt per install run on Windows, one
  administrator password per run on macOS, both requested by the helper.
- **Licensing** — the tool opens vendor apps and pages and records the user's
  confirmation; it never stores licence data outside the OS secret store and
  never sends it anywhere.
- **Observability** — errors go to the REAPER console and the run summaries;
  a failed download keeps its work folder for inspection.
- **Testing** — no automated test suite; changes are verified by hand in
  REAPER against real projects.
- **Interface language** — English only.

## Explicitly open decisions

- How catalogue management reads the plugin identities REAPER reports
  (`EnumInstalledFX`'s exact identifier forms per format and platform) — to
  be confirmed in REAPER during implementation, per SPEC.md §11.
- Whether a cross-platform package is unpacked by the same routing rules as
  a per-platform zip — left to `/architect` for catalogue management.
