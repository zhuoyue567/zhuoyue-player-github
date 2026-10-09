import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';
// 依赖方向说明：`DownloadQueue` 接口刻意留在下载页里（它是"这一页需要下载器
// 提供什么"的声明），所以 core 层反过来 import 一次 features。这样
// `main.dart` 只需要覆盖一个 provider，页面与实现之间也不需要互相认识。
import '../../features/downloads/downloads_page.dart';
import '../net/http_client.dart';
import '../storage/preferences.dart';
import '../storage/storage_paths.dart';
import '../utils/format.dart';
import 'download_task.dart';

/// 下载相关操作的失败。
///
/// 存在的意义只有一个：给用户一句**中文的、能照着做点什么**的话。
/// `toString()` 直接返回 message，所以界面上的 `'$error'` 不会漏出英文堆栈。
class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下载管理器：队列、并发、断点续传、持久化。
///
/// 它同时是 [DownloadQueue] 的唯一实现，被 `main.dart` 覆盖进
/// `downloadQueueProvider`。
///
/// 几条必须守住的约定：
/// - **同一时刻最多 [maxConcurrent] 个任务在下载**，其余排队。桌面端同时开
///   十几个连接会把带宽切得粉碎，每个任务的进度条都像冻住了；
/// - **进度不回写整个页面**：字节数是节流上报的（约 200ms 或 1% 一次），
///   大文件每收一个 chunk 就推一次会把 UI 线程刷爆；
/// - **异常一律落到任务的 [DownloadTask.error] 上**，绝不让它冒到 UI 之外；
///   一个任务失败不能影响同批次里的其它任务；
/// - **进度落盘有节流，但断点位置以磁盘文件长度为准**。进程被强杀时最后
///   几百毫秒的进度可能没写进 `tasks.json`，只要续传时以实际文件长度做
///   `Range` 起点，这个偏差就完全无害。
class DownloadManager implements DownloadQueue {
  /// 用容器的 [Ref] 构造：下载要用的东西（音源注册表、Dio、SharedPreferences）
  /// 全部从容器里取，这样 `main.dart` 里只需要一行 override。
  ///
  /// 生命周期自己管：构造时就把 [dispose] 挂到 `ref.onDispose` 上，
  /// 免得每个装配点都要记得写一遍。
  DownloadManager(this._ref, {StoragePaths? storagePaths})
    : _storage = storagePaths ?? StoragePaths.instance {
    _prefs = _ref.read(sharedPreferencesProvider);
    // 目录偏好是同步读得到的（SharedPreferences 实例已在 main() 里注入），
    // 所以界面第一帧就能显示正确路径，不会先闪一下默认值。
    //
    // **目录从哪来**这一件事全部交给 [StoragePaths]：安装器写的路径、用户在
    // 设置里改过的路径、以及"装过 / 没装过"两种情况的默认值，都在那一处收敛。
    // 这里不再自己算默认目录 —— 以前那套算法的默认值（`音乐\ZhuoYuePlayer`）
    // 与安装器的默认值不一致，于是"装过"和"没装过"的用户会看到两个不同的
    // 目录，而他们完全无从判断哪个才是对的。
    final String? chosen = _storage.chosenDownloadRoot();
    _customDirectory = (chosen != null && chosen.trim().isNotEmpty)
        ? chosen
        : null;
    // 环境变量都给不出目录（精简环境）时才退到应用支持目录：界面这一帧必须有
    // 一个能显示的值，哪怕它只是兜底。
    _rootDirectory = _customDirectory ?? _supportRootFallback();
    _ref.onDispose(dispose);
    _ready = _restore();
    // 装机时选的目录可能指向一块现在还没插上的盘。探测一次并回退，避免用户
    // 第一次点下载才看到"路径不存在"。
    unawaited(_validateRootDirectory());
  }

  /// 同时下载的任务数上限。
  ///
  /// 2 是"能跑满带宽"与"每个任务都还在动"之间的折中：1 个会让第二个任务
  /// 永远排在后面，3 个以上在几十兆的家用带宽上就开始互相拖慢。
  static const int maxConcurrent = 2;

  /// 下载根目录在 SharedPreferences 里的键。
  ///
  /// **保留这个名字只是为了兼容**：真正的键定义在 [StoragePaths] 上（那里是
  /// 目录这件事的唯一权威），这里转发过去，避免同一条偏好有两个字符串字面量。
  static const String directoryPreferenceKey =
      StoragePaths.downloadDirectoryKey;

  /// 下载根目录下的固定文件夹名。
  static const String rootFolderName = 'ZhuoYuePlayer';

  /// 任务列表文件名（放在应用支持目录的 `downloads/` 下）。
  static const String tasksFileName = 'tasks.json';

  /// 进度上报的最小间隔。低于这个间隔的变化合并成一次推送。
  static const Duration _progressInterval = Duration(milliseconds: 200);

  /// 落盘的合并窗口。进度是高频事件，每次都写盘会让磁盘一直转。
  static const Duration _persistDebounce = Duration(milliseconds: 800);

  final Ref _ref;

  /// 目录的唯一权威来源（见 `core/storage/storage_paths.dart`）。
  final StoragePaths _storage;

  late final SharedPreferences _prefs;

  /// 全部任务，键是 [DownloadTask.uid]。`Map` 保持插入顺序，界面据此稳定排序。
  final Map<String, DownloadTask> _tasks = <String, DownloadTask>{};

