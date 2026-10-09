<#
.SYNOPSIS
  把「运行时下载地址 + SHA-256」填进应用里那**一处**常量。

.DESCRIPTION
  为什么要一个脚本而不是手改：这两个值只在发布时才知道（仓库地址来自你、
  哈希来自 `build-runtime-archive.ps1` 的产出），而它们必须**成对正确** ——
  地址对、哈希错的话下载器会拒绝安装（这是刻意的：宁可失败也不装半个坏包）。
  手改很容易只改一个。脚本一次把两处改对，改完打印 diff 供核对。

  跑完请重新构建（Dart 常量进 AOT 快照，改完不重建等于没改）。

.PARAMETER Owner
  GitHub 账号（或组织）名。

.PARAMETER Repo
  仓库名。

.PARAMETER Tag
  Release 标签，默认 `v0.1.0`。

.PARAMETER ArchiveName
  附件名，默认 `runtime-v1.zip`（与 build-runtime-archive.ps1 的默认产物一致）。

.PARAMETER Sha256
  可选：不填就自动从 `packaging/dist/<ArchiveName>` 算（推荐，避免手抄出错）。

.PARAMETER DryRun
  只打印将要写入的内容，不改文件。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\configure-runtime-download.ps1 `
      -Owner yourname -Repo zhuoyue-player
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$Tag = 'v0.1.0',
  [string]$ArchiveName = 'runtime-v1.zip',
  [string]$Sha256,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }

$target = Join-Path $repoRoot 'lib\features\onboarding\onboarding_providers.dart'
if (-not (Test-Path $target)) { throw "找不到要修改的文件：$target" }

# ---- 1. 求出要写入的两个值 ------------------------------------------------
$url = "https://github.com/$Owner/$Repo/releases/download/$Tag/$ArchiveName"

if (-not $Sha256) {
  $archive = Join-Path $repoRoot "packaging\dist\$ArchiveName"
  if (-not (Test-Path $archive)) {
    throw "没给 -Sha256，而产物也不存在：$archive`n先跑 scripts\build-runtime-archive.ps1，或用 -Sha256 显式指定"
  }
  $Sha256 = (Get-FileHash $archive -Algorithm SHA256).Hash
  Ok "从产物算出的 SHA-256：$Sha256"
} else {
  $Sha256 = $Sha256.ToUpperInvariant()
  Ok "使用指定的 SHA-256：$Sha256"
}# 下载器接受大写，但统一成小写更省心（它内部会规范化）

$shaLower = $Sha256.ToLowerInvariant()

Step '将要写入'
Ok "url    = $url"
Ok "sha256 = $shaLower"

if ($DryRun) {
  Write-Host ''
  Write-Host '（-DryRun：没有修改任何文件）' -ForegroundColor Yellow
  return
}

# ---- 2. 替换那两处常量 -----------------------------------------------------
# 用正则匹配"常量名 + 任意空白 + 赋值 + 到行尾"，这样不用担心当前值是什么
# （可能是 null，也可能是上一次填的值）——重复运行是幂等的。
$text = [System.IO.File]::ReadAllText($target, [System.Text.UTF8Encoding]::new($false))
$before = $text

$urlPattern = "(?m)^(const String\? kRuntimeArchiveUrl = ).*?;$"
$shaPattern = "(?m)^(const String\? kRuntimeArchiveSha256 = ).*?;$"

if ($text -notmatch $urlPattern) { throw '在文件里找不到 `const String? kRuntimeArchiveUrl = …;` 这一行 —— 文件结构变了，请人工确认' }
if ($text -notmatch $shaPattern) { throw '在文件里找不到 `const String? kRuntimeArchiveSha256 = …;` 这一行 —— 文件结构变了，请人工确认' }

$text = [regex]::Replace($text, $urlPattern, "`${1}'$url';")
$text = [regex]::Replace($text, $shaPattern, "`${1}'$shaLower';")

if ($text -eq $before) {
  Ok '两处常量已经是目标值，无需修改'
} else {
  [System.IO.File]::WriteAllText($target, $text, [System.Text.UTF8Encoding]::new($false))
  Step '已写入，请核对以下几行：'
  Select-String -Path $target -Pattern 'kRuntimeArchiveUrl|kRuntimeArchiveSha256' |
    ForEach-Object { "    $($_.LineNumber): $($_.Line.Trim())" }
}

Write-Host ''
Write-Host '别忘了重新构建：Dart 常量会进 AOT 快照，改完不重建等于没改。' -ForegroundColor Yellow
Write-Host '   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-installer.ps1' -ForegroundColor Yellow
