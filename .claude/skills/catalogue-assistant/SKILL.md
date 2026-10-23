---
name: catalogue-assistant
description: Research one plugin from its vendor's official sources, inspect its installers already on the group's server, and write a draft ReaperPluginManager catalogue entry to the tool's drafts/ folder for the catalogue editor's Import draft, with a review report of every field's source and confidence. Use when the maintainer adds a plugin to the catalogue and names its installers' server paths.
argument-hint: "<plugin name>" "<vendor>" <server path> [<server path>]
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
- the server paths of its installers, relative to the server root exactly as
  a catalogue `file` names them: one per platform, or one package shared by
  both platforms.

Ask for whichever is missing, once, before any work. Never guess a server
path. The maintainer places installers on the server; this skill only reads
them.

## Boundaries

- **Official vendor sources only**: the vendor's own website, product pages,
  manuals, knowledge base, support articles and release notes. Forums,
  databases such as KVR, reseller and blog pages are not sources; a fact
  found only there is unknown.
- **Installers come from the group's server only**, through
  `fetch-installer.sh`. Read vendor pages; never download anything from a
  vendor site or any other source.
- **Nothing licence-bearing**: no serials, licence keys, accounts or
  sign-ins, no cracks, keygens or patches, no unofficial download sources.
- **The server password stays out of the conversation.** Only
  `fetch-installer.sh` touches the credentials. Never read `config.ini`'s
  credentials, the `secrets/` folder or a `netrc` file, and never run the
  `rpm-secret` helpers directly.
- **Static inspection only**: never run an installer or mount anything for
  writing.
- **One write**: `drafts/<id>.json` in the tool's local data folder. Nothing
  on the server, in the catalogue draft or in the settings changes.

## Step 1 — Fetch and inspect the installers

Run, from the repository root, quoting each path:

```
bash .claude/skills/catalogue-assistant/fetch-installer.sh fetch "<server path>" ["<server path>"]
```

It downloads each file with the tool's own settings and secret-store
credentials into a new temporary folder and prints, tab-separated after the
first word:

- `DIR <folder>` — the temporary folder, present when any file arrived;
- `OK <server path> <local path> <size> <sha256> <kind> <generator>`;
- `FAIL <server path> <reason>` — that installer could not be fetched;
- `ERROR <reason>` — nothing could be fetched (no settings, no password
  stored, unsupported server address).

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
  `hdiutil attach -nobrowse -readonly -noautoopen -mountpoint <folder>/mnt`,
  a listing two levels deep, then `hdiutil detach`; `7z l` or `innoextract
  -l` when installed. The plugin file and bundle names found are match
  strings confirmed from the installer.
- **SHA-256** — the `sha256` column, verbatim.

Then delete the temporary folder, also when inspection failed partway:

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
- `installers.windows` / `installers.macos` — `file` (the server path as
  given), `type`, `args` (Windows), `sha256`, `dest` when needed. A shared
  package is the same object under both keys, `type` `zip` on both.
- `activation` — from Step 3. When the method cannot be established, leave
  `activation` out and list it as unknown: to the tool an absent
  `activation` means `none`.

A field that cannot be established from a source or the installer is left
out, never guessed, and listed in the report.

## Step 5 — Write the draft

The file is a catalogue in format version 1 holding the one entry, with
keys in the order the tool's JSON encoder writes them (`id, name, vendor,
note, match, installers, file, type, args, sha256, dest, activation`, any
other key after them alphabetically), two-space indent, UTF-8 without BOM:

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
          "file": "acme/AcmeCompressor-2.1.0-win.exe",
          "type": "exe",
          "args": "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-",
          "sha256": "<64 lowercase hex digits>"
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
installer with a non-empty `file`, a `type` its platform allows (`exe`,
`msi`, `zip`, `script` on Windows; `pkg`, `dmg`, `zip`, `script` on macOS),
`sha256` of 64 hex digits. When `lua` (5.4) is on the PATH, also validate the written file with
the tool's own code, from the repository root:

```
lua - "<draft path>" <<'EOF'
package.path = "Scripts/ReaperPluginManager/?.lua;" .. package.path
local core = require("rpm_core")
local f = assert(io.open(arg[1], "rb"))
local value, err = core.json.decode(f:read("a"))
f:close()
if not value then print("INVALID " .. err) os.exit(1) end
local cat, warnings = core.catalogue.validate(value)
if not cat then print("INVALID " .. warnings) os.exit(1) end
if #warnings > 0 or #cat.plugins ~= 1 then print("INVALID " .. table.concat(warnings, "; ")) os.exit(1) end
print("VALID")
EOF
```

Write it to `drafts/<id>.json` under the folder
`bash .claude/skills/catalogue-assistant/fetch-installer.sh datadir`
prints, creating `drafts/` when missing. An existing file of that name is an
earlier draft not yet imported: ask before replacing it.

When no valid entry can be composed — no installer fetched and nothing
established about the plugin — write no file and say why.

## Step 6 — Report

In the conversation:

1. The draft's path, or the reason no file was written.
2. A table of every field — `id`, `name`, `vendor`, `note`, each `match`
   string, each installer's `file`, `type`, `args`, `sha256`, `dest`, and
   each `activation` field — with its value, its source (vendor URL,
   installer inspection with the evidence, the invocation) and its
   confidence (high, medium, low).
3. **Test by hand before publishing**: every `args` value, and every match
   string not confirmed by the installer's contents or a vendor page.
4. **Unknown, left empty**: every field not established, with what was
   tried; every installer that could not be fetched, with its reason.
5. Next: open the Catalogue Manager, Import draft, review, test the
   installers, then publish.
