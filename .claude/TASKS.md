# Tasks

Last task number: 69

---

## 1. Settings file reader with defaults

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: none
Feature: server-access

---

## 2. Server credential store and short-lived credentials file

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/helpers/rpm-secret.ps1, Scripts/ReaperPluginManager/helpers/rpm-secret.sh
Preconditions: none
Feature: server-access

---

## 3. curl transfer layer

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 1, 2
Feature: server-access

---

## 4. Update documentation for feature `server-access`

Status: [DONE]
Target: claude
Files: README.md, server/README.md
Preconditions: 1, 2, 3
Feature: server-access

---

## 5. JSON parser and encoder in pure Lua

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: plugin-catalogue

---

## 6. Catalogue validation and match index

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua, server/manifest.example.json
Preconditions: 5, 10
Feature: plugin-catalogue

---

## 7. Catalogue fetch with cached fallback

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 3, 6
Feature: plugin-catalogue

---

## 8. Update documentation for feature `plugin-catalogue`

Status: [DONE]
Target: claude
Files: server/README.md, README.md
Preconditions: 5, 6, 7
Feature: plugin-catalogue

---

## 9. Project file scanner

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: plugin-detection

---

## 10. Name normalization, installed check and installed grouping

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: plugin-detection

---

## 11. Catalogue association and classification

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 6, 10
Feature: plugin-detection

---

## 12. Update documentation for feature `plugin-detection`

Status: [DONE]
Target: claude
Files: server/README.md, README.md
Preconditions: 9, 10, 11
Feature: plugin-detection

---

## 13. Setup dialog, validation and saving

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_Setup.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 1, 2
Feature: setup-action

---

## 14. Action registration, startup hook and connection test

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_Setup.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 7, 13, 18
Feature: setup-action

---

## 15. Update documentation for feature `setup-action`

Status: [DONE]
Target: claude
Files: README.md
Preconditions: 13, 14
Feature: setup-action

---

## 16. Project check assembly

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 7, 9, 11
Feature: project-watcher

---

## 17. Summary window and Check project action

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/RPM_CheckProject.lua
Preconditions: 16, 21, 29
Feature: project-watcher

---

## 18. Background watcher loop

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_Watcher.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 17
Feature: project-watcher

---

## 19. Update documentation for feature `project-watcher`

Status: [DONE]
Target: claude
Files: README.md
Preconditions: 16, 17, 18
Feature: project-watcher

---

## 20. Job file writer, URL encoding and status file reader

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: plugin-installation

---

## 21. Install run: launch, progress window, summary and reopen

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 3, 20, 30
Feature: plugin-installation

---

## 22. Update documentation for feature `plugin-installation`

Status: [DONE]
Target: claude
Files: README.md
Preconditions: 20, 21
Feature: plugin-installation

---

## 23. Windows helper core: elevation, download, verify, exe/msi

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/helpers/rpm-install.ps1
Preconditions: 20
Feature: install-helper-windows

---

## 24. Windows helper zip routing

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/helpers/rpm-install.ps1
Preconditions: 23
Feature: install-helper-windows

---

## 25. Update documentation for feature `install-helper-windows`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 23, 24
Feature: install-helper-windows

---

## 26. macOS helper core: download, verify, zip routing, quarantine

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/helpers/rpm-install.sh
Preconditions: 20
Feature: install-helper-macos

---

## 27. macOS helper dmg and single-password pkg phase

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/helpers/rpm-install.sh
Preconditions: 26
Feature: install-helper-macos

---

## 28. Update documentation for feature `install-helper-macos`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 26, 27
Feature: install-helper-macos

---

## 29. Activation field, pending record and pending query

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 6
Feature: licence-activation

---

## 30. Activation walk-through window and openers

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 29
Feature: licence-activation

---

## 31. Saved serials and clipboard copy

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/helpers/rpm-secret.ps1, Scripts/ReaperPluginManager/helpers/rpm-secret.sh
Preconditions: 2, 30
Feature: licence-activation

---

## 32. Update documentation for feature `licence-activation`

Status: [DONE]
Target: claude
Files: README.md, server/README.md
Preconditions: 29, 30, 31
Feature: licence-activation

---

## 33. Catalogue editor shell: ReaImGui guard, draft store, entry list

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_CatalogueManager.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 7
Feature: catalogue-editor

---

## 34. Add entries: from installed, by hand, from a draft file

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_CatalogueManager.lua, Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 10, 33
Feature: catalogue-editor

---

## 35. Entry form, checksums and removal

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_CatalogueManager.lua
Preconditions: 34
Feature: catalogue-editor

---

## 36. Update documentation for feature `catalogue-editor`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 33, 34, 35
Feature: catalogue-editor

---

## 37. Publish the catalogue draft

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_CatalogueManager.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 3, 35
Feature: catalogue-publish

---

## 38. Update documentation for feature `catalogue-publish`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 37
Feature: catalogue-publish

---

## 39. Catalogue assistant Claude Code skill

Status: [DONE]
Target: claude
Files: .claude/skills/catalogue-assistant/SKILL.md, .claude/skills/catalogue-assistant/fetch-installer.sh
Preconditions: 3, 6
Feature: catalogue-assistant

---

## 40. Update documentation for feature `catalogue-assistant`

