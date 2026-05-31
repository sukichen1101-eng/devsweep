<#
.SYNOPSIS
    devsweep - build artifact cleaner
.DESCRIPTION
    根据 scan-builds.ps1 产出的 JSON,删除选定的构建产物目录
    (node_modules / target / .next / __pycache__ 等)。
    安全设计:
      - 默认 DryRun,必须 -Execute 才真删
      - 默认只删 Risk=Low 的产物;-IncludeMedium 才纳入 Medium
      - 支持 -MinGB 只删大于某尺寸的,避免误删小目录
      - 逐项透明日志(删了哪个目录、多大、重建命令是什么)
      - 绝不删源码:只删白名单内的已知产物目录名
.PARAMETER ScanJson
    scan-builds.ps1 输出的 JSON 路径。必填。
.PARAMETER Execute
    真正执行删除。不加 = DryRun 预览。
.PARAMETER IncludeMedium
    把 Risk=Medium 的产物(dist/build/venv/bin 等)也纳入。默认只删 Low。
.PARAMETER MinGB
    只删 >= 该大小(GB)的产物。默认 0(不限)。
.PARAMETER LogFile
    操作日志 JSON 路径。默认 $env:TEMP\devsweep\clean-builds_<timestamp>.json。
.EXAMPLE
    .\clean-builds.ps1 -ScanJson "...\builds_xxx.json"             # 预览 Low 风险
    .\clean-builds.ps1 -ScanJson "...\builds_xxx.json" -Execute    # 删 Low 风险
    .\clean-builds.ps1 -ScanJson "...\builds_xxx.json" -IncludeMedium -MinGB 0.5 -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScanJson,
    [switch]$Execute,
    [switch]$IncludeMedium,
    [double]$MinGB = 0,
    [string]$LogFile
)

$ErrorActionPreference = "Stop"
$dryRun = -not $Execute

function ConvertTo-GB { param($Bytes); if ($null -eq $Bytes) { return 0 }; return [math]::Round([double]$Bytes/1GB,2) }

if (-not (Test-Path -LiteralPath $ScanJson)) {
    Write-Error "Scan JSON not found: $ScanJson. Run scan-builds.ps1 first."
    exit 1
}

$scan = Get-Content -LiteralPath $ScanJson -Raw | ConvertFrom-Json
if ($scan.Mode -ne 'read-only-scan-builds') {
    Write-Error "Not a scan-builds JSON (Mode=$($scan.Mode)). Use output from scan-builds.ps1."
    exit 1
}

# 白名单:只有这些已知产物目录名才允许删除(防止 JSON 被篡改后误删源码)
$allowedKinds = @(
    'node_modules','target','.next','dist','build','__pycache__','.pytest_cache',
    '.gradle','.venv','venv','.turbo','out','.angular','obj','bin'
)

$minBytes = [long]($MinGB * 1GB)

# 按风险 + 尺寸 + 白名单过滤
$candidates = @($scan.Artifacts | Where-Object {
    ($allowedKinds -contains $_.Kind) -and
    ($_.Bytes -ge $minBytes) -and
    ( ($_.Risk -eq 'Low') -or ($IncludeMedium -and $_.Risk -eq 'Medium') )
})

$mode = if ($dryRun) { 'DRY-RUN (preview only)' } else { 'EXECUTE (deleting)' }
$riskScope = if ($IncludeMedium) { 'Low + Medium' } else { 'Low only' }
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  devsweep clean-builds  |  Mode: $mode" -ForegroundColor Cyan
Write-Host "  Risk scope: $riskScope  |  MinGB: $MinGB" -ForegroundColor Cyan
Write-Host "  Source: $ScanJson" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

if ($candidates.Count -eq 0) {
    Write-Host "  No artifacts match the current filter. Nothing to do." -ForegroundColor Yellow
    exit 0
}

$log = New-Object System.Collections.Generic.List[object]
$totalBytes = 0L

foreach ($a in $candidates) {
    $exists = Test-Path -LiteralPath $a.FullName
    $entry = [pscustomobject]@{
        Kind      = $a.Kind
        Ecosystem = $a.Ecosystem
        Risk      = $a.Risk
        SizeGB    = $a.SizeGB
        Bytes     = $a.Bytes
        Path      = $a.FullName
        Rebuild   = $a.Rebuild
        Action    = if ($dryRun) { 'would-delete' } else { 'deleted' }
        Succeeded = $true
        Error     = $null
        Time      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    if (-not $exists) {
        $entry.Action = 'skipped-missing'
        $entry.Succeeded = $false
        $entry.Error = 'path no longer exists'
        Write-Host ("  [skip] {0,-14} {1,7} GB  {2} (gone)" -f $a.Kind, $a.SizeGB, $a.FullName) -ForegroundColor DarkGray
        $log.Add($entry); continue
    }

    if ($dryRun) {
        Write-Host ("  [{0}] {1,-14} {2,7} GB  {3}" -f $a.Risk, $a.Kind, $a.SizeGB, $a.FullName) -ForegroundColor Yellow
        Write-Host ("         rebuild: {0}" -f $a.Rebuild) -ForegroundColor DarkGray
    } else {
        try {
            Remove-Item -LiteralPath $a.FullName -Recurse -Force -ErrorAction Stop
            Write-Host ("  [{0}] {1,-14} {2,7} GB  deleted  {3}" -f $a.Risk, $a.Kind, $a.SizeGB, $a.FullName) -ForegroundColor Green
        } catch {
            $entry.Succeeded = $false
            $entry.Error = $_.Exception.Message
            Write-Host ("  [FAIL] {0,-14} {1}" -f $a.Kind, $_.Exception.Message) -ForegroundColor Red
        }
    }
    if ($entry.Succeeded -or $dryRun) { $totalBytes += $a.Bytes }
    $log.Add($entry)
}

if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $outDir = Join-Path $env:TEMP "devsweep"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $LogFile = Join-Path $outDir "clean-builds_${stamp}.json"
}
$logResult = [pscustomobject]@{
    Tool        = "devsweep"
    Action      = "clean-builds"
    DryRun      = $dryRun
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    RiskScope   = $riskScope
    MinGB       = $MinGB
    TotalGB     = ConvertTo-GB $totalBytes
    ItemCount   = $log.Count
    Items       = $log.ToArray()
}
$logResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $LogFile -Encoding utf8

Write-Host "--------------------------------------------" -ForegroundColor Cyan
$verb = if ($dryRun) { 'Would free' } else { 'Freed' }
Write-Host ("  {0}: {1} GB across {2} dirs" -f $verb, (ConvertTo-GB $totalBytes), $candidates.Count) -ForegroundColor Cyan
if ($dryRun) {
    Write-Host "  This was a PREVIEW. Re-run with -Execute to actually delete." -ForegroundColor Yellow
}
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Output $LogFile
