# devsweep

> Developer-focused Windows disk cleanup as a Claude Code / AI-agent skill.
> **Read-only first. Deletes only after you confirm. Honest about what it actually freed.**

Most disk cleaners chase temp files and browser caches — the small stuff. On a *developer's* machine the real space hogs are elsewhere, and they get ignored:

- 🐳 **Docker / WSL2 `vhdx` virtual disks** — these only grow, never shrink. Tens of GB hide here. devsweep compacts them properly (`wsl --shutdown` → `Optimize-VHD`/`diskpart compact`).
- 📦 **Stray build artifacts** — `node_modules`, `target`, `.next`, `dist`, `__pycache__`, `.venv`, `.gradle` scattered across old projects you forgot about.
- 🧹 **Caches & temp** — browser, npm/pip/yarn/pnpm, Windows temp, crash dumps.

## Why this exists

I looked at the existing disk-cleanup skills on GitHub. They share the same flaws:

| Problem in the wild | What devsweep does instead |
|---|---|
| Hardcoded paths — only run on the author's PC | **Zero hardcoded paths.** Everything probed at runtime (env vars, WSL registry, drive enumeration). |
| Silent `Remove-Item -Recurse -Force` — no record of what was deleted | **Transparent JSON log** for every run: what, how much *actually* freed, what was locked. |
| Report optimistic pre-delete sizes even when deletion failed | **Honest accounting** — counts only bytes that truly disappeared (before-minus-after diff). |
| Delete dangerous things (Maven local repo, all event logs, restore points) | **Strict never-touch list.** Maven `.m2` is a repo, not a cache. Event logs untouched. |
| Ignore the biggest hog: Docker vhdx (or only delete useless `.vhdx.tmp`) | **Compacts the real vhdx** — losslessly, the #1 differentiator. |
| 46 KB SKILL.md + 30 Python files — too heavy to adopt | **Thin SKILL.md dispatcher**, pure PowerShell, no dependencies. |

## Safety model

```
scan (read-only)  →  report  →  you confirm  →  clean (DryRun → -Execute)
```

- **Scanners are 100% read-only.** Run them anytime.
- **Cleaners default to DryRun** (preview). Nothing is deleted without an explicit `-Execute`.
- **vhdx is only compacted, never deleted** — compaction is lossless.
- Risk tiers (Low / Medium / High / Forbidden) in [`references/classification-rules.md`](references/classification-rules.md); never-touch list in [`references/safe-paths.md`](references/safe-paths.md).

## Install

### As a Claude Code skill (recommended)

```powershell
# User-level (all projects)
git clone https://github.com/<you>/devsweep "$env:USERPROFILE\.claude\skills\devsweep"
```

Restart Claude Code. The skill auto-triggers when you say things like:

- "my disk is full" / "free up space" / "clean my C drive"
- "Docker is huge, compact it" / "shrink my WSL vhdx"
- "find what's eating my disk" / "clean up old node_modules"
- 中文:「磁盘满了」「C盘不够用」「清理 Docker」「压缩 vhdx」「看看什么占了硬盘」

### Standalone (no agent, just PowerShell)

```powershell
# 1. See what's eating the disk (read-only)
.\scripts\scan.ps1 -Root "C:\"
.\scripts\scan-builds.ps1 -Root "D:\dev"
.\scripts\scan-docker.ps1 -Deep

# 2. Preview a cleanup
.\scripts\clean-safe.ps1

# 3. Execute after reviewing
.\scripts\clean-safe.ps1 -Execute
```

## The scripts

| Script | Read-only? | What it does |
|---|---|---|
| `scan.ps1` | ✅ | Top directories + large files on a drive → JSON |
| `scan-builds.ps1` | ✅ | Finds build artifacts (node_modules/target/.venv/…) → JSON |
| `scan-docker.ps1` | ✅ | Locates Docker/WSL vhdx + lists distros (`-Deep` = all drives) → JSON |
| `clean-safe.ps1` | DryRun default | Low-risk cache/temp cleanup, per-item, skips locked files |
| `clean-builds.ps1` | DryRun default | Deletes build artifacts from a scan JSON; Low-only unless `-IncludeMedium` |
| `compact-docker.ps1` | DryRun default | Compacts vhdx: optional prune → `wsl --shutdown` → `Optimize-VHD`/diskpart |

## Requirements

- Windows 10/11, PowerShell 5.1+ (built in)
- `compact-docker.ps1` and some system paths need an **elevated** PowerShell (Run as Administrator)
- `Optimize-VHD` comes from the Hyper-V module; without it, devsweep falls back to `diskpart compact vdisk` automatically

## Notes

- All scripts are UTF-8 **with BOM** and print English, so they run on any Windows locale (including Chinese GBK consoles) without garbled output.
- compact-docker stops all containers/WSL sessions to release the vhdx — they restart automatically on next use. No data loss.
- Closing your browser before `clean-safe -Execute` reclaims more (browsers lock their cache).

## License

MIT
