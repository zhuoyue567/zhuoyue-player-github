# 开发指南

面向本仓库的日常开发：环境、命令、内嵌 Node 运行时的准备与重建、调试手段、代码规范、故障排查。

## 1. 环境

| 组件 | 版本 / 要求 | 校验命令 |
| --- | --- | --- |
| Flutter | 3.47.6 stable | `flutter --version` |
| Dart | 3.13.5（随 Flutter） | `dart --version` |
| Visual Studio | Community 2022 17.14，勾选「使用 C++ 的桌面开发」 | 见下 |
| Windows 10 SDK | 10.0.26100 | 见下 |
| PowerShell | 7.x（`pwsh`） | `pwsh -v` |
| 目标平台 | Windows 10/11 x64 | `flutter devices` 应列出 `Windows (desktop)` |

```powershell
# 桌面工具链自检（Flutter 会直接告诉你缺什么）
flutter doctor -v

# VS 安装的工作负载与 SDK
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include"
```

VS 缺「使用 C++ 的桌面开发」时，`flutter build windows` 会在 CMake configure 阶段报找不到 `cl.exe` 或 `WindowsTargetPlatformVersion`。

### 网络环境（本机实测）

| 目标 | 可达性 | 应对 |
| --- | --- | --- |
| `github.com`、`raw.githubusercontent.com` | **不可达（已封锁）** | 选型规避（见下）；必要时用 `gh-proxy.com` / `ghfast.top` 代理前缀 |
| `pub.dev`、`pub.flutter-io.cn` | 可达 | 设置 pub 镜像 |
| `registry.npmmirror.com` | 可达 | npm 走该 registry |
| `nodejs.org` | 可达 | 运行时 Node 从这里下载并做 SHA256 校验 |
| `gitee.com` | 可达 | 备用代码/资源镜像 |

```powershell
# 建议常驻环境变量（用户级）
[Environment]::SetEnvironmentVariable('PUB_HOSTED_URL', 'https://pub.flutter-io.cn', 'User')
[Environment]::SetEnvironmentVariable('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn', 'User')
```

**选型层面已经规避了 GitHub**：音频用 `just_audio_windows`（C++/WinRT 源码随 pub 包本地编译），不用 `media_kit`（其 `media_kit_libs_windows_audio` 会在 CMake configure 时从 GitHub Releases 下载预编译 libmpv，本机必然失败）。因此**不要**为了「试试看」而引入任何在构建期下载 GitHub 产物的依赖。

## 2. 常用命令

```powershell
# 依赖
flutter pub get
flutter pub upgrade --major-versions   # 谨慎：会动 material_color_utilities 等锁定版本

# 静态检查与格式化
flutter analyze
dart format lib test

# 测试
flutter test                     # 全量
flutter test test/unit/monet_test.dart   # 单文件

# 运行（调试）
flutter run -d windows
flutter run -d windows --verbose   # 需要看原生构建/插件注册细节时

# 发布构建
flutter build windows --release
# 产物：build\windows\x64\runner\Release\
#   zhuoyue_player.exe
#   flutter_windows.dll、插件 dll、data\flutter_assets\
#   runtime\  ← 由 CMake 复制（见下）

# 清理
flutter clean; flutter pub get
```

首次 `flutter build windows` 会编译 `just_audio_windows`、`window_manager`、`file_selector_windows`、`screen_retriever_windows` 的原生部分，耗时明显长于后续增量构建。

## 3. 内嵌 Node 运行时

### 3.1 准备

```powershell
pwsh -File scripts/fetch-runtime.ps1
```

脚本幂等：已存在的部分会跳过，`-Force` 强制重装。可用参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-NodeLine` | `latest-v22.x` | nodejs.org 的版本行目录 |
| `-Registry` | `https://registry.npmmirror.com` | npm registry 覆盖 |
| `-NeteaseVersion` | `4.32.0` | `NeteaseCloudMusicApi` 版本 |
| `-Force` | 关 | 重新下载 Node、重装依赖、覆盖 launcher |

产物与副作用：

```
runtime/
├─ node/                     node.exe + npm（便携版 win-x64）
└─ netease-api/
   ├─ package.json           仅声明 NeteaseCloudMusicApi@4.32.0
   ├─ node_modules/          从 npmmirror 安装
   └─ launcher.js            每次运行脚本都会重写（内容内嵌在脚本里）

.cache/                      下载缓存与冒烟日志（gitignored）
├─ node-v22.x.x-win-x64.zip  复用，避免重复下载
├─ runtime-smoke.log         冒烟测试 stdout（含 ZHUOYUE_API_READY <port>）
└─ runtime-smoke.err.log     冒烟测试 stderr
```

