import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/download/download_task.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/song_list.dart';
import '../../core/utils/format.dart';
import '../../data/models/media_source.dart';
import '../../data/models/song.dart';

/// 字节数的可读写法：`1.2 MB`、`512 KB`、`0 B`。
///
/// 实现收敛到 [ZhyFormat.bytes] —— 同一个仓库里只该有一份格式化实现。
/// 但这个名字保留：它是这一页对外的老接口，改名字只会让别处白改一遍。
String formatBytes(int? bytes) => ZhyFormat.bytes(bytes);

/// 下载队列的接口。
///
/// 定义成抽象接口而不是让页面直接依赖 `DownloadManager`，是为了把
/// "这一页需要下载器提供什么"和"下载器怎么实现"分开：并发数、续传、
/// 文件名去重、磁盘布局全在实现里，页面只负责画。
///
/// 实现约定：
/// - [tasks] 是当前快照；[changes] 之后每次变化都会推一份**新的**列表
///   （不要复用同一个 List 实例，否则 `setState` 前后引用相同，界面可能不刷新）；
/// - [changes] 不会正常结束，[DownloadsPage] 在页面销毁时取消订阅；
/// - 所有按 uid 定位的方法都在 uid 不存在时安静地什么都不做 ——
///   用户手快连点两下"移除"不该收到一个错误提示。
abstract interface class DownloadQueue {
  /// 当前全部任务（含已完成 / 失败 / 已取消）。
  List<DownloadTask> get tasks;

  /// 任务变化推送。
  Stream<List<DownloadTask>> get changes;

  /// 当前下载根目录；还没解析出来时为 null。
  String? get directory;

  /// 目录变化通知。
  ///
  /// 存在的理由：下载目录有**两个**入口 —— 本页的「更改目录」和设置页的
  /// 「存储路径」，而后者在另一个页面上。没有这条通知，用户从设置页改完切回来，
  /// 工具条上还挂着旧路径（"点了没反应"的另一种长相）。
  ///
  /// 实现必须是同步可读的 [Listenable]：界面在 `initState` 里就要能挂监听。
  Listenable get directoryChanges;

  /// 加入下载。同一首已存在时实现应当幂等（重复入队会让用户以为卡了）。
  Future<void> start(Song song);

  /// 取消：中止连接并**保留已下载的部分**，之后可以重试续传。
  Future<void> cancel(String uid);

  /// 暂停：同上，但语义是"我一会儿还要继续"。
  Future<void> pause(String uid);

  /// 继续一个暂停 / 失败 / 取消过的任务。
  Future<void> resume(String uid);

  /// 重新排队（与 [resume] 同义，界面上叫「重试」）。
  Future<void> retry(String uid);

  /// 删除一条记录。[deleteFile] 为 true 时连文件一起删。
  Future<void> remove(String uid, {bool deleteFile = false});

  /// 暂停全部（含排队中的）。
  Future<void> pauseAll();

  /// 继续全部已暂停的。
  Future<void> resumeAll();

  /// 清空已完成的记录（不删文件）。
  Future<void> clearCompleted();

  /// 让用户挑一个新的下载目录。
  Future<void> selectDirectory();

  /// 用系统文件管理器打开下载目录。
  Future<void> openFolder();

  /// 在文件管理器里选中某个任务的文件。
  Future<void> revealFile(String uid);
}

/// 下载队列 provider。
///
/// 默认返回 null：没有装配下载器时，界面必须明确告诉用户"这个功能没启用"，
/// 而不是画一条假的进度条。真实实现由 `main.dart` 覆盖：
///
/// ```dart
/// ProviderScope(
///   overrides: <Override>[
///     downloadQueueProvider.overrideWith((Ref ref) => DownloadManager(ref)),
///   ],
///   child: const ZhuoYueApp(),
/// )
/// ```
final Provider<DownloadQueue?> downloadQueueProvider = Provider<DownloadQueue?>(
  (Ref ref) => null,
);

