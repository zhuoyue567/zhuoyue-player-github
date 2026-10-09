import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// 主题设计令牌（design tokens）。
///
/// 走 [ThemeExtension] 而不是一堆全局常量，理由有两个：
///
/// 1. **能跟随主题切换插值**。Material 的深浅色切换、以及切歌时的取色切换，
///    都希望玻璃面板的模糊强度、描边透明度平滑过渡，而不是"啪"地跳变。
///    `ThemeExtension.lerp` 恰好提供了这个钩子。
/// 2. **组件取令牌时不必 import 任何业务代码**，`Theme.of(context).extension<ZhyTokens>()`
///    就够了，避免了 UI 组件反向依赖设置层。
@immutable
class ZhyTokens extends ThemeExtension<ZhyTokens> {
  const ZhyTokens({
    required this.glassBlurSigma,
    required this.glassTintOpacity,
    required this.glassStrokeOpacity,
    required this.glassHighlightOpacity,
    required this.noiseOpacity,
    required this.glassBackdropFilter,
    required this.shadowOpacity,
    required this.coverShadowOpacity,
    required this.panelRadius,
    required this.cardRadius,
    required this.pillRadius,
    required this.coverRadius,
    required this.titleBarHeight,
    required this.sidebarWidth,
    required this.playerBarHeight,
    required this.listRowHeight,
    required this.fast,
    required this.normal,
    required this.slow,
    required this.emphasized,
    required this.pageTransition,
  });

  /// 「模拟磨砂」与玻璃面板的模糊半径（逻辑像素）。
  final double glassBlurSigma;

  /// 玻璃面板覆盖在窗口材质之上的染色不透明度。
  /// 太小会看不清文字，太大会把系统毛玻璃盖死，0.3 ~ 0.6 是可读区间。
  final double glassTintOpacity;

  /// 玻璃面板 1px 描边的透明度。
  final double glassStrokeOpacity;

  /// 玻璃面板顶部内高光的透明度。这一层是"像玻璃"的关键：
  /// 真实玻璃边缘会把光折射出一条亮边。
  final double glassHighlightOpacity;

  /// 噪点叠加层的透明度。极低的值即可消除大面积渐变的"色带"。
  final double noiseOpacity;

  /// 玻璃面板是否要用 [BackdropFilter] 模糊**自己身后的 Flutter 内容**。
  ///
  /// 只在「模拟磨砂」下为 true：那时面板背后是我们自绘的封面渐变，
  /// 模糊它才有意义。走系统材质时背后是 DWM 画的毛玻璃，
  /// 再叠一层 BackdropFilter 不但看不出差别，还白白多一个离屏渲染。
  final bool glassBackdropFilter;

  /// 普通面板投影。
  final double shadowOpacity;

  /// 大封面投影，比普通面板更重。
  final double coverShadowOpacity;

  final double panelRadius;
  final double cardRadius;
  final double pillRadius;
  final double coverRadius;

  final double titleBarHeight;
  final double sidebarWidth;
  final double playerBarHeight;
  final double listRowHeight;

  /// 微交互（hover、按压反馈）。
  final Duration fast;

  /// 常规动画（面板展开、颜色过渡）。
  final Duration normal;

  /// 大动作（页面切换、全屏播放器推入）。
  final Duration slow;

  /// 表达性动画（Material 3 的"emphasized"曲线时长）。
  final Duration emphasized;

  /// 页面切换时长。
  final Duration pageTransition;

  /// 悬浮态（hover / focus）下叠加在背景上的白色/黑色蒙层强度。
  static const double hoverOverlay = 0.06;
  static const double pressedOverlay = 0.10;

  /// 少量常用的 M3 缓动曲线。曲线不放进 [ThemeExtension]：
  /// `Curve` 之间没有有意义的线性插值，硬插值只会产生怪异的过渡。
  static const Curve standardCurve = Curves.easeInOutCubicEmphasized;
  static const Curve decelerateCurve = Curves.easeOutCubic;
  static const Curve accelerateCurve = Curves.easeInCubic;

