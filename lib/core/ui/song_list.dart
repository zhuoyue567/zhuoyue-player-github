/// 内容页共用的歌曲 / 歌单展示组件。
///
/// 为什么都放在一个文件里：五个内容页（发现、歌单、搜索、下载、以及歌单详情）
/// 展示的是同一套东西 —— 一首歌的行、一首歌的卡片、一个歌单的卡片。
/// 如果每页各写一份，先崩掉的一定是"密度和交互不一致"：
/// 有的页双击播放、有的页单击播放；有的页显示时长、有的页不显示。
/// 这里把它们收敛成唯一的实现，页面只负责取数据和拼版面。
///
/// 依赖方向说明：这个文件属于 `core/ui`，但刻意 import 了
/// `features/player/player_controller.dart`。因为"点一首歌就播放"是本应用的
/// 核心交互，若为了层次纯洁把它改成回调参数，每个页面都要再写一遍
/// `playSong(...)`，反而更容易漏。播放器控制器本身不依赖任何 UI，
/// 不存在循环依赖。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/collection.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../features/player/player_controller.dart';
import '../theme/app_theme.dart';
import '../theme/theme_tokens.dart';
import 'cover_image.dart';
import 'glass.dart';

// ---------------------------------------------------------------------------
// 格式化工具
// ---------------------------------------------------------------------------

/// 时长格式：`m:ss`，超过一小时用 `h:mm:ss`；null 显示 `--:--`。
///
/// 曲目列表里的时长必须列成一条对齐的窄列，长短不一的写法会让整列看起来
/// 是"抖"的，这是列表观感里最容易被忽略的一处。
String formatDuration(Duration? duration) {
  if (duration == null) return '--:--';
  final int total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final int hours = total ~/ 3600;
  final int minutes = (total % 3600) ~/ 60;
  final int seconds = total % 60;
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours <= 0) return '$minutes:$ss';
  return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
}

/// 播放量 / 收藏数的中文习惯写法：`1.2万`、`3.4亿`。
///
/// 中文界面里 "12345" 远不如 "1.2万" 一眼能读，平台自己也这么显示。
String formatCount(int? count) {
  if (count == null || count <= 0) return '0';
  if (count < 10000) return '$count';
  // 先按「万」算，四舍五入到 9999.95 万以上就直接进到「亿」，
  // 否则会出现 "10000万" 这种没人这么写的数字。
  final double wan = count / 10000;
  if (wan < 9999.95) return '${_oneDecimal(wan)}万';
  return '${_oneDecimal(count / 100000000)}亿';
}

/// 一位小数，整数时不留 `.0`。
String _oneDecimal(double value) {
  final double rounded = (value * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return rounded.round().toString();
  return rounded.toStringAsFixed(1);
}

/// 把接口异常翻译成用户看得懂的一句话。
///
/// 直接把 `SocketException` 的原文丢到界面上，用户只会看到一串英文和堆栈。
String describeApiError(Object error) {
  if (error is MusicApiException) return error.message;
  final String text = error.toString();
  if (text.contains('SocketException') ||
      text.contains('Connection') ||
      text.contains('TimeoutException') ||
      text.contains('timed out')) {
    return '网络连接失败，请检查网络后重试';
  }
  if (text.contains('403')) return '音源拒绝了本次请求（403），请稍后重试';
  return '请求失败：$text';
}

/// 集合类型的中文名。
String collectionKindLabel(CollectionKind kind) => switch (kind) {
  CollectionKind.playlist => '歌单',
  CollectionKind.favorite => '我的收藏',
  CollectionKind.album => '专辑',
  CollectionKind.chart => '排行榜',
  CollectionKind.daily => '每日推荐',
  CollectionKind.artist => '艺人作品',
};

// ---------------------------------------------------------------------------
// 页面骨架
// ---------------------------------------------------------------------------

/// 页面内容的统一容器：限宽 1200、居中、24px 页边距。
///
/// 关键点是它**不画任何底色**。窗口的亚克力 / 毛玻璃只会在 Flutter
/// 没有绘制像素的地方透出来，一旦这里铺一层不透明背景，
/// 系统材质就被彻底盖死了（表现为"开了亚克力却完全是实色"）。
class PageContentContainer extends StatelessWidget {
  const PageContentContainer({
    super.key,
    required this.child,
    this.maxWidth = 1200,
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 24),
    this.fillHeight = false,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  /// 是否把可用高度撑满。
  /// 左右分栏（两侧各自滚动）的页面需要它为 true，普通上下滚动的页面保持 false。
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    Widget content = Padding(padding: padding, child: child);
    if (fillHeight) content = SizedBox.expand(child: content);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: content,
      ),
    );
  }
}