/// 下载管理页。
///
/// 整页只依赖 [DownloadQueue]：既不知道下载是怎么实现的，也不关心文件写到哪。
///
/// 布局上刻意**按音源分栏**：两个平台的曲目混在一张列表里时，
/// "哔哩下载失败了三个"这种信息会被淹没在几十行里，而用户处理它们的
/// 方式完全不同（网易云是直链过期，哔哩多半是 Referer / 登录态）。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  List<DownloadTask> _tasks = const <DownloadTask>[];
  DownloadQueue? _queue;
  StreamSubscription<List<DownloadTask>>? _taskSubscription;
  ProviderSubscription<DownloadQueue?>? _queueSubscription;

  /// 当前挂着的"目录变化"监听，换队列时要先摘下来。
  VoidCallback? _directoryListener;

  /// 当前选中的音源；null 表示「全部」。
  MediaSource? _filter;

  @override
  void initState() {
    super.initState();
    // 用 listenManual 而不是在 build 里 watch：这样即使 provider 在本页
    // 构建之后才被 main.dart 覆盖，也能立刻换上新实现并重新订阅
    // （否则页面会永远停在"未启用"那个状态上，直到用户切页）。
    _queueSubscription = ref.listenManual<DownloadQueue?>(
      downloadQueueProvider,
      (DownloadQueue? previous, DownloadQueue? next) {
        _attach(next);
        if (mounted) setState(() {});
      },
    );
    _attach(ref.read(downloadQueueProvider));
  }

  @override
  void dispose() {
    unawaited(_taskSubscription?.cancel());
    _queueSubscription?.close();
    _detachDirectoryListener();
    super.dispose();
  }

  /// 绑定（或解绑）下载队列，并接管它的变化流。
  /// 这里不调 setState：调用方（initState / listen 回调）自己负责刷新。
  void _attach(DownloadQueue? queue) {
    if (identical(queue, _queue)) return;
    unawaited(_taskSubscription?.cancel());
    _taskSubscription = null;
    _detachDirectoryListener();
    _queue = queue;
    _tasks = queue?.tasks ?? const <DownloadTask>[];
    _taskSubscription = queue?.changes.listen((List<DownloadTask> tasks) {
      if (!mounted) return;
      setState(() => _tasks = tasks);
    });
    // 目录被设置页改掉时，这一页的路径文字必须跟着变。
    final DownloadQueue? attached = queue;
    if (attached != null) {
      void listener() {
        if (mounted) setState(() {});
      }

      _directoryListener = listener;
      attached.directoryChanges.addListener(listener);
    }
  }

  void _detachDirectoryListener() {
    final VoidCallback? listener = _directoryListener;
    if (listener != null) {
      _queue?.directoryChanges.removeListener(listener);
      _directoryListener = null;
    }
  }

  /// 统一处理下载动作的失败：写日志 + 告诉用户，不让异常冒到框架里。
  Future<void> _guard(Future<void> Function() action, String label) async {
    try {
      await action();
    } on Object catch (error) {
      debugPrint('[downloads] $label失败: $error');
      if (!mounted) return;
      _showMessage(context, '$label失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final DownloadQueue? queue = ref.watch(downloadQueueProvider);
    final List<DownloadTask> tasks = _tasks;
    final int active = tasks
        .where((DownloadTask task) => task.status.isActive)
        .length;
    final int paused = tasks
        .where((DownloadTask task) => task.status == DownloadStatus.paused)
        .length;
    final int completed = tasks
        .where((DownloadTask task) => task.status == DownloadStatus.completed)
        .length;

    return PageContentContainer(
      // 顶部标题与工具条固定、下面任务列表自己滚：所以要把可用高度撑满。
      fillHeight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(
            queue,
            tasks.length,
            active: active,
            paused: paused,
            completed: completed,
          ),
          const SizedBox(height: 14),
          if (queue != null) ...<Widget>[
            _DirectoryBar(
              directory: queue.directory,
              onChangeDirectory: () =>
                  unawaited(_guard(queue.selectDirectory, '更改目录')),
              onOpenFolder: () => unawaited(_guard(queue.openFolder, '打开下载目录')),
            ),
            const SizedBox(height: 12),
            _buildSourceTabs(tasks),
            const SizedBox(height: 10),
          ],
          Expanded(child: _buildBody(queue, tasks)),
        ],
      ),
    );
  }

  Widget _buildHeader(
    DownloadQueue? queue,
    int total, {
    required int active,
    required int paused,
    required int completed,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '下载管理',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                queue == null
                    ? '下载器未启用'
                    : '共 $total 个任务 · $active 个进行中 · $completed 个已完成',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (queue != null) ...<Widget>[
          OutlinedButton.icon(
            // 没有可暂停的任务时按钮变灰而不是消失：按钮的位置固定，
            // 用户不会因为"上一秒还在那儿"而点空。
            onPressed: active > 0
                ? () => unawaited(_guard(queue.pauseAll, '全部暂停'))
                : null,
            icon: const Icon(Icons.pause_rounded, size: 18),
            label: const Text('全部暂停'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: paused > 0
                ? () => unawaited(_guard(queue.resumeAll, '全部继续'))
                : null,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('全部继续'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: completed > 0
                ? () => unawaited(_guard(queue.clearCompleted, '清空已完成'))
                : null,
            icon: const Icon(Icons.playlist_remove_rounded, size: 18),
            label: const Text('清空已完成'),
          ),
        ],
      ],
    );
  }

  /// 顶部音源切换：`全部 / 网易云音乐 3 / 哔哩哔哩 1`。
  Widget _buildSourceTabs(List<DownloadTask> tasks) {
    final List<MediaSource> sources = _sources(tasks);
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          _SourceTab(
            label: '全部',
            count: tasks.length,
            selected: _filter == null,
            onTap: () => setState(() => _filter = null),
          ),
          for (final MediaSource source in sources)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _SourceTab(
                label: source.label,
                count: tasks
                    .where((DownloadTask task) => task.song.source == source)
                    .length,
                selected: _filter == source,
                onTap: () => setState(() => _filter = source),
              ),
            ),
        ],
      ),
    );
  }

  /// 需要出现在标签栏里的音源。
  ///
  /// 两个在线音源**始终列出**（哪怕暂时 0 条）：标签栏本身要能告诉用户
  /// "这里可以按音源分开看"，等有任务才冒出来的标签会让人以为只是个筛选按钮。
  /// 任务里出现过的其它音源（例如「本地」）补在后面。
  List<MediaSource> _sources(List<DownloadTask> tasks) {
    final List<MediaSource> result = <MediaSource>[
      MediaSource.netease,
      MediaSource.bilibili,
    ];
    for (final DownloadTask task in tasks) {
      if (!result.contains(task.song.source)) result.add(task.song.source);
    }
    return result;
  }

  Widget _buildBody(DownloadQueue? queue, List<DownloadTask> tasks) {
    if (queue == null) {
      return ListView(
        padding: EdgeInsets.zero,
        children: const <Widget>[
          EmptyStateView(
            icon: Icons.download_for_offline_outlined,
            title: '下载器未启用',
            message:
                '当前构建没有装配下载管理器（downloadQueueProvider 返回 null）。\n'
                '在 main.dart 的 ProviderScope.overrides 里覆盖它即可启用。',
          ),
        ],
      );
    }

    if (tasks.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: const <Widget>[
          EmptyStateView(
            icon: Icons.download_done_rounded,
            title: '还没有下载任务',
            message: '在歌曲行上点下载按钮，或从搜索结果里下载',
          ),
        ],
      );
    }

    final List<DownloadTask> visible = _filter == null
        ? tasks
        : tasks
              .where((DownloadTask task) => task.song.source == _filter)
              .toList(growable: false);

    if (visible.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          EmptyStateView(
            icon: Icons.filter_alt_off_outlined,
            title: '「${_filter?.label ?? '全部'}」还没有下载任务',
            message: '换个音源看看，任务按音源分栏存放',
          ),
        ],
      );
    }

    // 任务数量级是"几十"，不是歌单的几千：一次性构建整个列表换来的是
    // 分栏标题与行能整段拼装，不必为了懒加载把逻辑拆成下标运算。
    return GlassPanel(
      padding: const EdgeInsets.all(6),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: _buildItems(queue, visible),
      ),
    );
  }

  List<Widget> _buildItems(DownloadQueue queue, List<DownloadTask> visible) {
    if (_filter != null) {
      return <Widget>[
        for (final DownloadTask task in _sorted(visible)) _row(queue, task),
      ];
    }

    // 「全部」视图按音源分栏，每栏一个小标题 + 条数。
    final List<Widget> items = <Widget>[];
    for (final MediaSource source in _sources(visible)) {
      final List<DownloadTask> group = _sorted(
        visible
            .where((DownloadTask task) => task.song.source == source)
            .toList(growable: false),
      );
      if (group.isEmpty) continue;
      items.add(_SectionHeader(label: source.label, count: group.length));
      for (final DownloadTask task in group) {
        items.add(_row(queue, task));
      }
    }
    return items;
  }

  Widget _row(DownloadQueue queue, DownloadTask task) {
    return _DownloadTaskRow(
      key: ValueKey<String>(task.uid),
      task: task,
      onPause: () => unawaited(_guard(() => queue.pause(task.uid), '暂停下载')),
      onResume: () => unawaited(_guard(() => queue.resume(task.uid), '继续下载')),
      onCancel: () => unawaited(_guard(() => queue.cancel(task.uid), '取消下载')),
      onRetry: () => unawaited(_guard(() => queue.retry(task.uid), '重新下载')),
      onRemove: () => unawaited(_removeTask(queue, task)),
      onReveal: () =>
          unawaited(_guard(() => queue.revealFile(task.uid), '打开所在文件夹')),
    );
  }

  /// 移除任务。已完成的记录会先问一句"要不要连文件一起删"。
  ///
  /// 直接删文件是危险的默认值：用户点垃圾桶十有八九只是想清列表，
  /// 而已经下好的歌重新下一遍可能是几十兆流量。
  Future<void> _removeTask(DownloadQueue queue, DownloadTask task) async {
    bool deleteFile = false;
    final String? path = task.filePath;
    if (task.status == DownloadStatus.completed &&
        path != null &&
        path.isNotEmpty) {
      final bool? alsoDelete = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('移除下载记录'),
          content: const Text('同时删除已经下载好的文件吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('仅移除记录'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除文件'),
            ),
          ],
        ),
      );
      if (alsoDelete == null) return;
      deleteFile = alsoDelete;
    }
    await _guard(
      () => queue.remove(task.uid, deleteFile: deleteFile),
      deleteFile ? '删除任务与文件' : '移除任务',
    );
  }
}

