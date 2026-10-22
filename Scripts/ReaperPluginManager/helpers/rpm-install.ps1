# rpm-install.ps1: Windows install helper of ReaperPluginManager.
# Reads the job file, elevates once, then downloads, verifies and installs
# each plugin, appending every step to the status file. Targets Windows
# PowerShell 5.1; ASCII-only.
#
#   -JobFile <file>     job.tsv: id name type url sha256 args dest, tab-separated
#   -StatusFile <file>  appended: START <n>, ITEM <id> download|verify|install,
#                       NOTE <id> <message>, OK <id>, FAIL <id> <message>,
#                       DONE <ok> <failed>
#   -WorkDir <dir>      downloads go to <dir>\<id>
#   -NetrcFile <file>   curl credentials file; deleted when the run ends
#   -Tls required|try|off (default required)   -Insecure
#   -Vst3Dir <dir>      default %CommonProgramFiles%\VST3
#   -Vst2Dir <dir>      default the settings' [install] vst2_dir; when empty,
#                       VST2 files in archives are skipped with a NOTE
#   -ClapDir <dir>      default %CommonProgramFiles%\CLAP
#   -NoElevate          do not relaunch as administrator (development use)
#
# No parameter is mandatory, so a missing one never prompts in a hidden
# window. Every failure is one FAIL line and stops only its plugin; the run
# always ends with DONE and deletes the credentials file.

