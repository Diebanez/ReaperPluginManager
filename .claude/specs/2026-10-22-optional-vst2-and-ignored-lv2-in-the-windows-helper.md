# Optional VST2 and ignored LV2 in the Windows helper

## Goal
The project targets VST3 first, with CLAP alongside. Unpacking an archive on
Windows installs VST3 and CLAP as before; a VST2 `.dll` is copied only when
the member has set `vst2_dir`, and is otherwise skipped with a note instead of
failing the whole plugin. `.lv2` bundles are skipped without being looked
into, because their inner `*_dsp.dll` / `*_ui.dll` were being copied as VST2
plugins.

## Acceptance criteria
- `Find-PluginItems` in `rpm-install.ps1` neither returns nor descends into a
  folder whose extension is `.lv2`.
- With `Vst2Dir` empty, an archive's VST2 items (a `.dll`, or any item when the
  entry's `dest` is `vst2`) are not copied and do not fail the entry; the
  helper writes `NOTE <id> <message>` naming the skipped files and that
  `vst2_dir` is not set, before the entry's `OK`.
- With `Vst2Dir` empty and nothing but VST2 items in the archive, the entry
  fails with `FAIL <id> only VST2 plugins in the archive and no VST2 folder
  set (vst2_dir in the settings)`.
- With `Vst2Dir` set, VST2 items are copied there exactly as before.
- `core.install.parse_status` accepts `NOTE <id> <message>`, keeps it on that
  id's item as `note` without changing its state, and still skips unknown
  lines.
- The install progress window shows an item's note under its line, after the
  item is installed.
- `README.md` (§ Settings, `vst2_dir`) and `server/README.md` (Windows
  installers) describe VST2 as optional and skipped by default, and `.lv2`
  folders as ignored.
- The macOS helper is unchanged.

## Decisions
- VST2 is optional and skipped by default; CLAP stays installed alongside
  VST3 (user decisions, 2026-10-22).
- The skip is reported through a new `NOTE` status line rather than as a
  failure, so the plugin still counts as installed.
- macOS is left as is: it has a standard VST2 folder that needs no setting,
  and its helper never routed `.lv2` contents.

## Hints
- Scripts/ReaperPluginManager/helpers/rpm-install.ps1 (`Find-PluginItems`,
  `Get-PluginFolder`, `Install-Zip`, `Install-Entry`)
- Scripts/ReaperPluginManager/rpm_core.lua (`M.install.parse_status`)
- Scripts/ReaperPluginManager/rpm_reaper.lua (`poll_status`, `install_rows`)
- README.md (§ Settings table, `vst2_dir` row)
- server/README.md (Windows installers: the `.dll` routing paragraph)

## Drift
- `.claude/domain/features/install-helper-windows.md` § Architecture (Install by type, zip) — diverges: states `.dll` → Vst2Dir unconditionally and says nothing of `.lv2`; the change skips VST2 when `vst2_dir` is empty (with a `NOTE`) and skips `.lv2` folders.
- `.claude/domain/features/plugin-installation.md` § Helper contract and § Data and state (status file) — diverges: lists `START`/`ITEM`/`OK`/`FAIL`/`DONE` only; the change adds `NOTE <id> <message>`.
- `.claude/domain/features/server-access.md` § Data and state (`[install] vst2_dir`) — settles: an empty `vst2_dir` means VST2 files from archives are skipped.
- `README.md` § Settings (`vst2_dir` row) — settles: empty means VST2 is skipped.
