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
- Inspecting the plugin's installers already placed on the group's server.
- Writing one draft entry file and a review report.

Non-goals:
- Downloading installers from vendor sites: installers come from the
  group's server only.
- Anything licence-bearing: no serials, accounts, cracks or keygens, and no
  unofficial download sources.
- Publishing: the maintainer imports, reviews and publishes through
  `catalogue-editor` and `catalogue-publish`.
- Shipping in the ReaPack package.

## Architecture

A Claude Code skill in this repository's `.claude/skills/`, outside the
REAPER scripts, per [technical-direction.md](../technical-direction.md).

- **Invocation** — the plugin name and vendor, plus the server paths of its
  installers (one per platform, or one shared package).
- **Vendor research** — official vendor pages and documentation only: which
  formats the plugin ships (VST2, VST3, AU, CLAP) and the names, file names,
  AU ids and CLAP ids each uses in a project; the activation method, the
  vendor app per platform with its usual location, and the vendor or
  download page.
- **Installer inspection** — fetches each named installer from the group's
  server into a temporary folder using the tool's own settings and
  credentials, through a script that materializes the credentials file
  itself, so the password never enters the conversation. Identifies the
  installer type and generator (Inno Setup, NSIS, InstallShield, WiX/MSI,
  pkg, dmg, zip) from the file, proposes the matching silent switches, and
  computes its SHA-256. The temporary folder is deleted afterwards.
- **Draft writer** — writes one entry in the catalogue schema, with the
  installers' existing server paths, to the `drafts/` folder in the tool's
  local data folder, where the editor's Import draft lists it.
- **Review report** — in the conversation: each field with its source and
  confidence. Silent switches are always marked "test by hand before
  publishing", as are any match strings not confirmed from a source.

## Data and state

- **Draft entry file** (`drafts/<id>.json`, the tool's local data folder in
  REAPER's resource path) — one catalogue entry; its installers reference
  files already on the server.
- Reads the tool's settings file and the server credential through the
  secret-store back end; writes nothing to either.
- No persistent state of its own.

## Interfaces and contracts

- Exposed: a Claude Code skill invoked with the plugin and its installers'
  server paths.
- Produces: a draft entry valid against `plugin-catalogue`'s schema, or no
  file and a stated reason.
- Expects: the tool's settings and credentials set up on the machine (via
  `setup-action`), and the installers already on the server.
- Failure contract: an installer that cannot be fetched is reported and its
  platform left without installer details; unknown fields are left empty
  and listed in the report, never guessed.

## Dependencies

- `plugin-catalogue` — the entry schema the draft must satisfy.
- `catalogue-editor` — imports the draft.
- `server-access` — settings, credentials and the transfer options the
  fetch reuses.
- Claude Code with web access, `curl`.

## Open questions

None.
