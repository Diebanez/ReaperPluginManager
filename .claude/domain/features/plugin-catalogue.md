# Plugin catalogue

The catalogue as data: its format on the server, the JSON codec that reads
and writes it, fetching it with a cached fallback, and the lookup index the
rest of the tool matches plugins against.

## Purpose

The catalogue is the one contract between the maintainer and every member:
which plugins exist, how each names itself in a project, and which installer
serves each platform. The project check reads it, plugin installation
follows it, licence activation reads its activation fields, and catalogue
management writes it. This feature owns its shape once. Part of
[product-design.md § Project check](../product-design.md#project-check).

## Scope and non-goals

In scope:
- The catalogue schema and its format version.
- A JSON parser and encoder in pure Lua (REAPER ships none).
- Fetching the catalogue through `server-access`, the local cache, and the
  fallback to it.
- The match index from normalized match strings to entries.

Non-goals:
- The content of an entry's `activation` field — `licence-activation` defines
  it; this feature carries it through untouched.
- Deciding whether a plugin is installed or missing — `plugin-detection`.
- Writing the catalogue to the server — `catalogue-management` (via
  `server-access`'s safe replace).

## Architecture

Built on pure Lua plus `server-access`, per
[technical-direction.md](../technical-direction.md). Everything except the
fetch lives in the module with no `reaper.*` calls.

- **JSON codec** — parser: objects, arrays, strings with `\uXXXX` escapes
  and surrogate pairs, numbers, `true`/`false`/`null`, a leading UTF-8 BOM
  tolerated, errors reported with their position. Encoder: indented output
  with a fixed, readable key order (`id, name, vendor, note, match,
  installers, file, type, args, sha256, dest, activation`, other keys after
  in alphabetical order).
- **Schema validation** — a catalogue whose JSON is invalid, or whose
  `version` is missing or higher than the tool understands, is rejected
  whole. Within an accepted catalogue, an entry missing a required field or
  repeating an `id` is skipped and reported to the REAPER console; the rest
  stay usable.
- **Fetch** — downloads the catalogue from the server root to a temporary
  local file; when it parses and validates, it replaces the cache. On any
  failure the cache is used and the reason is kept for the summary. No
  server and no cache → no catalogue, and nothing is installable.
- **Match index** — maps `norm(m)` for every match string `m` of every entry
  to that entry (`norm` is `plugin-detection`'s normalization).

## Data and state

- **Catalogue** (`manifest.json` at the server root):
  - `version` — `1`.
  - `plugins[]`, each entry:
    - `id` (required) — unique, no spaces; used in job and status files;
    - `name` (required), `vendor` — shown to users;
    - `note` — shown beside the name;
    - `match[]` (required) — the strings that identify the plugin in
      projects: the display name without its format prefix, the file name,
      the AU id, the CLAP id; one entry may cover several plugins shipped by
      one installer;
    - `installers.windows`, `installers.macos` — each absent, or an object
      with `file` (required, path relative to the server root), `type`
      (`exe` | `msi` | `zip` on Windows, `pkg` | `dmg` | `zip` on macOS;
      default from the file extension), `args` (Windows silent switches or
      MSI properties), `sha256`, `dest` (`vst3` | `vst2` | `clap` | `au` |
      absolute path, for archives). An installer with an empty `file`
      counts as absent. A package serving both platforms is the same `file`
      named under both keys;
    - `activation` — owned by `licence-activation`.
- **Cache** — the last valid catalogue, in the tool's local data folder,
  with the server URL it came from; a cache from a different URL than the
  current setting is ignored.
- **In-memory** — the parsed catalogue and its match index, rebuilt per
  check.

## Interfaces and contracts

- `json.decode(text) → value | nil, err_with_position`
- `json.encode(value) → text`
- `catalogue.validate(value) → catalogue, warnings | nil, err`
- `catalogue.fetch() → catalogue | nil, source, reason` — `source` is
  `server`, `cache` or `none`; `reason` explains a fallback.
- `catalogue.index(catalogue) → lookup(normalized_string) → entry | nil`
- Failure contract: fetch never raises; a malformed catalogue on the server
  never replaces a good cache.

## Dependencies

- `server-access` — the download.
- `plugin-detection` — the `norm` normalization the index uses.
- `licence-activation` — defines the `activation` field's content.

## Open questions

None.
