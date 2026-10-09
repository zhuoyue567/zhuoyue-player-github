import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../data/models/lyric.dart';
import '../../data/models/song.dart';
import '../../data/repositories/source_registry.dart';
import 'player_controller.dart';

/// 歌词区域顶部 / 底部渐隐带的高度。
///
/// 固定值而不是令牌：它是"视觉上到哪一行开始看不清"的经验值，
/// 与主题的圆角、动效时长不是同一类东西，跟着主题一起变反而会怪。
///
/// **它必须跟着 [kLyricRowExtent] 一起放大**：渐隐带的作用是"让紧挨当前行的
/// 上下两行开始化开"，所以它天然以**行高**为单位，而不是绝对像素。
/// 放大前 44 / 40 ≈ 1.1 行；行高涨到 56 之后如果还留 44，就只盖住 0.79 行 ——
/// 相邻的整行会完完整整地"硬切"进视野，Apple Music 那种聚焦在中间的层次感
/// 就没了。所以按同一比例取 60 / 56 ≈ 1.07 行。
const double kLyricFadeExtent = 60;

/// 当前曲目的歌词。
///
/// 依赖当前曲目自动重新加载；用 `uid` 做一次归属校验再写状态，
/// 避免"切歌太快，上一首的歌词盖住新歌"。
class CurrentLyricNotifier extends Notifier<Lyric?> {
  @override
  Lyric? build() {
    final Song? song = ref.watch(currentSongProvider);
    if (song == null) return null;
    unawaited(_load(song));
    return null;
  }

  Future<void> _load(Song song) async {
    final repository = ref.read(sourceRegistryProvider).bySource(song.source);
    if (repository == null) return;
    try {
      final Lyric lyric = await repository.lyric(song);
      if (ref.read(currentSongProvider)?.uid == song.uid) state = lyric;
    } on Object {
      // 歌词拿不到不算错误，界面显示"暂无歌词"即可。
      if (ref.read(currentSongProvider)?.uid == song.uid) {
        state = const Lyric.empty();
      }
    }
  }
}

final NotifierProvider<CurrentLyricNotifier, Lyric?> currentLyricProvider =
    NotifierProvider<CurrentLyricNotifier, Lyric?>(CurrentLyricNotifier.new);

/// 当前行的正文字号（逻辑像素）。
///
/// 与 [kLyricRowExtent] 是一对，改一个就必须评估另一个。取值对照：
/// 放大前当前行只有 16（用户反馈"歌词不够大"，对照 Apple Music 明显偏小），
/// 现在 24 —— 同时把与非当前行的差距拉开（24 : 17.5），
/// 这样"中间那行被聚焦"的层次才立得住，而不是整块歌词一起变大。
const double kLyricActiveFontSize = 24;

/// 非当前行的正文字号（逻辑像素）。放大前是 13.5。
///
/// 它同样要变大：只放大当前行会让上下文小得像脚注，眼睛在两种字号之间
/// 来回跳，反而更难读。
const double kLyricInactiveFontSize = 17.5;

/// 译文行的字号（逻辑像素）。放大前是 11。
///
/// 跟着正文一起放大，否则放大后的正文与译文比例失调，译文会显得像残渣。
const double kLyricTranslationFontSize = 13;

/// 歌词列表里每一行占用的高度。
///
/// **必须是定值**：自动滚动的目标是"让第 n 行落在可视区中心"，这个换算
/// 只能在行高已知时一次算准。若改成按内容测高，滚动目标就得等布局完成
/// 才知道，而那时滚动已经发起，画面会先闪一下再跳。
/// 译文跟在正文下面，所以这个高度要容得下两行文字。
///
/// **行高与字号必须同步改**（这里是最容易出错的地方）：
/// 一行里最高的内容是"当前行正文 + 译文" = [kLyricActiveFontSize] × 1.25
/// + [kLyricTranslationFontSize] × 1.2 = 24 × 1.25 + 13 × 1.2 = 45.6，
/// 行高 56 留出约 10 像素的上下呼吸，比例 56 / 24 ≈ 2.33
/// （放大前是 40 / 16 = 2.5，同一个经验区间）。
/// 只改字号不改行高 → 文字上下被裁；只改行高不改字号 → 行距空得发慌。
/// 这两件事在测试里都有断言钉着（见 `test/lyric_view_test.dart`）。
const double kLyricRowExtent = 56;

