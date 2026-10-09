import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/window_drag_region.dart';
import '../../core/utils/format.dart';
import '../../data/models/lyric.dart';
import '../../data/models/song.dart';
import 'lyric_view.dart';
import 'player_bar.dart';
import 'player_controller.dart';
import 'queue_view.dart';

/// 打开全屏播放页（沉浸式 Now Playing）。
///
/// 用 `opaque: true`：这一页的背景现在是**不透明**的（模糊封面 + 不透明主题底色，
/// 见 [_ImmersiveBackdrop]）。既然它自己不透明，就没有理由让 Flutter
/// 继续渲染下面那一整棵页面树 —— 那样既浪费 GPU，又会让后方歌单的
/// 文字在半透明区域里隐隐透上来。
Future<void> openNowPlaying(BuildContext context, {bool showQueue = false}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) => NowPlayingPage(
            initialTab: showQueue ? NowPlayingTab.queue : NowPlayingTab.lyric,
          ),
      transitionsBuilder:
          (
            BuildContext context,
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
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
    ),
  );
}

enum NowPlayingTab { lyric, queue }

/// 全屏播放页。
class NowPlayingPage extends ConsumerStatefulWidget {
  const NowPlayingPage({super.key, this.initialTab = NowPlayingTab.lyric});

  final NowPlayingTab initialTab;