Status: [DONE]
Target: claude
Files: CLAUDE.md
Preconditions: 39
Feature: catalogue-assistant

---

## 41. License the project under GPL-3.0

Status: [DONE]
Target: claude
Files: LICENSE, README.md
Preconditions: none

---

## 42. Package RPM for ReaPack with a tag-driven index

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_Setup.lua, Scripts/ReaperPluginManager/RPM_Watcher.lua, Scripts/ReaperPluginManager/RPM_CheckProject.lua, Scripts/ReaperPluginManager/RPM_CatalogueManager.lua, Scripts/ReaperPluginManager/rpm_core.lua, Scripts/ReaperPluginManager/rpm_reaper.lua, .reapack-index.conf, .github/workflows/
Preconditions: none

---

## 43. Document the ReaPack install and release

Status: [DONE]
Target: claude
Files: README.md, server/README.md, CLAUDE.md, .claude/domain/technical-direction.md, .claude/domain/features/catalogue-assistant.md, .claude/domain/design-process.md
Preconditions: 42

---

## 44. Script installer type and the unmanaged-installer check

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua, server/manifest.example.json
Preconditions: 6
Feature: plugin-catalogue

---

## 45. Update documentation for feature `plugin-catalogue`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 44
Feature: plugin-catalogue

---

## 46. Windows helper script installers

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/helpers/rpm-install.ps1
Preconditions: 24, 44
Feature: install-helper-windows

---

## 47. Update documentation for feature `install-helper-windows`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 46
Feature: install-helper-windows

---

## 48. macOS helper script installers run as the member

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/helpers/rpm-install.sh
Preconditions: 27, 44
Feature: install-helper-macos

---

## 49. Update documentation for feature `install-helper-macos`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 48
Feature: install-helper-macos

---

## 50. Unmanaged-installer mark and install warning

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 17, 44
Feature: project-watcher

---

## 51. Update documentation for feature `project-watcher`

Status: [DONE]
Target: claude
Files: README.md
Preconditions: 50
Feature: project-watcher

---

## 52. Script installers and the unmanaged mark in the editor

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_CatalogueManager.lua
Preconditions: 35, 44
Feature: catalogue-editor

---

## 53. Update documentation for feature `catalogue-editor`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 52, 44, 45, 46, 47, 48, 49
Feature: catalogue-editor

---

## 54. Shared presence detection and platform installer lookup

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: catalogue-browser

---

## 55. Cross-script install running state and start without reopen

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: none
Feature: catalogue-browser

---

## 56. Shared unmanaged confirmation and list primitives

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: none
Feature: catalogue-browser

---

## 57. Catalogue browser rows and search filter

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 54
Feature: catalogue-browser

---

## 58. Catalogue browser window and Browse action

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_Browse.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 55, 56, 57
Feature: catalogue-browser

---

## 59. Register the Browse action in Setup and the package

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/RPM_Setup.lua
Preconditions: 58
Feature: catalogue-browser

---

## 60. Update documentation for feature `catalogue-browser`

Status: [DONE]
Target: claude
Files: README.md, CLAUDE.md, .claude/domain/features/plugin-installation.md, .claude/domain/features/project-watcher.md, .claude/domain/features/plugin-detection.md, .claude/domain/features/plugin-catalogue.md, .claude/domain/features/setup-action.md, .claude/domain/technical-direction.md
Preconditions: 54, 55, 56, 57, 58, 59
Feature: catalogue-browser

---

## 61. Guided plugin scan after an install run

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: none
Feature: plugin-installation

---

## 62. Update documentation for feature `plugin-installation`

Status: [DONE]
Target: claude
Files: README.md, .claude/domain/features/plugin-installation.md, .claude/domain/features/catalogue-browser.md, CLAUDE.md
Preconditions: 61
Feature: plugin-installation

---

## 63. Restart helpers

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/helpers/rpm-restart.ps1, Scripts/ReaperPluginManager/helpers/rpm-restart.sh, Scripts/ReaperPluginManager/RPM_Setup.lua, CLAUDE.md
Preconditions: none
Feature: plugin-installation

---

## 64. Restart offer and reopening every open project

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 63
Feature: plugin-installation

---

## 65. Update documentation for feature `plugin-installation`

Status: [DONE]
Target: claude
Files: README.md, server/README.md, CLAUDE.md, .claude/domain/features/plugin-installation.md, .claude/domain/features/catalogue-browser.md
Preconditions: 63, 64
Feature: plugin-installation

---

## 66. Import draft attaches local installers named by `source`

Status: [DONE]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua, Scripts/ReaperPluginManager/RPM_CatalogueManager.lua
Preconditions: none
Feature: catalogue-editor

---

## 67. Update documentation for feature `catalogue-editor`

Status: [DONE]
Target: claude
Files: server/README.md
Preconditions: 66
Feature: catalogue-editor

---

## 68. Catalogue assistant takes local installers and drafts them as `source`

Status: [MISSING]
Target: claude
Files: .claude/skills/catalogue-assistant/SKILL.md, .claude/skills/catalogue-assistant/fetch-installer.sh
Preconditions: 66
Feature: catalogue-assistant

---

## 69. Update documentation for feature `catalogue-assistant`

Status: [MISSING]
Target: claude
Files: CLAUDE.md
Preconditions: 68
Feature: catalogue-assistant

---
