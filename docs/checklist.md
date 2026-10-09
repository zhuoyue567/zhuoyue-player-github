# 功能查验清单

打开这份文档 → 逐条对照 → 打勾。

所有条目都对应仓库里真实存在的东西（代码 / 测试 / 脚本）。**写不出验证动作的条目不写**；不确定的一律标注
`⚠️ 未确认`，而不是断言它存在。

---

## 1. 怎么用这份清单

### 1.1 状态标记的含义

| 标记 | 含义 | 你该怎么验 |
| --- | --- | --- |
| ✅ | **已实现，且有自动化测试覆盖** | 跑 `flutter test` 即可；「验证动作」列给出测试文件名与用例名，用 `flutter test <文件>` 单独复跑。不需要你手工点界面。 |
| 🟡 | **已实现，但只有人工能验** | 自动化测不到（真实窗口、真实桌面、真实网络、真实文件、观感）。「验证动作」列给出**具体操作步骤 + 期望结果**。 |
| ❌ | **未实现 / 已知缺失** | 代码里确实没有，或界面不可达。明细与原因见第 11 节「已知限制」。 |
| ⚠️ | **未确认** | 无法从代码或测试确证，需要读代码或人工确认后才能定性。 |

### 1.2 表格怎么读

- 每张表都有四列：**勾选 / 状态 / 条目 / 验证动作**。勾选列是 `- [ ]`，直接改成 `- [x]` 即打勾。
- 每个表格块里**第一条 ✅ 行一定会写出完整的测试文件路径**（例如 `flutter test test/monet_test.dart`）。后面的 ✅ 行若以 **「同上 → 「用例名」」** 开头，意思是：**跑本表格块第一条给出的那个测试文件，核对名为「用例名」的那条用例** —— 把命令换成 `flutter test <那个文件>`，输出里会逐条打印用例名，`+N` 就是它。
- 🟡 行**一定**给出「操作步骤 + 期望结果」，必要时附代码路径。
- ❌ 行的验证动作就是「到第 11 节查这条限制的原因与影响」。

### 1.3 环境前提

```powershell
cd E:\WorkSpace\zhuoyue-player
flutter --version                  # 期望 Flutter 3.47.6 stable / Dart 3.13.5
flutter pub get
pwsh -File scripts/fetch-runtime.ps1   # 准备 runtime/（幂等，已存在会跳过）
flutter run -d windows                  # 或 flutter build windows --debug 后直接跑 exe
```

只支持 **Windows 桌面**（仓库只有 `windows/` 平台目录），见 `pubspec.yaml` 与仓库根目录列表。

### 1.4 基线（先确认这两条，再往下勾）

```powershell
dart analyze lib test    # 期望：No issues found!（第 13.1 节给出了各时间点的实测）
flutter test             # 期望：All tests passed!（第 13.2 节给出了各时间点的实测数字，当前基线 241 passed / 11 skipped）
```

---

## 2. 窗口与材质

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | 六种窗口材质枚举，且「系统效果 / 自绘效果」划分正确 | `flutter test test/window_effects_test.dart` → group「ZhyWindowMaterial」两条。代码：`lib/core/theme/window_material.dart` |
| - [ ] | ✅ | 持久化的材质名字能跨版本还原，未知名字回落到 `acrylic` | 同上 → 「fromName 对未知输入回落到默认值」 |
| - [ ] | ✅ | 能读到真实的 Windows build number | `test/window_effects_test.dart` → 「能读到真实的 Windows build number」。代码：`lib/core/window/window_effects.dart`（`RtlGetVersion`） |
| - [ ] | ✅ | 能力判定与 build number 自洽（22000=Mica / 22621=backdrop / 17134=亚克力） | 同上 → 「能力判定与 build number 自洽」 |
| - [ ] | ✅ | 系统描述文案可读（`Windows 11 (build N)` 之类） | 同上 → 「label 能给出可读的系统描述」 |
| - [ ] | ✅ | 没有真实窗口时取句柄失败但不抛异常 | 同上 → 「在没有真实窗口的环境里，取句柄失败但不抛异常」 |
| - [ ] | ✅ | 直接调用应用材质时安全失败（不会抛） | 同上 → 「直接应用材质时也安全失败（不会抛）」 |
| - [ ] | 🟡 | **亚克力真的能透出桌面壁纸** | 设置 → 窗口材质 → 「亚克力」。把窗口拖到桌面壁纸/资源管理器之上，期望：能看见后面的内容、且在窗口内被模糊、在窗口外保持清晰。代码：`lib/core/window/window_effects.dart`（`applyMaterial`）+ `lib/app/window_bootstrap.dart`（`setBackgroundColor(Colors.transparent)`）+ `lib/features/shell/app_shell.dart`（`Scaffold(backgroundColor: Colors.transparent)`） |
| - [ ] | 🟡 | Mica / Mica Alt 在 Win11 22H2+ 生效；不支持时给出**明确降级文案** | 设置 → 窗口材质，鼠标停在「Mica」卡片上，期望：不支持时卡片下方出现红字限制（如「需要 Windows 11，当前会改用亚克力」）；选它之后材质区顶部出现黄色降级说明条。代码：`lib/features/settings/settings_page.dart`（`_MaterialCard._limitation`、`applied?.note` 展示区）+ `lib/core/window/window_providers.dart`（`appliedBackdropProvider`） |
| - [ ] | 🟡 | **模拟磨砂自绘生效**（封面渐变 + 实时模糊 + 噪点），不依赖系统效果 | 设置 → 窗口材质 → 「模拟磨砂」，期望：窗口不透明、有封面色的模糊底 + 细噪点；把「磨砂强度」拉到 0 与 80，期望模糊程度明显变化。代码：`lib/core/ui/window_backdrop.dart`（`_SimulatedBackdrop`）+ `lib/core/ui/glass.dart`（`ZhyNoise` / `NoiseOverlay`） |
| - [ ] | 🟡 | 系统圆角生效（`DWMWA_WINDOW_CORNER_PREFERENCE`） | 启动后看窗口四角是否为圆角（`lib/app/window_bootstrap.dart` → `WindowEffects.setRoundedCorners(true)`）。期望：四角圆润，没有直角黑边。 |
| - [ ] | 🟡 | 深色标题栏随明暗模式切换（`DWMWA_USE_IMMERSIVE_DARK_MODE`） | 设置 → 外观模式 → 切「浅色」/「深色」，期望：系统标题栏区域的明暗跟随（`lib/core/window/window_effects.dart` → `setImmersiveDarkMode(dark)`） |
| - [ ] | 🟡 | 边框色交回系统决定（`DWMWA_BORDER_COLOR` = `DWMWA_COLOR_NONE`） | 观察窗口最外圈细线是否随系统主题变化，而不是写死某个颜色。代码：`WindowEffects.applyMaterial` → `setBorderColor(null)` |
| - [ ] | 🟡 | **初始窗口 1240×800 且居中** | 启动应用，期望：窗口约 1240×800 逻辑像素、屏幕居中。代码：`lib/app/window_bootstrap.dart`（`kInitialWindowSize`）。⚠️ 注意 `window_manager` 在 Windows 上收发的**就是逻辑像素**，不要按物理像素去核对 |
| - [ ] | 🟡 | **最小尺寸 900×560 生效** | 拖窗口右下角往内缩，期望：缩到约 900×560 就停住，界面不出现溢出条纹。代码：`kMinimumWindowSize` |
| - [ ] | 🟡 | 无边框但**保留系统缩放边框**（边缘可拖动改尺寸） | 把鼠标移到窗口边缘，期望：光标变成缩放箭头且能拖动。代码：`WindowOptions(titleBarStyle: TitleBarStyle.hidden)` |
| - [ ] | 🟡 | 标题栏整条（含空白处）都能拖动窗口 | 按住标题栏上「标题文字」与「搜索框」之间的空白拖动，期望窗口跟着动。代码：`lib/features/shell/title_bar.dart`（`Positioned.fill(child: WindowDragRegion())`）+ `lib/core/ui/window_drag_region.dart` |
| - [ ] | 🟡 | 最小化 / 最大化（图标随状态切换为「向下还原」）/ 关闭三个窗口按钮可用 | 依次点三个按钮。期望：最小化后任务栏可还原；最大化后中间按钮变成「向下还原」图标且 tooltip 变「向下还原」；关闭按钮悬停变系统红底白字。代码：`lib/features/shell/title_bar.dart`（`_CaptionButton`、`onWindowMaximize` / `onWindowUnmaximize`） |
| - [ ] | 🟡 | 标题栏搜索框可提交关键词并跳到搜索页，且有清空按钮 | 在标题栏搜索框输入「晴天」回车，期望：切到「搜索」分区并出结果；输入内容后出现清空按钮。代码：`title_bar.dart`（`_buildSearchBox`）+ `lib/features/shell/app_shell.dart`（`_onSearch`） |
| - [ ] | 🟡 | **正常关闭：窗口先消失，再收尾；2 秒硬性截止** | 打开「维护 → 调试日志」保持可见，点关闭，期望：窗口几乎立刻消失；日志里出现 `[app] 窗口已隐藏（Nms）`。代码：`lib/features/shell/app_shell.dart`（`_shutdownAndExit`，先 `windowManager.hide()`，再 `Timer(2s, exit(0))`） |
| - [ ] | 🟡 | **正常关闭后没有残留 `node.exe`** | ① 先让网易云发一次请求（进「发现音乐」）；② `Get-Process node -ErrorAction SilentlyContinue` 记下 PID；③ 点关闭；④ 等 2 秒再跑一次 `Get-Process node -ErrorAction SilentlyContinue`，期望：本次启动拉起的那个 `node.exe` 已不存在。代码：`lib/core/runtime/embedded_netease_api.dart`（`stop(waitForExit: false)` 发 TERM+KILL） |
| - [ ] | 🟡 | 关闭时若收尾超时，也会在 2 秒内强制退出（不会「点了关闭无响应」） | 同上，观察日志里是否出现 `[app] 硬性截止触发，强制退出`（正常情况不该出现） |
| - [ ] | 🟡 | 「窗口背景不透明度」滑杆 0.30~1.00 生效并持久化 | 设置 → 窗口材质，拖动「背景不透明度」，期望：窗口通透度实时变化；重启后仍是该值。代码：`lib/features/settings/settings_page.dart`（`_SettingSlider`）+ `lib/core/theme/theme_settings.dart`（`windowOpacity`，键 `theme.windowOpacity`） |
| - [ ] | 🟡 | 「磨砂强度」滑杆 0~80 生效 | 同上，期望：模拟磨砂与玻璃面板的模糊半径变化。代码：`theme_settings.dart` → `blurSigma`（键 `theme.blurSigma`） |
| - [ ] | 🟡 | 「面板染色强度」滑杆 0%~90% 生效 | 同上，期望：玻璃面板底色浓度变化（越低越通透）。代码：`theme_settings.dart` → `panelOpacity`（键 `theme.panelOpacity`） |
| - [ ] | 🟡 | 「用封面做磨砂底色」开关生效 | 关掉它，期望：模拟磨砂底从封面图换成主题色渐变。代码：`settings_page.dart` → `setCoverBackdrop`；`lib/core/ui/window_backdrop.dart`（`useCover`） |
| - [ ] | 🟡 | 「切歌时背景淡入」开关生效 | 打开时切歌，期望背景交叉淡入；关掉后切歌背景瞬间跳变。代码：`lib/core/ui/window_backdrop.dart`（`animate` / `animationKey`） |
| - [ ] | ❌ | ~~侧边栏底部显示当前系统的材质能力文案~~ | **已移除**：`_SidebarFooter` 连同「账号登录」按钮一起删掉了（版本号是排查用的，设置页「窗口材质」分区里已有系统与材质状态）。这条留在这里是为了说明"以前有、现在没有"，别照着旧版界面找一个不存在的元素。 |
| - [ ] | 🟡 | 任务栏进度条跟随播放进度，暂停/无曲目时消失 | 播放一首歌，切到别的窗口看任务栏图标，期望有进度；播放位置 <1% 或 >99.9% 时不显示。代码：`app_shell.dart`（`windowManager.setProgressBar`） |
| - [ ] | 🟡 | 窗口标题跟随当前曲目（任务栏 / Alt+Tab 可见） | 播放一首歌，期望标题变成 `歌名 — 艺人`；停止后回到「卓越播放器」。代码：`app_shell.dart`（`ref.listen<Song?>(currentSongProvider, ...)`） |
| - [ ] | ✅ | 窗口材质名字等设置项跨版本还原 | `flutter test test/theme_settings_test.dart` → 「窗口材质与配色变体的名字能跨版本还原」 |
| - [ ] | ❌ | **窗口几何记忆**（位置 / 尺寸 / 最大化状态） | 未实现：`lib/` 下没有任何 `setPosition` / `getPosition` / 几何持久化代码，`window_bootstrap.dart` 每次都用固定的 `kInitialWindowSize` + 居中 |

---