脚本末尾自带冒烟测试：拉起 `node launcher.js`，等待就绪行，然后请求 `/search?keywords=周杰伦&limit=1`，要求 `code == 200`。

### 3.2 运行期位置

| 场景 | Flutter 端查找路径 |
| --- | --- |
| `flutter run -d windows`（调试） | 从 exe 目录**向上回溯**找到 `runtime/`（要求里面有 `node/` 与 `netease-api/`），所以仓库根的 `runtime/` 能被找到 |
| 便携版 | 同上：exe 同级或上溯能找到的 `runtime/` |
| 安装版 | 安装目录里**不带** runtime（安装包不含它）。应用在首次启动时下载到应用数据目录，之后从那里加载；运行时缺失时的提示由应用给出 |

> **纠错（原文这里是错的，留个记号免得有人照着旧描述去找代码）**：先前这份文档说"CMake 在构建时把 `runtime/` 复制到 exe 同级"—— **`windows/CMakeLists.txt` 里没有这条规则**，只有 `install(TARGETS …)` / `install(FILES …)`，不会复制 `runtime/`。发布路线已经改成"应用首次启动时下载运行时"，所以也不再需要它。相关事实见 `packaging/README.md`，以及 `docs/checklist.md` 里标为 ❌ 的那一条。
>
> 同理，原文说"缺失时 UI 提示执行 `fetch-runtime.ps1`"也已经过期：那是**开发期脚本**，安装后的用户没有仓库；现在提示改成了可在应用内下载或手动放置。

### 3.3 改了 Node 侧之后怎么重建

`launcher.js` 的内容写在 `scripts/fetch-runtime.ps1` 里（here-string），不要直接改 `runtime/netease-api/launcher.js` —— 下次跑脚本会被覆盖。

```powershell
# 1) 改 scripts/fetch-runtime.ps1 里的 launcher here-string
# 2) 重跑脚本：Node 与依赖会跳过，launcher.js 一定被重写
pwsh -File scripts/fetch-runtime.ps1
# 3) 让构建产物同步：重新构建（CMake 会再复制 runtime/）
flutter build windows --release
# 或者调试时手动同步到调试输出目录
Copy-Item -Recurse -Force runtime "build\windows\x64\runner\Release\runtime"
```

要换 `NeteaseCloudMusicApi` 版本：`pwsh -File scripts/fetch-runtime.ps1 -Force -NeteaseVersion 4.32.0`（或目标版本），然后重建。

## 4. 调试

### 内嵌服务

```powershell
# 手动起服务并观察就绪行（前台运行，Ctrl+C 退出）
$env:ZHUOYUE_HOST = '127.0.0.1'
& runtime\node\node.exe runtime\netease-api\launcher.js

# 另开一个窗口：拿到端口后直接验证接口
Invoke-RestMethod "http://127.0.0.1:<port>/search?keywords=周杰伦&limit=1" | Select-Object code
Invoke-RestMethod "http://127.0.0.1:<port>/song/url/v1?id=347230&level=exhigh" | ConvertTo-Json -Depth 4
```

- App 内：设置 → 诊断，可查看内嵌服务的 stdout/stderr 摘要与当前 baseUrl；`stderr` 里的 `[zhuoyue]` 前缀行定位问题最快。
- 日志文件在 `path_provider` 的应用支持目录下的 `logs/`（窗口客户区日志、服务输出、接口错误各一份）。
- 退出码含义：`2` 加载 API 失败、`3` 版本不兼容（无 `serveNcmApi`）、`4` 启动抛错、`5` 60s 未就绪、`1` 其他。看到 `3` 说明 `package.json` 里的版本和 launcher 期望的导出不一致。

### Flutter 侧

```powershell
flutter run -d windows --verbose          # 原生构建、插件注册、平台通道
flutter run -d windows --dart-define=ZHUOYUE_LOG=debug   # 打开调试日志等级
```

- 插件没注册（如音频无声、`window_manager` 报 MissingPluginException）时，先看 `windows/flutter/generated_plugin_registrant.cc` 是否包含该插件，再 `flutter clean` 重建。
- 亚克力/模糊看不到时，先确认窗口背景是透明的（`window_manager.setBackgroundColor(Colors.transparent)` 且 `Scaffold` 透明），再确认 OS 侧 API 调用返回值。
- 性能：`flutter run --profile -d windows` 配合 DevTools 看帧时间；取色管线的解码与量化已经在独立 isolate（`compute(..., debugLabel: 'monet-extract')`）里跑，若仍卡帧，先确认降采样到 112px 是否生效、缓存是否命中。

## 5. 代码规范

