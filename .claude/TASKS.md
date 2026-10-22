# Tasks

Last task number: 19

---

## 1. Settings file reader with defaults

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua, Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: none
Feature: server-access

---

## 2. Server credential store and short-lived credentials file

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/helpers/rpm-secret.ps1, Scripts/ReaperPluginManager/helpers/rpm-secret.sh
Preconditions: none
Feature: server-access

---

## 3. curl transfer layer

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 1, 2
Feature: server-access

---

## 4. Update documentation for feature `server-access`

Status: [MISSING]
Target: claude
Files: README.md, server/README.md
Preconditions: 1, 2, 3
Feature: server-access

---

## 5. JSON parser and encoder in pure Lua

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: plugin-catalogue

---

## 6. Catalogue validation and match index

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua, server/manifest.example.json
Preconditions: 5, 10
Feature: plugin-catalogue

---

## 7. Catalogue fetch with cached fallback

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 3, 6
Feature: plugin-catalogue

---

## 8. Update documentation for feature `plugin-catalogue`

Status: [MISSING]
Target: claude
Files: server/README.md, README.md
Preconditions: 5, 6, 7
Feature: plugin-catalogue

---

## 9. Project file scanner

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: plugin-detection

---

## 10. Name normalization, installed check and installed grouping

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: none
Feature: plugin-detection

---

## 11. Catalogue association and classification

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_core.lua
Preconditions: 6, 10
Feature: plugin-detection

---

## 12. Update documentation for feature `plugin-detection`

Status: [MISSING]
Target: claude
Files: server/README.md, README.md
Preconditions: 9, 10, 11
Feature: plugin-detection

---

## 13. Setup dialog, validation and saving

Status: [MISSING]
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

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua
Preconditions: 7, 9, 11
Feature: project-watcher

---

## 17. Summary window and Check project action

Status: [MISSING]
Target: claude
Files: Scripts/ReaperPluginManager/rpm_reaper.lua, Scripts/ReaperPluginManager/RPM_CheckProject.lua
Preconditions: 16, 21, 29
Feature: project-watcher

---

## 18. Background watcher loop

Status: [MISSING]
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
