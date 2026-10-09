<#
.SYNOPSIS
    准备 ZhuoYue Player 的内嵌运行时：Node.js + NeteaseCloudMusicApi。

.DESCRIPTION
    产物全部落在仓库根的 runtime/ 目录（已 gitignore），构建时由 CMake 复制到 exe 同级：

        runtime/
          node/           便携版 node.exe（含 npm）
          netease-api/    NeteaseCloudMusicApi 及其依赖 + launcher.js

    脚本是幂等的：已存在的部分会跳过，除非加 -Force。
    国内网络环境默认使用 npmmirror 镜像，可用 -Registry 覆盖。

.EXAMPLE
    pwsh -File scripts/fetch-runtime.ps1
    pwsh -File scripts/fetch-runtime.ps1 -Force -NodeLine latest-v22.x
#>
[CmdletBinding()]
param(
    [string]$NodeLine = 'latest-v22.x',
    [string]$Registry = 'https://registry.npmmirror.com',
    [string]$NeteaseVersion = '4.32.0',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RuntimeDir = Join-Path $RepoRoot 'runtime'
$CacheDir = Join-Path $RepoRoot '.cache'
$NodeDir = Join-Path $RuntimeDir 'node'
$ApiDir = Join-Path $RuntimeDir 'netease-api'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    [skip] $msg" -ForegroundColor DarkGray }

New-Item -ItemType Directory -Force -Path $RuntimeDir, $CacheDir | Out-Null

# ---------------------------------------------------------------- Node.js
Write-Step "Node.js ($NodeLine)"
$nodeExe = Join-Path $NodeDir 'node.exe'
if ((Test-Path $nodeExe) -and -not $Force) {
    Write-Skip "已存在 $nodeExe ($(& $nodeExe --version))"
}
else {
    $sumsUrl = "https://nodejs.org/dist/$NodeLine/SHASUMS256.txt"
    Write-Host "    读取 $sumsUrl"
    $sums = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing -TimeoutSec 60).Content
    $line = ($sums -split "`n") | Where-Object { $_ -match 'node-v[\d.]+-win-x64\.zip$' } | Select-Object -First 1
    if (-not $line) { throw "在 $sumsUrl 中找不到 win-x64 zip" }
    # 注意：必须强制成数组再取下标。PowerShell 里"只有一个元素的管道结果"
    # 直接写 [0] 会退化成取字符串的第 0 个字符（之前就把文件名取成了 'n'）。
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    $sha = $parts[0]
    $zipName = $parts[-1]
    $zipUrl = "https://nodejs.org/dist/$NodeLine/$zipName"
    $zipPath = Join-Path $CacheDir $zipName

    if (-not (Test-Path $zipPath)) {
        Write-Host "    下载 $zipUrl"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 900
    }
    else { Write-Skip "复用缓存 $zipPath" }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    if ($actual -ne $sha.ToLower()) { throw "SHA256 校验失败: 期望 $sha 实际 $actual" }
    Write-Ok "SHA256 校验通过 ($sha)"

    if (Test-Path $NodeDir) { Remove-Item -Recurse -Force $NodeDir }
    $tmp = Join-Path $CacheDir 'node-extract'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $zipPath -DestinationPath $tmp -Force
    $inner = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    Move-Item -Path $inner.FullName -Destination $NodeDir
    Remove-Item -Recurse -Force $tmp
    Write-Ok "解压到 $NodeDir"
}
$npmCmd = Join-Path $NodeDir 'npm.cmd'
Write-Ok "node $(& $nodeExe --version) / npm $(& $npmCmd --version)"

# ------------------------------------------------- NeteaseCloudMusicApi
Write-Step "NeteaseCloudMusicApi@$NeteaseVersion"
$apiMain = Join-Path $ApiDir 'node_modules\NeteaseCloudMusicApi\package.json'
if ((Test-Path $apiMain) -and -not $Force) {
    # 必须显式 -Encoding UTF8：Windows PowerShell 5.1 默认按 ANSI(936) 读文件，
    # 会把 package.json 里的中文描述读坏进而让 ConvertFrom-Json 直接抛错。
    # 这里干脆用正则取版本号，顺便免掉一整个 JSON 解析依赖。
    $raw = Get-Content -Raw -Encoding UTF8 $apiMain
    $installed = if ($raw -match '"version"\s*:\s*"([^"]+)"') { $Matches[1] } else { '未知' }
    Write-Skip "已安装 $installed（需要其他版本请加 -Force）"
}
else {
    New-Item -ItemType Directory -Force -Path $ApiDir | Out-Null
    $pkgJson = @{
        name         = 'zhuoyue-netease-runtime'
        version      = '1.0.0'
        private      = $true
        description  = 'Embedded NeteaseCloudMusicApi runtime for ZhuoYue Player'
        dependencies = @{ NeteaseCloudMusicApi = $NeteaseVersion }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $ApiDir 'package.json') -Value $pkgJson -Encoding UTF8

    Write-Host "    安装依赖（registry=$Registry）"
    Push-Location $ApiDir
    # Windows PowerShell 5.1 下，原生程序的 stderr 在 $ErrorActionPreference='Stop'
    # 时会被包装成终止性错误（npm 的 notice 走 stderr，于是安装成功也报错退出）。
    # 这里局部放宽策略，改为只看退出码。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $npmCmd install --no-audit --no-fund --loglevel=error "--registry=$Registry" 2>&1 |
            ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        $npmExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
    if ($npmExit -ne 0) { throw "npm install 失败，退出码 $npmExit" }
    Write-Ok "安装完成"
}

