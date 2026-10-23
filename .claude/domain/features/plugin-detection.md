# Plugin detection

The pure matching logic: which plugins a project uses, which of them are not
installed here, which catalogue entry each belongs to, and what can be done
about each.

## Purpose

The project check is only as good as its matching: a plugin reported missing
when it is installed, or matched to the wrong catalogue entry, makes the
tool wrong in front of the user. This feature holds that logic in one place,
with no REAPER calls, so it behaves identically wherever it runs. Part of
[product-design.md § Project check](../product-design.md#project-check);
it implements SPEC.md §4 unchanged.

## Scope and non-goals

In scope:
- Reading the plugin references out of a saved project file.
- Normalizing plugin names and identifiers.
- Deciding installed or missing against a list of installed plugins.
- Associating references and installed plugins with catalogue entries.
- Classifying missing references into the summary groups.

Non-goals:
- Enumerating installed plugins from REAPER (the watcher supplies the list).
- Showing anything to the user.
- JSFX: excluded from detection.
- Replacing plugin instances in a project.

## Architecture

Pure Lua in the module with no `reaper.*` calls, per
[technical-direction.md](../technical-direction.md).

- **Project scanner** — reads the project file line by line; every line
  that, trimmed, starts with `<VST `, `<AU `, `<CLAP `, `<LV2 ` or `<DX ` is
  a plugin reference, wherever it sits (track chains, master, take FX,
  containers). Tokenizes on spaces, with tokens quoted by `"`, `'` or `` ` ``;
  token 2 is the display name, token 3 the identifier. Returns distinct
  references by (tag, display name, identifier) with instance counts, in
  order of appearance.
- **Normalizer** — `norm(s)`: lower-case, keep only letters, digits and `.`.
  Splits a display name into format (from the prefix before `:`), base name
  (trailing `(N out)` / `(Nch)` removed repeatedly) and bare name (base name
  without its last parenthesis, the vendor). Identifier key: drop everything
  from `<`; for a file identifier keep only the file name; then `norm`. AU
  ids stay whole.
- **Installed check** — a reference is installed when its identifier key
  matches an installed plugin's, or `format:norm(base name)` matches (which
  covers VST2 across platforms).
- **Catalogue association** — a reference or installed plugin looks up, in
  order, its identifier key, `norm(base name)`, `norm(bare name)` in the
  catalogue's match index. An entry is "present" when any installed plugin
  associates with it: `present_entries` returns that set, and the classifier
  and the `catalogue-browser` entry states both call it.
- **Classifier** — per missing reference, with `p` the associated entry and
  `spec` its installer for this platform (`plugin-catalogue`'s
  `catalogue.installer(p, platform)`): `p` present → replace by hand;
  `spec` exists → installable (grouped per entry, instances summed), and
  also replace by hand when the format cannot load on this platform; `p`
  without `spec` → no installer for this platform; no `p` and an unloadable
  format → replace by hand; no `p` → unknown. Loadable formats: Windows
  vst, vst3, clap, lv2, dx; macOS vst, vst3, au, clap, lv2.

## Data and state

Stateless. Inputs: project file text, the installed-plugin list (display
name and identifier per plugin), the catalogue match index, the platform.
Output: the classification groups. Nothing is persisted.

## Interfaces and contracts

- `scan_project(text) → refs[]` — each `{ tag, name, ident, count }`.
- `norm(s)`, `split_name(display) → format, base, bare`, `ident_key(ident)`.
- `missing(refs, installed) → refs[]`
- `present_entries(installed, lookup) → set` — the catalogue entries some
  installed plugin associates with through the match index `lookup`, keyed
  by entry; empty when `lookup` is nil (no catalogue). Called by `classify`
  and by `catalogue-browser`.
- `classify(missing_refs, installed, catalogue_index, platform) → { installable[], no_installer[], unknown[], replace[] }`
- `group_installed(installed) → groups[]` — installed plugins grouped by
  `norm(base name)`, so the formats of one plugin form one group; used by
  catalogue management.
- Failure contract: a malformed line is skipped, never fatal; an empty
  project yields no references.

## Dependencies

- `plugin-catalogue` — the match index it classifies against.

## Open questions

- The exact identifier forms `EnumInstalledFX` returns per format and
  platform (file name, full path, `<id>` suffix) — the identifier key
  handles all three, to be confirmed in REAPER (SPEC.md §11).