param(
  [string]$JobFile,
  [string]$StatusFile,
  [string]$WorkDir,
  [string]$NetrcFile,
  [string]$Tls = 'required',
  [switch]$Insecure,
  [string]$Vst3Dir,
  [string]$Vst2Dir,
  [string]$ClapDir,
  [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$ConnectTimeout = 30
$StallTimeout = 60
$SuccessCodes = @(0, 3010)
# A folder path inside an archive that marks a 32-bit copy of a plugin.
$Marker32 = '(?i)(^|[^a-z0-9])(x86(?![-_]?64)|32-?bit|win32|32)(?=[^a-z0-9]|$)'

function Write-Status([string]$line) {
  [IO.File]::AppendAllText($StatusFile, $line + "`n", $Utf8NoBom)
}

function ConvertTo-OneLine([string]$text) {
  $t = ($text -replace '[\r\n]+', ' ').Trim()
  if (-not $t) { $t = 'unknown error' }
  return $t
}

function Remove-Credentials {
  if ($NetrcFile -and [IO.File]::Exists($NetrcFile)) {
    try { [IO.File]::Delete($NetrcFile) } catch { }
  }
}

# A command-line argument in double quotes; backslashes before the closing
# quote are doubled so they do not escape it.
function ConvertTo-Argument([string]$value) {
  if ($value -match '\\+$') { $value = $value + $matches[0] }
  return '"' + $value + '"'
}

# The value of `key` in `section` of the settings file at `path`, or '' when
# the file or the key is missing. Comments start with ; or # at the start of
# a line or after whitespace.
function Get-SettingsValue([string]$path, [string]$section, [string]$key) {
  if (-not $path -or -not [IO.File]::Exists($path)) { return '' }
  $current = ''
  foreach ($raw in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
    $line = ($raw -replace '(^|\s)[;#].*$', '').Trim()
    if ($line -match '^\[(.*)\]$') {
      $current = $matches[1].Trim()
    } elseif ($current -eq $section -and $line -match '^([^=]*)=(.*)$' -and $matches[1].Trim() -eq $key) {
      return $matches[2].Trim()
    }
  }
  return ''
}

# The job entries, one per non-empty line with an id.
function Read-Job([string]$path) {
  $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
  foreach ($raw in ($text -split "`n")) {
    $line = $raw.TrimEnd("`r")
    if (-not $line.Trim()) { continue }
    $f = @($line.Split("`t")) + @('', '', '', '', '', '', '')
    $id = $f[0].Trim()
    if (-not $id) { continue }
    New-Object PSObject -Property @{
      Id     = $id
      Name   = $f[1].Trim()
      Type   = $f[2].Trim().ToLowerInvariant()
      Url    = $f[3].Trim()
      Sha256 = $f[4].Trim()
      Args   = $f[5].Trim()
      Dest   = $f[6].Trim()
    }
  }
}

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal $identity
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunches this script as administrator with every parameter, already
# resolved, plus -NoElevate so the elevated instance never relaunches again.
# Throws when the prompt is refused.
function Start-Elevated {
  $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', (ConvertTo-Argument $PSCommandPath))
  foreach ($name in 'JobFile', 'StatusFile', 'WorkDir', 'NetrcFile', 'Tls', 'Vst3Dir', 'Vst2Dir', 'ClapDir') {
    $value = Get-Variable -Name $name -Scope Script -ValueOnly
    if ($value) { $list += @('-' + $name, (ConvertTo-Argument $value)) }
  }
  if ($Insecure) { $list += '-Insecure' }
  $list += '-NoElevate'
  $exe = Join-Path $PSHOME 'powershell.exe'
  Start-Process -FilePath $exe -ArgumentList ($list -join ' ') -Verb RunAs -WindowStyle Hidden | Out-Null
}

# Downloads the entry's installer into `dir`, named after the decoded last
# URL segment, and returns its path.
function Get-Installer($entry, [string]$dir) {
  $url = $entry.Url
  if (-not $url) { throw 'download failed: no URL in the job' }
  $path = $url -replace '[?#].*$', ''
  $name = [Uri]::UnescapeDataString($path.Substring($path.LastIndexOf('/') + 1))
  foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$c, '_') }
  if (-not $name.Trim('.', ' ')) { $name = 'installer' }
  $file = Join-Path $dir $name

  $curlArgs = @('--fail', '--silent', '--show-error', '--location', '--ftp-pasv',
    '--connect-timeout', [string]$ConnectTimeout,
    '--speed-limit', '1', '--speed-time', [string]$StallTimeout)
  if ($url -notmatch '^file:') {
    if ($Tls -eq 'required') { $curlArgs += '--ssl-reqd' }
    elseif ($Tls -eq 'try') { $curlArgs += '--ssl' }
    if ($Insecure) { $curlArgs += '--insecure' }
    if ($NetrcFile) { $curlArgs += @('--netrc-file', $NetrcFile) }
  }
  $curlArgs += @('--output', $file, $url)

  # curl's stderr must not turn into a terminating error: relax the error
  # preference around the call and read the exit code instead.
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $Curl @curlArgs 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
  if ($code -ne 0) {
    $text = (@($output) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join ' '
    if (-not $text) { $text = 'curl exit code ' + $code }
    throw ('download failed: ' + $text)
  }
  if (-not [IO.File]::Exists($file)) { throw 'download failed: no file was written' }
  return $file
}

# Lowercase hex SHA-256 of `file`, through .NET (Get-FileHash is not relied on).
function Get-Sha256([string]$file) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($file)
  try {
    $hash = $sha.ComputeHash($stream)
  } finally {
    $stream.Dispose()
    $sha.Dispose()
  }
  $sb = New-Object System.Text.StringBuilder 64
  foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
  return $sb.ToString()
}

function Install-Exe($entry, [string]$file, [string]$dir) {
  $params = @{ FilePath = $file; WorkingDirectory = $dir; Wait = $true; PassThru = $true }
  if ($entry.Args) { $params.ArgumentList = $entry.Args }
  $process = Start-Process @params
  return $process.ExitCode
}

function Install-Msi($entry, [string]$file) {
  $list = '/i ' + (ConvertTo-Argument $file) + ' /qn /norestart'
  if ($entry.Args) { $list += ' ' + $entry.Args }
  $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
  $process = Start-Process -FilePath $msiexec -ArgumentList $list -Wait -PassThru
  return $process.ExitCode
}

# The message of a caught error, without PowerShell's method-call wrapper.
function Get-ErrorText($record) {
  $e = $record.Exception
  if ($e.InnerException) { $e = $e.InnerException }
  return $e.Message
}

# The outermost plugin items under `dir`, in name order, without descending
# into an item already found; __MACOSX folders and .lv2 bundles are skipped,
# since an LV2 bundle's inner .dll files are not VST2 plugins.
function Find-PluginItems([string]$dir) {
  foreach ($path in ([IO.Directory]::GetFileSystemEntries($dir) | Sort-Object)) {
    $isDir = [IO.Directory]::Exists($path)
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -eq '.vst3' -or (-not $isDir -and ($ext -eq '.clap' -or $ext -eq '.dll'))) {
      $path
    } elseif ($isDir -and $ext -ne '.lv2' -and [IO.Path]::GetFileName($path) -ne '__MACOSX') {
      Find-PluginItems $path
    }
  }
}