  /// 正在下载的任务：[uid] → 运行期句柄（取消令牌、订阅、节流状态）。
  final Map<String, _ActiveDownload> _active = <String, _ActiveDownload>{};

  /// 会话内的直链缓存。
  ///
  /// 存在的理由是 [ResolvedStream.expiresAt]：同一首歌在短时间内重试
  /// （失败重试、暂停后再继续）没必要再解析一次地址；而地址一旦过期，
  /// 必须重新解析 —— 继续用一个过期的签名直链只会拿到 403。
  final Map<String, ResolvedStream> _streamCache = <String, ResolvedStream>{};

  final StreamController<List<DownloadTask>> _changes =
      StreamController<List<DownloadTask>>.broadcast();

  /// 目录被别处改掉时的通知。
  ///
  /// "别处"就是设置页：下载目录现在有两个入口（下载页的「更改目录」和设置页的
  /// 「存储路径」），而它们改的是同一份设置。没有这条通道的话，用户从设置页
  /// 改完再切回下载页，看到的还是旧路径 —— 也就是"点了没反应"。
  ///
  /// 用 [ValueNotifier] 而不是让下载页去 watch 某个 provider：本类是
  /// `DownloadQueue` 的唯一实现，`main.dart` 只覆盖一个 provider，
  /// 页面不该为了知道目录而认识第二个 provider。
  final ValueNotifier<String?> _directoryChanges = ValueNotifier<String?>(null);

  Timer? _persistTimer;

  /// 写盘用的串行链，见 [_persistNow]。
  Future<void> _persistChain = Future<void>.value();

  /// 首次恢复完成。所有公开操作都先等它 —— 否则用户在页面刚打开时点的
  /// "继续"，会在存档还没读出来时被覆盖掉。
  late final Future<void> _ready;

  /// 用户在"更改目录"里选过的目录；null 表示用默认目录。
  String? _customDirectory;

  /// 当前生效的下载根目录（任务文件放在 `<根目录>/<音源名>/` 下）。
  String? _rootDirectory;

  Directory? _supportDirectoryCache;

  bool _disposed = false;

  // ------------------------------------------------------------ DownloadQueue

  @override
  List<DownloadTask> get tasks =>
      List<DownloadTask>.unmodifiable(_tasks.values);

  @override
  Stream<List<DownloadTask>> get changes => _changes.stream;

  /// 当前下载根目录。真实文件按音源分子目录存放，见 [_taskDirectory]。
  @override
  String? get directory => _rootDirectory;

  @override
  Listenable get directoryChanges => _directoryChanges;

  @override
  Future<void> start(Song song) async {
    await _ready;
    if (_disposed) return;

    final DownloadTask? existing = _tasks[song.uid];
    if (existing != null) {
      switch (existing.status) {
        case DownloadStatus.queued:
        case DownloadStatus.running:
        case DownloadStatus.completed:
          // 已经在队列里 / 已经下好了。重复入队只会让用户以为"点了没反应"。
          return;
        case DownloadStatus.paused:
        case DownloadStatus.failed:
        case DownloadStatus.cancelled:
          // 重新入队时保留 filePath 与 receivedBytes：半成品文件直接续传，
          // 不必把已经下好的几十兆再拉一遍。
          _replace(
            existing.copyWith(
              status: DownloadStatus.queued,
              error: null,
              finishedAt: null,
            ),
          );
      }
    } else {
      _replace(DownloadTask(song: song, createdAt: DateTime.now()));
    }
    _pump();
  }

  /// 取消任务并**保留已下载的部分**（状态 `cancelled`，可随时重试续传）。
  @override
  Future<void> cancel(String uid) async {
    await _ready;
    final DownloadTask? task = _tasks[uid];
    if (task == null || task.status == DownloadStatus.completed) return;

    final _ActiveDownload? active = _active[uid];
    if (active != null) {
      _stopActive(active, paused: false);
    }
    _settle(uid, DownloadStatus.cancelled);
    _pump();
  }

  /// 暂停：停掉连接但保留半成品文件，之后可以从断点继续。
  @override
  Future<void> pause(String uid) async {
    await _ready;
    final DownloadTask? task = _tasks[uid];
    if (task == null || !task.status.isActive) return;

    final _ActiveDownload? active = _active[uid];
    if (active != null) {
      _stopActive(active, paused: true);
    }
    _settle(uid, DownloadStatus.paused);
    _pump();
  }

  /// 继续（暂停 / 失败 / 取消过的任务重新排队）。
  @override
  Future<void> resume(String uid) => retry(uid);

  @override
  Future<void> retry(String uid) async {
    await _ready;
    final DownloadTask? task = _tasks[uid];
    if (task == null) return;
    if (task.status.isActive) return;

    _replace(
      task.copyWith(
        status: DownloadStatus.queued,
        // 清掉上一次的错误：否则「重试」之后界面上还挂着那句旧报错。
        error: null,
        finishedAt: null,
      ),
    );
    _pump();
  }

  /// 删除一条任务记录。
  ///
  /// [deleteFile] 为 true 时连文件一起删；默认只删记录（用户可能只是不想让
  /// 它占着列表，而不是想丢掉这首歌）。正在下载的任务会先被取消，并等它
  /// 真正停下来之后再删文件 —— 否则下载线程会在删除之后又把文件写回来。
  @override
  Future<void> remove(String uid, {bool deleteFile = false}) async {
    await _ready;
    final DownloadTask? task = _tasks[uid];
    if (task == null) return;

    final _ActiveDownload? active = _active[uid];
    if (active != null) {
      _stopActive(active, paused: false);
      // 收尾是异步的（要关 IO）。给它一点时间，删文件才是"删得掉"的。
      await active.closed.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
    }

    _tasks.remove(uid);
    _streamCache.remove(uid);
    _emit();
    _flushPersist();

    if (deleteFile) await _deleteFile(task.filePath);
  }