## 3. 主题系统

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | 纯色封面能取回该颜色的色相（Monet 主管线） | `flutter test test/monet_test.dart` → 「纯色封面能取回该颜色的色相」。代码：`lib/core/theme/monet.dart`（降采样 112px → Celebi 量化 → Score 打分） |
| - [ ] | ✅ | 大面积白底上的小块彩色会被选为主题色（不是「出现最多」） | 同上 → 「大面积白底上的小块彩色会被选为主题色」 |
| - [ ] | ✅ | 空白输入 / 损坏图片字节返回 null 而不是抛异常 | 同上 → 「空白输入返回 null 而不是抛异常」「损坏的图片字节返回 null 而不是抛异常」 |
| - [ ] | ✅ | 候选色不足时 `gradientStops` 循环补齐 | 同上 → 「gradientStops 在候选色不足时会循环补齐」 |
| - [ ] | ✅ | `#RGB` / `#RRGGBB` / `#AARRGGBB` / 省略 `#` 都能解析；非法输入返回 null | `test/monet_test.dart` group「ZhyColor」→ 「解析各种写法的十六进制颜色」「非法输入返回 null 而不是抛异常」。代码：`lib/core/theme/color_utils.dart`（`ZhyColor.tryParseHex`） |
| - [ ] | ✅ | `toHexRgb` 与 `tryParseHex` 可往返 | 同上 → 「toHexRgb 与 tryParseHex 可以往返」 |
| - [ ] | ✅ | 对比度计算可用于断言前景/背景可读性 | 同上 → 「深色背景上给出浅色前景」。代码：`ZhyColor.contrastRatio` |
| - [ ] | ✅ | **主题设置的全部字段**（明暗模式 / 取色来源 / 自定义种子色 / 变体 / 对比度 / 窗口材质 / 三个滑杆 / 两个背景开关 / 字体 / 三个播放选项）都能存住并读回 | `flutter test test/theme_settings_test.dart` → 「全部字段都能存住并读回」 |
| - [ ] | 🟡 | 9 种配色变体（内容 / 色调点缀 / 保真 / 鲜艳 / 表现力 / 中性 / 单色 / 彩虹 / 水果沙拉） | 读 `lib/core/theme/color_variant.dart`（`ZhyColorVariant` 恰好 9 个枚举值）；再到设置 → 配色方案数卡片，期望 9 张 |
| - [ ] | 🟡 | 4 档对比度（标准 0.0 / 中等 0.5 / 高 1.0 / 柔和 −1.0） | 读 `lib/core/theme/color_variant.dart`（`ZhyContrastLevel` 恰 4 档）；再到设置 → 配色方案 → 对比度数 chip，期望 4 个，且每个带 tooltip 说明 |
| - [ ] | 🟡 | 深浅色三档（跟随系统 / 浅色 / 深色） | 设置 → 外观模式，期望恰好 3 个 chip（`lib/core/theme/theme_settings.dart` 的 `ZhyThemeMode`）；依次切换，期望整屏立刻切换明暗 |
| - [ ] | 🟡 | 10 个内置种子色预设（Material 紫 / 云音乐红 / 哔哩粉 / 海蓝 / 青柠 / 竹青 / 琥珀 / 玫瑰 / 夜紫 / 石墨） | 设置 → 主题色来源 → 自定义颜色，数圆形预设色点，期望 **10** 个；逐个悬停看 tooltip 名字。代码：`lib/core/theme/theme_settings.dart`（`kZhySeedPresets`） |
| - [ ] | ✅ | 「重置设置」之后所有主题字段回到默认值 | `flutter test test/theme_settings_test.dart` → 「reset 之后回到默认值」 |
| - [ ] | ✅ | 字体选择决定 `ThemeData.fontFamily` | `test/theme_settings_test.dart` → 「字体选择决定 ThemeData 的 fontFamily」「buildZhyTheme 会把 fontFamily 与令牌一起装进 ThemeData」 |
| - [ ] | ✅ | **组件级**文字样式都带上了全局字体族（按钮/顶栏/对话框/列表项/标签） | `flutter test test/theme_font_family_test.dart`（三条）：① 主题里每一处组件级样式都带字体族；② 选「系统默认」时不硬写字体族；③ 真实按钮从渲染树读回的 `fontFamily` 是 `Zhuzi`。【背景】`ThemeData(fontFamily:)` 只派生 `textTheme`，而组件级样式是**整体取代**而非合并，漏写 `fontFamily` 会让那段文字掉回系统默认字体 —— 真发生过的 bug：按钮用系统黑体、正文用内置竹石，看起来就是"字重不一样"。代码：`lib/core/theme/app_theme.dart`（`themed()`） |
| - [ ] | ✅ | 播放设置默认为「无缝衔接开、淡入淡出关」 | `test/theme_settings_test.dart` → 「播放设置默认为「无缝衔接开、淡入淡出关」」 |
| - [ ] | 🟡 | 自定义颜色区：预设圆点 + 色相/饱和度/明度滑杆 + `#RRGGBB` 输入**三处互通** | 设置 → 主题色来源 → 「自定义颜色」：① 点一个预设圆点，期望滑杆与输入框同步更新；② 拖动「色相」滑杆，期望预览方块与输入框同步；③ 在输入框输入 `#EC4141` 回车，期望滑杆跳到对应位置；④ 输入非法如 `#GG` 回车，期望退回当前值且不报错。代码：`lib/features/settings/settings_page.dart`（`_CustomColorPicker`） |
| - [ ] | 🟡 | 取色来源二选一（封面莫奈 / 自定义），说明文案随选择变化 | 同上，切换两个 ChoiceChip，期望下方说明文字变化、未选中侧的面板消失。代码：`_SeedSourceSection` + `theme_settings.dart`（`ZhySeedSource`） |
| - [ ] | 🟡 | 封面取色的**候选色带 + HCT 分量**真实展示 | 设置 → 主题色来源 → 「封面莫奈取色」，期望出现一排候选色块（可悬停看 hex）与一行 `种子色 #xxxxxx · HCT n° / n / n · 候选 N 色`。代码：`_PalettePreview` |
| - [ ] | 🟡 | **切歌时主题色真的跟着封面变** | 播放一首封面色很鲜明的歌（如封面色偏红），期望整个窗口（含标题栏图标渐变、按钮、玻璃面板）都染上该色；再切一首封面色完全不同的歌，期望整屏变色。代码：`lib/core/theme/theme_providers.dart`（`CoverPaletteNotifier` → `activeSeedArgbProvider`）+ `lib/core/ui/window_backdrop.dart`（`_syncCover` 把**同一份封面字节**喂给取色器，不重复下载） |
| - [ ] | 🟡 | 9 张变体卡片都带**真实色票预览**（用当前种子色现场算） | 设置 → 配色方案，期望每张卡片顶部有 5 个色块，切换变体时色块与整屏一起变。代码：`_VariantCard`（`ColorScheme.fromSeed(... dynamicSchemeVariant: variant.scheme)`） |
| - [ ] | 🟡 | 切换变体 / 对比度**不重新取色**（立即重建 ColorScheme） | 切变体后观察：不出现封面重新下载或取色耗时（无 loading），颜色立刻变化。代码：`theme_providers.dart`（变体只进 `buildScheme`） |
| - [ ] | 🟡 | 「跟随封面」模式下封面加载失败不会闪回默认紫 | 断网后切歌（封面取不到），期望主题色保持上一次的颜色而不是跳到 M3 默认紫。代码：`theme_providers.dart`（`CoverPaletteNotifier.updateFromBytes(null)` → `clear()`）。⚠️ 未确认：`clear()` 后 `activeSeedArgbProvider` 会回落到 `ZhyColor.fallbackSeedArgb`，与「保留上一次种子色」的说法是否一致需要读代码确认。 |
| - [ ] | 🟡 | 字体来源三档可选，每档带说明文案 | 设置 → 字体，切换「竹石（内置）/ 系统默认 / 自定义字体」，期望下方说明文字变化、选「自定义字体」时多出「字体文件 + 导入」一行。代码：`settings_page.dart`（`_FontSection`）+ `theme_settings.dart`（`ZhyFontSource`） |
| - [ ] | 🟡 | **导入本机 ttf/otf/ttc 并全局生效，重启仍生效** | 设置 → 字体 → 「自定义字体」→「导入」，选一个 `.ttf`。期望：① 提示「已应用字体「xxx.ttf」」；② 整屏（含标题栏、播放条、日志面板）字体立刻变成该字体；③ 关闭应用重开，仍是该字体（`lib/main.dart` 在 `runApp` 之前调 `ZhyFontLoader.restoreFromPreferences`）。代码：`lib/core/theme/font_loader.dart` |
| - [ ] | 🟡 | 字体预览块有 4 行真实样例（标题 / 中文小字 / 密集笔画 / 拉丁数字） | 设置 → 字体 → 预览块，期望看到「字体预览 · 卓越播放器」「中文小字：正在播放 发现音乐 …」「密集笔画：摩羯座 曦 鑫 龘 …」「Latin & digits: ZhuoYue Player 0123456789」。代码：`_FontSection` 预览 `Container` |
| - [ ] | 🟡 | 内置竹石字体随包分发：声明与实际文件都在 | `Test-Path assets/fonts/zhuzi.ttf` 期望 `True`；`Select-String -Path pubspec.yaml -Pattern 'zhuzi'` 期望命中 `- asset: assets/fonts/zhuzi.ttf`（family `Zhuzi`） |
| - [ ] | 🟡 | 「重置设置」按钮带确认对话框，且明确说明不影响队列与登录态 | 设置 → 维护 → 「重置设置」，期望弹「重置所有设置？」并写明「播放队列与账号登录状态不受影响」。代码：`_MaintenanceSectionState._resetAll` |
| - [ ] | 🟡 | 主题设置改动**即时生效并自动保存** | 改任意一项后立刻切换分区再切回，期望值仍是刚改的；重启后也仍在（`theme_settings.dart` 的 `save()` 走 `shared_preferences`） |

---

## 4. 账户

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | 设置页账户分区：一级标题 + 音源切换 + 二级标题都在 | `flutter test test/settings_page_test.dart` → 「账户分区：一级标题、音源切换与二级标题都在」。代码：`lib/features/settings/settings_page.dart`（`_AccountSectionCard`） |
| - [ ] | ✅ | 未登录时给出「登录」按钮，而不是只显示「未登录」 | 同上 → 「未登录时给出「登录」按钮，而不是只显示"未登录"」 |
| - [ ] | ✅ | 已登录时展示账号信息并提供「退出登录」入口 | 同上 → 「已登录时展示账号信息并提供退出入口」 |
| - [ ] | ✅ | 左侧导航「账户」位于「设置」**之前**，且账户管理页列出各音源 | `flutter test test/accounts_page_test.dart`（含"账户在设置之前"与"规划中音源按钮不可点"两条）。代码：`lib/features/shell/app_shell.dart`（`ShellSection`）+ `lib/features/account/accounts_page.dart` + `lib/features/account/account_catalog.dart` |
| - [ ] | 🟡 | 账户管理页里**规划中**的音源（QQ 音乐 / 酷狗 / NAS）显示为「规划中」且不可点 | 左侧导航「账户」，期望：网易云 / 哔哩哔哩两张卡可操作；QQ 音乐 / 酷狗 / NAS 显示「规划中」且按钮置灰（NAS 的按钮写「连接」，因为它没有账号可登）。**这是刻意不做成假支持的**：清单只登记了音源元数据，真正的接入需要各自实现 `MusicRepository`。 |
| - [ ] | 🟡 | 账户管理页里已登录音源可「刷新」与「退出登录」 | 左侧导航「账户」→ 已登录那张卡 →「刷新」应更新昵称/会员；「退出登录」后卡片回到「未登录」且提示已退出。代码：`accounts_page.dart` + `account_providers.dart`（`AccountNotifier.refresh` / `logout`） |
| - [ ] | 🟡 | 网易云**二维码**登录：key → create → 2 秒轮询 → 成功 | 左侧导航「账户」→ 网易云卡片 →「登录」（或设置 → 账户）。期望：出现二维码图片；用网易云 App 扫码后文案依次变成「等待扫码…」→「已扫码，请在手机上确认」→ 关闭弹窗并提示「网易云音乐 登录成功」。代码：`lib/features/account/login_dialog.dart`（`_startPolling` 2s）+ `lib/data/netease/netease_login.dart`（`NeteaseQrStatus` 801/802/803/800） |
| - [ ] | 🟡 | 二维码过期时提示「二维码已过期，请点击刷新」并可刷新 | 打开登录弹窗放 2 分钟以上，期望文案变化且「刷新二维码」按钮可用 |
| - [ ] | 🟡 | 网易云二维码图拿不到时退化成展示 URL 文本 | 断网或接口异常时打开登录弹窗，期望出现「二维码图片获取失败，可在浏览器打开以下链接完成登录」+ 链接文本。代码：`_QrFallback` |
| - [ ] | 🟡 | 网易云**手机号 + 密码**登录 | 登录弹窗下半部分输入手机号与密码 → 「登录」，期望登录成功并关闭弹窗、侧边栏账号卡片出现昵称。空输入时提示「请填写手机号与密码」。代码：`login_dialog.dart`（`_loginWithPassword`）+ `netease_login.dart`（`loginWithPassword`） |
| - [ ] | ❌ | 网易云**手机号 + 短信验证码**登录（界面入口） | 服务层有 `NeteaseLoginService.loginWithCaptcha`（`lib/data/netease/netease_login.dart`），但 `login_dialog.dart` 里没有任何调用点 —— 界面上不可达，因此用户侧等于未实现 |
| - [ ] | 🟡 | 哔哩哔哩**扫码登录** | 登录弹窗切到「哔哩哔哩」，期望出现自绘二维码（`lib/core/ui/qr_code_view.dart`）；用哔哩 App 扫码确认后提示「哔哩哔哩 登录成功」。代码：`login_dialog.dart`（`_buildBilibili`）+ `lib/data/bilibili/bilibili_login.dart`（86101/86090/86038/0） |
| - [ ] | 🟡 | 单次轮询失败不中断整个流程，但会把原因显示出来 | 故意在扫码过程中断网几秒，期望提示变成错误文案、恢复网络后继续轮询。代码：`login_dialog.dart`（`_pollOnce` 的 catch 只更新 hint） |
| - [ ] | 🟡 | 登录凭据（cookie）持久化，重启后自动恢复登录态 | 登录后完全退出应用再启动，期望侧边栏直接显示账号卡片而不是「未登录」。代码：`netease_login.dart`（键 `netease.cookie`）+ `bilibili_login.dart` + `account_providers.dart`（`build()` 里主动 `refresh()`） |
| - [ ] | 🟡 | 网易云请求逐条带 `cookie` 参数（不依赖 Node 侧会话） | 读 `lib/data/netease/netease_api_client.dart`：请求时把 `cookie` 作为参数下发；`bypassCache` 时带 `x-apicache-bypass` 头。人工可验：登录后重启内嵌服务（关掉应用里的 node 进程）再操作，登录态仍在 |
| - [ ] | 🟡 | **掉线提示**：凭据失效时主界面弹带「重新登录」动作的 SnackBar | 让哔哩登录态失效（把 `%APPDATA%\com.zhuoyue\zhuoyue_player\shared_preferences.json` 里的 `flutter.bilibili.cookie` 改成垃圾值后重启），期望：启动后弹「哔哩哔哩 登录已失效，请重新登录」+「重新登录」按钮。代码：`lib/features/shell/app_shell.dart`（`_listenAccountExpiry`）+ `lib/features/account/account_providers.dart`（`lastChangeWasExpiry`） |
| - [ ] | 🟡 | 主动退出登录**不**弹「登录已失效」 | 点「退出登录」，期望只弹「已退出网易云音乐账户」，不叠一条失效提示。代码：`account_providers.dart`（`logout()` 先把 `lastChangeWasExpiry` 清成 false） |
| - [ ] | 🟡 | 设置页哔哩未登录时**写明为什么会掉线** | 设置 → 账户 → 哔哩哔哩（未登录），期望出现二级行「为什么容易掉线」并说明 `SESSDATA` 有效期短 + 扫码拿不到 `ac_time_value`。代码：`settings_page.dart`（`_AccountSectionCardState` 里 `if (_source == MediaSource.bilibili)` 分支） |
| - [ ] | 🟡 | **按源切换账户设置**：顶部 ChoiceChip 切换，已登录一侧带对勾 | 设置 → 账户：切「网易云音乐」/「哔哩哔哩」，期望：一级标题变成「网易云音乐账户」/「哔哩哔哩账户」；已登录的一侧 chip 上带 `check_circle` 图标。代码：`_AccountSectionCardState`（`avatar` 分支） |
| - [ ] | 🟡 | 「刷新账号信息」按钮重新校验凭据并给结果提示 | 点「刷新」，期望弹「账户信息已更新：昵称」或「网易云音乐未登录或登录已失效」。代码：`_AccountSectionCardState._refresh` |
| - [ ] | 🟡 | 哔哩「收藏目标夹」选择（多个收藏夹时必须显式选） | 登录哔哩后，设置 → 账户 → 哔哩 → 「收藏目标夹」→「选择」，期望弹出收藏夹列表（带「N 首」），选中后提示「收藏目标夹已设为「xxx」」。未登录时提示「还没有可用的收藏夹，请先登录哔哩哔哩」。代码：`settings_page.dart`（`_BilibiliTargetFolderRow`）+ `lib/data/bilibili/bilibili_repository.dart`（`setTargetFolder` / `targetFolderId`） |
| - [ ] | 🟡 | 侧边栏账号卡片显示头像 / 昵称 / 会员标签 | 登录后看左上角卡片：期望圆形头像（无头像时显示人形图标）、昵称、原昵称下方是会员标签或「网易云音乐」；未登录时显示「未登录 / 登录后可同步歌单」。代码：`app_shell.dart`（`_AccountCard`） |
| - [ ] | 🟡 | 发现页顶部欢迎区：问候语随系统时间变化 | 把系统时间分别调到 3 点 / 9 点 / 12 点 / 15 点 / 20 点，期望问候语依次为「夜深了 / 早上好 / 中午好 / 下午好 / 晚上好」。代码：`lib/features/discover/discover_page.dart`（`_greeting`） |
| - [ ] | 🟡 | 发现页已登录时显示签名与「切换账号」 | 登录后看发现页顶部卡片，期望有签名（无签名时显示「欢迎回来，今天想听点什么？」）与「切换账号」按钮 |
| - [ ] | ❌ | 哔哩登录凭据**自动续期** | 未实现，且原理上做不到（扫码流程拿不到 `ac_time_value`）。详见第 11.5 节 |

---

