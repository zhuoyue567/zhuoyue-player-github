import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/glass.dart';
import '../../core/utils/format.dart';
import '../../data/models/song.dart';
import 'player_controller.dart';
import 'playback_extras.dart';

/// 底部常驻播放条。
///
/// 它对三种"没有歌可放"的中间态都有明确交代，而不是显示一个空壳：
/// 队列为空（提示去发现音乐）、正在解析地址（转圈）、解析失败（红色说明 + 重试）。
class PlayerBar extends ConsumerWidget {
  const PlayerBar({
    super.key,
    required this.onOpenNowPlaying,
    required this.onOpenQueue,
    this.queueOpen = false,
  });

  /// 点击封面 / 标题：打开全屏播放页。
  final VoidCallback onOpenNowPlaying;

  /// 点击队列按钮：开关右侧的队列 island。
  final VoidCallback onOpenQueue;

  /// 队列 island 当前是否展开，用于给按钮一个"已展开"的视觉状态。
  final bool queueOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );
    final Song? song = state.current;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: SizedBox(
        height: tokens.playerBarHeight,
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: <Widget>[
              // ---- 左：当前曲目 ----
              Expanded(
                flex: 3,
                child: song == null
                    ? _EmptyHint()
                    : _NowPlayingInfo(
                        song: song,
                        busy: state.resolving,
                        qualityLabel: state.qualityLabel,
                        onQualityChanged: controller.reloadCurrent,
                        onTap: onOpenNowPlaying,
                      ),
              ),

              // ---- 中：控制 + 进度 ----
              Expanded(
                flex: 5,
                child: SizedBox(
                  height: double.infinity,
                  child: Column(
                    // 整体在播放条里垂直居中，两行之间留一点呼吸。
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _TransportControls(state: state, controller: controller),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 26,
                        // 有错误时**顶掉进度条**显示原因，而不是只弹一条
                        // 一闪而过的提示：播放失败是"用户此刻最需要知道的事"，
                        // 而且它必须一直待在那里让用户看清（以前只有 SnackBar，
                        // 一旦自动跳曲或用户没注意就彻底消失了）。
                        child: state.error != null
                            ? _PlaybackErrorRow(
                                state: state,
                                controller: controller,
                              )
                            : _ProgressRow(
                                state: state,
                                controller: controller,
                              ),
                      ),
                    ],
                  ),
                ),
              ),

              // ---- 右：音量与辅助入口 ----
              Expanded(
                flex: 3,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    _VolumeControl(state: state, controller: controller),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.graphic_eq_rounded, size: 18),
                      tooltip: '均衡器',
                      onPressed: () => showEqualizerDialog(context),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.queue_music_rounded,
                        size: 20,
                        color: queueOpen ? scheme.primary : null,
                      ),
                      tooltip: queueOpen ? '收起播放队列' : '展开播放队列',
                      // 队列为空时也保持可点：island 里会写清"队列是空的"，
                      // 比按钮直接变灰更好懂；而且展开后总要能收起来。
                      onPressed: onOpenQueue,
                    ),
                    IconButton(
                      icon: const Icon(Icons.open_in_full_rounded, size: 18),
                      tooltip: '全屏播放页',
                      onPressed: song == null ? null : onOpenNowPlaying,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(
          Icons.library_music_outlined,
          size: 26,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '还没有正在播放的曲目\n去「发现音乐」挑一首吧',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _NowPlayingInfo extends StatelessWidget {
  const _NowPlayingInfo({
    required this.song,
    required this.busy,
    this.qualityLabel,
    required this.onQualityChanged,
    required this.onTap,
  });

  final Song song;
  final bool busy;

  /// **实际**拿到的音质（不是用户选的那一档）。
  final String? qualityLabel;

  /// 改完音质后重新加载当前曲目，让新档位当场生效。
  final Future<void> Function() onQualityChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(tokens.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: <Widget>[
            Stack(
              alignment: Alignment.center,
              children: <Widget>[
                CoverImage(url: song.coverUrl, size: 46, showShadow: true),
                if (busy)
                  SizedBox(
                    width: 46,
                    height: 46,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(tokens.coverRadius),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          '${song.artistLabel} · ${song.source.label}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 音质按钮放在这里（而不是右侧按钮堆）：它显示的是
                      // **实际**拿到的档位，属于"这首歌的信息"。
                      PlaybackQualityChip(
                        source: song.source,
                        actualLabel: qualityLabel,
                        onChanged: onQualityChanged,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放失败时顶替进度条的一行：原因 + 重试 + 关闭。
///
/// 独立成一行而不是塞进 SnackBar，是因为"这首为什么放不了"必须能停下来
/// 看清楚 —— SnackBar 会在自动跳曲时被顶掉，用户永远读不完。
class _PlaybackErrorRow extends StatelessWidget {
  const _PlaybackErrorRow({required this.state, required this.controller});

  final PlayerUiState state;
  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(Icons.error_outline_rounded, size: 15, color: scheme.error),
        const SizedBox(width: 6),
        Expanded(
          child: Tooltip(
            message: state.error ?? '',
            child: Text(
              state.error ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: scheme.error),
            ),
          ),
        ),
        TextButton(
          onPressed: controller.retry,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 24),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('重试', style: TextStyle(fontSize: 11.5)),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 14),
          tooltip: '关闭提示',
          onPressed: controller.dismissError,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 22, height: 22),
        ),
      ],
    );
  }
}

class _TransportControls extends StatelessWidget {
  const _TransportControls({required this.state, required this.controller});

  final PlayerUiState state;
  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasTrack = state.hasTrack;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // 随机与循环合并成一个按钮循环切换。
        //
        // 之前是两个独立按钮（随机开关 + 三态循环），但它们表达的是同一件事
        // ——"接下来怎么放"，摆两个既占地方又要用户同时理解两个状态。
        IconButton(
          icon: Icon(
            _modeIcon(state.mode),
            size: 20,
            color: state.mode == ZhyPlaybackMode.sequential
                ? null
                : scheme.primary,
          ),
          tooltip: '${state.mode.label}：${state.mode.description}（点击切换）',
          onPressed: controller.cyclePlaybackMode,
        ),
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded, size: 24),
          tooltip: '上一首',
          onPressed: hasTrack ? () => controller.previous() : null,
        ),
        // 主播放键做成实心圆，视觉重心明确。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Material(
            color: hasTrack ? scheme.primary : scheme.surfaceContainerHighest,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: hasTrack ? controller.togglePlayPause : null,
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  state.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 24,
                  color: hasTrack ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.skip_next_rounded, size: 24),
          tooltip: '下一首',
          onPressed: hasTrack ? () => controller.next() : null,
        ),
      ],
    );
  }

  /// 播放模式的图标。顺序播放用"列表+箭头"而不是灰掉的循环图标：
  /// 灰掉会被误读成"这个按钮不可用"。
  static IconData _modeIcon(ZhyPlaybackMode mode) => switch (mode) {
    ZhyPlaybackMode.sequential => Icons.playlist_play_rounded,
    ZhyPlaybackMode.loopAll => Icons.repeat_rounded,
    ZhyPlaybackMode.loopOne => Icons.repeat_one_rounded,
    ZhyPlaybackMode.shuffle => Icons.shuffle_rounded,
  };
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.state, required this.controller});

  final PlayerUiState state;
  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 40,
          child: Text(
            ZhyFormat.duration(state.position),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ProgressSlider(
            position: state.position,
            duration: state.duration,
            enabled: state.hasTrack,
            onSeek: controller.seek,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            ZhyFormat.duration(
              state.duration > Duration.zero ? state.duration : null,
            ),
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// 进度条。
///
/// 自己维护拖拽中的本地值：如果直接把 `状态里的 position` 绑给 Slider，
/// 播放中的每一帧 position 更新都会把用户正在拖动的滑块拽回去，
/// 表现为"进度条拖不动"。
class ProgressSlider extends StatefulWidget {
  const ProgressSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.enabled = true,
    this.compact = false,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final bool enabled;

  /// 紧凑模式（用于全屏播放页的控制条）。
  final bool compact;

  @override
  State<ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<ProgressSlider> {
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    final double total = widget.duration.inMilliseconds / 1000.0;
    final double current =
        _dragSeconds ??
        (widget.position.inMilliseconds / 1000.0).clamp(
          0.0,
          total <= 0 ? 0.0 : total,
        );
    final double max = total <= 0 ? 1.0 : total;
    final bool interactive = widget.enabled && total > 0;

    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: widget.compact ? 5 : 4,
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: widget.compact ? 7 : 6,
        ),
        overlayShape: RoundSliderOverlayShape(
          overlayRadius: widget.compact ? 16 : 14,
        ),
      ),
      child: Slider(
        value: current.clamp(0.0, max),
        max: max,
        onChanged: interactive
            ? (double value) => setState(() => _dragSeconds = value)
            : null,
        onChangeEnd: interactive
            ? (double value) {
                setState(() => _dragSeconds = null);
                widget.onSeek(Duration(milliseconds: (value * 1000).round()));
              }
            : null,
      ),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.state, required this.controller});

  final PlayerUiState state;
  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final IconData icon = state.volume <= 0.001
        ? Icons.volume_off_rounded
        : state.volume < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

    // 记住静音前的音量，取消静音时恢复，而不是直接跳到 100%。
    return Row(
      children: <Widget>[
        IconButton(
          icon: Icon(icon, size: 20),
          tooltip: state.volume <= 0.001 ? '取消静音' : '静音',
          onPressed: () =>
              controller.setVolume(state.volume <= 0.001 ? 0.7 : 0.0),
        ),
        SizedBox(
          width: 84,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: state.volume.clamp(0.0, 1.0),
              onChanged: controller.setVolume,
            ),
          ),
        ),
      ],
    );
  }
}
