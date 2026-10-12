# ADR-009: Automated Passthrough & Configuration Rollback Strategy

**Status:** Accepted, amended 2026-10-09 (see Amendment).

## Context
Changes to Proxmox hypervisor configuration or guest GPU drivers risk breaking passthrough functionality.

## Decision
All host automation scripts must generate timestamped backups of `/etc/pve/qemu-server/`, `/etc/modules`, and boot parameters prior to modification, and provide single-command rollback scripts.

## Rationale
Guarantees rapid recovery to a known good hypervisor state if passthrough initialization fails.

## Amendment (2026-10-09)
The first implementation restored the *latest* backup with whole-file copies. After two applies that restores an intermediate state, and it clobbers unrelated VM edits. Revised mechanism:
- `configure-passthrough.sh --apply` writes a **manifest** before any mutation: added `hostpciN` keys and values, plus the sha256 of every host file as written.
- `rollback-passthrough.sh --backup-dir <dir>` (explicit, there is no "latest") deletes only those keys, restores host files only if they still match the recorded hash, and aborts with no changes on any drift.
- The kernel command line is not modified (it depends on the bootloader); preflight fails if the IOMMU is inactive.
- The stack-level counterpart is ADR-010.
