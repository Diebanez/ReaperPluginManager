---
name: catalogue-assistant
description: Research one plugin from its vendor's official sources, inspect its installers — on the group's server or local files on this machine — and write a draft ReaperPluginManager catalogue entry to the tool's drafts/ folder for the catalogue editor's Import draft, which attaches its local installers, with a review report of every field's source and confidence. Use when the maintainer adds a plugin to the catalogue and names its installers' server paths or local file paths.
argument-hint: "<plugin name>" "<vendor>" <server path | local path> [<server path | local path>]
---

# Catalogue assistant

Proposes one catalogue entry — how the plugin names itself in projects, its
installers with type, silent switches and checksum, and its activation
method — as a draft entry file the catalogue editor imports. The maintainer
reviews, tests and publishes it; this skill never publishes. The design is
`.claude/domain/features/catalogue-assistant.md`; the entry schema is
`.claude/domain/features/plugin-catalogue.md` and the `activation` field
`.claude/domain/features/licence-activation.md`.

## Inputs

`$ARGUMENTS` holds:

- the plugin name and its vendor;
- its installers, one per platform or one package shared by both platforms,
  each either a **server path**, relative to the server root exactly as a
  catalogue `file` names it, or a **local file**, given by its absolute path
  — a drive-letter or UNC path on Windows, a path starting with `/` or `~`
  on macOS. An absolute path is always a local file and a relative one
  always a server path.

Ask for whichever is missing, once, before any work. Never guess a path. The
maintainer places server installers on the server and names local ones;
this skill only reads them.

## Boundaries

- **Official vendor sources only**: the vendor's own website, product pages,
  manuals, knowledge base, support articles and release notes. Forums,
  databases such as KVR, reseller and blog pages are not sources; a fact
  found only there is unknown.
- **Installers come from the group's server or the maintainer's own local
  files named at invocation only**, through `fetch-installer.sh`. Read
  vendor pages; never download anything from a vendor site or any other
  source.
- **Nothing licence-bearing**: no serials, licence keys, accounts or
  sign-ins, no cracks, keygens or patches, no unofficial download sources.
- **The server password stays out of the conversation.** Only
  `fetch-installer.sh` touches the credentials. Never read `config.ini`'s
  credentials, the `secrets/` folder or a `netrc` file, and never run the
  `rpm-secret` helpers directly.
- **Static inspection only**: never run an installer or mount anything for
  writing. A local installer is read where it is, never copied or changed.
- **One write**: `drafts/<id>.json` in the tool's local data folder. Nothing
  on the server, in the catalogue draft or in the settings changes.

## Step 1 — Fetch and inspect the installers

Run, from the repository root, quoting each path — `fetch` for the server
installers, `inspect` for the local ones:

```
bash .claude/skills/catalogue-assistant/fetch-installer.sh fetch "<server path>" ["<server path>"]
bash .claude/skills/catalogue-assistant/fetch-installer.sh inspect "<local path>" ["<local path>"]
```

`fetch` downloads each file with the tool's own settings and secret-store
credentials into a new temporary folder; `inspect` reads each local file
where it is, touching no settings, no credentials and no folder. Both print,
tab-separated after the first word:

- `DIR <folder>` — `fetch` only: the temporary folder, present when any file
  arrived;
- `OK <path> <local path> <size> <sha256> <kind> <generator>` — `<path>` the
  server path or the local path as given, `<local path>` the file's native
  path;
- `FAIL <path> <reason>` — that installer could not be fetched or read;
- `ERROR <reason>` — `fetch` only: nothing could be fetched (no settings, no
  password stored, unsupported server address).

The settings and password are the ones Setup stored on this machine; for a
portable REAPER install, set `REAPER_RESOURCE_PATH` to its resource folder
before running the script.

A `FAIL` or `ERROR` installer is reported with its reason, and its platform
gets no installer in the draft. Do not retry with other credentials or
another source.

For each `OK` file:

- **Type** — `kind` from the file's magic bytes: `exe`, `msi`, `zip`,
  `pkg`, `dmg`; `unknown` is reported and that installer left out.
- **Platform** — `exe` and `msi` serve Windows, `pkg` and `dmg` macOS. A
  `zip` serves the platform its contents show (`.dll`, Windows `.vst3`
  binaries → Windows; `.component`, `.vst`, bundles with `Contents/MacOS` →
  macOS), or both when it holds both, as a shared package named under both
  `installers` keys.