/// 悬浮状态探测器。
///
/// 把"鼠标是否压在这一块上"这个高频状态收敛在小组件内部：悬浮反馈只重绘
/// 这一块，而不是整页 —— 一屏几十个行 / 卡片时，这个差别是能感觉到的。
class HoverBuilder extends StatefulWidget {
  const HoverBuilder({
    super.key,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: widget.builder(context, _hovered),
    );
  }
}

// ---------------------------------------------------------------------------
// 空 / 错误状态
// ---------------------------------------------------------------------------

/// 统一的「空列表 / 出错了」占位块。
///
/// 每个页面都必须明确回答"为什么这里是空的"，而不是留一片白。
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.busy = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  /// 还在加载时把图标换成转圈："空"和"正在加载"长得一样是糟糕的体验。
  final bool busy;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (busy)
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          else
            Icon(
              icon,
              size: 40,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                ),
              ),
            ),
          if (action != null)
            Padding(padding: const EdgeInsets.only(top: 18), child: action!),
        ],
      ),
    );
  }
}

/// 错误占位块：普通失败给「重试」，登录失效给「去登录」。
///
/// 这两种情况的处理方式完全不同 —— 把登录失效也做成"重试"，
/// 用户会一直点一个永远不会成功的按钮。
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({
    super.key,
    required this.error,
    this.onRetry,
    this.onRequestLogin,
    this.padding,
  });

  final Object error;
  final VoidCallback? onRetry;

  /// 登录入口由外壳注入（登录弹窗是全局能力，不属于内容页）。
  final VoidCallback? onRequestLogin;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    // 先落到局部变量：公共字段没有类型提升，直接判断拿不到异常的成员。
    final Object failure = error;
    final MusicApiException? api = failure is MusicApiException
        ? failure
        : null;
    final bool needsLogin = api?.isAuthError ?? false;
    final String message = describeApiError(error);

    if (needsLogin) {
      return EmptyStateView(
        icon: Icons.lock_outline_rounded,
        title: '需要登录',
        message: onRequestLogin == null ? '$message\n请先在设置里登录对应账号' : message,
        padding:
            padding ?? const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        action: onRequestLogin == null
            ? null
            : FilledButton.icon(
                onPressed: onRequestLogin,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('去登录'),
              ),
      );
    }

    return EmptyStateView(
      icon: Icons.cloud_off_rounded,
      title: '加载失败',
      message: message,
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      action: onRetry == null
          ? null
          : OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// 歌曲列表
// ---------------------------------------------------------------------------

/// 曲目列表。
///
/// 统一用 [ListView.builder] 而不是 `Column`：歌单动辄上千首，
/// 一次性构建所有行会让滚动直接卡死。header / footer 也走同一条懒加载链路
/// （header 占第 0 项，footer 占最后一项），这样详情页的头部能跟着内容滚上去。
class SongListView extends ConsumerWidget {
  const SongListView({
    super.key,
    required this.songs,
    this.sourceLabel,
    this.showIndex = true,
    this.showAlbum = false,
    this.showSourceBadge = false,
    this.header,
    this.footer,
    this.emptyState,
    this.controller,
    this.onRefresh,
    this.onRemove,
    this.onDownload,
    this.padding,
    this.itemPadding,
  });

  final List<Song> songs;

  /// 覆盖来源徽标的文案（例如「网易云音乐」）；为 null 时用曲目自带的音源名。
  final String? sourceLabel;

  final bool showIndex;
  final bool showAlbum;
  final bool showSourceBadge;

  /// 列表头部（歌单信息、账户卡片等），会随内容一起滚动。
  final Widget? header;

  /// 列表尾部（"正在加载更多"、加载失败重试等）。
  final Widget? footer;

  final Widget? emptyState;
  final ScrollController? controller;
  final Future<void> Function()? onRefresh;

  /// 传入后每行出现「从队列移除」，参数是该行在 [songs] 中的下标。
  final void Function(int index)? onRemove;

  /// 传入后每行出现「下载」按钮。
  final void Function(Song song)? onDownload;

  final EdgeInsetsGeometry? padding;

  /// 单行的外边距，默认贴边（列表自带的 padding 已经留出了呼吸空间）。
  final EdgeInsetsGeometry? itemPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool hasHeader = header != null;
    final bool hasFooter = footer != null && songs.isNotEmpty;
    // 空列表也要占一项，否则连"空状态"都显示不出来。
    final int bodyCount = songs.isEmpty ? 1 : songs.length;
    final int itemCount = (hasHeader ? 1 : 0) + bodyCount + (hasFooter ? 1 : 0);
    final int firstSong = hasHeader ? 1 : 0;

    Widget list = ListView.builder(
      controller: controller,
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      // 有下拉刷新时必须允许"内容不到一屏也能拖动"，否则刷新手势会失效。
      physics: onRefresh != null ? const AlwaysScrollableScrollPhysics() : null,
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (hasHeader && index == 0) return header!;
        if (songs.isEmpty) {
          return emptyState ?? const SongListEmptyState();
        }
        final int songIndex = index - firstSong;
        if (songIndex >= songs.length) return footer!;
        final Song song = songs[songIndex];
        return Padding(
          padding: itemPadding ?? EdgeInsets.zero,
          child: SongRow(
            // key 带上下标：同一首歌在列表里可能重复出现（例如排行榜），
            // 只用 uid 会让两行的选中 / 悬浮状态串到一起。
            key: ValueKey<String>('${song.uid}#$songIndex'),
            song: song,
            index: songIndex,
            queue: songs,
            sourceLabel: sourceLabel,
            showIndex: showIndex,
            showAlbum: showAlbum,
            showSourceBadge: showSourceBadge,
            onRemove: onRemove == null ? null : () => onRemove!(songIndex),
            onDownload: onDownload == null ? null : () => onDownload!(song),
          ),
        );
      },
    );

    if (onRefresh != null) {
      // 桌面端主要靠刷新按钮，但列表被复用到别处时下拉刷新仍然好用，留着。
      list = RefreshIndicator(onRefresh: onRefresh!, child: list);
    }
    return list;
  }
}

