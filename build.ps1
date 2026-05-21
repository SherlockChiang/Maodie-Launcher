# Maodie Launcher - 一键打包脚本
# 用法: powershell -ExecutionPolicy Bypass -File build.ps1 [-SkipAsn] [-CleanOnly]

param(
    [switch]$SkipAsn,
    [switch]$CleanOnly
)

$ErrorActionPreference = "Stop"

$ProjectRoot = $PSScriptRoot
$AsnDb       = Join-Path $ProjectRoot "maodie\config\ASN.mmdb"
$ModuleProp  = Join-Path $ProjectRoot "module.prop"

$IncludeItems = @(
    "META-INF",
    "maodie",
    "webroot",
    "customize.sh",
    "module.prop",
    "service.sh",
    "uninstall.sh",
    "action.sh"
)

function Write-Step($msg)  { Write-Host ">> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "   $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "   $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "   $msg" -ForegroundColor Red }

function Get-Version {
    if (-not (Test-Path $ModuleProp)) {
        Write-Err "module.prop 不存在"
        exit 1
    }
    $content = Get-Content $ModuleProp -Raw
    $match = [regex]::Match($content, '^version=(.+)', 'Multiline')
    if (-not $match.Success) {
        Write-Err "无法从 module.prop 读取版本号"
        exit 1
    }
    return $match.Groups[1].Value.Trim()
}

function Get-GitHash {
    try {
        $hash = & git rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { return $hash }
    } catch {}
    return "local"
}

function Download-Asn {
    $url = "https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-ASN.mmdb"
    $dir = Split-Path $AsnDb -Parent

    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path $AsnDb) {
        $age = (Get-Date) - (Get-Item $AsnDb).LastWriteTime
        if ($age.TotalDays -lt 30) {
            Write-Ok "ASN 数据库已缓存 ($([int]$age.TotalDays) 天前)，跳过下载"
            return
        }
    }

    Write-Step "下载 ASN 数据库..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Maodie-Launcher/1.0")
        $wc.DownloadFile($url, $AsnDb)
        $sizeMB = [math]::Round((Get-Item $AsnDb).Length / 1MB, 1)
        Write-Ok "ASN 数据库下载完成: $sizeMB MB"
    } catch {
        Write-Warn "ASN 数据库下载失败: $($_.Exception.Message)"
        Write-Warn "模块仍可打包，但 geo-ip 规则可能不完整"
    }
}

# ─── 清理 ─────────────────────────────────────────────────────
if ($CleanOnly) {
    Write-Step "清理构建产物..."
    $zips = Get-ChildItem -Path $ProjectRoot -Filter "Maodie-Launcher-*.zip" -ErrorAction SilentlyContinue
    foreach ($z in $zips) {
        Remove-Item $z.FullName -Force
        Write-Ok "已删除: $($z.Name)"
    }
    Write-Host "`n清理完成。" -ForegroundColor Green
    exit 0
}

# ─── 主流程 ───────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "   Maodie Launcher - 一键打包" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

$version = Get-Version
$gitHash = Get-GitHash
Write-Step "版本: $version"
Write-Step "Commit: $gitHash"

Write-Step "检查打包文件..."
$missing = @()
foreach ($item in $IncludeItems) {
    $path = Join-Path $ProjectRoot $item
    if (-not (Test-Path $path)) {
        $missing += $item
    }
}
if ($missing.Count -gt 0) {
    Write-Err "缺少必要文件: $($missing -join ', ')"
    exit 1
}
Write-Ok "所有必要文件就绪"

if (-not $SkipAsn) {
    Download-Asn
} else {
    Write-Step "跳过 ASN 数据库下载 (-SkipAsn)"
}

$runDir = Join-Path $ProjectRoot "maodie\run"
if (-not (Test-Path $runDir)) {
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
}
$gitkeep = Join-Path $runDir ".gitkeep"
if (-not (Test-Path $gitkeep)) {
    Set-Content -Path $gitkeep -Value "" -NoNewline
}

# ─── 打包 ─────────────────────────────────────────────────────
Write-Step "正在打包..."
$zipName = "Maodie-Launcher-$version.zip"
$zipPath = Join-Path $ProjectRoot $zipName

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')

foreach ($item in $IncludeItems) {
    $fullPath = Join-Path $ProjectRoot $item

    if (Test-Path $fullPath -PathType Container) {
        $files = Get-ChildItem -Path $fullPath -Recurse -File
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($ProjectRoot.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($relativePath)
            $stream = $entry.Open()
            $fs = [System.IO.File]::OpenRead($file.FullName)
            $fs.CopyTo($stream)
            $fs.Close()
            $stream.Close()
        }
    } elseif (Test-Path $fullPath -PathType Leaf) {
        $relativePath = $item.Replace('\', '/')
        $entry = $zip.CreateEntry($relativePath)
        $stream = $entry.Open()
        $fs = [System.IO.File]::OpenRead($fullPath)
        $fs.CopyTo($stream)
        $fs.Close()
        $stream.Close()
    }
}

$zip.Dispose()

# ─── 结果 ─────────────────────────────────────────────────────
if (Test-Path $zipPath) {
    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "   打包成功!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Ok "文件: $zipName"
    Write-Ok "大小: $sizeMB MB"
    Write-Ok "路径: $zipPath"
    Write-Host ""
} else {
    Write-Err "打包失败: zip 文件未生成"
    exit 1
}
