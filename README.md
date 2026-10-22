# ReaperPluginManager

ReaperPluginManager keeps a group of REAPER users able to open each other's
projects. One maintainer keeps a catalogue of plugin installers on the group's
own server. When you open a project that uses plugins you do not have, the
manager lists them, installs what the catalogue offers once you agree, and
guides you through activating each plugin's licence with your own account.

## Installing

The manager needs REAPER 7 or later on Windows 10/11 or macOS; on any other
system it does nothing. Members and the maintainer install it the same way:

1. Download the release zip from the project's GitHub releases page.
2. Unpack it into the `Scripts` folder of REAPER's resource path (*Options >
   Show REAPER resource path in explorer/finder*), so the scripts sit in
   `Scripts/ReaperPluginManager/`.
3. Run Setup once: in REAPER's action list (*Actions > Show action list*),
   choose *New action > Load ReaScript...*, pick
   `Scripts/ReaperPluginManager/RPM_Setup.lua` and run it.

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
2. registers the manager's four actions: *Watcher*, *Check project*,
   *Catalogue management* and *Setup*;
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
run Setup again to test again.

### Turning automatic checks off

Run Setup and answer `no` to *Automatic check*, or set `auto = 0` in the
`[check]` section of `config.ini`. A running watcher stops within a second,
and from the next REAPER start the watcher exits at once; projects are then
checked only when you run *Check project*. The startup block stays in place.
To turn checks back on, run Setup and answer `yes`: the watcher starts at
once.

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
settings), the *ReaperPluginManager: Watcher* action checks every saved
project in the background each time it is opened, in a new tab or in place
of another project, about a second after it has loaded. Switching between
project tabs is not an opening and checks nothing; closing a project and
opening it again checks it again. Reloading a project in the tab it is
already in is not detected: run *Check project* instead. A project that has
never been saved is not checked. When the check finds nothing to list, no
window opens. While plugins are being installed, the projects you open are
checked once the install has ended. A check that fails writes the error to
the REAPER console and does not stop the watcher.

The *ReaperPluginManager: Check project* action checks the current project
on demand and always answers: the summary window, or a message — "All N
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
  however many instances the project holds.
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
  *Activate* button that opens the activation steps for that plugin; when
  they close, the summary comes back without the plugins you confirmed.

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

## Installing plugins

When you agree to install the plugins the summary offers, the manager
downloads and installs them in the background, so REAPER stays usable while
they install. One install runs at a time, and a failure stops only the plugin
it hit; the others go on.

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
licence activation for the installed plugins that need it.

### Restart and reopen

REAPER detects new plugins only when it starts. When at least one plugin was
installed, the manager asks you to restart REAPER. After the restart, the
project you were working on reopens on its own once REAPER has finished
starting, unless it is already open or its file is gone. If an installed
plugin still does not appear, rescan in REAPER:
*Preferences > Plug-ins > VST > Re-scan*.

## Settings

The settings live in `config.ini`, in the `ReaperPluginManager` folder of
REAPER's resource path (*Options > Show REAPER resource path in
explorer/finder*). The Setup action writes the server address, user, TLS
level and automatic check; set the other keys by editing the file, which keeps
every key and comment Setup does not change. A missing key, or a value the
manager does not accept, takes its default. Comments start with `;` or `#`.

| Section | Key | Values | Default |
| --- | --- | --- | --- |
| `[server]` | `url` | The server address, starting with its scheme, such as `ftps://example.com/plugins/`; a missing final `/` is added | empty |
| `[server]` | `user` | The server account's user name; empty connects anonymously | empty |
| `[server]` | `tls` | `required` (the connection must be encrypted), `try` (encrypted when the server offers it) or `off` | `required` |
| `[server]` | `insecure` | `1` accepts a server certificate that is not trusted, such as a self-signed one; `0` refuses it | `0` |
| `[install]` | `vst2_dir` | Windows only: the folder where VST2 `.dll` files unpacked from a zip installer are put | empty |
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
