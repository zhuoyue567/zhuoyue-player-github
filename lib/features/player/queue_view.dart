import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
// [ScrollDirection] 只在 rendering 里导出：判断"用户滚动方向"要用到它。
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/color_utils.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/song.dart';
import 'player_controller.dart';

/// 队列行的可见高度（逻辑像素）。
const double kQueueRowHeight = 46;

/// 相邻两行之间的间距（逻辑像素）。
const double kQueueRowGap = 4;

/// 队列里每一行占用的**槽位**高度 = [kQueueRowHeight] + [kQueueRowGap]。
///
/// 必须是定值：列表用 [ListView.itemExtent] 按它固定行高，"打开时聚焦当前
/// 曲目"的偏移才能用 `下标 × 槽高` 一次算准。若改成按内容测高，目标偏移就
/// 要等排版完成才知道，而那时滚动已经发起 —— 画面必然先停在错的位置再跳。
///
/// 这三个常量是一组：改行高或改间距都必须让槽高跟着变。列表行高、悬浮高亮
/// 块、聚焦偏移的换算全都依赖它们（`test/queue_focus_test.dart` 里有断言）。
const double kQueueRowExtent = kQueueRowHeight + kQueueRowGap;

/// 队列列表默认的纵向内边距（上下各一份）。
const double kQueueListPadding = 4;

/// 判定"滚动位置真的动了"的容差（逻辑像素）。
///
/// 滚动位置是浮点数：贴顶 / 贴底时 `pixels` 与理论值常差零点几像素。
/// 用 `==` 比较既会把"其实没动"当成一次滚动，也会把自己的程序性滚动
/// 误判成用户操作。
const double _scrollEpsilon = 1;

/// 当前曲目离视口中线几行以内，就认为用户"滚回来了"，恢复跟随。
///
/// 取 1.5 行：用户滚回来时只要那一行大体回到中间就该恢复跟随，不必像素级
/// 对齐 —— 与歌词区（`lyric_view.dart`）用的是同一套宽容度。
const double _centerToleranceRows = 1.5;

/// 让第 [index] 行**垂直居中**所需的滚动偏移。
///
/// 抽成不依赖 widget 的纯函数，是为了能把首尾夹取这类边界单独钉住：它同时
/// 被"首帧的 `initialScrollOffset`"与"换曲后的滚动目标"使用，两处共用同一份
/// 换算，不会各自漂移。
///
/// 内容坐标里第 i 行槽位的中心是 `上内边距 + i × 槽高 + 槽高/2`，让它对准
/// 视口中线就需要把列表滚到：
///
/// ```
/// 上内边距 + i × 槽高 + 槽高/2 - 视口高/2
/// ```
///
/// 结果**必须夹到 `0 .. 内容总高 - 视口高`**：
/// - 首行算出来是负数，只能贴顶（第一行永远无法居中）；
/// - 末行算出来会超出可滚范围，只能贴底。
/// 夹取之后那一行仍然**完整**落在视口里，不会"恰好露一半" —— 这是这条改动
/// 的底线：居中做不到时，退而求其次也要看得见整行。
double queueScrollOffsetFor({
  required int index,
  required int itemCount,
  required double viewportDimension,
  double rowExtent = kQueueRowExtent,
  double paddingTop = kQueueListPadding,
  double paddingBottom = kQueueListPadding,
}) {
  if (index < 0 || itemCount <= 0) return 0;
  // 视口高度未知（还没排版 / 被放进无界约束）时按 0 处理：目标退化成"顶部
  // 对齐"，好过算出一个越界偏移、再被滚动物理当成越界弹回去。
  final double viewport = viewportDimension.isFinite && viewportDimension > 0
      ? viewportDimension
      : 0;
  // 内容总高由固定槽高直接算出，不必等列表排版 —— 这正是定值行高的价值。
  final double contentExtent =
      paddingTop + itemCount * rowExtent + paddingBottom;
  final double maxScrollExtent = math.max(0.0, contentExtent - viewport);
  final double target =
      paddingTop + index * rowExtent + rowExtent / 2 - viewport / 2;
  return target.clamp(0.0, maxScrollExtent);
}

