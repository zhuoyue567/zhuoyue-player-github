# 架构

ZhuoYue Player 是一个纯 Dart/Flutter 的 Windows 桌面应用，只有一个外部进程：由 App 自己拉起的**内嵌 Node 服务**（网易云接口）。Bilibili 接口由 Dart 直连，音频解码播放交给原生插件。本文描述分层、目录、数据流、内嵌进程生命周期与风险。

## 分层

四层，自上而下依赖，不允许反向：

| 层 | 目录 | 职责 | 允许依赖 |
| --- | --- | --- | --- |
| app | `lib/app/` | 启动引导、窗口与材质初始化、路由、主题注入、依赖装配（Provider 的顶层 override） | core、data、features |
| features | `lib/features/` | 每个功能一个目录：Widget + 控制器（Riverpod `Notifier`/`AsyncNotifier`）+ 该功能私有的展示模型 | core、data |
| data | `lib/data/` | 接口客户端与仓库：HTTP 调用、DTO ↔ 领域模型映射、内嵌进程管理、Cookie 存取 | core |
| core | `lib/core/` | 与业务无关的能力：`Song`/`MediaSource` 模型、`AudioEngine` 抽象、Monet 取色、Win32 材质封装、缓存、日志、工具 | 无（只依赖第三方包与 Flutter SDK） |

**依赖规则（硬性）**

- `features → data → core`，**永不反向**：`core` 里不得出现 `Song` 之外的网易云/Bilibili 概念，也不得 import `data` 或 `features`。
- 跨功能复用一律下沉：两个 feature 都要用的 Widget 放 `lib/core/widgets/`，仓库方法放 `data/repositories/`。
- `app` 是唯一允许同时看见三层的模块，它只做装配与路由，不写业务逻辑。
- 强制手段：`analysis_options.yaml` 无法直接表达分层，因此靠 review + 目录约定；新增跨层 import 必须在 PR 描述里说明理由。

## 目录树