/// 当前行两侧各有多少行仍算"位于中心附近"（单位：行）。
///
/// 取 1.5 行：用户手动滚回当前行时，只要那一行大体回到了中间就恢复跟随，
/// 不必要求像素级对齐。
const double _centerToleranceRows = 1.5;

/// 判定"滚动条真的动了"的容差（逻辑像素）。
///
/// 滚动位置是浮点数，贴底 / 贴中时 `pixels` 与理论值常差零点几像素，
/// 用 `==` 比较会把"程序自己的滚动回调"误判成用户操作。
const double _scrollEpsilon = 1;

/// 根据播放位置算出当前正在唱的那一行。
///
/// 抽成不依赖 widget 的纯函数，才能把"位置 → 行号"的边界情况
/// （第一行之前 / 正好压在行首 / 两行之间 / 最后一行之后）单独钉住。
/// 返回 `-1` 表示还没到第一行（前奏 / 间奏）。
int lyricIndexAt(List<Duration> starts, Duration position) {
  if (starts.isEmpty) return -1;
  final int target = position.inMilliseconds;
  if (target < starts.first.inMilliseconds) return -1;

  // 二分而不是线性扫描：位置每 200ms 就更新一次，几百行的歌词上
  // 线性扫描是实打实的每帧开销。
  int low = 0;
  int high = starts.length - 1;
  int result = -1;
  while (low <= high) {
    final int mid = (low + high) >> 1;
    if (starts[mid].inMilliseconds <= target) {
      result = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return result;
}

/// 让第 [index] 行落在可视区正中的滚动偏移。
///
/// 前提是列表上下留了 [lyricListPadding] 那么多内边距 —— 那时第 i 行的
/// 中心正好在 `视口高/2 + i*行高`，把它对准视口中线只需要滚 `i*行高`。
///
/// 这样首末两行也能真居中：偏移从 0 开始、到 `(行数-1)*行高` 结束，
/// 恰好落在可滚动范围内。固定留一小段内边距时，第一行的目标偏移是负数，
/// 只能被夹到 0 —— 那就成了"首行永远偏下大半个视口"。
///
/// 末尾的 `min` 是防御性的：列表短于视口（几乎没有歌词）或几何参数
/// 不匹配时，滚动位置不会越界。
double lyricScrollOffsetFor({
  required int index,
  required double rowExtent,
  required double maxScrollExtent,
}) {
  if (index <= 0) return 0;
  final double target = index * rowExtent;
  return target < maxScrollExtent ? target : maxScrollExtent;
}

/// 歌词列表的纵向内边距：让首行 / 末行的中心都能落到视口中线。
///
/// 视口比一行还矮时（极端窗口尺寸）会算成负数，夹到 0。
EdgeInsets lyricListPadding(double viewportDimension, double rowExtent) {
  final double half = (viewportDimension - rowExtent) / 2;
  return EdgeInsets.symmetric(vertical: half > 0 ? half : 0);
}

/// 歌词区上下渐隐用的渐变遮罩。
///
/// **单独抽成函数是为了能被测到**：`ShaderMask` + `BlendMode.dstIn` 的语义是
/// "保留遮罩里不透明的地方、抹掉透明的地方"，很容易写反 —— 写反的结果是
/// **把中间整片歌词擦掉、只在上下各留一条窄带**（观感就是"整块歌词只显示
/// 顶端一行，下面一片空白"），而基于 `getRect` 的布局断言**看不出这种错**：
/// 行的位置都对，只是没画出来。所以这里把"两端透明、中间不透明"钉成可断言的
/// 事实，而不是留在 `shaderCallback` 的闭包里。
///
/// 颜色用主题表面色而不是黑色：`dstIn` 只看 alpha，颜色其实无所谓，
/// 但用 surface 不容易被后来改代码的人误读成"黑色抹掉"。
LinearGradient lyricFadeGradient(Color surface, {required double fade}) {
  final Color clear = surface.withValues(alpha: 0);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[clear, surface, surface, clear],
    stops: <double>[0, fade, 1 - fade, 1],
  );
}

/// Apple Music 风格的歌词视图。
///
/// 它刻意**不直接读 provider**：歌词、播放位置、seek 回调都由外面注入。
/// 好处是整块歌词可以脱离播放器单独布局与测试，全屏页只负责接线。
/// 依赖注入没有引入任何新包，纯 Dart 的类型签名即可。
class LyricView extends StatefulWidget {
  const LyricView({
    super.key,
    required this.lyric,
    required this.position,
    required this.onSeek,
    this.loading = false,
    this.scrollController,
    this.rowExtent = kLyricRowExtent,
    this.centerDecoration,
  });

  /// 当前曲目的歌词；null 或 [loading] 为 true 时显示加载态。
  final Lyric? lyric;

  /// 歌词是否还在取。
  ///
  /// 单独用一个开关而不是把 `lyric == null` 当成"加载中"：
  /// `currentLyricProvider` 的 null 只是"还没有结果"，曲目切走、
  /// 音源没有实现歌词接口都会走到这里，那与"正在取"是两回事，
  /// 文案也不一样（一个转圈、一个明确说暂无）。由调用方告知才准。
  final bool loading;

  /// 当前播放位置。
  final Duration position;

  /// 点击某一行时回调该行的开始时间。
  ///
  /// 交给外面的 [PlayerController.seek]，这里只声明"用户想跳到这一刻"。
  final ValueChanged<Duration> onSeek;

  /// 外部注入滚动控制器；不传则自己建一个并负责释放。
  final ScrollController? scrollController;

  /// 行高。生产上永远是 [kLyricRowExtent]，测试里调小它才能用小视口
  /// 造出"滚动到中间"的场景。
  final double rowExtent;

  /// 测试钩子：装饰**当前行所在的那一行**，用来在测试里量它的坐标。
  ///
  /// 为什么留这个口子：当前行是从生产数据算出来的，测试不该靠"猜哪一行
  /// 被选成了当前行"去断言；而按文字 find 会连带命中译文与更内层的
  /// RichText，量出来的矩形不是行框。让测试自己往那一行上挂一个可定位的
  /// 节点，是唯一既稳又不影响生产的做法。
  final Widget Function(BuildContext context, int index, Widget child)?
  centerDecoration;

  /// 当前行的行键，供测试与滚动定位使用。
  static Key rowKey(int index) => Key('lyric-row-$index');

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  ScrollController? _ownedController;
  int _cachedIndex = -1;

  /// 是否跟随播放位置自动滚动。用户一拖就关掉，滚回当前行附近再打开。
  bool _autoFollow = true;

  /// 当前行最近的滚动目标偏移。用来判断用户是不是滚回了中心附近。
  double? _followOffset;

  ScrollController get _controller =>
      widget.scrollController ?? (_ownedController ??= ScrollController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  int get _activeIndex {
    final Lyric? lyric = widget.lyric;
    if (lyric == null || lyric.isEmpty) return -1;
    return lyricIndexAt(
      lyric.lines.map((LyricLine line) => line.start).toList(growable: false),
      widget.position,
    );
  }

  /// 把当前行滚到可视区中心。
  ///
  /// 目标偏移是用行高算出来的静态值，所以直接 `animateTo` 就够；
  /// 不用 `Scrollable.ensureVisible`：那个依赖目标 RenderObject 已经布局，
  /// 而行还没进视口时它的位置正是未知的。
  void _scrollToIndex(
    int index, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    final double target = lyricScrollOffsetFor(
      index: index,
      rowExtent: widget.rowExtent,
      maxScrollExtent: position.maxScrollExtent,
    );
    _followOffset = target;
    if ((position.pixels - target).abs() < _scrollEpsilon) return;
    _controller.animateTo(target, duration: duration, curve: curve);
  }

  /// 自动跟随的目标位置：**只在当前行变化时**滚一次。
  ///
  /// 播放位置每 200ms 更新一次，但一行歌词要唱十几秒 —— 如果每来一次
  /// 位置就调用一次 `animateTo`，滚动动画会被无限重启动，长歌词还会跟着
  /// 卡顿。这里把"上次处理过的行号 + 上次的跟随开关"缓存在 State 上，
  /// 位置流再怎么刷都不会产生新的副作用。
  void _syncFollow(int index) {
    if (index == _cachedIndex && _autoFollow) return;
    _cachedIndex = index;
    final bool follow = _autoFollow;
    if (index < 0 || !follow) return;
    final ZhyTokens tokens = context.tokens;
    final Curve curve = ZhyTokens.decelerateCurve;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autoFollow) return;
      // 用户可能刚好在这一帧里把列表拖走了，这里再确认一次。
      _scrollToIndex(index, duration: tokens.normal, curve: curve);
    });
  }

  /// 用户滚回当前行附近 → 恢复跟随，并把那一行重新吸附到中心。
  ///
  /// 用行号距离判定而不是偏移距离：行高与滚动位置之间隔着一层布局，
  /// 用行号更直接，也天然带着几行的宽容度。
  ///
  /// 行号由偏移反推：内容坐标 `x` 处的行号是
  /// `(x - 顶部留白) / 行高 - 0.5`（减 0.5 是把"格子上沿"换成"格子中心"）。
  /// 顶部留白来自 [lyricListPadding]，**不能省** —— 漏掉它，反推出来的
  /// 行号会整体偏掉 `留白 / 行高` 行，"滚回当前行"就永远判不中。
  void _restoreFollowIfCentered(ScrollMetrics metrics) {
    final int active = _activeIndex;
    if (active < 0) return;
    final double paddingTop = lyricListPadding(
      metrics.viewportDimension,
      widget.rowExtent,
    ).top;
    final double center =
        metrics.pixels + (metrics.viewportDimension / 2) - paddingTop;
    final double centerRow = (center / widget.rowExtent) - 0.5;
    if ((centerRow - active).abs() > _centerToleranceRows) return;
    setState(() => _autoFollow = true);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autoFollow) return;
      final ZhyTokens tokens = context.tokens;
      _scrollToIndex(
        active,
        duration: tokens.normal,
        curve: ZhyTokens.decelerateCurve,
      );
    });
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // 只认最外层列表的通知，避免将来嵌进别的可滚动区域时误判。
    if (notification.depth != 0) return false;
    final ScrollMetrics metrics = notification.metrics;

    // 程序自己的 animateTo 也会走这条通知：与预期目标差得极小就放过。
    // 这条判断依赖容差而不是 `==` —— 滚动位置是浮点数，贴中 / 贴底时
    // `pixels` 常与理论值差零点几像素。
    final double? expected = _followOffset;
    final bool ownAnimation =
        expected != null && (metrics.pixels - expected).abs() <= _scrollEpsilon;

    if (_autoFollow) {
      final bool userDriven =
          notification is UserScrollNotification ||
          (notification is ScrollStartNotification &&
              notification.dragDetails != null) ||
          (notification is ScrollUpdateNotification &&
              notification.dragDetails != null);
      if (userDriven && !ownAnimation) {
        setState(() => _autoFollow = false);
      }
      return false;
    }

    // 拖动过程中不判定"回到当前"：用户只是在往回想拖，途中必然会扫过
    // 当前行，那时就恢复跟随会立刻把他拽回去。只在滚动真正停下来时判。
    final bool settled = notification is ScrollEndNotification;
    if (settled) _restoreFollowIfCentered(metrics);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;
    final Lyric? lyric = widget.lyric;
    final double rowExtent = widget.rowExtent;

    if (widget.loading || lyric == null) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: scheme.primary,
          ),
        ),
      );
    }

    if (lyric.isEmpty) {
      return Center(
        child: Text(
          lyric.isPureMusic ? '纯音乐，请欣赏' : '暂无歌词',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      );
    }

    final int active = _activeIndex;
    _syncFollow(active);

    // 视口高度决定了"让首末行也能居中"要留多少内边距，所以必须走
    // LayoutBuilder 拿实测高度，不能写死。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double viewport = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0;
        final EdgeInsets padding = lyricListPadding(viewport, rowExtent);
        return Stack(
          children: <Widget>[
            ShaderMask(
              // `dstIn`：保留遮罩里不透明处、抹掉透明处。渐变必须**两端透明、
              // 中间不透明**，否则会把歌词中间擦掉（见 [lyricFadeGradient]）。
              blendMode: BlendMode.dstIn,
              shaderCallback: (Rect bounds) {
                // 面板很矮时渐隐带会吃掉整块歌词，所以先把端点夹回 0~1。
                final double fade = (kLyricFadeExtent / bounds.height).clamp(
                  0.0,
                  0.45,
                );
                return lyricFadeGradient(
                  scheme.surface,
                  fade: fade,
                ).createShader(bounds);
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: ListView.builder(
                  controller: _controller,
                  // 不用滚动物理的回弹：桌面端拖动结束后不该再多滑一段。
                  physics: const ClampingScrollPhysics(),
                  padding: padding,
                  itemExtent: rowExtent,
                  itemCount: lyric.lines.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _buildRow(context, lyric, index, active, tokens, scheme),
                ),
              ),
            ),
            // 用户手动滚动后，告诉他还跟不跟着唱。
            if (!_autoFollow)
              Positioned(
                left: 0,
                right: 0,
                bottom: 6,
                child: Center(
                  child: _FollowButton(
                    onTap: () {
                      setState(() => _autoFollow = true);
                      if (active >= 0) {
                        _scrollToIndex(
                          active,
                          duration: tokens.normal,
                          curve: ZhyTokens.decelerateCurve,
                        );
                      }
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    Lyric lyric,
    int index,
    int active,
    ZhyTokens tokens,
    ColorScheme scheme,
  ) {
    final LyricLine line = lyric.lines[index];
    final bool isActive = index == active;
    final LyricLine? translation = lyric.translationAt(index);

    // 离当前行越远越淡：这正是 Apple Music 那种"聚焦在中间"的层次感。
    // 距离衰减的下限留 0.28，再淡下去在浅色主题上就看不见了。
    final double distance = active < 0
        ? 0
        : (index - active).abs().toDouble();
    final double opacity =
        isActive ? 1.0 : (0.62 - (distance * 0.06)).clamp(0.28, 0.62);

    // 每行带一个按行号命名的 key：既是列表元素身份，也让外部能直接定位
    // "第 n 行"去量它的位置（测试里的居中断言就靠它）。
    Widget row = KeyedSubtree(
      key: LyricView.rowKey(index),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSeek(line.start),
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: tokens.fast,
            curve: ZhyTokens.standardCurve,
            style: TextStyle(
              // 字号与 [kLyricRowExtent] 是绑定的：改这里必须同时改行高，
              // 否则要么上下裁字、要么行距空得发慌。当前行刻意比非当前行
              // 大一档，"聚焦在中间"的观感主要就来自这个差值。
              fontSize: isActive
                  ? kLyricActiveFontSize
                  : kLyricInactiveFontSize,
              height: 1.25,
              // 字重不再承担层次，因为内置字体（zhuzi.ttf）只有 w400 一个字面：
              // 请求 w600/w700 只会被引擎描边"合成"，中文小字会发虚、笔画粗细
              // 不匀。当前行与其它行的层次全部交给上面的字号与下面的颜色。
              fontWeight: FontWeight.w500,
              color: (isActive ? scheme.onSurface : scheme.onSurfaceVariant)
                  .withValues(alpha: opacity),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  line.text,
                  textAlign: TextAlign.center,
                  // 仍然单行省略，不改成换行：行高是写死的 itemExtent，
                  // 换行后"正文两行 + 译文"远超过 [kLyricRowExtent]，
                  // 内容会被行框直接裁掉。放大字号只是让长句更早出现省略号，
                  // 行为与放大前一致（同样单行省略），不是退步。
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (translation != null && translation.text.trim().isNotEmpty)
                  Text(
                    translation.text,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      // 译文字号也要跟正文一起放大，见常量处的说明。
                      fontSize: kLyricTranslationFontSize,
                      height: 1.2,
                      color: scheme.onSurfaceVariant.withValues(
                        alpha: opacity * 0.85,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final Widget Function(BuildContext, int, Widget)? decorate =
        widget.centerDecoration;
    if (decorate != null && isActive) {
      row = decorate(context, index, row);
    }
    return row;
  }
}

/// "回到当前"提示：只在用户手动滚走之后出现。
class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;
    return Material(
      color: scheme.secondaryContainer.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(tokens.pillRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(tokens.pillRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.my_location_rounded,
                size: 14,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                '回到当前',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
