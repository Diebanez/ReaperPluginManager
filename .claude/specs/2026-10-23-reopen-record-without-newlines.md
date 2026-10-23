# Reopen record without newlines

## Goal
The restart offer records every open project in the persistent ExtState
`ReaperPluginManager/reopen`. REAPER keeps persistent ExtStates in
`reaper-extstate.ini` as `key=value`, so a value holding newlines can be cut
at the first one and only one project would reopen. Store the record on one
line instead.

## Acceptance criteria
- `rpm_core.lua` gains pure `M.install.encode_reopen(paths) → string` and
  `M.install.decode_reopen(record) → paths[]`: encoding escapes `%` in each
  path as `%25` and joins the paths with `%0A`; decoding splits on `%0A`,
  unescapes `%25` back to `%`, drops empty parts, and also splits on raw
  `\r`/`\n`, so a record written by 1.3.0 (one path per line) still reads.
- `rpm_reaper.lua`'s restart offer writes the record with `encode_reopen`
  (both the Yes list and the No single project), and `reopen_after_restart`
  reads it with `decode_reopen`.
- A path containing `%0A` or `%25` literally round-trips unchanged.

## Decisions
- `%0A` is the separator rather than a tab or `|`: it stays printable for
  the ini file, and `|` is legal in macOS paths.

## Hints
- Scripts/ReaperPluginManager/rpm_core.lua (`M.install`, beside
  `parse_status`)
- Scripts/ReaperPluginManager/rpm_reaper.lua (`offer_restart`,
  `M.install.reopen_after_restart`)
- .claude/domain/features/plugin-installation.md (§ Data and state, Reopen
  record)

## Drift
- `.claude/domain/features/plugin-installation.md` § Data and state —
  diverges: the reopen record is described as one project path per line;
  the change stores the paths on one line, joined by `%0A` with `%` escaped.
