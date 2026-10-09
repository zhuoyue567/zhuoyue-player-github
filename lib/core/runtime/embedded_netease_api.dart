import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/media_source.dart';
import '../../data/repositories/music_repository.dart';
import 'runtime_installer.dart';

/// 就绪信号。`runtime/netease-api/launcher.js` 在服务**真正可响应**之后
/// 才在 stdout 打印这一行，所以只要读到它就不必再自己轮询端口。
const String kReadySignal = 'ZHUOYUE_API_READY';

/// 就绪行的匹配式。
///
/// 刻意用 `\s+` 而不是单个空格，并且端口只抓 `\d+`：
/// Node 在 Windows 上输出的是 CRLF，日志按行拆分后行尾常常还残留一个 `\r`，
/// `(\d+)` 天然不会把它吃进去，也就不会把端口解析成 `59451\r`。
final RegExp kReadyPattern = RegExp(r'ZHUOYUE_API_READY\s+(\d+)');

/// 内嵌网易云 API 服务（Node + NeteaseCloudMusicApi）的进程生命周期管理。
///
/// 这个类只干四件事：找到运行时、把 node 拉起来、把端口交出去、退出时收尸。
/// 所有 HTTP 细节都留给 `NeteaseApiClient` —— 进程管理和接口调用混在一起，
/// 出问题时（是服务没起来还是接口报错）就分不清了。
///
/// 关键约束是**幂等**：UI 上多个页面会并发地首次请求数据，
/// 如果每个调用都自己 spawn 一个 node，用户会看到好几个几百 MB 的进程，
/// 而且端口各不相同、cookie 各存各的。所以这里缓存同一个 Future。
class EmbeddedNeteaseApi {
  EmbeddedNeteaseApi({this.readyTimeout = const Duration(seconds: 60)}) {
    // 在构造函数里登记自己，而不是只让 provider 去登记。
    // 原因：`shutdownEmbeddedNeteaseApi()` 只能通过 `_activeInstance` 找到
    // 正在跑的服务进程。如果某个调用方（例如集成测试）直接 `new` 一个实例
    // 而没走 provider，登记就会落空，退出时那个 node 进程就变成孤儿 ——
    // 表现为"测试跑完任务管理器里多一个 node.exe"。把不变量收进构造函数，
    // 任何构造路径都逃不掉。
    _activeInstance = this;
  }

  /// 服务只监听回环地址：内嵌服务带登录态，绝不能暴露到局域网。
  static const String host = '127.0.0.1';

  /// 运行时缺失时给用户看的话。UI 直接展示它，不要自己拼字符串。
  ///
  /// 安装包**不再内嵌**运行时（内嵌会让安装包多出 121MB），所以这里的读者
  /// 是装完就用的普通用户，不能再让人去跑 `scripts/fetch-runtime.ps1`
  /// —— 那是开发脚本，安装后的机器上根本没有。
  ///
  /// 文案刻意不说"点某个按钮"：按钮在设置页，措辞随 UI 变化，
  /// 而这句话写死在核心层。这里只承诺"应用内可以下载安装"，
  /// 具体入口由 UI 自己引导。
  static const String missingRuntimeHint =
      '尚未安装内嵌运行时（Node + 网易云 API）。'
      '可以在应用内自动下载安装（设置里的内嵌服务/运行时入口），'
      '也可以手动把 runtime 目录（含 node/ 与 netease-api/）放到程序所在目录'
      '（exe 同级）后重启应用。';

  /// 由 [RuntimeInstaller] 告诉本类的"这次装到哪了"。
  ///
  /// 存在的理由：搜索路径是同步的（UI 在 build 里就问 `isAvailable`），
  /// 而安装目标由 path_provider 决定、只有异步才知道。与其在
  /// [_resolveRuntime] 里瞎猜一个路径，不如让安装完的那一方把确切位置登记进来。
  ///
  /// 只是**兜底**：登记的目录排在最后，不会盖住 exe 同级/上溯找到的运行时
  /// —— 用户手里明明有自带运行时，却被应用数据目录里的旧副本顶掉，
  /// 是比"找不到"更难查的一类问题。
  static final List<String> _registeredRuntimeDirectories = <String>[];

  /// 登记一个"已经装好的"运行时目录。重复登记会被忽略。
  static void registerInstalledRuntimeDirectory(Object directory) {
    final String path =
        directory is Directory ? directory.path : '$directory';
    if (path.trim().isEmpty) return;
    if (!_registeredRuntimeDirectories.contains(path)) {
      _registeredRuntimeDirectories.add(path);
    }
  }

