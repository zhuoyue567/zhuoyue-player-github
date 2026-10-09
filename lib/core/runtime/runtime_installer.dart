import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// 安装包不再内嵌 121MB 的 Node 运行时（内嵌会让安装包体积翻好几倍，
/// 而大多数用户其实用不到内嵌服务），改成首次使用时按需下载。
///
/// 这个文件负责那一次下载的全过程：下载 zip → 校验 → 解压 → 原子就位。
/// 所有会失败的地方都显式失败：宁可用户看到一条明确的错误，
/// 也不能让一个"看起来装好了、其实跑不起来"的运行时留在盘上 ——
/// 后者会变成几年后都查不出来的诡异 bug。
///
/// 设计上刻意为可测试性让路：
///  * "字节从哪来"走注入的 [RuntimeStreamOpener]，默认是本文件的
///    [RuntimeInstaller.openHttpStream]，测试用本机回环上的 `HttpServer` 替换；
///  * 目标目录、下载地址、期望校验和全部可注入。
/// 于是 `test/runtime_installer_test.dart` 可以完全离线地跑真实代码路径
/// （真的 SHA-256、真的 deflate 解压、真的落盘与改名）。

/// 运行时目录名：`<根>/node/`（便携版 node）与 `<根>/netease-api/`（API 服务）。
const String kRuntimeDirectoryName = 'runtime';

/// 应用数据目录下的子目录名（与 `com.zhuoyue/zhuoyue_player` 对齐）。
///
/// 这里刻意同时保留"厂商名/产品名"与裸产品名两种形态：
/// `getApplicationSupportDirectory()` 在 Windows 上取的是 exe 版本资源里的
/// CompanyName\ProductName（见 path_provider_windows 的
/// `_getApplicationSpecificSubdirectory`），一旦将来版本资源改了、或者
/// 运行时是被便携版写进去的，两种路径都可能出现，多列一个总比找不到好。
const List<String> kAppDataRuntimeRelativePaths = <String>[
  r'com.zhuoyue\zhuoyue_player\runtime',
  r'zhuoyue_player\runtime',
  r'runtime',
];

/// 下载进度回调。[received] 是**已落盘的字节数**，[total] 为 null 表示
/// 对方没有给 `Content-Length`（"未知"，而不是"零"，更不是随便编一个数）。
typedef RuntimeProgressCallback = void Function(int received, int? total);

/// 打开一个可下载的字节流。抽成函数类型是为了让测试注入本机假服务，
/// 不必为可测性引入一层"下载器接口 + 假实现"的样板。
///
/// [totalBytes] 为该流的 [bytes] 总长度；未知时为 null。
typedef RuntimeStreamOpener = Future<({Stream<List<int>> bytes, int? totalBytes})>
    Function(Uri url);

/// 取消信号。下载中途被取消时**不会**悄悄返回成功，
/// 而是抛出 [RuntimeCancelled]，让调用方（以及测试）能确认"确实停了"。
class RuntimeCancelSignal {
  final Completer<void> _cancelled = Completer<void>();

  /// 是否已被取消。
  bool get isCancelled => _cancelled.isCompleted;

  /// 取消发生后完成的 Future。
  ///
  /// 用 Completer 而不是只存一个 bool：轮询 bool 会引入
  /// "最多 20ms 才反应"的延迟，也让"取消后立刻停"变成一件概率事件。
  Future<void> get whenCancelled => _cancelled.future;

  /// 请求取消。可以重复调用。
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// 下载结果：字节流 + 总长度（未知时为 null）。
class RuntimeDownload {
  RuntimeDownload({required this.bytes, required this.totalBytes});

  final Stream<List<int>> bytes;

  /// HTTP `Content-Length`；对方没给就是 null。UI 据此显示"未知大小"
  /// 或不确定进度条，而不是假装知道总量。
  final int? totalBytes;
}

/// 下载失败的基类。所有子类都带 [message]，UI 可以直接展示。
sealed class RuntimeFailure implements Exception {
  const RuntimeFailure(this.message);

  /// 面向用户的简体中文说明。
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 网络层失败：DNS、连不上、超时、响应中途断流。
class RuntimeNetworkException extends RuntimeFailure {
  const RuntimeNetworkException(super.message, {this.cause});

  /// 底层异常，便于日志里保留原始信息。
  final Object? cause;
}

/// 服务器响应了，但状态码不是 200。
class RuntimeHttpException extends RuntimeFailure {
  const RuntimeHttpException(super.message, {required this.statusCode});

  final int statusCode;
}

/// SHA-256 与期望值不符。**必须**拒绝：内容被替换/截断时，
/// 继续解压只会得到一个"半坏"的运行时。
class RuntimeChecksumException extends RuntimeFailure {
  const RuntimeChecksumException(super.message, {this.expected, this.actual});

  final String? expected;
  final String? actual;
}

/// zip 本身损坏 / 不是 zip / 用了不支持的压缩方法。
class RuntimeArchiveException extends RuntimeFailure {
  const RuntimeArchiveException(super.message);
}

/// 磁盘写入失败（空间不足、没有权限、路径被占用）。
class RuntimeFileSystemException extends RuntimeFailure {
  const RuntimeFileSystemException(super.message, {this.cause});

  final Object? cause;
}

/// 用户取消。继承 [RuntimeFailure] 是刻意的：取消也是"没装成"，
/// 调用方用同一个 catch 就能兜住，不需要记得再写一个分支。
class RuntimeCancelled extends RuntimeFailure {
  const RuntimeCancelled([super.message = '已取消下载运行时。']);
}

/// 一次安装的结果。
class RuntimeInstallResult {
  const RuntimeInstallResult({
    required this.directory,
    required this.alreadyInstalled,
    this.receivedBytes = 0,
    this.sha256,
  });

