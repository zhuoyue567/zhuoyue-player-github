<#
.SYNOPSIS
  构建「卓越播放器」的 Windows 安装包。

.DESCRIPTION
  流程：release 构建 → 暂存到 packaging\staging → 去掉不该随包分发的东西
  → 用 Inno Setup 编译成安装包 → 报告产物大小与校验和。

  为什么要"暂存"而不是直接拿 build\ 当源：Flutter 的 build 目录里除了要发布的
  文件之外还有中间产物（*.pdb、kernel 之类），而且**内置字体必须在这里被摘掉**
  （再分发许可未经核实）。暂存让"发出去的到底是什么"变成一步可检查、可复现的操作。

.PARAMETER Version
  版本号，默认取 pubspec.yaml 里的 version（去掉 +build 后缀）。
  它会写进安装包的显示名与 installer.json。

.PARAMETER SkipBuild
  跳过 flutter build（暂存目录已经是最新构建产物时用，便于反复调安装脚本）。

.PARAMETER Configuration
  取 Release（默认，用于发布）或 Debug（只用于快速验证安装脚本本身能不能编译）。

.PARAMETER KeepGoing
  字体摘除后不再校验（默认会校验暂存目录里确实没有字体文件）。

.EXAMPLE
  pwsh -File scripts/build-installer.ps1
  pwsh -File scripts/build-installer.ps1 -SkipBuild -Version 0.1.0
#>
[CmdletBinding()]
param(
  [string]$Version,
  [switch]$SkipBuild,
  [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ---- 0. 前置检查 -----------------------------------------------------------
$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
  throw "找不到 ISCC.exe（Inno Setup 6）。装一个：winget install --id JRSoftware.InnoSetup -e"
}
Step "编译器：$iscc"

if (-not $Version) {
  $line = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)' | Select-Object -First 1
  if (-not $line) { throw "pubspec.yaml 里读不到 version" }
  $Version = ($line.Matches[0].Groups[1].Value -split '\+')[0]
}
Step "版本：$Version"

# ---- 1. release 构建 -------------------------------------------------------
if ($SkipBuild) {
  Warn '按参数跳过 flutter build（使用现有构建产物）'
} else {
  $configArg = "--$($Configuration.ToLower())"
  Step "flutter build windows $configArg"
  & flutter build windows $configArg
  if ($LASTEXITCODE -ne 0) { throw "flutter build 失败（exit=$LASTEXITCODE）" }
}

$built = Join-Path $repo "build\windows\x64\runner\$Configuration"
if (-not (Test-Path $built)) { throw "找不到 $Configuration 产物：$built" }

# ---- 2. 暂存 ---------------------------------------------------------------
$staging = Join-Path $repo 'packaging\staging'
Step "暂存到 $staging"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Copy-Item (Join-Path $built '*') $staging -Recurse -Force

# 中间产物不发布：*.pdb 是调试符号（几十 MB），*.exp/*.lib 是链接期产物。
$junk = Get-ChildItem $staging -Recurse -File -Include *.pdb, *.exp, *.lib, *.ilk -ErrorAction SilentlyContinue
if ($junk) {
  $junk | Remove-Item -Force
  Ok ("去掉中间产物 {0} 个（{1:N1} MB）" -f $junk.Count, (($junk | Measure-Object Length -Sum).Sum / 1MB))
}

# ---- 3. 摘掉内置字体 -------------------------------------------------------
# 用户的决定：字体随**源码仓库**分发，但**不随安装包**分发（再分发许可未经核实）。
# 只删文件是不够的：FontManifest.json 里还列着它，引擎会去找一个不存在的资源。
# 所以两处一起处理，并验证结果。
Step '摘掉内置字体（不随安装包分发）'
$fontAsset = Join-Path $staging 'data\flutter_assets\assets\fonts\zhuzi.ttf'
$fontDir = Join-Path $staging 'data\flutter_assets\assets\fonts'
$manifest = Join-Path $staging 'data\flutter_assets\FontManifest.json'