/// 排序：下载中 → 排队 → 已暂停 → 已完成 → 失败 → 已取消。
///
/// 用"分桶拼接"而不是 `List.sort`：Dart 的排序不保证稳定，
/// 同状态的任务会被打乱，用户会看到列表无缘无故地跳动。
List<DownloadTask> _sorted(List<DownloadTask> tasks) {
  if (tasks.length < 2) return tasks;
  List<DownloadTask> bucket(DownloadStatus status) => tasks
      .where((DownloadTask task) => task.status == status)
      .toList(growable: false);
  return <DownloadTask>[
    ...bucket(DownloadStatus.running),
    ...bucket(DownloadStatus.queued),
    ...bucket(DownloadStatus.paused),
    ...bucket(DownloadStatus.completed),
    ...bucket(DownloadStatus.failed),
    ...bucket(DownloadStatus.cancelled),
  ];
}

/// 下载目录工具条：路径 + 更改目录 + 打开下载目录。
class _DirectoryBar extends StatelessWidget {
  const _DirectoryBar({
    required this.directory,
    required this.onChangeDirectory,
    required this.onOpenFolder,
  });

  final String? directory;
  final VoidCallback onChangeDirectory;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? path = directory;
    final bool ready = path != null && path.isNotEmpty;

    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.folder_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Text(
            '下载目录',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: ready ? '文件按音源分子文件夹存放\n$path' : '正在读取下载目录…',
              child: Text(
                ready ? path : '（正在准备…）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: ready
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: onChangeDirectory,
            icon: const Icon(Icons.drive_file_move_outline, size: 17),
            label: const Text('更改目录'),
            style: _compactButtonStyle,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onOpenFolder,
            icon: const Icon(Icons.folder_open_rounded, size: 17),
            label: const Text('打开下载目录'),
            style: _compactButtonStyle,
          ),
        ],
      ),
    );
  }
}