  @override
  Future<void> pauseAll() async {
    await _ready;
    for (final DownloadTask task in _tasks.values.toList(growable: false)) {
      if (!task.status.isActive) continue;
      final _ActiveDownload? active = _active[task.uid];
      if (active != null) _stopActive(active, paused: true);
      _settle(task.uid, DownloadStatus.paused);
    }
    _pump();
  }

  @override
  Future<void> resumeAll() async {
    await _ready;
    for (final DownloadTask task in _tasks.values.toList(growable: false)) {
      if (task.status != DownloadStatus.paused) continue;
      _replace(
        task.copyWith(
          status: DownloadStatus.queued,
          error: null,
          finishedAt: null,
        ),
      );
    }
    _pump();
  }

  /// 清空"已完成"的记录。**不删文件** —— 用户按的是"清列表"，
  /// 顺手删掉下载好的歌是最容易招骂的一种"贴心"。
  @override
  Future<void> clearCompleted() async {
    await _ready;
    final List<String> done = <String>[
      for (final DownloadTask task in _tasks.values)
        if (task.status == DownloadStatus.completed) task.uid,
    ];
    if (done.isEmpty) return;
    for (final String uid in done) {
      _tasks.remove(uid);
      _streamCache.remove(uid);
    }
    _emit();
    _flushPersist();
  }

  /// 让用户挑一个下载目录，并把选择记在 SharedPreferences 里。
  ///
  /// 选完之后**记录**这一步交给 [StoragePaths.setDirectory]：设置页的「存储
  /// 路径」用的是同一个入口，所以从下载页改和从设置页改是同一件事（包括
  /// 参数校验与"已采纳过安装器配置"的标记），不会出现"一边改完另一边不知道"。
  @override
  Future<void> selectDirectory() async {
    await _ready;
    try {
      final String? picked = await getDirectoryPath(
        confirmButtonText: '选择此文件夹',
      );
      if (picked == null || picked.trim().isEmpty) return;
      final String saved = await _storage.setDirectory(
        StorageDirectoryKind.download,
        picked,
      );
      _customDirectory = saved;
      _rootDirectory = saved;
      // 目录变了，界面上的路径要立刻跟着变。
      _emit();
      _directoryChanges.value = saved;
    } on StoragePathException catch (error) {
      // 这一层已经给的是中文原因（不可写 / 路径为空），直接透给界面。
      throw DownloadException(error.message);
    } on Object catch (error) {
      debugPrint('[download] 选择下载目录失败：$error');
      throw DownloadException('无法打开目录选择框：$error');
    }
  }

  /// 用资源管理器打开下载目录。
  @override
  Future<void> openFolder() async {
    final String dir = _rootDirectory ?? await _resolveRootDirectory();
    try {
      // 与设置页的「打开」按钮共用同一份实现（见 storage_paths.dart）：
      // `explorer` 的参数怎么传最容易错，只该有一处知道。
      await openDirectoryInExplorer(dir);
    } on Object catch (error) {
      debugPrint('[download] 打开下载目录失败：$error');
      throw DownloadException('无法打开下载目录：$dir');
    }
  }

