# ReaperPluginManager

ReaperPluginManager keeps a group of REAPER users able to open each other's
projects. One maintainer keeps a catalogue of plugin installers on the group's
own server. When you open a project that uses plugins you do not have, the
manager lists them, installs what the catalogue offers once you agree, and
guides you through activating each plugin's licence with your own account.
You can also browse the catalogue and install any plugin it offers before a
project needs it.

## Installing

The manager needs REAPER 7 or later on Windows 10/11 or macOS; on any other
system it does nothing. Members and the maintainer install it the same way,
through ReaPack, REAPER's package manager:

1. If REAPER has no *Extensions > ReaPack* menu, install ReaPack first, as
   [reapack.com](https://reapack.com) describes, and restart REAPER.
2. Choose *Extensions > ReaPack > Import repositories...*, paste
   `https://github.com/Diebanez/ReaperPluginManager/raw/master/index.xml`
   and confirm.
3. Choose *Extensions > ReaPack > Browse packages*, find the
   ReaperPluginManager package, install it and apply the change.
4. Run Setup once: open REAPER's action list (*Actions > Show action list*),
   search for `RPM_Setup`, and run *Script: RPM_Setup.lua*.

ReaPack puts the files in `Scripts/ReaperPluginManager/Scripts/ReaperPluginManager/`
under REAPER's resource path (*Options > Show REAPER resource path in
explorer/finder*).

### Updating and removing

Updates arrive through ReaPack's package synchronisation (*Extensions >
ReaPack > Synchronize packages*); there is nothing to download by hand.

To remove the manager, uninstall the ReaperPluginManager package in
*Extensions > ReaPack > Browse packages*. ReaPack removes the scripts but
leaves Setup's block in REAPER's `Scripts/__startup.lua`: delete it by hand,
from the `-- >>> ReaperPluginManager` line to the
`-- <<< ReaperPluginManager` line (*What Setup does* below).

### For the maintainer

The *Script: RPM_CatalogueManager.lua* action also needs the ReaImGui
extension, which ReaPack cannot install as a dependency of this package.
Install it yourself from *Extensions > ReaPack > Browse packages*, searching
for ReaImGui (it comes from the ReaTeam Extensions repository, which ReaPack
includes by default), and restart REAPER.