  /// 就位后的运行时根目录（内含 `node/` 与 `netease-api/`）。
  final Directory directory;

  /// true 表示盘上本来就有可用运行时，这次没有发起下载。
  final bool alreadyInstalled;

  /// 本次实际下载的字节数；[alreadyInstalled] 时为 0。
  final int receivedBytes;

  /// 本次下载内容的 SHA-256（十六进制小写）；未下载时为 null。
  final String? sha256;
}

/// `https://nodejs.org/dist/<line>/SHASUMS256.txt` 里解析出来的一个发行包。
class NodeRuntimeSource {
  const NodeRuntimeSource({
    required this.fileName,
    required this.sha256,
    required this.downloadUrl,
  });

  final String fileName;

  /// 官方公布的 SHA-256（十六进制小写）。
  final String sha256;

  final Uri downloadUrl;

  /// 从 `SHASUMS256.txt` 正文里挑出 win-x64 的 zip 行。
  ///
  /// 格式是 `<64位十六进制>  <文件名>`（有的版本还有第三个字段）。
  /// 刻意不写死版本号：Node 发新版本后旧链接会被清掉，
  /// 写死就等于给自己埋一个"过一阵子就下不动"的定时炸弹。
  static NodeRuntimeSource parse(
    String shasumsBody, {
    required Uri baseUrl,
  }) {
    for (final String rawLine in const LineSplitter().convert(shasumsBody)) {
      final List<String> parts = rawLine
          .trim()
          .split(RegExp(r'\s+'))
          .where((String part) => part.isNotEmpty)
          .toList();
      if (parts.length < 2) continue;
      final String fileName = parts[1];
      if (!fileName.endsWith('-win-x64.zip')) continue;
      final String digest = parts[0].toLowerCase();
      if (digest.length != 64) continue;
      return NodeRuntimeSource(
        fileName: fileName,
        sha256: digest,
        downloadUrl: baseUrl.resolve(fileName),
      );
    }
    throw RuntimeArchiveException(
      '在 $baseUrl 中找不到 Windows x64 的 Node 发行包（-win-x64.zip）。',
    );
  }

  @override
  String toString() => 'NodeRuntimeSource($fileName, $sha256)';
}

/// 下载 / 校验 / 解压 / 就位内嵌运行时。
///
/// 幂等：目标目录里已经有 `node/node.exe` 与 `netease-api/launcher.js`
/// 就直接返回"已就绪"，不重复下载（121MB 重下一次对用户是实打实的代价）。
class RuntimeInstaller {
  RuntimeInstaller({
    Future<Directory> Function()? targetDirectory,
    RuntimeStreamOpener? openStream,
    void Function(String message)? log,
  })  : _targetDirectoryAsync = targetDirectory ?? defaultTargetDirectory,
        _openStream = openStream ?? openHttpStream,
        _log = log ?? _defaultLog;

  /// 校验必需的相对路径：缺任何一个都算"没装好"。
  static const List<String> requiredRelativePaths = <String>[
    'node/node.exe',
    'netease-api/launcher.js',
  ];

  /// 把日志写到 stdout。安装过程可能长达几分钟，
  /// 用户看不到任何输出会以为程序卡死。
  static void _defaultLog(String message) {
    try {
      stdout.writeln('[zhuoyue/runtime] $message');
    } catch (_) {
      // 无控制台（GUI 子系统）时 stdout 不可写，忽略即可，不能让日志把安装搞挂。
    }
  }

  final Future<Directory> Function() _targetDirectoryAsync;
  final RuntimeStreamOpener _openStream;
  final void Function(String message) _log;

  /// 应用数据目录下的运行时根目录（安装目标）。**运行时位置的唯一事实来源**。
  ///
  /// 用 `getApplicationSupportDirectory()` 而不是自己拼 `%APPDATA%`：
  /// 路径规则由 path_provider 与 Windows 版本资源（CompanyName\ProductName）
  /// 共同决定，手抄一份迟早会和真正的那份对不上。
  ///
  /// 读取侧那一份同步镜像见 [appDataRuntimeCandidates]，两者由测试钉在一起。
  static Future<Directory> defaultTargetDirectory() async {
    final Directory support = await getApplicationSupportDirectory();
    return Directory(_joinPath(support.path, kRuntimeDirectoryName));
  }

  /// 同步推导的应用数据目录候选（不依赖插件通道）。
  ///
  /// 存在的理由：`EmbeddedNeteaseApi._resolveRuntime()` 是同步的
  /// （UI 的 build 里直接问 `isAvailable`），没法 await 插件。于是这里
  /// 用环境变量复现 path_provider 的规则；两者结果一致时程序才能
  /// "装到哪、就从哪读"。
  ///
  /// 单一事实来源仍然是 [defaultTargetDirectory]（它走插件、永远正确）。
  /// 这里只是它的同步镜像，`test/runtime_installer_test.dart` 里有一条
  /// 对着真实插件断言的用例把两者钉在一起 —— 一旦路径规则变了就会红。
  static List<String> appDataRuntimeCandidates() {
    final List<String> out = <String>[];
    void addAll(String? base) {
      if (base == null || base.trim().isEmpty) return;
      for (final String relative in kAppDataRuntimeRelativePaths) {
        out.add(_joinPath(base.trim(), relative));
      }
    }

    // 顺序与"安装目标"保持一致：先 Roaming（getApplicationSupportDirectory），
    // 再 Local（getApplicationCacheDirectory / 部分 Windows 配置下的回退）。
    addAll(Platform.environment['APPDATA']);
    addAll(Platform.environment['LOCALAPPDATA']);
    return out;
  }

