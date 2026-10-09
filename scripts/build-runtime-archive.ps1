<#
.SYNOPSIS
  把本地已经准备好的 `runtime/`（node + netease-api）打成**一个合并 zip**，
  作为 GitHub Release 的附件 —— 应用首次启动时下载的就是它。

.DESCRIPTION
  为什么需要这个脚本：应用运行时要求 `runtime/` 里同时有 `node/node.exe` 与
  `netease-api/launcher.js`，而 **Node 官方发行包里只有 node.exe**，没有
  `NeteaseCloudMusicApi` 及其 `node_modules`。所以"让应用自己下载"这件事
  必须有一个**已经合并好的包**可下；这个脚本负责生成它，并给出应用要填的
  URL 与 SHA-256。

  用法：先在本机跑 `scripts/fetch-runtime.ps1` 把 `runtime/` 准备好，
  再跑本脚本产出 `packaging/dist/runtime-v1.zip`。

  产出之后要做两件事（脚本会把命令打印出来）：
    1. 把它作为附件上传到 GitHub Release（与安装包同一个 release）；
    2. 把 URL 与 SHA-256 填进应用里那**一处**常量。

.PARAMETER OutputPath
  产物路径，默认 `packaging/dist/runtime-v1.zip`。

.PARAMETER ZipName
  应用侧看到的文件名，也决定了 Release 附件名。默认 `runtime-v1.zip`。
  版本号进文件名是刻意的：将来运行时内容变了要发新包，
  文件名一变就不会有人误以为"还是原来那个"。

.PARAMETER SkipVerify
  跳过"打好之后重新读一遍 zip 校验条目数"这一步（默认会校验）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-runtime-archive.ps1
#>
[CmdletBinding()]
param(
  [string]$OutputPath,
  [string]$ZipName = 'runtime-v1.zip',
  [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

if (-not $OutputPath) { $OutputPath = Join-Path $repo "packaging\dist\$ZipName" }

# ---- 1. 前置检查：本地 runtime 必须真的是"完整可用"的那一套 -----------------
# 判定标准与运行时下载器里的 hasUsableRuntime 保持一致（只看这两个必需文件），
# 否则我们打出来的包会让应用装完仍然认为"没装好"。
Step '检查本地 runtime 是否完整'
$nodeExe = Join-Path $repo 'runtime\node\node.exe'
$launcher = Join-Path $repo 'runtime\netease-api\launcher.js'
$modules = Join-Path $repo 'runtime\netease-api\node_modules'

foreach ($must in @($nodeExe, $launcher)) {
  if (-not (Test-Path $must)) {
    throw "缺少 $must —— 先跑 scripts\fetch-runtime.ps1 把运行时准备好"
  }
}
if (-not (Test-Path $modules)) {
  throw "缺少 $modules —— 没有依赖的运行时打出来也是废的（应用会报无法加载 NeteaseCloudMusicApi）"
}
$srcBytes = (Get-ChildItem (Join-Path $repo 'runtime') -Recurse -File | Measure-Object Length -Sum).Sum
Ok ("runtime 体积 {0:N1} MB" -f ($srcBytes / 1MB))

# ---- 2. 打包 ---------------------------------------------------------------
$outDir = Split-Path $OutputPath -Parent
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

Step "打包到 $OutputPath"
# 关键：把 `runtime/` 这个目录本身作为压缩包的**顶层内容**打进 zip
# （即压缩包解开后直接是 `node/` 与 `netease-api/`，而不是 `runtime/node/`）。
# 下载器的 `_resolvePayload` 对"单层包裹"与"摊平"两种形态都兼容，
# 但摊平更省事，也不会在用户盘上多套一层目录。
# Windows PowerShell 5.1 下 `ZipArchiveMode` 在 System.IO.Compression 里，
# 而 `ZipFile` 在 System.IO.Compression.FileSystem 里 —— 两个都要显式加载；
# 只加载后者会报 "Unable to find type [System.IO.Compression.ZipArchiveMode]"。
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($OutputPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  $root = Join-Path $repo 'runtime'
  $files = Get-ChildItem $root -Recurse -File
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length).TrimStart('\')
    $entryName = $rel.Replace('\', '/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $zip, $f.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
  Ok ("写入 {0} 个条目" -f $files.Count)
} finally {
  $zip.Dispose()
}

$size = (Get-Item $OutputPath).Length
Ok ("产物 {0:N1} MB" -f ($size / 1MB))

# ---- 3. 校验（重新读一遍，确认条目在、关键文件在） -------------------------
if (-not $SkipVerify) {
  Step '重新读一遍 zip 校验'
  $read = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)
  try {
    $names = $read.Entries | ForEach-Object { $_.FullName }
    $count = ($names | Measure-Object).Count
    Ok "条目数 $count"
    foreach ($need in @('node/node.exe', 'netease-api/launcher.js')) {
      if ($names -notcontains $need) { throw "压缩包里缺少关键条目：$need" }
    }
    Ok '关键条目齐全（node/node.exe、netease-api/launcher.js）'
    if ($names | Where-Object { $_ -like 'runtime/*' }) {
      Warn '发现 `runtime/` 前缀 —— 应用侧能处理（会"提"一层），但摊平更干净，确认这是你想要的'
    }
    $moduleEntries = ($names | Where-Object { $_ -like 'netease-api/node_modules/*' } | Measure-Object).Count
    if ($moduleEntries -eq 0) { throw '压缩包里没有 netease-api/node_modules —— 应用装完仍会认为运行时不可用' }
    Ok "netease-api/node_modules 条目 $moduleEntries 个"
  } finally {
    $read.Dispose()
  }
}

# ---- 4. 给出应用侧要填的东西 ----------------------------------------------
$hash = (Get-FileHash $OutputPath -Algorithm SHA256).Hash
$fileName = Split-Path $OutputPath -Leaf

Step '完成'
Ok "产物：$OutputPath"
Ok "SHA256：$hash"
Write-Host ''
Write-Host '接下来两步（第一步在 GitHub 上做，第二步改一处代码）：' -ForegroundColor Yellow
Write-Host ''
Write-Host '1) 把这个 zip 作为附件上传到 Release（与安装包同一个 release）：' -ForegroundColor Yellow
Write-Host "     在 https://github.com/<你的账号>/<仓库名>/releases 里编辑 v0.1.0，上传 $fileName" -ForegroundColor Yellow
Write-Host '   （装了 gh 的话也可以： gh release upload v0.1.0 "<路径>" ）' -ForegroundColor Yellow
Write-Host ''
Write-Host '2) 把下面两行填进应用里的那一处常量（引导页/设置里那个下载入口）：' -ForegroundColor Yellow
Write-Host ''
Write-Host "     const String kRuntimeArchiveUrl =" -ForegroundColor Green
Write-Host "         'https://github.com/<你的账号>/<仓库名>/releases/download/v0.1.0/$fileName';" -ForegroundColor Green
Write-Host "     const String kRuntimeArchiveSha256 = '$hash';" -ForegroundColor Green
Write-Host ''
Write-Host '   哈希必须填：下载器会用它校验，不匹配就拒绝安装（宁可失败也不装半个坏的运行时）。' -ForegroundColor Yellow