The ReaPack package carries only the scripts and their helpers. The server
setup guide and the example catalogue are in the repository's
[`server/` folder](https://github.com/Diebanez/ReaperPluginManager/tree/master/server).

## Setup

Setup asks for the server connection in one dialog, saves it, and puts the
manager to work. It refuses to run on a REAPER older than version 7 ("REAPER
7 or later is required.") and on systems other than Windows and macOS.

### The dialog

The dialog proposes the current values; the password field always starts
empty.

- **Server URL** — the server address, starting with its scheme, such as
  `ftps://example.com/plugins/`; a missing final `/` is added. An address
  with no scheme is refused, and the dialog opens again.
- **User** — the server account's user name. Leave it empty to connect
  anonymously; any stored password is then removed.
- **Password** — masked as you type. Left empty with the same user, the
  stored password is kept. A password with spaces, tabs or line breaks is
  refused, and the dialog opens again with the other values kept. Where the
  password is kept is described under *The server password*.
- **TLS** — `required`, `try` or `off`, as the `tls` key in *Settings*
  describes; any other value becomes `required`.
- **Automatic check** — `yes` checks every project when it is opened; `no`
  (or `n`, `0`, `false`, `off`) checks only on demand. Any other value counts
  as `yes`.

Cancelling the dialog changes nothing.

### What Setup does

After you confirm the dialog, Setup:

1. saves the settings to `config.ini` and the password to your system's
   secret store;
2. registers the manager's five actions: *Script: RPM_Watcher.lua*,
   *Script: RPM_CheckProject.lua*, *Script: RPM_Browse.lua*,
   *Script: RPM_CatalogueManager.lua* and *Script: RPM_Setup.lua*;
3. adds a block between `-- >>> ReaperPluginManager` and
   `-- <<< ReaperPluginManager` to REAPER's `Scripts/__startup.lua`, creating
   the file when missing and leaving the rest of it as it is, so the watcher
   starts with every REAPER start;
4. starts the watcher right away, when automatic checking is on;
5. tests the connection by fetching the catalogue.

One message then reports each step, ending with "Connection succeeded: the
catalogue lists N plugins." or "Connection failed:" and the reason. A step
that fails is reported and the others still run where they can. A failed
connection test keeps the saved settings, so you can fix the server side and
run *Script: RPM_Setup.lua* again to test again.

### Turning automatic checks off

Run *Script: RPM_Setup.lua* and answer `no` to *Automatic check*, or set
`auto = 0` in the `[check]` section of `config.ini`. A running watcher stops
within a second, and from the next REAPER start the watcher exits at once;
projects are then checked only when you run *Script: RPM_CheckProject.lua*.
The startup block stays in place. To turn checks back on, run
*Script: RPM_Setup.lua* and answer `yes`: the watcher starts at once.

### Running Setup again

Running Setup again is safe: use it to change the server, the user, the
password, the TLS level or automatic checking, or only to test the
connection. It proposes the current values, keeps each action already
registered, replaces its startup block in place instead of adding a second
one, and does not start a second watcher.

## The project check

A check reads the project file as last saved, finds every plugin the project
uses, wherever it sits — track and master effects, take effects and
containers — and works out which are not installed on your machine. A plugin
counts as installed when REAPER lists the same plugin file or id, or a plugin
of the same format and name, so a project saved on another platform is
recognised too. Plugins added since the last save are not part of the check.

### When a project is checked

While automatic checking is on (`auto` in the `[check]` section of the
settings), the *Script: RPM_Watcher.lua* action checks every saved
project in the background each time it is opened, in a new tab or in place
of another project, about a second after it has loaded. Switching between
project tabs is not an opening and checks nothing; closing a project and
opening it again checks it again. Reloading a project in the tab it is
already in is not detected: run *Script: RPM_CheckProject.lua* instead. A project that has
never been saved is not checked. When the check finds nothing to list, no
window opens. While plugins are being installed, the projects you open are
checked once the install has ended. A check that fails writes the error to
the REAPER console and does not stop the watcher.

The *Script: RPM_CheckProject.lua* action checks the current project on
demand and always answers: the summary window, or a message — "All N
plugins are installed.", "The project uses no plugins.", "Save the project
first." for a project never saved, or that the project file cannot be read.
When the only missing plugins are ones not in the catalogue and that group is
switched off, the message counts them and says why they are not listed.

### The summary window

One summary window lists everything the check found. Its heading names the
project file and how many of its plugins are not installed. The findings are
sorted into groups, each title carrying its count, and empty groups are left
out:

- **To install** — the catalogue has an installer for your platform. Each
  plugin is listed once, as *Name (Vendor)* with the maintainer's note,
  however many instances the project holds. A plugin marked *unmanaged
  installer* installs through an install script the group's maintainer put
  on the server, which runs with administrator rights on Windows and with
  your own user's rights on macOS (*Installing plugins* below).
- **No installer for Windows** (or **macOS**) — the catalogue knows the
  plugin, but has no installer for your platform.
- **Not in the catalogue** — no catalogue entry matches the plugin, listed
  with its format and number of instances. Ask the maintainer to add it. This
  group can be switched off in the settings (`notify_unknown`).
- **Instances to replace by hand** — instances that will stay offline even
  after installing, because their format cannot be loaded here, each with the
  reason. See below.
- **Activation pending** — installed plugins whose licence activation you
  skipped; they stay listed until you confirm the activation. Each has an
  *Activate* button that opens the activation window for that plugin
  (*Activating licences* below); when it closes, the summary comes back
  without the plugins you confirmed.

The list scrolls with the mouse wheel, the arrow keys, Page Up, Page Down,
Home and End, and nothing is cut short. At the bottom, **Install N plugins**
— shown only when something can be installed — closes the window and starts
installing every plugin under *To install*; **Close**, or Escape, closes it
and installs nothing. A new check replaces a summary window that is still
open.

### Why an instance can need replacing by hand

The manager never modifies a project, so an instance whose format cannot be
loaded on your machine stays offline whatever is installed. You replace it
yourself, in REAPER, with a format you have. This happens in two cases:

- **The format does not exist on your platform.** An AU instance on Windows,
  or a DX instance on macOS, can never load there. When the catalogue can
  install the plugin, it also appears under *To install*: installing gives you
  the formats your platform loads, and you swap the instance for one of them.
- **The plugin is installed, but not in this format.** A VST2 instance in a
  project, on a machine where the catalogue's plugin is installed only as
  VST3, stays offline: the catalogue recognises the plugin as installed, so
  there is nothing to install, and the instance must be swapped for the VST3.

Formats loaded on Windows: VST2, VST3, CLAP, LV2 and DX. On macOS: VST2,
VST3, AU, CLAP and LV2.

### When the server cannot be reached

Every check fetches the catalogue from the server and keeps a copy of it on
your machine. When the server cannot be reached, or the catalogue on it cannot
be read, the check uses the cached copy, so a project can still be checked
offline, and a banner under the summary's heading says so and why: "The
server catalogue could not be used, so the cached one was." followed by the
reason. The copy belongs to the server address it came from: after you change
the address, it is not used. With no server and no cached copy, the check
finds no catalogue, nothing is offered for installing, and the banner reads
"No catalogue is available, so nothing can be installed." with the reason.

## Browsing the catalogue

The *Script: RPM_Browse.lua* action lists every plugin the group's catalogue
offers, so you can install one before any project uses it. Run it from
REAPER's action list; it needs no open project.

### The catalogue window

One window lists the catalogue's plugins, sorted by name. Its heading counts
them and says how many are installed on your machine and how many can be
installed. Each plugin is listed as *Name (Vendor)* with the maintainer's
note, and *unmanaged installer* beside the name of a plugin that installs
through an install script (*The summary window* above). Each plugin is in one
of three states:

- **Installed** — REAPER lists the plugin, recognised the way the project
  check recognises it. The row says "installed" and cannot be ticked:
  the browser never reinstalls or updates a plugin.
- **Can be installed** — the catalogue has an installer for your platform.
  The row carries a checkbox; a click anywhere on the row ticks or unticks it.
- **No installer** — the catalogue knows the plugin but has no installer for
  your platform. The row says "no installer for Windows" (or macOS) and
  cannot be ticked.

Typing filters the list: it keeps the plugins whose name contains what you
typed, ignoring case. Backspace removes the last character; Escape clears the
search, or closes the window when the search is already empty. A tick
survives the search: a ticked plugin the search hides stays ticked and is
installed with the others. The list scrolls with the mouse wheel, the arrow
keys, Page Up, Page Down, Home and End.

At the bottom, **Install N plugins** — shown only when at least one plugin is
ticked, and counting every ticked plugin — closes the window and installs
them, ending with the offer to restart REAPER so it detects them
(*Installing plugins* below); **Close** closes it and installs nothing.
When the ticked plugins include any marked *unmanaged installer*, the same
one confirmation as in the summary window comes first; cancelling it keeps
the window open with your ticks.

### While an install is running

One install runs at a time, wherever it was started. While one is running,
the action opens no window and says "An install is already running. Try
again when it has finished."; pressing **Install N plugins** while an
install started elsewhere is running shows the same message and keeps the
window open with your ticks.

### When the server cannot be reached

The browser fetches the catalogue as a check does. When it uses the cached
copy, a banner under the heading says so and why: "The server catalogue
could not be used, so the cached one was." followed by the reason. With no
server and no cached copy, no window opens, and a message says "No catalogue
is available, so nothing can be listed." with the reason. A catalogue that
lists no plugins opens no window either: "The catalogue lists no plugins."

## Installing plugins

When you agree to install the plugins the summary offers, or the ones you
ticked in the catalogue window, the manager downloads and installs them in
the background, so REAPER stays usable while they install. One install runs
at a time, and a failure stops only the plugin it hit; the others go on.

When the plugins to install include any marked *unmanaged installer*,
**Install N plugins** first asks for confirmation, in one prompt naming each
of them. Continue only if you trust the server's maintainer: their script
runs on your machine with the rights stated in *The summary window* above.
Cancelling installs nothing, not even the other plugins, and leaves the
summary window or the catalogue window open.

### The progress window

A progress window lists every plugin of the run with where it stands:
queued, downloading, verifying, installing, installed (in green) or failed (in
red, with the reason underneath). Closing the window does not stop the
install: when the run ends, the window opens again with the final summary.
When nothing is heard from the installer 30 seconds after the start, every
plugin fails with "the installer helper did not start".

### One administrator prompt

A run asks for administrator rights at most once, however many plugins it
installs:

- **Windows** — one administrator prompt when the run starts. Refusing it
  fails every plugin of the run with "administrator permission denied".
- **macOS** — only packages need administrator rights. They are installed
  together after every other plugin of the run, behind one password prompt.
  Cancelling it fails each package with "administrator password not
  entered"; the plugins installed before it stay installed.

### The final summary

When the run ends, the window shows how many plugins were installed and how
many failed, with the reason for each failure. Closing it hands over to
licence activation for the installed plugins that need it (*Activating
licences* below), then to the offer to restart REAPER (*Restart and reopen*
below). When nothing was installed, the run ends there.

### Restart and reopen

REAPER detects new plugins only when it starts. When at least one plugin was
installed, after the activation window when there is one, the manager asks
whether to restart REAPER now:

- **Yes** — REAPER quits, asking first whether to save unsaved changes as on
  any quit, and starts again on its own. Once it has finished starting, the
  projects that were open reopen, each in its own tab, with the one you were
  working on selected. A project that was never saved has no file and does
  not reopen, nor does one whose file is gone. If you cancel the quit, REAPER
  keeps running and the projects reopen at its next start. If REAPER cannot
  be restarted, a message says so and REAPER keeps running: restart it
  yourself, and the projects reopen then.
- **No** — a message reminds you to restart REAPER yourself. For an install
  started from the summary window, the project it was checking reopens on
  its own after that restart, once REAPER has finished starting, unless it
  is already open or its file is gone. An install started from the catalogue
  window reopens no project after a restart you make yourself.

If an installed plugin still does not appear after the restart, rescan in
REAPER: *Preferences > Plug-ins > VST > Re-scan*.

## Activating licences

Every plugin is activated with your own licence and your own vendor account.
The group's server holds installers only, never licence keys, serials or
vendor accounts, and the manager never shares, uploads or bypasses an
activation: it shows you how each plugin is activated, opens the vendor's app
or page, and remembers what you have not confirmed yet. It cannot check that
a plugin is really activated, so it takes your word for it.

### The activation window

After an install run, once you close its final summary, the activation window
walks you through the installed plugins whose catalogue entry names an
activation method, one step at a time. Plugins activated in the same vendor
app share one step; any other plugin has a step of its own. Each step names
the plugin or plugins, how they are activated — in the vendor app, with your
serial number, or by signing in to your vendor account — and the maintainer's
instructions, with three buttons:

- **Activate** — opens what the activation needs: the vendor app when it is
  installed where the catalogue expects it, otherwise its download page; the
  vendor's page for a serial or a sign-in. When you have saved the plugin's
  serial (*Saving a serial* below), it is also copied to the clipboard, ready
  to paste. A line under the step says what was opened, or why nothing was.
- **Done** — you have activated it: the plugins of the step are no longer
  pending, and the next step opens.
- **Later** — you will activate it another time: the plugins stay pending,
  and the next step opens.

Closing the window, or pressing Escape, leaves every step you have not marked
Done pending. When the window closes, the manager offers to restart REAPER
(*Restart and reopen* above).

### Activation pending

A plugin stays "activation pending" from the moment it enters the activation
window until you press Done for it. Whenever a check finds a project using a
pending plugin, the summary window lists it under **Activation pending** with
an *Activate* button that opens the activation window for that plugin again
(*The summary window* above). The reminder cannot be switched off: it ends
when you confirm the activation.

### Saving a serial

When you press Done on a plugin activated with a serial number, the manager
offers to save the serial on your machine, in a masked field; Cancel, or an
empty field, saves nothing, and the offer is not made again once a serial is
saved. A saved serial makes a reactivation faster: Activate copies it to the
clipboard. It is kept in your system's secret store, as the server password is
(*The server password* below) — on Windows encrypted for your Windows account,
under the `secrets` folder beside `config.ini`; on macOS in your default
Keychain, as an item named `ReaperPluginManager-serial` with the plugin's
catalogue id as its account. It is never written to a file in clear, never
put on a command line, and never sent anywhere. When the secret store cannot
be used, the serial is not saved or copied, and the manager says why.

## Settings

The settings live in `config.ini`, in the `ReaperPluginManager` folder of
REAPER's resource path (*Options > Show REAPER resource path in
explorer/finder*). *Script: RPM_Setup.lua* writes the server address, user,
TLS level and automatic check; set the other keys by editing the file, which
keeps every key and comment Setup does not change. A missing key, or a value the
manager does not accept, takes its default. Comments start with `;` or `#`.

| Section | Key | Values | Default |
| --- | --- | --- | --- |
| `[server]` | `url` | The server address, starting with its scheme, such as `ftps://example.com/plugins/`; a missing final `/` is added | empty |
| `[server]` | `user` | The server account's user name; empty connects anonymously | empty |
| `[server]` | `tls` | `required` (the connection must be encrypted), `try` (encrypted when the server offers it) or `off` | `required` |
| `[server]` | `insecure` | `1` accepts a server certificate that is not trusted, such as a self-signed one; `0` refuses it | `0` |
| `[install]` | `vst2_dir` | Windows only, optional: the folder where VST2 `.dll` files unpacked from a zip installer are put. Empty skips them: the VST3 and CLAP versions are installed and the install window names the VST2 files left out | empty |
| `[check]` | `auto` | `1` checks every project when it is opened; `0` checks only on demand | `1` |
| `[check]` | `notify_unknown` | `1` lists the plugins that are not in the catalogue; `0` hides that group | `1` |

### The server password

The server password is never written to `config.ini`. Setup keeps it in your
system's secret store: on Windows encrypted for your Windows account, under
the `secrets` folder beside `config.ini`; on macOS in your default Keychain, as
an item named `ReaperPluginManager:<server host>`. The manager reads it once
per REAPER session and hands it to `curl` through a credentials file that
exists only while a transfer runs, so it never appears on a command line. A
password cannot contain spaces, tabs or line breaks.

Each machine uses one server account, for checking projects, installing and
publishing alike. Members use a read-only account; the maintainer uses an
account that can write, and a write attempted with a read-only account fails
with the server's own error.

## Licence

ReaperPluginManager is licensed under the GNU General Public License v3.0.
The full text is in [`LICENSE`](LICENSE).