## 5. 音源与浏览

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | `Song.uid` 跨音源唯一 | `flutter test test/monet_test.dart` → 「Song.uid 跨音源唯一」。代码：`lib/data/models/song.dart` |
| - [ ] | ✅ | 下载文件名去掉 Windows 非法字符 | 同上 → 「safeFileName 去掉 Windows 非法字符」 |
| - [ ] | ✅ | 空艺人列表有兜底文案（「未知艺人」） | 同上 → 「artistLabel 在空艺人列表时给出兜底文案」 |
| - [ ] | ✅ | 时长格式 `m:ss` / `h:mm:ss` / `--:--` | 同上 group「ZhyFormat」→ 「时长格式化」 |
| - [ ] | ✅ | 大数字用中文单位（`1.2万` / `3.4亿`） | 同上 → 「大数字用中文单位」 |
| - [ ] | ✅ | 字节数格式化（`1.2 MB`） | 同上 → 「字节数格式化」 |
| - [ ] | 🟡 | 三个源共用一个 `MusicRepository` 抽象与 `Song` 模型（播放器不感知音源） | 读 `lib/data/repositories/music_repository.dart`（`abstract interface class`）+ `lib/data/repositories/source_registry.dart`（`sourceRegistryProvider`）；人工：把网易云与哔哩的曲目混在同一个队列里顺序播放，期望都能出声且来源徽标正确 |
| - [ ] | 🟡 | 发现音乐：**每日推荐 / 新歌速递 / 新歌榜** 三个分区 | 打开「发现音乐」。期望：已登录时出现「每日推荐」（副标题「根据你的口味生成」）、「新歌速递」（「刚刚上架的新歌」）、「新歌榜」（「按地区实时更新」），每区右侧有「播放全部」。代码：`lib/data/netease/netease_repository.dart`（`discover` / `_dailyFeed` / `_songFeed`）+ `discover_page.dart`（`_FeedSection`） |
| - [ ] | 🟡 | 未登录时「每日推荐」给出明确空分区文案 | 退出登录后打开发现页，期望「每日推荐」副标题为「登录后根据你的口味生成」且不报错。代码：`_dailyFeed` |
| - [ ] | 🟡 | **单个分区失败只影响自己**：原因写进该区副标题，其余区照常展示 | 断网后重开发现页，期望三个分区都显示各自的错误原因，而不是整页空白。代码：`_songFeed` 的 `catch (MusicApiException)` → `subtitle: error.message` |
| - [ ] | 🟡 | 推荐歌单网格（`/personalized` + `/top/playlist` 去重合并） | 发现页往下滚，期望出现「推荐歌单」网格，卡片副标题形如 `创建者 · N 首`。代码：`discoverCollections`（两个接口 `Future.wait` + `seen` 去重） |
| - [ ] | 🟡 | 我的歌单：**「我喜欢的音乐」置顶** | 打开「我的歌单」，期望第一个就是「我喜欢的音乐」（特殊类型 `specialType == 5`），其余保持接口原顺序。代码：`netease_repository.dart`（`myCollections` 里 `[...favorites, ...others]`） |
| - [ ] | 🟡 | 未登录时「我的歌单」整页给登录引导，不留上次登录的残留 | 退出登录后打开「我的歌单」，期望左栏是「需要登录」+「登录」按钮、右栏是「xx账号未登录」，列表为空。代码：`lib/features/playlists/playlists_page.dart`（`_loadCollections` 未登录时清空 `_collections` / `_songs`） |
| - [ ] | 🟡 | 哔哩收藏夹列表可读，且「没有收藏夹 / 未公开」时是空列表而不是报错 | 打开「哔哩收藏」，期望左栏列出收藏夹；换一个没有收藏夹的账号，期望显示「还没有歌单」空态而不是错误页。代码：`lib/data/bilibili/bilibili_repository.dart`（`_foldersOf`：`data` 为 null 时容错成空列表） |
| - [ ] | 🟡 | 哔哩不登录也能浏览**公开**收藏夹 | 未登录状态打开「哔哩收藏」，期望给出登录引导；若要验公开夹，需在代码/调试环境用 `publicCollections(mid)`（`bilibili_repository.dart`），⚠️ 未确认：当前界面没有输入别人 mid 的入口 |
| - [ ] | 🟡 | **歌单一次取全**：打开歌单/收藏夹即取回完整曲目，「播放全部」覆盖整个歌单 | 打开一个 300+ 首的歌单，等同步结束后看底部文案「已经到底了 · 共 N 首」，N 应等于歌单真实首数（远大于 50）；点「播放全部」后打开队列，期望队列长度等于 N。代码：`netease_repository.dart`（`allCollectionTracks`，`limit: 500` 循环；网易云 `_playlistTracks` 多取一条判断 `hasMore`）+ `bilibili_repository.dart`（`allCollectionTracks` 按 40 顺序翻页） |
| - [ ] | 🟡 | 哔哩 `ps` 上限被夹在 1..40（`ps=41` 会 `code=-400`） | 读 `bilibili_repository.dart`：`maxPageSize = 40`，`collectionTracks` 与唯一的读取出口 `_fetchTracks` 各夹一次。人工：打开一个 300+ 首的哔哩收藏夹，期望能一次取全而不报「请求错误」 |
| - [ ] | 🟡 | 哔哩收藏夹分页信息来自 `has_more` / `media_count` | 同上，翻页时能正常收敛（不无限翻页） |
| - [ ] | 🟡 | 搜索：网易云走 `/cloudsearch`，结构不符时回退 `/search` | 搜索「晴天」，期望出结果；读 `netease_repository.dart`（`search`）确认回退逻辑存在 |
| - [ ] | 🟡 | 搜索：哔哩走 `/x/web-interface/wbi/search/type` 并做 WBI 签名，标题里的 `<em>` 高亮标签被剥掉 | 切到哔哩音源搜索「晴天」，期望曲目标题**不含** `<em class="keyword">` 字样。代码：`bilibili_repository.dart`（`search` + `stripHtmlTags`） |
| - [ ] | 🟡 | **搜索联想**：350ms 防抖 + 请求序号防乱序 | 在搜索页快速连打 `a`→`ab`→`abc`，期望只出现最终关键词的联想词，不出现「鬼影结果」（`abc` 的联想先回来后不被 `a` 的覆盖）。代码：`lib/features/search/search_page.dart`（`_debounceDuration = 350ms`、`_suggestSeq` / `_searchSeq`） |
| - [ ] | 🟡 | 联想面板最多显示 8 条，且点击能直接搜 | 同上，期望列表不超过 8 行；点一条后搜索框内容变成该词且开始搜索。代码：`search_page.dart`（`_buildSuggestions` → `suggestions.take(8)`） |
| - [ ] | 🟡 | 哔哩音源不提供联想词（返回空），且不弹错误 | 切到哔哩后输入关键词，期望不出现联想面板也不报错。代码：`bilibili_repository.dart`（`searchSuggestions` 直接返回空列表） |
| - [ ] | 🟡 | 搜索历史仅内存、最多 10 条、重复词提到最前、可清空 | 搜 11 个词，期望面板上只有 10 个 chip 且最新在最前；重复搜同一个词，期望它移到最前而不重复；点「清空」后期望清空。⚠️ 重启应用后期望历史为空（只放内存，不落盘）。代码：`search_page.dart`（`_history` / `_historyLimit = 10`） |
| - [ ] | 🟡 | 搜索音源切换条（网易云 / 哔哩哔哩） | 搜索页顶部有「搜索音源」+ 两个 ChoiceChip，切换后立刻重查。代码：`app_shell.dart`（`_SearchSourceBar`） |
| - [ ] | 🟡 | 搜索无结果时给出可操作文案 | 搜一个不存在的词，期望「没有找到「xxx」」+「换个关键词试试；如果是版权或会员曲目，音源可能确实给不出结果」。代码：`search_page.dart`（`_buildContent`） |
| - [ ] | 🟡 | 歌单详情页：滚到离底部 400px 预取下一页 + 显式「加载更多」+ 「已经到底了 · 共 N 首」 | 打开发现页的一张歌单，快速往下滚，期望不出现「白一下」；底部依次可能出现「正在加载更多…」/「加载更多」/「已经到底了 · 共 N 首」。代码：`discover_page.dart`（`_maybeLoadMore`、`_buildFooter`） |
| - [ ] | 🟡 | 翻页失败只在列表尾部提示，已加载内容保留；首屏失败才整块错误态 | 断网后在详情页点「加载更多」，期望列表尾部出现「加载更多失败：…」+「重试」，已加载的曲目仍在。代码：`discover_page.dart`（`_moreError` vs `_error`） |
| - [ ] | 🟡 | 快速切换歌单不会把上一个歌单的曲目串进当前列表 | 连续点左栏两个歌单（趁第一个还在加载），期望最终右栏只显示第二个歌单的内容。代码：`playlists_page.dart`（`_loadSongs` 里 `if (_selected?.uid != collection.uid) return;`） |
| - [ ] | 🟡 | 媒体代理：哔哩音频 CDN 的 `Referer`/`UA` 由 loopback 代理补齐，`Range` 原样透传 | 播放一首哔哩收藏里的视频稿件音频，期望能出声；拖动进度条期望能 seek（不是从头重下）。代码：`lib/core/audio/media_proxy.dart`（只绑 `127.0.0.1`，`proxiedUriFor` 对无自定义头的流直连） |
| - [ ] | ❌ | 歌单级「收藏」 | 代码里没有：`MusicRepository` 只有曲目级 `isLiked` / `setLiked`。点歌单头部的「收藏」按钮会弹「歌单收藏接口尚未接入…」（`discover_page.dart` / `playlists_page.dart` 的 `_explainFavorite`） |
| - [ ] | ❌ | 歌单编辑 / 创建 / 删除 | 未实现（`MusicCollection.isEditable` 只是标记，没有写操作入口） |
| - [ ] | ❌ | 私人 FM、云盘、评论 / 动态、直播 | 未实现（README 明确列为「不做」） |

---

