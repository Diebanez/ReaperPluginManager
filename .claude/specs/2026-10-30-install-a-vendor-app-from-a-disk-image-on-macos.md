# Install a vendor app from a disk image on macOS

## Goal
Some catalogue entries install a vendor's app (UA Connect, the Spitfire Audio
app) whose macOS installer is a drag-to-Applications disk image holding only
the `.app`. The macOS install helper installs such an image silently: with no
package and no plugin bundle in it, the application at the image's top level
is copied into `/Applications`, replacing an older copy, asking for the
administrator password only when the member cannot write there, and then
inside the run's one password prompt.

## Acceptance criteria
- A `dmg` with a package within two levels is queued as a package, exactly as
  before.
- A `dmg` with no package and at least one plugin bundle outside an
  application bundle routes its plugins, exactly as before, and copies no
  application.
- A `dmg` with no package and no plugin bundle, holding a `.app` at its top
  level whose name does not contain `install` (any case), copies the first
  such application in name order to `/Applications/<name>.app`, replacing an
  existing copy, clears its quarantine flag, and reports `OK`, with no
  password prompt.
- When `/Applications` is not writable by the member, or an existing copy is
  not owned by the member, the application is copied into the entry's work
  folder and queued for the privileged phase, which replaces
  `/Applications/<name>.app` with it, clears its quarantine flag and writes
  the entry's `OK` or `FAIL application installation failed: <reason>`; the
  run still asks for the password at most once.
- A `dmg` holding neither a package, a plugin bundle nor such an application
  fails with the existing "no plugin … in the disk image" message.
- Plugin routing (zip and dmg) never descends into a `.app` bundle.
- `rpm-install.sh` stays bash 3.2 and ASCII-only.
- `server/README.md` § *Installers on macOS* describes the application case,
  the password rule and the hand test for it.

## Decisions
- **An application whose name contains `install` is passed over**: an
  installer app (e.g. `Splice Installer.app`) cannot be run silently, so
  copying it would install nothing usable.
- **The member's own copy first, the privileged phase as fallback**: copying
  as the member keeps an administrator's install silent; the fallback keeps
  the one-prompt rule for members who are not administrators.
- **Ownership decides the fallback**: an existing copy not owned by the member
  (installed by a vendor package as root) is replaced in the privileged phase,
  so a partial `rm -rf` never leaves a broken app behind.

## Hints
- `Scripts/ReaperPluginManager/helpers/rpm-install.sh` (`route_items`,
  `find_package`, `install_dmg`, `install_packages`)
- `server/README.md` (§ Installers on macOS, § One password for packages,
  § Try packages and disk images on a Mac first)
- `.claude/domain/features/install-helper-macos.md` (§ Architecture)

## Drift
- `.claude/domain/features/install-helper-macos.md` § Architecture (Install by type, `dmg`) — diverges: an image without a package has its bundles routed; the change installs a top-level application when the image holds no plugin bundle.
- `.claude/domain/features/install-helper-macos.md` § Architecture (Privileged phase) and the opening summary — diverges: the password is asked only when the job holds a package and the privileged script runs only `installer -pkg`; the change also queues an application the member cannot write into `/Applications`.
- `.claude/domain/features/plugin-installation.md` § Helper contract (Routing of extracted plugins) — settles: plugin items inside an application bundle are not routed.
- `server/README.md` § Try packages and disk images on a Mac first — diverges: "An image holding only an installer application cannot be installed by the manager"; the change installs an image holding the vendor application itself, and still not an installer application. Updated in this change.
