# devsweep

> Developer-focused Windows disk cleanup as a Claude Code / AI-agent skill.
> **Read-only first. Deletes only after you confirm. Honest about what it actually freed.**
>
> 面向开发者的 Windows 磁盘清理 skill（Claude Code / AI agent 技能）。
> **先只读扫描，确认后才删除，如实报告真正释放了多少空间。**

English | [中文](#中文说明)

---

Most disk cleaners chase temp files and browser caches — the small stuff. On a *developer's* machine the real space hogs are elsewhere, and they get ignored:

- 🐳 **Docker / WSL2 `vhdx` virtual disks** — these only grow, never shrink. Tens of GB hide here. devsweep compacts them properly (`wsl --shutdown` → `Optimize-VHD`/`diskpart compact`).
- 📦 **Stray build artifacts** — `node_modules`, `target`, `.next`, `dist`, `__pycache__`, `.venv`, `.gradle` scattered across old projects you forgot about.
- 🧹 **Caches & temp** — browser, npm/pip/yarn/pnpm, Windows temp, crash dumps.

## Demo

A typical session: scan first (read-only), then clean only what you approve.

```console
$ scan-docker.ps1 -Deep
[devsweep] Probing Docker / WSL disk usage (read-only)...
[devsweep] -Deep: scanning all fixed drives for stray vhdx (slower)...
[devsweep] vhdx files: 3, total 27.29 GB
[devsweep] WSL available: True | Docker available: False

  15.12 GB  <user>\AppData\Local\wsl\{...}\ext4.vhdx          [WSL:Ubuntu, active]
   8.12 GB  D:\old-docker-data\...\docker_data.vhdx           [orphan, 83 days untouched]
   3.85 GB  D:\Docker\Data\disk\docker_data.vhdx              [docker-desktop, active]

$ clean-safe.ps1                 # preview — nothing deleted
  [Browser] Edge Cache                375.9 MB  (preview)
  [Temp   ] User Temp                   128 MB  (preview)
  Would free: 849.6 MB across 5 items
  This was a PREVIEW. Re-run with -Execute to actually clean.

$ clean-safe.ps1 -Execute        # after you confirm
  [Browser] Edge Cache             375.9 MB  freed
  [Temp   ] User Temp              partial — some files in use
  Freed: 504.2 MB across 5 items   # only what ACTUALLY disappeared
```

> 💡 Want an animated demo? Record one and drop it here:
> `![demo](docs/demo.gif)`

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
git clone https://github.com/sukichen1101-eng/devsweep "$env:USERPROFILE\.claude\skills\devsweep"
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
.\scripts\scan-builds.ps1 -Root "D:\projects"
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
- `Optimize-VHD` comes from the Hyper-V module (not on Windows Home); without it, devsweep falls back to `diskpart compact vdisk` automatically — which itself needs admin. On Windows Home without admin, compaction can't run; reclaim space elsewhere instead.

## Notes

- All scripts are UTF-8 **with BOM** and print English, so they run on any Windows locale (including Chinese GBK consoles) without garbled output.
- compact-docker stops all containers/WSL sessions to release the vhdx — they restart automatically on next use. No data loss.
- Closing your browser before `clean-safe -Execute` reclaims more (browsers lock their cache).

---

## 中文说明

[English](#devsweep) | 中文

大多数磁盘清理工具只盯着临时文件、浏览器缓存这些**小钱**。但在**开发者**的电脑上，真正吃空间的大头在别处，而且总被忽略：

- 🐳 **Docker / WSL2 的 `vhdx` 虚拟磁盘** —— 只涨不缩，几十 GB 藏在里面。devsweep 用正确方式压缩它（`wsl --shutdown` → `Optimize-VHD`/`diskpart compact`）。
- 📦 **散落各处的构建产物** —— 旧项目里的 `node_modules`、`target`、`.next`、`dist`、`__pycache__`、`.venv`、`.gradle`。
- 🧹 **缓存与临时文件** —— 浏览器、npm/pip/yarn/pnpm、Windows 临时目录、崩溃转储。

### 核心理念

```
扫描（只读） → 报告 → 你确认 → 清理（先预览，再 -Execute）
```

- **扫描脚本 100% 只读**，随时可跑，不会动任何东西。
- **清理脚本默认只预览（DryRun）**，不加 `-Execute` 绝不删除。
- **vhdx 只压缩、永不删除** —— 压缩是无损操作。
- **诚实统计**：只计算真正消失的字节（删除前后差值），绝不虚报。
- **严格的永不触碰清单**：不删 Maven 本地仓库本体、不清空 Windows 事件日志、不碰系统还原点。

### 比现有同类工具强在哪

| 别人的通病 | devsweep 的做法 |
|---|---|
| 写死作者电脑的路径，换台机器就废 | **零硬编码路径**，全部运行时探测（环境变量、WSL 注册表、盘符枚举） |
| 闷头 `Remove-Item -Force`，删了什么没记录 | **每次都写透明 JSON 日志**：删了什么、实际释放多少、哪些被锁 |
| 删失败了还谎报释放量 | **诚实统计**，只认真正消失的字节 |
| 误删危险目标（Maven 仓库、全部事件日志） | **严格白名单**，Maven `.m2` 是仓库不是缓存，绝不碰 |
| 忽略最大的 Docker vhdx | **真正压缩 vhdx**，无损，核心差异化 |
| SKILL.md 46KB + 30 个文件，太重没人装 | **薄 SKILL.md + 纯 PowerShell 无依赖** |

### 安装（作为 Claude Code skill）

```powershell
git clone https://github.com/sukichen1101-eng/devsweep "$env:USERPROFILE\.claude\skills\devsweep"
```

重启 Claude Code 后，说「磁盘满了」「清理 Docker」「压缩 vhdx」「看看什么占了硬盘」就会自动触发。

### 环境要求

- Windows 10/11，PowerShell 5.1+（系统自带）
- `compact-docker.ps1` 需要**管理员** PowerShell
- `Optimize-VHD` 来自 Hyper-V 模块（家庭版没有）；没有时自动回退到 `diskpart compact`，但它同样要管理员权限。家庭版 + 非管理员时压缩跑不动，请改用其他方式回收空间。

## License

MIT
