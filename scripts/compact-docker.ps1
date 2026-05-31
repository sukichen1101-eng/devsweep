<#
.SYNOPSIS
    devsweep - Docker / WSL vhdx compactor (the killer feature)
.DESCRIPTION
    压缩 Docker Desktop / WSL2 的 vhdx 虚拟磁盘,回收"只增不减"的空间。
    这是现有同类 skill 全都没做对的部分。

    正确的压缩顺序(本脚本严格遵守):
      1. (可选) docker system prune  —— 先删无用镜像/容器/卷,让 vhdx 内部腾出空间
      2. wsl --shutdown              —— 必须先关停,否则 vhdx 被占用无法压缩
      3. Optimize-VHD (Hyper-V 模块) —— 首选,最干净
         若无 Hyper-V,回退到 diskpart 的 compact vdisk

    安全设计:
      - 默认 DryRun:只打印将执行的命令,不真正操作
      - 关停 WSL 会中断所有运行中的容器/WSL 会话,脚本会显式警告并要求 -Execute
      - 压缩是无损操作(只回收未使用块),不会损坏镜像或数据
      - 全程透明日志
.PARAMETER ScanJson
    scan-docker.ps1 输出的 JSON(用于确定要压缩哪些 vhdx)。
    不提供时,脚本会现场调用 scan-docker 逻辑重新探测。
.PARAMETER Execute
    真正执行。不加 = DryRun 预览命令。
.PARAMETER Prune
    压缩前先跑 docker system prune -f(回收更多空间,但会删未使用镜像)。
.PARAMETER VhdxPath
    只压缩指定的单个 vhdx。不提供则压缩 scan 找到的全部。
.PARAMETER LogFile
    操作日志路径。默认 $env:TEMP\devsweep\compact-docker_<timestamp>.json。
.EXAMPLE
    .\compact-docker.ps1 -ScanJson "...\docker_xxx.json"            # 预览
    .\compact-docker.ps1 -ScanJson "...\docker_xxx.json" -Execute   # 真压缩
    .\compact-docker.ps1 -Prune -Execute                            # 先 prune 再压缩全部
#>
[CmdletBinding()]
param(
    [string]$ScanJson,
    [switch]$Execute,
    [switch]$Prune,
    [string]$VhdxPath,
    [string]$LogFile
)

$ErrorActionPreference = "Stop"
$dryRun = -not $Execute

function ConvertTo-GB { param($Bytes); if ($null -eq $Bytes) { return 0 }; return [math]::Round([double]$Bytes/1GB,2) }

# ---- 确定要压缩的 vhdx 清单 ----
$vhdxList = @()
if ($VhdxPath) {
    if (-not (Test-Path -LiteralPath $VhdxPath)) {
        Write-Error "vhdx not found: $VhdxPath"; exit 1
    }
    $vhdxList = @($VhdxPath)
} elseif ($ScanJson -and (Test-Path -LiteralPath $ScanJson)) {
    $scan = Get-Content -LiteralPath $ScanJson -Raw | ConvertFrom-Json
    $vhdxList = @($scan.VhdxFiles | ForEach-Object { $_.FullName } | Where-Object { Test-Path -LiteralPath $_ })
} else {
    Write-Host "[devsweep] No scan JSON given; probing vhdx via registry..." -ForegroundColor DarkGray
    $lxss = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss"
    $found = New-Object System.Collections.Generic.List[string]
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.BasePath) {
            $bp = ($p.BasePath -replace '^\\\\\?\\','')
            $dir = Split-Path -Parent $bp
            if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = $bp }
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Recurse -Force -File -Filter '*.vhdx' -ErrorAction SilentlyContinue |
                    ForEach-Object { $found.Add($_.FullName) }
            }
        }
    }
    $vhdxList = @($found | Select-Object -Unique)
}

if ($vhdxList.Count -eq 0) {
    Write-Host "[devsweep] No vhdx files found to compact." -ForegroundColor Yellow
    exit 0
}

# 记录压缩前大小
$before = @{}
foreach ($v in $vhdxList) { $before[$v] = (Get-Item -LiteralPath $v -Force).Length }

