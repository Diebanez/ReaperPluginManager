# rpm-restart.ps1: Windows restart helper of ReaperPluginManager.
# Waits for REAPER to quit, then starts it again. Targets Windows PowerShell
# 5.1; ASCII-only.
#
#   -Exe <file>    full path of the reaper.exe to wait for and start again
#
# Every 0.5 s it looks for a running process whose executable path equals
# -Exe, ignoring case, so another REAPER installation running at the same
# time neither blocks nor triggers the restart. Once none is left it starts
# -Exe from its own folder and exits; when one is still running after 60 s
# it exits without starting anything. It writes no output and no file. No
# parameter is mandatory, so a missing one never prompts in a hidden window.

param(
  [string]$Exe
)

$ErrorActionPreference = 'Stop'

if (-not $Exe) { exit 1 }

try {
  $Exe = [IO.Path]::GetFullPath($Exe)
} catch {
  exit 1
}
if (-not [IO.File]::Exists($Exe)) { exit 1 }

$name = [IO.Path]::GetFileNameWithoutExtension($Exe)

function Test-Running {
  $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
  foreach ($p in $procs) {
    $path = $null
    try { $path = $p.Path } catch { }
    if ($path -and [string]::Equals($path, $Exe, [StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

$deadline = (Get-Date).AddSeconds(60)
while ($true) {
  $running = $true
  try { $running = Test-Running } catch { }
  if (-not $running) {
    try {
      Start-Process -FilePath $Exe -WorkingDirectory ([IO.Path]::GetDirectoryName($Exe)) | Out-Null
    } catch {
      exit 1
    }
    exit 0
  }
  if ((Get-Date) -ge $deadline) { exit 1 }
  Start-Sleep -Milliseconds 500
}
