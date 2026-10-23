# Replace the conhost headless launches on Windows

## Goal
Windows Defender blocks the `conhost.exe --headless` launches as
Trojan:Win32/Commando.A!ml. Replace both with launches that show no window
and are not flagged: the licence-activation opener runs `explorer.exe
"<target>"`, and the background upload's cmd line runs through a new static
helper, `rpm-run-hidden.ps1`, started the way the install helper is.

## Acceptance criteria
- `open_target` in `Scripts/ReaperPluginManager/rpm_reaper.lua`, on Windows,
  runs `explorer.exe "<target>"` through `reaper.ExecProcess(cmd, -1)`, with
  the target's double quotes stripped as before; the macOS branch is
  unchanged.
- `launch_background` on Windows builds the same cmd line as before —
  `<curl command> && (echo EXIT 0)>><status> || (echo EXIT -)>><status>` —
  writes it to a temporary line file in the data folder, and starts
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden
  -File "<helpers>\rpm-run-hidden.ps1" -LineFile "<file>"` through
  `reaper.ExecProcess(cmd, -2)`; it returns false when the line file cannot
  be written or the launch fails. The macOS branch is unchanged.
- The line file's name falls under the data folder's stale-file sweep.
- `Scripts/ReaperPluginManager/helpers/rpm-run-hidden.ps1` exists: it reads
  the line with `[IO.File]::ReadAllText` as UTF-8, starts `cmd.exe` through
  `System.Diagnostics.ProcessStartInfo` with `Arguments = '/d /s /c "' +
  line + '"'`, `UseShellExecute = $false`, `CreateNoWindow = $true`, waits
  for it, and deletes the line file whatever happened. No parameter is
  mandatory.
- `rpm-run-hidden.ps1` targets Windows PowerShell 5.1, is ASCII-only
  (comments and messages included), parses without errors, and relies on no
  module that breaks under a PowerShell 7 `PSModulePath`.
- No `conhost` remains anywhere in the Lua source.
- `CLAUDE.md` § Layout lists `rpm-run-hidden.ps1` among the helpers, and
  § Conventions states its PowerShell 5.1 and ASCII-only constraints.
- The install helper launch and every waited `ExecProcess` call are
  unchanged.

## Decisions
- **Launch evidence (user's test in REAPER on Windows 11):** `cmd.exe` or
  `powershell.exe` through `ExecProcess` `-1` shows a window;
  `powershell.exe -WindowStyle Hidden` through `ExecProcess` `-2` shows none
  (the install helper's launch, never flagged by Defender); a waited
  `ExecProcess` shows none.
- **conhost --headless is banned:** `conhost.exe --headless cmd.exe /d /c
  start <url>` showed no window, but Defender blocked it three times as
  Trojan:Win32/Commando.A!ml (ML detection on the command-line pattern), so
  it is used nowhere.
- **Opener: `explorer.exe "<target>"`** — a GUI-subsystem program, so no
  console is created; it opens a URL in the default browser and starts an
  application path.
- **Background upload: hidden PowerShell runner with a line file and
  `ProcessStartInfo` `CreateNoWindow`** (user's choice).
- **The line goes in a plain line file, never a `.cmd`/`.bat`:** in a batch
  file `%` would need doubling and would corrupt percent-encoded URLs; on a
  `cmd /c` command line it does not.
- **No PowerShell native-argument passing** (`& cmd.exe ... $line`): Windows
  PowerShell 5.1 mangles embedded double quotes.
- **The line file takes the `upload` transient prefix**, so the existing
  stale-file sweep removes one a failed launch leaves behind.

## Hints
- Scripts/ReaperPluginManager/rpm_reaper.lua (`launch_background`,
  `open_target`, `temp_path`, `write_private`, `helpers_dir`, the
  `TRANSIENT_PREFIXES` sweep, `launch_helper` for the PowerShell launch form)
- Scripts/ReaperPluginManager/helpers/rpm-run-hidden.ps1 (new)
- Scripts/ReaperPluginManager/helpers/rpm-install.ps1 (header and
  PowerShell 5.1 style to follow)
- CLAUDE.md (§ Layout, § Conventions)
- .claude/domain/features/install-helper-windows.md (§ Interfaces and
  contracts: source and launch constraints)

## Drift
- `.claude/domain/features/install-helper-windows.md` § Interfaces and
  contracts — diverges: the Launch constraints bullet says to prefix a
  `cmd.exe` line with `conhost.exe --headless`; the change bans conhost
  `--headless`, runs background cmd lines through `rpm-run-hidden.ps1`
  (line file, `CreateNoWindow`) and opens URLs and applications with
  `explorer.exe`.
- `.claude/domain/features/install-helper-windows.md` § Architecture —
  settles: the document describes only the install helper's parts and says
  nothing of a runner script for background cmd lines; the change adds
  `rpm-run-hidden.ps1` beside it.
- `.claude/domain/features/licence-activation.md` § Architecture (Opener) —
  diverges: the document says Windows runs `start "" "<target>"` under
  `conhost.exe --headless`; the change runs `explorer.exe "<target>"`.
- `.claude/domain/features/server-access.md` § Architecture (Transfer) —
  diverges: the document says the Windows background upload runs `cmd.exe`
  under `conhost.exe --headless`; the change runs the cmd line through
  `rpm-run-hidden.ps1`.
- `CLAUDE.md` § Layout and § Conventions — settles: the helpers list and the
  PowerShell 5.1 / ASCII-only convention gain `rpm-run-hidden.ps1`; updated
  by this change.
