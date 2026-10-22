# rpm-secret.ps1: Windows secret-store back end of ReaperPluginManager.
# Keeps one secret per store file, encrypted with DPAPI (CurrentUser scope).
# Targets Windows PowerShell 5.1; ASCII-only.
#
#   -Action get    -Store <file>               prints "OK <hex>" or "NOTFOUND"
#   -Action set    -Store <file> -InFile <file> prints "OK"
#   -Action delete -Store <file>               prints "OK", also when absent
#
# Any failure prints "ERROR <reason>". The secret travels as raw bytes: set
# reads it from -InFile, which is deleted whatever happens; get prints it as
# lowercase hex, so no console encoding ever touches it. Exit codes: 0 OK,
# 1 ERROR, 2 NOTFOUND.

param(
  [Parameter(Mandatory = $true)][ValidateSet('get', 'set', 'delete')][string]$Action,
  [Parameter(Mandatory = $true)][string]$Store,
  [string]$InFile
)

$ErrorActionPreference = 'Stop'

function Get-Scope {
  Add-Type -AssemblyName System.Security
  return [System.Security.Cryptography.DataProtectionScope]::CurrentUser
}

function Clear-Bytes($bytes) {
  if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
}

try {
  switch ($Action) {
    'get' {
      if (-not [IO.File]::Exists($Store)) {
        Write-Output 'NOTFOUND'
        exit 2
      }
      $scope = Get-Scope
      $blob = [IO.File]::ReadAllBytes($Store)
      $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($blob, $null, $scope)
      $sb = New-Object System.Text.StringBuilder ($plain.Length * 2)
      foreach ($b in $plain) { [void]$sb.Append($b.ToString('x2')) }
      Clear-Bytes $plain
      Write-Output ('OK ' + $sb.ToString())
      exit 0
    }
    'set' {
      if (-not $InFile) { throw 'no -InFile given' }
      $plain = $null
      try {
        $plain = [IO.File]::ReadAllBytes($InFile)
      } finally {
        if ([IO.File]::Exists($InFile)) { [IO.File]::Delete($InFile) }
      }
      if ($plain.Length -eq 0) { throw 'empty secret' }
      $scope = Get-Scope
      $blob = [System.Security.Cryptography.ProtectedData]::Protect($plain, $null, $scope)
      Clear-Bytes $plain
      $dir = [IO.Path]::GetDirectoryName($Store)
      if ($dir -and -not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
      $tmp = $Store + '.new'
      [IO.File]::WriteAllBytes($tmp, $blob)
      if ([IO.File]::Exists($Store)) { [IO.File]::Delete($Store) }
      [IO.File]::Move($tmp, $Store)
      Write-Output 'OK'
      exit 0
    }
    'delete' {
      if ([IO.File]::Exists($Store)) { [IO.File]::Delete($Store) }
      Write-Output 'OK'
      exit 0
    }
  }
} catch {
  if ($InFile -and [IO.File]::Exists($InFile)) {
    try { [IO.File]::Delete($InFile) } catch { }
  }
  $msg = ($_.Exception.Message -replace '[\r\n]+', ' ')
  Write-Output ('ERROR ' + $msg)
  exit 1
}
