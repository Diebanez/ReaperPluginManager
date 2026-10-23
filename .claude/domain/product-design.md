# ReaperPluginManager

ReaperPluginManager keeps a group of REAPER users able to open each other's
projects. One maintainer keeps a catalogue of plugin installers on the
group's own private server. When anyone in the group opens a project that
uses plugins they do not have, the tool lists them, installs what the
catalogue offers once the user agrees, guides the user through activating
each plugin's licence with their own account, and reopens the project after
REAPER restarts. It is open source, for any band, studio or group that shares
REAPER projects across Windows and Mac machines.

Technical foundations (stack, architecture, hosting) are recorded in
[technical-direction.md](./technical-direction.md), not here.

## Target users

### Maintainer

One person per group curates the catalogue: which plugins it offers, the
installer for each platform, how each plugin identifies itself inside a
project, and how its licence is activated. The maintainer runs the server and
hands members the credentials to read it. Without the tool, this is a
hand-kept server folder plus messages telling bandmates what to install. The
maintainer is also a member on their own machines.

### Members

Bandmates who open shared projects on their own Windows or Mac machine. They
reach for the tool the moment a project opens with plugins offline. Their
access to the server is read-only, with credentials the maintainer provides.
Without the tool, they find missing plugins one at a time from REAPER's
offline-plugin warnings, hunt down installers and ask the maintainer.

## User experience and key flows

### Opening a project with missing plugins (member)

1. The member opens a saved project. The tool checks it automatically every
   time a project is opened (switching between open tabs is not an opening);
   an action runs the same check on demand on the current project.
2. Every plugin installed → nothing happens (the on-demand check says all N
   plugins are installed). An unsaved project cannot be checked; the
   on-demand check asks the member to save it first.