/// [SongListView] 的默认空状态。
class SongListEmptyState extends StatelessWidget {
  const SongListEmptyState({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return EmptyStateView(
      icon: Icons.queue_music_rounded,
      title: '这里还没有曲目',
      message: message ?? '换个歌单，或者先在音源里收藏一些内容',
    );
  }
}

/// 一行曲目。
///
/// 交互约定（整个应用保持一致）：
/// - **单击**选中该行（为多选 / 键盘操作留位置，也给出明确的视觉反馈）；
/// - **双击**播放，行尾还有显式的播放按钮 —— 桌面用户两种习惯都有；
/// - 不可播放的曲目整体压暗 + 悬浮显示原因，点它只会解释原因，绝不静默失败。
class SongRow extends ConsumerStatefulWidget {
  const SongRow({
    super.key,
    required this.song,
    required this.index,
    this.queue,
    this.sourceLabel,
    this.showIndex = true,
    this.showAlbum = false,
    this.showSourceBadge = false,
    this.onRemove,
    this.onDownload,
  });

  final Song song;

  /// 在所属列表中的下标（从 0 开始，显示时会 +1）。
  final int index;

  /// 双击播放时的上下文列表：播放器会用它替换队列，
  /// 这样当前这首播完能自然接着往下走，而不是播完就停。
  final List<Song>? queue;