  /// 在资源管理器里定位到某个任务的文件（选中它）。
  @override
  Future<void> revealFile(String uid) async {
    await _ready;
    final String? path = _tasks[uid]?.filePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      await openFolder();
      return;
    }
    try {
      await revealPathInExplorer(path);
    } on Object catch (error) {
      debugPrint('[download] 定位文件失败：$error');
      throw DownloadException('无法打开文件所在位置：$path');
    }
  }

  /// 收尾：停掉所有连接、把状态写成"已暂停"、关闭广播流。
  ///
  /// 由 `ref.onDispose` 自动调用（见构造函数）。这里**不推送 UI 更新** ——
  /// 容器销毁时界面也在销毁，推了也没人接。
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final _ActiveDownload active in _active.values.toList(
      growable: false,
    )) {
      active.disposed = true;
      active.token.cancel('下载管理器已关闭');
      unawaited(active.subscription?.cancel());
      if (!active.done.isCompleted) active.done.complete();
      // 把"正在下载"落成"已暂停"：进程已经死了，下次启动不可能还在下，
      // 存档里留一个 running 会让用户以为它还在偷偷跑。
      final DownloadTask? task = _tasks[active.uid];
      if (task != null && task.status == DownloadStatus.running) {
        _tasks[active.uid] = task.copyWith(
          status: DownloadStatus.paused,
          finishedAt: DateTime.now(),
        );
      }
    }
    _active.clear();

    _persistTimer?.cancel();
    _persistTimer = null;
    // 最后一次落盘（进程可能马上就没了，来不及等它，但值得发起）。
    _persistNow();
    unawaited(_changes.close());
    // 目录通知器也关掉：页面还挂在上面的监听要能收到"结束了"。
    _directoryChanges.dispose();
  }

  // ------------------------------------------------------------------ 队列

  /// 把队列填满到并发上限。任何状态变化之后都要调一次。
  void _pump() {
    if (_disposed) return;
    while (_active.length < maxConcurrent) {
      final DownloadTask? next = _nextQueued();
      if (next == null) return;
      _begin(next);
    }
  }

  /// 取队列里最早的排队任务。
  ///
  /// "最早"用 [DownloadTask.createdAt] 而不是插入顺序：重启后从存档恢复
  /// 的任务带的是当初入队的时间，用户看到的顺序才能和上次一致。
  DownloadTask? _nextQueued() {
    DownloadTask? best;
    for (final DownloadTask task in _tasks.values) {
      if (task.status != DownloadStatus.queued) continue;
      if (_active.containsKey(task.uid)) continue;
      if (best == null || task.createdAt.isBefore(best.createdAt)) best = task;
    }
    return best;
  }

  void _begin(DownloadTask task) {
    final _ActiveDownload active = _ActiveDownload(
      uid: task.uid,
      token: CancelToken(),
    );
    _active[task.uid] = active;
    _update(
      task.uid,
      (DownloadTask current) =>
          current.copyWith(status: DownloadStatus.running, error: null),
    );
    unawaited(_run(active));
  }

  /// 单个任务的完整生命周期。**这里不允许抛异常** —— 所有失败都落到任务的
  /// `error` 上，然后继续泵下一个任务。
  Future<void> _run(_ActiveDownload active) async {
    final String uid = active.uid;
    try {
      await _download(active);
      // 暂停 / 取消是"外部叫停"，状态已经被那边写好了，这里不要覆盖。
      if (active.stopped) return;
      _update(uid, (DownloadTask task) {
        return task.copyWith(
          status: DownloadStatus.completed,
          // 服务端没给总大小时，把已收到的量当成总量，进度条才能走满。
          totalBytes: task.totalBytes ?? task.receivedBytes,
          finishedAt: DateTime.now(),
          error: null,
        );
      });
      _flushPersist();
    } on Object catch (error, stackTrace) {
      if (active.stopped) return;
      debugPrint('[download] $uid 下载失败：$error\n$stackTrace');
      _settle(uid, DownloadStatus.failed, error: _describe(error));
    } finally {
      _active.remove(uid);
      if (!active.closed.isCompleted) active.closed.complete();
      _pump();
    }
  }

  /// 让一个正在运行的任务停下来。[paused] 决定这次停止算暂停还是取消。
  void _stopActive(_ActiveDownload active, {required bool paused}) {
    active.paused = paused;
    active.cancelled = !paused;
    // 两件事都要做：cancel token 断开 socket，cancel 订阅停止写文件。
    // 只做一件的话，另一边还会继续往磁盘里灌几百 KB 才停。
    active.token.cancel(paused ? '用户暂停了下载' : '用户取消了下载');
    unawaited(active.subscription?.cancel());
    if (!active.done.isCompleted) active.done.complete();
  }

  /// 把任务定格在某个终态上。
  ///
  /// 终态立刻落盘（不等合并窗口）：这是"用户马上会看到、也可能马上关掉程序"
  /// 的状态，拖 800ms 的话，强杀进程会在存档里留下一条"已暂停"的已完成任务。
  void _settle(String uid, DownloadStatus status, {String? error}) {
    _update(
      uid,
      (DownloadTask task) => task.copyWith(
        status: status,
        error: error,
        finishedAt: DateTime.now(),
      ),
    );
    _flushPersist();
  }

  // -------------------------------------------------------------- 实际下载

  /// 下载一个任务的全部字节。
  Future<void> _download(_ActiveDownload active) async {
    final String uid = active.uid;
    final DownloadTask? current = _tasks[uid];
    // 理论上不可能走到这里（任务被移除时也会先叫停），但**绝不**用 `!`
    // 去赌一个可能为 null 的值：这里崩掉会变成一个没人接的异步异常。
    if (current == null) return;
    final DownloadTask task = current;
    final Song song = task.song;

    final MusicRepository? repository = _ref
        .read(sourceRegistryProvider)
        .bySource(song.source);
    if (repository == null) {
      throw DownloadException('「${song.source.label}」暂时不支持下载');
    }

    // 1) 地址。可能已经过期（网易云直链带时效签名）→ 重新解析。
    ResolvedStream stream = await _resolve(repository, song);
    if (active.stopped) return;

    // 2) 目标文件。已经有记录就沿用（扩展名和去重都已定好），否则新建。
    final File file;
    final String? recorded = task.filePath;
    if (recorded != null && recorded.isNotEmpty) {
      file = File(recorded);
    } else {
      final String directory = await _taskDirectory(song);
      await Directory(directory).create(recursive: true);
      file = _targetFile(directory, song, _extensionFor(stream.mimeType));
      _update(
        uid,
        (DownloadTask current) => current.copyWith(filePath: file.path),
      );
    }
    await file.parent.create(recursive: true);
    if (active.stopped) return;

    // 3) 断点位置。**以磁盘上的真实长度为准**：存档里的 receivedBytes 可能
    //    比文件落后（落盘是节流的），以它做 Range 起点会重复写入一段数据。
    int resumeFrom = 0;
    if (file.existsSync()) resumeFrom = file.lengthSync();
    if (resumeFrom > 0) {
      _update(
        uid,
        (DownloadTask current) => current.copyWith(receivedBytes: resumeFrom),
      );
    }
    // 文件已经完整：不必再发一次请求。
    final int? knownTotal = task.totalBytes;
    if (resumeFrom > 0 && knownTotal != null && resumeFrom >= knownTotal) {
      return;
    }

    // 4) 发请求。416 表示服务端不接受这个续传起点（文件被改过 / 已经下完），
    //    此时**只能从头再来**：把两段字节接在一起会得到一个坏文件。
    bool append = resumeFrom > 0;
    Response<ResponseBody> response;
    try {
      response = await _open(stream, from: resumeFrom, token: active.token);
    } on _RangeNotSatisfiable {
      debugPrint('[download] $uid 服务端不接受续传起点（416），改为重新下载');
      await file.writeAsBytes(const <int>[], flush: true);
      resumeFrom = 0;
      append = false;
      _update(
        uid,
        (DownloadTask current) =>
            current.copyWith(receivedBytes: 0, totalBytes: null),
      );
      stream = await _resolve(repository, song, force: true);
      if (active.stopped) return;
      response = await _open(stream, from: 0, token: active.token);
    }

    final int code = response.statusCode ?? 0;
    // 服务端忽略 Range（返回 200 全量）时不能在文件后面追加，
    // 否则文件会变成"半段旧数据 + 全量新数据"。
    final bool effectiveAppend = append && code == HttpStatus.partialContent;
    if (append && !effectiveAppend) {
      debugPrint('[download] $uid 服务端未支持 Range（$code），从头下载');
      resumeFrom = 0;
    }

    final int? contentLength = _contentLength(response);
    final int? total = contentLength == null
        ? (stream.sizeBytes ?? task.totalBytes)
        : contentLength + (effectiveAppend ? resumeFrom : 0);

    // 5) 落盘。
    final ResponseBody body = response.data!;
    final IOSink sink = file.openWrite(
      mode: effectiveAppend ? FileMode.append : FileMode.write,
    );
    int received = effectiveAppend ? resumeFrom : 0;

    final StreamSubscription<Uint8List> subscription = body.stream.listen(
      (Uint8List chunk) {
        sink.add(chunk);
        received += chunk.length;
        _reportProgress(active, received, total);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!active.done.isCompleted) {
          active.done.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!active.done.isCompleted) active.done.complete();
      },
      cancelOnError: true,
    );
    active.subscription = subscription;

    try {
      await active.done.future;
      if (!active.stopped) await sink.flush();
    } finally {
      active.subscription = null;
      await subscription.cancel();
      try {
        // 无论成功、失败还是被叫停，都要把已经写进去的字节交给系统：
        // 断点续传要的就是这些数据。
        await sink.close();
      } on Object catch (error) {
        debugPrint('[download] $uid 关闭文件时出错（已忽略）：$error');
      }
    }

    _reportProgress(active, received, total, force: true);
    if (active.stopped) return;

    if (total != null && total > 0 && received < total) {
      throw DownloadException(
        '连接提前中断：已收到 ${ZhyFormat.bytes(received)} / '
        '${ZhyFormat.bytes(total)}，可以重试续传',
      );
    }
  }

  /// 发起一次流式 GET。
  ///
  /// [ResolvedStream.headers] 必须原样带上：哔哩的音频 CDN 会校验 `Referer`
  /// 与浏览器 UA，缺一个就是 403 —— 而 403 的响应体通常还是一段 JSON，
  /// 看起来"下载成功了但文件只有 200 字节"。
  Future<Response<ResponseBody>> _open(
    ResolvedStream stream, {
    required int from,
    required CancelToken token,
  }) async {
    final Dio dio = _ref.read(dioProvider);
    final Response<ResponseBody> response;
    try {
      response = await dio.get<ResponseBody>(
        stream.url.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, dynamic>{
            ...stream.headers,
            // 断点续传：从已落盘的字节之后接着要。服务端支持时回 206，
            // 不支持时回 200 全量，两种都由下面的状态码分支处理。
            if (from > 0) 'Range': 'bytes=$from-',
          },
          // 自己判断状态码：403 / 404 / 416 各自要有不同的说法，
          // 交给 Dio 统一抛"bad response"就只剩一个数字了。
          validateStatus: (int? code) => code != null && code < 500,
          // 只约束"响应头多久没来"；响应体是流式的，不受它限制，
          // 所以大文件不会被这个超时误杀。
          receiveTimeout: const Duration(seconds: 30),
        ),
        cancelToken: token,
      );
    } on DioException catch (error) {
      throw DownloadException(_describeDio(error));
    }

    final int code = response.statusCode ?? 0;
    if (code == HttpStatus.requestedRangeNotSatisfiable) {
      throw const _RangeNotSatisfiable();
    }
    if (code < 200 || code >= 300) {
      throw DownloadException(_statusMessage(code));
    }
    if (response.data == null) {
      throw const DownloadException('音源没有返回任何数据');
    }
    return response;
  }

  /// 取地址：缓存里那个还没过期就直接用，否则重新解析。
  Future<ResolvedStream> _resolve(
    MusicRepository repository,
    Song song, {
    bool force = false,
  }) async {
    final ResolvedStream? cached = force ? null : _streamCache[song.uid];
    if (cached != null && cached.isValidAt(DateTime.now())) return cached;
    final ResolvedStream fresh = await repository.resolveStream(song);
    _streamCache[song.uid] = fresh;
    return fresh;
  }

  /// 进度节流上报：约 200ms 一次，或涨了 1% 就来一次。
  ///
  /// 大文件每秒能收到上千个 chunk，逐个推送会让整页每秒重建上千次 ——
  /// 表现为"下载时界面卡住不动"。
  void _reportProgress(
    _ActiveDownload active,
    int received,
    int? total, {
    bool force = false,
  }) {
    final DateTime now = DateTime.now();
    if (!force) {
      final bool byTime =
          now.difference(active.lastReportedAt) >= _progressInterval;
      final bool byPercent =
          total != null &&
          total > 0 &&
          (received - active.lastReportedBytes) * 100 >= total;
      if (!byTime && !byPercent) return;
    }
    active.lastReportedAt = now;
    active.lastReportedBytes = received;
    _update(
      active.uid,
      (DownloadTask task) => task.copyWith(
        receivedBytes: received,
        totalBytes: total ?? task.totalBytes,
      ),
    );
  }

  // ------------------------------------------------------------ 目录与命名

  /// 任务的目标目录：`<根目录>/<音源名>/`。
  ///
  /// 按音源分子目录不是为了好看：两个平台的曲目重名率很高（同一首翻唱、
  /// 同一张专辑），混在一个目录里迟早会出现"下载被静默跳过"或互相覆盖。
  Future<String> _taskDirectory(Song song) async {
    final String root = _rootDirectory ?? await _resolveRootDirectory();
    return _join(root, _sanitizeSegment(song.source.label));
  }

  /// 解析根目录：用户选的 > 安装器采纳的值 > 与安装器一致的默认值 >
  /// 应用支持目录 > 临时目录。
  ///
  /// 这条链**全部**由 [StoragePaths.ensureDirectory] 给出，本类不再自己判断
  /// "哪个目录能用"：可写性探测（盘不存在 / 只读介质 / 权限不足）也在那里，
  /// 所以这里拿到的目录是真的能写的，而不是"看起来像"。
  Future<String> _resolveRootDirectory() async {
    final StorageDirectoryProbe probe = await _storage.ensureDirectory(
      StorageDirectoryKind.download,
    );
    final String? resolved = probe.directory;
    if (resolved != null) return _rootDirectory = resolved;
    // 连临时目录都写不了（极端环境）。退回应用支持目录，让错误以"写文件失败"
    // 的形式出现在任务上，而不是在这里抛出一个没人接的异步异常。
    debugPrint('[download] 没有可写的下载目录：${probe.failure}');
    return _rootDirectory = _join(
      (await _supportDirectory()).path,
      rootFolderName,
    );
  }

  /// 构造函数里要一个同步可用的值，这里给出最后的同步兜底。
  ///
  /// 正常情况下 [StoragePaths] 已经由环境变量算出了与安装器一致的默认目录，
  /// 走不到这里；只有 `USERPROFILE` / `APPDATA` 都不存在（精简环境）时才会。
  String _supportRootFallback() {
    final Directory cached = _supportDirectoryCache ?? Directory.systemTemp;
    return _join(cached.path, rootFolderName);
  }

  /// 启动时验证一次当前根目录，不可用就换成回退链给出的目录并记下来。
  ///
  /// 为什么需要它：[StoragePaths] 的同步取值只读偏好，不碰 IO，所以它可能指向
  /// 一块没插上的移动硬盘，也可能还没读过安装器配置（构造函数不能 await）。
  /// 这里补上一次"采纳 + 探测"，把结果写回偏好 —— 否则每次启动、每次写任务
  /// 目录都要白探一次。
  Future<void> _validateRootDirectory() async {
    try {
      // 先采纳安装器的选择：构造函数是同步的，那一步只能在这里补。
      // 不补的话装配器写的下载目录要等到用户手动改一次才会生效。
      await _storage.adoptInstallerChoicesIfNeeded();

      final String adopted = _storage.chosenDownloadRoot() ?? '';
      if (adopted.isNotEmpty && adopted != _rootDirectory) {
        _customDirectory = adopted;
        _rootDirectory = adopted;
        _emit();
      }

      final String? current = _rootDirectory;
      if (current == null || current.trim().isEmpty) return;
      final StorageDirectoryProbe probe = await _storage.ensureDirectory(
        StorageDirectoryKind.download,
      );
      final String? resolved = probe.directory;
      if (resolved == null || resolved == current) return;
      // 只有在**不能写**的时候才换：能写就说明用户选的目录是好的，
      // 不该因为我们探测顺手建了别的目录就把它换掉。
      if (await isDirectoryWritable(Directory(current))) return;
      _customDirectory = resolved;
      _rootDirectory = resolved;
      await _prefs.setString(directoryPreferenceKey, resolved);
      debugPrint('[download] 原下载目录不可写，已改用：$resolved');
      _emit();
      _directoryChanges.value = resolved;
    } on Object catch (error) {
      debugPrint('[download] 校验下载目录失败（已忽略）：$error');
    }
  }

  /// 应用支持目录。取不到（例如在测试环境里没有插件注册）时逐级退让。
  Future<Directory> _supportDirectory() async {
    final Directory? cached = _supportDirectoryCache;
    if (cached != null) return cached;
    try {
      return _supportDirectoryCache = await getApplicationSupportDirectory();
    } on Object catch (error) {
      debugPrint('[download] 应用支持目录不可用（$error），改用环境变量 / 临时目录');
    }
    final String? appData = Platform.environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      return _supportDirectoryCache = Directory(_join(appData, rootFolderName));
    }
    return _supportDirectoryCache = Directory.systemTemp;
  }

  /// 任务列表文件 `<应用支持目录>/downloads/tasks.json`。
  ///
  /// **刻意不放在用户可改的「下载目录」里**：`tasks.json` 是"读不出来就丢状态"
  /// 的存档（断点位置、已完成记录），而下载目录是可以随时被用户改掉、甚至换到
  /// 一个移动硬盘上的。把存档和音频文件混在一起，用户改目录就会连带丢掉任务
  /// 列表。存档留在应用支持目录里，与 `installer.json` 同处一地，最稳。
  Future<File> _tasksFile() async {
    final String dir = _join((await _supportDirectory()).path, 'downloads');
    return File(_join(dir, tasksFileName));
  }

  /// 按 `<艺人> - <歌名>.<扩展名>` 生成目标文件，并避开已经被别的任务占用的名字。
  File _targetFile(String directory, Song song, String extension) {
    final String base = _sanitizeFileName(song);
    final Set<String> taken = <String>{
      for (final DownloadTask task in _tasks.values)
        if (task.song.uid != song.uid &&
            task.filePath != null &&
            task.filePath!.isNotEmpty)
          task.filePath!,
    };
    String candidate = _join(directory, '$base.$extension');
    int index = 2;
    while (taken.contains(candidate)) {
      candidate = _join(directory, '$base ($index).$extension');
      index++;
    }
    return File(candidate);
  }

  /// 从 [Song.safeFileName]（已经去过 Windows 非法字符）出发做最后一点收尾。
  ///
  /// 两件 `safeFileName` 管不到的事：Windows 上文件名不能以点或空格结尾
  /// （`晴天.` 会被系统静默截断成 `晴天`，于是"文件明明下好了却打不开"），
  /// 以及超长文件名会撞上路径长度上限。
  String _sanitizeFileName(Song song) {
    String name = song.safeFileName.trim().replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty) {
      // 歌名全是不合法字符时，至少给一个稳定可读的兜底名字。
      name = song.uid.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    }
    if (name.length > 120) name = name.substring(0, 120);
    return name;
  }

  /// 目录名同样不能带 Windows 非法字符（音源名目前是安全的，但不该依赖这点）。
  String _sanitizeSegment(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');

  /// 从 MIME 推扩展名。
  ///
  /// 宁可回落成 mp3 也不猜：扩展名错会让"双击用系统播放器打开"直接失败，
  /// 而用户看到文件在那儿、就是不响，是最难自查的一类问题。
  String _extensionFor(String? mimeType) {
    final String mime = (mimeType ?? '').toLowerCase();
    if (mime.contains('flac')) return 'flac';
    if (mime.contains('mpeg') || mime.contains('mp3')) return 'mp3';
    if (mime.contains('mp4') || mime.contains('m4a') || mime.contains('aac')) {
      return 'm4a';
    }
    return 'mp3';
  }

  int? _contentLength(Response<ResponseBody> response) {
    final String? raw = response.headers.value(Headers.contentLengthHeader);
    if (raw == null) return null;
    final int? value = int.tryParse(raw);
    return (value != null && value > 0) ? value : null;
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } on Object catch (error) {
      debugPrint('[download] 删除文件失败（已忽略）：$path -> $error');
    }
  }

  // ------------------------------------------------------------ 状态与持久化

  void _replace(DownloadTask task) {
    _tasks[task.uid] = task;
    _emit();
  }

  /// 改一个任务。任务已经被移除（用户手快点了移除）时什么也不做。
  void _update(String uid, DownloadTask Function(DownloadTask task) change) {
    final DownloadTask? task = _tasks[uid];
    if (task == null) return;
    _replace(change(task));
  }

  /// 推一份**新的**列表给界面。
  ///
  /// 必须是一个新实例：界面靠 `setState` 换引用，复用同一个 List 时
  /// 前后引用相同，可能整页不刷新。
  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(List<DownloadTask>.unmodifiable(_tasks.values));
    _schedulePersist();
  }

  void _schedulePersist() {
    if (_disposed) return;
    _persistTimer ??= Timer(_persistDebounce, () {
      _persistTimer = null;
      _persistNow();
    });
  }

  /// 立刻写盘，不等合并窗口。用于终态变更与"删除记录"这类一次性动作。
  void _flushPersist() {
    if (_disposed) return;
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistNow();
  }

  /// 把"写任务列表"追加到一条串行的写入链上。
  ///
  /// **必须串行**：两次 `writeAsString` 并发时，先发起的那次完全可能后落盘，
  /// 于是磁盘上留下的是更旧的状态（界面已经是"已取消"，存档里还写着"下载中"）。
  /// 挂进一条链里，就能保证最后一次调用最终胜出。
  void _persistNow() {
    _persistChain = _persistChain.then((void _) => _writeTasks()).catchError((
      Object error,
    ) {
      // 存档写不出去不是"下载失败"，没有理由打断正在跑的任务。
      debugPrint('[download] 任务列表写入失败（已忽略）：$error');
    });
  }

  Future<void> _writeTasks() async {
    final File file = await _tasksFile();
    await file.parent.create(recursive: true);
    final String text = jsonEncode(<Object?>[
      for (final DownloadTask task in _tasks.values) task.toJson(),
    ]);
    await file.writeAsString(text, flush: true);
  }

  /// 启动时恢复任务列表。
  Future<void> _restore() async {
    try {
      final File file = await _tasksFile();
      if (!await file.exists()) {
        _emit();
        return;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        _emit();
        return;
      }
      for (final Object? entry in decoded) {
        if (entry is! Map) continue;
        final DownloadTask task;
        try {
          task = DownloadTask.fromJson(<String, Object?>{
            for (final MapEntry<Object?, Object?> item in entry.entries)
              '${item.key}': item.value,
          });
        } on Object catch (error) {
          // 单条坏记录只丢它自己：一条脏数据不该让整份下载列表消失。
          debugPrint('[download] 跳过损坏的任务记录：$error');
          continue;
        }
        _tasks[task.uid] = await _reconcileWithDisk(task);
      }
    } on Object catch (error) {
      debugPrint('[download] 任务列表读取失败（当作空列表）：$error');
    }
    _emit();
  }

  /// 把一条恢复出来的记录和磁盘上的真实文件对齐。
  Future<DownloadTask> _reconcileWithDisk(DownloadTask task) async {
    // 进程已经死了：重启后不可能还有任务在下载，running 一律降级为 paused。
    DownloadTask restored = task.status == DownloadStatus.running
        ? task.copyWith(status: DownloadStatus.paused)
        : task;

    final String? path = restored.filePath;
    if (path == null || path.isEmpty) return restored;

    final File file = File(path);
    final bool exists = await file.exists();
    if (!exists) {
      if (restored.status == DownloadStatus.completed) {
        // 文件被用户删了 / 移走了。继续显示"已完成"就是在骗人。
        return restored.copyWith(
          status: DownloadStatus.failed,
          error: '文件已被移动或删除，请重新下载',
          filePath: null,
        );
      }
      return restored.copyWith(receivedBytes: 0, filePath: null);
    }

    final int length = await file.length();
    return restored.copyWith(receivedBytes: length);
  }

  // -------------------------------------------------------------- 错误文案

  /// 把任意异常收敛成一句中文。
  ///
  /// 界面上直接显示 `$error`，所以这里绝不能把 DioException 的英文堆栈
  /// 原样透出去 —— 用户看到一串 `SocketException: ...` 是没法照着做什么的。
  String _describe(Object error) {
    if (error is DownloadException) return error.message;
    if (error is MusicApiException) return error.message;
    if (error is DioException) return _describeDio(error);
    if (error is FileSystemException) {
      final String where = error.path == null ? '' : '（${error.path}）';
      return '写入文件失败$where：${error.message}';
    }
    final String text = '$error';
    if (text.contains('SocketException') ||
        text.contains('Connection') ||
        text.contains('timed out')) {
      return '网络连接失败，请检查网络后重试';
    }
    return '下载失败：$text';
  }

  String _describeDio(DioException error) {
    switch (error.type) {
      case DioExceptionType.cancel:
        return '下载已停止';
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '连接音源超时，请稍后重试';
      case DioExceptionType.connectionError:
        return '无法连接音源，请检查网络后重试';
      case DioExceptionType.badCertificate:
        return '音源证书校验失败，已中止下载';
      case DioExceptionType.badResponse:
        final int? code = error.response?.statusCode;
        return code == null ? '音源返回了无法识别的响应' : _statusMessage(code);
      case DioExceptionType.unknown:
        break;
    }
    final String text = '${error.message ?? error.error ?? error}';
    if (text.contains('SocketException') || text.contains('Connection')) {
      return '网络连接失败，请检查网络后重试';
    }
    return '下载失败：$text';
  }

  /// HTTP 状态码的中文解释。403 / 404 是下载里最常遇到的两个。
  String _statusMessage(int code) {
    switch (code) {
      case HttpStatus.unauthorized:
        return '需要登录后才能下载（401），请先在设置里登录';
      case HttpStatus.forbidden:
        return '音源拒绝了下载请求（403）：直链可能已过期或需要重新登录';
      case HttpStatus.notFound:
        return '直链已失效或文件不存在（404），请重试';
      case HttpStatus.requestedRangeNotSatisfiable:
        return '服务端不接受续传起点（416），请重新下载';
      default:
        return '音源返回了错误（$code），请稍后重试';
    }
  }
}