  @override
  ConsumerState<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends ConsumerState<NowPlayingPage> {
  late NowPlayingTab _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Song? song = state.current;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 沉浸式底图：当前封面放大 + 重度模糊，再叠主题色。
          _ImmersiveBackdrop(song: song),

          SafeArea(
            child: Column(
              children: <Widget>[
                _Header(onClose: () => Navigator.of(context).maybePop()),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(flex: 5, child: _LeftPane(state: state)),
                        const SizedBox(width: 28),
                        Expanded(
                          flex: 4,
                          child: _RightPane(
                            tab: _tab,
                            onTabChanged: (NowPlayingTab tab) =>
                                setState(() => _tab = tab),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 沉浸式背景：**不透明**的高斯模糊。
///
/// 早先的做法是"半透明底色 + 半透明模糊封面"，两层各留一半透光率，
/// 累加之后整页仍有约 25% 是通透的 —— 于是后面歌单页的歌名、行高分割线
/// 会隐隐透上来，读歌词时非常干扰。
///
/// 现在的分层是：最底层铺**完全不透明**的主题表面色兜底，
/// 模糊封面只作为"上色"叠在上面，再压一层主题色渐变保证对比度。
/// 既保住了"背景跟着封面走"的氛围，又彻底隔绝了后方内容。
class _ImmersiveBackdrop extends StatelessWidget {
  const _ImmersiveBackdrop({required this.song});

  final Song? song;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 不透明兜底。这一层是"看不穿"的唯一保证。
        ColoredBox(color: scheme.surface),
        if (song?.coverUrl != null)
          // 放大 1.2 倍再模糊：高斯模糊会让画面四周出现一圈变淡的边，
          // 放大可以把它推到可视区域之外，避免出现暗角。
          Transform.scale(
            scale: 1.2,
            child: Opacity(
              opacity: 0.58,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  // 比之前更重：要的是"色块氛围"，不是"看得清画面"。
                  sigmaX: 96,
                  sigmaY: 96,
                  tileMode: TileMode.decal,
                ),
                child: CoverImage(url: song!.coverUrl, fit: BoxFit.cover),
              ),
            ),
          ),
        // 主题色染色：把封面的杂色统一进当前配色体系，
        // 同时把标题与歌词的对比度拉回可读区间。
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                scheme.surface.withValues(alpha: 0.62),
                scheme.surface.withValues(alpha: 0.88),
              ],
            ),
          ),
        ),
        const Positioned.fill(child: NoiseOverlay(opacity: 0.04)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Stack(
        children: <Widget>[
          // 这一页盖住了标题栏，所以窗口的拖动区必须在这里补一份，
          // 否则进入沉浸页之后整个窗口就拖不动了。
          const Positioned.fill(child: WindowDragRegion()),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: Row(
                children: <Widget>[
                  IconButton(
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 26,
                    ),
                    tooltip: '收起',
                    onPressed: onClose,
                  ),
                  const Spacer(),
                  Text(
                    '正在播放',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  // 与左侧的收起按钮等宽，标题才能真正居中。
                  const SizedBox(width: 48),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeftPane extends ConsumerWidget {
  const _LeftPane({required this.state});

  final PlayerUiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Song? song = state.current;
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );

    if (song == null) {
      return Center(
        child: Text(
          '还没有在播放的曲目',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Flexible(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double side = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : 320;
              final double size = side.clamp(160, 380);
              return AnimatedContainer(
                duration: tokens.slow,
                curve: ZhyTokens.standardCurve,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(tokens.panelRadius),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: tokens.coverShadowOpacity,
                      ),
                      blurRadius: 48,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: CoverImage(
                  url: song.coverUrl,
                  width: size,
                  height: size,
                  borderRadius: BorderRadius.circular(tokens.panelRadius),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 28),
        Text(
          song.title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${song.artistLabel}${song.album == null ? '' : ' · ${song.album}'}',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        Row(
          children: <Widget>[
            SizedBox(
              width: 46,
              child: Text(
                ZhyFormat.duration(state.position),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: ProgressSlider(
                position: state.position,
                duration: state.duration,
                compact: true,
                onSeek: controller.seek,
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                ZhyFormat.duration(
                  state.duration > Duration.zero ? state.duration : null,
                ),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 与播放条一致：随机与循环合并成一个按钮循环切换。
            IconButton(
              iconSize: 22,
              tooltip: '${state.mode.label}：${state.mode.description}（点击切换）',
              icon: Icon(
                _modeIcon(state.mode),
                color: state.mode == ZhyPlaybackMode.sequential
                    ? null
                    : scheme.primary,
              ),
              onPressed: controller.cyclePlaybackMode,
            ),
            IconButton(
              iconSize: 30,
              tooltip: '上一首',
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: () => controller.previous(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Material(
                color: scheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: controller.togglePlayPause,
                  child: SizedBox(
                    width: 54,
                    height: 54,
                    child: Icon(
                      state.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 30,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              iconSize: 30,
              tooltip: '下一首',
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: () => controller.next(),
            ),
          ],
        ),
      ],
    );
  }

  /// 播放模式图标（与播放条保持同一套映射）。
  static IconData _modeIcon(ZhyPlaybackMode mode) => switch (mode) {
    ZhyPlaybackMode.sequential => Icons.playlist_play_rounded,
    ZhyPlaybackMode.loopAll => Icons.repeat_rounded,
    ZhyPlaybackMode.loopOne => Icons.repeat_one_rounded,
    ZhyPlaybackMode.shuffle => Icons.shuffle_rounded,
  };
}

class _RightPane extends ConsumerWidget {
  const _RightPane({required this.tab, required this.onTabChanged});

  final NowPlayingTab tab;
  final ValueChanged<NowPlayingTab> onTabChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return GlassPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              _TabButton(
                label: '歌词',
                selected: tab == NowPlayingTab.lyric,
                onTap: () => onTabChanged(NowPlayingTab.lyric),
              ),
              const SizedBox(width: 8),
              _TabButton(
                label:
                    '队列 (${ref.watch(playerControllerProvider).queue.length})',
                selected: tab == NowPlayingTab.queue,
                onTap: () => onTabChanged(NowPlayingTab.queue),
              ),
              const Spacer(),
              if (tab == NowPlayingTab.queue)
                IconButton(
                  icon: const Icon(Icons.clear_all_rounded, size: 18),
                  tooltip: '清空队列',
                  onPressed: () =>
                      ref.read(playerControllerProvider.notifier).clearQueue(),
                ),
            ],
          ),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.4)),
          Expanded(
            child: tab == NowPlayingTab.lyric
                ? const _LyricPanel()
                : const QueueListView(),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: tokens.fast,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(tokens.pillRadius),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            // 内置字体只有 w400 一个字面，请求 w600 会被引擎描边合成
            // （中文小字因此发虚、笔画不匀），所以这里恒为 w500；
            // 选中态只靠下面的 color 区分。
            fontWeight: FontWeight.w500,
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 把歌词接到 provider 上。
///
/// 这一层只做"读状态 + 接线"，歌词的布局、滚动与动画全在 [LyricView] 里：
/// 位置每 200ms 变一次，重建范围被压在这一个 `select` 上 —— 播放条、
/// 封面、队列都不会跟着刷。
class _LyricPanel extends ConsumerWidget {
  const _LyricPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Lyric? lyric = ref.watch(currentLyricProvider);
    final Duration position = ref.watch(
      playerControllerProvider.select((PlayerUiState state) => state.position),
    );

    return LyricView(
      lyric: lyric,
      // provider 的 null 就是"还没拿到结果"（当前曲目在取歌词）。
      loading: lyric == null,
      position: position,
      onSeek: ref.read(playerControllerProvider.notifier).seek,
    );
  }
}
