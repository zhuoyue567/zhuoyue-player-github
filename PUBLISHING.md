# 上传与发布清单

这个仓库可以直接上传 GitHub（`scripts\make-github-copy.ps1` 就是干这个的：它把工作树复制到
一个平级目录、在那里 `git init` + 提交，发布内容完全由 `.gitignore` 决定）。

## 上传源码（4 步）

1. 在 GitHub 新建一个**空**仓库 —— **不要**勾选 Add README / .gitignore / license
   （勾了会产生一次无关的首次提交，push 时会冲突）
2. 生成拷贝（一条命令）：

       powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make-github-copy.ps1

   它会在提交前做三道检查：**凭据扫描**（cookie/token 的值，字段名不算）、**发布内容核对**
   （内置字体必须在、下载的 Node 运行时必须不在、README/LICENSE/CHANGELOG/.gitignore 必须齐）、
   以及体积报告。任何一道不过就中止，不会先提交再说。
3. 在拷贝里加远程并推送：

       cd ..\zhuoyue-player-github
       git remote add origin https://github.com/<你的账号>/<仓库名>.git
       git push -u origin main

## 发布 Release（两个附件）

打标签 `v0.1.0` 并新建 Release，上传这两个文件（都在源仓库的 `packaging\dist\` 下）：

| 文件 | 大小 | 是什么 |
| --- | --- | --- |
| `zhuoyue-player-0.1.0-setup.exe` | 约 11 MB | 安装包（不含 Node 运行时、不含内置字体） |
| `runtime-v1.zip` | 约 48 MB | 首次启动时下载的运行时（Node + 网易云接口服务，已合并打包） |

## 上传前必做的一步

应用里"首次启动下载运行时"的地址与校验和默认是**空的**（`kRuntimeArchiveUrl` /
`kRuntimeArchiveSha256` 都是 null），所以那个按钮会**禁用并说明原因** —— 这是刻意的：
地址错了要显式失败，不能猜一个然后失败得莫名其妙。

填它只需一条命令（**哈希会自动从 `runtime-v1.zip` 算**，不需要手抄）：

    powershell -File scripts\configure-runtime-download.ps1 -Owner <你的账号> -Repo <仓库名>

然后**重新构建安装包**（Dart 常量会进 AOT 快照，不重建等于没改）：

    powershell -File scripts\build-installer.ps1

再重新生成一次拷贝（让源码里也带上这两个常量），然后 push。

**建议顺序**：建空仓库 -> 填地址 -> 重建安装包 -> 生成拷贝 -> push -> 上传两个附件。

改了 `runtime/` 的话，运行时包要重出：`scripts\build-runtime-archive.ps1`（它会重新校验
压缩包里的关键条目并给出新的 URL/哈希两行）。

## 常用命令

    flutter test                                        # 全量测试
    dart analyze lib test                               # 静态检查
    powershell -File scripts\build-installer.ps1        # 出安装包（先做 release 构建）
    powershell -File scripts\build-runtime-archive.ps1  # 出运行时包
    powershell -File scripts\make-github-copy.ps1       # 生成用于上传的独立拷贝
    powershell -File scripts\fetch-runtime.ps1          # 开发期：准备本地 runtime/

## 打包与安装器的取舍

见 `packaging\README.md`：为什么按用户安装、为什么安装包不含 Node 运行时与内置字体、
安装时选的三个路径怎么通过 `installer.json` 交给应用。