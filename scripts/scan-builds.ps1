<#
.SYNOPSIS
    devsweep - read-only build-artifact scanner
.DESCRIPTION
    扫描开发者磁盘黑洞:node_modules / target / .next / dist / build /
    __pycache__ / .gradle / .venv 等构建产物与依赖目录。
    纯只读,只统计不删除。输出 JSON 供 report.ps1 / clean-builds.ps1 使用。
    这是 devsweep 的差异化点:现有同类 skill 都不扫这些。
.PARAMETER Root
    要扫描的根路径,如 "D:\dev"。默认当前用户目录(探测,不写死)。
.PARAMETER MinMB
    只列出 >= 该大小(MB)的产物目录。默认 50。
.PARAMETER MaxDepth
    递归最大深度,防止在超深目录树里卡死。默认 8。
.PARAMETER OutFile
    JSON 输出路径。默认 $env:TEMP\devsweep\builds_<timestamp>.json。
.EXAMPLE
    .\scan-builds.ps1 -Root "D:\dev"
    .\scan-builds.ps1 -Root "D:\" -MinMB 100
#>
[CmdletBinding()]
param(
    [string]$Root,
    [double]$MinMB = 50,
    [int]$MaxDepth = 8,
    [string]$OutFile
)

$ErrorActionPreference = "Stop"

# Root 未指定时用当前用户目录(探测 $env:USERPROFILE,不写死路径)
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $env:USERPROFILE
}

try {
    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
} catch {
    Write-Error "Cannot resolve path: $Root"
    exit 1
}

# 已知的构建产物 / 依赖目录名 -> 生态 + 风险等级 + 重建方式
# 风险等级:Low = 删了自动重建/重下;Medium = 重建较慢但安全
$buildDirSpecs = @(
    @{ Name = 'node_modules';  Eco = 'Node.js';    Risk = 'Low';    Rebuild = 'npm/pnpm/yarn install' },
    @{ Name = 'target';        Eco = 'Rust/Maven'; Risk = 'Low';    Rebuild = 'cargo build / mvn package' },
    @{ Name = '.next';         Eco = 'Next.js';    Risk = 'Low';    Rebuild = 'next build' },
    @{ Name = 'dist';          Eco = 'JS/Python';  Risk = 'Medium'; Rebuild = 'rebuild from source' },
    @{ Name = 'build';         Eco = 'Generic';    Risk = 'Medium'; Rebuild = 'rebuild from source' },
    @{ Name = '__pycache__';   Eco = 'Python';     Risk = 'Low';    Rebuild = 'auto-regenerated' },
    @{ Name = '.pytest_cache'; Eco = 'Python';     Risk = 'Low';    Rebuild = 'auto-regenerated' },
    @{ Name = '.gradle';       Eco = 'Gradle';     Risk = 'Low';    Rebuild = 'gradle re-downloads' },
    @{ Name = '.venv';         Eco = 'Python';     Risk = 'Medium'; Rebuild = 'recreate venv + pip install' },
    @{ Name = 'venv';          Eco = 'Python';     Risk = 'Medium'; Rebuild = 'recreate venv + pip install' },
    @{ Name = '.turbo';        Eco = 'Turborepo';  Risk = 'Low';    Rebuild = 'auto-regenerated' },
    @{ Name = 'out';           Eco = 'Next/JS';    Risk = 'Medium'; Rebuild = 'rebuild from source' },
    @{ Name = '.angular';      Eco = 'Angular';    Risk = 'Low';    Rebuild = 'auto-regenerated' },
    @{ Name = 'obj';           Eco = '.NET';       Risk = 'Low';    Rebuild = 'dotnet build' },
    @{ Name = 'bin';           Eco = '.NET';       Risk = 'Medium'; Rebuild = 'dotnet build' }
)
$targetNames = $buildDirSpecs | ForEach-Object { $_.Name }
$specByName = @{}
foreach ($s in $buildDirSpecs) { $specByName[$s.Name] = $s }

function ConvertTo-GB { param($Bytes); if ($null -eq $Bytes) { return 0 }; return [math]::Round([double]$Bytes/1GB,2) }
function Get-DirSize {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

Write-Host "[devsweep] Scanning build artifacts under: $resolvedRoot (read-only)" -ForegroundColor Cyan
Write-Host "[devsweep] Looking for: $($targetNames -join ', ')" -ForegroundColor DarkGray

$rootDepth = ($resolvedRoot.TrimEnd('\') -split '\\').Count
$found = New-Object System.Collections.Generic.List[object]
$minBytes = [long]($MinMB * 1MB)

# 手动 BFS 遍历:遇到目标目录就记录并"剪枝"(不再深入,避免把 node_modules 内部的
# node_modules 重复计算),同时受 MaxDepth 限制
$queue = New-Object System.Collections.Generic.Queue[string]
$queue.Enqueue($resolvedRoot)

while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $curDepth = ($current.TrimEnd('\') -split '\\').Count - $rootDepth
    if ($curDepth -ge $MaxDepth) { continue }

    $subDirs = Get-ChildItem -LiteralPath $current -Force -Directory -ErrorAction SilentlyContinue
    foreach ($d in $subDirs) {
        if ($targetNames -contains $d.Name) {
            # 命中构建产物目录:统计大小,剪枝(不再深入)
            $size = Get-DirSize $d.FullName
            if ($size -ge $minBytes) {
                $spec = $specByName[$d.Name]
                $found.Add([pscustomobject]@{
                    SizeGB        = ConvertTo-GB $size
                    Bytes         = $size
                    Kind          = $d.Name
                    Ecosystem     = $spec.Eco
                    Risk          = $spec.Risk
                    Rebuild       = $spec.Rebuild
                    LastWriteTime = $d.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                    FullName      = $d.FullName
                })
            }
        } else {
            # 普通目录:继续深入
            $queue.Enqueue($d.FullName)
        }
    }
}

# 强制数组,避免单元素时 .Count 不展开 / 为 null
$sorted = @($found | Sort-Object Bytes -Descending)
$artifactCount = $sorted.Count
$totalBytes = ($sorted | Measure-Object -Property Bytes -Sum).Sum
if ($null -eq $totalBytes) { $totalBytes = 0 }

# 按生态汇总
$byEco = $sorted | Group-Object Ecosystem | ForEach-Object {
    $sum = ($_.Group | Measure-Object -Property Bytes -Sum).Sum
    [pscustomobject]@{
        Ecosystem = $_.Name
        Count     = $_.Count
        SizeGB    = ConvertTo-GB $sum
    }
} | Sort-Object SizeGB -Descending

$result = [pscustomobject]@{
    Tool        = "devsweep"
    Mode        = "read-only-scan-builds"
    Root        = $resolvedRoot
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    MinMB       = $MinMB
    MaxDepth    = $MaxDepth
    TotalGB     = ConvertTo-GB $totalBytes
    Count       = $artifactCount
    ByEcosystem = @($byEco)
    Artifacts   = @($sorted)
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $outDir = Join-Path $env:TEMP "devsweep"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $OutFile = Join-Path $outDir "builds_${stamp}.json"
}

$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutFile -Encoding utf8

Write-Host "[devsweep] Found $artifactCount build-artifact dirs, total $(ConvertTo-GB $totalBytes) GB" -ForegroundColor Green
Write-Host "[devsweep] JSON written to: $OutFile" -ForegroundColor Green
Write-Output $OutFile