```
zhuoyue-player/
├─ lib/
│  ├─ main.dart                      # ★ 入口（当前仍是 Flutter 模板，待接 app/bootstrap）
│  ├─ app/
│  │  ├─ app.dart                    # 根 Widget：MaterialApp.router + 主题 + 本地化
│  │  ├─ bootstrap.dart              # 启动时序：窗口初始化 → 恢复几何 → 预加载设置 → 启动 API
│  │  ├─ router.dart                 # 路由表（播放页、歌单页、Bilibili 页、设置页）
│  │  ├─ providers.dart              # 顶层 Provider 装配与 override 点（便于测试注入假实现）
│  │  ├─ window/
│  │  │  ├─ window_controller.dart   # 封装 window_manager：无边框、拖拽区、最小/最大/关闭
│  │  │  └─ geometry_store.dart      # 窗口位置/尺寸/最大化状态的持久化与恢复
│  │  └─ theme/
│  │     ├─ theme_controller.dart    # 当前种子色、variant、对比度、明暗模式、材质模式的状态机
│  │     └─ theme_builder.dart       # ColorScheme（fromSeed）+ ZhyTokens → ThemeData
│  ├─ core/
│  │  ├─ model/
│  │  │  ├─ song.dart                # 统一歌曲模型（含 source、sourceId、可播放地址）
│  │  │  ├─ media_source.dart        # enum MediaSource { netease, bilibili, local }
│  │  │  ├─ album.dart               # 专辑/合辑
│  │  │  ├─ artist.dart              # 歌手
│  │  │  ├─ playlist.dart            # 歌单（网易云歌单 / Bilibili 收藏夹共用的展示模型）
│  │  │  ├─ lyric.dart               # 歌词行 + 时间戳
│  │  │  └─ page_result.dart         # 分页结果泛型（items + hasMore + cursor）
│  │  ├─ audio/
│  │  │  ├─ audio_engine.dart        # 抽象接口：load/setQueue/play/pause/seek/volume/position 流
│  │  │  ├─ just_audio_engine.dart   # 基于 just_audio + just_audio_windows 的实现
│  │  │  ├─ audio_engine_provider.dart # 单一 AudioEngine 实例的 Provider（全局唯一播放器）
│  │  │  ├─ playback_state.dart      # 播放状态快照（曲目、进度、缓冲、模式、音量）
│  │  │  └─ queue_controller.dart    # 队列：源无关，操作 Song 列表与当前索引
│  │  ├─ theme/                      # ★ 取色与主题基础设施（已落地）
│  │  │  ├─ monet.dart               # ★ MonetExtractor / MonetPalette：降采样→量化→打分
│  │  │  ├─ color_variant.dart       # ★ ZhyColorVariant（9 种变体）、ZhyContrastLevel（4 档）
│  │  │  ├─ color_utils.dart         # ★ ZhyColor：hex 解析/格式化、对比度、混色、透明与明暗调整
│  │  │  ├─ theme_tokens.dart        # ★ ZhyTokens extends ThemeExtension：模糊/描边/圆角/动画令牌
│  │  │  ├─ window_material.dart     # ★ ZhyWindowMaterial：亚克力/Mica/Mica Alt/模糊/模拟磨砂/实色
│  │  │  ├─ material_you_source.dart # 取色来源抽象：桌面=封面 Monet/自定义，Android 后续=系统动态色
│  │  │  └─ cover_palette_cache.dart # 封面 URL → MonetPalette 的内存/磁盘缓存（规划）
│  │  ├─ win32/
│  │  │  ├─ dwm.dart                 # DwmSetWindowAttribute：Mica、暗色标题栏、圆角、边框色
│  │  │  ├─ accents.dart             # SetWindowCompositionAttribute + ACCENT_* 结构体（亚克力/模糊）
│  │  │  ├─ win_utils.dart           # hwnd 获取、OS build 判定（22H2+）、特性探测
│  │  │  └─ ffi_bindings.dart        # win32/ffi 的动态库与函数签名集中声明
│  │  ├─ storage/
│  │  │  ├─ prefs.dart              # shared_preferences 的类型安全封装（键名常量化）
│  │  │  ├─ cover_cache.dart        # 自研封面磁盘缓存：URL→文件哈希、LRU 清理、内存层
│  │  │  └─ paths.dart              # path_provider 封装：缓存目录、下载目录、日志目录
│  │  ├─ download/
│  │  │  ├─ download_task.dart      # 下载任务模型（进度、状态、目标路径）
│  │  │  └─ download_manager.dart   # dio 流式下载 + 进度广播 + 取消/重试
│  │  ├─ utils/
│  │  │  ├─ logger.dart             # 统一日志（含内嵌服务 stdout/stderr 落盘）
│  │  │  ├─ duration_format.dart    # 时长/时间戳格式化
│  │  │  └─ result.dart             # 轻量 Result/Failure，避免到处 try-catch
│  │  └─ widgets/                   # 跨功能通用组件（封面、玻璃卡片、空态、加载骨架）
│  ├─ data/
│  │  ├─ netease/
│  │  │  ├─ netease_runtime.dart     # 内嵌 Node 进程：定位、启动、就绪握手、健康检查、退出
│  │  │  ├─ netease_client.dart      # dio 封装：baseUrl 动态端口、cookie 注入、统一解包
│  │  │  ├─ netease_endpoints.dart   # 路径常量表（见 docs/api-integration.md）
│  │  │  ├─ netease_dto.dart         # 接口 JSON → DTO（宽松容错，字段可空）
│  │  │  ├─ netease_mapper.dart      # DTO → Song/Playlist/Album/Artist/Lyric
│  │  │  ├─ netease_cookie_store.dart# Cookie 拥有者：读写 shared_preferences、请求时下发
│  │  │  └─ netease_repository.dart  # 业务方法：登录、歌单、推荐、搜索、歌曲地址、红心
│  │  ├─ bilibili/
│  │  │  ├─ bilibili_client.dart     # dio 封装：Referer/UA 默认头、cookie、错误码
│  │  │  ├─ bilibili_endpoints.dart  # 路径常量表（收藏夹、playurl、音频区 URL、登录）
│  │  │  ├─ bilibili_auth.dart       # 二维码登录：generate → 轮询 poll → 存 SESSDATA/bili_jct
│  │  │  ├─ bilibili_dto.dart        # 收藏夹/资源/播放地址 JSON → DTO
│  │  │  ├─ bilibili_mapper.dart     # DTO → Song（source=bilibili）、Playlist
│  │  │  └─ bilibili_repository.dart # 收藏夹列表、资源列表、音轨解析与过期重解析
│  │  └─ repositories/
│  │     ├─ music_repository.dart    # 源无关门面：按 MediaSource 分派，供 features 调用
│  │     ├─ playlist_repository.dart # 歌单/收藏夹的统一读取
│  │     └─ lyric_repository.dart    # 歌词获取与合并（含翻译/罗马音预留）
│  └─ features/
│     ├─ discover/                   # 基础发现：推荐歌单、每日推荐、榜单入口
│     ├─ playlists/                  # 歌单列表与详情、收藏歌单管理
│     ├─ bilibili/                   # Bilibili 登录、收藏夹浏览、音频区条目
│     ├─ player/                     # 播放页（封面、歌词、进度）、迷你播放条、队列面板
│     ├─ search/                     # 全局搜索（网易云 + Bilibili 收藏夹）
│     ├─ downloads/                  # 下载列表、进度、目录选择
│     └─ settings/                   # 主题设置（取色来源/variant/对比度/材质）、账号、缓存清理
├─ assets/images/                    # 图标与占位图（app icon、默认封面）
├─ scripts/
│  └─ fetch-runtime.ps1              # ★ 幂等拉取 Node + NeteaseCloudMusicApi + 写 launcher.js
├─ runtime/                          # 运行时产物（gitignore）：node/、netease-api/
├─ windows/                          # ★ 原生壳：CMake、runner、插件注册；复制 runtime/ 到 exe 同级
├─ test/                             # 单测与 Widget 测试（模型映射、Monet、队列逻辑优先）
└─ docs/                             # 本文档集
```

