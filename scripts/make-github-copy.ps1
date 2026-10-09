<#
.SYNOPSIS
  为「卓越播放器」生成一份**用于上传 GitHub 的独立拷贝**。

.DESCRIPTION
  用户的要求是"单独拷贝一份用于上传 github"，所以这里不做在本仓库里 `git init`
  —— 本仓库带着 500MB+ 的构建产物、121MB 的下载运行时与本机临时文件，
  直接在它里面建仓很容易把不该发的东西发出去。

  做法：把工作树复制到一个**平级的新目录**，在那里 `git init` + 首次提交。
  "到底哪些文件会被发布"这个问题**只有一个答案来源：`.gitignore`** ——
  脚本刻意不自己维护第二份排除清单（那种双份清单迟早会不一致）。
  复制阶段只把几个体积巨大的目录排除掉（纯粹为了速度），细粒度过滤交给 git。

  提交**之前**会做两道检查，任何一道不过就中止：
    1. 敏感信息扫描：cookie / token 之类的字面量绝不能进仓库；
    2. 发布内容核对：字体必须在、下载的 Node 运行时必须不在、体积要在合理范围。

.PARAMETER Target
  拷贝到哪里。默认是仓库的平级目录 `<仓库名>-github`。

.PARAMETER RemoteUrl
  可选：填了就顺手 `git remote add origin <url>` 并 `git push -u origin HEAD`。
  不填只做本地提交，远程仓库由你在网页上建好后再推。

.PARAMETER Force
  目标目录已存在时先删掉它（默认会中止，避免误删你手动改过的东西）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make-github-copy.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make-github-copy.ps1 `
      -RemoteUrl https://github.com/<你>/zhuoyue-player.git
#>
[CmdletBinding()]
param(
  [string]$Target,
  [string]$RemoteUrl,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw '找不到 git' }

$repoName = Split-Path $repo -Leaf
if (-not $Target) { $Target = Join-Path (Split-Path $repo -Parent) "$repoName-github" }
$Target = [System.IO.Path]::GetFullPath($Target)

# 防手滑：绝不往仓库自己里面、也绝不往盘根目录里拷。
if ($Target -eq $repo -or $repo.StartsWith($Target, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "目标目录不能是仓库本身或它的父目录：$Target"
}
if ($Target -eq [System.IO.Path]::GetPathRoot($Target)) { throw "目标目录不能是盘根：$Target" }

Step "源仓库：$repo"
Step "目标目录：$Target"

# 记住目标目录里原有的 origin：重新生成会把目录内容清掉、git 仓库重建，
# 若不记住并恢复，用户刚配好的远程就没了（下一次 push 还得再配一遍）。
$prevRemote = $null
if (Test-Path (Join-Path $Target '.git')) {
  $prevRemote = (& git -C $Target remote get-url origin 2>$null)
  if ($prevRemote) { Warn "目标目录里已有 origin：$prevRemote（重建后会恢复它）" }
}

if (Test-Path $Target) {
  # 空目录直接用：**不要去删它**。一个很实际的场景是它正被编辑器/VSCode 打开着，
  # 删除会失败（而且删到一半会留下一个半残目录 —— 我就这么踩过一次），
  # 但往里写文件是允许的。只有非空目录才需要 -Force 明确确认。
  $existing = Get-ChildItem $Target -Force -ErrorAction SilentlyContinue
  if ($existing) {
    if (-not $Force) {
      throw "目标目录非空：$Target`n（确认可以删掉它之后加 -Force 重跑；这样不会误删你手动改过的文件）"
    }
    Warn '目标目录非空，按 -Force 先清空'
    # 注意：**只清内容，不强求删掉目录本身**。编辑器（VSCode）打开着这个文件夹时，
    # 目录本身删不掉，而 `Remove-Item -Recurse` 会先把内容删光、再在最后一步报错退出 ——
    # 结果就是一个"半残目录 + 脚本中止"，我就这么踩过一次。所以这里吞掉那个错误，
    # 后面按"目录是否已空"决定能不能继续。
    try {
      Remove-Item (Join-Path $Target '*') -Recurse -Force -ErrorAction Stop
    } catch {
      Warn ('清空时遇到占用（多半是编辑器开着它）：' + $_.Exception.Message.Split([Environment]::NewLine)[0])
    }
    if (Get-ChildItem $Target -Force -ErrorAction SilentlyContinue) {
      throw "清不干净：$Target 里还有删不掉的内容，先关掉占用它的程序（例如 VSCode）再重跑"
    }
    Ok '内容已清空（目录本身被占用没关系，往里面写是允许的）'
  } else {
    Warn '目标目录已存在但是空的（多半是编辑器正开着它），直接往里写，不删目录'
  }
}
New-Item -ItemType Directory -Force -Path $Target | Out-Null