- Lint：`flutter_lints ^6.0.0`（`analysis_options.yaml`），提交前 `flutter analyze` 必须零 issue。
- 格式：`dart format`（默认 80 列不便阅读长表时，用行尾换行而非超标），CI 未启用，靠本地执行。
- 命名：文件 `snake_case.dart`；类 `UpperCamelCase`；颜色走 `ColorScheme`，尺寸/模糊/动画等非颜色常量集中在 `ZhyTokens`（`ThemeExtension`），禁止在组件里写魔法数字。
- 分层：严格遵守 `features → data → core`，`core` 不得 import `data`/`features`。
- 状态：Riverpod 的 `Notifier` / `AsyncNotifier`（3.x API）。**不要**使用已移除的 `StateNotifier`/`StateProvider` 写法。
- 网络：所有 HTTP 走 `dio` 的封装客户端（统一超时、重试、错误映射、日志脱敏），禁止在 Widget 里直接 `dio.get`。
- 日志：用 `core/utils/logger.dart`，禁止 `print`；日志不得包含 `MUSIC_U`、`SESSDATA`、`__csrf` 等凭据。
- 注释：解释「为什么」，不解释「是什么」；中文注释可以，公共 API 用 `///`。

## 6. 故障排查

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| GitHub 不可达 / 构建时要下 GitHub 产物 | 引入了在构建期下载 GitHub Releases 的依赖（典型：`media_kit_libs_windows_audio`） | 本项目已选 `just_audio_windows` 规避；不要新增此类依赖。若必须访问，使用 `gh-proxy.com` 或 `ghfast.top` 前缀代理，或改从 gitee 取 |
| 依赖解析失败（`flutter pub get` 卡住/超时/版本不兼容） | 未设 pub 镜像；或某依赖 pin 了旧 `win32`（如 `flutter_acrylic` 固定 5.x，与 `win32 ^6.4.0` 冲突） | 设置 `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL`；删除 `pubspec.lock` 后重试；冲突时不要降级 `win32`，改用自研 FFI 层；`material_color_utilities` 保持 `^0.13.0`（由 Flutter SDK 锁定） |
| 亚克力/Mica 不生效（纯色或黑块） | Flutter 表面不透明；OS 不支持该效果（Win10 旧版、远程桌面、系统「透明效果」关闭）；`DWMWA_SYSTEMBACKDROP_TYPE` 需要 Win11 22H2+ | 确认 `Scaffold(backgroundColor: Colors.transparent)` 与 `setBackgroundColor(Colors.transparent)`；Win10 走 `SetWindowCompositionAttribute`（`ACCENT_ENABLE_ACRYLICBLURBEHIND`）路径；仍失败则切「模拟磨砂」；`ACCENT_POLICY.GradientColor` 是 **AABBGGRR** 字节序，写反会得到错色 |
| 播放无声 | 系统输出设备/独占模式；`just_audio_windows` 未注册；URL 403（Bilibili 缺 Referer/UA）；歌曲无版权导致 `url == null` | 先用系统播放器验证同一 URL；检查 `generated_plugin_registrant.cc`；Bilibili 请求补 `Referer` + 浏览器 UA；`song/url/v1` 的 `url` 为 `null` 时按「需会员/无版权」提示，不是播放器问题 |
| 内嵌服务起不来 | `runtime/` 未准备或未复制到 exe 同级；端口探测失败；杀软拦截 `node.exe`；版本不兼容（退出码 3）；60s 未就绪（退出码 5） | 跑 `pwsh -File scripts/fetch-runtime.ps1`；确认 exe 同级有 `runtime\netease-api\launcher.js`；手动前台运行 launcher 看 stderr；加杀软白名单；版本不符时 `-Force` 重装依赖 |
| 网易云接口返回 `code` 非 200 | `301` 未登录、`400` 参数错、`404`/`url==null` 无版权或需会员、`406`/`429` 频率限制、服务未就绪导致连接被拒 | `301` 跳登录；`404` 明确提示不可播放；`406`/`429` 退避重试一次；连接被拒时触发一次惰性重启并看日志。日志里记录路径、参数与响应体前 512 字符（脱敏后） |
| 切歌卡顿 | 大图封面在解码/量化 | 取色已跑在独立 isolate；确认降采样到 112px 生效、`coverUrl` 缓存命中（同图不重算） |
| 取色结果与旧教程代码对不上 | `material_color_utilities` 0.13 起 `Quantizer.quantize` 变成异步并返回 `QuantizerResult`（直方图在 `colorToCount`），`Score.score` 仍吃 `Map<int,int>` | 按 `lib/core/theme/monet.dart` 的写法：`await QuantizerCelebi().quantize(pixels, maxColors)` 后传 `quantized.colorToCount`；不要照抄 0.11/0.12 的同步 `Map` 写法 |
| 主题不跟随封面变化 | 取色缓存键未随封面 URL 变化；`MaterialYouSource` 处于「自定义」模式 | 归一化封面 URL（去掉 `?param=` 尺寸差异）后再做键；检查 `theme.source` 设置值 |
| 哔哩收藏夹报「请求参数错误」 | `fav/resource/list` 的 `ps` **硬上限是 40**，`ps=41` 即 `code=-400`，而报错文案只有「请求错误」 | 已在 `BilibiliRepository._fetchTracks` 里 `clamp(1, 40)`，不要在调用方绕过它；见 [api-integration.md](api-integration.md) 的 2.2 节 |
| **截图里某个控件"没渲染"** | 截图脚本没声明 DPI 感知：`GetWindowRect`/`ClientToScreen` 返回虚拟化坐标，而 `CopyFromScreen` 按物理像素采样，两套坐标系混用会让画面整体错位（本机 150% 缩放下约 170 px），表现为底部被裁、右侧一列控件消失 | `scripts/capture-window.ps1` 已在最前面调用 `SetProcessDPIAware()` 并用 `GetClientRect` + `ClientToScreen` 取客户区。**先怀疑截图工具，再去查渲染代码** —— 这次为此白查了很久，最后是打印 `localToGlobal` 才确认控件一直都在正确位置 |
| 无交互桌面上无法用合成鼠标点击验证界面 | 非交互会话里 `SetCursorPos`/`mouse_event` 送不到窗口（连点几下，截图完全一样） | 用 Debug 专用环境变量直接摆初始状态：`ZHY_DEBUG_SECTION=settings\|discover\|bilibili\|search\|downloads`、`ZHY_DEBUG_QUEUE=1`、`ZHY_DEBUG_NOWPLAYING=1`、`ZHY_DEBUG_DUMP=1`（打印 widget 树）。仅 `kDebugMode` 生效 |
| 无法用"真实登录态"验证解析/播放 | `flutter test` 里没有 `shared_preferences` 插件（`MissingPluginException`），`TestWidgetsFlutterBinding` 又会把所有 HTTP 变成 400 | **直接读本机真实 prefs 文件**：`%APPDATA%\com.zhuoyue\zhuoyue_player\shared_preferences.json` 里的 `flutter.netease.cookie`，赋给 `NeteaseApiClient.cookie`（公开字段）即可带上真实登录态。**注意**：① 不要调 `TestWidgetsFlutterBinding.ensureInitialized()`，否则 HTTP 全 400；② `SharedPreferences` 仍需 `setMockInitialValues` 才拿得到实例；③ 临时脚本跑完即删，cookie 不要打印 |
| 「大部分歌曲播放失败」这类"整片失败"的报告 | 单曲失败和**状态被旧操作污染**在界面上长得一模一样 | 先用真实账号跑一遍解析层：拉歌单 → 逐首 `resolveStream` → 统计失败率与原因。实测 30 首里 28 首正常（27 首无损），失败 2 首都是"已下架" —— 于是可以确定问题**不在解析层**，而在播放器状态机（连续选曲时被取代的那次 `load` 抛 `PlayerInterruptedException`，其失败覆盖了当前曲目的状态）。`lib/features/player/player_controller.dart` 用 `_loadToken` 丢弃过期加载的结果 |
| 「某个区块上沿被压暗了一块」 | `GlassPanel` 的高光曾是 `LinearGradient(白→透明, stops:[0,0.12])`，也就是**顶部 12% 高度的一块亮区**，到 12% 处戛然而止。因为它随面板高度缩放，面板越大越像"上半部分被压暗"；又完全由我们自绘，所以挪窗口不会消失 | 已改为顶部 1.2px 的细亮线（并左右淡出）：真实玻璃折射出的是**亮边**而不是亮区。见 `lib/core/ui/glass.dart` |
| 窗口缩不小 / 尺寸比设定值大一圈 | 把 `window_manager` 的尺寸当成了物理像素并乘了 `devicePixelRatio`（起因是用 DPI 不感知的脚本量尺寸，读到虚拟化坐标） | Windows 上它就是**逻辑像素**，直接传即可，不要做 DPI 换算。`lib/app/window_bootstrap.dart` 里有详细说明 |
| 取消收藏/切歌后播放条音质显示与选择不符 | 服务端按会员权益静默降级 | 这是**预期行为**：`ResolvedStream.qualityLabel` 记录的是服务端实际给的档位，界面照实显示；不要把它改成"用户选的档位" |

排查通用顺序：① 窗口/插件层（`flutter doctor`、plugin registrant）→ ② 内嵌服务（前台手动跑 launcher，看就绪行）→ ③ 接口（直接 `Invoke-RestMethod` 打内嵌服务）→ ④ UI（DevTools 看状态与重建）。