## 6. 播放

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | **播放模式合并按钮**：一次点击在四种模式间循环，且 `shuffle`/`repeat` 始终自洽 | `flutter test test/player_controller_test.dart` → 「播放模式按钮：一次点击在四种模式间循环，且 shuffle/repeat 始终自洽」。代码：`lib/features/player/player_controller.dart`（`cyclePlaybackMode`） |
| - [ ] | ✅ | 淡入淡出开启：起播音量从 0 单调渐强到用户音量（不会把音量留在 0） | 同上 → 「淡入淡出开启时：起播音量从 0 渐强到用户音量」 |
| - [ ] | ✅ | 淡入淡出关闭：直接就是用户音量，没有渐变 | 同上 → 「淡入淡出关闭时：直接就是用户音量，没有渐变」 |
| - [ ] | ✅ | **临近曲尾就提前渐弱到 0**（不是等播完才降） | 同上 → 「临近曲尾时渐弱到 0（不是等播完才降音量）」 |
| - [ ] | ✅ | **单曲循环时不渐弱** | 同上 → 「单曲循环时不渐弱（那一遍结束会立刻重播同一首）」 |
| - [ ] | ✅ | 无缝衔接开启：会预解析下一首 | 同上 → 「无缝衔接开启时：会预解析下一首」 |
| - [ ] | ✅ | 无缝衔接关闭：只解析当前曲目 | 同上 → 「无缝衔接关闭时：只解析当前曲目」 |
| - [ ] | ✅ | 连续选曲时，被取代的那次加载失败**不污染**当前曲目状态 | 同上 → 「连续选曲：被取代的那次加载失败不得污染当前曲目状态」 |
| - [ ] | ✅ | 解析比下一次点击还慢时，过期的那次**不得去换流** | 同上 → 「解析比下一次点击还慢：过期的那次不得去换流，否则会顶掉新歌」 |
| - [ ] | ✅ | **实际**音质被写进播放状态（供播放条显示） | 同上 → 「实际音质被写进播放状态（供播放条显示）」 |
| - [ ] | ✅ | 音质档位顺序：索引越小档位越高；认不出的档位排在最低档之后 | `flutter test test/netease_quality_test.dart` → 「索引越小档位越高，认不出的档位排在最低档之后」。代码：`netease_repository.dart`（`_qualities` 7 档 + `qualityRank`） |
| - [ ] | ✅ | 自动档：连续 7 次只有免费档不动，**第 8 次才降级** | 同上 → 「连续 7 次「请求无损只给极高」上限不动，第 8 次才收到极高」 |
| - [ ] | ✅ | 中间夹一次「要到了」就清零计数，上限不降 | 同上 → 「中间夹一次「要到了」（实际==请求）就清零计数，上限不降」 |
| - [ ] | ✅ | 真实数据形态（27 首无损夹 1 首 320k）永不降级 | 同上 → 「这正是真实数据的形态：27 首无损之间夹 1 首 320k，永不降级」 |
| - [ ] | ✅ | 实际低于请求但高于免费档（请求 Hi-Res 只给无损）不算「没权益」 | 同上 → 「实际低于请求但高于免费档（请求 Hi-Res 只给无损）不算"没权益"」 |
| - [ ] | ✅ | 降级落点是**免费档（极高）**，不是本次实际拿到的档位 | 同上 → 「降到免费档而不是"这一次实际给的档位"：实际只有 128k 也收在极高」 |
| - [ ] | ✅ | 免费门槛是可传参数（换成 `higher` 时落点跟着变） | 同上 → 「免费门槛是参数：换成 higher 时落点跟着变」 |
| - [ ] | ✅ | 实际高于请求时按实际上抬，但越不过会员等级上限 | 同上 → 「实际高于请求时按实际上抬，但越过不了会员等级上限」 |
| - [ ] | ✅ | 认不出的档位（如 `jyeffect`）不参与判断 | 同上 → 「认不出的档位（例如沉浸声 jyeffect）不参与判断」 |
| - [ ] | ✅ | 自动档初始值：无记录时黑胶 VIP → 无损 | 同上 → 「无记录时等于按会员等级猜的档位：黑胶 VIP → 无损」 |
| - [ ] | ✅ | 自动档降级：连续 8 首只有极高才降，第 9 首请求的就是极高 | 同上 → 「连续 8 首只有极高才降级，第 9 首请求的就是极高」 |
| - [ ] | ✅ | 被单曲打断就重新计数 | 同上 → 「被单曲打断就重新计数：7 次极高 + 1 次无损 + 7 次极高仍不降级」 |
| - [ ] | ✅ | 降级与观测都写进日志（应用内日志面板抓的就是 `debugPrint`） | 同上 → 「降级与观测都写进日志（应用内日志面板抓的就是 debugPrint）」 |
| - [ ] | ✅ | 高于免费档的降级不写成「连续第 n 次」（计数与措辞一致） | 同上 → 「高于免费档的降级不写成"连续第 n 次"（计数与措辞要一致）」 |
| - [ ] | ✅ | 手动档位不受自动上限影响 | 同上 → 「上限已降到极高时，手动选无损仍然请求无损」 |
| - [ ] | ✅ | 手动档位的降级不会反过来改自动档上限 | 同上 → 「手动档位的降级不会反过来改自动档的上限」 |
| - [ ] | 🟡 | 音质文案：「自动（目标：X）」说的是**目标**而不是当前 | ① 设置 → 播放 → 音质，期望「自动」chip 文案形如 `自动（目标：无损）`；② 播放条上的音质胶囊显示的是**实际**拿到的档位（如 `极高`），点开可改。代码：`lib/features/settings/settings_page.dart`（`'自动（目标：${effective.label}）'`）+ `lib/features/player/playback_extras.dart`（`PlaybackQualityChip`） |
| - [ ] | 🟡 | 全屏播放页：**不透明**高斯模糊背景 + 主题色染色 + 噪点，后方歌单内容不会透上来 | 播放一首有封面的歌 → 点播放条右侧「全屏播放页」。期望：背景是重度模糊的封面色调，**不能**看见后面歌单的文字/分割线。代码：`lib/features/player/now_playing_page.dart`（`_ImmersiveBackdrop`：不透明 `scheme.surface` 兜底 + `sigma 96` 模糊 + 0.62/0.88 渐变） |
| - [ ] | 🟡 | **逐行歌词 + 当前行高亮 + 自动滚动居中**（二分定位） | 在全屏播放页播放一首有歌词的歌，期望：当前行加粗放大且用主题主色、翻译行跟随显示在主行下方，并且随播放推进自动滚到视口**垂直中央**。代码：`lib/features/player/lyric_view.dart`（`LyricView`；`lyricIndexAt` 二分；`lyricScrollOffsetFor` 用 `行号 × 行高` 算目标偏移）+ `lib/features/player/now_playing_page.dart`（`_LyricPanel` 只做接线） |
| - [ ] | 🟡 | **用户上滚后暂停自动跟随；滚回当前行附近恢复跟随并吸附回中心** | 播放中把歌词列表往上拖走几行，期望它**停在原地不再被拉回**；再往下滚到当前行大体回到屏幕中间，期望恢复跟随并自动把当前行吸到中央。代码：`lyric_view.dart`（`_autoFollow` / `_onScrollNotification` / `_restoreFollowIfCentered`，容差 `_centerToleranceRows = 1.5` 行） |
| - [ ] | 🟡 | 点击某一行歌词跳到该行时刻 | 点歌词中任意一行，期望播放位置跳到该行开始时间。代码：`lyric_view.dart`（`LyricView.onSeek` ← `now_playing_page.dart` 的 `_LyricPanel` 接 `PlayerController.seek`） |
| - [ ] | ✅ | 歌词字号够大（当前行 24 / 非当前行 17.5 / 译文 13） | `flutter test test/lyric_view_test.dart` → 「当前行字号明显更大，且放大后仍然垂直居中」「行高与字号同步」。三个字号是公开常量 `kLyricActiveFontSize` / `kLyricInactiveFontSize` / `kLyricTranslationFontSize`，与 `kLyricRowExtent`（56）**必须同步改**：行高要容得下"正文 + 译文"（24×1.25 + 13×1.2 = 45.6 < 56）。 |
| - [ ] | 🟡 | 歌词区上下有渐隐带（`kLyricFadeExtent = 60`，≈1.07 行高） | 看歌词列表最上/最下若干像素，期望文字逐渐淡出而不是硬切。代码：`lyric_view.dart`（渐隐带按"行高倍数"定，行高变大时必须跟着变大，否则相邻行会整行硬切进视野） |
| - [ ] | 🟡 | 「纯音乐，请欣赏」/「暂无歌词」占位（与「还在取歌词」的转圈**区分开**） | ① 播放一首纯音乐 → 期望「纯音乐，请欣赏」；② 播放一首真的没有歌词的歌 → 期望「暂无歌词」；③ 刚切歌、歌词还在取时 → 期望转圈。代码：`lyric_view.dart`（`loading` 与 `lyric.isEmpty` / `lyric.isPureMusic` 三分支）+ `lib/data/models/lyric.dart` |
| - [ ] | 🟡 | 歌词归属校验：切歌太快时上一首的歌词不会盖住新歌 | 快速连续点两三首不同的歌，期望歌词区最终显示的是当前曲目的歌词（而不是上一首的）。代码：`lyric_view.dart`（`CurrentLyricNotifier._load` 里比对 `currentSongProvider?.uid` 才写 `state`） |
| - [ ] | 🟡 | 全屏播放页有「歌词 / 队列 (N)」两个标签页，队列页可清空队列 | 在全屏播放页点「队列 (N)」标签，期望看到队列行；点右上「清空队列」期望队列清空。代码：`now_playing_page.dart`（`_RightPane`） |
| - [ ] | 🟡 | 全屏播放页保留窗口拖动区（进入沉浸页后窗口仍可拖） | 在全屏播放页按住顶部中间「正在播放」那一行左右拖动，期望窗口跟着动。代码：`now_playing_page.dart`（`_Header` 里的 `WindowDragRegion`） |
| - [ ] | 🟡 | 全屏播放页的进度条可拖动 seek，且拖动过程中不被回拽 | 在全屏播放页拖动进度条并松手，期望 seek 到目标位置。代码：`lib/features/player/player_bar.dart`（`ProgressSlider` 用 `_dragSeconds` 本地值） |
| - [ ] | 🟡 | 队列 island 从右侧滑入滑出、不改变导航层级、不打断浏览 | 点播放条右侧队列按钮，期望一块玻璃岛从右边滑入，左侧歌单仍可见可点（不弹模态遮罩）；再点一次滑出。切换左侧导航分区时队列自动收起。代码：`lib/features/player/queue_island.dart` + `app_shell.dart`（`_queueOpen`） |
| - [ ] | 🟡 | 队列 island 头显示「播放队列 · N 首」，队列空时清空按钮置灰 | 清空队列后点队列按钮，期望岛内显示空态且「清空队列」变灰。代码：`queue_island.dart` |
| - [ ] | 🟡 | 队列行：点一下跳播、悬浮出现移除按钮、当前曲目高亮 | 在队列 island 里点第 3 行，期望立刻播第 3 首；鼠标悬停某行期望出现移除按钮。代码：`lib/features/player/queue_view.dart`（`QueueListView` / `QueueRow`） |
| - [ ] | ✅ | 下架/无版权的歌**按队列切歌**，且封面与歌词跟着切 | `flutter test test/player_controller_test.dart` → 「点到一首下架歌：跳过它、播下一首，封面/歌词跟着切过去」「从正常歌点下一首遇到下架歌：继续往前切」「点上一首遇到下架歌：沿"上"的方向继续找，不掉头往后」。要点：切歌方向跟随用户的**行进方向**（点上一首就往回找）；整队都不可播时停下并说明（递归有上限，见 `_skipUnplayable`） |
| - [ ] | ✅ | **暂时性失败不跳歌**：停在原地给原因 + 重试 | 同上 → 「网络类失败**不**跳歌：停在原地给原因与重试（对照组）」。判据在 `_isUnplayable`：只有 `Song.playable == false` 或 `MusicApiException.unplayable` 才算"根本放不了"；网络超时与 403 不算 |
| - [ ] | 🟡 | 播放条上**常驻**显示失败原因 + 重试 + 关闭 | 断网后点一首歌，期望：播放条中部**顶掉进度条**显示原因 + 「重试」+ 关闭按钮，并且**不会**自动跳到下一首（暂时性失败）。代码：`player_controller.dart`（失败分支）+ `player_bar.dart`（`_PlaybackErrorRow`） |
| - [ ] | 🟡 | 换流引起的「完成」事件被挡掉（改音质不会自己跳下一首） | 播放中在播放条点音质胶囊改成「无损」，期望不跳歌。代码：`player_controller.dart`（`_handleCompletion` 里 `state.resolving` 与「位置离曲尾还远」两条判据） |
| - [ ] | 🟡 | 播放条空态：「还没有正在播放的曲目 / 去「发现音乐」挑一首吧」 | 全新启动（无队列）看底部播放条，期望出现上述两行提示。代码：`player_bar.dart`（`_EmptyHint`） |
| - [ ] | 🟡 | 播放条解析中转圈（封面上盖 loading） | 点一首网络较慢的歌，期望封面位置出现半透明黑底 + 转圈。代码：`player_bar.dart`（`_NowPlayingInfo` 的 `busy`） |
| - [ ] | 🟡 | 播放条左侧显示 `歌名 / 艺人 · 音源` + **实际**音质胶囊 | 播放中看播放条左侧，期望有音质小胶囊（如 `极高`、`无损`），点开可改。代码：`player_bar.dart` + `playback_extras.dart`（`PlaybackQualityChip`） |
| - [ ] | 🟡 | 播放条音量滑杆 + 静音（再点恢复 0.7） | 点喇叭图标静音，期望图标变 `volume_off`、音量条归零；再点一次，期望音量回到 0.7。代码：`player_bar.dart`（`_VolumeControl`） |
| - [ ] | 🟡 | 音量持久化 | 把音量调到 30% 后重启，期望仍是 30%。代码：`player_controller.dart`（键 `player.volume`） |
| - [ ] | 🟡 | 「上一首」在播放超过 3 秒时回到本曲开头 | 播放 5 秒后点上一首，期望回到本曲 0:00 而不是切到上一首；在 2 秒内点则切上一首。代码：`player_controller.dart`（`previous`） |
| - [ ] | 🟡 | 顺序播放走到队列尽头会停下但保留当前曲目 | 队列最后一首播完（顺序播放模式），期望停住且播放条仍显示这首歌，按播放可重听。代码：`player_controller.dart`（`_move` 里 `target == null` 分支） |
| - [ ] | 🟡 | 播完再点播放从头开始（不停在末尾） | 等一首歌播完，点播放键，期望从 0:00 开始。代码：`togglePlayPause` |
| - [ ] | 🟡 | 播放模式与随机状态持久化 | 切到「随机播放」后重启，期望仍是随机。代码：`player_controller.dart`（键 `player.shuffle` / `player.repeat`） |
| - [ ] | 🟡 | **均衡器面板**：8 个预设 + 10 段增益（±12 dB，24 级）+ 复位 + 「当前后端不生效」徽标 + 顶部说明 | 播放条点 `graphic_eq` 图标，期望弹出「均衡器」对话框：标题右侧有「当前后端不生效」徽标，正文最上方有解释 Windows 后端没有音频效果接口的说明块，8 个预设 ChoiceChip，31Hz~16kHz 十行滑杆（每行右侧显示 `+x.x`）。代码：`lib/features/player/playback_extras.dart`（`kEqualizerPresets` / `_kBandLabels` / `_EqualizerDialog`） |
| - [ ] | ❌ | **均衡器实际改变声音** | 未实现，且当前后端做不到。详见第 11.1 节 |
| - [ ] | 🟡 | 封面磁盘缓存（内存 LRU 24MB + 磁盘 256MB 预算整理） | 滚动一个有封面的列表，期望已看过的封面再次出现时不重新下载（断网后仍能显示）。代码：`lib/core/cache/cover_cache.dart`（`_memoryBudgetBytes` / `_diskBudgetBytes` / `enforceDiskBudget`）+ `lib/core/ui/cover_image.dart` |
| - [ ] | 🟡 | 切歌/滚动导致的封面错位不会发生（异步返回时校验 URL 仍是当前值） | 快速滚动一个长列表，期望封面对应正确行。代码：`cover_image.dart`（`_load` 里比对 `widget.url`） |
| - [ ] | 🟡 | 歌曲行：**行尾只有一个「…」**，菜单含播放 / 下一首播放 / 加入队列 / 下载 / 从队列移除 / 复制歌曲信息 | `flutter test test/song_row_test.dart` → 「行尾只留一个「…」，播放/下一首/加入队列/下载都不再占位」「「…」菜单里保留了完整动作（下载/加入队列/移除）」。人工：点任意一行的「…」核对菜单项 |
| - [ ] | ✅ | 不可播放的曲目：菜单里「播放」与「下载」**置灰**而不是消失 | 同上 → 「不可播放的曲目：菜单里的播放与下载都置灰」 |
| - [ ] | ✅ | 行首序号在鼠标悬停时变成播放按钮 | 同上 → 「鼠标移到序号上时变成播放按钮」 |
| - [ ] | ✅ | 无悬停时序号照常显示 | 同上 → 「序号照常显示（没有悬停时不是播放按钮）」 |
| - [ ] | 🟡 | 单击一行就播放（不是「先选中再双击」） | 单击列表任意一行，期望立刻开始播放该曲。代码：`lib/core/ui/song_list.dart`（`_play` → `onTap`） |
| - [ ] | 🟡 | 点行尾「…」能正常弹出菜单（不被整行手势抢走） | 点任意行的「…」，期望菜单立刻弹出。代码：`song_list.dart`（单击/双击手势只包内容区，不含右侧操作区） |
| - [ ] | 🟡 | 当前播放行显示跳动音柱 + 主题色标题 | 播放一首后看列表里对应行，期望行首是跳动的三根柱子（暂停时定格），标题用主色加粗。代码：`song_list.dart`（`_PlayingBars` / `_titleBlock`） |
| - [ ] | 🟡 | 不可播放的曲目整体压暗，悬浮显示原因 | 在列表里找一首不可播放的歌，期望内容区半透明，鼠标悬停出现原因 tooltip。代码：`song_list.dart`（`Opacity(opacity: playable ? 1 : 0.55)` + `Tooltip`） |
| - [ ] | 🟡 | 加入队列 / 下一首播放有明确 SnackBar 反馈 | 从「…」菜单点「下一首播放」，期望提示「已加入下一首播放」。代码：`song_list.dart`（`_enqueue`） |
| - [ ] | 🟡 | 「复制歌曲信息」写入剪贴板并提示 | 点「复制歌曲信息」，期望提示「已复制：歌名 - 艺人」且粘贴板内容一致。代码：`song_list.dart`（`_copyInfo`） |
| - [ ] | ✅ | 三栏（导航 / 中栏 / 右栏 / 队列 island）上下边界一致 | `flutter test test/page_layout_test.dart` → 「三栏（导航 / 中栏 / 右栏 / 队列 island）的上下边界一致」 |
| - [ ] | ✅ | 三栏的上下留白只有一处定义 | 同上 → 「三栏的上下留白只有一处定义」 |
| - [ ] | ✅ | 单栏页面（发现 / 搜索 / 下载）的默认留白与共享定义一致 | 同上 → 「单栏页面（发现 / 搜索 / 下载）用的默认留白与共享定义一致」 |
| - [ ] | 🟡 | 设置页悬停高亮底色块比文字左右各宽 12px、带圆角 | 鼠标移到「播放」或「窗口材质」里的开关条目上，期望底色块左右比文字宽出一截、四角圆润（不出现「阴影和字贴在一起」）。代码：`settings_page.dart`（`contentPadding: EdgeInsets.symmetric(horizontal: 12)` + `RoundedRectangleBorder`） |
| - [ ] | 🟡 | 玻璃面板顶部只有一条细亮线（不是一块亮区） | 看任意一张大玻璃卡（如歌单头），期望顶部是一条 1.2px、左右淡出的亮线，而不是「上半部分被压暗」。代码：`lib/core/ui/glass.dart`（`GlassPanel` 的高光实现） |

---