# ------------------------------------------------------------- launcher
Write-Step "写入 launcher.js"
$launcher = Join-Path $ApiDir 'launcher.js'
$launcherSrc = @'
// ZhuoYue Player 内嵌网易云 API 服务启动器。
//
// 由 Flutter 端以子进程方式拉起：
//   1. 自己在 loopback 上挑一个空闲端口（不依赖库的返回值形态）；
//   2. 启动 NeteaseCloudMusicApi；
//   3. 轮询 HTTP 直到服务真正可响应，才在 stdout 打印
//      "ZHUOYUE_API_READY <port>"。
// Flutter 端仅以这一行为就绪信号，避免竞态。
const http = require('http');
const net = require('net');

const HOST = process.env.ZHUOYUE_HOST || '127.0.0.1';

let ncm;
try {
  ncm = require('NeteaseCloudMusicApi');
} catch (err) {
  console.error('[zhuoyue] 无法加载 NeteaseCloudMusicApi:', err && err.message);
  process.exit(2);
}

function findFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, HOST, () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

function probe(port) {
  return new Promise((resolve) => {
    const req = http.request(
      { host: HOST, port, path: '/', method: 'GET', timeout: 1500 },
      (res) => {
        res.resume();
        resolve(true);
      }
    );
    req.on('error', () => resolve(false));
    req.on('timeout', () => {
      req.destroy();
      resolve(false);
    });
    req.end();
  });
}

async function main() {
  if (typeof ncm.serveNcmApi !== 'function') {
    console.error(
      '[zhuoyue] NeteaseCloudMusicApi 未导出 serveNcmApi，版本不兼容。exports=',
      Object.keys(ncm).join(',')
    );
    process.exit(3);
  }

  const port = await findFreePort();
  // 环境变量与入参同时给，兼容不同版本读取来源的差异。
  process.env.PORT = String(port);

  try {
    // 不传 moduleDefs：4.x 的 main.js 并没有导出它，传 undefined 反而容易被误读为
    // "自定义路由"。留空时 server.js 会走内置的完整路由表。
    await ncm.serveNcmApi({
      port,
      host: HOST,
      checkVersion: false,
    });
  } catch (err) {
    console.error('[zhuoyue] serveNcmApi 抛错:', err && (err.stack || err.message));
    process.exit(4);
  }

  // 就绪判定：连续轮询到 HTTP 可响应。
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    if (await probe(port)) {
      console.log(`ZHUOYUE_API_READY ${port}`);
      return;
    }
    await new Promise((r) => setTimeout(r, 250));
  }

  console.error('[zhuoyue] 服务在 60 秒内未就绪');
  process.exit(5);
}

main().catch((err) => {
  console.error('[zhuoyue] 启动失败:', err && (err.stack || err.message));
  process.exit(1);
});
'@
Set-Content -Path $launcher -Value $launcherSrc -Encoding UTF8
Write-Ok $launcher

# ------------------------------------------------------------- 冒烟测试
Write-Step "冒烟测试"
$env:ZHUOYUE_HOST = '127.0.0.1'
$env:ZHUOYUE_PORT = '0'
$logFile = Join-Path $CacheDir 'runtime-smoke.log'
$errFile = Join-Path $CacheDir 'runtime-smoke.err.log'
$proc = Start-Process -FilePath $nodeExe -ArgumentList $launcher -WorkingDirectory $ApiDir `
    -RedirectStandardOutput $logFile -RedirectStandardError $errFile -PassThru -NoNewWindow

try {
    $port = $null
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $logFile) {
            $m = Select-String -Path $logFile -Pattern 'ZHUOYUE_API_READY (\d+)' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($m) { $port = [int]$m.Matches[0].Groups[1].Value; break }
        }
        if ($proc.HasExited) { break }
    }
    if (-not $port) {
        Write-Host "    stdout: $(Get-Content $logFile -Raw -ErrorAction SilentlyContinue)" -ForegroundColor DarkGray
        Write-Host "    stderr: $(Get-Content $errFile -Raw -ErrorAction SilentlyContinue)" -ForegroundColor DarkGray
        throw "服务未在 45 秒内就绪"
    }
    Write-Ok "服务已就绪，端口 $port"

    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/search?keywords=%E5%91%A8%E6%9D%B0%E4%BC%A6&limit=1" -TimeoutSec 30
    if ($r.code -eq 200) { Write-Ok "/search 返回 code=200，共 $($r.result.songCount) 条" }
    else { Write-Host "    /search 返回 code=$($r.code)" -ForegroundColor Yellow }
}
finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n运行时准备完成：" -ForegroundColor Green
Write-Host "  node      : $NodeDir"
Write-Host "  netease   : $ApiDir"
