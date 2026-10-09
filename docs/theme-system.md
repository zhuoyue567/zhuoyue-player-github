# 主题系统

ZhuoYue Player 的主题完全走 Material 3 / Material You：**种子色 → DynamicScheme → ThemeData**，配合 **ThemeExtension 令牌** 与 **Win32 窗口材质**。种子色有两个来源：当前封面的 Monet 取色，或用户自选颜色。窗口的亚克力/Mica 与同一套 `ColorScheme` 共享颜色，因此换歌换封面时整个窗口（含背景）一起变色。

代码入口：`lib/core/theme/`（取色、变体、令牌、材质枚举）+ `lib/app/theme/`（控制器与 `ThemeData` 组装）。

## 1. 三层主题模型

```
① 种子色 Seed                lib/core/theme/monet.dart
   ├─ Monet：封面字节 → 降采样 112px → Celebi 量化 → Score 打分 → seedArgb
   └─ 自定义：设置页 HSV/Hex 选择器 → ARGB（hex 解析在 color_utils.dart）
        ↓   MaterialYouSource 抽象（桌面 = 封面/自定义；Android 后续 = 系统动态色）
② DynamicScheme / ColorScheme  ZhyColorVariant + ZhyContrastLevel
   ColorScheme.fromSeed(seedColor, brightness, dynamicSchemeVariant, contrastLevel)
        ↓
③ ThemeData + 令牌            lib/app/theme/ + theme_tokens.dart
   ColorScheme 直接进 ThemeData；玻璃/圆角/动画等非颜色令牌走
   ZhyTokens extends ThemeExtension<ZhyTokens>
        ↓
   窗口材质层（浙窗口背景）     ZhyWindowMaterial → Win32（DWM / SetWindowCompositionAttribute）
```

| 层 | 输入 | 输出 | 依赖 Flutter Widgets |
| --- | --- | --- | --- |
| ① 种子色 | 封面字节 / 用户色值 | `MonetPalette`（`seedArgb` + 候选色 + HCT） | 否（`dart:ui` 的 `Color` 除外） |
| ② 配色方案 | 种子色、variant、brightness、contrastLevel | `ColorScheme`（全套 M3 角色） | 是（用 SDK 的 `ColorScheme.fromSeed`） |
| ③ 主题与令牌 | ② + `ZhyTokens` | `ThemeData`（含 `extension<ZhyTokens>()`）+ Win32 材质参数 | 是 |

**为什么用 SDK 的 `ColorScheme.fromSeed` 而不是手写 `SchemeXxx`**：`fromSeed` 内部就是 `material_color_utilities` 的 `SchemeTonalSpot` 等系列，与 Android 系统动态取色同一份算法；手写一遍没有收益，还会随上游版本跑偏。因此 `ZhyColorVariant` 只是 `DynamicSchemeVariant` 的展示层包装（补中文名与适用场景）。

## 2. Monet 取色流程

实现：`lib/core/theme/monet.dart`（`MonetExtractor` / `MonetPalette`），与 Android 12 的 `DynamicColors` 同源。

```dart
class MonetExtractor {
  const MonetExtractor({
    this.maxDimension = 112,  // 降采样后的最长边（对齐 Android Monet）
    this.maxColors = 128,     // 量化后最多保留的颜色数
    this.desired = 5,         // 期望返回的候选色数量
  });

  /// 从编码后的图片字节取色；解码 + 量化整体放进独立 isolate。
  Future<MonetPalette?> extractFromEncoded(Uint8List bytes) {
    if (bytes.isEmpty) return Future<MonetPalette?>.value();
    return compute(
      _extractFromEncoded,
      _MonetJob(bytes, maxDimension, maxColors, desired),
      debugLabel: 'monet-extract',
    );
  }

  Future<MonetPalette?> extractFromImage(img.Image source) async {
    final img.Image small = _downscale(source);            // 最长边 → 112
    final List<int> pixels = _opaquePixels(small);         // 丢弃 alpha < 128 的像素
    if (pixels.length < 16) return null;                   // 像素太少，统计无意义

    // 注意：material_color_utilities 0.13 起 quantize 是异步的，
    // 返回 QuantizerResult，直方图在 colorToCount 里。
    final mcu.QuantizerResult quantized =
        await mcu.QuantizerCelebi().quantize(pixels, maxColors);

    final List<int> ranked = mcu.Score.score(
      quantized.colorToCount,
      desired: desired,
      filter: true,
    );
    if (ranked.isEmpty) return null;

    final mcu.Hct hct = mcu.Hct.fromInt(ranked.first);
    return MonetPalette(
      seedArgb: ranked.first,          // 直接可当 Material You 种子色
      rankedArgb: List<int>.unmodifiable(ranked),
      hue: hct.hue, chroma: hct.chroma, tone: hct.tone,
    );
  }
}
```