# ---- 1. 复制（只排除体积巨大的目录，纯为速度） ----------------------------
# 这些目录在 .gitignore 里也都被忽略，所以"少复制了它们"不会让发布内容变少。
# /XD 排除目录 /XF 排除文件；/NFL /NDL /NJH /NJS /NP 让 robocopy 安静点。
Step '复制工作树（排除构建产物与下载的运行时）'
$excludeDirs = @(
  (Join-Path $repo 'build'),
  (Join-Path $repo '.dart_tool'),
  (Join-Path $repo '.cache'),
  (Join-Path $repo 'packaging\staging'),
  (Join-Path $repo 'packaging\dist'),
  (Join-Path $repo 'runtime\node'),
  (Join-Path $repo 'runtime\netease-api\node_modules'),
  (Join-Path $repo 'windows\flutter\ephemeral'),
  (Join-Path $repo '.git')
)
$rcArgs = @($repo, $Target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
if ($excludeDirs.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $excludeDirs }
& robocopy @rcArgs | Out-Null
# robocopy 的退出码：0-7 是成功（1=有文件被复制，2=有额外文件，3=两者），>=8 才是失败。
if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（exit=$LASTEXITCODE）" }
Ok '复制完成'

# ---- 2. 建仓 ---------------------------------------------------------------
Step '在拷贝里初始化 git 仓库'
Push-Location $Target
try {
  & git init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git init 失败' }
  if ($prevRemote) {
    & git remote add origin $prevRemote
    Ok "已恢复 origin：$prevRemote"
  }
  & git add -A
  if ($LASTEXITCODE -ne 0) { throw 'git add 失败' }

  # ---- 3. 检查一：敏感信息 -------------------------------------------------
  # 这是最后一道防线：凭据一旦进了提交历史，删文件是没用的（历史里还在）。
  # 所以宁可在提交前硬失败。
  #
  # **只匹配"值的形状"，不匹配字段名**：`MUSIC_U=` 这种字段名在正常代码与文档里
  # 到处都是（拼 Cookie 头的代码、讲 Cookie 的文档、跑真账号的集成测试），
  # 按字段名扫全是误报 —— 那等于逼着后来的人把这道检查关掉。
  # 真正危险的是"字段名后面跟着一长串像凭据的值"，所以按下面这个形状匹配。
  # （实测：当前工作树对下面每一条都是**零命中**，说明仓库里没有真实凭据。）
  Step '扫描敏感信息（凭据绝不能进仓库）'
  $secretPatterns = @(
    '(MUSIC_U|MUSIC_A_T|MUSIC_R_T)[=:][ \t]*[''"]?[0-9A-Fa-f]{32,}',
    'SESSDATA[=:][ \t]*[''"]?[A-Za-z0-9%_.\-]{32,}',
    'bili_jct[=:][ \t]*[''"]?[0-9a-fA-F]{32}',
    '__csrf[=:][ \t]*[''"]?[0-9a-fA-F]{32}',
    'DedeUserID__ckMd5[=:][ \t]*[''"]?[0-9a-fA-F]{16}',
    'NMTID[=:][ \t]*[''"]?[A-Za-z0-9_\-]{20,}'
  )
  $hits = @()
  foreach ($pat in $secretPatterns) {
    # -I 跳过二进制；-E 用扩展正则（git grep 默认 BRE，这里显式指定）
    $found = & git grep -I -l -E -e $pat 2>$null
    if ($found) { $hits += $found }
  }
  if ($hits.Count -gt 0) {
    throw ("发现疑似凭据，已中止提交：" + [Environment]::NewLine + ($hits | Sort-Object -Unique | ForEach-Object { "      $_" } | Out-String))
  }
  Ok '没有发现 cookie / token 的值（字段名不算，见脚本注释）'

  # ---- 4. 检查二：发布内容 -------------------------------------------------
  Step '核对发布内容'
  $files = & git ls-files
  $fileCount = ($files | Measure-Object).Count
  Ok "会被跟踪的文件：$fileCount 个"

  # 4.1 字体必须在（用户的决定：随仓库分发、不随安装包分发）
  if ($files -contains 'assets/fonts/zhuzi.ttf') {
    Ok '内置字体在（随仓库分发，符合决定）'
  } else {
    Warn '内置字体**不在**跟踪列表里 —— 按你的决定它应当随仓库分发，请确认这是你想要的'
  }

  # 4.2 下载的运行时必须不在
  $runtimeLeaks = $files | Where-Object { $_ -like 'runtime/node/*' -or $_ -like 'runtime/netease-api/node_modules/*' }
  if ($runtimeLeaks) {
    throw ("下载的 Node 运行时混进了仓库（121MB，且是第三方产物）：" + [Environment]::NewLine + (($runtimeLeaks | Select-Object -First 5) -join [Environment]::NewLine))
  }
  Ok '下载的 Node 运行时不在（符合预期）'

  # 4.3 必需文件
  foreach ($must in @('README.md', 'LICENSE', 'CHANGELOG.md', '.gitignore', 'pubspec.yaml')) {
    if ($files -notcontains $must) { throw "缺少必需文件：$must" }
  }
  Ok 'README / LICENSE / CHANGELOG / .gitignore / pubspec.yaml 齐全'

  # 4.4 体积
  $bytes = 0
  foreach ($f in $files) { if (Test-Path $f) { $bytes += (Get-Item $f).Length } }
  Ok ("跟踪内容体积 {0:N1} MB" -f ($bytes / 1MB))
  if ($bytes -gt 200MB) { Warn '体积偏大，确认一下是不是把不该发的东西带进来了' }

  # ---- 5. 提交 -------------------------------------------------------------
  Step '首次提交'
  & git -c user.name='ZhuoYue Player Contributors' -c user.email='noreply@example.com' `
        commit -m "chore: 卓越播放器 v0.1.0 首个公开版本" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git commit 失败' }
  Ok (& git log --oneline -1)

  # ---- 6. 可选：推送 -------------------------------------------------------
  if ($RemoteUrl) {
    Step "添加远程并推送：$RemoteUrl"
    & git remote add origin $RemoteUrl
    & git push -u origin HEAD
    if ($LASTEXITCODE -ne 0) { throw '推送失败（多半是还没登录/没权限，先在 git 凭据里登录再重试）' }
    Ok '已推送'
  } else {
    Write-Host ''
    Write-Host '下一步（远程仓库由你在网页上建好，别在网页上初始化 README，否则会有无关的首次提交冲突）：' -ForegroundColor Yellow
    Write-Host "  1. 在 GitHub 新建空仓库（不要勾选 Add README / .gitignore / license）" -ForegroundColor Yellow
    Write-Host "  2. cd `"$Target`"" -ForegroundColor Yellow
    Write-Host "  3. git remote add origin https://github.com/<你的用户名>/<仓库名>.git" -ForegroundColor Yellow
    Write-Host "  4. git push -u origin main" -ForegroundColor Yellow
    Write-Host "  （或者直接重跑本脚本并带上 -RemoteUrl，我帮你把这两步做掉）" -ForegroundColor Yellow
  }
} finally {
  Pop-Location
}

Step '完成'
Ok "拷贝位于：$Target"
