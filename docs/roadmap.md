# 路线图

v1 交付目标是 **Windows 桌面**上的「第三方网易云 + Bilibili 收藏音乐」播放器。里程碑按可独立验收的阶段切分；每个阶段的「完成」定义是清单全部勾上，且不引入非目标里的东西。

| 里程碑 | 主题 | 关键交付 | 状态 |
| --- | --- | --- | --- |
| M0 | 环境与骨架 | 工具链可用、依赖可解析、无边框窗口能跑起来 | 进行中 |
| M1 | 主题系统 | Monet 取色 + 4 种窗口材质 + 令牌体系 | 规划中 |
| M2 | 网易云接入 | 内嵌运行时 + 登录 + 发现/歌单/搜索/歌词 | 规划中 |
| M3 | 播放器与下载 | 播放引擎、队列、播放页、封面缓存、下载 | 规划中 |
| M4 | Bilibili | 扫码登录、收藏夹、DASH 音轨、跨源队列 | 规划中 |
| M5 | 打磨与发布 | 无障碍、错误面、设置、打包、构建记录 | 规划中 |
| M6+ | Android（后续） | 平台端口 + 系统动态色 | 非本期 |

## M0 环境与骨架

- [ ] Flutter 3.47.6 / Dart 3.13.5 与 VS 2022（桌面 C++ 工作负载）+ Windows 10 SDK 10.0.26100 验证通过。
- [ ] `pubspec.yaml` 全部依赖可解析（pub 走镜像），`flutter pub get` 无冲突。
- [ ] `scripts/fetch-runtime.ps1` 幂等可重跑，产物落在 `runtime/`，冒烟测试 `/search` 返回 `code=200`。
- [ ] `window_manager` 无边框窗口可显示、可拖拽、可最小化/最大化/关闭，几何信息能恢复。
- [ ] CMake 在构建时把 `runtime/` 复制到 exe 同级，安装目录可独立启动。
- [ ] `.gitignore` 覆盖 `runtime/`、`.cache/`、`build/`、`.dart_tool/`、`windows/flutter/ephemeral/`。
- [ ] 目录骨架（`core/data/features/app`）与 `analysis_options.yaml` 落地，`flutter analyze` 零告警。

非目标：本阶段不做任何主题取色、不做接口调用 UI、不做播放。

## M1 主题系统

- [ ] Monet 管线：`QuantizerCelebi.quantize` → `Score.score(desired: 4, cutoff: 1)` → `Hct` 种子色；112px 降采样；封面 URL 归一化 + 缓存。
- [ ] 主题组装：`ColorScheme.fromSeed(dynamicSchemeVariant:, contrastLevel:)`，`ZhyColorVariant` 暴露 9 种变体、`ZhyContrastLevel` 4 档，切换不重新取色。
- [ ] `MaterialYouSource` 抽象就位（本期实现「封面 Monet」与「自定义」，预留「系统动态色」）。
- [ ] 种子色 → `ColorScheme` → `ThemeData`，全链路无魔法数字（非颜色令牌进 `ZhyTokens` 这个 `ThemeExtension`）。
- [ ] 4 种窗口材质：实色 / 亚克力（`ACCENT_ENABLE_ACRYLICBLURBEHIND` 或 `DWMSBT_TRANSIENTWINDOW`）/ Mica（`DWMSBT_MAINWINDOW` / `DWMSBT_TABBEDWINDOW`）/ 模拟磨砂（渐变 + 模糊 + 噪点），不可用时自动降级。
- [ ] `DWMWA_USE_IMMERSIVE_DARK_MODE`、`DWMWA_WINDOW_CORNER_PREFERENCE`、`DWMWA_BORDER_COLOR` 按主题生效。
- [ ] 自研 HSV + Hex 取色器，实时预览，落盘遵循「松手才写」。
- [ ] 透明窗口前提验证：`setBackgroundColor(Colors.transparent)` + `Scaffold(backgroundColor: Colors.transparent)`，亚克力可见。

非目标：不做动态壁纸取色、不做壁纸采样（那是 Mica 由 OS 完成的事）；不做主题导入导出。

## M2 网易云接入

- [ ] `NeteaseRuntime`：惰性启动、`ZHUOYUE_API_READY <port>` 握手、30s 健康探测、退出时优雅关闭、端口冲突自愈、错误码可读化。
- [ ] 二维码登录全流程（key → create → check 轮询 → cookie 落盘），以及 `/login/status` 恢复登录态。
- [ ] Cookie 由 Dart 侧拥有：逐请求以 `cookie` 参数下发，退出登录清空。
- [ ] 发现页：`/personalized`、`/top/playlist`、`/recommend/songs`（未登录时的空态与提示）。
- [ ] 歌单页：`/user/playlist`、`/playlist/detail`、`/playlist/track/all`（分页）。
- [ ] 搜索页：`/search`（单曲/歌单）、`/search/default` 占位词。
- [ ] 歌词：`/lyric`（原文 + 翻译），时间轴解析与高亮。
- [ ] 红心：`/likelist` 打标 + `/song/like` 切换。
- [ ] `/song/download` 的可用性验证（本表标注「待验证」），确认后再决定下载实现路径。

