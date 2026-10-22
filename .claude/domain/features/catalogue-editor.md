# Catalogue editor

The maintainer's window for shaping the catalogue: add plugins from REAPER's
installed list, by hand or from a draft file, attach installers, set install
options and the activation method, and remove entries — all in a local draft
that `catalogue-publish` sends to the server.

## Purpose

Implements the editing half of
[product-design.md § Catalogue management](../product-design.md#catalogue-management):
the maintainer curates the catalogue inside REAPER, where the tool can read
how each plugin names itself in a project, and never hand-edits the
catalogue file.

## Scope and non-goals

In scope:
- The ReaImGui editor window and the "Catalogue management" action.
- The local draft: create from the current catalogue, edit, discard.
- Adding an entry from installed plugins, by hand, or by importing a draft
  entry file.
- Editing every entry field, including installers and activation.
- Computing installer checksums.
- Validation shown inline.

Non-goals:
- Uploading anything — `catalogue-publish`.
- Researching plugins — `catalogue-assistant`, whose output arrives as a
  draft entry file.
- Members' use: the action is meant for the maintainer and needs ReaImGui.

## Architecture

Lua with ReaImGui, per [technical-direction.md](../technical-direction.md).

- **Guard** — without ReaImGui, the action explains that catalogue
  management needs ReaImGui (installable through ReaPack) and exits.
- **Draft store** — on first open, fetches the catalogue and starts a draft
  from it, remembering that fetched copy as the draft's base. The draft
  survives closing the window and restarting REAPER until it is published or
  discarded.
- **Entry list** — every draft entry with its name, vendor, platforms
  covered and activation method; entries changed, added or removed since the
  base are marked; validation problems are shown beside their entry.
- **Add from installed** — lists REAPER's installed plugins grouped by
  `plugin-detection.group_installed`, hiding Cockos plugins, JSFX and plugins
  the draft already covers. Picking a group creates an entry: `id` = unique
  slug of the bare name, `name`, `vendor` = last parenthesis, `match` = the
  base name plus every distinct identifier (file name only for file
  plugins).
- **Add by hand** — name, vendor and match strings typed in.
- **Import draft** — lists the draft entry files in the drafts folder (the
  assistant's output), validates the chosen one against the catalogue
  schema and adds it, or merges it into the entry with the same `id` after
  confirmation; an imported file is then removed from the folder.
- **Entry form** — note; per platform, or once as a shared package: the
  installer, type, silent-install arguments, destination; the activation
  method, app per platform, URL and instructions. An installer is either a
  local file picked from disk — attaching it computes its SHA-256 with OS
  tools (`certutil`/PowerShell on Windows, `shasum -a 256` on macOS) and
  assigns its server path — or a file already on the server, as an imported
  draft names it, kept at its existing path and never uploaded.
- **Remove** — removes an entry from the draft.
- **Publish / Discard** — Publish hands the draft to `catalogue-publish`;
  Discard deletes the draft after confirmation.

## Data and state

- **Draft** (local data folder) — the draft catalogue in the catalogue
  schema; the base catalogue it started from; per attached installer, the
  local source path, the server path it will be uploaded to, its size and
  checksum.
- **Server paths** — a local installer is assigned one folder per entry id:
  `<id>/windows/<file>`, `<id>/macos/<file>`, and `<id>/<file>` for a
  package shared by both platforms (named in both `installers` keys). An
  installer already on the server keeps its own path.
- **Drafts folder** (`drafts/`, local data folder) — draft entry files the
  catalogue assistant writes; Import draft lists them.
- Source of truth: the draft, until published; then the server catalogue.

## Interfaces and contracts

- Exposed: the REAPER action "ReaperPluginManager: Catalogue management".
- Expects: `plugin-catalogue` (fetch, validate, encode), `plugin-detection`
  (`group_installed`, `norm`), `catalogue-publish.publish(draft)`.
- Failure contract: an invalid draft entry blocks Publish and is shown
  inline; a vanished local installer file is flagged on its entry; a failed
  checksum computation leaves the checksum empty and says so.

## Dependencies

- `plugin-catalogue` — schema, validation, codec, fetch.
- `plugin-detection` — installed-plugin grouping and normalization.
- `licence-activation` — the `activation` field's content.
- `catalogue-publish` — sends the draft to the server.
- ReaImGui — the window toolkit, maintainer machine only.

## Open questions

None.
