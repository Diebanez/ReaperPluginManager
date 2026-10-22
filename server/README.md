# Server setup guide

This guide is for the group's maintainer: the person who keeps the plugin
catalogue on the group's server. The catalogue is the file `manifest.json` at
the server root; `manifest.example.json` in this folder is a complete example
to start from.

## Server address

Every machine reaches the server through the address in its settings (the
`url` key described in the member guide, `README.md` at the repository root).
The address starts with one of these schemes:

- `ftp://` — FTP. The `tls` setting decides whether the connection is
  upgraded to TLS (explicit TLS); at the default, `required`, a server that
  does not offer TLS is refused.
- `ftps://` — FTP over implicit TLS.
- `https://` — a web server.
- `file://` — a folder, local, on a network share or cloud-synced:
  `file:///C:/Plugins/`, `file:///Users/me/Dropbox/Plugins/` or
  `file://fileserver/share/Plugins/`.

Fetching the catalogue and downloading installers work with every scheme.
Publishing the catalogue writes to the server — it uploads, renames and
deletes files — and works with FTP, FTPS and `file://` servers as they are,
but with an HTTPS server only when it speaks WebDAV: uploads are HTTP `PUT`,
renames WebDAV `MOVE` and deletes WebDAV `DELETE`. A plain HTTPS server
refuses them, and the manager reports that writing over HTTPS needs WebDAV.

Each machine uses one server account. Give members a read-only account and
yourself one allowed to upload, rename and delete files and, over FTP, to
create folders.

## The catalogue format

`manifest.json` is a JSON file in UTF-8, read as catalogue format version 1;
`manifest.example.json` in this folder shows every part described below. At
the top level it holds two keys:

- `version` (required) — the catalogue format version: `1`.
- `plugins` (required) — an array of entries, one per installer you offer.

Each entry in `plugins` holds:

- `id` (required) — a short identifier, unique in the catalogue and without
  spaces, such as `acme-compressor`.
- `name` (required) — the plugin's name, shown to members.
- `vendor` — the maker's name, shown to members.
- `note` — a short remark shown beside the name, such as `VST3 only`.
- `match` (required) — an array of the strings that identify the plugin in
  projects; see *Match strings* below.
- `installers` — an object with up to two keys, `windows` and `macos`, each
  describing the installer for that platform. A platform left out, or whose
  `file` is empty, has no installer: members on it see the plugin listed
  without one.
- `activation` — how a member activates the plugin's licence after
  installing it. Leave it out for a plugin that needs no activation.

Each installer object holds:

- `file` (required) — the installer's path, relative to the server root and
  written with `/`, such as `acme/AcmeCompressor-2.1.0-win.exe`.
- `type` — how the file is installed: `exe`, `msi` or `zip` on Windows,
  `pkg`, `dmg` or `zip` on macOS. When it is left out, the file extension
  decides, so set it only for a file whose extension is not one of these.
- `args` — Windows only: the installer's silent-install switches for an
  `exe`, such as `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, or the extra
  properties for an `msi`.
- `sha256` — the file's SHA-256 checksum in hexadecimal. When present, a
  download whose checksum differs is not installed.
- `dest` — for an archive, where its plugins are put: `vst3`, `vst2`, `clap`,
  `au` or an absolute folder path. When it is left out, each plugin goes to
  the standard folder for its file type.

### One package for both platforms

When one file installs the plugin on both Windows and macOS — typically a zip
holding the plugin for each — name the same `file` under both `windows` and
`macos`, as the `acme-reverb` entry of `manifest.example.json` does. The file
is stored once on the server.

### How the manager reads the catalogue

Each project check downloads `manifest.json` and keeps a copy of it on the
member's machine. When the server cannot be reached, or its catalogue cannot
be used, the manager falls back to that copy; with neither, nothing is
offered for installing.

- A file that is not valid JSON, or whose `version` is missing or higher than
  the manager understands, is refused whole, and the member's copy of the last
  good catalogue stays in use.
- Within an accepted catalogue, an entry without an `id`, a `name` or a
  `match` array, with spaces in its `id`, or repeating an earlier entry's
  `id`, is skipped and reported in REAPER's console; the other entries stay
  usable.

## Match strings

Each catalogue entry lists in `match` the strings that identify its plugin
inside a project. When a member opens a project, every plugin instance it uses
is looked up against these strings to find its entry; an instance that matches
no entry is reported as not in the catalogue.

### What to record

Record one string for each form the plugin takes in a project:

- **Display name, every format** — REAPER shows a plugin as, for example,
  `VST3: Acme Compressor (Acme Audio)`. Record it without the format prefix
  (`VST:`, `VSTi:`, `VST3:`, `AU:`, `CLAP:` and so on): `Acme Compressor`.
  The vendor in the last parenthesis may be kept or left out, since an
  instance matches either form; keep it when the name alone is generic, such
  as `Compressor (Acme Audio)`, because a bare `Compressor` would match every
  vendor's plugin of that name.
- **VST2** — the plugin file name for each platform, such as
  `AcmeCompressor.dll` and `AcmeCompressor.vst`.
- **VST3** — the plugin file name, such as `AcmeCompressor.vst3`.
- **AU** — the plugin's AU id.
- **CLAP** — the plugin's CLAP id, such as `com.acmeaudio.compressor`.

Record file names only, never a folder path: a project may have been saved on
another machine, with the plugin in another folder. When one installer ships
several plugins, list the match strings of each of them in its one entry.

Cover every format the installer puts on a machine. The entry is how the tool
recognises the plugin as already installed: when a member has it installed in
any form the entry matches, the entry is not offered again, and their
instances that still cannot load — a VST2 instance when only the VST3 is
installed, for example — are listed for replacement by hand.

### How strings are compared

Match strings are compared after normalization, so they need not be typed
exactly as REAPER shows them:

- Letters are lower-cased, and only the letters `a`–`z`, the digits and `.`
  are kept. Spaces, hyphens, colons and other punctuation are ignored, and so
  are letters outside `a`–`z`: `Acme Compressor`, `acme-compressor` and
  `ACME COMPRESSOR` are the same string.
- From a display name, the format prefix and trailing channel annotations
  such as `(2 out)` or `(8ch)` are removed before the lookup.
- From a plugin file identifier, the folder path and anything from a `<`
  onwards are removed, leaving the file name. AU and CLAP ids are compared
  whole.

A plugin is looked up by its file name or id first, then by its display name
with the vendor, then by its display name without the vendor; the first entry
found is the one used. When two entries record the same string after
normalization, the entry listed first in the catalogue takes it, so keep match
strings distinct across entries.