/// 播放队列列表。
///
/// 抽成独立组件的理由：它现在有**两个宿主** —— 全屏播放页的「队列」标签页，
/// 以及播放条右侧滑入的队列 island。两处必须长得一样、行为一样
/// （点一下跳播、悬浮出现移除按钮、当前曲目高亮 + 音柱图标）。
/// 如果各写一份，第一个崩掉的必然是行为一致性。
///
/// 除了"长得一样"，两处还共用同一套**聚焦**行为：打开（island 滑入 / 切到
/// 队列标签）时列表已经停在当前曲目上，打开期间换曲也会跟过去 —— 除非用户
/// 自己滚过。实现见 [_QueueListViewState]。
class QueueListView extends ConsumerStatefulWidget {
  const QueueListView({
    super.key,
    this.padding,
    this.emptyHint,
    this.active = true,
  });

  final EdgeInsetsGeometry? padding;

  /// 空队列时的提示文案。
  final String? emptyHint;

  /// 宿主是否正把这块列表摆在用户面前（island 已滑入 / 队列标签被选中）。
  ///
  /// 为什么需要这个开关：island 收起时**并没有从树里消失**（它靠位移与透明
  /// 度藏起来），所以列表只创建一次，`initState` 那一次聚焦也就只发生一次。
  /// 而用户每次重新打开队列，想看的都是"现在放到哪一首" —— 由这个字段从
  /// false 翻到 true 来触发重新聚焦。
  final bool active;

  /// 第 [index] 行的键。
  ///
  /// 列表是懒构建的，按文字找行会连带命中更内层的 `Text`；量"当前那一行"的
  /// 矩形需要一个稳定的定位点（测试里的"完整落在视口内"就靠它）。
  static Key rowKey(int index) => ValueKey<String>('queue-row-$index');

  @override
  ConsumerState<QueueListView> createState() => _QueueListViewState();
}

class _QueueListViewState extends ConsumerState<QueueListView> {
  /// 列表的滚动控制器。
  ///
  /// **延迟到首次拿到实测视口高度时才创建**：目标偏移里含 `视口高 / 2`，
  /// 而 `build` 里还算不出来（只有 [LayoutBuilder] 知道）。这样做的收益是
  /// 首帧就带着正确的 `initialScrollOffset` 挂上去 —— 用户不会看到
  /// "先从头再滚过去"。
  ScrollController? _controller;

  /// 用户是否还在跟随当前曲目。手动滚动过就关掉，滚回当前曲目附近再打开。
  bool _autoFollow = true;

  /// 本次"打开"是否还没把当前曲目聚焦到位。
  bool _pendingFocus = true;

  /// 已经处理过的那一首的下标。
  ///
  /// 列表会因为播放位置每 200ms 更新而重建（宿主 `watch` 的是整个播放状态），
  /// 没有这份记忆就会变成"每次重建都去滚一次"，滚动动画永远重启不完。
  int _focusedIndex = -1;

  /// 最近一次程序性滚动的落点，用来给自己的滚动通知留一个浮点容差。
  double? _programmaticTarget;

  /// 正在等这一帧结束再回收控制器（队列被清空时）。
  bool _releasingController = false;

