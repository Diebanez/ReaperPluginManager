# Domain index

Product and rules knowledge for ReaperPluginManager. Read this first, then the
files relevant to your task.

This layer answers WHAT the product is and WHY it is built this way. For
CODEBASE STRUCTURE — which file implements what — see
[../context/INDEX.md](../context/INDEX.md) if the project has a context
layer.

## Files

| File | Covers |
| --- | --- |
| [design-process.md](./design-process.md) | State of the `/product-design` run: method, phases, current stage |
| [product-design.md](./product-design.md) | The product design: what ReaperPluginManager is, its users, key flows, design decisions and high-level features |
| [technical-direction.md](./technical-direction.md) | The product's technical foundations: stack, topology, data, hosting, protocols |
| [features/server-access.md](./features/server-access.md) | Settings file, server credentials in the OS secret store, and the shared `curl` transfer contract |
| [features/setup-action.md](./features/setup-action.md) | The setup action: dialog, validation, action registration, startup hook, connection test |
| [features/plugin-catalogue.md](./features/plugin-catalogue.md) | The catalogue schema and version, the Lua JSON codec, fetch with cached fallback, the match index |
| [features/plugin-detection.md](./features/plugin-detection.md) | Pure matching logic: project scan, normalization, installed-or-missing, catalogue association, classification |
| [features/project-watcher.md](./features/project-watcher.md) | Automatic check on every project open, the check action, the single summary window and install hand-off |

## Features

Low-level feature documents live under [features/](./features/), one per
feature, written by `/architect`. The feature index — status and generated
task IDs per feature — is [../FEATURES.md](../FEATURES.md).