# True when the plugin item goes to the VST2 folder: the entry's dest says
# vst2, or there is no dest and the item is a .dll.
function Test-Vst2Item([string]$item, [string]$dest) {
  if ($dest) { return $dest.ToLowerInvariant() -eq 'vst2' }
  return [IO.Path]::GetExtension($item).ToLowerInvariant() -eq '.dll'
}

# The plugin items to copy: of a name found more than once, the copies whose
# folder path under `root` marks them 32-bit are dropped, as long as one copy
# is not so marked.
function Select-PreferredItems([string[]]$items, [string]$root) {
  foreach ($group in ($items | Group-Object { [IO.Path]::GetFileName($_).ToLowerInvariant() })) {
    $copies = @($group.Group)
    if ($copies.Count -gt 1) {
      $unmarked = @($copies | Where-Object {
        [IO.Path]::GetDirectoryName($_).Substring($root.Length) -notmatch $Marker32
      })
      if ($unmarked.Count -gt 0) { $copies = $unmarked }
    }
    $copies
  }
}

# The folder a plugin item goes to: the entry's dest (vst3, vst2, clap or an
# absolute path), or else the item's extension.
function Get-PluginFolder([string]$item, [string]$dest) {
  $kind = $dest.ToLowerInvariant()
  if (-not $kind) {
    $kind = @{ '.vst3' = 'vst3'; '.clap' = 'clap'; '.dll' = 'vst2' }[[IO.Path]::GetExtension($item).ToLowerInvariant()]
  }
  switch ($kind) {
    'vst3' { return $Vst3Dir }
    'clap' { return $ClapDir }
    'vst2' {
      if (-not $Vst2Dir) { throw 'no VST2 folder set (vst2_dir in the settings)' }
      return $Vst2Dir
    }
  }
  if ($dest -notmatch '^([A-Za-z]:[\\/]|[\\/]{2})') {
    throw ('destination not supported on Windows: ' + $dest)
  }
  return $dest
}

function Copy-Folder([string]$source, [string]$target) {
  [void][IO.Directory]::CreateDirectory($target)
  foreach ($file in [IO.Directory]::GetFiles($source)) {
    [IO.File]::Copy($file, (Join-Path $target ([IO.Path]::GetFileName($file))))
  }
  foreach ($sub in [IO.Directory]::GetDirectories($source)) {
    Copy-Folder $sub (Join-Path $target ([IO.Path]::GetFileName($sub)))
  }
}

# Copies the plugin item (file or folder) into `folder`, deleting an existing
# item of the same name first: a folder copied over another would nest in it.
function Copy-PluginItem([string]$item, [string]$folder) {
  $name = [IO.Path]::GetFileName($item)
  $target = Join-Path $folder $name
  try {
    [void][IO.Directory]::CreateDirectory($folder)
    if ([IO.Directory]::Exists($target)) { [IO.Directory]::Delete($target, $true) }
    elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
    if ([IO.Directory]::Exists($item)) { Copy-Folder $item $target }
    else { [IO.File]::Copy($item, $target) }
  } catch {
    throw ('cannot copy ' + $name + ' to ' + $folder + ': ' + (Get-ErrorText $_))
  }
}

# Unpacks the archive into `dir`\unpacked and copies its plugin items to their
# folders, every folder resolved before the first copy. VST2 is optional: with
# no VST2 folder set, VST2 items are skipped and their names returned, so the
# caller can report them; an archive holding nothing else fails.
function Install-Zip($entry, [string]$file, [string]$dir) {
  $root = Join-Path $dir 'unpacked'
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($file, $root)
  } catch {
    throw ('cannot unpack the archive: ' + (Get-ErrorText $_))
  }
  $items = @(Find-PluginItems $root)
  if ($items.Count -eq 0) { throw 'no plugin (.vst3, .clap, .dll) in the archive' }
  $items = @(Select-PreferredItems $items $root)
  $skipped = @()
  if (-not $Vst2Dir) {
    $skipped = @($items | Where-Object { Test-Vst2Item $_ $entry.Dest } | ForEach-Object { [IO.Path]::GetFileName($_) })
    $items = @($items | Where-Object { -not (Test-Vst2Item $_ $entry.Dest) })
    if ($items.Count -eq 0) {
      throw 'only VST2 plugins in the archive and no VST2 folder set (vst2_dir in the settings)'
    }
  }
  $folders = @($items | ForEach-Object { Get-PluginFolder $_ $entry.Dest })
  for ($i = 0; $i -lt $items.Count; $i++) {
    Copy-PluginItem $items[$i] $folders[$i]
  }
  return $skipped
}

