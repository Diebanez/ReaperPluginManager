# Install helper — macOS

The macOS process that downloads, verifies and installs the plugins of one
job, asking for the administrator password at most once and only when the
job holds a package, reporting each step to the status file.

## Purpose

Does the work of
[product-design.md § Plugin installation](../product-design.md#plugin-installation)
on macOS, outside REAPER so REAPER never blocks. Implements the helper
contract in [plugin-installation.md](./plugin-installation.md#helper-contract).

## Scope and non-goals

In scope:
- Download and checksum verification.
- Installing `zip`, `dmg`, `pkg` and `script` entries.
- Clearing the quarantine flag on copied plugins.

Non-goals:
- Any other installer type — fails with "installer type not supported on
  macOS".
- Licence activation and rescanning.

## Architecture

A bash 3.2 script, per [technical-direction.md](../technical-direction.md).

- **Options** — `--job --status --workdir --netrc --tls --insecure
  --plugins-root` (default `~/Library/Audio/Plug-Ins`; overridable for
  development).
- **Job reading** — tabs converted to `\037` and lines read with that
  separator, because a tab separator collapses empty fields. No associative
  arrays, `mapfile` or `${var,,}`.
- **Download and verify** — `curl` with the common options and the
  credentials file; SHA-256 with `shasum -a 256`.
- **Destinations** — `.vst3` → `VST3/`, `.component` → `Components/`, `.vst`
  → `VST/`, `.clap` → `CLAP/` under the plugins root; `dest` `vst3 | vst2 |
  au | clap | <path>` overrides. `__MACOSX` folders are ignored. After each
  copy, `xattr -dr com.apple.quarantine` on the copied item.
- **Install by type**:
  - `zip` — `ditto -x -k`, then route bundles per the contract.
  - `dmg` — `yes | hdiutil attach -nobrowse -readonly -noautoopen
    -mountpoint …` (the `yes` accepts licence prompts). A `.pkg`/`.mpkg`
    within two levels is copied into the work folder and queued as a
    package; otherwise bundles are routed. Then `hdiutil detach`, with
    `-force` when needed.
  - `pkg` — queued.
  - `script` — `ditto -x -k` into the work folder, then `/bin/bash
    install.sh` from the unpacked folder, run as the member in the same
    unprivileged pass as zip routing and never inside the administrator
    prompt, with the `RPM_*` variables of the contract set to the folders
    under the plugins root (`RPM_VST3_DIR` its `VST3/`, `RPM_CLAP_DIR` its
    `CLAP/`, `RPM_VST2_DIR` its `VST/`, `RPM_AU_DIR` its `Components/`), no
    time limit, and its output captured for the `FAIL` message. No
    `install.sh` at the zip's root → "no install.sh in the archive". A
    script therefore writes only where the member can — never into system
    locations such as `/Library` or `/Applications`; a plugin that needs
    those ships its vendor `pkg` instead. Running it as the member leaves no
    root-owned files in the member's own folders and gives a script no more
    rights than it needs.
- **Privileged phase** — after every other entry, generates one script that
  runs `/usr/sbin/installer -pkg … -target /` per queued package and writes
  each package's `OK`/`FAIL` line. It runs that script once through
  `osascript … with administrator privileges`: one password prompt, and none
  for a job whose entries are only zips and scripts. A cancelled prompt →
  `FAIL <id> administrator password not entered` for every queued package
  without an outcome.
- **Development fallback** — `unzip` and `cp -R` stand in when `ditto` and
  `xattr` are missing (running the script under Git Bash).

## Data and state

Reads the job file; appends to the status file; works in `work/<id>/`. No
state of its own beyond the run.

## Interfaces and contracts

- Invoked per the helper contract; options above.
- Failure contract: every failure becomes a one-line `FAIL` message; the
  script always ends with `DONE` and deletes the credentials file.

## Dependencies

- `plugin-installation` — the contract it implements.
- `server-access` — the transfer options and credentials file it receives.
- `curl`, `ditto`, `hdiutil`, `installer`, `osascript`, `shasum`, `xattr` —
  all part of macOS.

## Open questions

None.