- **Generator** — `generator` from the marker strings each tool leaves:
  `inno`, `nsis`, `installshield`, `wix-burn` (a WiX bundle `.exe`), `wix`
  (a WiX-built `.msi`), `msi` (any other `.msi`), `none` (zip, pkg, dmg),
  `unknown`. For an `unknown` exe, look further before giving up:
  `LC_ALL=C grep -a -o -m 5 -E "(Inno Setup|Nullsoft|InstallShield|WixBundle|Advanced Installer|InstallAware|Setup Factory)[ -~]{0,40}" "<local path>"`.
- **Contents** — list what it installs where a tool on this machine can:
  `unzip -Z1` for a zip (on Windows without `unzip`:
  `powershell -NoProfile -Command "Add-Type -A System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::OpenRead('<local path>').Entries.FullName"`);
  on macOS `pkgutil --payload-files` for a pkg, and for a dmg
  `hdiutil attach -nobrowse -readonly -noautoopen -mountpoint <folder>/mnt`
  (for a local dmg, `<folder>` a new `mktemp -d` folder, removed after
  `hdiutil detach`), a listing two levels deep, then `hdiutil detach`;
  `7z l` or `innoextract -l` when installed. The plugin file and bundle
  names found are match strings confirmed from the installer.
- **SHA-256** — the `sha256` column, verbatim.

Then delete the `fetch` temporary folder, also when inspection failed
partway (`inspect` makes none):

```
bash .claude/skills/catalogue-assistant/fetch-installer.sh clean "<folder>"
```

## Step 2 — Silent switches

`args` is Windows only. Propose it from the generator, unless the vendor's
own documentation states the switches for this product, which then win:

