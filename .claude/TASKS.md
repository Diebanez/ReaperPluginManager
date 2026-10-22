# Tasks

Last task number: 4

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