// ---------------------------------------------------------------------------
// 运行期句柄与小异常
// ---------------------------------------------------------------------------

/// 一个正在下载的任务的运行期状态。
///
/// 和 [DownloadTask] 分开：任务是**要被持久化的数据**，这里是"这次运行的
/// 取消令牌、订阅、节流计时"，两者生命周期完全不同，混在一起会让存档里
/// 躺着几个没法序列化的字段。
class _ActiveDownload {
  _ActiveDownload({required this.uid, required this.token});

  final String uid;
  final CancelToken token;

  /// 写完（或出错）时完成。用它把"监听流"改造成 `await`。
  final Completer<void> done = Completer<void>();

  /// 整个任务彻底结束（文件已关闭）时完成。移除任务要靠它等文件句柄释放。
  final Completer<void> closed = Completer<void>();

  StreamSubscription<Uint8List>? subscription;

  bool paused = false;
  bool cancelled = false;
  bool disposed = false;

  DateTime lastReportedAt = DateTime.now();
  int lastReportedBytes = 0;

  /// 是否已经被叫停（暂停 / 取消 / 管理器关闭）。
  bool get stopped => paused || cancelled || disposed;
}

/// 服务端不接受 `Range` 起点（416）。内部信号，不面向用户。
class _RangeNotSatisfiable implements Exception {
  const _RangeNotSatisfiable();

  @override
  String toString() => '服务端不接受续传起点';
}

// ---------------------------------------------------------------------------
// 路径工具
//
// 不 import `package:path`：它不是本项目的直接依赖，为两次字符串拼接引入一个
// 隐式依赖并不划算（`depend_on_referenced_packages` 也会报出来）。
// ---------------------------------------------------------------------------

String _join(String parent, String child) {
  if (parent.isEmpty) return child;
  return parent.endsWith(Platform.pathSeparator)
      ? '$parent$child'
      : '$parent${Platform.pathSeparator}$child';
}
