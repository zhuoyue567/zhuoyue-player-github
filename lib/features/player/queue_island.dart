import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/glass.dart';
import 'player_controller.dart';
import 'queue_view.dart';

/// 从右侧滑入的「播放队列 island」。
///
/// 刻意**不是**一个全屏页面：用户想看的往往只是"下一首是什么"，
/// 为这个动作铺满整个窗口会打断他正在浏览的歌单 —— 尤其是播放列表
/// 本身就在右边的歌单页里时，盖住它完全得不偿失。
/// 所以做成一块浮在内容之上的玻璃岛：滑入不改变导航层级，
/// 再点一次就滑出去，浏览位置与滚动位置都不受影响。
class QueueIsland extends ConsumerWidget {
  const QueueIsland({
    super.key,
    required this.open,
    required this.onClose,
    this.width = 320,
  });

  final bool open;
  final VoidCallback onClose;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final PlayerUiState state = ref.watch(playerControllerProvider);

    // 关闭时把 offset 推到 1.05 之外：Stack 默认 hardEdge 裁剪，
    // 于是它既看不见也点不到；再叠一个 IgnorePointer 是为了让意图显式。
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedSlide(
        offset: open ? Offset.zero : const Offset(1.05, 0),
        duration: tokens.normal,
        curve: open ? ZhyTokens.decelerateCurve : ZhyTokens.accelerateCurve,
        child: AnimatedOpacity(
          opacity: open ? 1 : 0,
          duration: tokens.normal,
          child: SizedBox(
            width: width,
            child: GlassPanel(
              // island 要有明确的边界：圆角加大一点、投影保留，
              // 这样它读起来是"浮在内容之上的一块"，而不是内容的一部分。
              radius: tokens.panelRadius + 6,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.queue_music_rounded,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '播放队列',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${state.queue.length} 首',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.clear_all_rounded, size: 17),
                        tooltip: '清空队列',
                        onPressed: state.queue.isEmpty
                            ? null
                            : () => ref
                                  .read(playerControllerProvider.notifier)
                                  .clearQueue(),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.keyboard_arrow_right_rounded,
                          size: 20,
                        ),
                        tooltip: '收起队列',
                        onPressed: onClose,
                      ),
                    ],
                  ),
                  Divider(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                    height: 12,
                  ),
                  // island 收起时列表**仍在树里**（只是被移出可视区），所以
                  // 必须把"打开了"这件事传下去：列表据此在滑入的第一帧就
                  // 把当前曲目摆到中间，而不是等用户自己去找。
                  Expanded(child: QueueListView(active: open)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