3. Otherwise a single window lists everything missing, per group: plugins
   the catalogue can install
   (with the maintainer's note), plugins with no installer for this
   platform, plugins the catalogue does not know, and instances that will
   stay offline even after installing and need replacing by hand (an AU
   instance on Windows, a VST2 instance when only the VST3 is installed),
   and installed plugins still pending activation.
   When the server cannot be reached, the last catalogue fetched is used and
   the summary says why.
4. The member confirms the download and install. It runs in the background
   — REAPER stays usable — with a progress window showing each plugin as
   queued, downloading, verifying, installing, installed or failed. Closing
   the window does not stop the install. A run asks for administrator rights
   at most once.
5. For each installed plugin that needs licence activation, the tool shows
   how it is activated, opens the vendor's app or page, and asks the member
   to confirm once they have signed in or entered their own serial. A
   skipped activation leaves the plugin flagged "activation pending", and
   the tool reminds the member each time a project uses it.
6. A final summary lists what was installed and what failed, with the
   reason. When anything was installed, the member restarts REAPER; the
   project reopens on its own once REAPER has started.

### First-time setup (member and maintainer)

The user runs the setup action once and enters the server address, user,
password and encryption level. The tool registers its actions, arranges to
check projects automatically from every REAPER start, starts checking right
away, and tests the connection, reporting how many plugins the catalogue
lists or what went wrong. Re-running setup updates the values without
duplicating anything; a blank password with the same user keeps the stored
one.

### Adding a plugin to the catalogue (maintainer)

Inside REAPER, the maintainer picks the plugin from REAPER's installed
plugins, so the tool captures how each of its formats names itself in a
project, or types the name, vendor and identities by hand when the plugin is
not installed on that machine. They attach one installer per platform, or a
single package that serves both, set the install options and the activation
method, and the tool uploads the files and updates the catalogue. A
Claude-based assistant, the maintainer's personal aid, helps fill an entry in
correctly — silent-install switches, activation method, how the plugin names
itself.
The maintainer can later add the second platform's installer to an entry,
replace an installer with a newer version, or remove a plugin.

## Design decisions

- Windows and macOS only; on Linux the tool does nothing.
- Two roles: the maintainer is the only one who writes the catalogue;
  members read it and do not report anything back through the tool.
- The catalogue lives on the group's own private server — FTP with TLS,
  FTPS, HTTPS, or a local, network or cloud-synced shared folder. There is no
  central service; the release ships what a group needs to set up its own
  server, including the shared-folder option that needs no server software.
- Only saved projects are checked, each time one is opened, with all
  findings in a single window.
- Installing never blocks REAPER. New plugins become visible only after a
  restart, because REAPER cannot rescan plugins while running, so the tool
  reopens the project after the restart.
- The tool never modifies a project: instances that cannot load on this
  platform are reported for manual replacement.
- A plugin that no silent installer or plain plugin files can install ships
  as an install script the maintainer packs on the server — an unmanaged
  installer, which runs with administrator rights. The group's server is
  self-managed and trusted by its members, so beyond the checksum check the
  only safeguard is an explicit warning before installing one: no script
  preview, no time limit, no signing.
- Licensing stays legal: each user activates every plugin with their own
  licence and account. The server holds installers, never licence keys or
  vendor credentials, and the tool never shares or bypasses an activation.
  Within that limit activation is made as fast as possible — a user's own
  licence details may be kept on their own machine to speed up a
  reactivation.
- The tool cannot verify that a plugin is activated; it trusts the user's
  confirmation and flags what was skipped rather than blocking it.
- JSFX are out of scope.
- English-only interface.
- Constraint: plain REAPER 7 scripts plus `curl`, no compiled extension.

## High-level features

### Setup

Serves every user, in the first-time setup flow. One action asks for the
server address, user, password and encryption level, proposing the current
values on a re-run, and rejects input the tool cannot use (an address with no
scheme, a password the credentials file cannot hold). It registers the tool's
actions in REAPER, arranges for projects to be checked automatically from
every REAPER start without duplicating that arrangement on a re-run, starts
checking at once, and ends by testing the connection: how many plugins the
catalogue lists, or why the server could not be reached. Users who do not
want automatic checks can turn them off and keep the on-demand check.

### Project check

Serves members, in the open-a-project flow, up to the point they agree to
install. Every saved project is checked each time it is opened — switching
between project tabs is not an opening — and an action checks the current
project on demand. It finds every plugin
the project uses, wherever it sits (track, master, take or container
effects), works out which are not installed here, and fetches the latest
catalogue, falling back to the last one fetched when the server cannot be
reached. One summary window lists every missing plugin, grouped into:
installable from the catalogue (with the maintainer's note), no installer
for this platform, not in the catalogue (a group the user can switch off),
instances that need replacing by hand, and installed plugins still pending
activation. Plugins whose installer is an unmanaged install script are
marked as such. With something installable, it asks whether to download and
install now, warning first, in one prompt, about every unmanaged installer
it would run; otherwise the summary is informational only.

### Plugin installation

Serves members, in the open-a-project flow, from the moment they agree to
install. Downloads and installs run in the background while REAPER stays
usable; a progress window shows each plugin as queued, downloading,
verifying, installing, installed or failed, and closing it does not stop
the run. A run asks for administrator rights at most once (once on Windows,
one password on macOS). A failure stops only the plugin it hit. At the end a
summary lists what was installed and what failed with the reason; when
anything was installed it tells the user to restart REAPER, and the project
reopens on its own after the restart.

### Licence activation

Serves members, in the open-a-project flow after installation, and on every
later project check. For each newly installed plugin whose catalogue entry
names an activation method — vendor app, serial number or vendor sign-in —
it shows how that plugin is activated, opens the vendor's app or page, and
asks the user to confirm once they have activated it with their own licence.
A plugin left unconfirmed is flagged "activation pending" and the tool
reminds the user whenever a project uses it, until they confirm. A user's
own licence details may be kept on their own machine to speed up a
reactivation; nothing licence-related ever goes to the server.

### Catalogue management

Serves the maintainer, in the add-to-catalogue flow. Inside REAPER, the
maintainer adds a plugin by picking it from REAPER's installed plugins —
capturing how each of its formats names itself in a project, grouping the
formats of one plugin into one entry — or by typing the name, vendor and
identities by hand. They attach an installer per platform or one package
serving both — for a plugin no installer or plain plugin files can install,
a zip carrying an install script, marked as an unmanaged installer — set the
install options (silent-install switches, where
extracted plugins go, an optional checksum), the activation method and a
note shown to members. Existing entries can gain the other platform's
installer, have an installer replaced by a newer version, or be removed.
Changes collect in a local draft until the maintainer publishes them at
once: the tool uploads the new installers, updates the catalogue on the
server in one step, and deletes the installer files it no longer references.

### Catalogue assistant

Serves the maintainer, before or during catalogue management. A Claude-based
assistant that researches a plugin from official vendor sources, inspects
its installers already placed on the group's server, and proposes its
catalogue entry: the installer type, the silent-install switches to try,
the activation method and how the plugin names itself in projects, flagging
what must still be tested by hand. It never downloads from vendor sites. It is a personal aid for this project's maintainer and is not
part of the open-source release.
