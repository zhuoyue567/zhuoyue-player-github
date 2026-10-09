import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/cover_cache.dart';
import '../theme/app_theme.dart';
import '../theme/theme_tokens.dart';

/// 统一的封面显示组件。
///
/// 所有封面都走 [CoverCache]（内存 LRU → 磁盘 → 网络），因此：
/// - 滚动列表时同一张封面只下载一次；
/// - 莫奈取色器读的是同一份字节，不会为了取色再拉一遍图；
/// - 离线时列表依然有图（磁盘缓存命中）。
///
/// 另外两处刻意的处理：切歌时用 [AnimatedSwitcher] 交叉淡入而不是硬切；
/// 异步返回时校验 URL 是否仍然是当前值，避免快速滚动/切歌导致
/// "第 5 行的封面显示成了第 2 行的图"这类经典错位。
class CoverImage extends ConsumerStatefulWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.size,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.showShadow = false,
    this.placeholderIcon = Icons.music_note_rounded,
  });

  final String? url;
  final double? size;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxFit fit;
  final bool showShadow;
  final IconData placeholderIcon;

  @override
  ConsumerState<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<CoverImage> {
  Uint8List? _bytes;
  String? _resolvedUrl;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      // 立刻清掉旧图：宁可短暂空白，也不显示错误的封面。
      setState(() {
        _bytes = null;
        _resolvedUrl = null;
        _failed = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final String? url = widget.url;
    if (url == null || url.isEmpty) return;

    final Uint8List? bytes = await ref.read(coverCacheProvider).bytesFor(url);
    if (!mounted || widget.url != url) return;
    setState(() {
      _bytes = bytes;
      _resolvedUrl = url;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double? side = widget.size;
    final double width = widget.width ?? side ?? 48;
    final double height = widget.height ?? side ?? 48;
    final BorderRadius shape =
        widget.borderRadius ?? BorderRadius.circular(tokens.coverRadius);

    final Uint8List? bytes = _bytes;

    Widget content;
    if (bytes != null) {
      content = Image.memory(
        bytes,
        width: width,
        height: height,
        fit: widget.fit,
        gaplessPlayback: true,
        // 封面会在列表里被缩放显示，中等质量即可，省一次高质量重采样。
        filterQuality: FilterQuality.medium,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _Placeholder(
              width: width,
              height: height,
              icon: widget.placeholderIcon,
              scheme: scheme,
            ),
      );
    } else {
      content = _Placeholder(
        width: width,
        height: height,
        icon: widget.placeholderIcon,
        scheme: scheme,
        dimmed: _failed,
      );
    }

    Widget surface = ClipRRect(
      borderRadius: shape,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOut,
        child: KeyedSubtree(
          key: ValueKey<String>(
            _resolvedUrl ?? 'empty-${_failed ? "err" : "idle"}',
          ),
          child: content,
        ),
      ),
    );

    if (widget.showShadow) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: tokens.coverShadowOpacity),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: surface,
      );
    }

    return SizedBox(width: width, height: height, child: surface);
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.width,
    required this.height,
    required this.icon,
    required this.scheme,
    this.dimmed = false,
  });

  final double width;
  final double height;
  final IconData icon;
  final ColorScheme scheme;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final double iconSize = (width < height ? width : height) * 0.4;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.surfaceContainerHighest,
            Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.10),
              scheme.surfaceContainerHighest,
            ),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          dimmed ? Icons.image_not_supported_outlined : icon,
          size: iconSize.clamp(12, 64),
          color: scheme.onSurfaceVariant.withValues(alpha: dimmed ? 0.5 : 0.35),
        ),
      ),
    );
  }
}