  /// 仅供测试：清空登记，避免用例之间互相污染。
  static void resetRegisteredRuntimeDirectories() {
    _registeredRuntimeDirectories.clear();
  }

  /// 运行时搜索路径，按优先级从高到低。
  ///
  /// 顺序是刻意的：
  ///  1. 环境变量 `ZHUOYUE_RUNTIME_DIR`：开发和排障时的最高优先级，
  ///     用来指一个临时运行时，不必动任何目录；
  ///  2. exe 同级 → exe 向上回溯：打包发布的**标准**布局（CMake 会把
  ///     `runtime/` 拷到 exe 旁边），以及开发时 exe 在
  ///     `build/windows/x64/runner/Debug/` 需要往上找几层；
  ///  3. 当前目录向上回溯：从仓库根直接 `flutter run` 的情况；
  ///  4. 应用数据目录里下载的那份（+ 显式登记过的）：
  ///     只有前面的目录都没有，才动它。
  ///
  /// 也就是"**自带的优先，下载的兜底**"：便携版/安装包自带运行时应当
  /// 永远压过用户机器上可能过期的旧副本。
  static List<String> resolveSearchPaths() {
    final List<String> candidates = <String>[];

    final String? fromEnv = Platform.environment['ZHUOYUE_RUNTIME_DIR'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      candidates.add(fromEnv.trim());
    }

    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    candidates.add(_join(exeDir.path, 'runtime'));
    _addAscending(exeDir, candidates);
    _addAscending(Directory.current, candidates);

    // 应用数据目录：先推导出的标准位置，再是安装时登记的确切位置。
    candidates.addAll(RuntimeInstaller.appDataRuntimeCandidates());
    candidates.addAll(_registeredRuntimeDirectories);

    return candidates;
  }

  static void _addAscending(Directory start, List<String> out) {
    Directory dir = start;
    for (int level = 0; level <= _maxAscendLevels; level++) {
      out.add(_join(dir.path, 'runtime'));
      final Directory parent = dir.parent;
      if (parent.path == dir.path) return; // 已经到盘根
      dir = parent;
    }
  }

  static String _join(String parent, String child) {
    if (parent.isEmpty) return child;
    return parent.endsWith(Platform.pathSeparator)
        ? '$parent$child'
        : '$parent${Platform.pathSeparator}$child';
  }

  /// 日志环形缓冲保留的行数。
  static const int _logLimit = 50;

  /// 从 exe 目录 / 当前目录向上回溯的最大层数。
  static const int _maxAscendLevels = 8;

  /// 等待就绪信号的最长时间。超过就杀进程并抛出带日志的异常。
  final Duration readyTimeout;

  final List<String> _logs = <String>[];

  Process? _process;
  int? _port;

  /// 正在进行的启动过程。所有并发调用共享它，保证只 spawn 一次。
  Future<int>? _starting;

  String? _runtimeDirectory;
  String? _nodeExecutable;
  String? _launcherScript;
  bool _resolved = false;

  /// 当前服务端口；尚未就绪时为 null。
  int? get port => _port;

  /// 最近的服务日志（stdout + stderr 合并，最多 [_logLimit] 行）。
  /// 设置页的"诊断"面板直接展示它。
  List<String> get recentLogs => List<String>.unmodifiable(_logs);

  /// 找到的运行时目录（含 `node/` 与 `netease-api/`）；找不到为 null。
  String? get runtimeDirectory {
    _resolveRuntime();
    return _runtimeDirectory;
  }

  /// 运行时是否齐备。UI 可以先问这个，避免为一个不存在的运行时白等 60 秒。
  bool get isAvailable {
    _resolveRuntime();
    return _launcherScript != null && _nodeExecutable != null;
  }

  /// 确保服务已启动，返回监听端口。
  ///
  /// 幂等：并发调用拿到的是同一个 Future；进程后来意外退出时会清掉缓存，
  /// 于是下一次调用会重新拉起（用户不需要重启应用）。
  Future<int> ensureStarted() {
    final int? alive = _port;
    if (alive != null && _process != null) {
      return Future<int>.value(alive);
    }

    final Future<int>? pending = _starting;
    if (pending != null) return pending;

    final Future<int> started = _start();
    _starting = started;
    // 启动失败时若没人监听，Dart 会报"未处理的异步异常"，把真正的错误淹掉。
    // 这里挂一个空的错误处理器，调用方依旧能从返回的 Future 拿到错误。
    unawaited(started.then<void>((int _) {}, onError: (Object _) {}));

    return started.whenComplete(() {
      // 无论成功还是失败都要清空：失败后必须允许重试。
      if (identical(_starting, started)) _starting = null;
    });
  }