# Downloads, verifies and installs one entry; throws with the FAIL message.
function Install-Entry($entry) {
  if (@('exe', 'msi', 'zip') -notcontains $entry.Type) {
    throw 'installer type not supported on Windows'
  }
  if (-not $WorkDir) { throw 'no work folder given' }
  $dir = Join-Path $WorkDir $entry.Id

  Write-Status ('ITEM ' + $entry.Id + ' download')
  if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
  [void][IO.Directory]::CreateDirectory($dir)
  $file = Get-Installer $entry $dir

  if ($entry.Sha256) {
    Write-Status ('ITEM ' + $entry.Id + ' verify')
    $actual = Get-Sha256 $file
    if (-not [string]::Equals($actual, $entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'checksum mismatch'
    }
  }

  Write-Status ('ITEM ' + $entry.Id + ' install')
  switch ($entry.Type) {
    'exe' { $code = Install-Exe $entry $file $dir }
    'msi' { $code = Install-Msi $entry $file }
    'zip' { $skipped = @(Install-Zip $entry $file $dir); $code = 0 }
  }
  if ($SuccessCodes -notcontains $code) {
    throw ('installer exited with code ' + $code)
  }
  if ($entry.Type -eq 'zip' -and $skipped.Count -gt 0) {
    Write-Status ('NOTE ' + $entry.Id + ' VST2 not installed (no VST2 folder set, vst2_dir in the settings): ' + ($skipped -join ', '))
  }

  try { [IO.Directory]::Delete($dir, $true) } catch { }
}

# --- Main -----------------------------------------------------------------

if (-not $StatusFile) { exit 1 }

$Tls = $Tls.Trim().ToLowerInvariant()
if (@('required', 'try', 'off') -notcontains $Tls) { $Tls = 'required' }

$common = $env:CommonProgramW6432
if (-not $common) { $common = $env:CommonProgramFiles }
if (-not $Vst3Dir) { $Vst3Dir = Join-Path $common 'VST3' }
if (-not $ClapDir) { $ClapDir = Join-Path $common 'CLAP' }
if (-not $Vst2Dir -and $JobFile) {
  try {
    $settingsFile = Join-Path ([IO.Path]::GetDirectoryName($JobFile)) 'config.ini'
    $Vst2Dir = Get-SettingsValue $settingsFile 'install' 'vst2_dir'
  } catch { }
}

$Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not [IO.File]::Exists($Curl)) { $Curl = 'curl.exe' }

$entries = @()
try {
  if ($JobFile) { $entries = @(Read-Job $JobFile) }
} catch { }
$total = $entries.Count

Write-Status ('START ' + $total)

if ($total -gt 0 -and -not $NoElevate -and -not (Test-Administrator)) {
  $elevated = $false
  try {
    Start-Elevated
    $elevated = $true
  } catch { }
  if ($elevated) { exit 0 }
  foreach ($entry in $entries) {
    Write-Status ('FAIL ' + $entry.Id + ' administrator permission denied')
  }
  Write-Status ('DONE 0 ' + $total)
  Remove-Credentials
  exit 1
}

$ok = 0
$failed = 0
try {
  foreach ($entry in $entries) {
    try {
      Install-Entry $entry
      Write-Status ('OK ' + $entry.Id)
      $ok++
    } catch {
      Write-Status ('FAIL ' + $entry.Id + ' ' + (ConvertTo-OneLine $_.Exception.Message))
      $failed++
    }
  }
} finally {
  Write-Status ('DONE ' + $ok + ' ' + $failed)
  Remove-Credentials
}
exit 0