## 7. 缓存与同步

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | `Song` 缓存序列化往返不丢关键字段 | `flutter test test/collection_cache_test.dart` → 「往返不丢关键字段」。代码：`lib/core/cache/collection_cache.dart`（`songToCacheJson` / `songFromCacheJson`） |
| - [ ] | ✅ | 缓存字段缺失或类型错误时逐项退化，不抛异常 | 同上 → 「字段缺失或类型错误时不抛异常，只逐项退化」 |
| - [ ] | ✅ | 没有 `id` 的缓存条目直接丢弃 | 同上 → 「没有 id 的条目直接丢弃」 |
| - [ ] | ✅ | `write` → `read` 往返一致 | 同上 → 「write → read 往返一致」 |
| - [ ] | ✅ | 没有缓存时返回 null | 同上 → 「没有缓存时返回 null」 |
| - [ ] | ✅ | 文件被截断成半截 JSON 时返回 null 而不是抛异常 | 同上 → 「文件被截断成半截 JSON 时返回 null 而不是抛异常」 |
| - [ ] | ✅ | 文件内容不是 JSON 时返回 null | 同上 → 「文件内容不是 JSON 时返回 null」 |
| - [ ] | ✅ | `songs` 字段被写成非列表时返回 null | 同上 → 「songs 字段被写成非列表时返回 null」 |
| - [ ] | ✅ | `remove` / `totalSize` / `clear` 正常 | 同上 → 「remove 之后读不到，totalSize / clear 正常工作」 |
| - [ ] | ✅ | 不同音源的同名 id 不会互相覆盖 | 同上 → 「不同音源的同名 id 不会互相覆盖」 |
| - [ ] | ✅ | 同步频率判定：`manual` 永不同步 | 同上 group「SyncPolicy.isDue」→ 「manual 永远不同步」。代码：`lib/core/cache/sync_policy.dart` |
| - [ ] | ✅ | `onLaunch` 在「今天还没同步过」时为真（按自然日比较） | 同上 → 「onLaunch 在"今天还没同步过"时为真」 |
| - [ ] | ✅ | `hourly` / `every6Hours` / `daily` 的间隔正确 | 同上 → 「hourly 按间隔判定」「every6Hours / daily 的间隔正确」 |
| - [ ] | ✅ | `SyncPolicyStore` 读写 `shared_preferences` | 同上 → 「SyncPolicyStore 读写 shared_preferences」（键 `sync.frequency`） |
| - [ ] | ✅ | **差量合并**：新增在前、旧的照旧 | 同上 group「mergeCollectionSongs 差量合并」→ 「前面新增若干条：新增在前，旧的照旧」 |
| - [ ] | ✅ | 远端只给第一页时，尾部靠缓存补上且顺序不乱 | 同上 → 「远端只给了最前面一页（差量拉取）：尾部靠缓存补上，顺序不乱」 |
| - [ ] | ✅ | 删除若干条时被删的不再出现，`removed` 计数正确 | 同上 → 「删除若干条：被删的不再出现，removed 计数正确」 |
| - [ ] | ✅ | 同时新增与删除时顺序与计数都正确 | 同上 → 「同时新增与删除，顺序与计数都正确」 |
| - [ ] | ✅ | 两侧都存在重复 uid 时结果里也不重复 | 同上 → 「两侧都存在重复 uid 时结果里也不重复」 |
| - [ ] | ✅ | 缓存为空时结果就是远端内容本身 | 同上 → 「缓存为空时就是远端内容本身」 |
| - [ ] | ✅ | **差量拉取**：一页里没有新内容就立刻停止翻页（只发 1 次请求） | 同上 group「computeCollectionSync 差量拉取」→ 「一页里没有新内容就立刻停止翻页（只发 1 次请求）」 |
| - [ ] | ✅ | 云端没有变化时也只发 1 次请求 | 同上 → 「云端没有变化时也只发 1 次请求」 |
| - [ ] | ✅ | 新增内容超过一页时会连续翻页，直到某页没有新 uid | 同上 → 「新增内容超过一页时会连续翻页，直到某页没有新 uid」 |
| - [ ] | ✅ | 云端总数变少（有删除）时必须翻到末尾，差集才正确 | 同上 → 「云端总数变少（有删除）时必须继续翻到末尾，差集才正确」 |
| - [ ] | ✅ | 分页顺序与缓存对不上时退回全量重取 | 同上 → 「分页顺序与缓存对不上时退回全量重取」 |
| - [ ] | ✅ | 首次加载（没有缓存）走全量 | 同上 → 「首次加载（没有缓存）走全量」 |
| - [ ] | ✅ | `manual` 策略下有缓存就完全不联网 | 同上 group「loadOrSync」→ 「manual 策略下有缓存就完全不联网」 |
| - [ ] | ✅ | `force` 时跳过频率限制并把合并结果写回缓存 | 同上 → 「force 时跳过频率限制并把合并结果写回缓存」 |
| - [ ] | ✅ | 同步失败时继续返回缓存内容并把原因写进 `error` | 同上 → 「同步失败时继续返回缓存内容并把原因写进 error」 |
| - [ ] | ✅ | **并发去重**：同一个集合并发同步只发一次请求 | 同上 → 「同一个集合并发同步只发一次请求」 |
| - [ ] | 🟡 | 缓存目录结构 `<应用支持目录>/collections/<音源>/<集合 id>.json` | 打开一个歌单后到 `%APPDATA%\com.zhuoyue\zhuoyue_player\collections\` 下查看，期望有 `netease\` / `bilibili\` 子目录与对应 json。代码：`collection_cache.dart`（`_fileFor` / `_safeId`） |
| - [ ] | 🟡 | 写缓存先写 `.part` 再 rename（永远读不到半截文件） | 读 `collection_cache.dart`（`write`）；人工：在写入瞬间强杀进程，期望盘上留下 `.part` 而不是损坏的正式文件 |
| - [ ] | 🟡 | **打开歌单秒开**：先渲染本地缓存，再后台与云端同步 | 打开一个已缓存过的歌单，期望内容立刻出现（无 loading），随后状态条从「本地缓存」变成「已同步」。代码：`lib/features/playlists/playlists_page.dart`（`_loadSongs(reset: true)` → 先 `_showCachedSongs` 再 `_syncSongs`） |
| - [ ] | 🟡 | **断网时已缓存歌单仍可看** | ① 先联网打开一个歌单；② 禁用网络适配器；③ 重新打开该歌单（或重启应用后再打开），期望曲目列表照常显示、状态条显示「同步失败：…（当前显示本地缓存）」而不是错误页。代码：`collection_cache.dart`（`_loadOrSync` 的 catch 返回 `entry?.songs`）+ `playlists_page.dart`（`_syncNote`） |
| - [ ] | 🟡 | 同步状态条：`本地缓存 / 已同步 · <相对时间> · 云端无变化 / 新增 N 首、移除 M 首` | 打开一个已同步的歌单，期望状态条出现上述文案之一。代码：`playlists_page.dart`（`_buildSyncBar`）+ `lib/core/utils/format.dart`（`ZhyFormat.relativeTime`） |
| - [ ] | 🟡 | **同步频率**在歌单页头部可切换 5 档，改完立刻生效 | 点状态条右侧的频率按钮（显示当前档位名如「每次启动」），期望弹出「仅手动 / 每次启动 / 每小时 / 每 6 小时 / 每天」五项，选中后按钮文案变化且重启后保持。代码：`playlists_page.dart`（`PopupMenuButton<SyncFrequency>`）+ `sync_policy.dart`（`setFrequency` 落盘） |
| - [ ] | 🟡 | 「仅手动」档位下打开歌单不联网，只有点「立即同步」才更新 | 把频率设为「仅手动」，打开一个已缓存的歌单，期望状态条停在缓存内容、不出现「正在与云端同步…」；点「立即同步」后期望更新并显示「新增 N 首」。代码：`sync_policy.dart`（`isDue` 对 manual 恒 false）+ `playlists_page.dart`（`_forceSync`） |
| - [ ] | 🟡 | 同步失败**不清空**已展示内容，只提示原因 | 断网后点「立即同步」，期望已显示的曲目仍在，状态条变红字说明原因。代码：`playlists_page.dart`（`_syncNote`，不清 `_songs`） |
| - [ ] | 🟡 | 发现页打开公开歌单也走同一套缓存 + 差量同步 | 断网后重新打开发现页里上次看过的歌单，期望曲目照常显示。代码：`lib/features/discover/discover_page.dart`（`_CollectionDetailPageState._load` 里读 `collectionCacheProvider`） |

---

## 8. 下载

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | `DownloadTask` 的 `toJson` / `fromJson` 往返每个字段都不丢 | `flutter test test/download_task_test.dart` → 「toJson / fromJson 往返后每一个字段都不丢」。代码：`lib/core/download/download_task.dart` |
| - [ ] | ✅ | 失败原因与暂停状态也能往返 | 同上 → 「失败原因与暂停状态也能往返」 |
| - [ ] | ✅ | 缺曲目信息 / 状态名不认识时按可恢复方式降级 | 同上 → 「缺曲目信息 / 状态名不认识时按可恢复的方式降级」 |
| - [ ] | ✅ | 总大小未知时进度返回 0，并用 `hasStarted` 表达「已开始」 | 同上 group「DownloadTask 进度」→ 「总大小未知时返回 0，并用 hasStarted 表达"已开始"」 |
| - [ ] | ✅ | 总大小已知时是比例且被夹在 0~1 | 同上 → 「总大小已知时是比例，且被夹在 0~1」 |
| - [ ] | ✅ | `copyWith` 能把可空字段显式清成 null | 同上 → 「copyWith 能把可空字段显式清成 null」 |
| - [ ] | ✅ | `Song` 序列化关键字段不丢，且不含不可序列化的东西 | 同上 group「Song 序列化」→ 「关键字段不丢，且不含不可序列化的东西」 |
| - [ ] | ✅ | 网易云与哔哩的 uid 都能原样恢复（跨源身份不能串） | 同上 → 「网易云与哔哩的 uid 都能原样恢复（跨源身份不能串）」 |
| - [ ] | ✅ | 下载管理**按音源分栏**：标签始终存在且带条数 | `flutter test test/downloads_page_test.dart` → 「下载管理按音源分栏：标签始终存在，且带条数」。代码：`lib/features/downloads/downloads_page.dart`（`_buildSourceTabs` / `_sources`） |
| - [ ] | ✅ | 切到「哔哩哔哩」标签后只留下哔哩的任务 | 同上 → 「切到哔哩标签后只留下哔哩的任务」 |
| - [ ] | ✅ | 切到「网易云音乐」标签后反过来只留网易云任务 | 同上 → 「切到网易云标签后反过来只留网易云任务」 |
| - [ ] | ✅ | 某源没有任务时切过去给出空状态，而不是空白页 | 同上 → 「某源没有任务时切过去给出空状态，而不是空白页」 |
| - [ ] | ✅ | 未装配下载器时说明原因，而不是当作「没有任务」 | 同上 → 「未装配下载器时说明原因，而不是当作"没有任务"」 |
| - [ ] | ✅ | 任务行显示进度与状态，而不是只有标题 | 同上 → 「任务行显示进度与状态，而不是只有标题」 |
| - [ ] | 🟡 | `downloadQueueProvider` 在入口被真实装配（README 里「`DownloadQueue` 尚为 null，需要接上真实下载器」那句**已过期**） | 读 `lib/main.dart`：`downloadQueueProvider.overrideWith((Ref ref) => DownloadManager(ref))`；人工：启动后进「下载管理」，期望头部文案是「共 N 个任务 · …」而不是「下载器未启用」 |
| - [ ] | 🟡 | **真实下载一个文件**（`dio` 流式 + `IOSink`） | 在歌单页或搜索结果里从「…」菜单点「下载」，期望提示「已加入下载：xxx」；进「下载管理」期望进度条推进到 100%、状态胶囊变「已完成」；点「打开所在文件夹」期望资源管理器选中该文件，且文件能用系统播放器播放。代码：`lib/core/download/download_manager.dart`（`_download` / `_open`） |
| - [ ] | 🟡 | **Range 断点续传**：以磁盘上文件的**真实长度**做 Range 起点 | 下载到 30% 时点「暂停」→ 记录文件大小 → 点「继续下载」，期望继续增长（不是从 0 重来）。代码：`download_manager.dart`（步骤 3：`resumeFrom = file.lengthSync()`）+ `_open` 里 `if (from > 0) 'Range': 'bytes=$from-'` |
| - [ ] | 🟡 | 服务端返回 416 时改为**从头下载**（把旧文件清空） | 难以稳定复现；可读代码确认分支存在：`download_manager.dart`（`_RangeNotSatisfiable` → `file.writeAsBytes([])` + `resumeFrom = 0` + `_resolve(force: true)`） |
| - [ ] | 🟡 | 服务端忽略 Range（返回 200 全量）时**不追加**，改为从头写 | 同上，代码分支：`effectiveAppend = append && code == 206`；人工可验：对不支持 Range 的音源下载并暂停/继续，期望文件不会变成「半段旧 + 全量新」的坏文件（用播放器打开验证时长正常） |
| - [ ] | 🟡 | 并发上限 2：同时入队 4 首，只有 2 首在「进行中」 | 连续加入 4 个下载，期望任意时刻最多 2 个状态为「进行中」，其余是「等待中」。代码：`download_manager.dart`（`maxConcurrent = 2` + `_pump`） |
| - [ ] | 🟡 | 暂停与取消**都保留半成品文件**，之后可续传 | 暂停后看目标目录，期望存在一个体积小于总长的文件；再点「重试（会从断点续传）」期望接着长。代码：`_stopActive` / `cancel`（保留 `filePath` 与 `receivedBytes`） |
| - [ ] | 🟡 | **任务持久化**：`<应用支持目录>/downloads/tasks.json`，重启后运行中任务降级为「已暂停」 | 下载中直接关掉应用再重开，期望任务列表还在、状态是「已暂停」而不是「进行中」。代码：`download_manager.dart`（`tasksFileName` / `_restore` / `_reconcileWithDisk` 里 `running → paused`） |
| - [ ] | 🟡 | 已完成任务的文件被移动/删除后，状态改为「失败」并提示原因 | 下载完成 → 在资源管理器里删掉该文件 → 重启应用，期望该任务状态变红并提示「文件已被移动或删除，请重新下载」。代码：`_reconcileWithDisk` |
| - [ ] | 🟡 | 文件按音源分子目录存放：`<根目录>/<音源名>/` | 下载一首网易云与一首哔哩的歌，期望分别落在 `…\ZhuoYuePlayer\网易云音乐\` 与 `…\ZhuoYuePlayer\哔哩哔哩\`。代码：`_taskDirectory` |
| - [ ] | 🟡 | 文件命名 `<艺人> - <歌名>.<扩展名>`；非法字符清理、去掉结尾的点与空格、超 120 字截断、重名加 `(2)` | 下载同名歌曲两次（不同音源或不同版本），期望第二个文件名变成 `… (2).mp3`；检查文件名里没有 `\ / : * ? " < > |`，且不以 `.` 或空格结尾。代码：`_sanitizeFileName` / `_targetFile` |
| - [ ] | 🟡 | 扩展名从 MIME 推断，认不出时回落 `mp3` | 下载一首无损网易云歌，期望扩展名是 `.flac`；下载一首普通歌期望 `.mp3`。代码：`_extensionFor` |
| - [ ] | 🟡 | 哔哩音频 CDN 的 `Referer` / UA 由 `ResolvedStream.headers` **原样带入**下载请求（否则 403） | 下载一首哔哩收藏里的歌，期望成功而不是「音源拒绝了下载请求（403）」。代码：`_open` 里 `headers: {...stream.headers, ...}` |
| - [ ] | 🟡 | 直链过期按 `expiresAt` 校验并重新解析 | 暂停一个哔哩下载 30 分钟以上再继续，期望能续上（而不是 403）。代码：`_resolve` + `ResolvedStream.isValidAt` |
| - [ ] | 🟡 | **下载目录选择**（`file_selector`）并持久化 | 点「更改目录」选一个新目录，期望路径文案立刻变化；重启后仍是该目录。代码：`selectDirectory`（键 `download.directory`） |
| - [ ] | 🟡 | 默认下载目录是 `%USERPROFILE%\Music\ZhuoYuePlayer` | 未设置自定义目录时看「下载目录」那一行。代码：`_synchronousDefaultRoot` |
| - [ ] | 🟡 | 「打开下载目录」与「打开所在文件夹」（选中文件） | 点「打开下载目录」期望打开资源管理器；已完成任务点文件夹图标，期望**选中**该文件而不是只打开目录。代码：`openFolder` / `revealFile`（`explorer /select,$path` 单参数写法） |
| - [ ] | 🟡 | 进度上报节流：约 200ms 或涨 1% 一次（下载时界面不卡） | 下载一个 50MB+ 的文件，期望界面保持可交互、进度条平滑推进而不是卡死。代码：`_reportProgress`（`_progressInterval = 200ms` / `byPercent`） |
| - [ ] | 🟡 | 移除任务：已完成时弹「同时删除已经下载好的文件吗？」三选（取消 / 仅移除记录 / 删除文件） | 在一个已完成任务上点垃圾桶，期望出现该对话框；选「仅移除记录」期望文件仍在盘上。代码：`downloads_page.dart`（`_removeTask`） |
| - [ ] | 🟡 | 「清空已完成」**只清记录不删文件** | 点「清空已完成」，期望列表清空、文件仍在原目录。代码：`download_manager.dart`（`clearCompleted`） |
| - [ ] | 🟡 | 「全部暂停」/「全部继续」按可用状态置灰 | 无进行中任务时「全部暂停」变灰；无已暂停任务时「全部继续」变灰。代码：`downloads_page.dart`（`_buildHeader`） |
| - [ ] | 🟡 | 失败原因一律中文可读（401/403/404/416 各有专属文案） | 读 `download_manager.dart`（`_statusMessage` / `_describeDio` / `_describe`）；人工：让一个下载 403 失败，期望看到「音源拒绝了下载请求（403）：直链可能已过期或需要重新登录」而不是英文堆栈 |
| - [ ] | 🟡 | 歌曲行与搜索结果都能直接加入下载 | 歌单页与搜索页的行菜单里都有「下载」项，点击后提示「已加入下载：xxx」。代码：`playlists_page.dart`（`_download`）+ `search_page.dart`（`_download`） |
| - [ ] | ❌ | **视频下载（含画面）** | 未实现：下载的是解析出来的**音频轨**（`.mp3` / `.flac` / `.m4a`），不是视频文件 |

---

