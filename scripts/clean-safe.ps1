<#
.SYNOPSIS
    devsweep - safe cache cleaner (low-risk only)
.DESCRIPTION
    只清理"删了会自动重建"的低风险缓存:各浏览器缓存、包管理器缓存
    (npm/pip/yarn/pnpm)、各类临时目录、缩略图缓存、崩溃转储等。
    安全设计:
      - 默认 DryRun(只预览不删除),必须显式 -Execute 才真删
      - 永不删除任何用户数据、源码、配置、Maven 本地仓库本体
      - 不清空 Windows 事件日志,不碰 WinSxS/还原点/PatchCache(这些是竞品的雷)
      - 每一项操作写入透明日志(JSON),删了什么、多大、何时,全程可追溯
.PARAMETER Execute
    真正执行删除。不加此参数 = DryRun 预览。
.PARAMETER SkipDev
    跳过开发者缓存模块(npm/pip 等),只清浏览器和系统临时文件。
.PARAMETER LogFile
    操作日志 JSON 路径。默认 $env:TEMP\devsweep\clean-safe_<timestamp>.json。
.EXAMPLE
    .\clean-safe.ps1            # 预览(默认安全)
    .\clean-safe.ps1 -Execute   # 实际清理
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$SkipDev,
    [string]$LogFile
)

$ErrorActionPreference = "Stop"
$dryRun = -not $Execute

function ConvertTo-MB { param($Bytes); if ($null -eq $Bytes) { return 0 }; return [math]::Round([double]$Bytes/1MB,1) }