  final String? sourceLabel;
  final bool showIndex;
  final bool showAlbum;
  final bool showSourceBadge;

  final VoidCallback? onRemove;
  final VoidCallback? onDownload;

  @override
  ConsumerState<SongRow> createState() => _SongRowState();
}

class _SongRowState extends ConsumerState<SongRow> {
  bool _hovered = false;

  Song get _song => widget.song;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  /// 播放当前行。不可播放时只解释原因，不发任何请求。
  void _play() {
    if (!_song.playable) {
      _explainUnplayable();
      return;
    }
    unawaited(
      ref
          .read(playerControllerProvider.notifier)
          .playSong(_song, context: widget.queue),
    );
  }

  /// 「播放」按钮：当前曲目时变成播放 / 暂停开关，符合播放器的普遍预期。
  void _playOrToggle({required bool isCurrent}) {
    if (!_song.playable) {
      _explainUnplayable();
      return;
    }
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );
    if (isCurrent) {
      unawaited(controller.togglePlayPause());
      return;
    }
    unawaited(controller.playSong(_song, context: widget.queue));
  }

  void _enqueue({required bool next}) {
    if (!_song.playable) {
      _explainUnplayable();
      return;
    }
    ref.read(playerControllerProvider.notifier).enqueue(_song, next: next);
    _showMessage(context, next ? '已加入下一首播放' : '已加入播放队列');
  }

  void _explainUnplayable() {
    _showMessage(context, _song.unplayableReason ?? '该曲目当前不可播放');
  }

  void _copyInfo() {
    final String text = '${_song.title} - ${_song.artistLabel}';
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _showMessage(context, '已复制：$text');
  }