## 9. 诊断

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | ✅ | 环形缓冲默认容量 2000 | `flutter test test/log_buffer_test.dart` → 「默认容量是 2000」。代码：`lib/core/diagnostics/log_buffer.dart` |
| - [ ] | ✅ | 超出容量后丢弃最旧的，`droppedCount` 与长度都正确 | 同上 → 「超出容量后丢弃最旧的，droppedCount 与长度都正确」 |
| - [ ] | ✅ | 绕圈多次之后顺序依然正确（cursor 回绕） | 同上 → 「绕圈多次之后顺序依然正确（cursor 回绕）」 |
| - [ ] | ✅ | 恰好装满时不算丢弃 | 同上 → 「恰好装满时不算丢弃」 |
| - [ ] | ✅ | `clear` 清空内容但保留 `droppedCount` | 同上 → 「clear 清空内容但保留 droppedCount」 |
| - [ ] | ✅ | `entries` 返回的是副本，改动它不影响缓冲区 | 同上 → 「entries 返回的是副本，改动它不影响缓冲区」 |
| - [ ] | ✅ | `[tag]` 前缀解析与剥离 | 同上 group「tag 解析」→ 四条 |
| - [ ] | ✅ | 多行消息（堆栈）拆成 message + detail | 同上 group「多行消息（堆栈）」→ 五条 |
| - [ ] | ✅ | 级别推断：中文错误关键字判 error、英文大小写不敏感、警告类判 warning、普通判 debug、error 优先 | 同上 group「级别推断」→ 六条 |
| - [ ] | ✅ | `filtered`：级别过滤 / 关键字（含 tag 与堆栈）/ 两者叠加 / 空关键字不过滤 | 同上 group「filtered」→ 五条 |
| - [ ] | ✅ | `export` 格式为 `HH:mm:ss.SSS [级别] [tag] 消息`，detail 换行缩进两格，按时间正序 | 同上 group「export」→ 三条 |
| - [ ] | ✅ | 合并通知：同一窗口内多次 add 只通知一次 / `flushNotification` 立刻通知 / dispose 后不再通知 | 同上 group「合并通知」→ 三条 |
| - [ ] | ✅ | `installLogCapture`：装钩子后 `debugPrint` 进缓冲区且**原实现仍被调用** | 同上 group「installLogCapture」→ 「装钩子之后 debugPrint 进缓冲区，并且原实现仍然被调用」 |
| - [ ] | ✅ | 「当前这一层不是我们」时日志照样往下传 | 同上 → 「当前这一层不是我们时，日志照样往下传」 |
| - [ ] | ✅ | 多行 `debugPrint` 拆成 message + detail | 同上 → 「多行 debugPrint 拆成 message + detail」 |
| - [ ] | ✅ | 幂等：重复安装不会把原实现包成多层 | 同上 → 「幂等：重复安装不会把原实现包成多层」 |
| - [ ] | ✅ | 换成新缓冲区时旧缓冲区不再收到日志 | 同上 → 「换成新缓冲区时旧缓冲区不再收到日志」 |
| - [ ] | ✅ | `debugPrint(null)` 不产生日志也不会崩 | 同上 → 「debugPrint(null) 不产生日志也不会崩」 |
| - [ ] | ✅ | 测试环境里的策略：`flutter test` 能被识别为测试环境、`installLogCapture` 是空操作 | 同上 group「测试环境下的策略」→ 两条 |
| - [ ] | ✅ | 日志面板：空状态提示去播放一首歌 | `flutter test test/log_panel_test.dart` → 「空状态提示去播放一首歌」。代码：`lib/features/diagnostics/log_panel.dart` |
| - [ ] | ✅ | 日志面板：渲染日志行、来源标签与丢弃计数 | 同上 → 「渲染日志行、来源标签与丢弃计数」 |
| - [ ] | ✅ | 日志面板：级别过滤与关键字搜索 | 同上 → 「级别过滤与关键字搜索」 |
| - [ ] | ✅ | 日志面板：用户手动往上滚之后**不再**被强行拉到底部 | 同上 → 「用户手动往上滚之后不再被强行拉到底部」 |
| - [ ] | ✅ | 日志面板：详情默认折叠，点开之后显示堆栈 | 同上 → 「详情默认折叠，点开之后显示堆栈」 |
| - [ ] | ✅ | 日志面板：复制全部与清空都会给提示 | 同上 → 「复制全部与清空都会给提示」 |
| - [ ] | ✅ | 设置页「维护」分区可以打开日志面板，且设置页本身不受影响 | 同上 → 「维护分区可以打开日志面板，且设置页本身不受影响」 |
| - [ ] | 🟡 | **日志捕获从应用启动就开始**（不是等用户打开面板） | 启动后随便播一首歌，再打开「设置 → 维护 → 打开调试日志」，期望面板里**已经有**刚才那次播放的日志（例如 `[player] 已预解析下一首：…`）。代码：`lib/features/shell/app_shell.dart`（`initState` 里 `ref.read(logBufferProvider)`，注释写明原因） |
| - [ ] | 🟡 | 日志面板是右侧滑入 island Overlay，不吃掉交互、不改变导航层级 | 打开日志面板后，左边界面仍可见可点（能一边点播放一边看日志刷出来），点面板外灰色区域可关闭。代码：`log_panel.dart`（`showLogPanel` 用 `OverlayEntry`） |
| - [ ] | 🟡 | 日志面板支持 Esc 关闭 | 把焦点放在面板搜索框里按 `Esc`，期望面板滑出。代码：`log_panel.dart`（`SingleActivator(LogicalKeyboardKey.escape)` + 自定义 `_ClosePanelIntent`） |
| - [ ] | 🟡 | 日志行时间戳用等宽字体 + 表格数字，可整体拖选复制 | 在日志行上拖动选中，期望时间/级别/来源/消息一起被选中。代码：`log_panel.dart`（`_LogRow` 的 `SelectableText.rich`、`Consolas`） |
| - [ ] | 🟡 | 附加一条 `已丢弃 N 条更早日志` 的提示 | 制造 2000 条以上日志（例如反复切歌），期望面板底部出现该提示且颜色为主题 tertiary。代码：`log_panel.dart`（`_buildFooter`）+ `LogBuffer.droppedCount` |
| - [ ] | 🟡 | `ZHY_DEBUG_SECTION` 环境变量能指定启动分区 | `$env:ZHY_DEBUG_SECTION='settings'; flutter run -d windows`，期望启动即在设置页。可选值读 `lib/features/shell/app_shell.dart`（`ShellSection` 的 `name`：`discover`/`neteasePlaylists`/`bilibili`/`search`/`downloads`/`accounts`/`settings`）。仅 `kDebugMode` 生效 |
| - [ ] | 🟡 | `ZHY_DEBUG_QUEUE=1` 启动即展开队列 island | `$env:ZHY_DEBUG_QUEUE='1'; flutter run -d windows` |
| - [ ] | 🟡 | `ZHY_DEBUG_NOWPLAYING=1` 启动即打开全屏播放页 | `$env:ZHY_DEBUG_NOWPLAYING='1'; flutter run -d windows` |
| - [ ] | 🟡 | `ZHY_DEBUG_DUMP=1` 首帧后打印整棵 widget 树 | `$env:ZHY_DEBUG_DUMP='1'; flutter run -d windows`，期望控制台出现 `debugDumpApp()` 输出（经 `debugPrint` 转发） |
| - [ ] | 🟡 | `ZHUOYUE_RUNTIME_DIR` 能指定内嵌运行时目录 | `$env:ZHUOYUE_RUNTIME_DIR='E:\WorkSpace\zhuoyue-player\runtime'; flutter run -d windows`。代码：`lib/core/runtime/embedded_netease_api.dart`（`_resolveRuntime` 第一优先级） |
| - [ ] | 🟡 | **截图脚本**可用（DPI 感知 + 客户区坐标） | `pwsh -File scripts/capture-window.ps1`，期望在 `docs/images/screenshot-window.png` 生成截图，且窗口右侧一列按钮与底部播放条都完整（不被裁掉）。代码：`scripts/capture-window.ps1`（`SetProcessDPIAware()` + `GetClientRect` + `ClientToScreen` + `CopyFromScreen`） |
| - [ ] | 🟡 | 截图脚本可选参数：`-Exe` / `-Out` / `-WaitSeconds` / `-SettleSeconds` / `-KeepRunning` | `pwsh -File scripts/capture-window.ps1 -Out docs\images\shot.png -KeepRunning`，期望截图另存且应用保持运行 |
| - [ ] | 🟡 | 封面缓存大小统计与「清空缓存」 | 设置 → 维护，期望显示「封面缓存：x.x MB」；点「清空缓存」，期望提示「封面缓存已清空」且数字归零，随后封面重新加载。代码：`settings_page.dart`（`_MaintenanceSection`）+ `lib/core/cache/cover_cache.dart`（`sizeOnDisk` / `clear`） |
| - [ ] | 🟡 | 封面磁盘预算整理（超 256MB 时按**最后访问时间**从旧到新删） | 读 `cover_cache.dart`（`enforceDiskBudget`，在首次 `_ensureDirectory` 时后台触发）；人工：把缓存目录塞到 256MB 以上再启动，期望日志出现 `[cover] 磁盘缓存已整理至 x.x MB` |
| - [ ] | ❌ | 内嵌 Node 服务的 stdout/stderr **落盘到日志文件** | 代码里没有写盘：`embedded_netease_api.dart` 只把 stdout/stderr 追加进内存里的 `_logs`（上限 50 行）。`docs/architecture.md` / `docs/development.md` 里「落盘到日志目录」的说法与实现不符 |
| - [ ] | ❌ | 设置页「诊断」分区，展示内嵌服务 baseUrl 与 stdout/stderr 摘要 | 未实现：现在的设置页只有「账户 / 外观模式 / 字体 / 播放 / 主题色来源 / 配色方案 / 窗口材质 / 维护」八个分区，没有「诊断」。`docs/development.md` 里「设置 → 诊断」那句已过期 |
| - [ ] | ❌ | `NeteaseApiClient.ping()` 的界面入口 | `lib/data/netease/netease_api_client.dart` 里定义了 `ping()`（失败时附带内嵌服务最近日志），但全仓库**没有任何调用点** |
| - [ ] | ❌ | 日志导出到文件 | 未实现：日志面板只有「复制全部到剪贴板」（`_copyAll`），没有写文件 |
| - [ ] | ❌ | 日志轮转与体积上限 | 未实现：只有内存环形缓冲 2000 条，没有落盘所以也没有轮转 |
| - [ ] | ⚠️ | 日志脱敏（不打印 `MUSIC_U` / `SESSDATA` / `__csrf`） | 未确认：`lib/core/diagnostics/log_buffer.dart` 里**没有**脱敏逻辑；脱敏依赖各调用点自律（例如 `netease_api_client.dart` 的日志不打印 cookie）。需要逐处读代码或做一次「登录 → 全量跑一遍功能 → 搜日志面板关键词」的实测才能定性 |

---

## 10. 工程

