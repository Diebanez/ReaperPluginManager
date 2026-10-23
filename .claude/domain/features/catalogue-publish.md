# Catalogue publish

Sends the maintainer's draft to the server: uploads the new installers in
the background, replaces the catalogue in one safe step, then deletes the
installer files the new catalogue no longer references.

## Purpose

Implements the publishing half of
[product-design.md § Catalogue management](../product-design.md#catalogue-management):
members only ever see a complete, consistent catalogue whose every
installer exists on the server.

## Scope and non-goals

In scope:
- Detecting a catalogue changed on the server since the draft began.
- Background upload of new and replaced installers, with progress.
- Replacing the catalogue safely.
- Deleting installer files no longer referenced.

Non-goals:
- Editing the draft — `catalogue-editor`.
- Server-side permissions: a read-only account fails with the server's
  error.

## Architecture

Lua with ReaImGui progress, transfers through `server-access`, per
[technical-direction.md](../technical-direction.md).

- **Change check** — re-fetches the server catalogue; when it differs from
  the draft's base, warns that the server changed since editing began (for
  example from another machine) and asks whether to publish over it or
  stop.
- **Upload phase** — uploads each attached installer not yet on the server
  to its server path, one at a time in the background, showing per-file
  progress in the editor window; REAPER stays usable. Any failure stops the
  publish before the catalogue is touched and reports which file failed;
  installers already uploaded stay and are not uploaded again on retry.
- **Catalogue phase** — encodes the draft and replaces the server catalogue
  with `server-access`'s safe replace; the new catalogue becomes the local
  cache.
- **Cleanup phase** — deletes every installer file the base catalogue
  referenced and the new one does not. A failed delete is reported and
  leaves an orphan file; the publish still counts as done.
- **Finish** — the draft is cleared and a summary lists uploads, catalogue
  replacement and deletions.

## Data and state

- Reads the draft and its base from `catalogue-editor`'s draft store.
- Per-installer upload state in the draft (uploaded or not), so a retried
  publish resumes.
- No state of its own after a successful publish.

## Interfaces and contracts

- `publish(draft) → ok, report` — runs the three phases in order; never
  replaces the catalogue unless every upload succeeded.
- Expects from `server-access`: `upload_async`, `replace`, `delete`, and the
  catalogue fetch from `plugin-catalogue`.
- Failure contract: upload failure → no catalogue change; catalogue replace
  failure → no deletions, the server catalogue left as `server-access`'s
  `transfer.replace` contract states; delete failure → reported orphan only.

## Dependencies

- `catalogue-editor` — the draft.
- `plugin-catalogue` — fetch, encode, cache.
- `server-access` — asynchronous upload, safe replace, delete.

## Open questions

None beyond `server-access`'s question on writing over HTTPS.