> 标 `★` 的是仓库里**已经落地**的文件（`lib/main.dart`、`lib/core/theme/` 下的 5 个文件、`scripts/fetch-runtime.ps1`、`windows/`），其余为**规划位**，按 [roadmap](roadmap.md) 的里程碑逐步落位；落位时如与规划路径不同，以实际代码为准并同步更新本文。

## 统一模型与音源无关

队列和播放器只认识 `Song` 与 `MediaSource`，不关心歌曲来自哪家平台：

```dart
enum MediaSource { netease, bilibili, local }

class Song {
  final String id;            // 平台内 id（本地文件为路径哈希）
  final MediaSource source;
  final String title;
  final List<String> artists;
  final String? albumName;
  final String? coverUrl;     // 本地文件为 null
  final Duration? duration;
  final String? localPath;    // 已下载或本地导入时有值

  /// 平台侧原始 id。网易云为数字 id，Bilibili 为 bvid 或 音频区 au id。
  final String sourceId;
}
```

约定：

- `AudioEngine.load` 接收的是**已解析出的可播放 URL**（或 `localPath`），解析由 `data` 层完成；播放引擎不做任何平台判断。
- `MediaSource` 决定 UI 细节（来源角标、能否下载、能否红心），但不影响播放路径。
- 新增音源 = 新增一个 `MediaSource` 值 + 一个仓库实现，`core/audio` 与播放页不改动。

## 数据流 ①：播放一首网易云歌曲