  /// 判断 [directory] 是不是一套看起来可用的运行时。
  ///
  /// **语义边界（写下来免得被误读）**：它回答的是"要不要重新下载 100MB+"
  /// 这一个问题，做法是看两个必需文件在不在：
  ///  * 存在性检查，**不校验内容**。文件被截断、node 版本不对、
  ///    node_modules 缺依赖，这里都照样算"可用" —— 这些要靠启动时的
  ///    就绪信号（`ZHUOYUE_API_READY`）去发现，那时应用会给出带日志的报错，
  ///    而不是悄悄重下 100MB；
  ///  * 反过来，只要缺一个必需文件就判"没装好"，于是会重新下载。
  ///    这条保证了"半成品绝不冒充成品"：
  ///    中途失败/取消留下的残骸永远不会被当成装好了。
  static bool hasUsableRuntime(Object directory) {
    final String base = directory is Directory ? directory.path : '$directory';
    for (final String relative in requiredRelativePaths) {
      if (!File(_joinPath(base, relative)).existsSync()) return false;
    }
    return true;
  }

  /// 确保运行时已就位。已就位时**不会**发起任何网络请求。
  ///
  /// [expectedSha256] 给了就一定要校验：不匹配直接拒绝，绝不"先装上再说"。
  /// 它接受裸的 64 位十六进制串，也接受 `SHASUMS256.txt` 里的整行
  /// （`<hash>  <文件名>`）与 `sha256:` 前缀 —— 调用方不必自己切字符串。
  Future<RuntimeInstallResult> ensureInstalled({
    Uri? archiveUrl,
    String? expectedSha256,
    NodeRuntimeSource? source,
    RuntimeProgressCallback? onProgress,
    RuntimeCancelSignal? cancelSignal,
  }) async {
    if (archiveUrl == null && source == null) {
      throw ArgumentError(
        '必须提供 archiveUrl 或 source 之一：不知道去哪下载，就不能假装安装成功。',
      );
    }

    final Directory target = await _targetDirectoryAsync();
    if (hasUsableRuntime(target)) {
      _log('运行时已就位，跳过下载：${target.path}');
      return RuntimeInstallResult(directory: target, alreadyInstalled: true);
    }

    final String? wanted = _normalizeSha256(expectedSha256);

    // 上一次中途失败/取消留下的残骸必须先扫掉：留在那里既占空间
    // （一整套运行时 100MB 级），又会让"下一轮从干净状态开始"这个前提不成立。
    _sweepStagingLeftovers(target);
    _removeQuietly(_backupDirectory(target));

    // 暂存目录必须建在 **目标之外**（同级的兄弟目录），不能开在 target 里面。
    //
    // 理由是就位流程本身：最后一步要把解压好的目录改名成 target，
    // 而 target 已存在（残缺的那份）时必须先清掉它。如果暂存在 target 里，
    // 清掉 target 的同一次调用就把暂存本身也删了，`payload` 记下的路径
    // 当场失效 —— 报错是 "Rename failed: 系统找不到指定的文件"，
    // 而根因是布局自相矛盾。
    //
    // 放在同级还有一个好处：暂存和目标必然同卷，rename 就是纯改名，
    // 不会退化成跨卷复制（用户的应用数据目录和缓存目录很可能不在一个盘上）。
    final String jobId = _newJobId();
    final Directory staging = Directory(
      _joinPath(target.parent.path, '.zhuoyue-runtime-staging-$jobId'),
    );

    try {
      await staging.create(recursive: true);
      final File archive = File(_joinPath(staging.path, 'runtime.zip'));

      final ({int received, String sha256}) downloaded = await _downloadTo(
        url: archiveUrl ?? source!.downloadUrl,
        destination: archive,
        onProgress: onProgress,
        cancelSignal: cancelSignal,
      );

      // 校验放在解压之前：损坏/被替换的包根本不该进解压器，
      // 否则错误会以"zip 损坏"的面目出现，误导排查方向。
      if (wanted != null && downloaded.sha256 != wanted) {
        throw RuntimeChecksumException(
          '运行时压缩包校验失败（SHA-256 不符），已放弃安装。',
          expected: wanted,
          actual: downloaded.sha256,
        );
      }

      final Directory extracted = Directory(_joinPath(staging.path, 'extract'));
      await _extractArchive(archive, extracted, cancelSignal: cancelSignal);

      final Directory? payload = _resolvePayload(extracted);
      if (payload == null) {
        throw RuntimeArchiveException(
          '压缩包里没有找到可用的运行时（需要同时包含 '
          '${requiredRelativePaths.join(' 与 ')}）。',
        );
      }

      await _replaceTarget(payload: payload, target: target);
      _log('运行时安装完成：${target.path}');

      return RuntimeInstallResult(
        directory: target,
        alreadyInstalled: false,
        receivedBytes: downloaded.received,
        sha256: downloaded.sha256,
      );
    } finally {
      // 无论成功、失败还是取消，暂存目录都不留。放在 finally 里是因为
      // "失败路径也要清理"这件事最容易在改动中被漏掉。
      _removeQuietly(staging);
      // 老版本应用（曾用过备份轮换）留下的残骸也顺手清掉。
      _removeQuietly(_backupDirectory(target));
    }
  }

  /// 删除已安装的运行时（设置页的"重新下载运行时"用得上）。
  Future<void> uninstall() async {
    final Directory target = await _targetDirectoryAsync();
    _removeQuietly(target);
    _sweepStagingLeftovers(target);
    _removeQuietly(_backupDirectory(target));
  }

  // ------------------------------------------------------------- 下载