  @override
  ZhyTokens copyWith({
    double? glassBlurSigma,
    double? glassTintOpacity,
    double? glassStrokeOpacity,
    double? glassHighlightOpacity,
    double? noiseOpacity,
    bool? glassBackdropFilter,
    double? shadowOpacity,
    double? coverShadowOpacity,
    double? panelRadius,
    double? cardRadius,
    double? pillRadius,
    double? coverRadius,
    double? titleBarHeight,
    double? sidebarWidth,
    double? playerBarHeight,
    double? listRowHeight,
    Duration? fast,
    Duration? normal,
    Duration? slow,
    Duration? emphasized,
    Duration? pageTransition,
  }) {
    return ZhyTokens(
      glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
      glassTintOpacity: glassTintOpacity ?? this.glassTintOpacity,
      glassStrokeOpacity: glassStrokeOpacity ?? this.glassStrokeOpacity,
      glassHighlightOpacity:
          glassHighlightOpacity ?? this.glassHighlightOpacity,
      noiseOpacity: noiseOpacity ?? this.noiseOpacity,
      glassBackdropFilter: glassBackdropFilter ?? this.glassBackdropFilter,
      shadowOpacity: shadowOpacity ?? this.shadowOpacity,
      coverShadowOpacity: coverShadowOpacity ?? this.coverShadowOpacity,
      panelRadius: panelRadius ?? this.panelRadius,
      cardRadius: cardRadius ?? this.cardRadius,
      pillRadius: pillRadius ?? this.pillRadius,
      coverRadius: coverRadius ?? this.coverRadius,
      titleBarHeight: titleBarHeight ?? this.titleBarHeight,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      playerBarHeight: playerBarHeight ?? this.playerBarHeight,
      listRowHeight: listRowHeight ?? this.listRowHeight,
      fast: fast ?? this.fast,
      normal: normal ?? this.normal,
      slow: slow ?? this.slow,
      emphasized: emphasized ?? this.emphasized,
      pageTransition: pageTransition ?? this.pageTransition,
    );
  }

  @override
  ZhyTokens lerp(covariant ZhyTokens? other, double t) {
    if (other == null) return this;
    return ZhyTokens(
      glassBlurSigma: _lerp(glassBlurSigma, other.glassBlurSigma, t),
      glassTintOpacity: _lerp(glassTintOpacity, other.glassTintOpacity, t),
      glassStrokeOpacity: _lerp(
        glassStrokeOpacity,
        other.glassStrokeOpacity,
        t,
      ),
      glassHighlightOpacity: _lerp(
        glassHighlightOpacity,
        other.glassHighlightOpacity,
        t,
      ),
      noiseOpacity: _lerp(noiseOpacity, other.noiseOpacity, t),
      // bool 没有插值语义，过半即切换。
      glassBackdropFilter: t < 0.5
          ? glassBackdropFilter
          : other.glassBackdropFilter,
      shadowOpacity: _lerp(shadowOpacity, other.shadowOpacity, t),
      coverShadowOpacity: _lerp(
        coverShadowOpacity,
        other.coverShadowOpacity,
        t,
      ),
      panelRadius: _lerp(panelRadius, other.panelRadius, t),
      cardRadius: _lerp(cardRadius, other.cardRadius, t),
      pillRadius: _lerp(pillRadius, other.pillRadius, t),
      coverRadius: _lerp(coverRadius, other.coverRadius, t),
      titleBarHeight: _lerp(titleBarHeight, other.titleBarHeight, t),
      sidebarWidth: _lerp(sidebarWidth, other.sidebarWidth, t),
      playerBarHeight: _lerp(playerBarHeight, other.playerBarHeight, t),
      listRowHeight: _lerp(listRowHeight, other.listRowHeight, t),
      fast: _lerpDuration(fast, other.fast, t),
      normal: _lerpDuration(normal, other.normal, t),
      slow: _lerpDuration(slow, other.slow, t),
      emphasized: _lerpDuration(emphasized, other.emphasized, t),
      pageTransition: _lerpDuration(pageTransition, other.pageTransition, t),
    );
  }

  static double _lerp(double a, double b, double t) => lerpDouble(a, b, t) ?? a;

  static Duration _lerpDuration(Duration a, Duration b, double t) => Duration(
    microseconds:
        lerpDouble(a.inMicroseconds, b.inMicroseconds, t)?.round() ??
        a.inMicroseconds,
  );
}