| 步骤 | API | 关键参数 | 为什么这样做 |
| --- | --- | --- | --- |
| 解码 | `img.decodeImage` | — | 封面是 JPEG/PNG/WebP，需先解码；解码在主 isolate 上对 1000×1000 图要几十毫秒，正卡在切歌那一帧，所以放进 `compute` |
| 降采样 | `img.copyResize` | 最长边 `112`、`Interpolation.average` | 一是滤掉高频噪声（噪点会让量化器产出大量无意义色簇），二是让量化足够快（几十毫秒内）；112 取自 Android Monet |
| 透明像素过滤 | `image.getBytes(ChannelOrder.rgba)` | `alpha < 128` 丢弃 | 半透明像素与背景混合后的真实颜色未知，参与量化只会污染结果 |
| 量化 | `QuantizerCelebi().quantize(pixels, 128)` | `maxColors: 128` | 基于 Wu 的混合算法把像素聚成不超过 128 种颜色，产出 `颜色 → 像素数` 直方图 |
| 打分 | `Score.score(colorToCount, desired: 5, filter: true)` | `desired`（候选数量，默认 5）、`filter`（剔除近黑/近白、低色度色）；`Score.score` 另有 `cutoff` 参数，本项目保持默认 `0` 不用 | 关键差别：Score 选的是「最适合当主题色」而不是「出现最多」。白底专辑封面上最多的必然是白色，Score 按彩度/明度/占比综合打分，避开大面积白底与黑边 |
| 兜底 | `ranked.isEmpty` / 像素不足 → `null` | — | 纯黑白封面可能无候选色，调用方回落到上一次种子色或 M3 默认紫，UI 不空转 |
| 产出 | `MonetPalette` | `seedArgb`、`rankedArgb`、`hue/chroma/tone` | 只留一个种子色会让界面「能用但单调」；候选色供渐变背景、次级强调色、封面投影使用（`accentAt(i)`、`gradientStops(n)`） |

**缓存**：以归一化后的封面 URL 为键（本地文件用路径 + mtime），内存 `Map<String, MonetPalette>` + 磁盘 JSON 持久化在缓存目录。切歌回退到已听过的歌不重算；网易云封面 URL 的 `?param=` 尺寸差异会在去键前剥掉，避免同图重复计算。

**不取色的场景**：用户选择自定义种子色时，`MaterialYouSource` 直接返回用户颜色，封面加载不再触发取色（省一次解码）。封面加载失败（离线、404）时保留上一次种子色，不闪回默认紫。

## 3. Variant（配色方案变体）

`lib/core/theme/color_variant.dart` 的 `ZhyColorVariant` 包装 SDK 的 `DynamicSchemeVariant`，补中文名与适用场景。**默认是「内容」（content）**：色相与彩度都紧贴封面，最像当前这张专辑。

| Variant（枚举名 / 中文名） | 色彩特征 | 什么时候用 |
| --- | --- | --- |
| `content` / 内容 | 色相与彩度紧贴封面 | **默认值**。希望主题「就是这张专辑的味道」 |
| `tonalSpot` / 色调点缀 | Android 12 Material You 默认，低彩度、柔和 | 追求最稳妥、任何封面都不翻车 |
| `fidelity` / 保真 | 尽量还原封面原色 | 封面色彩本身很讲究，不想被算法改动 |
| `vibrant` / 鲜艳 | 彩度拉满 | 流行 / 电子乐，界面要更跳脱 |
| `expressive` / 表现力 | 主色相主动偏离封面 | 想要配色有变化和惊喜感 |
| `neutral` / 中性 | 接近灰阶，只留一丝色彩 | 长时间浏览歌单、阅读场景 |
| `monochrome` / 单色 | 完全灰阶 | 极简、不抢封面风头、无障碍需求 |
| `rainbow` / 彩虹 | 玩味方案，封面色相不进主题 | 额外暴露；想要明显区别于封面的个性配色 |
| `fruitSalad` / 水果沙拉 | 另一种玩味方案，色相刻意错开 | 额外暴露；同上 |

上表前 7 项是设置页的主推选项，后两项（`rainbow` / `fruitSalad`）由 SDK 提供、本项目一并暴露但不作推荐。切换 variant 只重建 `ColorScheme`，**不重新取色**。