  Future<({int received, String sha256})> _downloadTo({
    required Uri url,
    required File destination,
    required RuntimeProgressCallback? onProgress,
    required RuntimeCancelSignal? cancelSignal,
  }) async {
    // 先同步地把取消状态读出来：`ensureInstalled` 是 async 的，
    // 调用方可能在它真正开始干活之前就点了取消。
    if (cancelSignal?.isCancelled ?? false) throw const RuntimeCancelled();

    final RuntimeDownload download;
    try {
      final ({Stream<List<int>> bytes, int? totalBytes}) opened =
          await _openStream(url).withCancellation(
        cancelSignal,
        '已取消下载运行时（未收到任何数据）。',
        // 打开动作通常不能中途放弃。等它最终完成并把连接放掉，
        // 用户"取消"之后才不会留下一根还在拉数据的连接。
        onLateValue: (value) => value.bytes.listen(null).cancel(),
      );
      download = RuntimeDownload(
        bytes: opened.bytes.withCancellation(cancelSignal, '已取消下载运行时。'),
        totalBytes: opened.totalBytes,
      );
    } on RuntimeFailure {
      rethrow;
    } on Error {
      // 编程错误（类型错、断言失败）不该被伪装成网络问题。
      rethrow;
    } catch (error) {
      throw RuntimeNetworkException(
        '无法连接下载服务器：$error',
        cause: error,
      );
    }

    _log(
      '开始下载 ${url.toString()}'
      '（大小 ${download.totalBytes == null ? '未知' : '${download.totalBytes} 字节'}）',
    );

    final IOSink sink = destination.openWrite();
    // 边收边算摘要：121MB 的包不适合"先落盘再整体读一遍"（多一次全量 IO，
    // 也白白多占一份内存）。
    final _DigestSink digestSink = _DigestSink();
    final ByteConversionSink hasher = sha256.startChunkedConversion(digestSink);

    int received = 0;
    int lastReportedBytes = 0;
    int? announcedTotal = download.totalBytes;

    // 进度必须单调：`await for` 的字节数天然单调，但"总大小"可能先是未知、
    // 后来才知道（比如注入的流自己发现长度），于是百分比会往回跳。
    // 这里记住上一次的量，保证给 UI 的数字不会自相矛盾。
    void report(int bytes) {
      if (bytes < lastReportedBytes) return;
      lastReportedBytes = bytes;
      onProgress?.call(bytes, announcedTotal);
    }

    try {
      await for (final List<int> chunk in download.bytes) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        report(received);
      }
      await sink.flush();
      await sink.close();
      hasher.close();
    } on RuntimeFailure {
      await _closeQuietly(sink);
      rethrow;
    } on Error {
      await _closeQuietly(sink);
      rethrow;
    } catch (error) {
      await _closeQuietly(sink);
      throw RuntimeFileSystemException(
        '写入临时文件失败：$error（请检查磁盘空间与目录权限）',
        cause: error,
      );
    }

    if (download.totalBytes != null && received != download.totalBytes) {
      // 断流时 `await for` 会正常结束而不是报错，长度对不上是唯一的线索。
      throw RuntimeNetworkException(
        '下载不完整：期望 ${download.totalBytes} 字节，实际收到 $received 字节。',
      );
    }

    final String hex = digestSink.hex;
    _log('下载完成，共 $received 字节，SHA-256=$hex');
    return (received: received, sha256: hex);
  }

