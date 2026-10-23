# rpm-run-hidden.ps1: Windows background runner of ReaperPluginManager.
# Runs one cmd.exe line with no console window, waits for it to end, then
# deletes the line file. Targets Windows PowerShell 5.1; ASCII-only.
#
#   -LineFile <file>    UTF-8 text holding the cmd.exe line; deleted at the end
#
# The line reaches cmd.exe as '/d /s /c "<line>"' through ProcessStartInfo,
# so its double quotes and percent signs arrive exactly as written. No
# parameter is mandatory, so a missing one never prompts in a hidden window.

param(
  [string]$LineFile
)

$ErrorActionPreference = 'Stop'

if (-not $LineFile) { exit 1 }

$code = 1
try {
  $line = [IO.File]::ReadAllText($LineFile, [Text.Encoding]::UTF8).TrimEnd("`r", "`n")
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
  $psi.Arguments = '/d /s /c "' + $line + '"'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $proc.WaitForExit()
  $code = $proc.ExitCode
} catch {
  $code = 1
}
try { [IO.File]::Delete($LineFile) } catch { }
exit $code
