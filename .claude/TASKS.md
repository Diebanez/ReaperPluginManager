# Tasks

Last task number: 40

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

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_Setup.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 7, 13, 18
Feature: setup-action

---

## 15. Update documentation for feature `setup-action`

Status: [MISSING]
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

Status: [MISSING]
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

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/helpers/rpm-secret.ps1, Scripts/ReaperPluginManager/helpers/rpm-secret.sh
Preconditions: 2, 30
Feature: licence-activation

---

## 32. Update documentation for feature `licence-activation`

Status: [MISSING]
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

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/RPM_CatalogueManager.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 3, 35
Feature: catalogue-publish

---

## 38. Update documentation for feature `catalogue-publish`

Status: [MISSING]
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
