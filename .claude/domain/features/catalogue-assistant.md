# Catalogue assistant

A Claude Code skill that researches one plugin and proposes its catalogue
entry — formats and project names, installer technology and silent
switches, activation method — as a draft entry file the catalogue editor
imports, with a report of what still needs testing by hand.

## Purpose

Implements [product-design.md § Catalogue assistant](../product-design.md#catalogue-assistant).
Silent-install switches and activation methods differ per vendor and per
installer generator; getting them right is research, not data entry. The
assistant does that research so the maintainer reviews a proposal instead
of starting from a blank form. It is the maintainer's personal aid and is
not part of the open-source release.

## Scope and non-goals

In scope:
- Researching a plugin from official vendor sources.
- Inspecting the plugin's installers: files already on the group's server,
  or local files on the maintainer's machine.
- Writing one draft entry file and a review report.

Non-goals:
- Downloading installers from vendor sites: installers come from the
  group's server or the maintainer's own local files only.
- Anything licence-bearing: no serials, accounts, cracks or keygens, and no
  unofficial download sources.
- Publishing: the maintainer imports, reviews and publishes through
  `catalogue-editor` and `catalogue-publish`.
- Shipping in the ReaPack package.

## Architecture

A Claude Code skill in this repository's `.claude/skills/`, outside the
REAPER scripts, per [technical-direction.md](../technical-direction.md).

- **Invocation** — the plugin name and vendor, plus its installers (one per
  platform, or one shared package), each a server path or the path of a
  local file.
- **Vendor research** — official vendor pages and documentation only: which
  formats the plugin ships (VST2, VST3, AU, CLAP) and the names, file names,
  AU ids and CLAP ids each uses in a project; the activation method, the
  vendor app per platform with its usual location, and the vendor or
  download page.
- **Installer inspection** — fetches each server installer into a temporary
  folder using the tool's own settings and credentials, through a script
  that materializes the credentials file itself, so the password never
  enters the conversation; a local installer is inspected where it is,
  never copied or changed. Identifies the installer type and generator
  (Inno Setup, NSIS, InstallShield, WiX/MSI, pkg, dmg, zip) from the file,
  proposes the matching silent switches, and computes its SHA-256. The
  temporary folder is deleted afterwards.
- **Draft writer** — writes one entry in the draft schema
  (`catalogue-editor`'s drafts folder) to the `drafts/` folder in the tool's
  local data folder, where the editor's Import draft lists it: a server
  installer by its server path and checksum, a local one by its absolute
  path as `source`, each with its type, silent switches and `dest`, so
  Import draft leaves nothing to attach by hand.
- **Review report** — in the conversation: each field with its source and
  confidence. Silent switches are always marked "test by hand before
  publishing", as are any match strings not confirmed from a source.

## Data and state

- **Draft entry file** (`drafts/<id>.json`, the tool's local data folder in
  REAPER's resource path) — one catalogue entry; its installers reference
  files already on the server or local files the editor uploads on publish.
- Reads the tool's settings file and the server credential through the
  secret-store back end; writes nothing to either.
- No persistent state of its own.

## Interfaces and contracts

- Exposed: a Claude Code skill invoked with the plugin and its installers'
  server or local paths.
- Produces: a draft entry valid against the draft schema, or no file and a
  stated reason.
- Expects: for server installers, the tool's settings and credentials set
  up on the machine (via `setup-action`) and the files already on the
  server; for local installers, files readable on this machine.
- Failure contract: an installer that cannot be fetched or read is reported
  and its platform left without installer details; unknown fields are left
  empty and listed in the report, never guessed.

## Dependencies

- `plugin-catalogue` — the entry schema the draft must satisfy.
- `catalogue-editor` — imports the draft.
- `server-access` — settings, credentials and the transfer options the
  fetch reuses.
- Claude Code with web access, `curl`.

## Open questions

None.