$mode = if ($dryRun) { 'DRY-RUN (preview commands only)' } else { 'EXECUTE' }
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  devsweep compact-docker  |  Mode: $mode" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  vhdx to compact:" -ForegroundColor White
foreach ($v in $vhdxList) {
    Write-Host ("    {0,7} GB  {1}" -f (ConvertTo-GB $before[$v]), $v) -ForegroundColor Gray
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "  [PREVIEW] The following steps would run:" -ForegroundColor Yellow
    if ($Prune) { Write-Host "    1. docker system prune -f" -ForegroundColor Yellow }
    Write-Host "    2. wsl --shutdown   (WARNING: stops ALL containers & WSL sessions)" -ForegroundColor Yellow
    foreach ($v in $vhdxList) {
        Write-Host ("    3. Optimize-VHD -Path `"{0}`" -Mode Full   (fallback: diskpart compact vdisk)" -f $v) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  This was a PREVIEW. Re-run with -Execute to actually compact." -ForegroundColor Yellow
    Write-Host "  Note: compacting is lossless (reclaims empty blocks only)." -ForegroundColor DarkGray
    exit 0
}

# ===== 实际执行 =====
$steps = New-Object System.Collections.Generic.List[object]

function Add-Step { param([string]$Name,[bool]$Ok,[string]$Detail)
    $steps.Add([pscustomobject]@{ Step=$Name; Succeeded=$Ok; Detail=$Detail; Time=(Get-Date).ToString("HH:mm:ss") })
}

# 1. (可选) docker system prune
if ($Prune) {
    Write-Host ">>> docker system prune -f ..." -ForegroundColor Magenta
    $dockerCmd = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $dockerCmd) { $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue }
    if ($dockerCmd) {
        try {
            & docker system prune -f 2>&1 | Out-Host
            Add-Step 'docker-prune' $true 'pruned unused images/containers/networks'
        } catch {
            Add-Step 'docker-prune' $false $_.Exception.Message
            Write-Host "    prune failed (continuing): $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Add-Step 'docker-prune' $false 'docker CLI not found'
        Write-Host "    docker not found, skipping prune" -ForegroundColor Yellow
    }
}

# 2. wsl --shutdown (必须,否则 vhdx 被占用)
Write-Host ">>> wsl --shutdown  (stopping all WSL/containers)..." -ForegroundColor Magenta
try {
    & wsl.exe --shutdown 2>&1 | Out-Host
    Start-Sleep -Seconds 3   # 给 WSL 一点时间彻底释放句柄
    Add-Step 'wsl-shutdown' $true 'all distros stopped'
} catch {
    Add-Step 'wsl-shutdown' $false $_.Exception.Message
    Write-Host "    wsl --shutdown failed: $($_.Exception.Message)" -ForegroundColor Red
}

# 3. 逐个压缩
$hasOptimizeVhd = $null -ne (Get-Command Optimize-VHD -ErrorAction SilentlyContinue)

foreach ($v in $vhdxList) {
    Write-Host (">>> Compacting: {0}" -f $v) -ForegroundColor Magenta
    $ok = $false; $detail = ''
    if ($hasOptimizeVhd) {
        # 首选 Hyper-V 的 Optimize-VHD
        try {
            Optimize-VHD -Path $v -Mode Full -ErrorAction Stop
            $ok = $true; $detail = 'Optimize-VHD Full'
        } catch {
            $detail = "Optimize-VHD failed: $($_.Exception.Message)"
        }
    }
    if (-not $ok) {
        # 回退 diskpart compact vdisk
        try {
            $script = @"
select vdisk file="$v"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
            $tmp = Join-Path $env:TEMP ("devsweep_diskpart_{0}.txt" -f ([System.IO.Path]::GetRandomFileName()))
            $script | Out-File -FilePath $tmp -Encoding ascii
            & diskpart /s $tmp 2>&1 | Out-Host
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            $ok = $true
            $detail = if ($detail) { "$detail; diskpart fallback ok" } else { 'diskpart compact ok' }
        } catch {
            $detail = "$detail; diskpart failed: $($_.Exception.Message)"
        }
    }

    $afterSize = (Get-Item -LiteralPath $v -Force).Length
    $savedGB = ConvertTo-GB ($before[$v] - $afterSize)
    if ($ok) {
        Write-Host ("    OK  {0} GB -> {1} GB  (saved {2} GB)" -f (ConvertTo-GB $before[$v]), (ConvertTo-GB $afterSize), $savedGB) -ForegroundColor Green
    } else {
        Write-Host ("    FAILED: {0}" -f $detail) -ForegroundColor Red
    }
    Add-Step ("compact:" + (Split-Path $v -Leaf)) $ok ("{0}; before={1}GB after={2}GB saved={3}GB" -f $detail, (ConvertTo-GB $before[$v]), (ConvertTo-GB $afterSize), $savedGB)
}

# ---- 透明日志 ----
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $outDir = Join-Path $env:TEMP "devsweep"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $LogFile = Join-Path $outDir "compact-docker_${stamp}.json"
}
$totalSaved = 0L
foreach ($v in $vhdxList) { $totalSaved += ($before[$v] - (Get-Item -LiteralPath $v -Force).Length) }
$logResult = [pscustomobject]@{
    Tool        = "devsweep"
    Action      = "compact-docker"
    DryRun      = $false
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Pruned      = [bool]$Prune
    UsedOptimizeVhd = $hasOptimizeVhd
    TotalSavedGB = ConvertTo-GB $totalSaved
    Steps       = $steps.ToArray()
}
$logResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $LogFile -Encoding utf8

Write-Host "--------------------------------------------" -ForegroundColor Cyan
Write-Host ("  Total reclaimed: {0} GB" -f (ConvertTo-GB $totalSaved)) -ForegroundColor Cyan
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host "  Tip: Docker Desktop / WSL will restart automatically on next use." -ForegroundColor DarkGray
Write-Output $LogFile
exit 0