  @override
  void didUpdateWidget(covariant QueueListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 重新打开的这一刻恢复聚焦：用户这次打开队列，想看的就是"现在放到哪一
    // 首"，上一次他在队列里手动滚走这件事不该带到这一次来。
    if (widget.active && !oldWidget.active) {
      _autoFollow = true;
      _pendingFocus = true;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 把 [EdgeInsetsGeometry] 解析成具体值。
  ///
  /// 目标偏移要从**上内边距之后**算起，所以这里必须拿到具体数字。列表本身
  /// 仍然接受 `EdgeInsetsGeometry`，调用方的写法不受影响。用 LTR 解析：
  /// 这里只关心上下内边距，与文字方向无关。
  static EdgeInsets _resolvePadding(EdgeInsetsGeometry? padding) =>
      padding?.resolve(TextDirection.ltr) ??
      const EdgeInsets.symmetric(vertical: kQueueListPadding);

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );

    if (state.queue.isEmpty) {
      // 队列空了：清掉"已聚焦"的记忆，并等这一帧结束后把控制器一起丢掉。
      // `initialScrollOffset` 只在挂载时生效，下一批歌的下标与长度都不一样，
      // 拿着旧偏移挂上去会先错一帧再被拽回来。
      _focusedIndex = -1;
      _pendingFocus = true;
      _autoFollow = true;
      _releaseControllerAfterFrame();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            widget.emptyHint ?? '队列是空的\n去「发现音乐」挑一首吧',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final EdgeInsets padding = _resolvePadding(widget.padding);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // ListView 不收缩，视口高度就等于父级给的高度，不必等它排版。
        final double viewport = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0;
        final ScrollController listController = _ensureController(
          index: state.index,
          itemCount: state.queue.length,
          viewport: viewport,
          padding: padding,
        );
        _syncToCurrent(
          index: state.index,
          itemCount: state.queue.length,
          viewport: viewport,
          padding: padding,
        );

        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: ListView.builder(
            controller: listController,
            // 不做回弹：桌面端拖到底之后再滑一段很"手机"，与歌词列表一致。
            physics: const ClampingScrollPhysics(),
            padding: padding,
            // 固定槽高：几百首的队列里，滚动范围与"第 n 行在哪"不必布局就能算，
            // 顺带省掉了滑动时反复估算总高的开销。
            itemExtent: kQueueRowExtent,
            itemCount: state.queue.length,
            itemBuilder: (BuildContext context, int index) => QueueRow(
              key: QueueListView.rowKey(index),
              song: state.queue[index],
              index: index,
              active: index == state.index,
              playing: state.playing,
              onPlay: () => unawaited(controller.jumpTo(index)),
              onRemove: () => controller.removeAt(index),
            ),
          ),
        );
      },
    );
  }

  /// 首次布局时创建控制器，并让它带着"当前曲目居中"的初始偏移挂上去。
  ///
  /// 这是"打开即到位、不跳动"的关键：偏移在**挂载之前**就定了，列表首帧画
  /// 出来就已经在目标位置，而不是先画在 0 再滚过去。
  ScrollController _ensureController({
    required int index,
    required int itemCount,
    required double viewport,
    required EdgeInsets padding,
  }) {
    final ScrollController? existing = _controller;
    if (existing != null) return existing;

    final double initial = queueScrollOffsetFor(
      index: index,
      itemCount: itemCount,
      viewportDimension: viewport,
      paddingTop: padding.top,
      paddingBottom: padding.bottom,
    );
    final ScrollController controller = ScrollController(
      initialScrollOffset: initial,
    );
    _controller = controller;
    _programmaticTarget = initial;
    _focusedIndex = index;
    return controller;
  }

  /// 让列表对准当前曲目。
  ///
  /// 四条分支对应四种情形，缺一条都会出问题：
  /// - **打开时**（`_pendingFocus`）：偏移已在首帧由 `initialScrollOffset` 摆好，
  ///   这里只补一次帧尾校正，且**不带任何动画**；
  /// - **用户在跟随、曲目变了**：平滑滚过去（与歌词区的跟随一致）；
  /// - **用户手动滚过**：什么都不做 —— 他正想看后面几首，把他拽回去是最烦的；
  /// - **island 还收着**：看不见的列表不值得做滚动动画，打开时再对准。
  void _syncToCurrent({
    required int index,
    required int itemCount,
    required double viewport,
    required EdgeInsets padding,
  }) {
    if (index < 0) return;

    if (_pendingFocus) {
      _focus(index, itemCount, viewport, padding, animate: false);
      return;
    }
    if (index == _focusedIndex) return;

    if (!_autoFollow) {
      // 不跟，但要记下这一首已经处理过：否则等他滚回当前曲目附近、跟随刚恢复
      // 的那一刻，列表会突然跳一下。
      _focusedIndex = index;
      return;
    }
    if (!widget.active) {
      _focusedIndex = index;
      return;
    }

    _focus(index, itemCount, viewport, padding, animate: true);
  }

  void _focus(
    int index,
    int itemCount,
    double viewport,
    EdgeInsets padding, {
    required bool animate,
  }) {
    _focusedIndex = index;
    _pendingFocus = false;
    _applyOffsetAfterFrame(
      queueScrollOffsetFor(
        index: index,
        itemCount: itemCount,
        viewportDimension: viewport,
        paddingTop: padding.top,
        paddingBottom: padding.bottom,
      ),
      animate: animate,
    );
  }

  /// 帧尾再动滚动位置。
  ///
  /// 绝不在 `build` / 排版里滚：那时视口还没排完版（`jumpTo` 会直接抛），
  /// 副作用也不允许。放到帧尾既安全，又不会多等一帧 —— 首帧的偏移本来就已经
  /// 由 `initialScrollOffset` 摆好了，这里多数时候是空操作。
  void _applyOffsetAfterFrame(double target, {required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ScrollController? controller = _controller;
      if (controller == null || !controller.hasClients) return;
      final ScrollPosition position = controller.position;
      if (!position.hasContentDimensions) return;

      // 用**实测**的可滚范围再夹一次：纯函数只能按我们假定的几何算，真实视口
      // 与它差一点时（窗口尺寸刚变、调用方改过内边距），越界偏移会被滚动物理
      // 弹回去 —— 那才是真正难看的"跳一下"。
      final double clamped = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      // 先记落点：jumpTo 会同步派发滚动通知，靠它把自己和用户滚动区分开。
      _programmaticTarget = clamped;
      if ((position.pixels - clamped).abs() <= _scrollEpsilon) return;

      if (!animate) {
        controller.jumpTo(clamped);
        return;
      }
      final ZhyTokens tokens = context.tokens;
      unawaited(
        controller.animateTo(
          clamped,
          duration: tokens.normal,
          curve: ZhyTokens.decelerateCurve,
        ),
      );
    });
  }

  /// 队列清空后把控制器留到帧尾再回收。
  ///
  /// 不能在 `build` 里直接 `dispose`：这一帧列表还挂着它。等帧尾时元素已经
  /// 卸载、控制器也已 detach，才是安全的。万一队列在这期间又变回非空（同一
  /// 帧里两次状态变更），就留着它 —— 宁可先用一次旧偏移，也不能把一个正在
  /// 使用的控制器丢掉。
  void _releaseControllerAfterFrame() {
    if (_controller == null || _releasingController) return;
    _releasingController = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _releasingController = false;
      if (!mounted) return;
      if (ref.read(playerControllerProvider).queue.isNotEmpty) return;
      _controller?.dispose();
      _controller = null;
    });
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // 只认最外层列表的通知，避免将来嵌进别的可滚动区域时误判。
    if (notification.depth != 0) return false;

    if (_autoFollow) {
      if (_isUserScroll(notification)) setState(() => _autoFollow = false);
      return false;
    }

    // 拖动过程中不判定"回到当前"：用户只是想往回滚，途中必然扫过当前曲目，
    // 那时就恢复跟随会立刻把他拽回去。只在滚动真正停下来时判。
    if (notification is ScrollEndNotification) {
      _restoreFollowIfCentered(notification.metrics);
    }
    return false;
  }

  /// 这一条通知是不是"用户真的滚了"。
  ///
  /// 不能只看"位置变了"：程序自己的 `jumpTo` / `animateTo` 同样会派发通知。
  /// 用户输入的判据只有两个 —— 带拖拽细节的滚动（拖动），以及方向非 idle 的
  /// [UserScrollNotification]（滚轮 / 触控板；`jumpTo` 触发的那个方向是 idle）。
  /// 再叠一层"落点是不是我们自己的目标"，这里必须给浮点容差。
  bool _isUserScroll(ScrollNotification notification) {
    final double? expected = _programmaticTarget;
    if (expected != null &&
        (notification.metrics.pixels - expected).abs() <= _scrollEpsilon) {
      return false;
    }
    if (notification is UserScrollNotification) {
      return notification.direction != ScrollDirection.idle;
    }
    if (notification is ScrollStartNotification) {
      return notification.dragDetails != null;
    }
    if (notification is ScrollUpdateNotification) {
      return notification.dragDetails != null;
    }
    return false;
  }

  /// 用户滚回当前曲目附近 → 恢复跟随。
  ///
  /// 用"行距"而不是像素判定：行号天然带着几行的宽容度，也不必和行高较劲。
  /// 恢复之后**不**立刻把那一行吸到正中 —— 用户可能是想点当前曲目旁边的歌，
  /// 刚对准就把列表挪走反而添乱；下一次换曲时自然会把当前曲目带回中间。
  void _restoreFollowIfCentered(ScrollMetrics metrics) {
    if (!metrics.hasContentDimensions) return;
    final int index = ref.read(playerControllerProvider).index;
    if (index < 0) return;

    final EdgeInsets padding = _resolvePadding(widget.padding);
    // 视口中线落在内容坐标里的哪一行：扣掉上内边距，再扣掉半行换成"槽位中心"。
    final double centerInContent =
        metrics.pixels + metrics.viewportDimension / 2;
    final double row =
        (centerInContent - padding.top - kQueueRowExtent / 2) / kQueueRowExtent;
    if ((row - index).abs() > _centerToleranceRows) return;

    setState(() => _autoFollow = true);
  }
}

