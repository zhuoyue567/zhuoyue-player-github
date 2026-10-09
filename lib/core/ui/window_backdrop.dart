import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/cover_cache.dart';
import '../theme/monet.dart';
import '../theme/theme_providers.dart';
import '../theme/theme_settings.dart';
import '../theme/window_material.dart';
import 'glass.dart';

/// 窗口最底层的背景。
///
/// 这一个 widget 同时承担三件事，把它们放在一起是有意的：
///
/// 1. **画背景** —— 按当前窗口材质决定是"什么都别画，交给 DWM"
///    还是"自己画一层封面渐变 + 模糊 + 噪点"；
/// 2. **同步封面 → 主题色** —— 它已经在加载封面字节了，顺手喂给莫奈取色器，
///    避免为了取色再下载一次同一张图（这是本项目里最容易踩的性能坑）；
/// 3. **承载切歌时的背景交叉淡入**。
class WindowBackdrop extends ConsumerStatefulWidget {
  const WindowBackdrop({super.key, required this.child, this.coverUrl});

  final Widget child;

  /// 当前播放曲目的封面地址；为空时回落到主题色渐变。
  final String? coverUrl;

  @override
  ConsumerState<WindowBackdrop> createState() => _WindowBackdropState();
}

class _WindowBackdropState extends ConsumerState<WindowBackdrop> {
  Uint8List? _coverBytes;
  String? _loadedUrl;

  @override
  void initState() {
    super.initState();
    _syncCover();
  }

  @override
  void didUpdateWidget(covariant WindowBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl) {
      _syncCover();
    }
  }

  Future<void> _syncCover() async {
    final String? url = widget.coverUrl;
    if (url == null || url.isEmpty) {
      if (mounted) {
        setState(() {
          _coverBytes = null;
          _loadedUrl = null;
        });
      }
      ref.read(coverPaletteProvider.notifier).clear();
      return;
    }

    final Uint8List? bytes = await ref.read(coverCacheProvider).bytesFor(url);
    // 期间可能又切歌了，这时结果已经过时，直接丢弃，避免"背景是上一首"。
    if (!mounted || widget.coverUrl != url) return;

    setState(() {
      _coverBytes = bytes;
      _loadedUrl = url;
    });
    await ref.read(coverPaletteProvider.notifier).updateFromBytes(bytes);
  }

  @override
  Widget build(BuildContext context) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final MonetPalette? palette = ref.watch(coverPaletteProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyWindowMaterial material = settings.material;

    final Widget backdrop;
    if (material.isOpaque) {
      backdrop = _SurfaceBackdrop(scheme: scheme);
    } else if (material.usesSystemEffect) {
      backdrop = _SystemEffectTint(
        scheme: scheme,
        palette: palette,
        opacity: settings.windowOpacity,
      );
    } else {
      backdrop = _SimulatedBackdrop(
        bytes: _coverBytes,
        useCover: settings.coverBackdrop,
        palette: palette,
        scheme: scheme,
        opacity: settings.windowOpacity,
        blurSigma: settings.blurSigma,
        animate: settings.animatedBackdrop,
        animationKey: _loadedUrl,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 背景完全不接受指针事件：否则它会挡住窗口拖拽区。
        Positioned.fill(child: IgnorePointer(child: backdrop)),
        Positioned.fill(child: widget.child),
      ],
    );
  }
}

/// 实色背景：主题表面色 + 极轻的色相渐变，避免大面积纯色显得死板。
class _SurfaceBackdrop extends StatelessWidget {
  const _SurfaceBackdrop({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.surface,
            Color.alphaBlend(
              scheme.primaryContainer.withValues(alpha: 0.18),
              scheme.surface,
            ),
            Color.alphaBlend(
              scheme.tertiaryContainer.withValues(alpha: 0.12),
              scheme.surface,
            ),
          ],
        ),
      ),
    );
  }
}

/// 走系统材质时，Flutter 只铺一层**半透明染色**。
///
/// 铺满不透明色会把 DWM 画的毛玻璃彻底盖死（表现为"设置里开了亚克力但完全看不出来"）；
/// 什么都不铺又会让文字直接压在壁纸/窗口后面的内容上，可读性无法保证。
/// 折中是：一层很淡的、带主题色的渐变，既能看出毛玻璃，又保证对比度。
class _SystemEffectTint extends StatelessWidget {
  const _SystemEffectTint({
    required this.scheme,
    required this.palette,
    required this.opacity,
  });

  final ColorScheme scheme;
  final MonetPalette? palette;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    // 0.30~1.00 的"不透明度"映射到 0.06~0.62 的染色 alpha：
    // 直接把设置值当 alpha 用的话，默认档位就会把毛玻璃盖掉九成。
    final double alpha = (opacity * 0.55).clamp(0.06, 0.72);

    final Color accent = palette?.seedColor ?? scheme.primary;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.surface.withValues(alpha: (alpha * 0.85).clamp(0.0, 1.0)),
            Color.alphaBlend(
              accent.withValues(alpha: alpha * 0.16),
              scheme.surface.withValues(alpha: alpha),
            ),
            scheme.surface.withValues(alpha: alpha),
          ],
          stops: const <double>[0.0, 0.45, 1.0],
        ),
      ),
    );
  }
}

/// 「模拟磨砂」背景：不使用系统效果，全部自绘。
///
/// 这是三条退路里最重要的一条 —— 远程桌面、虚拟机、Win10 早期版本上
/// 系统级模糊都会失效，但用户对"亚克力播放器"的期待不会因此消失。
class _SimulatedBackdrop extends StatelessWidget {
  const _SimulatedBackdrop({
    required this.bytes,
    required this.useCover,
    required this.palette,
    required this.scheme,
    required this.opacity,
    required this.blurSigma,
    required this.animate,
    required this.animationKey,
  });

  final Uint8List? bytes;
  final bool useCover;
  final MonetPalette? palette;
  final ColorScheme scheme;
  final double opacity;
  final double blurSigma;
  final bool animate;
  final String? animationKey;

  @override
  Widget build(BuildContext context) {
    final List<Color> gradient = palette != null
        ? palette!.gradientStops(3)
        : <Color>[
            scheme.primaryContainer,
            scheme.tertiaryContainer,
            scheme.secondaryContainer,
          ];

    final Widget layer = _buildLayer(gradient);
    if (!animate) return layer;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // 默认的 layoutBuilder 会把新旧两层都居中堆叠，正合我们需要。
      child: KeyedSubtree(
        key: ValueKey<String>(animationKey ?? 'fallback'),
        child: layer,
      ),
    );
  }

  Widget _buildLayer(List<Color> gradient) {
    final Widget base = (useCover && bytes != null)
        ? ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: blurSigma,
              sigmaY: blurSigma,
              tileMode: TileMode.decal,
            ),
            child: Image.memory(
              bytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // 背景已经被模糊到看不出细节，关掉滤镜能让采样更快。
              filterQuality: FilterQuality.low,
            ),
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient
                    .map((Color c) => c.withValues(alpha: 0.9))
                    .toList(growable: false),
              ),
            ),
          );

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: scheme.surface),
        Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              base,
              // 用主题表面色压一层，把封面的杂色统一到当前配色体系里，
              // 保证正文文字在各处都够清楚。
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      scheme.surface.withValues(alpha: 0.42),
                      scheme.surface.withValues(alpha: 0.68),
                    ],
                  ),
                ),
              ),
              // 模糊之后必然出现色带，噪点在这一层最有用。
              const Positioned.fill(child: NoiseOverlay(opacity: 0.05)),
            ],
          ),
        ),
      ],
    );
  }
}