| 勾选 | 状态 | 条目 | 验证动作 |
| --- | --- | --- | --- |
| - [ ] | 🟡 | `dart analyze lib test` 零 issue | `dart analyze lib test`。**会话早期实测** `No issues found!`（退出码 0）；**会话末期实测** 1 个 warning（`test/lyric_view_test.dart:330` 未使用局部变量）。以你本机输出为准，**期望最终为 0**。规则集：`analysis_options.yaml`（`package:flutter_lints/flutter.yaml`，排除 `build/**`、`windows/**`） |
| - [ ] | 🟡 | `flutter test` 全量通过 | `flutter test`。**会话早期实测** `+163 ~11: All tests passed!`；**会话末期实测** `+186 ~11 -1: Some tests failed.`（原因与失败用例见 13.2）。`~11` 是 `test/integration/` 的默认跳过数 |
| - [ ] | ✅ | **测试数量与基线**：写文档时为 163 个，末期已增至 186 个单元/组件测试 | 跑 `flutter test` 看末尾 `+A ~B -C`；测试文件 → 覆盖主题的对照表见 13.2 |
| - [ ] | ✅ | `test/integration/` 默认跳过，需显式开启 | `flutter test` 期望末尾 `~11`（11 个 skipped）；`$env:ZHY_LIVE_TESTS='1'; flutter test test\integration` 才真正联网跑 |
| - [ ] | ✅ | 集成测试 1：内嵌运行时能被找到并拉起（且并发调用只拉一个进程） | `test/integration/netease_live_test.dart` → 同名用例 |
| - [ ] | ✅ | 集成测试 2：搜索能返回带封面的曲目 | 同上 → 「搜索能返回带封面的曲目」 |
| - [ ] | ✅ | 集成测试 3：推荐歌单能取到集合，且集合内曲目可分页 | `$env:ZHY_LIVE_TESTS='1'; flutter test test\integration\netease_live_test.dart` → 「推荐歌单能取到集合，且集合内曲目可分页」 |
| - [ ] | ✅ | 集成测试 4：能解析出真实的播放地址并带失效时间 | 同一文件 → 「能解析出真实的播放地址并带失效时间」 |
| - [ ] | ✅ | 集成测试 5：歌词能解析成升序时间轴，并支持二分定位 | 同一文件 → 「歌词能解析成升序时间轴，并支持二分定位」 |
| - [ ] | ✅ | 集成测试 6：音质档位真的生效（无损不应低于极高） | 同一文件 → 「音质档位真的生效：无损不应低于极高」 |
| - [ ] | ✅ | 集成测试 7：歌单能一次取全（不再只取 50 首） | 同一文件 → 「歌单能一次取全（不再只取 50 首）」 |
| - [ ] | ✅ | 集成测试 8：差量同步：首次全量、第二次只发 1 次分页请求 | 同一文件 → 「差量同步：首次全量、第二次只发 1 次分页请求」 |
| - [ ] | ✅ | 集成测试 9：未登录时「我的歌单」给出明确的鉴权错误 | 同一文件 → 「未登录时「我的歌单」给出明确的鉴权错误」 |
| - [ ] | ✅ | 集成测试 10：真实 `/song/url/v1` 会回 `level`，且它是可识别的档位 | `test/integration/netease_quality_live_test.dart` → 同名用例 |
| - [ ] | ✅ | 集成测试 11：批量自动档，真实数据不该把上限降下去 | `$env:ZHY_LIVE_TESTS='1'; flutter test test\integration\netease_quality_live_test.dart` → 「批量自动档：真实数据不该把上限降下去」 |
| - [ ] | 🟡 | 集成测试可选带真实 cookie（`ZHY_LIVE_COOKIE`） | `$env:ZHY_LIVE_TESTS='1'; $env:ZHY_LIVE_COOKIE='MUSIC_U=...; __csrf=...'; flutter test test\integration\netease_quality_live_test.dart`。**不要把 cookie 写进文件**。代码：`netease_quality_live_test.dart` 顶部注释 |
| - [ ] | 🟡 | 构建命令：调试运行 | `flutter run -d windows`。首次会编译 `just_audio_windows` 的 C++/WinRT 部分，明显慢于增量构建 |
| - [ ] | 🟡 | 构建命令：发布构建与产物路径 | `flutter build windows --release` → 产物 `build\windows\x64\runner\Release\zhuoyue_player.exe`（连同 `flutter_windows.dll`、插件 DLL、`data\`） |
| - [ ] | 🟡 | **运行时 `runtime/` 的获取**：`pwsh -File scripts/fetch-runtime.ps1` | 幂等；已存在的部分会跳过。本次实测已就绪：`runtime/node/node.exe` 与 `runtime/netease-api/launcher.js` 均存在。代码：`scripts/fetch-runtime.ps1` |
| - [ ] | 🟡 | 脚本参数：`-NodeLine`（默认 `latest-v22.x`）/ `-Registry`（默认 `https://registry.npmmirror.com`）/ `-NeteaseVersion`（默认 `4.32.0`）/ `-Force` | 读 `scripts/fetch-runtime.ps1` 的 `param` 块；`pwsh -File scripts/fetch-runtime.ps1 -Force -NodeLine latest-v22.x` 可强制重装 |
| - [ ] | 🟡 | 脚本校验 Node.js 压缩包的 SHA256（`SHASUMS256.txt`） | 读 `fetch-runtime.ps1`；跑步脚本时期望打印 `[ok] SHA256 校验通过 (<sha>)` |
| - [ ] | 🟡 | 脚本自带冒烟测试（拉起 launcher → 等就绪行 → `/search` 要求 `code=200`） | 跑脚本末尾，期望输出 `[ok] 服务已就绪，端口 NNNNN` 与 `[ok] /search 返回 code=200，共 N 条`；日志落在 `.cache/runtime-smoke.log` 与 `.cache/runtime-smoke.err.log` |
| - [ ] | 🟡 | `launcher.js` 由脚本里的 here-string 重写（改 Node 侧必须重跑脚本） | 读 `fetch-runtime.ps1`（`Set-Content -Path $launcher ...`）；人工：直接改 `runtime/netease-api/launcher.js` 后重跑脚本，期望改动被覆盖 |
| - [ ] | 🟡 | 就绪握手的唯一信号是 stdout 上恰好一行 `ZHUOYUE_API_READY <port>` | 前台手动跑：`$env:ZHUOYUE_HOST='127.0.0.1'; & runtime\node\node.exe runtime\netease-api\launcher.js`，期望最后打印 `ZHUOYUE_API_READY <port>`。代码：`embedded_netease_api.dart`（`kReadySignal` / `kReadyPattern`） |
| - [ ] | 🟡 | 退出码语义：2=加载 API 失败、3=版本不兼容、4=启动抛错、5=60s 未就绪、1=其他 | 读 `scripts/fetch-runtime.ps1` 里的 launcher 源码（`process.exit(2/3/4/5/1)`） |
| - [ ] | 🟡 | 内嵌服务的启动超时是可读错误并带最近日志 | 把 `runtime/node/node.exe` 改名后启动并进网易云页，期望报「运行时缺失，请先运行 scripts/fetch-runtime.ps1」；若进程起来但不就绪，期望 60s 后报「内嵌网易云服务启动超时（60 秒）。最近日志：…」。代码：`embedded_netease_api.dart`（`missingRuntimeHint` / `readyTimeout`） |
| - [ ] | 🟡 | `.gitignore` 覆盖 `runtime/`、`.cache/`、`build/`、`.dart_tool/`、`windows/flutter/ephemeral/` | `Get-Content .gitignore` 核对；`git status --short` 期望这些目录不出现在未跟踪列表里 |
| - [ ] | 🟡 | 内置字体资产随包分发 | `Test-Path assets/fonts/zhuzi.ttf` → `True`；`pubspec.yaml` 里 family `Zhuzi` → `assets/fonts/zhuzi.ttf` |
| - [ ] | 🟡 | `.cache/` 下有下载缓存与冒烟日志 | 跑过脚本后 `Get-ChildItem .cache`，期望有 `node-v22.x.x-win-x64.zip`、`runtime-smoke.log`、`runtime-smoke.err.log` |
| - [ ] | ❌ | **CMake 在构建时把 `runtime/` 复制到 exe 同级** | 未实现：`windows/CMakeLists.txt` 里只有 `install(TARGETS …)` / ICU / flutter_windows.dll / 插件 DLL / assets / AOT，**没有任何 `runtime` 目录的 install 或 POST_BUILD 规则**（`.gitignore` 与 README 里的注释声称有）。实际能跑是因为 `EmbeddedNeteaseApi._resolveRuntime` 会从 exe 目录**向上回溯最多 8 层**找 `runtime/`，所以在仓库内构建的 Release 也能找到；但把 `Release\` 单独拷到别的机器就找不到运行时了。绕法：`Copy-Item -Recurse -Force runtime "build\windows\x64\runner\Release\runtime"` |
| - [ ] | ❌ | 窗口几何记忆（位置 / 尺寸 / 最大化） | 未实现 |
| - [ ] | ❌ | Android / 移动端端口 | 未实现：仓库只有 `windows/` 平台目录 |
| - [ ] | ❌ | 自动更新器、安装包签名、崩溃上报 | 未实现（README 明确列为「不做」） |

---

## 11. 已知限制 / 不要当成 bug

逐条给出**原因**与**影响**。这些都不是缺陷报告的对象。

### 11.1 均衡器不会改变声音（界面已如实标注）

- **原因**：Windows 上音频由 `just_audio_windows`（C++/WinRT + Media Foundation）播放，它**没有暴露任何音频效果接口**；`just_audio` 的 `AndroidEqualizer` 与 `AudioPipeline` 都是 Android 专属（走 `AudioEffect`）。
- **影响**：`lib/features/player/playback_extras.dart` 里的 8 个预设与十段增益**只保存曲线，不影响听感**。面板顶部有「当前后端不生效」徽标与整段说明，不做一个看起来在工作的假均衡器。
- **验证**：`grep -r "AndroidEqualizer\|AudioPipeline" lib/` → 无匹配。
- **将来**：换到支持音频图的后端（`media_kit` + mpv，带 `af=equalizer`）即可直接生效，曲线不用重新设计。

### 11.2 无缝衔接只做到「预解析下一首、消除空档」，做不到采样级无缝

- **原因**：采样级无缝需要播放后端把两段音频连续送给声卡；`just_audio_windows`（Media Foundation）不提供这个能力。
- **影响**：切歌时仍有一次本地换流，只是把「调接口解析地址」的几百毫秒到一秒提前做掉了。设置页里那段副标题已如实写明。
- **代码**：`lib/features/player/player_controller.dart`（`_prefetchNext` / `_takeStream`）；文案在 `lib/features/settings/settings_page.dart`。

### 11.3 网易云 SVIP 识别不出来 → 超清母带 / 高清臻音 / Hi-Res 实际不可达

- **原因**：`lib/data/netease/netease_parsers.dart` 的 `tryParseProfile` 只按 `vipType > 0` 产出固定文案 `'黑胶VIP'`；而 `lib/data/netease/netease_repository.dart` 的 `_vipLevel` 只有在 `vipLabel` 里含 `SVIP` 时才返回 2。
- **影响**：`_vipLevel` 最大只能到 1 → `_vipCeiling` 最高只到「无损」→ 档位表里的 `jymaster`（超清母带）/ `sky`（高清臻音）/ `hires`（Hi-Res）在**自动档**下永远选不到。它们在设置页与音质菜单里仍可**手动**选中（`effectiveQuality` 对手动档位不做会员等级过滤），只是服务端可能降级。
- **验证**：读 `netease_parsers.dart` 的 `vipLabel:` 那一行；`grep -n "SVIP" lib/data/netease/` 只会命中 `netease_repository.dart` 的 `_vipLevel`。
- **注意**：`test/netease_quality_test.dart` 里那条「SVIP 账号 + 无记录 → 最高档 jymaster」是**直接注入 `vipLabel: '黑胶SVIP'`** 的单元测试，它验证的是档位映射逻辑，**不代表线上能拿到 SVIP 身份**。

### 11.4 音质「自动」的自我校正是**单向收紧**的

- **原因**：自动档请求的档位**就是** `autoQualityCeiling`；服务端不可能给出比请求更高的档位，所以观测只能把上限压低，永远抬不回来。
- **规则**：连续 **8 首** 都只拿到免费档（≤ 极高）才降级到「极高」并落盘（键 `audio.quality.netease.ceiling`）。任何一次「要到了」（或高于免费档）立刻清零计数。「要这么严」的理由是实测数据：黑胶 VIP 账号抽 30 首里 27 首无损、1 首只有 320k —— 单曲没有无损是常态。
- **影响**：一旦降级，**降级后不会自动恢复**（账号续费 / 升级成 SVIP 也不会），只有**换账号（uid 变化）**才会清掉记录（`_resetObservedCeiling` 只认「两个 uid 都非空且不同」）。手动选的档位不受这个上限影响。
- **绕法**：设置 → 播放 → 音质里手动选「无损」；或清掉 `shared_preferences` 里的 `audio.quality.netease.ceiling`。
- **代码**：`netease_repository.dart`（`applyQualityObservation` / `_observeQuality` / `_resetObservedCeiling`）。

### 11.5 哔哩掉线只能重新扫码（无法自动续期）

- **原因有两层**：① `SESSDATA` 本身生命周期就比网易云的 `MUSIC_U` 短得多（数天到数十天）；② 续期接口 `/x/passport-login/web/cookie/refresh` 需要 cookie 里的 `ac_time_value`，而**扫码登录（`qrcode/poll` → crossDomain 回跳）这条路径只给出 `SESSDATA` / `bili_jct` / `DedeUserID` / `DedeUserID__ckMd5` / `sid`**，不含 `ac_time_value`。
- **影响**：「网易云还登录着、哔哩却变成未登录」是**正常现象**。客户端会：启动时打一次 `nav`；`code == -101` 或 `data.isLogin != true` 时立即清 session、删本地 profile，并弹一条带「重新登录」动作的提示。设置页哔哩未登录时会直接写明这个原因。
- **代码**：`lib/data/bilibili/bilibili_login.dart`、`lib/data/bilibili/bilibili_repository.dart`、`lib/features/account/account_providers.dart`、`lib/features/shell/app_shell.dart`（`_listenAccountExpiry`）。
- **将来**：要支持自动续期需改成**网页版扫码**流程以拿到 `ac_time_value`。

### 11.6 哔哩收藏接口 `ps` 上限 40 → 拉 348 首要 9 次顺序请求

- **原因**：`x/v3/fav/resource/list` 的 `ps` 硬上限是 40，`ps=41` 立刻返回 `code=-400, message="请求错误"` —— 报错文案完全看不出是分页大小的问题。
- **实现**：`lib/data/bilibili/bilibili_repository.dart` 把上限守在 `maxPageSize = 40`，并在 `collectionTracks` 与唯一的读取出口 `_fetchTracks` 各 `clamp(1, 40)` 一次；**刻意不并发**（收藏夹接口是风控重点，并发翻页容易撞 `-412`），顺序拉完一两秒。
- **影响**：344~400 首的收藏夹要 9 次请求，首屏（或强制全量同步）会慢一两秒，这是预期行为。注意 `MusicRepository.collectionTracks` 的 `limit` 默认值是 **50**，所以夹紧是必需的。
- **另一个坑**：`media_id` 不存在时接口返回 `{"code":0,"message":"OK","data":null}` —— 「收藏夹没了」不是错误码，而是空 `data`，必须当成空页。

### 11.7 网易云内嵌服务有 2 分钟 URL 级缓存（客户端用 `x-apicache-bypass` 绕过）

- **原因**：`NeteaseCloudMusicApi` 对 200 响应做了 2 分钟的 URL 级缓存。
- **影响**：对「必须实时」的接口（二维码轮询、登录状态、红心列表），如果不绕过缓存会拿到旧结果 —— 表现为「扫完码界面一直没反应」「刚取消红心又变回红心」。
- **实现**：`lib/data/netease/netease_api_client.dart` 的 `bypassCache: true` 会带上 `x-apicache-bypass: 1` 头；调用点见 `/login/status`、`/likelist`、`/like`、`/recommend/songs`、`/user/account`。

### 11.8 强杀进程会留下一个 `node.exe`

- **原因**：Windows 上子进程**不随父进程退出**。内嵌的网易云 API 是一个 `node.exe` 子进程，只能由应用在退出流程里显式收掉。
- **正常关闭不会残留**：应用拦截了 `onWindowClose`，先 `windowManager.hide()`（观感上立刻关闭），再 `shutdownEmbeddedNeteaseApi()` 发 TERM + KILL，最后 `exit(0)`，并有 2 秒硬性截止兜底。本机实测约 150ms 且无残留。
- **强杀会残留**：用任务管理器「结束任务」时收尾代码根本没机会跑，于是盘上留一个 `node.exe`。它只监听 loopback 且端口是随机分配的，不会和下次启动冲突，但属于资源泄漏 —— 手动结束即可。
- **截图脚本是这条最常见的触发源**：`scripts/capture-window.ps1` 先 `CloseMainWindow()`，若窗口没按时退出就 `$proc.Kill()` 兜底 —— 而 `Kill()` 正是"强杀"，所以**每次靠兜底结束都会留下一个 `node.exe`**。本会话里两次残留（18:26、19:35）都出自子代理跑截图，而不是应用的正常关闭路径。
  - 自查方法：`Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*zhuoyue-player*' } | Select ProcessId,CreationDate`。**看 `CreationDate` 判断是谁留下的** —— 如果它比你刚才那次正常关闭还早，那就是更早一次强杀的遗留，别误判成"正常关闭也漏"。
- **代码**：`lib/features/shell/app_shell.dart`（`_shutdownAndExit`）、`lib/core/runtime/embedded_netease_api.dart`（`stop(waitForExit: false)`）。

### 11.9 未接入的能力（代码里确实没有）

| 能力 | 现状 | 证据 |
| --- | --- | --- |
| 歌单级「收藏」 | 不存在 | `MusicRepository` 只有曲目级 `isLiked` / `setLiked`；点歌单头的「收藏」会弹「歌单收藏接口尚未接入…」（`discover_page.dart` / `playlists_page.dart` 的 `_explainFavorite`） |
| 歌单创建 / 编辑 / 删除 | 不存在 | `MusicCollection.isEditable` 只是标记，没有对应写操作 |
| 网易云手机号**验证码**登录的界面入口 | 半成品 | `NeteaseLoginService.loginWithCaptcha` 存在，但 `login_dialog.dart` 里没有调用点 |
| 内嵌 Node stdout/stderr 落盘 | 不存在 | `embedded_netease_api.dart` 只在内存 `_logs` 里留最近 50 行；全仓库没有 `writeAsString` 之类的日志写盘 |
| 设置页「诊断」分区 | 不存在 | 设置页只有账户/外观/字体/播放/主题色/配色方案/窗口材质/维护八个分区 |
| `NeteaseApiClient.ping()` 的入口 | 未接线 | 方法定义在 `netease_api_client.dart`，全仓库无调用点 |
| 日志导出到文件 / 日志轮转 | 不存在 | 日志面板只有「复制全部」到剪贴板 |
| 窗口几何记忆 | 不存在 | `lib/` 下无 `setPosition` / `getPosition` / 几何持久化 |
| CMake 复制 `runtime/` 到 exe 同级 | 未实现（文档声称有） | `windows/CMakeLists.txt` 无相关 install / POST_BUILD 规则 |
| 视频下载（含画面） | 不存在 | 下载的是解析出的音频轨（`.flac` / `.mp3` / `.m4a`） |
| 系统媒体键（SMTC）/ 任务栏缩略图控件 | 不存在 | README 规划中 |
| 私人 FM / 云盘 / 评论 / 动态 / 直播 / 播客 / 电台 / MV | 不做 | README「明确不做」 |

### 11.10 只支持 Windows 桌面

- **证据**：仓库根目录只有 `windows/` 一个平台目录（没有 `android/` / `ios/` / `linux/` / `macos/` / `web/`）；窗口材质实现是 `dart:ffi` 直调 `user32.dll` / `dwmapi.dll` / `ntdll.dll` / `kernel32.dll`（`lib/core/window/window_effects.dart`）。
- **影响**：`WindowEffects.applyMaterial` 在非 Windows 平台直接返回 `applied: null` + note「当前平台不是 Windows，已退回 Flutter 自绘背景」，不会崩，但也没有任何系统材质。
- **Android 端口**排在后续阶段，`docs/roadmap.md` 列出了现在必须留出的抽象点。

### 11.11 内置字体没有粗体字面 → 全应用不使用 w600/w700

- **证据（实测）**：`assets/fonts/zhuzi.ttf` 的 `OS/2 usWeightClass = 400`、`name(2) = 'Regular'`、无 `fvar` 表 —— **只有一个字面**。用单字面字体做像素测量：请求 w500 与 w400 的墨迹**完全相同**（比值 1.0000），请求 w600 / w700 的墨迹多出 **51%**（比值 1.5124）—— 也就是 Flutter 在**描边合成粗体（faux bold）**。
- **影响**：中文小字被合成加粗会发虚、笔画粗细不匀，观感上就是"部分字体字重不对"（只有请求 w600/w700 的那些，w400/w500 用的是真字面所以正常）。
- **当前的取舍**：代码侧统一只请求 w400 / w500，**层次改由字号与颜色承担**。代价是**全应用没有真正的粗体强调**。
- **不变量**：`flutter test test/typography_weight_test.dart` 扫描 `lib/**` 断言没有 `FontWeight.w600` / `w700`；唯一豁免是日志面板里显式指定 `Consolas` 的样式（Consolas 有真正的 Bold，不走合成）。
- **将来要做真粗体**有两条路：① 再引入一个带 Bold 字面的字体；② 默认改用系统字体（实测微软雅黑有 `Regular(400) + Bold(700)`，Segoe UI 有 400/700，`Segoe UI Semibold` 是**独立的 family** 且正好是 600）。走任一条时，必须**一起放宽那条测试**并说明原因，而不是删掉它。
- **顺带纠正**：`app_theme.dart` 的 `fontFamilyFallback` 里 `Segoe UI` 那一串**不会**用于拉丁字母与数字 —— `zhuzi.ttf` 本身就有 A-Z/a-z/0-9 的字形，而 fallback 只在主字体**缺字形**时才生效。它真正的作用是兜住主字体没有的字形（例如 emoji）。

---

## 12. 需要人工查验的重点清单

**自动化测不到**的东西集中在这里。每条都给「具体操作步骤 + 期望结果」。