  void _handleMenu(String value) {
    switch (value) {
      case 'play':
        _play();
      case 'next':
        _enqueue(next: true);
      case 'queue':
        _enqueue(next: false);
      case 'download':
        widget.onDownload?.call();
      case 'remove':
        widget.onRemove?.call();
      case 'copy':
        _copyInfo();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 只监听"当前曲目"和"是否播放中"两个窄 provider：
    // 直接 watch 整个 playerControllerProvider 会让每一行都跟着进度条
    // 每秒重绘几十次。
    final Song? current = ref.watch(currentSongProvider);
    final bool playing = ref.watch(isPlayingProvider);
    final bool isCurrent = current != null && current.uid == _song.uid;
    final bool playable = _song.playable;

    // 背景优先级：正在播放 > 透明；悬浮蒙层最后叠上去，
    // 保证任何状态下都有即时反馈。
    //
    // 这里**没有**"选中行"这一档了：单击一行现在的语义是"播放这首"，
    // 不再是"选中它"，所以留着选中态既没有含义、又会让用户以为
    // "我点了怎么只是变了个色"。
    Color background = Colors.transparent;
    if (isCurrent) {
      background = scheme.primaryContainer.withValues(alpha: 0.35);
    }
    if (_hovered) {
      background = Color.alphaBlend(
        scheme.primary.withValues(alpha: ZhyTokens.hoverOverlay),
        background,
      );
    }

    Widget row = AnimatedContainer(
      duration: tokens.fast,
      curve: ZhyTokens.standardCurve,
      height: tokens.listRowHeight,
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(tokens.cardRadius),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            // ★ 单击选中 / 双击播放的 GestureDetector **只包内容区**，
            // 不要把右侧操作区也包进去。
            //
            // 之前它是包住整行的，而且是 `HitTestBehavior.opaque` 又带
            // `onDoubleTap`：于是点行尾的「…」时，手势竞技场里胜出的是整行
            // 那个识别器（带双击的识别器必须先等双击超时才能定胜负），
            // 结果就是**点了三个点没反应** —— 用户会以为菜单坏了。
            // 按钮自己赢下自己那块区域的点击，才是符合直觉的行为。
            child: MouseRegion(
              cursor: playable
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // ★ 单击就播放。
                //
                // 以前这里是"单击只选中、双击才播放"，于是用户点一行歌
                // 什么都不会发生，必须先点行首悬浮出来的播放键、或者在
                // 播放栏再按一次播放 —— 用户报的正是这个。
                // 播放器里点一首歌的默认预期就是"放这首"，双击反而不自然；
                // 而且带 `onDoubleTap` 的识别器必须先等双击超时才能定胜负，
                // 这也是之前"点行尾「…」没反应"的原因之一。
                onTap: _play,
                // 不可播放时只压暗主体信息，右侧操作按钮保持原样可用。
                child: Opacity(
                  opacity: playable ? 1 : 0.55,
                  child: Row(
                    children: <Widget>[
                      if (widget.showIndex)
                        _indexSlot(
                          scheme,
                          isCurrent: isCurrent,
                          playing: playing,
                        ),
                      CoverImage(
                        url: _song.coverUrl,
                        size: 40,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _titleBlock(scheme, isCurrent: isCurrent),
                      ),
                      if (widget.showSourceBadge) ...<Widget>[
                        const SizedBox(width: 10),
                        _sourceBadge(scheme, tokens),
                      ],
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 48,
                        child: Text(
                          formatDuration(_song.duration),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.85,
                            ),
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _actions(scheme, isCurrent: isCurrent, playing: playing),
        ],
      ),
    );

    // 悬浮检测留在整行上：鼠标停在行尾按钮上时，行首序号同样应该变成播放键。
    row = MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: row,
    );

    // 只有不可播放的行才包 Tooltip：给每一行都挂一个 Tooltip
    // 会在长列表里堆积大量 Overlay 条目。
    if (!playable) {
      row = Tooltip(message: _song.unplayableReason ?? '该曲目当前不可播放', child: row);
    }
    return row;
  }

  /// 序号位：鼠标移上来时变成播放按钮。
  ///
  /// 为什么把播放入口放在行首序号上：右侧那排图标（播放 / 下一首 / 加入队列 /
  /// 下载）在窄窗口下会把标题挤没，而且和序号功能重复 —— 序号本来就在
  /// "这一行的第几首"这个位置，把鼠标停上去变成播放键是列表的通用习惯。
  /// 右侧只留一个「…」，其余动作都在它的菜单里。
  Widget _indexSlot(
    ColorScheme scheme, {
    required bool isCurrent,
    required bool playing,
  }) {
    // 悬停时：当前曲目显示播放/暂停，其它行显示播放。
    final IconData hoverIcon = isCurrent && playing
        ? Icons.pause_rounded
        : Icons.play_arrow_rounded;

    return SizedBox(
      width: 32,
      child: Center(
        child: _hovered
            ? IconButton(
                icon: Icon(hoverIcon, size: 18),
                color: scheme.primary,
                tooltip: isCurrent && playing ? '暂停' : '播放',
                onPressed: () => _playOrToggle(isCurrent: isCurrent),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 26,
                  height: 26,
                ),
              )
            : isCurrent
            ? _PlayingBars(color: scheme.primary, playing: playing)
            : Text(
                '${widget.index + 1}',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  // 等宽数字：序号是 1、10、100 混在一起的窄列，
                  // 不等宽会左右跳动。
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _titleBlock(ColorScheme scheme, {required bool isCurrent}) {
    final String? album = _song.album;
    final String subtitle =
        widget.showAlbum && album != null && album.isNotEmpty
        ? '${_song.artistLabel} · $album'
        : _song.artistLabel;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            // 内置字体只有 w400 一个字面，请求 w600 会被引擎描边合成
            // （中文小字因此发虚、笔画不匀），所以这里恒为 w500；
            // "正在播放"只靠下面的 color 区分。
            fontWeight: FontWeight.w500,
            color: isCurrent ? scheme.primary : scheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }

  Widget _sourceBadge(ColorScheme scheme, ZhyTokens tokens) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(tokens.pillRadius),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Text(
        widget.sourceLabel ?? _song.source.label,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// 行尾操作区：**只留一个「…」**。
  ///
  /// 之前这里是"悬浮时浮现一排图标"（播放 / 下一首 / 加入队列 / 下载 / 移除）。
  /// 那排在窄窗口下会把标题挤到省略号，而且"播放"与行首序号重复、
  /// "下载"占一个常用位却不常用。现在全部收进「…」的菜单，
  /// 并且**常显**不再依赖悬浮 —— 用户不需要先猜"这里悬浮会出现东西"。
  Widget _actions(
    ColorScheme scheme, {
    required bool isCurrent,
    required bool playing,
  }) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz_rounded),
      iconSize: 18,
      tooltip: '更多',
      padding: EdgeInsets.zero,
      onSelected: _handleMenu,
      itemBuilder: (BuildContext context) => _menuItems(scheme),
    );
  }

  List<PopupMenuEntry<String>> _menuItems(ColorScheme scheme) {
    PopupMenuItem<String> item(
      String value,
      IconData icon,
      String label, {
      bool enabled = true,
    }) {
      return PopupMenuItem<String>(
        value: value,
        enabled: enabled,
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 16,
              color: enabled
                  ? scheme.onSurfaceVariant
                  : scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 10),
            Text(label),
          ],
        ),
      );
    }

    final bool playable = _song.playable;

    return <PopupMenuEntry<String>>[
      item('play', Icons.play_arrow_rounded, '播放', enabled: playable),
      item('next', Icons.skip_next_rounded, '下一首播放', enabled: playable),
      item('queue', Icons.queue_music_rounded, '加入队列'),
      if (widget.onDownload != null)
        // 不可播放的曲目没有可下载的音源。置灰而不是直接藏起来：
        // 用户能看出"这个动作存在，只是这首不行"，比菜单里凭空少一项好懂。
        item('download', Icons.download_rounded, '下载', enabled: playable),
      if (widget.onRemove != null)
        item('remove', Icons.playlist_remove_rounded, '从队列移除'),
      const PopupMenuDivider(),
      item('copy', Icons.content_copy_rounded, '复制歌曲信息'),
    ];
  }
}