/// 工具条上的按钮比常规按钮矮一档：这一条只是"路径 + 两个动作"，
/// 用默认的 20/14 内边距会把整条撑得比标题还高。
final ButtonStyle _compactButtonStyle = OutlinedButton.styleFrom(
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
  minimumSize: Size.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
);

/// 音源标签（带条数徽标）。
class _SourceTab extends StatelessWidget {
  const _SourceTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return HoverBuilder(
      builder: (BuildContext context, bool hovered) {
        final Color background = selected
            ? scheme.primaryContainer
            : hovered
            ? scheme.onSurface.withValues(alpha: ZhyTokens.hoverOverlay)
            : Colors.transparent;
        final Color foreground = selected
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: tokens.fast,
            curve: ZhyTokens.standardCurve,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(tokens.pillRadius),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    // 内置字体只有 w400 一个字面，请求 w600 会被引擎描边合成
                    // （中文小字因此发虚、笔画不匀），所以这里恒为 w500；
                    // 选中态只靠上面的 foreground 颜色区分。
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.onPrimaryContainer.withValues(alpha: 0.14)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(tokens.pillRadius),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: foreground,
                      // 等宽数字：切换音源时徽标宽度不会左右跳。
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 「全部」视图里的音源分栏标题。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 4),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.4,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count 个任务',
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(width: 12),
          // 细线只用来"把标题和下面的行分开"，所以从文字后面开始延伸。
          Expanded(
            child: Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行下载任务。
class _DownloadTaskRow extends StatelessWidget {
  const _DownloadTaskRow({
    super.key,
    required this.task,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
    required this.onRemove,
    required this.onReveal,
  });

  final DownloadTask task;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onRemove;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Song song = task.song;
    final String? filePath = task.filePath;

    return HoverBuilder(
      cursor: SystemMouseCursors.basic,
      builder: (BuildContext context, bool hovered) {
        return AnimatedContainer(
          duration: tokens.fast,
          curve: ZhyTokens.standardCurve,
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: hovered
                ? scheme.primary.withValues(alpha: ZhyTokens.hoverOverlay)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(tokens.cardRadius),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.32),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              CoverImage(
                url: song.coverUrl,
                size: 44,
                borderRadius: BorderRadius.circular(8),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _StatusChip(status: task.status),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      song.artistLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // 进度条的颜色 / 轨道色全部来自主题的
                    // progressIndicatorTheme，这里不传任何颜色。
                    LinearProgressIndicator(
                      value: _progressValue(task),
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        Text(
                          _byteLabel(task),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _trailingLabel(task),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    if (task.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          task.error!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: scheme.error),
                        ),
                      ),
                    if (filePath != null && filePath.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Tooltip(
                          message: filePath,
                          child: Text(
                            filePath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(mainAxisSize: MainAxisSize.min, children: _actions()),
            ],
          ),
        );
      },
    );
  }

  /// 行内操作。按状态给不同的动作：「取消」和「暂停」必须分开，
  /// 用一个按钮去猜用户想干什么，最后两边都会做错。
  List<Widget> _actions() {
    final List<Widget> buttons = <Widget>[];
    switch (task.status) {
      case DownloadStatus.running:
        buttons.add(
          _iconButton(
            icon: Icons.pause_rounded,
            tooltip: '暂停',
            onPressed: onPause,
          ),
        );
        buttons.add(
          _iconButton(
            icon: Icons.close_rounded,
            tooltip: '取消下载',
            onPressed: onCancel,
          ),
        );
      case DownloadStatus.queued:
        buttons.add(
          _iconButton(
            icon: Icons.close_rounded,
            tooltip: '取消排队',
            onPressed: onCancel,
          ),
        );
      case DownloadStatus.paused:
        buttons.add(
          _iconButton(
            icon: Icons.play_arrow_rounded,
            tooltip: '继续下载',
            onPressed: onResume,
          ),
        );
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        buttons.add(
          _iconButton(
            icon: Icons.refresh_rounded,
            tooltip: '重试（会从断点续传）',
            onPressed: onRetry,
          ),
        );
      case DownloadStatus.completed:
        buttons.add(
          _iconButton(
            icon: Icons.folder_open_rounded,
            tooltip: '打开所在文件夹',
            onPressed: onReveal,
          ),
        );
    }
    buttons.add(
      _iconButton(
        icon: Icons.delete_outline_rounded,
        tooltip: '移除任务',
        onPressed: onRemove,
      ),
    );
    return buttons;
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      iconSize: 18,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
    );
  }

  /// 进度条的取值：null 表示"不确定进度"（来回跑的动画）。
  double? _progressValue(DownloadTask task) {
    if (task.status == DownloadStatus.completed) return 1;
    // 排队 / 暂停 / 失败 / 取消都不是"正在动"的状态：给确定值（可能为 0），
    // 比让进度条来回跑更诚实。
    if (task.status != DownloadStatus.running) return task.progress;
    // 真正下载中但服务端没给总大小、也还没收到任何数据：只有这时才用不确定动画。
    if (task.totalBytes == null && !task.hasStarted) return null;
    return task.progress;
  }

  String _byteLabel(DownloadTask task) {
    final String received = formatBytes(task.receivedBytes);
    final int? total = task.totalBytes;
    if (total == null || total <= 0) return '$received / 大小未知';
    return '$received / ${formatBytes(total)}';
  }

  String _trailingLabel(DownloadTask task) => switch (task.status) {
    DownloadStatus.running =>
      task.totalBytes == null ? '进行中' : '${task.percent}%',
    DownloadStatus.queued => '等待中',
    DownloadStatus.paused => '已暂停',
    // 终态用相对时间：状态胶囊已经写了"已完成"，这里再写一遍是浪费一行字。
    DownloadStatus.completed ||
    DownloadStatus.failed ||
    DownloadStatus.cancelled => ZhyFormat.relativeTime(
      task.finishedAt ?? task.createdAt,
    ),
  };
}

/// 状态胶囊。颜色全部来自色角色：主题色跟着封面走，
/// 写死的颜色在换封面之后一定显得脏。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final DownloadStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final (Color background, Color foreground, IconData icon) chip =
        switch (status) {
          DownloadStatus.running => (
            scheme.primaryContainer,
            scheme.onPrimaryContainer,
            Icons.downloading_rounded,
          ),
          DownloadStatus.queued => (
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant,
            Icons.schedule_rounded,
          ),
          DownloadStatus.paused => (
            scheme.surfaceContainerHigh,
            scheme.primary,
            Icons.pause_circle_outline_rounded,
          ),
          DownloadStatus.completed => (
            scheme.surfaceContainerHigh,
            scheme.primary,
            Icons.check_circle_rounded,
          ),
          DownloadStatus.failed => (
            scheme.error.withValues(alpha: 0.14),
            scheme.error,
            Icons.error_outline_rounded,
          ),
          DownloadStatus.cancelled => (
            scheme.surfaceContainerHigh,
            scheme.onSurfaceVariant,
            Icons.block_rounded,
          ),
        };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: chip.$1,
        borderRadius: BorderRadius.circular(context.tokens.pillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(chip.$3, size: 13, color: chip.$2),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: chip.$2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹一条提示。用 [ScaffoldMessenger.maybeOf]：内容组件可能被放在没有
/// Scaffold 的路由里，拿不到 messenger 时静默降级，而不是抛异常崩页面。
void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}