| # | 项目 | 操作步骤 | 期望结果 |
| --- | --- | --- | --- |
| 1 | 拖动窗口 / 最大化 / 还原 | ① 按住标题栏空白拖动；② 点最大化；③ 再点一次（此时 tooltip 是「向下还原」）；④ 双击标题栏（若系统支持） | 拖动跟手；最大化后内容自适应且不留黑边；还原后尺寸回到 1240×800 附近；标题栏按钮图标随状态切换 |
| 2 | 边缘缩放 / 最小尺寸 | 把鼠标移到窗口右下边缘，向内拖到不能再缩 | 光标变成缩放箭头；缩到约 900×560 停住；界面无 overflow 条纹、无被压扁的控件 |
| 3 | 亚克力在真实桌面上的观感 | 设置 → 窗口材质 → 亚克力；把窗口移到有壁纸和资源管理器窗口的位置 | 能看见后面的内容、窗口内被模糊、窗口外保持清晰；文字仍然清晰可读（不糊成一片） |
| 4 | Mica / Mica Alt 观感与降级文案 | 依次选 Mica / Mica Alt / 高斯模糊 / 模拟磨砂 / 实色 | 每种都能看出差别；不支持的材质在卡片下方出红字限制、选中后材质区顶部出黄色降级说明条 |
| 5 | 模拟磨砂在「无系统效果」环境下的表现 | 选「模拟磨砂」；把「磨砂强度」拉到 0 与 80 各看一次；关掉「用封面做磨砂底色」 | 数值 0 时背景接近清晰渐变、80 时明显糊；关掉封面底后换成主题色渐变；整屏有极细噪点（不出现明显色带） |
| 6 | 鼠标悬停交互 | ① 悬停左侧导航项；② 悬停歌曲行序号；③ 悬停歌单列表行；④ 悬停设置里的开关条目；⑤ 悬停标题栏关闭按钮 | ① 出现药丸形底色块；② 序号变成播放按钮（当前曲目是暂停键）；③ 整行出现底色；④ 底色块左右各比文字宽 12px、带圆角；⑤ 关闭按钮变系统红底白字 |
| 7 | 歌词滚动观感 | 播放一首歌词密集的歌，全程看歌词区；中途手动往上拖走几行，再滚回当前行附近 | 当前行加粗放大 + 主题主色；翻译行跟随；随播放平滑滚动（不是跳变）；当前行大致在视口垂直中央；**手动上滚后停在那里不再被拉回**，滚回当前行附近后恢复跟随并吸附回中心；最上/最下有 44px 渐隐带 |
| 7b | 歌词行点击 seek | 点歌词中任意一行 | 播放位置跳到该行开始时间，且当前行高亮随之切换 |
| 8 | 全屏播放页切换动画 | 从播放条点「全屏播放页」进入，再点左上「收起」退出 | 进入是 420ms 淡入 + 从下 6% 滑入；退出 320ms 反向；动画期间不卡顿、不闪黑 |
| 9 | 队列 island 滑入滑出 | 点播放条队列按钮 → 再点一次 → 换左侧导航分区 | 从右侧滑入 320px 宽玻璃岛；左侧界面仍可点；再点滑出；切换分区时自动收起 |
| 10 | 真实下载一个文件（完整链路） | ① 歌单页某行「…」→ 下载（记下是网易云还是哔哩）；② 进「下载管理」看进度；③ 完成后点文件夹图标 | 进度条推进到 100%、状态胶囊变「已完成」；资源管理器**选中**该文件；文件能被系统播放器正常播放且时长与歌曲一致 |
| 11 | 断点续传的可感知效果 | 下载到约 30% 时点暂停 → 记录文件大小 → 点继续 | 文件从已有的字节数继续增长，网络面板/耗时上不该出现「从头再下一遍」 |
| 12 | 断网时打开已缓存歌单 | ① 联网打开一个歌单等同步完成；② 断开网络；③ 切走再切回该歌单（或重启应用再打开） | 曲目列表立刻出现（秒开）；状态条显示「同步失败：…（当前显示本地缓存）」；已缓存的歌**仍可播放**（若直链已过期会失败，属正常，见 11.7 与地址时效） |
| 13 | 切换显示缩放比例后的布局 | 把系统显示缩放从 100% 依次切到 125% / 150% / 200%，每次重启应用 | 窗口尺寸与最小尺寸仍是**逻辑**像素语义（不会因为缩放变成巨大的窗口）；三栏上下边界仍对齐；设置页二级标题左列仍对齐；文字不被裁切 |
| 14 | 多显示器 / DPI 混合环境 | 把窗口从 100% 显示器拖到 150% 显示器 | 内容不模糊错位；窗口可正常拖动与缩放（截图脚本要求先声明 DPI 感知，见 `scripts/capture-window.ps1`） |
| 15 | 登录掉线提示 | 手动破坏哔哩 cookie 后重启（见第 4 节对应条目） | 弹「哔哩哔哩 登录已失效，请重新登录」+「重新登录」按钮，持续 8 秒；点按钮能打开登录弹窗 |
| 16 | 二维码扫码全流程 | 用真实 App 扫两种二维码 | 文案依次推进；成功后弹「xx 登录成功」、侧边栏账号卡片出现头像昵称；不需要重启 |
| 17 | 音质胶囊 vs 设置的关系 | 播放一首歌，看播放条胶囊；点开改成「无损」；再看胶囊 | 胶囊显示的是**服务端实际给的档位**（可能仍是「极高」）；改档位时当前曲目会重新加载但**不跳歌**、不改变播放/暂停状态 |
| 18 | 播放失败常驻提示 | 播一首不可播放的歌（找「…」菜单里播放键置灰的那首，或断网后点播放） | 播放条中部顶掉进度条显示红色原因 + 「重试」+ 关闭；**不会**自动跳下一首；点「关闭」后进度条回来 |
| 19 | 强杀进程的残留（对照 11.8） | ① 进发现页让内嵌服务起来；② `Get-Process node` 记 PID；③ 任务管理器结束 `zhuoyue_player.exe`；④ 再 `Get-Process node` | 会看到那个 `node.exe` 仍在（这是已知限制，不是 bug）；手动结束它 |
| 20 | 正常关闭的速度与残留 | 同上但改用点窗口关闭按钮 | 窗口几乎立刻消失（日志里 `[app] 窗口已隐藏（Nms）` 的 N 通常在 100ms 量级）；2 秒内 `node.exe` 消失 |
| 21 | 真实桌面上跑截图脚本 | `pwsh -File scripts/capture-window.ps1` | 生成 `docs/images/screenshot-window.png`；画面里**右侧一列按钮与底部播放条都完整**（这是 DPI 感知修正后的关键验收点） |
| 22 | 日志面板「不吃掉交互」 | 打开日志面板后，点左边界面的播放按钮 | 播放真的开始，且日志面板里同步刷出 `[player] …` 行；面板不拦点击 |
| 23 | 内嵌服务起不来时的用户可见性 | 把 `runtime/node/node.exe` 改名后进网易云页 | 报「运行时缺失，请先运行 scripts/fetch-runtime.ps1」；哔哩与本地播放不受影响 |
| 24 | 玻璃面板顶部高光 | 看歌单详情头 / 侧边栏 / 队列 island 的上沿 | 是一条 1.2px、左右淡出的细亮线；**不是**「上半部分被压暗一块」 |

---

## 13. 测试基线

### 13.1 静态分析

```powershell
cd E:\WorkSpace\zhuoyue-player
dart analyze lib test
```

**两次实测（写这份文档期间仓库正被另一处改动触碰，所以给出两个时间点的数字）：**

| 测量时刻 | 命令 | 结果 |
| --- | --- | --- |
| 会话早期（歌词区抽离之前） | `dart analyze lib test` | `Analyzing lib, test...` / `No issues found!` → 退出码 `0` |
| 会话末期（`lib/features/player/lyric_view.dart` 正在落地） | `dart analyze lib test` | `1 issue found.` → `warning - test\lyric_view_test.dart:330:18 - The value of the local variable 'viewport' isn't used.` |
| **最终（全部改动落地后）** | `dart analyze lib test` | `Analyzing lib, test...` / `No issues found!` → 退出码 `0` |

**期望值：零 issue。** 上面第二条是**临时状态**，不是本清单的问题（见 13.2 的说明）。规则集见 `analysis_options.yaml`（`package:flutter_lints/flutter.yaml`，`analyzer.exclude` 排除 `build/**` 与 `windows/**`）。

### 13.2 单元 / 组件测试

```powershell
flutter test
```

**两次实测（同上，给两个时间点）：**

| 测量时刻 | 结果 | 解读 |
| --- | --- | --- |
| 会话早期（歌词区抽离之前） | `00:08 +163 ~11: All tests passed!` | **163 passed / 11 skipped** |
| 会话中期（`lyric_view.dart` + `test/lyric_view_test.dart` 正在落地） | `00:08 +186 ~11 -1: Some tests failed.` | **186 passed / 11 skipped / 1 failed**；失败用例是 `test/lyric_view_test.dart` → 「用户上滚后暂停自动跟随；滚回当前行附近恢复」（已修复，见下一行） |
| 歌词区落地完成 | `00:07 +189 ~11: All tests passed!` | **189 passed / 11 skipped / 0 failed** |
| 上一轮迭代后 | `00:08 +218 ~11: All tests passed!` | **218 passed / 11 skipped / 0 failed** |
| **最新（下架歌按队列切歌 + 队列聚焦当前曲目）** | `00:09 +241 ~11: All tests passed!` | **241 passed / 11 skipped / 0 failed** —— 全绿，**这就是本清单的当前基线** |

> **怎么解读中间那行**：写这份文档时，歌词区正被抽到新文件 `lib/features/player/lyric_view.dart`，它的测试还在调，所以那一刻套件是红的。那条用例后来修好了：原因是**测试自己的拖动量算错了** —— 两次拖动的净值（`-70+90`）对应的是第 4~5 行，而期间"当前行"已经前进到第 6 行，于是"滚回当前行附近"的判据（视口中心落在当前行 ±容差内）当然不成立。修的是测试而不是实现。
>
> 条数只应该随迭代增加；如果你跑出来的条数更多、且没有失败，那说明又有新测试落地了，以你本机输出为准。

**怎么读结果**：`flutter test` 最后一行是 `+A ~B -C`，即 `A passed / B skipped / C failed`。`~11` 永远来自 `test/integration/`（默认跳过，见 13.3）。

**测试文件 → 覆盖主题**（条数随迭代变化，不在此处固化；用 `flutter test <文件>` 单独复跑）：

| 测试文件 | 覆盖主题 |
| --- | --- |
| `test/collection_cache_test.dart` | Song 缓存序列化、CollectionCache 读写与容错、SyncPolicy、差量合并与差量拉取、loadOrSync |
| `test/log_buffer_test.dart` | 环形缓冲、tag 解析、多行拆分、级别推断、过滤、导出、合并通知、debugPrint 钩子 |
| `test/netease_quality_test.dart` | 档位顺序、自动档观测与降级、初始值、手动档不受上限影响 |
| `test/monet_test.dart` | Monet 取色、ZhyColor、模型工具、ZhyFormat |
| `test/player_controller_test.dart` | 淡入淡出、无缝衔接预解析、播放模式循环、过期加载丢弃、实际音质 |
| `test/download_task_test.dart` | DownloadTask 序列化与进度、Song 序列化 |
| `test/window_effects_test.dart` | Windows build 探测、能力判定、材质划分与名字还原、安全失败 |
| `test/log_panel_test.dart` | 日志面板空态 / 渲染 / 过滤 / 跟随 / 详情 / 复制清空 / 维护入口 |
| `test/downloads_page_test.dart` | 下载页按音源分栏、空态、未装配提示、任务行 |
| `test/theme_settings_test.dart` | 主题设置存取、默认值、reset、字体与令牌进 ThemeData |
| `test/song_row_test.dart` | 行尾「…」、序号悬浮播放键、菜单动作、不可播放置灰 |
| `test/settings_page_test.dart` | 账户分区、未登录 / 已登录、播放菜单 |
| `test/page_layout_test.dart` | 三栏留白单一来源、单栏默认一致、三栏边界一致 |
| `test/lyric_view_test.dart` | 歌词纯函数（`lyricIndexAt` / `lyricScrollOffsetFor` / `lyricListPadding`）、当前行居中、用户上滚后暂停跟随 |

### 13.3 联网集成测试（默认跳过）

`test/integration/` 下的 **11 个** 用例默认全部跳过，跳过原因是：

```
联网集成测试：设置环境变量 ZHY_LIVE_TESTS=1 后运行
```

开启方式：

```powershell
# 前置：runtime/ 已就绪
pwsh -File scripts/fetch-runtime.ps1

# 全部集成测试
$env:ZHY_LIVE_TESTS = '1'
flutter test test\integration

# 只跑音质观测那一组（想验登录态时）
$env:ZHY_LIVE_TESTS = '1'
$env:ZHY_LIVE_COOKIE = 'MUSIC_U=...; __csrf=...'   # 注意：不要写进文件、不要提交
flutter test test\integration\netease_quality_live_test.dart
```

| 文件 | 用例数 | 说明 |
| --- | --- | --- |
| `test/integration/netease_live_test.dart` | 9 | 真机拉起内嵌服务、真实搜索、推荐歌单分页、真实播放地址带失效时间、歌词升序可二分、音质档位生效、歌单一次取全、差量同步只发 1 次请求、未登录明确鉴权错误 |
| `test/integration/netease_quality_live_test.dart` | 2 | 真实 `/song/url/v1` 回可识别 `level`；批量自动档在真实数据下不该被降级 |

**注意**：这两个文件都**不要**调 `TestWidgetsFlutterBinding.ensureInitialized()`（那会让 Dio 用测试的假 HttpClient，所有 HTTP 变 400）；条数与实测数字会随迭代变化，以你本机 `flutter test` 的输出为准。

---

## 14. 本次未能确认的条目

以下条目在写这份清单时**无法从代码或测试确证**，已在上文标为 `⚠️`。需要读代码或人工实测后定性：

1. **封面加载失败后主题色是否真的保留上一次的颜色** —— `lib/core/theme/theme_providers.dart` 的 `CoverPaletteNotifier.clear()` 会把 palette 置空，而 `activeSeedArgbProvider` 在 `coverSeed` 为 null 时回落到 `ZhyColor.fallbackSeedArgb`（M3 默认紫）。这与 `docs/theme-system.md` 里「封面加载失败时保留上一次种子色，不闪回默认紫」的说法**可能不一致**，需要读代码或断网实测确认。
2. ~~歌词自动滚动是否会打断用户的手动滚动~~ —— **已确认实现**：`lib/features/player/lyric_view.dart` 里有 `_autoFollow` 开关与 `_restoreFollowIfCentered`（用户拖动 → 关闭跟随；滚动停止且当前行回到中线 1.5 行以内 → 恢复跟随）。因此该项已从「未确认」移到第 6 节作为 🟡 人工验证条目。⚠️ 但要注意：该文件在写这份清单期间**正在被改动**，且留下了两处 `// ignore: avoid_print` 的调试 `print`（`_restoreFollowIfCentered` 与 `_onScrollNotification` 内），上线前应清掉。
3. **日志脱敏是否真的生效** —— `lib/core/diagnostics/log_buffer.dart` 里**没有**任何脱敏逻辑，脱敏完全依赖各调用点自律。`docs/development.md` 把「日志脱敏」列为已完成的 M5 项。需要逐处读 `debugPrint` 调用点，或做一次实测（登录后跑一遍功能，再在日志面板里搜 `MUSIC_U` / `SESSDATA` / `__csrf`）。
4. **哔哩公开收藏夹的界面入口** —— `BilibiliRepository.publicCollections(mid)` / `publicCollectionTracks` 存在，但界面上没看到输入别人 `mid` 的地方（「哔哩收藏」页走的是 `myCollections`）。需要确认是否存在未读到的入口。
5. **日志文件是否真的写在磁盘上** —— 代码里没有日志写盘逻辑（见 11.9），但 `docs/architecture.md` / `docs/development.md` 都提到「日志文件在 `path_provider` 的应用支持目录下的 `logs/`」。需要检查运行后 `%APPDATA%\com.zhuoyue\zhuoyue_player\` 下是否真有 `logs/` 目录。