/// 队列里的一行。
class QueueRow extends StatefulWidget {
  const QueueRow({
    super.key,
    required this.song,
    required this.index,
    required this.active,
    required this.playing,
    required this.onPlay,
    required this.onRemove,
  });

  final Song song;
  final int index;
  final bool active;
  final bool playing;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  State<QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<QueueRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 悬浮蒙层用 alphaBlend 叠在"正在播放"底色之上，而不是替换它：
    // 否则鼠标扫过当前曲目时，高亮会突然消失，看起来像跳到了别的歌。
    final Color base = widget.active
        ? scheme.primaryContainer.withValues(alpha: 0.32)
        : Colors.transparent;
    final Color background = _hovered
        ? Color.alphaBlend(
            scheme.onSurface.withValues(alpha: ZhyTokens.hoverOverlay),
            base,
          )
        : base;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPlay,
        child: AnimatedContainer(
          duration: tokens.fast,
          // 行高 + 间距必须正好等于 [kQueueRowExtent]（列表的 itemExtent）：
          // 槽高是紧约束，两者之和对不上时行内可见高度会被悄悄改掉，
          // 悬浮高亮块也就跟着变胖或变瘦。
          height: kQueueRowHeight,
          margin: const EdgeInsets.only(bottom: kQueueRowGap),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(tokens.cardRadius),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 22,
                child: widget.active
                    ? Icon(
                        widget.playing
                            ? Icons.equalizer_rounded
                            : Icons.pause_rounded,
                        size: 14,
                        color: scheme.primary,
                      )
                    : Text(
                        '${widget.index + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          // 等宽数字：否则 1 和 11 的宽度不同，序号列会左右抖。
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        // 字重不承担层次：内置字体只有 w400 一个字面，
                        // 请求 w600 会被引擎描边合成（中文小字会发虚）。
                        // 当前曲目的区分交给下面的颜色。
                        fontWeight: FontWeight.w500,
                        color: widget.active
                            ? scheme.primary
                            : ZhyColor.alpha(scheme.onSurface, 0.9),
                      ),
                    ),
                    Text(
                      widget.song.artistLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 操作区**始终占位**：只在悬浮时插入会让右侧的时长左右横跳。
              SizedBox(
                width: 30,
                child: _hovered
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, size: 14),
                        tooltip: '从队列移除',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 26,
                          height: 26,
                        ),
                        onPressed: widget.onRemove,
                      )
                    : null,
              ),
              SizedBox(
                width: 38,
                child: Text(
                  ZhyFormat.duration(widget.song.duration),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
