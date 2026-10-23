# Design process

The state of this project's `/product-design` run. `/product-design` reads
this file to decide where to resume; nothing else records that.

## Method

Top-down product design. The user and Claude work through the phases below
conversationally; each phase's output is written into product-design.md and
technical-direction.md before the next begins.

Greenfield or brownfield: brownfield in documentation — no code yet, but
`SPEC.md` specified the product; the phases confirmed and revised it.
Business modelling: out of scope — the product is released as open source,
with no revenue model.

## Phases

| Phase | What it does | State |
| --- | --- | --- |
| 0 — gate + resume | Verify the domain layer; resume or start fresh | done |
| 1 — orient + stub | Detect greenfield/brownfield, create the documents | done |
| 2 — interview | Product, users, experience, big decisions, business model | done |
| 3 — write-back | Fill product-design.md and business-model.md | done |
| 4 — high-level features | Identify the feature set, user-experience angle | done |
| 5 — feature write-back | Record the feature set in product-design.md | done |
| 6 — technical direction | Decide the product's technical foundations | done |
| 7 — technical write-back | Record the direction in technical-direction.md | done |

## Current stage

**PHASE 7 — technical write-back: done — process complete**

- product-design.md — the product, maintainer and member roles, four key
  flows, design decisions, seven high-level features.
- technical-direction.md — Lua in REAPER, PowerShell/bash helpers, `curl`,
  ReaImGui for the catalogue editor, ReaPack release, two open decisions.

Next: `/architect` for the catalogue browser, the one feature not yet
architected.

## Decisions worth keeping

- The domain documents supersede SPEC.md where they differ: catalogue upload,
  licence activation, English-only interface, catalogue management replacing
  the export flow, no automated tests, ReaPack release.
- Export-from-installed was replaced by catalogue management: it only drafted
  entries with no installers and could not add a second platform to an
  existing entry.
- Catalogue management runs inside REAPER: only there can the tool read how a
  plugin names itself in a project.
- Activation pending is a flag, not a block: the tool cannot check activation,
  only take the user's word for it.
- English-only interface, for the open-source audience.
- The catalogue assistant exists because silent-install switches and
  activation methods differ per vendor and must be researched per plugin; it
  stays personal for now.
- Helpers stay scripts rather than one compiled program: an unsigned binary
  that launches installers as administrator trips Gatekeeper and SmartScreen,
  and there is no signing budget.
- Members need ReaPack to install the manager; ReaImGui stays the
  maintainer's alone.
- The release is a ReaPack package of the scripts and helpers, indexed by
  this repository; the server setup material every group needs stays in the
  public repository's `server/` folder.
- The catalogue replace deletes before renaming where the rename will not
  overwrite: Windows-hosted FTP servers refuse it, and the brief absence is
  covered by members' cached catalogue.
