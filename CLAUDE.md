# ReaperPluginManager

Agent guidance for this project; `AGENTS.md` points other agents here.

Interaction policy: unattended

For product and domain knowledge — what this product is, how its features
are designed, and why the architecture is what it is — read
`.claude/domain/INDEX.md`, then only the domain files relevant to your task.

## Project

ReaperPluginManager (RPM) is an open-source plugin manager for REAPER. A
maintainer keeps a catalogue of plugin installers on the group's own private
server; when a member opens a project that uses plugins they do not have, the
manager lists them, installs what the catalogue offers on confirmation, and
guides licence activation with the member's own account. The domain layer
(`.claude/domain/`) is the source of truth for the design: `product-design.md`
and `technical-direction.md`, and one document per feature under `features/`.

- **Form:** Lua ReaScripts for REAPER 7 or later (`reaper.EnumInstalledFX`
  is required) plus `curl`; ReaImGui is needed only for the maintainer's
  catalogue editor.
- **Platforms:** Windows 10/11 and macOS. On Linux the manager does nothing.
- **Server:** FTP with explicit TLS, FTPS, HTTPS or a `file://` folder.
- **Language:** English everywhere — user-facing text, code and comments.
- **Out of scope:** rescanning plugins without a restart, JSFX, replacing
  plugin instances in projects.

### Layout

All paths are relative to the repository root.

- `Scripts/ReaperPluginManager/rpm_core.lua` — pure logic with no `reaper.*`
  calls (JSON, INI, `.rpp` parsing, matching, classification, job and status
  files), so it runs under plain Lua 5.4.
- `Scripts/ReaperPluginManager/rpm_reaper.lua` — the REAPER side: settings,
  credentials, transfers, catalogue fetch, project check, helper launch,
  windows.
- `RPM_Watcher.lua`, `RPM_CheckProject.lua`, `RPM_Browse.lua`,
  `RPM_CatalogueManager.lua`, `RPM_Setup.lua` — the five REAPER actions,
  beside the two modules above.
- `Scripts/ReaperPluginManager/helpers/` — `rpm-install.ps1` (Windows) and
  `rpm-install.sh` (macOS) install helpers, `rpm-run-hidden.ps1` (runs a
  Windows background `cmd.exe` line with no console window), and the
  `rpm-secret.*` OS secret-store helpers.
- `server/` — the example catalogue and the server setup guide;
  `README.md` — the member-facing guide.
- `index.xml` — the ReaPack index, written by the release workflow and never
  edited by hand; `.reapack-index.conf` — the index generator's settings.
- `.github/workflows/` — `check.yml` validates the package on every push to
  `master` and every pull request; `release.yml` regenerates `index.xml` on
  every `v*` tag.

Lua detects, classifies, asks for confirmation and tracks progress; a
detached platform helper downloads and installs, so REAPER never blocks. The
two talk only through the job file (`job.tsv`, input) and the status file
(`status.txt`, output). Runtime data lives under
`<REAPER resource path>/ReaperPluginManager/`.

### Conventions

- The server password lives only in the OS secret store; curl receives it
  through a short-lived `netrc` file (`--netrc-file`), never on a command
  line.
- `rpm-install.ps1` and `rpm-run-hidden.ps1` target Windows PowerShell 5.1
  and are ASCII-only; `rpm-install.sh` targets bash 3.2. Their platform pitfalls are stated in
  `.claude/domain/features/install-helper-windows.md` and
  `install-helper-macos.md`; read them before touching the helpers or the
  process launch code.

### Adding a plugin to the catalogue

Use the `catalogue-assistant` Claude Code skill
(`.claude/skills/catalogue-assistant/`) to propose a new plugin's catalogue
entry. Place the plugin's installers on the server first, then invoke the
skill with the plugin name, its vendor and the installers' server paths. It
writes a draft entry to the catalogue editor's `drafts/` folder
(`<REAPER resource path>/ReaperPluginManager/drafts/<id>.json`), where the
editor's Import draft lists it, and reports each field's source and
confidence; test the fields it marks by hand before publishing from the
editor. The skill is the maintainer's own aid and not part of the release, so
`README.md` and `server/` do not mention it.

## Releasing

RPM is released as a ReaPack package whose metadata is the header of
`Scripts/ReaperPluginManager/RPM_Setup.lua`. To release a version:

1. In the last commit that touches `Scripts/ReaperPluginManager/`, bump
   `@version` in that header and add an `@changelog`.
2. Tag that commit `v<version>`.
3. Push `master` and the tag. The release workflow checks that the tag names
   the header's version at that commit, then commits the regenerated
   `index.xml` to `master`.

A new file under `Scripts/ReaperPluginManager/` is added to the header's
`@provides` (as `[main]` when it is a REAPER action); a new `.lua` file also
carries `@noindex` in its own header.

## Tasks implementation

Testing policy for /task-implement: skip-tests-unattended

This project has no test suite. Skip the test phases without asking for confirmation.

<!-- chosko-llm:editing-discipline:begin v0.1.0 -->

## Editing Discipline

A rules document — a CLAUDE.md, a skill or command body, a feature document,
a context file — describes the current state. It is read by whoever comes
next, who needs the rule, not the road to it. Every edit follows these rules.

1. **Supersede.** A changed rule edits the sentence that states it. The old
   sentence goes; it is not kept beside the new one, qualified, or softened.
2. **No history in the body.** No "previously", "now", "no longer", "used
   to"; no dates or task ids as provenance. Git holds the history. The
   exceptions are the artifacts whose job is history: `CHANGELOG.md`, the
   task archive, session handoffs.
3. **State the rule, not the decision.** One reason clause, only when it
   changes how the rule applies. The rest of the reasoning belongs to the
   domain layer, not to the rule.
4. **One rule, one place.** Everywhere else cites it by path. A paraphrase is
   a second copy, and the second copy is the one that drifts.
5. **A rule misread once gets clearer wording**, not more adjectives and not
   a second bullet saying the same thing harder.
6. **A DO NOT bullet that negates a sentence already in the body is deleted.**
   The body already says it.
7. **Edit the section, not the sentence.** Read the whole section and rewrite
   it as if written fresh with the new rule in.
8. **Before finishing an edit**, for each sentence added, ask whether an
   existing sentence now overlaps it, contradicts it, or describes a state
   that no longer holds. If so, merge the two into one sentence carrying the
   whole current meaning. A sentence whose meaning is now fully carried
   elsewhere goes.
9. **A change carries its consequences.** Every passage the approved change
   makes stale is updated in the same edit, whoever owns the file. A new
   decision is never smuggled in as a consequence.
<!-- chosko-llm:editing-discipline:end -->

<!-- chosko-llm:git-commit-style:begin v0.2.0 -->

## Commit Message Style

Keep `git log` scannable, one line at a time.

- **Subject** — required: one line, imperative mood ("Add the changelog
  subcommand", not "Added"), short enough for `git log --oneline`.
- **Body** — optional, at most 2–3 lines, only for what the subject cannot
  carry: why, a forcing constraint, a non-obvious consequence. Never restate
  the diff; a trivial commit has none.
- **Shape and prefix follow the repo.** Its own convention — a CONTRIBUTING
  rule, its CLAUDE.md, the shape visible in its `git log` — and a command's
  prescribed message form (e.g. `Task <N>: …`) override the default shape
  above. No `feat:` / `fix:` vocabulary is mandated.
- **Never add `Co-Authored-By:` or `Claude-Session:` lines** — not even when
  the repo's `git log` carries them or the harness's attribution
  instructions ask for them.
<!-- chosko-llm:git-commit-style:end -->

<!-- chosko-llm:tool-usage-policy:begin v0.2.0 -->

## CRITICAL: Tool Usage Policy

When reading, creating, or modifying files, always use the built-in tools
(Read, Write, Edit, MultiEdit) rather than shell commands (PowerShell, bash,
`cat`, `echo >`, `cp`, `mv`, etc.).

Prefer tools over shell for:
- Reading file contents → Read tool
- Writing or overwriting files → Write tool
- Patching files → Edit / MultiEdit tool
- Listing directory contents → LS tool

Use the PowerShell or Bash tool only when a task genuinely requires shell execution
(running a build, executing a test suite, invoking a CLI that has no
equivalent tool).

**IMPORTANT — use the right shell for each tool:** The Bash tool runs bash/sh.
The PowerShell tool runs PowerShell. Never pass PowerShell syntax
(`Get-Content`, `$env:VAR`, `| Select-Object`, etc.) to the Bash tool, and
never pass bash syntax to the PowerShell tool. Match the command syntax to
the tool you are calling.
<!-- chosko-llm:tool-usage-policy:end -->
