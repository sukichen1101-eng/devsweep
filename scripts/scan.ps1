<#
.SYNOPSIS
    devsweep - read-only disk scanner
.DESCRIPTION
    扫描指定盘/目录的占用大户:Top 目录 + 大文件。
    纯只读,不删除、不移动、不改名。输出 JSON 供 report.ps1 渲染。
    零硬编码路径:所有路径运行时探测。
.PARAMETER Root
    要扫描的根路径,如 "C:\" 或 "D:\dev"。默认系统盘。
.PARAMETER MinFileGB
    大文件阈值(GB)。默认 0.5。
.PARAMETER Top
    Top 目录/大文件各返回多少条。默认 30。
.PARAMETER OutFile
    JSON 输出路径。默认 $env:TEMP\devsweep\scan_<drive>_<timestamp>.json。
.EXAMPLE
    .\scan.ps1 -Root "C:\"
    .\scan.ps1 -Root "D:\dev" -MinFileGB 1 -Top 50
#>
[CmdletBinding()]
param(
    [string]$Root,
    [double]$MinFileGB = 0.5,
    [int]$Top = 30,
    [string]$OutFile
)

$ErrorActionPreference = "Stop"

# Root 未指定时用系统盘(探测 $env:SystemDrive,不写死 C:)
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = "$($env:SystemDrive)\"
}

try {
    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
} catch {
    Write-Error "Cannot resolve path: $Root"
    exit 1
}

$driveRoot = [System.IO.Path]::GetPathRoot($resolvedRoot)
$driveInfo = [System.IO.DriveInfo]::GetDrives() |
    Where-Object { $_.Name -eq $driveRoot } | Select-Object -First 1

# 永不进入的系统保护目录(只读扫描也跳过,省时间+避免噪音)
$skipDirNames = @(
    'System Volume Information', '$RECYCLE.BIN', '$Recycle.Bin',
    'Recovery', 'Config.Msi'
)

function ConvertTo-GB {
    param($Bytes)
    if ($null -eq $Bytes) { return 0 }
    return [math]::Round(([double]$Bytes / 1GB), 2)
}

# 计算单个目录总占用(只读,递归,忽略无权限项)
function Get-DirSize {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

Write-Host "[devsweep] Scanning: $resolvedRoot (read-only, nothing will be deleted)" -ForegroundColor Cyan

# 驱动器概况
$driveSummary = $null
if ($driveInfo) {
    $usedPct = 0
    if ($driveInfo.TotalSize -gt 0) {
        $usedPct = [math]::Round((1 - $driveInfo.AvailableFreeSpace / $driveInfo.TotalSize) * 100, 1)
    }
    $driveSummary = [pscustomobject]@{
        Name    = $driveInfo.Name
        Format  = $driveInfo.DriveFormat
        Type    = $driveInfo.DriveType.ToString()
        TotalGB = ConvertTo-GB $driveInfo.TotalSize
        FreeGB  = ConvertTo-GB $driveInfo.AvailableFreeSpace
        UsedPct = $usedPct
    }
}

# Top 目录(Root 下第一层,逐个算总大小)
Write-Host "[devsweep] Measuring top-level directories..." -ForegroundColor DarkGray
$topDirectories = Get-ChildItem -LiteralPath $resolvedRoot -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $skipDirNames -notcontains $_.Name } |
    ForEach-Object {
        $size = Get-DirSize $_.FullName
        [pscustomobject]@{
            SizeGB        = ConvertTo-GB $size
            Bytes         = $size
            LastWriteTime = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            FullName      = $_.FullName
        }
    } |
    Sort-Object Bytes -Descending |
    Select-Object -First $Top

# 大文件(全盘递归,>= 阈值)
Write-Host "[devsweep] Finding files >= $MinFileGB GB..." -ForegroundColor DarkGray
$minBytes = [long]($MinFileGB * 1GB)
$largeFiles = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -ge $minBytes } |
    Sort-Object Length -Descending |
    Select-Object -First $Top |
    ForEach-Object {
        [pscustomobject]@{
            SizeGB        = ConvertTo-GB $_.Length
            Bytes         = $_.Length
            Extension     = $_.Extension
            LastWriteTime = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            FullName      = $_.FullName
        }
    }

# 组装结果
$result = [pscustomobject]@{
    Tool        = "devsweep"
    Mode        = "read-only-scan"
    Root        = $resolvedRoot
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    MinFileGB   = $MinFileGB
    Top         = $Top
    Drive       = $driveSummary
    TopDirectories = @($topDirectories)
    LargeFiles     = @($largeFiles)
}

# 输出 JSON(默认 TEMP,运行时探测)
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $outDir = Join-Path $env:TEMP "devsweep"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $driveLetter = ($driveRoot -replace '[:\\]', '')
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $OutFile = Join-Path $outDir "scan_${driveLetter}_${stamp}.json"
}

$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutFile -Encoding utf8

Write-Host "[devsweep] Scan complete." -ForegroundColor Green
Write-Host "[devsweep] JSON written to: $OutFile" -ForegroundColor Green

# 路径回显到 stdout 末行,方便调用方捕获
Write-Output $OutFile
