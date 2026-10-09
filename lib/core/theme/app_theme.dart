import 'package:flutter/material.dart';

import 'theme_settings.dart';
import 'theme_tokens.dart';
import 'window_material.dart';

/// 由「用户设置 + 深浅色」推导出设计令牌。
///
/// 令牌里有一半的值取决于窗口材质：走系统毛玻璃时描边要更明显、高光要更亮，
/// 否则玻璃面板会糊在系统背景里分不清边界；而实色模式下这些装饰全部归零。
ZhyTokens buildZhyTokens(ZhyThemeSettings settings, Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  final bool opaque = settings.material.isOpaque;

  return ZhyTokens(
    glassBlurSigma: settings.blurSigma,
    glassTintOpacity: settings.panelOpacity,
    glassStrokeOpacity: opaque ? 0.06 : (dark ? 0.10 : 0.18),
    glassHighlightOpacity: opaque ? 0.0 : (dark ? 0.07 : 0.24),
    noiseOpacity: settings.material.isSimulated ? 0.035 : 0.0,
    glassBackdropFilter: settings.material.isSimulated,
    shadowOpacity: dark ? 0.45 : 0.16,
    coverShadowOpacity: dark ? 0.60 : 0.28,
    panelRadius: 20,
    cardRadius: 14,
    pillRadius: 999,
    coverRadius: 12,
    titleBarHeight: 44,
    sidebarWidth: 216,
    // 播放条高度。
    //
    // 从 88 提到 104 是因为 88 减去上下内边距只剩 68 ——
    // 而中间那一列要放"传输控件(40) + 间距 + 进度条(28)"约 72 像素，
    // 于是控件被挤到偏上、进度条贴着底边。多给 16 像素，
    // 整列才能舒展地垂直居中。
    playerBarHeight: 104,
    listRowHeight: 52,
    fast: const Duration(milliseconds: 120),
    normal: const Duration(milliseconds: 240),
    slow: const Duration(milliseconds: 420),
    emphasized: const Duration(milliseconds: 500),
    pageTransition: const Duration(milliseconds: 300),
  );
}