# 计算目录/通配占用(只读)
function Get-PathSize {
    param([string]$Path)
    $sum = (Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

# ---- 清理目标:全部是"删了自动重建"的低风险缓存 ----
# 注意:这里只放安全项。Maven .m2\repository 是本地仓库本体,绝不列入(竞品的错误)。
$browserTargets = @(
    @{ Label = 'Edge Cache';        Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache" },
    @{ Label = 'Edge Code Cache';   Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache" },
    @{ Label = 'Chrome Cache';      Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache" },
    @{ Label = 'Chrome Code Cache'; Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache" },
    @{ Label = 'Firefox Cache';     Path = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles" }
)
$tempTargets = @(
    @{ Label = 'User Temp';      Path = "$env:TEMP" },
    @{ Label = 'LocalApp Temp';  Path = "$env:LOCALAPPDATA\Temp" },
    @{ Label = 'Thumbnail Cache';Path = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" ; FilePattern = 'thumbcache_*.db' },
    @{ Label = 'Crash Dumps';    Path = "$env:LOCALAPPDATA\CrashDumps" }
)
$devTargets = @(
    @{ Label = 'pip cache';   Path = "$env:LOCALAPPDATA\pip\cache" },
    @{ Label = 'npm cache';   Path = "$env:APPDATA\npm-cache" },
    @{ Label = 'yarn cache';  Path = "$env:LOCALAPPDATA\Yarn\Cache" },
    @{ Label = 'pnpm store';  Path = "$env:LOCALAPPDATA\pnpm-cache" },
    @{ Label = 'VSCode CachedData'; Path = "$env:APPDATA\Code\CachedData" },
    @{ Label = 'NuGet http-cache';  Path = "$env:LOCALAPPDATA\NuGet\v3-cache" }
)

$targets = @()
$targets += $browserTargets | ForEach-Object { $_ + @{ Module = 'Browser' } }
$targets += $tempTargets    | ForEach-Object { $_ + @{ Module = 'Temp' } }
if (-not $SkipDev) {
    $targets += $devTargets | ForEach-Object { $_ + @{ Module = 'Dev' } }
}

# 去重:某些机器上 $env:TEMP 与 $env:LOCALAPPDATA\Temp 是同一路径,会造成重复目标。
# 按 (规范化路径 + FilePattern) 去重,避免对同一目录重复清理 / 重复计数。
$seenTargets = New-Object System.Collections.Generic.HashSet[string]
$targets = @($targets | Where-Object {
    $norm = $_.Path.TrimEnd('\').ToLowerInvariant()
    if ($_.ContainsKey('FilePattern')) { $norm += '|' + $_.FilePattern }
    $seenTargets.Add($norm)   # Add 返回 false 表示已存在 -> 过滤掉
})

$mode = if ($dryRun) { 'DRY-RUN (preview only)' } else { 'EXECUTE (deleting)' }
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  devsweep clean-safe  |  Mode: $mode" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$log = New-Object System.Collections.Generic.List[object]
$totalBytes = 0L

# 浏览器开着时缓存文件被锁,删不干净。检测一下,提示用户(只在真删时提示)。
if (-not $dryRun) {
    $runningBrowsers = @('msedge','chrome','firefox') |
        ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue } |
        Select-Object -ExpandProperty ProcessName -Unique
    if ($runningBrowsers) {
        Write-Host ("  NOTE: {0} running — their cache is partly locked. Close them to reclaim more." -f ($runningBrowsers -join ', ')) -ForegroundColor Yellow
    }
}

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.Path)) { continue }

    # 有 FilePattern 的只针对匹配文件,否则清目录内容
    if ($t.ContainsKey('FilePattern')) {
        $items = Get-ChildItem -LiteralPath $t.Path -Filter $t.FilePattern -Force -File -ErrorAction SilentlyContinue
        $size = ($items | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $size) { $size = 0 }
    } else {
        $size = Get-PathSize $t.Path
    }
    if ($size -le 0) { continue }

    $entry = [pscustomobject]@{
        Module     = $t.Module
        Label      = $t.Label
        Path       = $t.Path
        SizeMB     = ConvertTo-MB $size
        Bytes      = $size
        FreedBytes = 0
        Action     = if ($dryRun) { 'would-delete' } else { 'deleted' }
        Succeeded  = $true
        Error      = $null
        Time       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    if ($dryRun) {
        Write-Host ("  [{0,-7}] {1,-22} {2,8} MB  (preview)" -f $t.Module, $t.Label, (ConvertTo-MB $size)) -ForegroundColor Yellow
        $entry.FreedBytes = 0
        $totalBytes += $size   # 预览模式:统计"可释放"潜力
    } else {
        # 逐项删除并跳过被占用的文件:遇到一个锁定文件不应中断整个目录的清理。
        # (Remove-Item -Recurse 遇到单个锁定项会抛错,导致同目录其他可删项也漏删。)
        if ($t.ContainsKey('FilePattern')) {
            Get-ChildItem -LiteralPath $t.Path -Filter $t.FilePattern -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
                    catch { $entry.Error = $_.Exception.Message }
                }
        } else {
            # 删目录内容而非目录本身(保留缓存目录结构,程序下次照常用)
            Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
                    catch { $entry.Error = $_.Exception.Message }
                }
        }

        # 诚实统计:实际释放 = 删除前大小 - 删除后剩余大小(只认真正消失的字节)
        if ($t.ContainsKey('FilePattern')) {
            $remain = (Get-ChildItem -LiteralPath $t.Path -Filter $t.FilePattern -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        } else {
            $remain = Get-PathSize $t.Path
        }
        if ($null -eq $remain) { $remain = 0 }
        $freed = [long]$size - [long]$remain
        if ($freed -lt 0) { $freed = 0 }
        $entry.FreedBytes = $freed
        $entry.Bytes      = $freed   # Bytes 字段也只记实际释放量,不记删除前的虚高值

        if ($entry.Error -and $freed -le 0) {
            # 完全没删掉(全程被锁)
            $entry.Succeeded = $false
            $entry.Action = 'failed-locked'
            Write-Host ("  [{0,-7}] {1,-22} LOCKED, 0 freed: {2}" -f $t.Module, $t.Label, $entry.Error) -ForegroundColor Red
        } elseif ($entry.Error) {
            # 删掉一部分,还剩一些被锁
            $entry.Succeeded = $true
            $entry.Action = 'partial'
            Write-Host ("  [{0,-7}] {1,-22} {2,8} MB  freed (partial, some files in use)" -f $t.Module, $t.Label, (ConvertTo-MB $freed)) -ForegroundColor Yellow
        } else {
            Write-Host ("  [{0,-7}] {1,-22} {2,8} MB  freed" -f $t.Module, $t.Label, (ConvertTo-MB $freed)) -ForegroundColor Green
        }
        $totalBytes += $freed
    }
    $log.Add($entry)
}

# ---- 写透明日志 ----
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $outDir = Join-Path $env:TEMP "devsweep"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $LogFile = Join-Path $outDir "clean-safe_${stamp}.json"
}
$logResult = [pscustomobject]@{
    Tool      = "devsweep"
    Action    = "clean-safe"
    DryRun    = $dryRun
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalMB   = ConvertTo-MB $totalBytes
    ItemCount = $log.Count
    Items     = $log.ToArray()
}
$logResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $LogFile -Encoding utf8

Write-Host "--------------------------------------------" -ForegroundColor Cyan
$verb = if ($dryRun) { 'Would free' } else { 'Freed' }
Write-Host ("  {0}: {1} MB across {2} items" -f $verb, (ConvertTo-MB $totalBytes), $log.Count) -ForegroundColor Cyan
if ($dryRun) {
    Write-Host "  This was a PREVIEW. Re-run with -Execute to actually clean." -ForegroundColor Yellow
}
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Output $LogFile
