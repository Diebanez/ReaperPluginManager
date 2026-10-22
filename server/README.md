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
- `dest` — for an archive, or a macOS disk image without a package, where its
  plugins are put: `vst3`, `vst2`, `clap`, `au` or an absolute folder path.
  When it is left out, each plugin goes to the standard folder for its file
  type; *Installers on Windows* and *Installers on macOS* below list the
  folders of each platform.

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

## Installers on Windows

On Windows, the manager installs a `windows` installer according to its
`type`, after one administrator prompt per run; when the member refuses it,
every plugin of the run fails with "administrator permission denied".

- `exe` — the installer is run with the entry's `args`. Without `args` it
  opens its own installer window, which the member clicks through.
- `msi` — the package is installed with `msiexec /i <file> /qn /norestart`,
  followed by the entry's `args`.
- `zip` — the archive is unpacked and the plugins in it are copied to their
  folders, as described below.

Any other type fails with "installer type not supported on Windows".

An `exe` or `msi` installer succeeds when it exits with code `0`, or with
`3010`, which asks for a restart the manager does not perform. Any other code
fails with "installer exited with code <n>".

### Where plugins are copied

From a `zip`, the manager copies every plugin it finds to the folder for its
file type:

- `.vst3` (file or folder) — `C:\Program Files\Common Files\VST3`
- `.clap` — `C:\Program Files\Common Files\CLAP`
- `.dll` (VST2) — the folder in the member's `vst2_dir` setting, described in
  the member guide. Windows has no standard VST2 folder: with the setting
  empty, an archive holding a `.dll` fails with "no VST2 folder set" and
  nothing from it is copied.

Only the outermost plugins are copied, never the contents of a `.vst3`
folder, and `__MACOSX` folders are ignored. A plugin of the same name already
in the folder is replaced. When the archive holds more than one copy of the
same file name, the copies whose folder path in the archive contains a word
marking them 32-bit (`x86`, `32bit`, `32-bit`, `win32` or `32`) are skipped,
as long as one copy is not so marked. An archive holding no `.vst3`, `.clap` or `.dll` fails.

An entry's `dest` sends every plugin to one folder instead: `vst3`, `clap` and
`vst2` name the folders above, and an absolute path — a drive path such as
`D:\Plugins` or a network path such as `\\server\share\Plugins` — names any
other folder. `au` and any other value fail on Windows.

### Test silent switches by hand

Before publishing an `exe` or `msi` entry with `args`, run the installer with
those switches by hand on a Windows machine, from an administrator command
prompt, and check that it installs without opening a window and exits with
`0` or `3010`. Silent switches differ from one installer maker to the next,
and an installer that ignores them opens its window and waits for the member,
holding up the rest of the run.

## Installers on macOS

On a Mac, the manager installs a `macos` installer according to its `type`:

- `zip` — the archive is unpacked and the plugins in it are copied to their
  folders, as described below.
- `dmg` — the disk image is opened read-only, accepting any licence agreement
  it shows before opening. When it holds a package (`.pkg` or `.mpkg`) at its
  top level or one folder down, that package is installed as a `pkg` entry
  is; a package whose name contains `uninstall` is passed over. Otherwise the
  plugins in the image are copied to their folders as from a `zip`. The image
  is closed afterwards either way.
- `pkg` — the package is installed with macOS's own installer, for the whole
  machine.

Any other type fails with "installer type not supported on macOS".

### Where plugins are copied

From a `zip`, or a `dmg` without a package, the manager copies every plugin
bundle it finds into the member's `~/Library/Audio/Plug-Ins` folder, in the
subfolder for the bundle's type:

- `.vst3` — `VST3`
- `.component` (AU) — `Components`
- `.vst` (VST2) — `VST`
- `.clap` — `CLAP`

Only the outermost bundles are copied, never a bundle's own contents, and
`__MACOSX` folders are ignored. A bundle of the same name already in the
folder is replaced, and the quarantine flag is cleared from each copy so macOS
lets REAPER load it. An archive or image holding no plugin bundle fails.

An entry's `dest` sends every bundle to one folder instead: `vst3`, `vst2`,
`au` and `clap` name the `VST3`, `VST`, `Components` and `CLAP` subfolders
above, and an absolute path names any other folder. A package ignores `dest`:
it decides itself where it installs.

### One password for packages

Packages need administrator rights. The manager installs every other plugin
of the run first, then all the run's packages together, behind one macOS
password prompt — asked once per run, however many packages it holds. When
the member cancels the prompt, each package fails with "administrator
password not entered"; the plugins installed before it stay installed.

### Try packages and disk images on a Mac first

Before publishing a `pkg` or `dmg` entry, try its installer by hand on a Mac:

- A package is installed without its installer window, as
  `sudo installer -pkg <file> -target /` in Terminal installs it, so a
  package that works when opened by double-click can still fail there. Run
  that command on it once.
- Open a disk image and check that it holds a package at its top level or one
  folder down, or the plugin bundles themselves. An image holding only an
  installer application cannot be installed by the manager.

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
