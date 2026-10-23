# Fall back to delete and rename in safe replace

## Goal
Safe replace uploads `<name>.uploading` and renames it over `<name>`. Servers
whose rename refuses to overwrite an existing file (Windows-hosted FTP such as
IIS FTP and FileZilla Server) make every catalogue publish fail at that
rename. When the rename fails on an FTP, FTPS or HTTPS server, `op_replace`
deletes `<name>` and renames again — the fallback `move_file` already applies
to `file://` servers — so publishing works on those servers too, and nothing
changes on a server that overwrites on rename.

## Acceptance criteria
- On an FTP, FTPS or HTTPS server, when the rename of `<name>.uploading` over
  `<name>` fails, `op_replace` deletes `<name>` and renames
  `<name>.uploading` to `<name>` again; success of that second rename makes
  the replace succeed.
- When the first rename succeeds, `op_replace` makes no delete and no second
  rename.
- When the delete of `<name>` fails, `op_replace` removes `<name>.uploading`
  and returns the first rename's error, as before the change.
- When the delete succeeded and the second rename fails, `op_replace` does
  not remove `<name>.uploading` and returns an error saying `<name>` was
  removed from the server, the new file is on the server as
  `<name>.uploading`, and it must be renamed to `<name>` by hand or published
  again.
- `file://` servers keep their current path: `op_rename`'s `move_file`
  already replaces an existing file, and a failed move removes
  `<name>.uploading` and returns its error.
- The comment above `op_replace` describes the fallback and the one case
  that keeps `<name>.uploading`.

## Decisions
- **Evidence (user's manual test):** in REAPER against a local FTP server
  (pyftpdlib on Windows), Publish uploaded the 22 MB installer and
  `manifest.json.uploading`, then `RNTO manifest.json` failed with
  `550 File exists.`; RPM deleted the temporary file and showed "Publishing
  stopped: ...". Windows-hosted FTP servers (IIS FTP, FileZilla Server)
  refuse a rename over an existing file; vsftpd and ProFTPD on Linux
  overwrite.
- **Accepted trade-off (user decision):** between the delete and the second
  rename the catalogue is briefly absent; a member fetching it in that
  instant gets "not found" and keeps using the locally cached catalogue
  (`catalogue.fetch` falls back to the cache on any download failure,
  `rpm_reaper.lua` `fetch`; `plugin-catalogue.md` § Architecture, Fetch).
- **The temporary file is kept after a failed second rename:** it is then
  the only copy of the file on the server, so deleting it would lose the
  catalogue.
- **The fallback is not applied to `file://` servers:** `op_rename` there
  goes through `move_file`, which already deletes and moves again.

## Hints
- `Scripts/ReaperPluginManager/rpm_reaper.lua` (`op_replace` ~line 654;
  `move_file` ~line 471 for the same fallback on `file://`; `op_rename`,
  `op_delete`; `catalogue_phase` ~line 1205 prefixes the error with
  "Publishing stopped: the catalogue on the server could not be replaced: ")

## Drift
- `.claude/domain/features/server-access.md` § Architecture (Transfer) —
  diverges: states safe replace as upload as `<name>.uploading`, then rename
  over `<name>`; the change adds the delete-and-rename-again fallback when
  the rename does not overwrite (owner `/architect`).
- `.claude/domain/features/server-access.md` § Interfaces and contracts
  (`transfer.replace`) — diverges: says members never observe a partial
  file; that still holds, but the fallback allows a brief absence of
  `<name>`, and a failed second rename leaves the new file only as
  `<name>.uploading` (owner `/architect`).
- `.claude/domain/features/server-access.md` § Scope and non-goals —
  diverges: describes safe replace as upload under a temporary name, then
  rename, without the fallback (owner `/architect`).
- `.claude/domain/technical-direction.md` § Data and storage — diverges: the
  catalogue is replaced by upload-then-rename so members never read a
  half-written file; the fallback adds a delete before the rename on servers
  that do not overwrite (owner `/product-design`).
- `server/README.md` § publishing step 4 (Catalogue replace) — diverges:
  says the catalogue is renamed over `manifest.json` and a failed replace
  leaves the server catalogue unchanged; with the fallback, a failed second
  rename leaves no `manifest.json` and the new catalogue as
  `manifest.json.uploading`.
- `.claude/domain/features/catalogue-publish.md` § Architecture (Catalogue
  phase) and § Interfaces and contracts (failure contract) — settles: a
  catalogue replace failure still means no deletions; the change decides
  the server state such a failure can leave (owner `/architect`).
- `.claude/domain/features/plugin-catalogue.md` § Architecture (Fetch) —
  settles: a failed download falls back to the cache, which is what makes
  the brief absence acceptable (owner `/architect`).
- `README.md` § When the server cannot be reached — settles: a member whose
  check meets the absent catalogue sees the cached-catalogue banner.