/// 把 [ColorScheme] + [ZhyTokens] + 窗口材质组装成最终的 [ThemeData]。
///
/// 这里的原则是：**主题只负责"材质与形状"，不负责具体页面布局**。
/// 组件级主题统一走 Material 3 的色角色（`surfaceContainer*`、`outlineVariant`
/// 等），这样换一个种子色 / 换一个 variant，整站观感会一起变，
/// 而不用去逐个页面改颜色。
ThemeData buildZhyTheme({
  required ColorScheme scheme,
  required ZhyTokens tokens,
  required ZhyWindowMaterial material,
  String? fontFamily,
}) {
  final bool dark = scheme.brightness == Brightness.dark;

  // 关键点：走系统材质时，Flutter 必须主动"交出"背景。
  // DWM 的毛玻璃只会从 Flutter 没有绘制像素的地方透出来 ——
  // 任何一层不透明底色（包括 Scaffold 的默认 surface）都会把它彻底盖死，
  // 表现为"设置了亚克力但看起来完全是实色"。
  final Color scaffoldColor = material.usesSystemEffect
      ? Colors.transparent
      : scheme.surface;

  final BorderRadius cardShape = BorderRadius.circular(tokens.cardRadius);
  final BorderRadius pillShape = BorderRadius.circular(tokens.pillRadius);

  /// zhuzi 没有的字形（emoji 之类）的兜底顺序。
  const List<String> fallbackFamilies = <String>[
    'Segoe UI',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
  ];

  /// 主题里每一处**显式写的** TextStyle 都必须用它来构造。
  ///
  /// 为什么必须这样：`ThemeData(fontFamily:)` 只派生 `textTheme` 那一套，
  /// 而**组件级样式会整体取代**对应那一档，而不是与之合并 ——
  /// `ButtonStyle.textStyle` / `AppBarTheme.titleTextStyle` /
  /// `ListTileTheme.titleTextStyle` / `ChipTheme.labelStyle` …这些一旦只写
  /// `fontSize`/`fontWeight`，字体族就丢了，那段文字会**掉回系统默认字体**。
  ///
  /// 这曾经是一个真实且很难看的 bug：按钮文字（「播放全部」「添加到队列」、
  /// 「更改目录」……）全是系统默认的黑体，而旁边的正文是内置竹石 ——
  /// 两者字形与笔画粗细都不一样，用户看到的就是"部分字体的字重不对"。
  /// 由 test/theme_font_family_test.dart 钉住。
  TextStyle themed({
    double? fontSize,
    FontWeight? fontWeight,
    double? height,
    double? letterSpacing,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fallbackFamilies,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scaffoldColor,
    extensions: <ThemeExtension<dynamic>>[tokens],
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,

    // 全局字体。null 表示不指定，走 Flutter 的默认字体链。
    //
    // 附带一组 fallback。注意 fallback **只在主字体缺该字形时**才会生效：
    // 实测内置的 zhuzi.ttf 本身覆盖了拉丁字母与数字（A-Z / a-z / 0-9 都有
    // 字形），所以排在前面的 Segoe UI 其实轮不到它来渲染。这组 fallback
    // 真正兜的是 zhuzi 没有的字形（emoji 之类），避免出现"豆腐块"。
    //
    // 还有一条与字重有关的事实：zhuzi.ttf 只有 w400 一个字面。请求 w600/w700
    // 时引擎只能描边"合成"，中文小字会发虚、笔画粗细不匀。所以主题与页面里
    // 统一只用 w400 / w500，不请求它没有的字重 —— 这条不变量由
    // test/typography_weight_test.dart 钉住。
    fontFamily: fontFamily,
    fontFamilyFallback: fallbackFamilies,

    // ---- 分隔线：用 outlineVariant 的弱化版，避免线条比内容还抢眼 ----
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: dark ? 0.35 : 0.6),
      thickness: 1,
      space: 1,
    ),

    // ---- 顶栏：透明，交给外层玻璃面板去画背景 ----
    appBarTheme: AppBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: themed(
        color: scheme.onSurface,
        fontSize: 16,
        fontWeight: FontWeight.w500,
      ),
    ),

    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: tokens.shadowOpacity),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: cardShape),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.panelRadius + 8),
      ),
      titleTextStyle: themed(
        color: scheme.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w500,
      ),
      contentTextStyle: themed(
        color: scheme.onSurfaceVariant,
        fontSize: 14,
        height: 1.5,
      ),
    ),

    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(
        alpha: dark ? 0.5 : 0.7,
      ),
      isDense: true,
      hintStyle: themed(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: pillShape,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: pillShape,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: pillShape,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: pillShape,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
    ),

    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: cardShape),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minVerticalPadding: 10,
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: themed(
        color: scheme.onSurface,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: themed(
        color: scheme.onSurfaceVariant,
        fontSize: 12,
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.onSurface.withValues(alpha: 0.38);
          }
          return scheme.onSurfaceVariant;
        }),
        overlayColor: WidgetStateProperty.resolveWith((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.pressed)) {
            return scheme.primary.withValues(alpha: 0.16);
          }
          return scheme.primary.withValues(alpha: 0.08);
        }),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),

    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      secondaryActiveTrackColor: scheme.primary.withValues(alpha: 0.5),
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      trackShape: const RoundedRectSliderTrackShape(),
      showValueIndicator: ShowValueIndicator.never,
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 3,
    ),

    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.secondaryContainer,
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      labelStyle: themed(color: scheme.onSurfaceVariant, fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: pillShape),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),

    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll<double>(6),
      radius: const Radius.circular(3),
      thumbVisibility: const WidgetStatePropertyAll<bool>(false),
      trackVisibility: const WidgetStatePropertyAll<bool>(false),
      interactive: true,
      crossAxisMargin: 2,
      mainAxisMargin: 2,
      thumbColor: WidgetStatePropertyAll<Color>(
        scheme.onSurfaceVariant.withValues(alpha: 0.35),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: cardShape),
      textStyle: themed(color: scheme.onSurface, fontSize: 13),
    ),

    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(
          scheme.surfaceContainerHigh,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: cardShape),
        ),
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: themed(color: scheme.onInverseSurface, fontSize: 12),
      waitDuration: const Duration(milliseconds: 500),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: themed(
        color: scheme.onInverseSurface,
        fontSize: 13,
      ),
      actionTextColor: scheme.inversePrimary,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: cardShape),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: pillShape),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: themed(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: pillShape),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        textStyle: themed(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: pillShape),
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: themed(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: pillShape),
        ),
        side: WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle>(
          themed(fontSize: 12.5, fontWeight: FontWeight.w500),
        ),
      ),
    ),

    // 桌面端不需要移动端那种"整页横向推入"的手感，
    // 淡入 + 极小位移更接近原生 Windows 应用的观感。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.windows: _ZhyFadeThroughTransitionsBuilder(),
        TargetPlatform.linux: _ZhyFadeThroughTransitionsBuilder(),
        TargetPlatform.macOS: _ZhyFadeThroughTransitionsBuilder(),
      },
    ),
  );
}

/// 淡入 + 2% 垂直位移的页面切换。
class _ZhyFadeThroughTransitionsBuilder extends PageTransitionsBuilder {
  const _ZhyFadeThroughTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<double> curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// 便捷读取设计令牌。
///
/// 拿不到扩展时回落到一套默认值而不是抛异常：主题扩展可能因为
/// 局部 `Theme(...)` 覆盖而缺失，为此崩掉一个页面并不值得。
extension ZhyThemeContext on BuildContext {
  ZhyTokens get tokens =>
      Theme.of(this).extension<ZhyTokens>() ??
      buildZhyTokens(const ZhyThemeSettings(), Theme.of(this).brightness);
}
