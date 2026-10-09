import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_tokens.dart';

/// 噪点纹理。
///
/// 存在的唯一理由是消除「色带」（banding）：大面积的低透明度渐变在
/// 8 位色深的屏幕上必然出现台阶，叠一层极淡的噪点就能把它打散。
/// 纹理只生成一次（128×128 平铺），运行时零分配。
class ZhyNoise {
  ZhyNoise._();

  static const int _size = 128;

  static ui.Image? _image;
  static Future<ui.Image>? _pending;

  static ui.Image? get current => _image;

  static Future<ui.Image> image() {
    final ui.Image? ready = _image;
    if (ready != null) return Future<ui.Image>.value(ready);
    final Future<ui.Image>? pending = _pending;
    if (pending != null) return pending;

    final Completer<ui.Image> completer = Completer<ui.Image>();
    final Uint8List pixels = Uint8List(_size * _size * 4);
    // 固定种子：每次启动的颗粒形态一致，避免"噪点在跳"的廉价感。
    final math.Random random = math.Random(20240613);
    for (int i = 0; i < pixels.length; i += 4) {
      final int value = 96 + random.nextInt(64);
      pixels[i] = value;
      pixels[i + 1] = value;
      pixels[i + 2] = value;
      pixels[i + 3] = 255;
    }

    ui.decodeImageFromPixels(pixels, _size, _size, ui.PixelFormat.rgba8888, (
      ui.Image image,
    ) {
      _image = image;
      _pending = null;
      completer.complete(image);
    });
    _pending = completer.future;
    return completer.future;
  }

  /// 提前生成，避免第一帧才去做这件事。
  static Future<void> warmUp() => image();
}

/// 用噪点纹理铺满一块区域。
class NoiseOverlay extends StatelessWidget {
  const NoiseOverlay({super.key, required this.opacity, this.tileSize = 128});

  final double opacity;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    if (opacity <= 0) return const SizedBox.shrink();
    final ui.Image? noise = ZhyNoise.current;
    if (noise == null) {
      // 纹理还没准备好，顺手补生成；这一帧先不画噪点。
      unawaited(ZhyNoise.image());
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: CustomPaint(
        painter: _NoisePainter(
          image: noise,
          opacity: opacity,
          tileSize: tileSize,
        ),
      ),
    );
  }
}

class _NoisePainter extends CustomPainter {
  const _NoisePainter({
    required this.image,
    required this.opacity,
    required this.tileSize,
  });

  final ui.Image image;
  final double opacity;
  final double tileSize;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = tileSize / image.width;
    final Paint paint = Paint()
      ..shader = ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        // 用 diagonal3Values 而不是 `..scale()`：后者在 vector_math 里
        // 已标记废弃（会走一次完整的矩阵乘法），这里只需要一个缩放矩阵。
        Matrix4.diagonal3Values(scale, scale, 1.0).storage,
      )
      // 关键：shader 会覆盖 paint.color，只能靠 colorFilter 来缩放透明度。
      // modulate 会把纹理的 alpha 乘以滤镜的 alpha，正好实现"可控强度的噪点"。
      ..colorFilter = ColorFilter.mode(
        Color.fromRGBO(255, 255, 255, opacity),
        BlendMode.modulate,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_NoisePainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.opacity != opacity ||
      oldDelegate.tileSize != tileSize;
}

/// 玻璃面板：亚克力材质在界面里的"零件"。
///
/// 三层结构，缺一层都会削弱"这是玻璃"的观感：
/// 1. **模糊层**（可选）—— 模糊身后的 Flutter 内容；
/// 2. **染色层** —— 主题色 + 描边 + 顶部内高光。高光那一笔是点睛：
///    真实玻璃的边缘会把光折射出一条亮边；
/// 3. **噪点层** —— 打散渐变色带。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius,
    this.padding,
    this.margin,
    this.tintOpacity,
    this.borderOpacity,
    this.blurSigma,
    this.tint,
    this.showHighlight = true,
    this.showShadow = true,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? tintOpacity;
  final double? borderOpacity;
  final double? blurSigma;
  final Color? tint;
  final bool showHighlight;
  final bool showShadow;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius shape = BorderRadius.circular(
      radius ?? tokens.panelRadius,
    );
    final Color base = tint ?? scheme.surfaceContainerHigh;
    final double alpha = (tintOpacity ?? tokens.glassTintOpacity).clamp(
      0.0,
      1.0,
    );

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: base.withValues(alpha: alpha),
        borderRadius: shape,
        border: Border.all(
          color: scheme.outlineVariant.withValues(
            alpha: borderOpacity ?? tokens.glassStrokeOpacity,
          ),
        ),
      ),
      child: Stack(
        children: <Widget>[
          if (showHighlight && tokens.glassHighlightOpacity > 0)
            Positioned(
              // 只画顶部一条**亮边**，而不是"顶部 12% 高度的白色渐变"。
              //
              // 之前用的是 LinearGradient(白 → 透明, stops: [0, 0.12])：
              // 效果是在每条玻璃面板的上沿铺一条明显更亮的横带，到 12% 处
              // 戛然而止。因为它是"一块亮区"，观感上就变成了
              // 「面板上半部分被压暗了一块」，面板越大越明显。
              // 用户反馈的播放栏顶部、左上账户卡片都是这个原因 ——
              // 而且它与窗口背景无关，所以挪动窗口并不会消失。
              //
              // 真实玻璃折射出的是**亮边**而不是亮区。这里改成 1.2px 的细亮线，
              // 并在左右两端淡出，既不产生横带，又仍然是"玻璃"该有的样子。
              top: 0,
              left: 0,
              right: 0,
              height: 1.2,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: <Color>[
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(
                          alpha: tokens.glassHighlightOpacity,
                        ),
                        Colors.white.withValues(alpha: 0),
                      ],
                      stops: const <double>[0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          if (tokens.noiseOpacity > 0)
            Positioned.fill(child: NoiseOverlay(opacity: tokens.noiseOpacity)),
          Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ],
      ),
    );

    if (tokens.glassBackdropFilter) {
      surface = ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: blurSigma ?? tokens.glassBlurSigma * 0.6,
            sigmaY: blurSigma ?? tokens.glassBlurSigma * 0.6,
          ),
          child: surface,
        ),
      );
    } else if (clipBehavior == Clip.antiAlias) {
      surface = ClipRRect(borderRadius: shape, child: surface);
    }

    // 阴影画在**裁剪之外**。
    //
    // 原来的顺序是"先画阴影，再 ClipRRect 整个结果"，而阴影本来就画在盒子
    // 外沿，于是被自己那次裁剪整条削掉 —— 所有玻璃面板其实都没有投影，
    // 整个界面因此发平。把阴影挪到最外层，才既保留裁剪又留得住投影。
    if (showShadow && tokens.shadowOpacity > 0) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: tokens.shadowOpacity * 0.5),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: surface,
      );
    }

    if (margin != null) {
      surface = Padding(padding: margin!, child: surface);
    }
    return surface;
  }
}