/// 「正在播放」的跳动音柱。
///
/// 自绘而不是用动图：只有三根柱子、一个 [AnimationController]，
/// 开销可以忽略，还能跟着主题色走。暂停时停住而不是隐藏 —— 像"定格"，
/// 比突然消失安静。
class _PlayingBars extends StatefulWidget {
  const _PlayingBars({required this.playing, required this.color});

  final bool playing;
  final Color color;

  @override
  State<_PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<_PlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _PlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.playing) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) => CustomPaint(
          painter: _BarsPainter(phase: _controller.value, color: widget.color),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  const _BarsPainter({required this.phase, required this.color});

  final double phase;
  final Color color;

  /// 三根柱子的相位差：错开才像波形，同步起伏会像"呼吸灯"。
  static const List<double> _offsets = <double>[0.0, 0.35, 0.7];

  @override
  void paint(Canvas canvas, Size size) {
    const int count = 3;
    final double gap = size.width * 0.14;
    final double barWidth = (size.width - gap * (count - 1)) / count;
    final Paint paint = Paint()..color = color;

    for (int i = 0; i < count; i++) {
      final double wave =
          0.35 +
          0.65 * (0.5 + 0.5 * math.sin((phase + _offsets[i]) * 2 * math.pi));
      final double barHeight = size.height * wave;
      final Rect rect = Rect.fromLTWH(
        i * (barWidth + gap),
        size.height - barHeight,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.color != color;
}

// ---------------------------------------------------------------------------
// 卡片
// ---------------------------------------------------------------------------

/// 网格 / 横向轮播里的一张歌曲卡片。
///
/// 卡片宽度取自父级约束：放进 [GridView] 时自动撑满格子，放进横向
/// [ListView]（宽度无界）时必须由调用方给出 [width]。
class SongCard extends ConsumerWidget {
  const SongCard({
    super.key,
    required this.song,
    this.queue,
    this.width = 164,
    this.onTap,
  });

  final Song song;
  final List<Song>? queue;
  final double width;

  /// 额外的点击处理（例如埋点）；播放行为始终由卡片自己完成。
  final VoidCallback? onTap;

  /// 标题 + 间距 + 副标题占用的固定高度。
  ///
  /// 两个 [Text] 都显式设了 `height`，所以这个值是**确定**的：
  /// 布局不再依赖具体字体的度量，也就不会因为系统字体、
  /// 语言或文本缩放的变化而突然溢出。
  static const double textBlockHeight = 48;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool playable = song.playable;

    void play() {
      if (!playable) {
        _showMessage(context, song.unplayableReason ?? '该曲目当前不可播放');
        return;
      }
      onTap?.call();
      unawaited(
        ref
            .read(playerControllerProvider.notifier)
            .playSong(song, context: queue),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 横向轮播里子项拿到的是无界宽度，此时用构造参数 width；
        // 纵向网格里则是父级给的确定宽度。
        final double cardWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : width;

        // 让**封面**去吃掉多余或不足的高度，而不是让文字溢出。
        // 之前是"封面固定见方、总高度靠调用方猜"，结果轮播按 226 猜少了
        // 几像素，每张卡片底部都报 BOTTOM OVERFLOWED BY 3.0 PIXELS。
        // 把弹性放在图片上，这类问题就从根上不会再出现。
        final double maxCoverByHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight - textBlockHeight
            : cardWidth;
        final double coverSide = math.max(
          48.0,
          math.min(cardWidth, maxCoverByHeight),
        );

        final BorderRadius coverShape = BorderRadius.circular(
          tokens.cardRadius,
        );

        return HoverBuilder(
          cursor: playable
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          builder: (BuildContext context, bool hovered) {
            Widget card = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: play,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AnimatedSlide(
                    // 悬浮时封面轻轻抬起：比放大更克制，也不会糊掉封面。
                    offset: Offset(0, hovered ? -0.02 : 0),
                    duration: tokens.fast,
                    curve: ZhyTokens.decelerateCurve,
                    child: Stack(
                      children: <Widget>[
                        CoverImage(
                          url: song.coverUrl,
                          width: coverSide,
                          height: coverSide,
                          borderRadius: coverShape,
                          showShadow: hovered,
                        ),
                        if (hovered)
                          Positioned.fill(
                            child: Center(
                              child: _PlayOverlay(
                                tooltip: '播放',
                                onPressed: play,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artistLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            );

            if (!playable) {
              card = Opacity(
                opacity: 0.6,
                child: Tooltip(
                  message: song.unplayableReason ?? '该曲目当前不可播放',
                  child: card,
                ),
              );
            }
            return card;
          },
        );
      },
    );
  }
}

/// 歌单 / 收藏夹 / 专辑卡片。
class CollectionCard extends ConsumerWidget {
  const CollectionCard({
    super.key,
    required this.collection,
    this.onTap,
    this.subtitle,
    this.width = 168,
  });

  final MusicCollection collection;
  final VoidCallback? onTap;

  /// 副标题（创建者、曲目数等由调用方决定文案）。
  final String? subtitle;

  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int? playCount = collection.playCount;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double cardWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : width;

        return HoverBuilder(
          builder: (BuildContext context, bool hovered) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AnimatedSlide(
                    offset: Offset(0, hovered ? -0.02 : 0),
                    duration: tokens.fast,
                    curve: ZhyTokens.decelerateCurve,
                    child: Stack(
                      children: <Widget>[
                        CoverImage(
                          url: collection.coverUrl,
                          width: cardWidth,
                          height: cardWidth,
                          borderRadius: BorderRadius.circular(
                            tokens.cardRadius,
                          ),
                          showShadow: hovered,
                          placeholderIcon: Icons.queue_music_rounded,
                        ),
                        if (playCount != null)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: _CountPill(count: playCount),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    collection.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 封面上的圆形播放按钮。
class _PlayOverlay extends StatelessWidget {
  const _PlayOverlay({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              Icons.play_arrow_rounded,
              size: 26,
              color: scheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面右下角的播放量胶囊。
///
/// 底色用 `inverseSurface` 而不是写死的半透明黑：
/// 主题色随封面变化时，写死的黑色蒙层会和整站配色脱节。
class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.play_arrow_rounded,
            size: 13,
            color: scheme.onInverseSurface,
          ),
          const SizedBox(width: 2),
          Text(
            formatCount(count),
            style: TextStyle(
              fontSize: 11,
              color: scheme.onInverseSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 歌单信息头
// ---------------------------------------------------------------------------

/// 歌单 / 收藏夹详情头：大封面 + 名称 + 创建者 + 曲目数 + 播放全部 + 收藏。
///
/// 发现页的歌单详情与「我的歌单」右栏展示的是同一个东西，
/// 所以只写一份。
class CollectionHeaderView extends StatelessWidget {
  const CollectionHeaderView({
    super.key,
    required this.collection,
    this.trackCount,
    this.onPlayAll,
    this.onAddToQueue,
    this.onFavorite,
    this.compact = false,
  });

  final MusicCollection collection;

  /// 已加载到的曲目总数（接口会给出更准确的值，优先用它）。
  final int? trackCount;

  final VoidCallback? onPlayAll;

  /// 把整个集合**追加**到当前播放队列（不替换、不跳转）。
  final VoidCallback? onAddToQueue;
  final VoidCallback? onFavorite;

  /// 紧凑模式：封面小一些，用于左右分栏的右栏。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double coverSize = compact ? 112 : 148;
    final int count = trackCount ?? collection.trackCount;
    final String? creator = collection.creatorName;
    final String? description = collection.description;

    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CoverImage(
            url: collection.coverUrl,
            size: coverSize,
            borderRadius: BorderRadius.circular(tokens.cardRadius),
            showShadow: true,
            placeholderIcon: Icons.queue_music_rounded,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  collectionKindLabel(collection.kind),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  collection.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 19 : 22,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  <String>[
                    if (creator != null && creator.isNotEmpty) '由 $creator 创建',
                    '共 $count 首',
                    if (collection.source.label.isNotEmpty)
                      collection.source.label,
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (description != null && description.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: onPlayAll,
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('播放全部'),
                    ),
                    const SizedBox(width: 12),
                    // 「添加到队列」与「播放全部」的区别只在"换不换队列/跳不跳"：
                    // 前者把这批歌排到当前队列后面（正在放的不受影响），
                    // 后者用这批歌替换队列并从头播。两个都常用，所以都放在这里。
                    OutlinedButton.icon(
                      onPressed: onAddToQueue,
                      icon: const Icon(Icons.playlist_add_rounded, size: 18),
                      label: const Text('添加到队列'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: onFavorite,
                      icon: const Icon(Icons.favorite_border_rounded, size: 18),
                      label: const Text('收藏'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

/// 弹一条提示。用 [ScaffoldMessenger.maybeOf]：内容组件可能被放在没有
/// Scaffold 的路由里，拿不到 messenger 时静默降级，而不是抛异常崩页面。
void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}