```
播放页点击曲目
  → PlayerController.play(song)                     (features/player)
  → QueueController 更新队列与当前索引                 (core/audio)
  → MusicRepository.resolveUrl(song)                (data/repositories)
  → NeteaseRepository.songUrl(id, level)            (data/netease)
  → NeteaseClient GET /song/url/v1?id=..&level=..    (dio → http://127.0.0.1:<port>)
       · 内嵌 Node 服务（首次调用时才启动，见下节）
       · 带上 Dart 侧持有的 Cookie
  → 解包 { code:200, data:[{ url, br, size, type }] }
  → AudioEngine.load(url) / setQueue(...)           (core/audio → just_audio_windows → MFT)
  → 同时：CoverCache 取封面字节（命中磁盘则跳过网络）
       → MonetExtractor.extractFromEncoded(bytes)     (core/theme/monet.dart，跑在 isolate)
       → MonetPalette.seedArgb → ThemeController 更新种子色（palette 进封面缓存）
       → theme_builder 重建 ColorScheme（fromSeed + variant/contrast）→ ThemeData 更新
  → 播放页/迷你条/亚克力背景同时收到新的 ColorScheme
```

要点：

- **取色与播放解耦**：封面变化是唯一触发 Monet 的信号；同一 `coverUrl` 的取色结果按 URL 缓存，切歌回退不重算。
- 播放地址拿不到（`code != 200`、无版权、VIP 限制）时，UI 明确显示原因，不静默失败。
- 主题更新走 Riverpod 的 `ThemeController`，`MaterialApp.router` 的 `theme` 随之重建；窗口材质层从 `ZhyWindowMaterial` + 当前 `ColorScheme` 取底色/边框色再下发给 Win32。

## 数据流 ②：播放 Bilibili 收藏

```
Bilibili 页
  → BilibiliRepository.folders()                    (data/bilibili)
  → GET x/v3/fav/folder/created/list-all?up_mid=<mid>
       · 未登录：仅 public 收藏夹可浏览（SESSDATA 为空时私有夹不可见）
  → 用户选择收藏夹 → resources(mediaId, page)
  → GET x/v3/fav/resource/list?media_id=..&pn=..&ps=20
  → 资源按类型分流：
       · 音频区条目 → GET audio/music-service-c/url?songid=..&quality=..
       · 视频条目   → GET x/player/playurl?bvid=..&cid=..&fnval=16
                     解析 DASH，从 audio[] 中按 bandwidth/id 选音轨
  → 得到音频流地址（有时效）
  → 关键请求头：Referer: https://www.bilibili.com + 桌面浏览器 User-Agent
       · 缺失 → 403；对播放地址本身的 GET 也必须带，否则被拒
  → 映射为 Song(source: MediaSource.bilibili, sourceId: bvid/au id)
  → AudioEngine.load(url)  —— 与流程 ① 完全相同的一个实例
```

要点：

- Bilibili 不走 Node 服务，全部由 `dio` 直连，因此**没有**第二个子进程。
- 播放地址会过期，`BilibiliRepository` 在 `AudioEngine` 报错（403/404）时**重新解析一次**再重试，不做无限重试。
- 收藏夹资源的 `coverUrl` 同样喂给 Monet 流程，两个音源的视觉体验一致。

## 内嵌 Node 服务生命周期

负责类：`data/netease/netease_runtime.dart`。

