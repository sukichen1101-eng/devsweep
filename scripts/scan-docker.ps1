<#
.SYNOPSIS
    devsweep - read-only Docker & WSL disk scanner
.DESCRIPTION
    盘点 Docker Desktop 的 vhdx 虚拟磁盘大小、WSL 各发行版占用。
    纯只读,只探测不操作。输出 JSON 供 report.ps1 / compact-docker.ps1 使用。
    这是 devsweep 最大的差异化点:vhdx 只增不减,是开发机最隐蔽的几十 GB 黑洞,
    现有同类 skill 要么完全不碰,要么只删无用的 .vhdx.tmp。
    本脚本同时给出 docker system df 的可回收量(若 docker 可用)。
.PARAMETER OutFile
    JSON 输出路径。默认 $env:TEMP\devsweep\docker_<timestamp>.json。
.EXAMPLE
    .\scan-docker.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$Deep
)

$ErrorActionPreference = "Stop"

function ConvertTo-GB { param($Bytes); if ($null -eq $Bytes) { return 0 }; return [math]::Round([double]$Bytes/1GB,2) }

Write-Host "[devsweep] Probing Docker / WSL disk usage (read-only)..." -ForegroundColor Cyan

# ---- 1. 查找所有 .vhdx 虚拟磁盘 ----
# 四管齐下定位,绝不猜单一路径:
#   (a) WSL 注册表 BasePath 的父目录 —— 每个发行版的权威位置(最可靠;搜父目录可
#       同时覆盖 Docker 的 main/ 和 disk/ 兄弟目录)
#   (b) Docker Desktop settings 的 dataFolder
#   (c) 候选目录兜底搜
#   (d) -Deep 时全盘扫所有固定盘(能抓到迁移/残留的旧 vhdx)
$vhdxFiles = New-Object System.Collections.Generic.List[object]
$seenPaths = New-Object System.Collections.Generic.HashSet[string]

function Add-Vhdx {
    param([System.IO.FileInfo]$File, [string]$Source)
    $key = $File.FullName.ToLowerInvariant()
    if ($seenPaths.Contains($key)) { return }
    [void]$seenPaths.Add($key)
    $script:vhdxFiles.Add([pscustomobject]@{
        SizeGB        = ConvertTo-GB $File.Length
        Bytes         = $File.Length
        Source        = $Source
        LastWriteTime = $File.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        FullName      = $File.FullName
    })
}

# (a) WSL 注册表 BasePath 的父目录 —— 每个发行版的确切位置
#     搜父目录:Docker Desktop 的 BasePath 是 ...\Data\main,而 vhdx 还可能在
#     兄弟目录 ...\Data\disk 里,搜父目录一次覆盖。
try {
    $lxss = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss"
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.BasePath) {
            $bp = $p.BasePath -replace '^\\\\\?\\',''   # 去掉 \\?\ 长路径前缀
            if (Test-Path -LiteralPath $bp) {
                $searchDir = Split-Path -Parent $bp   # 父目录,覆盖 main/ + disk/
                if (-not $searchDir -or -not (Test-Path -LiteralPath $searchDir)) { $searchDir = $bp }
                Get-ChildItem -LiteralPath $searchDir -Recurse -Force -File -Filter '*.vhdx' -ErrorAction SilentlyContinue |
                    ForEach-Object { Add-Vhdx -File $_ -Source "WSL:$($p.DistributionName)" }
            }
        }
    }
} catch {}

# (b) Docker Desktop settings 的 dataFolder
try {
    $dockerSettings = @(
        (Join-Path $env:APPDATA 'Docker\settings-store.json'),
        (Join-Path $env:APPDATA 'Docker\settings.json')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dockerSettings) {
        $s = Get-Content $dockerSettings -Raw | ConvertFrom-Json
        if ($s.dataFolder -and (Test-Path -LiteralPath $s.dataFolder)) {
            Get-ChildItem -LiteralPath $s.dataFolder -Recurse -Force -File -Filter '*.vhdx' -ErrorAction SilentlyContinue |
                ForEach-Object { Add-Vhdx -File $_ -Source "DockerSettings" }
        }
    }
} catch {}