```dart
// 唯一入口：SDK 的 fromSeed，variant 与对比度都是它的参数
final ColorScheme scheme = ColorScheme.fromSeed(
  seedColor: Color(palette.seedArgb),
  brightness: brightness,
  dynamicSchemeVariant: variant.scheme,   // ZhyColorVariant → DynamicSchemeVariant
  contrastLevel: contrast.value,          // ZhyContrastLevel → double
);
```

## 4. 对比度档位

`ZhyContrastLevel`，对应 `ColorScheme.fromSeed(contrastLevel: ...)`，取值区间 **-1.0 ~ 1.0**，`0.0` 是 Material 标准对比度。

| 档位 | 取值 | 效果与用途 |
| --- | --- | --- |
| `standard` / 标准 | `0.0` | Material 默认对比度，**默认值** |
| `medium` / 中等 | `0.5` | 前景更实，弱光环境下更清楚 |
| `high` / 高 | `1.0` | 最高对比度，等同系统「高对比度文字」设置 |
| `reduced` / 柔和 | `-1.0` | 低于标准，观感更轻，可读性会下降（给「不想要太硬」的用户，不推荐长时间使用） |

对比度不是「调透明度」：`ColorScheme.fromSeed` 会在 HCT 空间重算每个角色的 tone，因此 `onSurfaceVariant`、`outline` 等会成组变化，不会出现单个角色失配。要求：**标准及以上档位，正文与背景对比度不低于 4.5:1，大字/图标不低于 3:1**；`ZhyColor.contrastRatio(a, b)`（`color_utils.dart`）用 WCAG 公式算实际比值，可在测试里直接断言。

## 5. 亚克力表面用到的颜色角色

窗口半透明时，颜色角色分两套看：一套是 Flutter 画的内容（文字/卡片/控件），一套是窗口背后的 OS 材质。

| 角色 | 浅色方案用途 | 深色方案用途 |
| --- | --- | --- |
| `surface` | 亚克力/磨砂层的基底色（按材质模式决定是否带 alpha） | 同左，基底更深 |
| `surfaceTint` | 约 5% 不透明度叠加，让窗口「染」上主色 | 同左，通常 8% 以内 |
| `surfaceContainerLowest/Low` | 卡片、列表行底 | 卡片底，比窗口亮一档 |
| `surfaceContainerHigh/Highest` | 悬浮面板、菜单、弹窗 | 抽屉、播放条 |
| `onSurface` | 主文字 | 主文字 |
| `onSurfaceVariant` | 次要文字、说明 | 同左 |
| `outline` / `outlineVariant` | 卡片描边、分隔线（低 alpha） | 同左 |
| `primary` / `onPrimary` | 播放按钮、进度条、选中态 | 同左 |
| `scrim` | 弹窗遮罩（亚克力下降低不透明度，避免糊成一片） | 同左 |
| `MonetPalette.rankedArgb[1..]` | 渐变背景、次级强调色、封面投影 | 同左（深色下渐变更暗、更收） |

浅色/深色的差别不只是明度反转：深色下窗口「有多亮」取决于背后壁纸/桌面，所以透明模式的表面 alpha 要更低，否则整窗发灰。

## 6. 窗口材质与透明度模型

枚举 `ZhyWindowMaterial`（`lib/core/theme/window_material.dart`）共 6 种，各自的 Win32 行为：

| 模式 | Flutter 侧 | Win32 层 | 可用条件 |
| --- | --- | --- | --- |
| `solid` 实色 | 不透明，`isOpaque == true` | 不启用背景效果（`DWMSBT_NONE`） | 始终可用，回退终点，性能最好 |
| `acrylic` 亚克力 | 表面透明，背景交给 DWM | Win11 22H2+ 用 `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE, DWMSBT_TRANSIENTWINDOW)`；Win10/早期 Win11 用 `SetWindowCompositionAttribute` + `ACCENT_ENABLE_ACRYLICBLURBEHIND` | Win10 1803+ / Win11 |
| `mica` Mica | 表面透明 | `DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW` | Win11 22H2+（`minWindows11`） |
| `micaAlt` Mica Alt | 表面透明 | `DWMSBT_TABBEDWINDOW`（标签式 Mica，层间层次更明显） | Win11 22H2+ |
| `blur` 高斯模糊 | 表面透明 | `SetWindowCompositionAttribute` + `ACCENT_ENABLE_BLURBEHIND`（Aero 模糊，只有模糊没磨砂颗粒） | Win10+ |
| `simulated` 模拟磨砂 | **不透明**，自绘：封面渐变 + 实时模糊 + 噪点（`isSimulated == true`） | 不调用任何效果 API | 始终可用；远程桌面/虚拟机、旧版 Win10、用户想要实心窗口时的体面退路 |