  /// 打开下载流；**200 之外的响应直接当失败**。
  ///
  /// 404/500 时把响应体交给解压器，只会得到"这不是一个 zip 文件"这种
  /// 南辕北辙的报错，用户完全没法据此判断是自己的网络还是服务器的问题。
  static Future<({Stream<List<int>> bytes, int? totalBytes})> openHttpStream(
    Uri url,
  ) async {
    final HttpClient client = HttpClient()
      // `followRedirects` 保持默认的 true：国内镜像/官方站常 302 到 CDN，
      // 不跟随就等于直接失败。
      //
      // 关掉自动解压，并显式声明 `Accept-Encoding: identity`：
      // 只有"收到的字节"与 `Content-Length` 一一对应，
      // 进度数字和下载完整性校验才成立（长度对不上是我们发现断流的唯一线索）。
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final HttpClientRequest request = await client.getUrl(url);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        // 必须把响应体读掉/丢掉，否则连接不会回到连接池。
        await response.drain<void>();
        throw RuntimeHttpException(
          '下载运行时失败：服务器返回 HTTP ${response.statusCode}。',
          statusCode: response.statusCode,
        );
      }
      return (
        bytes: response,
        totalBytes: response.contentLength >= 0 ? response.contentLength : null,
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  // ------------------------------------------------------------- 解压

  Future<void> _extractArchive(
    File archive,
    Directory destination, {
    required RuntimeCancelSignal? cancelSignal,
  }) async {
    try {
      await destination.create(recursive: true);
    } on FileSystemException catch (error) {
      throw RuntimeFileSystemException(
        '无法创建解压目录 ${destination.path}：${error.message}',
        cause: error,
      );
    }

    final RandomAccessFile? handle = await _openForReadQuietly(archive);
    if (handle == null) {
      throw RuntimeArchiveException('下载的压缩包不存在或无法读取：${archive.path}');
    }

    try {
      final _ZipReader reader = await _ZipReader.open(handle);
      await reader.extractTo(
        destination,
        cancelSignal: cancelSignal,
        onEntry: (String name) => _log('解压 $name'),
      );
    } finally {
      // 必须 await（而不是 closeSync）：Windows 上同步关闭只是把删除动作
      // **排进队列**，文件句柄还会短暂存在。紧接着的目录改名会因此报
      // "Rename failed" —— 表面看是改名的问题，实际是这里没等干净。
      try {
        await handle.close();
      } catch (_) {
        // 已经关掉了，无所谓。
      }
    }
  }

  Future<RandomAccessFile?> _openForReadQuietly(File file) async {
    try {
      return await file.open();
    } on FileSystemException {
      return null;
    }
  }

  /// 判断解压结果的形态，返回"应当改名成就位目录"的那个目录。
  ///
  /// Node 官方 zip 是 `node-v22.x.x-win-x64/…` 的单层包裹，而
  /// `scripts/fetch-runtime.ps1` 打的包是直接摊平的。两种都得吃下，
  /// 否则"开发期能装、安装包不能装"会变成老大难。
  Directory? _resolvePayload(Directory extracted) {
    if (hasUsableRuntime(extracted)) return extracted;
    for (final FileSystemEntity entity in extracted.listSync()) {
      if (entity is Directory && hasUsableRuntime(entity)) return entity;
    }
    return null;
  }

  /// 把 [payload] 搬进 [target]。失败时抛出，成功时返回 null。
  ///
  /// 这里**不做"备份旧版本再轮换"**，因为走到这里时目标必定是一套残缺的
  /// 目录：真正可用的那份会在 `ensureInstalled` 开头就被幂等检查拦下、
  /// 根本不会下载。为一个到不了的分支写轮换代码，只会让人误以为
  /// "随时都有一个完整旧版本兜底"。
  ///
  /// 代价要如实写下来：删掉残缺目录到改名成功之间有一个极短的非原子窗口，
  /// 进程若正好在这里被强杀，目标路径会不存在。这不是数据损失
  /// （那份残缺目录本来就用不了），下次启动 `hasUsableRuntime` 会判为
  /// "没装好"并重新下载。
  ///
  /// 选"删掉残缺目录"而不是"整目录轮换"还有一个硬约束：Windows 的
  /// `Directory.rename` 在目标已存在时不会替换，而是把源目录移**进去**，
  /// 于是会得到 `runtime/extract/node/...` 这种多套一层的怪路径。
  Future<void> _replaceTarget({
    required Directory payload,
    required Directory target,
  }) async {
    final Directory parent = target.parent;
    try {
      await parent.create(recursive: true);
    } on FileSystemException catch (error) {
      throw RuntimeFileSystemException(
        '无法创建运行时目录 ${parent.path}：${error.message}',
        cause: error,
      );
    }

    if (target.existsSync()) {
      // 留着它会让后面的 rename 变成"移进去"，必须先清掉。
      _removeQuietly(target);
      if (target.existsSync()) {
        throw RuntimeFileSystemException(
          '无法清掉旧的运行时目录 ${target.path}'
          '（可能被其他程序占用，请关闭后重试）。',
        );
      }
    }

    // payload 与 target 是同一个父目录下的兄弟（暂存建在目标**外面**），
    // 所以这次 rename 是纯改名：同卷、不复制、内容已经全部落盘。
    // 暂存一旦开在目标里面，这一步就会报 "Rename failed: 系统找不到指定的
    // 文件" —— 因为目标被挪走时，暂存作为它的子目录也一起消失了。
    try {
      await payload.rename(target.path);
    } on FileSystemException catch (error) {
      throw RuntimeFileSystemException(
        '无法把新运行时移动到 ${target.path}：${_detail(error)}'
        '（暂存目录=${payload.path}）',
        cause: error,
      );
    }
  }

  /// 把 FileSystemException 翻成一句能被用户/日志看懂的话。
  ///
  /// Windows 的 message 常常只有一句 "Rename failed"，真正的信息在
  /// osError 里（例如"系统找不到指定的文件"/"拒绝访问"），不带上就等于没线索。
  static String _detail(FileSystemException error) {
    final String? osMessage = error.osError?.message;
    final int? code = error.osError?.errorCode;
    if (osMessage == null || osMessage.isEmpty) return error.message;
    return code == null ? osMessage : '$osMessage（错误码 $code）';
  }

  // ------------------------------------------------------------- 杂项

  /// 每次安装一个唯一名，避免同一台机器上两个安装任务互相删对方的暂存目录。
  static String _newJobId() =>
      'job-${DateTime.now().millisecondsSinceEpoch}-'
      '${Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// 备份目录的路径。
  ///
  /// 当前流程不会往里放东西（见 [_replaceTarget] 的说明），保留它只是为了
  /// **清理**老版本应用留下的残骸：`ensureInstalled` 与 `uninstall` 都会顺手
  /// 把它删掉，免得用户盘上永久躺着一份 100MB 的旧运行时。
  static Directory _backupDirectory(Directory target) =>
      Directory(_joinPath(target.parent.path, '.zhuoyue-runtime-backup'));

  /// 递归删除，失败不抛。清理是"尽力而为"：清理失败也不该把
  /// 真正的错误（网络、校验）盖掉。
  static void _removeQuietly(FileSystemEntity entity) {
    try {
      if (entity.existsSync()) entity.deleteSync(recursive: true);
    } on FileSystemException {
      // 被占用/权限不足等等，留给下一次启动再清。
    }
  }

  /// 清掉同级目录里所有 `.zhuoyue-runtime-staging-*` 残骸，只保留 [keep]。
  ///
  /// 单独一个方法是因为它需要**枚举父目录**：父目录通常还住着别的应用数据
  /// （设置文件、缓存），所以只删名字以固定前缀开头的那些，绝不整目录清空。
  static void _sweepStagingLeftovers(Directory target, {Directory? keep}) {
    final Directory parent = target.parent;
    if (!parent.existsSync()) return;
    final List<FileSystemEntity> entries;
    try {
      // 必须 toList()：`listSync()` 返回的是惰性迭代器，
      // 边遍历边删会抛"目录内容已改变"。
      entries = parent.listSync();
    } on FileSystemException {
      return;
    }
    for (final FileSystemEntity entity in entries) {
      if (entity is! Directory) continue;
      final String name = entity.uri.pathSegments
          .where((String segment) => segment.isNotEmpty)
          .last;
      if (!name.startsWith('.zhuoyue-runtime-staging-')) continue;
      if (keep != null && entity.path == keep.path) continue;
      _removeQuietly(entity);
    }
  }

  static Future<void> _closeQuietly(IOSink sink) async {
    try {
      await sink.close();
    } catch (_) {
      // 关闭失败没有补救手段，忽略。
    }
  }

  /// 规范化 SHA-256 输入，顺便校验形状。
  ///
  /// 接受三种写法：裸 hash、`sha256:<hash>`、`<hash>  <文件名>`（SHASUMS256.txt 原文）。
  /// 形状不对就抛 [ArgumentError]：把错误的值当成"没给校验和"来静默跳过校验，
  /// 是这类代码里最危险的一种"宽容"。
  static String? _normalizeSha256(String? raw) {
    if (raw == null) return null;
    String value = raw.trim();
    if (value.isEmpty) return null;
    final int spaceIndex = value.indexOf(RegExp(r'\s'));
    if (spaceIndex > 0) value = value.substring(0, spaceIndex);
    if (value.toLowerCase().startsWith('sha256:')) {
      value = value.substring('sha256:'.length);
    }
    final String lower = value.toLowerCase();
    if (lower.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(lower)) {
      throw ArgumentError(
        'SHA-256 格式不正确（应为 64 位十六进制）：$raw',
      );
    }
    return lower;
  }
}

/// `package:crypto` 的分块摘要需要一个 `Sink<Digest>`。
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  /// 摘要的十六进制小写形式；还没收到摘要时抛错（说明调用方顺序写错了）。
  String get hex {
    final Digest? digest = _digest;
    if (digest == null) throw StateError('摘要尚未计算完成');
    return digest.toString();
  }

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

/// 把取消信号接进 Future / Stream。
///
/// 关键在于**不能只是"忽略结果"**：取消必须真的把底层 HTTP 连接关掉，
/// 否则用户点了取消，后台还在以几 MB/s 拉数据。Stream 版本在收到取消时
/// 会主动 `cancel()` 订阅，`HttpClientResponse` 的订阅被取消就等于关连接。
extension _CancellableFuture<T extends Object> on Future<T> {
  /// [signal] 为 null 时原样返回（没接取消信号的调用方不受影响）。
  ///
  /// [onLateValue] 在"已经取消、但底层操作随后才成功"时被调用，
  /// 用于把那个迟到的资源释放掉。
  Future<T> withCancellation(
    RuntimeCancelSignal? signal,
    String message, {
    void Function(T value)? onLateValue,
  }) {
    if (signal == null) return this;
    if (signal.isCancelled) return Future<T>.error(RuntimeCancelled(message));

    final Completer<T> completer = Completer<T>();
    late final Future<void> aborted;
    aborted = signal.whenCancelled.then((_) {
      if (completer.isCompleted) return;
      completer.completeError(RuntimeCancelled(message));
    });

    then(
      (T value) {
        if (completer.isCompleted) {
          onLateValue?.call(value);
          return;
        }
        completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (completer.isCompleted) return;
        completer.completeError(error, stackTrace);
      },
    );
    // `aborted` 只是为了在取消时补一个错误，永远不会自己失败；
    // 但未处理的 Future 错误仍然会被打印成"未捕获异常"，所以挂个空处理器。
    unawaited(aborted.then<void>((void _) {}, onError: (Object _) {}));
    return completer.future;
  }
}

extension _CancellableStream on Stream<List<int>> {
  /// 见 [_CancellableFuture.withCancellation]。
  Stream<List<int>> withCancellation(
    RuntimeCancelSignal? signal,
    String message,
  ) {
    if (signal == null) return this;
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    StreamSubscription<List<int>>? subscription;
    bool done = false;

    void finish([Object? error, StackTrace? stackTrace]) {
      if (done) return;
      done = true;
      if (error != null) {
        controller.addError(error, stackTrace);
      }
      unawaited(controller.close());
    }

    controller.onListen = () {
      subscription = listen(
        controller.add,
        onError: (Object error, StackTrace stackTrace) =>
            finish(error, stackTrace),
        onDone: finish,
        cancelOnError: true,
      );
      // 用 whenCancelled 这个 Future 而不是轮询标志位：取消必须是
      // "立刻停"，不能变成"最多晚 20 毫秒停"。
      unawaited(
        signal.whenCancelled.then((void _) {
          if (done) return;
          // 取消订阅 = 关掉底层连接；这是"立即停止下载"的实际动作。
          unawaited(subscription?.cancel());
          finish(RuntimeCancelled(message));
        }),
      );
    };
    controller.onCancel = () => subscription?.cancel();

    return controller.stream;
  }
}

String _joinPath(String parent, String child) {
  if (parent.isEmpty) return child;
  final String separator = Platform.pathSeparator;
  return parent.endsWith(separator) || parent.endsWith('/')
      ? '$parent$child'
      : '$parent$separator$child';
}

// ======================================================================
// 纯 Dart 的 zip 读取
//
// 为什么不用 `package:archive`：它是**传递依赖**（经由 image 间接引入），
// 直接 import 会触发 depend_on_referenced_packages，而本仓库要求
// `dart analyze` 零 warning，且不允许新增依赖。核心的 deflate 解压
// `dart:io` 的 `ZLibDecoder(raw: true)` 就能做，剩下的只是读结构。
// ======================================================================

/// 一个中央目录条目。
class _ZipEntry {
  _ZipEntry({
    required this.path,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.isEncrypted,
  });