# (c) 候选目录兜底(探测,不写死单一路径)
$vhdxSearchRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Docker'),
    (Join-Path $env:LOCALAPPDATA 'wsl'),
    (Join-Path $env:LOCALAPPDATA 'Packages'),
    (Join-Path $env:USERPROFILE  '.docker')
) | Where-Object { Test-Path $_ } | Select-Object -Unique
foreach ($r in $vhdxSearchRoots) {
    Get-ChildItem -LiteralPath $r -Recurse -Force -File -Filter '*.vhdx' -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Vhdx -File $_ -Source "Probe" }
}

# (d) -Deep:全盘扫所有固定盘,抓迁移/残留的旧 vhdx(慢,但最彻底)
if ($Deep) {
    Write-Host "[devsweep] -Deep: scanning all fixed drives for stray vhdx (slower)..." -ForegroundColor DarkGray
    [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.RootDirectory.FullName -Recurse -Force -File -Filter '*.vhdx' -ErrorAction SilentlyContinue |
                ForEach-Object { Add-Vhdx -File $_ -Source "Deep" }
        }
}

$vhdxSorted = @($vhdxFiles | Sort-Object Bytes -Descending)

# ---- 2. WSL 发行版列表(若 wsl 可用) ----
$wslDistros = @()
$wslAvailable = $false
$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($wslCmd) {
    $wslAvailable = $true
    try {
        # wsl -l -v 输出是 UTF-16,需要正确解码
        $prevEnc = [Console]::OutputEncoding
        $raw = & wsl.exe --list --verbose 2>$null
        $lines = $raw | Where-Object { $_ -and ($_ -replace '\x00','').Trim() -ne '' }
        $parsed = @()
        foreach ($ln in $lines) {
            $clean = ($ln -replace '\x00','').Trim()
            if ($clean -match '^\*?\s*(NAME)\s+(STATE)\s+(VERSION)') { continue }  # 表头
            $clean = $clean -replace '^\*',''
            $cols = ($clean -split '\s+') | Where-Object { $_ -ne '' }
            if ($cols.Count -ge 3) {
                $parsed += [pscustomobject]@{
                    Distro  = $cols[0]
                    State   = $cols[1]
                    Version = $cols[2]
                }
            }
        }
        $wslDistros = $parsed
    } catch {
        $wslDistros = @()
    }
}

# ---- 3. docker system df(若 docker 可用,给出可回收量)----
$dockerDf = $null
$dockerAvailable = $false
$dockerCmd = Get-Command docker.exe -ErrorAction SilentlyContinue
if (-not $dockerCmd) { $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue }
if ($dockerCmd) {
    try {
        $dfJsonLines = & docker system df --format '{{json .}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $dfJsonLines) {
            $dockerAvailable = $true
            $items = @()
            foreach ($jl in $dfJsonLines) {
                if ($jl.Trim() -ne '') {
                    try { $items += ($jl | ConvertFrom-Json) } catch {}
                }
            }
            $dockerDf = $items
        }
    } catch {
        $dockerAvailable = $false
    }
}

$totalVhdxBytes = ($vhdxSorted | Measure-Object -Property Bytes -Sum).Sum
if ($null -eq $totalVhdxBytes) { $totalVhdxBytes = 0 }

$result = [pscustomobject]@{
    Tool            = "devsweep"
    Mode            = "read-only-scan-docker"
    GeneratedAt     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    WslAvailable    = $wslAvailable
    DockerAvailable = $dockerAvailable
    TotalVhdxGB     = ConvertTo-GB $totalVhdxBytes
    VhdxFiles       = @($vhdxSorted)
    WslDistros      = @($wslDistros)
    DockerSystemDf  = $dockerDf
    Note            = "vhdx files only grow; reclaim with: wsl --shutdown then Optimize-VHD / diskpart compact. Run 'docker system prune' first to maximize reclaimable space."
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $outDir = Join-Path $env:TEMP "devsweep"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $OutFile = Join-Path $outDir "docker_${stamp}.json"
}

$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutFile -Encoding utf8

Write-Host "[devsweep] vhdx files: $($vhdxSorted.Count), total $(ConvertTo-GB $totalVhdxBytes) GB" -ForegroundColor Green
Write-Host "[devsweep] WSL available: $wslAvailable | Docker available: $dockerAvailable" -ForegroundColor Green
Write-Host "[devsweep] JSON written to: $OutFile" -ForegroundColor Green
Write-Output $OutFile

# 重置退出码:上面调用的 wsl.exe / docker 原生命令可能把 $LASTEXITCODE 置为非 0
# (如 Docker 守护进程未运行),但脚本本身已成功完成。
exit 0
