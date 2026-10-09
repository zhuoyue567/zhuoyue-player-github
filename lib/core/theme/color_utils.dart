import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 颜色工具集合。
///
/// 这里刻意不直接用 `Color.red` / `Color.value` / `Color.withOpacity`：
/// 它们在 Flutter 3.27 之后都已标记废弃（`Color` 改为浮点分量表示），
/// 统一走 [Color.toARGB32] 与 [Color.withValues] 以免将来编译不过。
class ZhyColor {
  const ZhyColor._();

  /// 应用在「没有封面 / 封面还没解析出来」时使用的兜底种子色。
  ///
  /// 取 Material 3 的基线紫，保证任何情况下界面都是成体系的一套配色，
  /// 而不是临时拼出来的灰色。
  static const int fallbackSeedArgb = 0xFF6750A4;

  /// 解析用户输入的十六进制颜色，容忍 `#RGB` / `#RRGGBB` / `#AARRGGBB`
  /// 以及带不带 `#`、大小写混写的情况。
  static int? tryParseHex(String input) {
    String s = input.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.startsWith('0x') || s.startsWith('0X')) s = s.substring(2);
    // 允许用户在颜色值里混入空格，例如 "#1a 73e8"。
    s = s.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return null;
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) return null;

    switch (s.length) {
      case 3: // RGB，每一位复制一遍扩展成 RRGGBB
        final int r = int.parse('${s[0]}${s[0]}', radix: 16);
        final int g = int.parse('${s[1]}${s[1]}', radix: 16);
        final int b = int.parse('${s[2]}${s[2]}', radix: 16);
        return 0xFF000000 | (r << 16) | (g << 8) | b;
      case 6:
        return 0xFF000000 | int.parse(s, radix: 16);
      case 8:
        return int.parse(s, radix: 16);
      default:
        return null;
    }
  }

  /// 输出 `#RRGGBB`，用于展示与持久化。
  static String toHexRgb(int argb) =>
      '#${(argb & 0x00FFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// 输出 `#AARRGGBB`。
  static String toHexArgb(int argb) =>
      '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

  /// 是否属于"深色"，用 WCAG 相对亮度判断。
  static bool isDark(Color color) => color.computeLuminance() < 0.5;

  /// 在 [background] 上放文字时应该用亮色还是暗色前景。
  ///
  /// 阈值 0.45 而不是 0.5：经验上偏暗一侧的中间调用深色文字更易读。
  static Color onColor(Color background) => background.computeLuminance() > 0.45
      ? const Color(0xFF1A1A1A)
      : Colors.white;

  /// WCAG 对比度，范围 1.0 ~ 21.0。用于自检主题可读性。
  static double contrastRatio(Color a, Color b) {
    final double la = a.computeLuminance();
    final double lb = b.computeLuminance();
    final double lighter = math.max(la, lb);
    final double darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// 线性混色，`t = 0` 返回 [a]，`t = 1` 返回 [b]。
  static Color mix(Color a, Color b, double t) {
    final double k = t.clamp(0.0, 1.0);
    return Color.fromARGB(
      _lerpInt(a.a, b.a, k),
      _lerpInt(a.r, b.r, k),
      _lerpInt(a.g, b.g, k),
      _lerpInt(a.b, b.b, k),
    );
  }

  /// 覆盖一层不透明度，语义比 `withValues` 更明确一点。
  static Color alpha(Color color, double opacity) =>
      color.withValues(alpha: opacity.clamp(0.0, 1.0));

  /// 把颜色朝着更亮 / 更暗推，用于生成亚克力表面的高光与描边。
  static Color shift(Color color, double amount) => amount >= 0
      ? mix(color, Colors.white, amount)
      : mix(color, Colors.black, -amount);

  /// 把颜色当成 HSL 调整彩度，`factor > 1` 更鲜艳，`< 1` 更灰。
  ///
  /// 用于「模拟磨砂」背景：直接从封面取来的颜色往往过艳，
  /// 大块铺开会很吵，需要压一下。
  static Color saturate(Color color, double factor) {
    final HSLColor hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation((hsl.saturation * factor).clamp(0.0, 1.0))
        .toColor();
  }

  static int _lerpInt(double a, double b, double t) =>
      ((a + (b - a) * t) * 255).round().clamp(0, 255);
}
