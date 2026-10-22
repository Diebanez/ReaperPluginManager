# ReaperPluginManager

ReaperPluginManager keeps a group of REAPER users able to open each other's
projects. One maintainer keeps a catalogue of plugin installers on the group's
own server. When you open a project that uses plugins you do not have, the
manager lists them, installs what the catalogue offers once you agree, and
guides you through activating each plugin's licence with your own account.

## The project summary

When a project uses plugins that are not installed on your machine, one
summary window lists all of them. A plugin counts as installed when REAPER
lists the same plugin file or id, or a plugin of the same format and name, so
a project saved on another platform is recognised too. Every plugin the
project uses is checked, wherever it sits: track and master effects, take
effects and containers.

The missing plugins are sorted into groups:

- **To install** — the catalogue has an installer for your platform. Each
  plugin is listed once, with the maintainer's note, however many instances
  the project holds.
- **No installer for this platform** — the catalogue knows the plugin, but
  has no installer for your platform.
- **Not in the catalogue** — no catalogue entry matches the plugin, listed
  with its format and number of instances. Ask the maintainer to add it. This
  group can be switched off in the settings.
- **Replace by hand** — instances that will stay offline even after
  installing, because their format cannot be loaded here. See below.
- **Activation pending** — installed plugins whose licence activation you
  skipped; they stay listed until you confirm the activation.

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