  /// 停止服务。未启动时调用是安全的（空操作）。
  ///
  /// [waitForExit] 为 false 时**只发终止信号，不等它退出**：应用退出走的就是
  /// 这条路。node 只是无状态的 HTTP 代理，没有任何需要落盘的状态，
  /// 等它"优雅退出"没有意义，却会让点关闭之后多等几百毫秒 ——
  /// 而信号本身是同步送达操作系统内核的，不等也一样不会变成孤儿进程。
  Future<void> stop({bool waitForExit = true}) async {
    final Process? process = _process;
    _process = null;
    _port = null;
    _starting = null;
    if (process == null) return;

    if (waitForExit) {
      await _kill(process);
      return;
    }

    // 先 TERM（Windows 上就是 TerminateProcess，立即生效），
    // 再补一发 KILL 兜底，然后立刻返回。
    try {
      process.kill();
    } catch (_) {
      // 进程可能已经没了。
    }
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // 同上。
    }
  }

  // ---------------------------------------------------------------- 启动

  Future<int> _start() async {
    _resolveRuntime();
    final String? dir = _runtimeDirectory;
    final String? node = _nodeExecutable;
    final String? launcher = _launcherScript;
    if (dir == null || node == null || launcher == null) {
      throw MusicApiException(
        '$missingRuntimeHint（未找到 runtime/netease-api/launcher.js 或 node 可执行文件）',
        source: MediaSource.netease,
      );
    }

    final String apiDir = _join(dir, 'netease-api');
    _appendLog('[zhuoyue] 启动 node: $node');
    _appendLog('[zhuoyue] launcher: $launcher');

    final Process process;
    try {
      process = await Process.start(
        node,
        <String>[launcher],
        workingDirectory: apiDir,
        // 环境变量与脚本里的冒烟测试保持一致；PORT 由 launcher 自己挑。
        environment: <String, String>{
          ...Platform.environment,
          'ZHUOYUE_HOST': host,
        },
        runInShell: false,
      );
    } on ProcessException catch (error) {
      throw MusicApiException(
        '无法启动内嵌网易云服务：$error',
        source: MediaSource.netease,
        cause: error,
      );
    }

    _process = process;
    final Completer<int> ready = Completer<int>();

    // stdout 必须持续读走：管道缓冲区满了以后 node 会阻塞在 console.log 上，
    // 服务看起来"卡死"，但其实是没人收日志。
    final StreamSubscription<String> outSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          _appendLog('[out] $line');
          final RegExpMatch? match = kReadyPattern.firstMatch(line);
          final int? port = match == null
              ? null
              : int.tryParse(match.group(1)!);
          if (port != null && !ready.isCompleted) ready.complete(port);
        });

    final StreamSubscription<String> errSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) => _appendLog('[err] $line'));

    final Timer timer = Timer(readyTimeout, () {
      if (ready.isCompleted) return;
      // 超时信息里必须带日志：运行时坏掉（缺依赖、被安全软件拦截、
      // node 版本不对）时，日志是用户唯一能自查的线索。
      ready.completeError(
        MusicApiException(
          '内嵌网易云服务启动超时（${readyTimeout.inSeconds} 秒）。最近日志：\n${_recentTail()}',
          source: MediaSource.netease,
        ),
      );
    });

    unawaited(
      process.exitCode.then((int code) {
        _appendLog('[zhuoyue] node 进程退出，退出码 $code');
        if (!ready.isCompleted) {
          ready.completeError(
            MusicApiException(
              '内嵌网易云服务启动后立即退出（退出码 $code）。最近日志：\n${_recentTail()}',
              source: MediaSource.netease,
            ),
          );
        }
        if (identical(_process, process)) {
          // 进程没了就清掉缓存，下一次 ensureStarted() 会重新拉起。
          _process = null;
          _port = null;
          _starting = null;
        }
        unawaited(outSub.cancel());
        unawaited(errSub.cancel());
      }),
    );

    final int port;
    try {
      port = await ready.future;
    } catch (_) {
      // 起不来就把进程收拾干净，别留下孤儿 node。
      timer.cancel();
      await _kill(process);
      await outSub.cancel();
      await errSub.cancel();
      rethrow;
    }

    timer.cancel();
    _port = port;
    _appendLog('[zhuoyue] 服务就绪，端口 $port');
    return port;
  }

  /// 先礼后兵地结束进程：`kill()` 失败或 3 秒内没退出，才上 sigkill。
  Future<void> _kill(
    Process process, {
    Duration grace = const Duration(seconds: 3),
  }) async {
    try {
      process.kill();
    } catch (_) {
      // 进程可能已经没了，忽略。
    }
    try {
      await process.exitCode.timeout(grace);
      return;
    } on TimeoutException {
      // 还活着，强制终止。
    } catch (_) {
      return;
    }
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // 同上。
    }
  }

  // ------------------------------------------------------------ 运行时定位

  /// 按 [resolveSearchPaths] 给出的优先级找一个可用的运行时。
  ///
  /// 之所以要向上回溯：开发时 exe 在 `build/windows/x64/runner/Debug/`，
  /// 而 `runtime/` 在仓库根，两者隔着好几层；打包后 runtime 就在 exe 旁边。
  /// 两种布局都要能用，否则"开发能跑、打包不能跑"这种问题会反复出现。
  void _resolveRuntime() {
    if (_resolved) return;
    _resolved = true;

    for (final String candidate in resolveSearchPaths()) {
      if (_probe(candidate)) {
        _runtimeDirectory = candidate;
        return;
      }
    }
  }

  /// 判断 [dir] 是不是一个可用的运行时目录，是则记下 node 与 launcher 路径。
  bool _probe(String dir) {
    final File launcher = File(_join(_join(dir, 'netease-api'), 'launcher.js'));
    if (!launcher.existsSync()) return false;

    final File bundled = File(_join(_join(dir, 'node'), 'node.exe'));
    if (bundled.existsSync()) {
      _nodeExecutable = bundled.path;
      _launcherScript = launcher.path;
      return true;
    }

    // 兜底：开发机上通常已经有系统 node，没必要强制下载一份便携版。
    final String? onPath = _findOnPath('node');
    if (onPath != null) {
      _nodeExecutable = onPath;
      _launcherScript = launcher.path;
      return true;
    }

    // launcher 在但没有任何 node：算不可用，不过先记住路径便于报错。
    _launcherScript = launcher.path;
    return false;
  }

  String? _findOnPath(String executable) {
    final String? path =
        Platform.environment['PATH'] ?? Platform.environment['Path'];
    if (path == null || path.isEmpty) return null;
    for (final String entry in path.split(';')) {
      final String dir = entry.trim().replaceAll('"', '');
      if (dir.isEmpty) continue;
      for (final String name in <String>['$executable.exe', executable]) {
        final File file = File(_join(dir, name));
        if (file.existsSync()) return file.path;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ 杂项

  void _appendLog(String line) {
    _logs.add(line);
    if (_logs.length > _logLimit) {
      _logs.removeRange(0, _logs.length - _logLimit);
    }
  }

  String _recentTail([int lines = 20]) {
    if (_logs.isEmpty) return '（无日志输出）';
    final int from = _logs.length > lines ? _logs.length - lines : 0;
    return _logs.sublist(from).join('\n');
  }
}

/// 当前被 Riverpod 托管的实例。
///
/// 退出流程（`main()` 里的 window close 回调）拿不到 ProviderContainer，
/// 只能靠这个引用找到正在跑的服务进程。
EmbeddedNeteaseApi? _activeInstance;

/// 应用退出时调用：确保内嵌 node 进程不会变成孤儿进程。
///
/// 不调用也不会崩，只是会在任务管理器里留下一个 node.exe，
/// 下次启动时因为端口是随机分配的，也不会冲突 —— 但那是资源泄漏，必须收掉。
///
/// [waitForExit] 默认 false：退出流程要的是"尽快结束"，而不是"确认它结束"。
/// 需要确凿证据（例如测试要断言没有残留进程）时才传 true。
Future<void> shutdownEmbeddedNeteaseApi({bool waitForExit = false}) async {
  final EmbeddedNeteaseApi? api = _activeInstance;
  _activeInstance = null;
  if (api != null) await api.stop(waitForExit: waitForExit);
}

/// 全局唯一的内嵌服务管理器。
final Provider<EmbeddedNeteaseApi> embeddedNeteaseApiProvider =
    Provider<EmbeddedNeteaseApi>((Ref ref) {
      // 构造函数里已经把自己登记成 _activeInstance 了。
      final EmbeddedNeteaseApi api = EmbeddedNeteaseApi();
      ref.onDispose(api.stop);
      return api;
    });