| Generator | `type` | `args` |
| --- | --- | --- |
| `inno` | `exe` | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` |
| `nsis` | `exe` | `/S` |
| `wix-burn` | `exe` | `/quiet /norestart` |
| `installshield` | `exe` | `/s /v"/qn REBOOT=ReallySuppress"` (an MSI-based project; a pure InstallScript project needs a recorded response file — leave `args` empty and say so) |
| `wix`, `msi` | `msi` | empty: the helper already runs `msiexec /i <file> /qn /norestart`; add only MSI properties the vendor documents |
| `unknown` | `exe` | empty |

A `zip`, `pkg` or `dmg` takes no `args`. A `zip` takes `dest` (`vst3`,
`vst2`, `clap`, `au` or an absolute path) only when routing by file
extension would put its plugins in the wrong place; otherwise leave it out.

Every proposed `args` is marked **test by hand before publishing**, whatever
its source.

## Step 3 — Vendor research

From official vendor sources (Boundaries):

- **Formats** the plugin ships per platform: VST2, VST3, AU, CLAP.
- **Match strings** — the strings that identify it in projects: the plugin's
  name as REAPER shows it without format prefix and vendor parenthesis
  (`VST3: Acme Compressor (Acme Audio)` → `Acme Compressor`), each format's
  file name (`AcmeCompressor.vst3`, `AcmeCompressor.dll`,
  `AcmeCompressor.component`, `AcmeCompressor.clap`), the AU id and the CLAP
  id (reverse-DNS, e.g. `com.acmeaudio.compressor`). One installer shipping
  several plugins gets the strings of each. A string confirmed by the
  installer's contents or a vendor page is confirmed; one inferred from
  naming conventions is unconfirmed.
- **Activation** — `method`: `none`, `vendor-app`, `serial` or `sign-in`.
  For `vendor-app`, the vendor app per platform with its display name and
  usual location (Windows executable path, macOS `.app` bundle path). The
  vendor page, or the app's download page, as `url`. One or two neutral
  lines of `instructions` for the member.
- **Note** — a short remark members see beside the name, only when it helps
  (e.g. `VST3 only`).

## Step 4 — Compose the entry

- `id` — the plugin's name as a lowercase slug of ASCII letters and digits
  joined by `-`, no spaces. To keep it unique, fetch `manifest.json` with the
  same script (Step 1, then `clean`) and read its ids: when the plugin is
  already in the catalogue, reuse its `id` and say that Import draft will
  merge into it.
- `name`, `vendor` — from the invocation, corrected to the vendor's own
  spelling.
- `match` — at least the name, then every string from Step 3.
- `installers.windows` / `installers.macos` — for a server installer,
  `file` (the server path as given), `type`, `args` (Windows), `sha256`,
  `dest` when needed; for a local installer, `source` (its absolute path, in
  the native form `inspect` printed), `type`, `args` (Windows), `dest` when
  needed, and no `file` or `sha256`: Import draft attaches the file and
  computes its checksum. A shared package is the same object under both
  keys, `type` `zip` on both.
- `activation` — from Step 3. When the method cannot be established, leave
  `activation` out and list it as unknown: to the tool an absent
  `activation` means `none`.

A field that cannot be established from a source or the installer is left
out, never guessed, and listed in the report.

## Step 5 — Write the draft

The file is a catalogue in format version 1 holding the one entry, with
keys in the order the tool's JSON encoder writes them (`id, name, vendor,
note, match, installers, file, type, args, sha256, dest, activation`, any
other key — `source` among them — after them alphabetically), two-space
indent, UTF-8 without BOM. The example names a server installer for macOS
and a local one for Windows:

```json
{
  "plugins": [
    {
      "id": "acme-compressor",
      "name": "Acme Compressor",
      "vendor": "Acme Audio",
      "match": [
        "Acme Compressor",
        "AcmeCompressor.vst3",
        "AcmeCompressor.component"
      ],
      "installers": {
        "macos": {
          "file": "acme/AcmeCompressor-2.1.0-mac.pkg",
          "type": "pkg",
          "sha256": "<64 lowercase hex digits>"
        },
        "windows": {
          "type": "exe",
          "args": "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-",
          "source": "C:\\Users\\me\\Downloads\\AcmeCompressor-2.1.0-win.exe"
        }
      },
      "activation": {
        "app": {
          "macos": { "name": "Acme Hub", "path": "/Applications/Acme Hub.app" },
          "windows": { "name": "Acme Hub", "path": "C:\\Program Files\\Acme\\Acme Hub\\Acme Hub.exe" }
        },
        "instructions": "Sign in to Acme Hub and click Activate next to Acme Compressor.",
        "method": "vendor-app",
        "url": "https://www.acmeaudio.example/hub"
      }
    }
  ],
  "version": 1
}
```

Before writing, check the entry against the format: `id` non-empty without
whitespace; `name` non-empty; `match` a non-empty array of strings; each
installer with a non-empty `file` and a `sha256` of 64 hex digits, or a
non-empty absolute `source` and no `file`, and a `type` its platform allows
(`exe`, `msi`, `zip`, `script` on Windows; `pkg`, `dmg`, `zip`, `script` on
macOS). When `lua` (5.4) is on the PATH, also validate the written file with
the tool's own code — the reader Import draft uses — from the repository
root:

```
lua - "<draft path>" <<'EOF'
package.path = "Scripts/ReaperPluginManager/?.lua;" .. package.path
local core = require("rpm_core")
local f = assert(io.open(arg[1], "rb"))
local entry, why = core.editor.read_draft_entry(f:read("a"))
f:close()
if not entry then print("INVALID " .. why) os.exit(1) end
print("VALID")
EOF
```

Write it to `drafts/<id>.json` under the folder
`bash .claude/skills/catalogue-assistant/fetch-installer.sh datadir`
prints, creating `drafts/` when missing. An existing file of that name is an
earlier draft not yet imported: ask before replacing it.

When no valid entry can be composed — no installer fetched or read and nothing
established about the plugin — write no file and say why.

## Step 6 — Report

In the conversation:

1. The draft's path, or the reason no file was written.
2. A table of every field — `id`, `name`, `vendor`, `note`, each `match`
   string, each installer's `file` or `source`, `type`, `args`, `sha256`
   (for a local installer, the one `inspect` printed, which Import draft
   computes again), `dest`, and each `activation` field — with its value,
   its source (vendor URL, installer inspection with the evidence, the
   invocation) and its confidence (high, medium, low).
3. **Test by hand before publishing**: every `args` value, and every match
   string not confirmed by the installer's contents or a vendor page.
4. **Unknown, left empty**: every field not established, with what was
   tried; every installer that could not be fetched or read, with its
   reason.
5. Next: open the Catalogue Manager and Import draft, which attaches the
   local installers; review, test the installers, then publish, which
   uploads them.
