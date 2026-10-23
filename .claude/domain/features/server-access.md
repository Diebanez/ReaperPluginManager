# Server access

The shared foundation every server-touching feature goes through: the
user's settings, the server credentials, and the one place that turns them
into `curl` transfers. It knows nothing about catalogues or plugins.

## Purpose

Every feature that reads or writes the group's server — the setup
connection test, the project check's catalogue fetch, plugin installation,
catalogue management — needs the same address, the same TLS rules and the
same credentials, applied the same way. This feature owns them once, so a
change to how the tool talks to the server lands in one place. It is the
technical foundation of [product-design.md § Setup](../product-design.md#setup).

## Scope and non-goals

In scope:
- The settings file: its keys, defaults and parsing.
- The server credentials: storage in the OS secret store, retrieval, and the
  short-lived credentials file a transfer needs.
- The transfer contract: download, upload (blocking or in the background),
  safe replace (upload under a temporary name, then rename) and delete, with
  the common `curl` options derived from the settings.
- The option set handed to the install helpers, so they transfer exactly as
  the Lua side does.

Non-goals:
- Writing settings or credentials — only `setup-action` does that.
- Anything about the catalogue's format or caching, or about plugins.
- Licence data of any kind; it is never part of the server credentials.
- Separate read and write accounts: a machine holds one server account.
  Members hold a read-only account, the maintainer a write account; a write
  attempted with a read-only account fails with the server's own error.

## Architecture

Built on Lua ReaScripts, `curl` and the platform secret stores, per
[technical-direction.md](../technical-direction.md).

- **Settings** — reads the settings file from the tool's local data folder
  and returns a complete settings value, falling back to the default for
  every missing or invalid key. Pure logic; lives in the module with no
  `reaper.*` calls.
- **Credential store** — keeps the server password in the OS secret store:
  Windows DPAPI (current-user scope) and the macOS Keychain. It is the only
  component that touches the secret store for server credentials. It reads
  the password at most once per REAPER session and holds it in memory, so a
  transfer does not pay a secret-store round trip each time.
- **Credentials file** — materializes a `netrc`-format file (`machine`,
  `login`, `password`) in the local data folder for exactly the duration a
  transfer needs it, owner-only permissions on macOS, and removes it
  afterwards. A stale one left by a crash is swept on the next start.
- **Transfer** — builds the `curl` invocation from the settings plus the
  credentials file and runs it: download to a path, upload a local file to a
  server path, rename and delete on the server. A background upload starts
  `curl` without waiting — on Windows its `cmd.exe` line runs through
  `rpm-run-hidden.ps1` (launch constraints:
  [install-helper-windows.md](./install-helper-windows.md#interfaces-and-contracts))
  — and reports progress and the exit code through a
  small status file the caller polls from its `defer` loop, so large
  installers never freeze REAPER. Common options:
  fail on HTTP/FTP errors, silent with errors shown, follow redirects,
  passive FTP, a timeout, `--ssl-reqd` for `tls=required`, `--ssl` for
  `try`, `--insecure` when the user accepts self-signed certificates. Safe
  replace = upload as `<name>.uploading`, then rename over `<name>`. Rename
  and delete are FTP commands (`RNFR`/`RNTO`, `DELE`) over FTP and FTPS,
  WebDAV `MOVE`/`DELETE` over HTTPS; for `file://` servers upload, rename
  and delete are a copy, a move and a removal.
- **Helper hand-off** — for a detached install run, the Lua side
  materializes the credentials file before launch and passes its path with
  the TLS and insecure options; the helper deletes the file when it writes
  its final status line, success or failure.

## Data and state

- **Settings file** (`config.ini`, local data folder), sections and keys:
  - `[server]` `url` (always ends with `/`), `tls` (`required` | `try` |
    `off`, default `required`), `insecure` (`0` | `1`, default `0`);
  - `[install]` `vst2_dir` (Windows only, optional: destination for VST2
    `.dll` files unpacked from archives; empty, the default, means those
    files are skipped);
  - `[check]` `auto` (`1` | `0`, default `1`), `notify_unknown` (`1` | `0`,
    default `1`).
  Comments with `;` or `#`. The file is the source of truth for settings.
- **Server credentials** — user name in the settings file's `[server]`
  section (`user`), password only in the OS secret store, keyed by server
  host and user. An empty user means anonymous access: no secret, no
  credentials file.
- **In-memory** — the decrypted password, for the REAPER session only.
- **Transient** — the credentials file, alive only during a transfer or an
  install run.

## Interfaces and contracts

- `settings.load() → settings` — never fails; missing file or keys yield
  defaults.
- `credentials.get() → user, password | nil` — `nil` password for anonymous
  access; a secret-store failure returns an error naming the store.
- `transfer.download(server_path, local_path) → ok, err`
- `transfer.upload(local_path, server_path) → ok, err`
- `transfer.upload_async(local_path, server_path) → handle` and
  `handle:poll() → state, bytes_done, bytes_total, err` — `state` is
  `running`, `done` or `failed`.
- `transfer.replace(local_path, server_path) → ok, err` — the safe replace
  above; members never observe a partial file.
- `transfer.delete(server_path) → ok, err`
- `transfer.helper_options() → { netrc_path?, tls, insecure }` — for the
  install launch; the caller owns starting the helper.
- Failure contract: every transfer returns `ok = false` with a one-line
  reason built from `curl`'s exit code and error text (unreachable host, TLS
  refused, login failed, not found, permission denied). A password never
  appears on a command line or in an error message.

## Dependencies

- `setup-action` — the only writer of the settings file and the
  credentials.
- `catalogue-publish` — the caller of background upload, replace and
  delete.
- `curl` — shipped with Windows 10+ and macOS; the tool's only transfer
  mechanism.
- Windows PowerShell (DPAPI via .NET `ProtectedData`) and the macOS
  `security` tool — the secret-store back ends.

## Open questions

- How to hand the password to the macOS `security` tool when storing it
  without it appearing on a command line — blocks the macOS credential store.
- Whether an elevated Windows helper running under a different administrator
  account can read the credentials file in the user's data folder — blocks
  installs for standard (non-admin) Windows users.
- Whether an HTTPS server is writable only when it speaks WebDAV, leaving
  catalogue publishing to FTP, FTPS and `file://` servers otherwise — blocks
  publishing to a plain HTTPS server.
