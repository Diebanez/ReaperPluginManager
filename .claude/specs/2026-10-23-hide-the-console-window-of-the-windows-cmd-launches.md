# Hide the console window of the Windows cmd launches

## Goal
On Windows, the two no-wait `cmd.exe` launches flash a visible console window:
licence activation's opener (vendor app or sign-in URL) and catalogue
publishing's background installer upload. Prefixing each command with
`conhost.exe --headless` runs it under a console host that creates no window,
with no quoting change and no measurable block of REAPER.

## Acceptance criteria
- `open_target` in `Scripts/ReaperPluginManager/rpm_reaper.lua` builds, on
  Windows, `conhost.exe --headless cmd.exe /d /c start "" "<target>"` — the
  existing command text unchanged after the prefix — and still runs it with
  `reaper.ExecProcess(cmd, -1)`.
- `launch_background` in the same file builds, on Windows,
  `conhost.exe --headless cmd.exe /d /s /c "<curl …> && (echo EXIT 0)>>… || (echo EXIT -)>>…"`
  — the existing command text unchanged after the prefix — and still runs it
  with `reaper.ExecProcess(cmd, -1)`.
- The macOS branches of both functions are unchanged.
- The install helper launch (`powershell.exe … -WindowStyle Hidden` with
  `ExecProcess(cmd, -2)`) and every waited `ExecProcess` call (curl, the
  secret helper, checksums) are unchanged.

## Decisions
- **Evidence (user's launch test in REAPER on Windows 11):** a window shows
  for `cmd.exe` via `ExecProcess -1` and for `powershell.exe -WindowStyle
  Hidden` via `ExecProcess -1`. No window for `powershell.exe -WindowStyle
  Hidden` via `ExecProcess -2` (the current helper launch); `conhost.exe
  --headless <cmd>` via `ExecProcess -1` (REAPER blocked 17 ms, the process
  ran to completion); a waited PowerShell launcher using `Start-Process
  -WindowStyle Hidden` (blocked 179 ms); wscript with a `.vbs`; a waited
  `ExecProcess` (timeout > 0); the helper's elevated relaunch (`Start-Process
  -Verb RunAs -WindowStyle Hidden`).
- **Method: the `conhost.exe --headless` prefix** — no quoting changes, no
  measurable block. Rejected: a PowerShell launcher (the curl line would need
  re-quoting, ~180 ms block) and VBScript (deprecated on Windows 11).
- **Accepted risk:** `--headless` is an undocumented conhost option; it is
  present on Windows 10 and 11, the supported platforms.
- A GUI app started by `start` from the headless console still opens
  normally, since `start` uses ShellExecute.
- The install helper launch and the waited calls already show no window, so
  they stay as they are.

## Hints
- `Scripts/ReaperPluginManager/rpm_reaper.lua` (`launch_background`, around
  line 726; `open_target`, around line 1473)
- `.claude/domain/features/install-helper-windows.md`,
  `.claude/domain/features/plugin-installation.md` (process launch pitfalls
  and the helper launch that stays unchanged)

## Drift
- `.claude/domain/features/licence-activation.md` § Architecture (Opener) — settles: it names Windows `start "" "<target>"` through `ExecProcess` and leaves the console window unstated; the change runs that command under `conhost.exe --headless`, so no console window shows.
- `.claude/domain/features/server-access.md` § Architecture (Transfer) — settles: a background upload starts `curl` without waiting; the change decides that on Windows it runs under `conhost.exe --headless`, with no visible console window.
- `.claude/domain/features/plugin-installation.md` § Open questions — settles: "Whether `reaper.ExecProcess` with the no-wait timeout starts `powershell.exe` with no visible window" is answered by the user's launch test: with the current `-2` timeout and `-WindowStyle Hidden` no window shows (with `-1` one does); the helper launch is unchanged.