非目标：不做私人 FM、不做云盘、不做歌单编辑/创建、不做评论与动态。

## M3 播放器与下载

- [ ] `AudioEngine` 抽象 + `JustAudioEngine`（`just_audio` + `just_audio_windows`）实现，全局单实例。
- [ ] 队列：顺序/单曲/随机，上一首/下一首，`Song` 源无关。
- [ ] `MusicRepository.resolveUrl`：`/song/url/v1` 的 `level` 选择与 `url == null` 的明确提示。
- [ ] 播放页：封面、标题/歌手、进度拖动、音量、播放模式、歌词联动。
- [ ] 迷你播放条 + 队列面板。
- [ ] 封面磁盘缓存（自研，URL→哈希、LRU 清理、内存层），**不引入** `cached_network_image`/`sqflite`。
- [ ] 下载：`/song/url/v1` + `dio.download` 流式落地，`file_selector` 选目录，进度/取消/重试。
- [ ] 窗口标题/任务栏与当前曲目联动。

非目标：不做音频可视化频谱、不做均衡器、不做唱片风格皮肤市场。

## M4 Bilibili

- [ ] 扫码登录（`qrcode/generate` + `qrcode/poll`），`SESSDATA`/`bili_jct`/`DedeUserID` 落盘，`nav` 校验登录态（Cookie 续期列为后续增强）。
- [ ] 收藏夹：`x/v3/fav/folder/created/list-all` → `x/v3/fav/resource/list` 分页；未登录仅公开夹可见，私有夹给出明确提示。
- [ ] 音轨解析：视频走 `x/player/playurl`（`fnval=16`）取 `dash.audio[]` 按 `bandwidth` 选轨 + `backupUrl` 兜底；音频区走 `audio/music-service-c/url`（参数与结构按「待验证」结论落地）。
- [ ] 播放地址请求**强制**带 `Referer: https://www.bilibili.com` 与浏览器 UA，音频流 GET 同样携带。
- [ ] 播放地址不持久化；每次播放前解析，过期/403 时重解析一次并 seek 回原位置。
- [ ] 跨源队列：网易云曲目与 Bilibili 曲目可混排、可拖动排序，来源角标正确。
- [ ] 失效条目（`data.invalid`）与 `-403`/`-412` 的差异化提示与退避。

非目标：不做视频画面播放、不做弹幕、不做评论/投币/追番、不做直播、不做 WBI 签名的全量接入（按需再说）。

## M5 打磨与发布

- [ ] 三档对比度与高对比度模式实测通过（正文 ≥ 4.5:1，大字 ≥ 3:1）。
- [ ] 键盘操作（空格播放/暂停、方向键 seek、焦点顺序）与 `Semantics` 标签补全。
- [ ] 统一错误面：服务未启动、网络失败、无版权/需会员、未登录、接口异常，各有明确文案与出路（重试/登录/查看日志）。
- [ ] 设置页：取色来源、variant、对比度、明暗模式、窗口材质、缓存清理、下载目录、账号管理、诊断日志导出。
- [ ] 日志脱敏（不打印 `MUSIC_U`/`SESSDATA`/`__csrf`），日志轮转与体积上限。
- [ ] 发布构建：`flutter build windows --release`，验证干净机器（无 Flutter/Node 环境）可启动、`runtime/` 就位、体积可接受（约 100 MB 运行时）。
- [ ] README 的「构建记录」表填入首行真实数据，四份文档与本版实现对齐。

非目标：不做自动更新器、不做安装包签名与商店上架、不做崩溃上报服务。

## Android（后续阶段）

Android 排在本期之后，但**现在就要为它留出接口**，否则将来要动播放器与主题两条主链路。

| 现在必须抽象 | 位置 | 为 Android 预留什么 |
| --- | --- | --- |
| `MaterialYouSource` | `core/theme/material_you_source.dart` | 桌面实现返回封面 Monet/自定义色；Android 实现改为读取系统动态色（`dynamic_color` 或平台通道）。上层 `ThemeController` 不感知来源差异 |
| `AudioEngine` | `core/audio/audio_engine.dart` | 桌面用 `just_audio_windows`；Android 用 `just_audio` 的 ExoPlayer 实现，或整体换 `media_kit`（接口不变） |
| `MediaSource` + `Song` | `core/model/` | 新增音源只加枚举值与仓库，不改队列与播放页 |
| 窗口材质 | `app/window/window_material.dart` | 桌面走 Win32；Android 侧为空实现或映射到系统模糊，调用点不变 |
| 存储路径 | `core/storage/paths.dart` | 桌面用 `path_provider` 的桌面实现；Android 需换成应用私有目录，不散落硬编码路径 |
| 输入形态 | 各 feature 的 Widget | 悬停/右键菜单/键盘快捷键必须可降级为触屏长按，避免把桌面交互写死在业务里 |
| 下载与文件选择 | `core/download/`、`file_selector` | 桌面是任意目录；Android 需走 SAF，因此下载层不直接持有 `File` 路径假设 |

Android 阶段的非目标：手机端适配平板分屏、后台播放的服务化（`audio_service`）留到该阶段再评估。
