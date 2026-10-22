# Install helper — Windows

The Windows process that downloads, verifies and installs the plugins of one
job, with a single administrator prompt, reporting each step to the status
file.

## Purpose

Does the work of
[product-design.md § Plugin installation](../product-design.md#plugin-installation)
on Windows, outside REAPER so REAPER never blocks. Implements the helper
contract in [plugin-installation.md](./plugin-installation.md#helper-contract).

## Scope and non-goals

In scope:
- Elevation, once per run.
- Download and checksum verification.
- Installing `exe`, `msi` and `zip` entries.

Non-goals:
- Any other installer type — fails with "installer type not supported on
  Windows".
- Licence activation, rescanning, user interaction beyond the UAC prompt
  (an `exe` entry with no silent switches runs its own interactive
  installer).

## Architecture

A Windows PowerShell 5.1 script, per
[technical-direction.md](../technical-direction.md).

- **Parameters** — `-JobFile -StatusFile -WorkDir -NetrcFile -Tls -Insecure
  -Vst3Dir` (default `%CommonProgramFiles%\VST3`) `-Vst2Dir` (default from
  the settings' `vst2_dir`) `-ClapDir` (default `%CommonProgramFiles%\CLAP`)
  `-NoElevate` (development use).
- **Elevation** — writes `START` at once; when not running as administrator
  and without `-NoElevate`, relaunches itself with `Start-Process -Verb
  RunAs`, forwarding every parameter, and exits. A refused prompt → `FAIL
  <id> administrator permission denied` for every plugin and `DONE 0 n`.
- **Download** — `curl` with the common options and the credentials file;
  stderr captured with error handling relaxed around the call and the exit
  code read from `$LASTEXITCODE`.
- **Verify** — SHA-256 through .NET `SHA256`, not `Get-FileHash`.
- **Install by type**:
  - `exe` — `Start-Process -Wait -PassThru` with `args`; success on exit
    code 0 or 3010.
  - `msi` — `msiexec /i "<file>" /qn /norestart <args>`; same codes.
  - `zip` — unpack with .NET `ZipFile.ExtractToDirectory`, then route per the
    contract: `.vst3` (file or folder) → Vst3Dir, `.clap` → ClapDir, `.dll`
    → Vst2Dir, unless `dest` says otherwise. When the same name appears more
    than once, drop the copy whose relative path marks it 32-bit (`x86`,
    `32bit`, `32-bit`, `win32`, `32`) as long as one copy is not so marked.
    No plugin found → "no plugin (.vst3, .clap, .dll) in the archive".

## Data and state

Reads the job file; appends to the status file with
`[IO.File]::AppendAllText` (UTF-8, no BOM); works in `work/<id>/`. No state
of its own beyond the run.

## Interfaces and contracts

- Invoked per the helper contract; parameters above.
- Source constraints: ASCII only, messages included; runs under
  `powershell.exe` 5.1 even when the parent environment carries a
  PowerShell 7 module path (no reliance on `Get-FileHash` or
  `Expand-Archive`).
- Failure contract: every failure becomes a one-line `FAIL` message; the
  script always ends with `DONE` and deletes the credentials file.

## Dependencies

- `plugin-installation` — the contract it implements.
- `server-access` — the transfer options and credentials file it receives.
- `curl`, Windows PowerShell 5.1, .NET `System.IO.Compression.FileSystem`.

## Open questions

- Whether the elevated instance, if a standard user elevates with a
  different administrator account, can still read the credentials file and
  write the status file in the user's data folder (also open in
  `server-access`).
