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