  final String path;
  final int method;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final bool isEncrypted;
}

class _ZipReader {
  _ZipReader._(this._handle, this._length);

  /// 用长度换构造：`RandomAccessFile` 没提供"已知长度"的公开构造，
  /// 而这里需要长度来算偏移，于是先量一次再建。
  static Future<_ZipReader> open(RandomAccessFile handle) async {
    final int length = await handle.length();
    return _ZipReader._(handle, length);
  }

  static const int _eocdSignature = 0x06054b50;
  static const int _centralSignature = 0x02014b50;
  static const int _localSignature = 0x04034b50;
  static const int _methodStored = 0;
  static const int _methodDeflate = 8;

  final RandomAccessFile _handle;
  final int _length;

  /// 解析并解压所有条目到 [destination]。
  Future<void> extractTo(
    Directory destination, {
    RuntimeCancelSignal? cancelSignal,
    void Function(String name)? onEntry,
  }) async {
    final List<_ZipEntry> entries = await _readCentralDirectory();
    if (entries.isEmpty) {
      throw const RuntimeArchiveException('压缩包里没有任何文件。');
    }

    for (final _ZipEntry entry in entries) {
      if (cancelSignal?.isCancelled ?? false) {
        throw const RuntimeCancelled('已取消安装运行时。');
      }
      if (entry.path.endsWith('/')) {
        await _createDirectory(_resolveInside(destination, entry.path));
        continue;
      }
      onEntry?.call(entry.path);
      await _extractEntry(entry, destination, cancelSignal: cancelSignal);
    }
  }