| 阶段 | 行为 |
| --- | --- |
| 定位 | 从 exe 所在目录找 `runtime/netease-api/launcher.js`；调试模式（`flutter run`）回退到仓库根 `runtime/` |
| 惰性启动 | **首次**发生网易云请求时启动（`LazyAsyncSingleton`）。只浏览设置页、只听本地文件时不启动进程 |
| 端口选择 | **由 Node 侧决定**：`launcher.js` 用 `net.createServer().listen(0)` 拿一个空闲 loopback 端口，Flutter 不猜、不预留 |
| 就绪握手 | Node 启动 API 后轮询 HTTP 探测自己，成功后向 stdout 打印**恰好一行** `ZHUOYUE_API_READY <port>`；Dart 逐行读取 stdout，只在看到这一行后才把 baseUrl 设为 `http://127.0.0.1:<port>`，超时 60s 抛可读错误 |
| 健康检查 | 就绪后周期性（30s）`GET /`；连续 3 次失败视为进程僵死 → 重启一次并重建 baseUrl |
| 端口冲突 | 不冲突：端口来自 `listen(0)`。若进程退出后端口被抢占，重启会重新选端口，Dart 端以新握手行覆盖 baseUrl |
| 优雅退出 | 监听 App 生命周期：窗口关闭/进程退出前先尝试 `kill(SIGTERM)`，2s 内未退出则强杀；同时 `stdout/stderr` 落盘到日志目录便于排查 |
| 异常退出 | 捕获 exit code：2=加载 API 失败、3=版本不兼容无 `serveNcmApi`、4=启动抛错、5=60s 未就绪；分别映射为不同的用户提示 |
| 版本与校验 | `scripts/fetch-runtime.ps1` 从 nodejs.org 下载 win-x64 便携版并校验 `SHASUMS256.txt` 的 SHA256；`NeteaseCloudMusicApi` 固定 4.32.0，从 `registry.npmmirror.com` 安装 |

体积代价要说清楚：`runtime/` 约 **100 MB**（`node.exe` 约 80 MB + API 及其依赖），会被复制到安装目录同级，安装包因此偏大。这是「网易云接口必须有 Node」这一约束下的既定取舍。

## 已知风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 网易云接口变更 / `NeteaseCloudMusicApi` 停更 | 登录、歌单、播放地址大面积失效 | 版本锁定 4.32.0 便于回滚；接口集中在 `netease_endpoints.dart`，改路径不动业务；`netease_dto.dart` 宽松解析，缺字段不崩 |
| Bilibili 播放地址 403 | 无法播放 | 所有请求（含音频流 GET）强制带 `Referer: https://www.bilibili.com` + 浏览器 UA；失败时重解析一次并提示 |
| 播放地址过期 | 播放中途报错 | 播放前校验时效字段，失败即重解析；队列跳到下一首时同样重新解析 |
| `just_audio_windows` 冷启动/首次播放延迟 | 首曲有可感知延迟 | 预热引擎实例；UI 先展示 loading 态；`AudioEngine` 抽象保留换 `media_kit` 的可能 |
| 亚克力/Mica 在部分系统不可用（Win10 旧版、远程桌面、关闭透明效果） | 窗口变成黑块或纯色 | 启动时探测 OS build 与 `DwmSetWindowAttribute` 返回值；失败自动降级到「模拟磨砂」，并允许用户在设置里手动锁定实色 |
| 透明窗口 + 亚克力时文字对比度不足 | 可读性差 | 表面色带 alpha 且叠加 surface tint；文字使用 `ColorScheme.onSurface` 并保证对比度等级（见 [theme-system](theme-system.md)） |
| 内嵌 Node 被杀软拦截 / 端口探测失败 | 网易云功能整体不可用 | 启动超时给明确文案与「查看日志」入口；Bilibili 与本地播放不依赖 Node，仍可用 |
| `runtime/` 未准备就启动 | 网易云请求全部失败 | 启动时探测 `launcher.js` 是否存在，缺失则在 UI 顶部提示执行 `pwsh -File scripts/fetch-runtime.ps1` |
| GitHub 不可达 | 依赖装不上、构建失败 | 音频插件选型已规避（见 [development](development.md) 排查表）；pub 走 `pub.flutter-io.cn`，npm 走 `registry.npmmirror.com` |
| 第三方接口的合规风险 | 账号或法律风险 | 限速、不做批量抓取、不绕过付费/版权；不可播放内容明确提示（见 [api-integration](api-integration.md) 合规说明） |