if (Test-Path $fontAsset) {
  $before = (Get-Item $fontAsset).Length / 1MB
  Remove-Item $fontAsset -Force
  if ((Get-ChildItem $fontDir -File -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
    Remove-Item $fontDir -Force
  }
  Ok ("已删除 zhuzi.ttf（{0:N1} MB）" -f $before)
} else {
  Warn '暂存目录里没有 zhuzi.ttf（可能本来就没打进去）'
}

if (Test-Path $manifest) {
  $json = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  $kept = @($json | Where-Object { $_.family -ne 'Zhuzi' })
  $removed = @($json | Where-Object { $_.family -eq 'Zhuzi' }).Count
  if ($removed -gt 0) {
    $kept | ConvertTo-Json -Depth 10 -Compress | Set-Content $manifest -Encoding UTF8 -NoNewline
    Ok "FontManifest.json 里摘掉了 Zhuzi 条目"
  } else {
    Warn 'FontManifest.json 里本来就没有 Zhuzi'
  }
} else {
  Warn '没有 FontManifest.json（新版本 Flutter 可能改用别的清单）'
}

# AssetManifest 里若还列着字体，也一起摘掉，避免运行时去取一个不存在的资源。
$assetManifest = Join-Path $staging 'data\flutter_assets\AssetManifest.json'
if (Test-Path $assetManifest) {
  $raw = Get-Content $assetManifest -Raw -Encoding UTF8
  if ($raw -match 'zhuzi') {
    $obj = $raw | ConvertFrom-Json
    $obj.PSObject.Properties | Where-Object { $_.Name -match 'zhuzi' } | ForEach-Object { $obj.PSObject.Properties.Remove($_.Name) }
    $obj | ConvertTo-Json -Depth 10 -Compress | Set-Content $assetManifest -Encoding UTF8 -NoNewline
    Ok 'AssetManifest.json 里摘掉了字体条目'
  }
}

# ---- 4. 校验 ---------------------------------------------------------------
Step '校验暂存内容'
$leftover = Get-ChildItem $staging -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'zhuzi\.ttf$' }
if ($leftover) { throw "暂存目录里仍有字体文件：$($leftover.FullName -join ', ')" }
Ok '确认没有字体残留'

# 必需文件按构建类型区分：Release 是 AOT（`data\app.so`），
# Debug 是 JIT（`data\flutter_assets\kernel_blob.bin`）—— 我第一次把 app.so
# 写成无条件必需，结果 Debug 暂存直接被自己的校验挡住。
$required = @('zhuoyue_player.exe', 'flutter_windows.dll', 'data\icudtl.dat')
if ($Configuration -eq 'Release') {
  $required += 'data\app.so'
} else {
  $required += 'data\flutter_assets\kernel_blob.bin'
}
foreach ($must in $required) {
  if (-not (Test-Path (Join-Path $staging $must))) { throw "暂存目录缺少必需文件：$must" }
}
Ok ("必需文件齐全（{0}）" -f ($required -join ' / '))

$size = (Get-ChildItem $staging -Recurse -File | Measure-Object Length -Sum).Sum
Ok ("暂存体积 {0:N1} MB" -f ($size / 1MB))

# ---- 5. 编译安装包 ---------------------------------------------------------
Step 'ISCC 编译安装包'
& $iscc "/DAppVersion=$Version" (Join-Path $repo 'packaging\zhuoyue-player.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC 失败（exit=$LASTEXITCODE）" }

$setup = Get-ChildItem (Join-Path $repo 'packaging\dist') -Filter '*-setup.exe' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setup) { throw '没有生成安装包' }

$hash = (Get-FileHash $setup.FullName -Algorithm SHA256).Hash
Step '完成'
Ok ("产物：{0}" -f $setup.FullName)
Ok ("大小：{0:N1} MB" -f ($setup.Length / 1MB))
Ok ("SHA256：{0}" -f $hash)
Write-Host ''
Write-Host '提醒：安装包**不含** Node 运行时与内置字体。' -ForegroundColor Yellow
Write-Host '     应用首次启动需要联网准备运行时；字体缺失时会回退到系统字体。' -ForegroundColor Yellow