  Future<List<_ZipEntry>> _readCentralDirectory() async {
    final int eocdOffset = await _findEndOfCentralDirectory();
    final int totalEntries = await _readUint16(eocdOffset + 10);
    final int centralOffset = await _readUint32(eocdOffset + 16);
    if (centralOffset <= 0 || centralOffset >= _length) {
      throw const RuntimeArchiveException('压缩包目录结构损坏（中央目录偏移越界）。');
    }

    final List<_ZipEntry> entries = <_ZipEntry>[];
    int cursor = centralOffset;
    for (int index = 0; index < totalEntries; index++) {
      if (cursor + 46 > _length) {
        throw const RuntimeArchiveException('压缩包目录结构损坏（条目被截断）。');
      }
      if (await _readUint32(cursor) != _centralSignature) {
        throw const RuntimeArchiveException('压缩包目录结构损坏（中央目录签名不符）。');
      }
      final int flags = await _readUint16(cursor + 8);
      final int method = await _readUint16(cursor + 10);
      final int crc32 = await _readUint32(cursor + 16);
      final int compressedSize = await _readUint32(cursor + 20);
      final int uncompressedSize = await _readUint32(cursor + 24);
      final int nameLength = await _readUint16(cursor + 28);
      final int extraLength = await _readUint16(cursor + 30);
      final int commentLength = await _readUint16(cursor + 32);
      final int localHeaderOffset = await _readUint32(cursor + 42);

      if (compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF) {
        throw const RuntimeArchiveException(
          '压缩包使用了 ZIP64 扩展，暂不支持。',
        );
      }

      final Uint8List nameBytes = await _readBytes(cursor + 46, nameLength);
      final String name = utf8.decode(nameBytes, allowMalformed: true);
      entries.add(
        _ZipEntry(
          path: name,
          method: method,
          crc32: crc32,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localHeaderOffset: localHeaderOffset,
          isEncrypted: (flags & 0x1) != 0,
        ),
      );

      cursor += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
  }

  Future<void> _extractEntry(
    _ZipEntry entry,
    Directory destination, {
    required RuntimeCancelSignal? cancelSignal,
  }) async {
    if (entry.isEncrypted) {
      throw RuntimeArchiveException('压缩包里的 ${entry.path} 是加密的，无法解压。');
    }
    final String targetPath = _resolveInside(destination, entry.path);

    // 本地文件头里的 name/extra 长度才决定数据段起点：中央目录里的 extra
    // 字段长度与本地头里的可以不同，照抄中央目录的偏移会读出乱码。
    if (await _readUint32(entry.localHeaderOffset) != _localSignature) {
      throw RuntimeArchiveException('压缩包损坏：${entry.path} 的本地文件头无效。');
    }
    final int localNameLength = await _readUint16(entry.localHeaderOffset + 26);
    final int localExtraLength = await _readUint16(entry.localHeaderOffset + 28);
    final int dataStart =
        entry.localHeaderOffset + 30 + localNameLength + localExtraLength;

    if (dataStart + entry.compressedSize > _length) {
      throw RuntimeArchiveException(
        '压缩包被截断：${entry.path} 的数据不完整。',
      );
    }

    final Uint8List raw = await _readBytes(dataStart, entry.compressedSize);
    final Uint8List decoded;
    if (entry.method == _methodStored) {
      if (entry.compressedSize != entry.uncompressedSize) {
        throw RuntimeArchiveException('压缩包损坏：${entry.path} 的长度记录不一致。');
      }
      decoded = raw;
    } else if (entry.method == _methodDeflate) {
      try {
        decoded = Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      } catch (error) {
        throw RuntimeArchiveException(
          '压缩包损坏：无法解压 ${entry.path}（$error）。',
        );
      }
    } else {
      throw RuntimeArchiveException(
        '压缩包里的 ${entry.path} 使用了不支持的压缩方式（method=${entry.method}）。',
      );
    }

    if (decoded.length != entry.uncompressedSize) {
      throw RuntimeArchiveException(
        '压缩包损坏：${entry.path} 解压后大小不符'
        '（期望 ${entry.uncompressedSize}，实际 ${decoded.length}）。',
      );
    }
    if (cancelSignal?.isCancelled ?? false) {
      throw const RuntimeCancelled('已取消安装运行时。');
    }
    if (_crc32(decoded) != entry.crc32) {
      // CRC 是"内容完整"的最后一道闸门；跳过它等于把损坏的文件
      // 当作好文件装进用户机器。
      throw RuntimeArchiveException('压缩包损坏：${entry.path} 的 CRC32 校验失败。');
    }

    final File file = File(targetPath);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(decoded, flush: true);
    } on FileSystemException catch (error) {
      throw RuntimeFileSystemException(
        '无法写出 ${file.path}：${error.message}',
        cause: error,
      );
    }
  }