枚举上还带着判定用的元数据：`usesSystemEffect`（是否需要把 Flutter 渲染面设为透明并把背景交给 DWM）、`minWindows11`、`isOpaque`、`isSimulated`、`fromName()`（持久化名字还原，未知名字回落到 `acrylic`）。

Win32 细节（`lib/core/win32/`）：

- `DwmSetWindowAttribute` 另负责：`DWMWA_USE_IMMERSIVE_DARK_MODE`（深色标题栏）、`DWMWA_WINDOW_CORNER_PREFERENCE`（圆角：不圆/小圆角/圆角）、`DWMWA_BORDER_COLOR`（边框色，跟随主题）。
- `SetWindowCompositionAttribute` + `ACCENT_POLICY` 的 `GradientColor` 是 **AABBGGRR** 字节序（与常规 ARGB 的 R/B 相反），写反会得到错色。
- 版本探测：Win11 判定用 build ≥ 22000（`minWindows11`），Mica 的 `SYSTEMBACKDROP_TYPE` 需要 22621（22H2）。
- 降级：API 返回非 `S_OK`、或「透明效果」被系统关闭、或远程桌面场景，自动切 `simulated` 并写日志；用户可在设置里手动锁定模式，避免反复试探。

**关键前提：Flutter 表面必须真的透明。** OS 的 Mica/亚克力画在窗口**背后**，Flutter 侧画一块不透明底就完全看不见：

```dart
await windowManager.waitUntilReadyToShow(windowOptions, () async {
  // 只在 usesSystemEffect 的模式下才需要透明
  await windowManager.setBackgroundColor(
    material.usesSystemEffect ? Colors.transparent : colors.surface,
  );
  await windowManager.show();
});
```

```dart
Scaffold(
  // 系统效果模式必须显式透明，否则默认底色会盖死 Mica/亚克力
  backgroundColor: material.usesSystemEffect ? Colors.transparent : null,
  body: Stack(
    children: [
      if (material.isSimulated) const FrostedBackground(), // 自绘渐变 + 模糊 + 噪点
      content, // 内容坐在带 alpha 的 surfaceContainer* 玻璃面板上
    ],
  ),
)
```

内容不直接坐在裸亚克力上，而是坐在带 alpha 的玻璃面板上（`ZhyTokens.glassTintOpacity`），这样文字可读性可控；`glassHighlightOpacity` 给面板顶部加一条 1px 内高光，是「像玻璃」的关键。

## 7. 自定义颜色

入口：设置 → 主题 → 取色来源，三选一：

| 来源 | 行为 | 存储 |
| --- | --- | --- |
| 跟随封面（Monet） | 每次换封面重新取色并写缓存 | 只存开关 |
| 自定义 | 停用 Monet，使用用户颜色 | `theme.seedArgb`（int） |
| 跟随系统（Android 后续） | 由平台提供动态色（`MaterialYouSource` 的另一实现） | 只存开关 |

选择器自研，不引入第三方包：

- **HSV 面板**：`CustomPaint` + `GestureDetector` 画色相条 + 明度/饱和度方块，拖动时 `HSVColor.fromColor` / `toColor` 互转；拖动过程只更新预览，松手才落盘（避免每秒写 prefs）。
- **Hex 输入**：用 `ZhyColor.tryParseHex(input)`（支持 `#RGB`/`#RRGGBB`/`#AARRGGBB`、可省略 `#`）校验，非法输入边框转 `colorScheme.error` 且不生效；回显用 `ZhyColor.toHexRgb` / `toHexArgb`。
- **预设色**：M3 基准色板若干，一键填入。
- 实时预览：改动立即重建 `ColorScheme`，整个窗口（含窗口材质底色）即时变化。

存储键（`core/storage/prefs.dart`）：

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `theme.source` | String | `cover` | `cover` / `custom` / `system` |
| `theme.seedArgb` | int | — | 自定义种子色 ARGB |
| `theme.variant` | String | `content` | 9 种 variant 的枚举名（`ZhyColorVariant.fromName`） |
| `theme.contrast` | String | `standard` | 4 档对比度（`ZhyContrastLevel`） |
| `theme.mode` | String | `system` | `system` / `light` / `dark` |
| `window.material` | String | `acrylic` | `ZhyWindowMaterial.fromName` 的枚举名 |

## 8. 无障碍

