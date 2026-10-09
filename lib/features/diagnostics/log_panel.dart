import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/log_buffer.dart';
import '../../core/diagnostics/log_providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/glass.dart';

/// 同一时刻只允许一个日志面板。多开没有意义，只会叠出好几层遮罩。
///
/// 注意它是**模块级**状态：面板是靠 OverlayEntry 关掉的，不是靠 Navigator，
/// 所以没有"路由栈"能替我们记住这件事。
bool _open = false;

/// 仅供测试：把"面板已打开"的状态清掉。
///
/// 面板正常关闭时 `_LogOverlay` 会自己复位，但用例在面板还开着的时候就
/// 结束的话，这个标志会留在 true 上，把它后面的用例全部挡在门外 ——
/// 那种失败会表现得像"按钮点了没反应"，极难定位。
@visibleForTesting
void debugResetLogPanelState() => _open = false;

/// 打开「调试日志」面板。
///
/// 做成覆盖在整棵界面之上的右侧 island，而不是一个全屏页面或对话框：
///
/// - **不改变导航层级**。用户来看日志时往往正停在出问题的那一页
///   （设置里的音质、歌单页、播放条），铺满窗口会把他正在看的东西
///   盖掉，关掉之后滚动位置也没了。
/// - **不吃掉交互**。面板只占右侧一小条，左侧的界面仍然可见 ——
///   复现"某首歌播不了"时，能一边点播放一边看日志刷出来，
///   这是对话框做不到的（对话框拦住了底下的所有点击）。
Future<void> showLogPanel(BuildContext context) async {
  final BuildContext captured = context;
  if (_open) return;
  final OverlayState? overlay = Overlay.maybeOf(captured, rootOverlay: true);
  if (overlay == null) return;

  _open = true;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) => _LogOverlay(
      onClosed: () {
        _open = false;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

/// 面板外壳：遮罩层 + 右侧滑入岛 + 退场时序。
///
/// 把它做成独立的 widget 而不是在 [showLogPanel] 里手写
/// `AnimationController`，是为了让"关闭"这件事有明确的生命周期钩子：
/// 反放动画结束后再移除 OverlayEntry，否则面板会瞬间消失而不是滑出去。
class _LogOverlay extends StatefulWidget {
  const _LogOverlay({required this.onClosed});

  final VoidCallback onClosed;

  @override
  State<_LogOverlay> createState() => _LogOverlayState();
}

class _LogOverlayState extends State<_LogOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _curve = CurvedAnimation(
      parent: _controller,
      curve: ZhyTokens.decelerateCurve,
      reverseCurve: ZhyTokens.accelerateCurve,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (mounted) widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    // 遮罩只是"点空白处关掉"和一点压暗，**不能**是不透明底色：
    // 窗口本身是亚克力，铺一层纯色会把系统材质盖死。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: FadeTransition(
            opacity: _curve,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: ColoredBox(
                color: scheme.scrim.withValues(alpha: 0.14),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              // hardEdge 裁剪让面板"滑出去"时是真的滑出可视区，
              // 而不是飘在窗口外面还露着半个身子。
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerRight,
                      child: FractionalTranslation(
                        translation: Offset(1.05 * (1 - _curve.value), 0),
                        child: Opacity(
                          opacity: _curve.value,
                          // 面板是插进 Overlay 的，那里**没有 Material 祖先**
                          // （它已经越过了 Scaffold）。ChoiceChip / IconButton
                          // 这类控件会断言"找不到 Material"并直接抛异常，
                          // 所以这里自己铺一层透明的。
                          child: Material(
                            type: MaterialType.transparency,
                            child: LogPanel(onClose: _close),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 日志面板本体：过滤 + 列表 + 导出。
///
/// 独立成 public widget（而不是藏在 OverlayEntry 的 builder 里），
/// 是为了能被单独挂到别处（测试、未来的独立窗口）而不必改这里。
class LogPanel extends ConsumerStatefulWidget {
  const LogPanel({super.key, this.onClose, this.width = 460, this.height});

  final VoidCallback? onClose;
  final double width;

  /// 不给宽度/高度就撑满可用空间（面板在 Overlay 里是被 `Positioned.fill`
  /// 约束过的，所以"可用空间"就是窗口减去外边距）。
  final double? height;

  @override
  ConsumerState<LogPanel> createState() => _LogPanelState();
}

/// 级别过滤档位。「警告以上 / 仅错误」比"四个复选框"更贴近真实用法：
/// 排查问题时人只想看"出事的那些"。
enum _LevelFilter {
  all('全部'),
  warningUp('警告以上'),
  errorOnly('仅错误');

  const _LevelFilter(this.label);

  final String label;

  LogLevel? get minLevel => switch (this) {
    _LevelFilter.all => null,
    _LevelFilter.warningUp => LogLevel.warning,
    _LevelFilter.errorOnly => LogLevel.error,
  };
}

class _LogPanelState extends ConsumerState<LogPanel> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  _LevelFilter _filter = _LevelFilter.all;
  String _keyword = '';

  /// 是否"跟着最新一条走"。
  ///
  /// 用户一旦手动往上滚，就把它置为 false —— 这条标志位就是
  /// 「别把正在翻日志的人强行拉回底部」的全部实现。
  bool _followTail = true;

  /// 已渲染到的版本号，避免同一次数据版本重复套用滚动动作。
  int _appliedRevision = -1;

  @override
  void initState() {
    super.initState();
    // 面板打开前积压的日志可能还在合并窗口里，先把它放出来，
    // 否则用户会看到"面板是空的、过一会儿才刷出来"。
    ref.read(logBufferProvider).flushNotification();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 32px 的容差：滚到底时 ScrollPosition 的 pixels 常常差那么零点几，
    // 用 `==` 判断会永远停在 false，自动跟随就再也不会恢复。
    final bool atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 32;
    if (atBottom != _followTail) {
      setState(() => _followTail = atBottom);
    }
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    final double target = _scroll.position.maxScrollExtent;
    if ((_scroll.position.pixels - target).abs() < 1) return;
    _scroll.jumpTo(target);
  }

  Future<void> _copyAll() async {
    final LogBuffer buffer = ref.read(logBufferProvider);
    final String text = buffer.export();
    // 先取到 messenger：await 之后 context 可能已经失效，
    // `ScaffoldMessenger.maybeOf(context)` 就再也找不到东西了。
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (text.trim().isEmpty) {
      messenger?.showSnackBar(const SnackBar(content: Text('还没有日志可以复制')));
      return;
    }
    // 剪贴板是平台通道：它可能抛（通道缺失、被系统拒绝）。
    // 这里绝不能让它把整个方法掀掉 —— 用户看到的会是"点了按钮没反应"，
    // 而日志本身其实已经导出好了。catch 住，如实告诉他。
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on Object catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('复制失败：$error')));
      return;
    }
    messenger?.showSnackBar(
      SnackBar(content: Text('已复制 ${buffer.length} 条日志到剪贴板')),
    );
  }

  void _clear() {
    final LogBuffer buffer = ref.read(logBufferProvider);
    final int count = buffer.length;
    buffer.clear();
    // 清空之后没有"最新一条"可跟，重新锚到底部；否则用户会停在
    // 一个已经不存在的滚动位置上。
    setState(() => _followTail = true);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(count == 0 ? '日志已经是空的' : '已清空 $count 条日志')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;

    // 这里必须用 `read` + [ListenableBuilder]，**不能**用 `ref.watch`。
    //
    // Riverpod 3 的 `ref.watch(Provider)` 只在 provider **自身的值**变化时
    // 重建（override、invalidate），而 `LogBuffer` 是个 ChangeNotifier：
    // 它 notifyListeners 时 provider 的值还是同一个对象，watch 什么都不会做。
    // 面板会永远停在打开那一刻的快照上 —— 这正是"日志面板看起来是空的"
    // 那种最难查的 bug。真正驱动重建的是 ListenableBuilder。
    final LogBuffer buffer = ref.read(logBufferProvider);

    return ListenableBuilder(
      listenable: buffer,
      builder: (BuildContext context, Widget? _) => _buildBody(
        context,
        tokens,
        Theme.of(context).colorScheme,
        buffer,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ZhyTokens tokens,
    ColorScheme scheme,
    LogBuffer buffer,
  ) {
    final int revision = buffer.revision;

    final List<LogEntry> visible = buffer.filtered(
      minLevel: _filter.minLevel,
      keyword: _keyword,
    );

    // 有日志在合并窗口里刚落地时，把界面推到底 —— 但这**只**在
    // 用户本来就贴着底部时才做。放在 build 末尾的 post-frame 回调里，
    // 是因为 jumpTo 依赖这一帧刚算出来的 maxScrollExtent：
    // 在 build 中间调用会滚到旧的（更小的）范围上，然后被下一次布局纠正，
    // 看起来就是"滚一下又弹回去"。
    if (revision != _appliedRevision) {
      _appliedRevision = revision;
      if (_followTail && visible.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _followTail) _jumpToBottom();
        });
      }
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: GlassPanel(
        radius: tokens.panelRadius + 6,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        // 必须显式撑满可用高度。
        //
        // `SizedBox(height: null)` 给 Column 的是**宽松**约束，而
        // `MainAxisSize.max` 在宽松约束下会退化成"包住内容"：里面那个
        // `Expanded` 于是分到 0 高度，日志列表的视口变成十几像素高 ——
        // 看起来就是"日志行都在树里、但一条也看不见"。
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : 240,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildHeader(context, scheme, buffer),
                  const SizedBox(height: 10),
                  _buildFilters(context, scheme),
                  const SizedBox(height: 8),
                  Expanded(child: _buildList(context, scheme, buffer, visible)),
                  const SizedBox(height: 8),
                  _buildFooter(context, scheme, buffer, visible),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme scheme, LogBuffer b) {
    return Row(
      children: <Widget>[
        Icon(Icons.terminal_rounded, size: 17, color: scheme.primary),
        const SizedBox(width: 8),
        Text(
          '调试日志',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '共 ${b.length} 条',
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurfaceVariant,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.content_copy_rounded, size: 16),
          tooltip: '复制全部',
          onPressed: _copyAll,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline_rounded, size: 17),
          tooltip: '清空日志',
          onPressed: _clear,
        ),
        if (widget.onClose != null)
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: '关闭（Esc）',
            onPressed: widget.onClose,
          ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context, ColorScheme scheme) {
    return Row(
      children: <Widget>[
        for (final _LevelFilter item in _LevelFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(item.label, style: const TextStyle(fontSize: 11.5)),
              selected: _filter == item,
              visualDensity: VisualDensity.compact,
              // 点已选中的档位不应该把它取消掉 —— 过滤条件总是"有且仅有一个"，
              // 没有"不选任何档位"这个状态。
              onSelected: (_) => setState(() => _filter = item),
            ),
          ),
        const SizedBox(width: 4),
        Expanded(
          child: Shortcuts(
            // 面板是覆盖层，没有自己的文本输入环境；不给快捷键的话，
            // 在搜索框里按 Esc 什么都不会发生。
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.escape): _ClosePanelIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _ClosePanelIntent: CallbackAction<_ClosePanelIntent>(
                  onInvoke: (_) {
                    widget.onClose?.call();
                    return null;
                  },
                ),
              },
              child: TextField(
                controller: _search,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索关键字（消息 / 来源 / 堆栈）',
                  hintStyle: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIcon: const Icon(Icons.search_rounded, size: 15),
                  prefixIconConstraints: const BoxConstraints(
                    minHeight: 30,
                    minWidth: 32,
                  ),
                  suffixIcon: _keyword.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.backspace_outlined, size: 14),
                          tooltip: '清空搜索',
                          onPressed: () {
                            _search.clear();
                            setState(() => _keyword = '');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                ),
                onChanged: (String value) {
                  final String next = value.trim();
                  if (next == _keyword) return;
                  setState(() => _keyword = next);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    ColorScheme scheme,
    LogBuffer buffer,
    List<LogEntry> visible,
  ) {
    if (buffer.isEmpty) {
      return _EmptyState(
        icon: Icons.terminal_rounded,
        text: '还没有日志。播放一首歌再回来看看。',
        scheme: scheme,
      );
    }
    if (visible.isEmpty) {
      // 空结果和"完全没有日志"必须说清楚是两回事，否则用户会以为
      // 日志丢了，然后去点清空 —— 那才是真的丢了。
      return _EmptyState(
        icon: Icons.filter_alt_off_rounded,
        text: '没有符合条件的日志。试试放宽级别筛选或换个关键字。',
        scheme: scheme,
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        _onScroll();
        // 返回 false：把通知继续往上抛，别把外面的滚动行为改掉。
        return false;
      },
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          primary: false,
          padding: const EdgeInsets.only(right: 4),
          itemCount: visible.length,
          itemBuilder: (BuildContext context, int index) =>
              _LogRow(entry: visible[index]),
        ),
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    ColorScheme scheme,
    LogBuffer buffer,
    List<LogEntry> visible,
  ) {
    final String shown = _filter.minLevel == null && _keyword.isEmpty
        ? '共 ${visible.length} 条'
        : '显示 ${visible.length} / ${buffer.length} 条';

    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            shown,
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (buffer.droppedCount > 0)
          Text(
            '已丢弃 ${buffer.droppedCount} 条更早日志',
            style: TextStyle(fontSize: 10.5, color: scheme.tertiary),
          ),
        const SizedBox(width: 8),
        if (!_followTail)
          // 手动往上翻时给一个明确的状态提示，而不是让用户以为"新日志没进来"。
          TextButton.icon(
            onPressed: () {
              setState(() => _followTail = true);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _jumpToBottom();
              });
            },
            icon: const Icon(Icons.vertical_align_bottom_rounded, size: 14),
            label: const Text('回到最新', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
      ],
    );
  }
}

/// Esc 的意图类型。用自定义 Intent 而不是 `DismissIntent`：
/// 后者会被 Scaffold / Dialog 等祖先拦截，语义也不完全一样。
class _ClosePanelIntent extends Intent {
  const _ClosePanelIntent();
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.text,
    required this.scheme,
  });

  final IconData icon;
  final String text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 26, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行日志。
///
/// 时间 / 级别 / 来源 / 消息拼在**同一个** SelectableText.rich 里：
/// 这样一次拖拽就能把整行（含时间戳）复制走，而不是只能选中消息那一段 ——
/// 排查问题时"这条是几点几分出现的"和消息本身一样重要。
class _LogRow extends StatefulWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  bool _expanded = false;

  /// 等宽字体。主字体写死 Consolas（Windows 桌面必然存在），
  /// fallback 再兜一层通用 `monospace`：万一系统精简掉了 Consolas，
  /// 时间戳也不会退化成比例字体、把每一列都错开。
  static const List<String> _mono = <String>['Consolas', 'monospace'];

  Color _levelColor(ColorScheme scheme) => switch (widget.entry.level) {
    LogLevel.debug => scheme.onSurfaceVariant,
    LogLevel.info => scheme.primary,
    LogLevel.warning => scheme.tertiary,
    LogLevel.error => scheme.error,
  };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final LogEntry entry = widget.entry;
    final String? detail = entry.detail;
    final Color levelColor = _levelColor(scheme);

    final TextSpan head = TextSpan(
      style: TextStyle(
        fontFamily: 'Consolas',
        fontFamilyFallback: _mono,        fontSize: 11.5,
        height: 1.45,
        color: scheme.onSurface.withValues(alpha: 0.92),
      ),
      children: <InlineSpan>[
        // 时间用等宽 + 表格数字，扫描时能一眼对齐。
        TextSpan(
          text: _formatClock(entry.at),
          style: TextStyle(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        TextSpan(
          text: '  [${entry.level.label}]',
          style: TextStyle(color: levelColor, fontWeight: FontWeight.w600),
        ),
        if (entry.tag != null)
          TextSpan(
            text: ' [${entry.tag}]',
            style: TextStyle(color: scheme.secondary),
          ),
        const TextSpan(text: '  '),
        TextSpan(text: entry.message),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                // 让色点与第一行文字的中线对齐；纯几何居中的话，
                // 因为行高带 leading，点会明显偏上。
                padding: const EdgeInsets.only(top: 5),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: levelColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText.rich(
                  head,
                  // 面板本身已经是窄岛，再给 SelectableText 默认的
                  // 8x4 内边距会把每行都撑歪。
                  textWidthBasis: TextWidthBasis.parent,
                ),
              ),
              if (detail != null)
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Icon(
                      _expanded
                          ? Icons.unfold_less_rounded
                          : Icons.unfold_more_rounded,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          if (detail != null && _expanded)
            Padding(
              padding: const EdgeInsets.only(left: 15, top: 5, bottom: 3),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(
                    context.tokens.cardRadius * 0.5,
                  ),
                  border: Border(
                    left: BorderSide(
                      color: levelColor.withValues(alpha: 0.6),
                      width: 2,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: SelectableText(
                    detail,
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontFamilyFallback: _mono,
                      fontSize: 10.5,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _formatClock(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${three(at.millisecond)}';
  }
}