  /// 把条目名映射成解压根内的绝对路径，并挡住穿越攻击。
  ///
  /// zip 条目名是调用方提供的**不可信输入**：`../../windows/system32/x`
  /// 这样的名字必须直接拒绝，不能"规范化一下继续解压"。
  String _resolveInside(Directory destination, String entryName) {
    final String normalized = entryName.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(normalized)) {
      throw RuntimeArchiveException('压缩包包含非法路径（绝对路径）：$entryName');
    }
    final List<String> parts = <String>[];
    for (final String segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        throw RuntimeArchiveException('压缩包包含非法路径（越界）：$entryName');
      }
      parts.add(segment);
    }
    if (parts.isEmpty) {
      throw RuntimeArchiveException('压缩包包含非法路径（空）：$entryName');
    }
    String path = destination.path;
    for (final String part in parts) {
      path = _joinPath(path, part);
    }
    return path;
  }

  Future<void> _createDirectory(String path) async {
    try {
      await Directory(path).create(recursive: true);
    } on FileSystemException catch (error) {
      throw RuntimeFileSystemException(
        '无法创建目录 $path：${error.message}',
        cause: error,
      );
    }
  }

  /// 从尾部找 EOCD 记录。注释区最长 65535 字节，所以最多回看这么多。
  ///
  /// 从后往前按窗口扫：40 亿字节（zip32 上限）的文件逐字节读盘，
  /// 光找 EOCD 就是几百万次系统调用。窗口之间重叠 3 字节，
  /// 这样签名跨窗口边界也不会漏。
  ///
  /// 注意窗口的**读**范围要一直读到文件末尾：EOCD 有 22 字节，
  /// 它的签名位于 `length - 22`，只读到 `length - 1 - 22` 会把
  /// 最后一个有效位置切掉 —— 表现为"合法的 zip 也报不是 zip"。
  Future<int> _findEndOfCentralDirectory() async {
    const int minimum = 22;
    if (_length < minimum) {
      throw const RuntimeArchiveException('这不是一个 zip 文件（文件太小）。');
    }
    const int maxComment = 0xFFFF;
    final int lowestStart = _length - minimum - maxComment > 0
        ? _length - minimum - maxComment
        : 0;
    final int highestStart = _length - minimum;
    const int window = 1024;

    int scanEnd = highestStart;
    while (scanEnd >= lowestStart) {
      final int scanStart = scanEnd - window + 1 >= lowestStart
          ? scanEnd - window + 1
          : lowestStart;
      final int readEnd = scanEnd + 3 >= _length ? _length - 1 : scanEnd + 3;
      final Uint8List bytes = await _readBytes(scanStart, readEnd - scanStart + 1);
      final ByteData data = ByteData.sublistView(bytes);
      for (int i = scanEnd - scanStart; i >= 0; i--) {
        if (data.getUint32(i, Endian.little) == _eocdSignature) {
          return scanStart + i;
        }
      }
      scanEnd = scanStart - 1;
    }
    throw const RuntimeArchiveException(
      '这不是一个 zip 文件（找不到中央目录结束记录）。',
    );
  }

  Future<int> _readUint16(int offset) async {
    final Uint8List bytes = await _readBytes(offset, 2);
    return ByteData.sublistView(bytes).getUint16(0, Endian.little);
  }

  Future<int> _readUint32(int offset) async {
    final Uint8List bytes = await _readBytes(offset, 4);
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  /// 用**异步** API 读写：Windows 上同步读写的关闭动作是排队完成的，
  /// 句柄会短暂地继续占着文件，后续的目录改名会莫名其妙地失败。
  Future<Uint8List> _readBytes(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > _length) {
      throw const RuntimeArchiveException('压缩包读取越界（文件可能被截断）。');
    }
    final Uint8List buffer = Uint8List(count);
    if (count == 0) return buffer;
    await _handle.setPosition(offset);
    int read = 0;
    while (read < count) {
      final int got = await _handle.readInto(buffer, read, count);
      if (got <= 0) {
        throw const RuntimeArchiveException('压缩包读取中断（文件可能被截断）。');
      }
      read += got;
    }
    return buffer;
  }
}

/// CRC-32（IEEE 802.3，zip 用的那个），表驱动实现。
int _crc32(List<int> data) {
  final List<int> table = _crc32Table;
  int crc = 0xFFFFFFFF;
  for (int i = 0; i < data.length; i++) {
    crc = (crc >> 8) ^ table[(crc ^ data[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final List<int> _crc32Table = _buildCrc32Table();

List<int> _buildCrc32Table() {
  final List<int> table = List<int>.filled(256, 0);
  for (int i = 0; i < 256; i++) {
    int value = i;
    for (int bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1);
    }
    table[i] = value;
  }
  return table;
}