- 对比度由算法保证：`ColorScheme.fromSeed(contrastLevel:)` 在 HCT 空间重算 tone，配对关系由算法维护，而不是靠肉眼调。
- 为什么需要档位：同一套 M3 配色在低质量 TN 屏、强光环境、视力较弱用户身上的可读性差异很大；档位让用户一次点击换到更清晰的前景。`reduced` 明确标注「可读性会下降」，属于观感优先选项。
- 亚克力模式下背景是动态图像，对比度无法预设，因此：内容坐在带 alpha 的玻璃面板上（`ZhyTokens.glassTintOpacity`，注释里给出 0.3 ~ 0.6 的可读区间）；开启「高对比度」时把所有表面 alpha 提到不透明（退化到 `solid` 观感）。
- 语义与键盘：图标按钮带 `tooltip`/`Semantics` 标签；播放页支持空格播放/暂停、左右方向键 seek；焦点顺序与视觉顺序一致。

## 9. 设计令牌（`ZhyTokens`）

令牌走 `ThemeExtension` 而不是全局常量，理由有两个：① `ThemeExtension.lerp` 让深浅色切换、切歌换色时玻璃模糊强度与描边透明度**平滑过渡**而不是「啪」地跳变；② 组件只需 `Theme.of(context).extension<ZhyTokens>()`，不必 import 任何业务代码，避免 UI 反向依赖设置层。

| 令牌 | 用途 |
| --- | --- |
| `glassBlurSigma` | 「模拟磨砂」与玻璃面板的模糊半径（逻辑像素） |
| `glassTintOpacity` | 玻璃面板覆盖在窗口材质之上的染色不透明度（0.3 ~ 0.6 是可读区间） |
| `glassStrokeOpacity` | 玻璃面板 1px 描边的透明度 |
| `glassHighlightOpacity` | 玻璃面板顶部内高光的透明度（「像玻璃」的关键） |
| `noiseOpacity` | 噪点叠加层透明度，极低值即可消除大面积渐变的色带 |
| `shadowOpacity` / `coverShadowOpacity` | 普通面板投影 / 大封面投影（后者更重） |
| `panelRadius` / `cardRadius` / `pillRadius` / `coverRadius` | 面板 / 卡片 / 药丸控件 / 封面圆角 |
| `titleBarHeight` / `sidebarWidth` / `playerBarHeight` / `listRowHeight` | 无边框窗口的标题栏高度、侧栏宽度、播放条高度、列表行高 |
| `fast` / `normal` / `slow` / `emphasized` / `pageTransition` | 微交互（hover、按压）/ 常规动画 / 大动作 / M3 表达性动画 / 页面切换时长 |
| `ZhyTokens.hoverOverlay` / `pressedOverlay` | 悬浮态 0.06 / 按压态 0.10 的叠加蒙层强度（静态常量） |
| `ZhyTokens.standardCurve` / `decelerateCurve` / `accelerateCurve` | `easeInOutCubicEmphasized` / `easeOutCubic` / `easeInCubic`；曲线不进 `ThemeExtension`，因为曲线之间没有有意义的线性插值 |

**这些不是固定数值**：每种窗口材质、明暗模式各给一套 `ZhyTokens`（例如 `solid` 下 `glassBlurSigma` 为 0、`simulated` 下取有效模糊值），通过 `ThemeData(extensions: [tokens])` 注入，切换材质时由 `lerp` 平滑过渡。

`ColorScheme` + 令牌的组装（节选）：

```dart
ColorScheme buildScheme({
  required ZhyColorVariant variant,
  required ZhyContrastLevel contrast,
  required int seedArgb,
  required Brightness brightness,
}) => ColorScheme.fromSeed(
  seedColor: Color(seedArgb),
  brightness: brightness,
  dynamicSchemeVariant: variant.scheme,
  contrastLevel: contrast.value,
);

ThemeData buildTheme({
  required ColorScheme colors,
  required ZhyTokens tokens,
  required ZhyWindowMaterial material,
}) => ThemeData(
  useMaterial3: true,
  colorScheme: colors,
  // 系统效果模式必须透明，否则盖死 Mica/亚克力
  scaffoldBackgroundColor: material.usesSystemEffect ? Colors.transparent : colors.surface,
  extensions: <ThemeExtension<dynamic>>[tokens],
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder()},
  ),
);
```

> 组件取色的统一写法：颜色走 `Theme.of(context).colorScheme`，尺寸/模糊/时长走 `Theme.of(context).extension<ZhyTokens>()!` —— 不允许在组件里出现硬编码色值、模糊 sigma 或动画毫秒数。
