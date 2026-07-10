# Maodie Launcher - 一键打包脚本
# 用法: powershell -ExecutionPolicy Bypass -File build.ps1 [-CleanOnly]

param(
    [switch]$CleanOnly
)

$ErrorActionPreference = "Stop"

$ProjectRoot = $PSScriptRoot
$ModuleProp  = Join-Path $ProjectRoot "module.prop"

$IncludeItems = @(
    "META-INF",
    "maodie",
    "webroot",
    "customize.sh",
    "module.prop",
    "service.sh",
    "post-fs-data.sh",
    "uninstall.sh",
    "action.sh"
)

$ExcludedRelativePaths = @(
    "maodie/config/cache.db",
    "maodie/config/adblock.enabled",
    "maodie/config/adblock.state",
    "maodie/config/config.yaml.last-good"
)

function Test-ExcludedPath($relativePath) {
    if ($ExcludedRelativePaths -contains $relativePath) { return $true }
    if ($relativePath.StartsWith("maodie/config/proxy_providers/")) { return $true }
    if ($relativePath.StartsWith("maodie/run/") -and $relativePath -ne "maodie/run/.gitkeep") { return $true }
    return $false
}

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

$zip = $null
try {
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')

    foreach ($item in $IncludeItems) {
        $fullPath = Join-Path $ProjectRoot $item

        if (Test-Path $fullPath -PathType Container) {
            $files = Get-ChildItem -Path $fullPath -Recurse -File
            foreach ($file in $files) {
                $relativePath = $file.FullName.Substring($ProjectRoot.Length + 1).Replace('\', '/')
                if (Test-ExcludedPath $relativePath) { continue }
                $entry = $zip.CreateEntry($relativePath)
                $stream = $entry.Open()
                try {
                    $fs = [System.IO.File]::OpenRead($file.FullName)
                    try { $fs.CopyTo($stream) } finally { $fs.Dispose() }
                } finally { $stream.Dispose() }
            }
        } elseif (Test-Path $fullPath -PathType Leaf) {
            $relativePath = $item.Replace('\', '/')
            $entry = $zip.CreateEntry($relativePath)
            $stream = $entry.Open()
            try {
                $fs = [System.IO.File]::OpenRead($fullPath)
                try { $fs.CopyTo($stream) } finally { $fs.Dispose() }
            } finally { $stream.Dispose() }
        }
    }
} catch {
    if ($zip) { $zip.Dispose(); $zip = $null }
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    throw
} finally {
    if ($zip) { $zip.Dispose() }
}

# ─── 结果 ─────────────────────────────────────────────────────
if (Test-Path $zipPath) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $required = @("module.prop", "customize.sh", "service.sh", "maodie/kernel/Mihomo", "maodie/config/config.yaml")
        $entries = @($archive.Entries | ForEach-Object { $_.FullName })
        foreach ($path in $required) {
            if ($entries -notcontains $path) { throw "ZIP 缺少必要文件: $path" }
        }
    } finally { $archive.Dispose() }
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
