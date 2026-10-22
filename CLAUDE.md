# ReaperPluginManager

Agent guidance for this project; `AGENTS.md` points other agents here.

Interaction policy: unattended

For product and domain knowledge — what this product is, how its features
are designed, and why the architecture is what it is — read
`.claude/domain/INDEX.md`, then only the domain files relevant to your task.

## Project

ReaperPluginManager (RPM) is a plugin manager for REAPER. Plugin installers
live on a private FTP server; when the user opens a project that uses plugins
that are not installed, the manager lists them and, on confirmation,
downloads and installs them. `SPEC.md` (in Italian) is the full
specification and the source of truth for data formats, flows, test plan and
acceptance criteria.

- **Form:** Lua ReaScripts for REAPER 7 or later (`reaper.EnumInstalledFX`
  is required); no compiled extension and no dependency beyond `curl`.
- **Platforms:** Windows 10/11 and macOS. On Linux the manager does nothing.
- **Server:** FTP with explicit TLS; `ftps://`, `https://` and `file://`
  URLs must work too.
- **Language:** user-facing text in Italian; code and comments in English.
- **Out of scope:** licence activation, rescanning plugins without a restart,
  JSFX, uploading to the server, replacing plugin instances in projects.

### Layout

All paths are relative to the repository root.

- `Scripts/ReaperPluginManager/rpm_core.lua` — pure logic with no `reaper.*`
  calls (JSON, INI, `.rpp` parsing, matching, classification, job and status
  files), so it runs under plain Lua 5.4 in tests.
- `Scripts/ReaperPluginManager/rpm_reaper.lua` — the REAPER side: config,
  manifest download, project check, helper launch, progress window.
- `RPM_Watcher.lua`, `RPM_CheckProject.lua`, `RPM_ExportInstalled.lua`,
  `RPM_Setup.lua` — the four REAPER actions, beside the two modules above.
- `Scripts/ReaperPluginManager/helpers/` — `rpm-install.ps1` (Windows) and
  `rpm-install.sh` (macOS) install helpers.
- `server/manifest.example.json`, `tests/`, `README.md`.

Lua detects, classifies, asks for confirmation and tracks progress; a
detached platform helper downloads and installs, so REAPER never blocks. The
two talk only through the job file (`job.tsv`, input) and the status file
(`status.txt`, output). Runtime data lives under
`<REAPER resource path>/ReaperPluginManager/`.

### Conventions

- Credentials go to curl only through a separate `netrc` file
  (`--netrc-file`), never on the command line.
- `rpm-install.ps1` targets Windows PowerShell 5.1 and is ASCII-only,
  Italian messages included; `rpm-install.sh` targets bash 3.2.
- `SPEC.md` §8 lists the known platform pitfalls (PowerShell 5.1 encoding
  and module loading, bash field splitting, Lua `gsub` return values,
  `reaper.ExecProcess` timeouts); read it before touching the helpers or the
  process launch code.

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
