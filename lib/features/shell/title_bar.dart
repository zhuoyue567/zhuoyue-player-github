import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/window_drag_region.dart';

/// 自绘标题栏。
///
/// 用 `TitleBarStyle.hidden` 保留系统缩放边框、只隐藏系统标题栏，
/// 这样窗口仍然可以从边缘拖拽改变大小（很多"无边框"实现会丢掉这个能力，
/// 用户会以为窗口坏了）。
///
/// 这里**不放搜索框**：左侧导航已经有独立的「搜索」分区，而搜索页自带输入框、
/// 联想与历史记录。两个入口指向同一件事，用户反而要在"上面那个框"和
/// "左边那一页"之间猜哪个才是完整的搜索 —— 所以标题栏只留应用标识与窗口按钮。
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
  });

  final String title;

  final List<Widget> actions;

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_syncMaximized());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final bool maximized = await windowManager.isMaximized();
    if (mounted && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: tokens.titleBarHeight,
      child: Stack(
        children: <Widget>[
          // 整条标题栏都能拖窗口 —— 包括标题与窗口按钮之间那一大段
          // "看起来什么都没有"的空白（搜索框删掉之后这段更宽了）。
          // 放在 Stack 最底层，上层的窗口按钮会先吃掉自己的手势，
          // 剩下的空隙才归拖动。
          const Positioned.fill(child: WindowDragRegion()),
          Positioned.fill(
            child: Row(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[scheme.primary, scheme.tertiary],
                          ),
                        ),
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          size: 12,
                          color: scheme.onPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        widget.title,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                ...widget.actions,
                const SizedBox(width: 6),
                _CaptionButton(
                  icon: Icons.remove_rounded,
                  tooltip: '最小化',
                  onPressed: () => unawaited(windowManager.minimize()),
                ),
                _CaptionButton(
                  icon: _maximized
                      ? Icons.filter_none_rounded
                      : Icons.crop_square_rounded,
                  tooltip: _maximized ? '向下还原' : '最大化',
                  // 最大化状态由 onWindowMaximize / onWindowUnmaximize
                  // 监听回调统一更新，按钮自己不用维护状态。
                  onPressed: () => unawaited(toggleMaximize()),
                ),
                _CaptionButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  // 关闭按钮用系统红，这是桌面端不会出错的惯例。
                  hoverColor: const Color(0xFFC42B1C),
                  hoverForeground: Colors.white,
                  onPressed: () => unawaited(windowManager.close()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 窗口按钮。做成有 hover 背景的小方块，符合 Windows 11 的原生手感。
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.hoverColor,
    this.hoverForeground,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? hoverColor;
  final Color? hoverForeground;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = _hovered
        ? (widget.hoverColor ?? scheme.onSurface.withValues(alpha: 0.08))
        : Colors.transparent;
    final Color foreground = _hovered && widget.hoverForeground != null
        ? widget.hoverForeground!
        : scheme.onSurfaceVariant;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 44,
            height: 32,
            color: background,
            child: Icon(widget.icon, size: 14, color: foreground),
          ),
        ),
      ),
    );
  }
}
