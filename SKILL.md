---
name: devsweep
description: "Developer-focused Windows disk cleanup. Finds and reclaims the big space hogs on a dev machine — Docker/WSL2 vhdx virtual disks (which only grow, never shrink), stray build artifacts (node_modules, target, .next, __pycache__, .venv), browser/package-manager caches, and temp files. Read-only by default: scans and reports first, deletes only after you confirm. Use when the user asks to: free disk space, clean C drive, my disk is full, reclaim space, shrink Docker, compact WSL vhdx, find what's eating my disk, clean node_modules, disk cleanup. Chinese triggers: 磁盘满了, C盘满了, 清理磁盘, 释放空间, 磁盘不够用, 清理 Docker, 压缩 vhdx, 清 node_modules, 看看什么占了硬盘. Windows / PowerShell only."
---

# devsweep

Developer-focused Windows disk cleanup. **Read-only first, delete only on confirmation.**

This skill reclaims the space that actually piles up on a developer's machine — and that generic cleaners miss:

- **Docker / WSL2 `vhdx` virtual disks** — these grow but never shrink on their own; the #1 hidden hog (tens of GB). devsweep compacts them properly.
- **Stray build artifacts** — `node_modules`, `target`, `.next`, `dist`, `__pycache__`, `.venv`, `.gradle` scattered across old projects.
- **Caches & temp** — browser caches, npm/pip/yarn/pnpm caches, Windows temp, crash dumps.

## Core principle: scan → report → confirm → clean

NEVER delete without showing the user what will be deleted first. The scan scripts are read-only and safe to run anytime. The clean scripts default to **DryRun** (preview) and require an explicit `-Execute` flag to actually delete.

## Workflow

### 1. Assess — what's eating the disk? (read-only, always safe)

Run the scanners that fit the user's situation. They write JSON to `$env:TEMP\devsweep\` and print a summary. All are pure read-only.

```powershell
# Overall: top directories + large files on a drive
& "<skill>\scripts\scan.ps1" -Root "C:\"

# Build artifacts across dev folders (the developer black holes)
& "<skill>\scripts\scan-builds.ps1" -Root "D:\dev"

# Docker / WSL vhdx + WSL distros (use -Deep to scan all fixed drives for stray vhdx)
& "<skill>\scripts\scan-docker.ps1" -Deep
```

Pick based on the ask:
- "disk is full" / "what's eating my disk" → run all three, lead with the biggest finding.
- "clean node_modules" / "build artifacts" → `scan-builds.ps1`.
- "Docker is huge" / "compact WSL" → `scan-docker.ps1 -Deep`.

### 2. Report — summarize findings to the user

Read the JSON output and present it plainly: biggest hogs first, total reclaimable, and which category (vhdx / builds / cache). Call out the high-value targets (a 15 GB vhdx beats clearing 300 MB of cache). Be honest about what's safe vs. what needs a closer look.

### 3. Confirm — get explicit sign-off before deleting

State exactly what will be deleted, how much it frees, and whether it's reversible (caches/builds rebuild automatically; vhdx compaction is lossless). Wait for the user to say go. For build artifacts, default to **Low-risk only** unless the user opts into Medium.

### 4. Clean — preview, then execute

Always run DryRun first, show it, then re-run with `-Execute` after confirmation.

```powershell
# Safe caches (browser/npm/pip/temp). Preview then execute.
& "<skill>\scripts\clean-safe.ps1"            # preview
& "<skill>\scripts\clean-safe.ps1" -Execute   # after user confirms

# Build artifacts, driven by the scan-builds JSON. Low-risk by default.
& "<skill>\scripts\clean-builds.ps1" -ScanJson "<builds.json>"                       # preview, Low only
& "<skill>\scripts\clean-builds.ps1" -ScanJson "<builds.json>" -Execute              # delete Low
& "<skill>\scripts\clean-builds.ps1" -ScanJson "<builds.json>" -IncludeMedium -Execute  # +Medium

# Compact Docker/WSL vhdx — the killer feature. Stops WSL, so warn first.
& "<skill>\scripts\compact-docker.ps1" -ScanJson "<docker.json>"            # preview the steps
& "<skill>\scripts\compact-docker.ps1" -ScanJson "<docker.json>" -Execute   # after confirm
& "<skill>\scripts\compact-docker.ps1" -Prune -Execute                      # prune images first, then compact all
```

Every clean script writes a transparent JSON log (what was deleted, how much actually freed, any locked/failed items). Surface the real freed total — never the optimistic pre-delete estimate.

## Important behaviors & gotchas

- **compact-docker stops ALL containers and WSL sessions** (`wsl --shutdown` is required to release the vhdx). Warn the user before `-Execute`. Docker/WSL restart automatically on next use; data is not lost.
- **compact-docker prerequisites — check BEFORE running it.** Compaction needs EITHER `Optimize-VHD` (Hyper-V module, NOT present on Windows Home editions) OR an elevated PowerShell for the `diskpart` fallback. So on Windows Home without admin rights, compaction cannot proceed and would only stop WSL for nothing. Before suggesting compact-docker, verify: (1) `Get-Command Optimize-VHD` exists, OR the session is elevated; (2) nothing critical runs inside the target WSL distro (a service the user depends on). If neither compaction path is available, do NOT run it — tell the user it needs Hyper-V or an admin PowerShell, and fall back to reclaiming space elsewhere (orphaned/stale vhdx removal, build artifacts, caches).
- **Browsers lock their cache.** clean-safe deletes what it can and honestly reports the rest as locked. Closing browsers reclaims more — mention it.
- **Admin rights**: compact-docker's `Optimize-VHD` / `diskpart` and some system paths need an elevated PowerShell. If a step fails with access-denied, tell the user to run as Administrator.
- **Encoding**: all scripts are UTF-8 with BOM and print English, so they run cleanly on any Windows locale (including Chinese GBK consoles).

## What devsweep NEVER does (safety guarantees)

Read `references/safe-paths.md` for the full never-touch list and `references/classification-rules.md` for the risk tiers. In short:

- Never deletes source code, user documents, configs, or `.git`.
- Never deletes the Maven local repo body (`~/.m2/repository`) — it's not a cache.
- Never clears all Windows Event Logs, never touches WinSxS / restore points / `$PatchCache$` / `pagefile.sys`.
- Never deletes a vhdx — only compacts it (lossless).

## Resources

- `scripts/scan.ps1` — read-only: top dirs + large files on a drive
- `scripts/scan-builds.ps1` — read-only: build artifacts (node_modules/target/etc.)
- `scripts/scan-docker.ps1` — read-only: Docker/WSL vhdx + distros (`-Deep` for full-drive)
- `scripts/clean-safe.ps1` — low-risk cache/temp cleaner (DryRun unless `-Execute`)
- `scripts/clean-builds.ps1` — build-artifact cleaner driven by scan JSON (DryRun unless `-Execute`)
- `scripts/compact-docker.ps1` — Docker/WSL vhdx compactor (DryRun unless `-Execute`)
- `references/classification-rules.md` — risk tiers (Low/Medium/High/Forbidden)
- `references/safe-paths.md` — never-touch path list
