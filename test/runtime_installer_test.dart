import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/runtime/embedded_netease_api.dart';
import 'package:zhuoyue_player/core/runtime/runtime_installer.dart';

/// RuntimeInstaller 的离线测试。
///
/// 刻意**完全不碰网络**：下载服务由本机回环上的 `HttpServer` 扮演，
/// 压缩包由 [_buildZip] 现场造一个很小的 fixture。
/// 理由有二：
///   1. 121MB 的真运行时不可能是单测的输入（跑一次几分钟，还会因为
///      上游改版本而随机红）；
///   2. 校验和不匹配、404、断流、取消这些分支只能在"能摆布服务端"的
///      前提下才测得到。
///
/// 但被测代码是**真的**：真实的 SHA-256、真实的 deflate 解压、真实的
/// 文件写入与改名。只有"字节从哪来"被换掉了。
void main() {
  late Directory workspace;
  late _FakeServer server;

  setUpAll(() async {
    server = await _FakeServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('zhuoyue-runtime-test-');
    server.reset();
  });

  tearDown(() async {
    // 每个用例都从零开始：残留的运行时会让下一个用例"幂等命中"，
    // 于是它测的其实不是它自己声称的东西。
    try {
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    } on FileSystemException {
      // Windows 上偶发占用，忽略。
    }
  });

  Directory target() => Directory('${workspace.path}${Platform.pathSeparator}runtime');

  RuntimeInstaller installer({void Function(String message)? log}) =>
      RuntimeInstaller(
        targetDirectory: () async => target(),
        log: log ?? (String _) {},
      );

  /// 目标目录的父目录。暂存目录与备份目录都住在这里，
  /// 所以"有没有留下垃圾"必须在这里看。
  Directory parent() => workspace;

  List<String> namesIn(Directory directory) {
    if (!directory.existsSync()) return <String>[];
    return directory
        .listSync()
        .map((FileSystemEntity e) =>
            e.uri.pathSegments.where((String s) => s.isNotEmpty).last)
        .toList();
  }

  /// 断言"什么都没留下"：既没有半成品运行时，也没有暂存/备份残骸。
  ///
  /// 两个位置都要看：
  ///  * 目标目录里 —— 半成品会让下次启动误判为"已经装好了"；
  ///  * 父目录里 —— 一整套运行时是 100MB 级，留在用户盘上是不可接受的。
  void expectNoLeftovers() {
    final Directory dir = target();
    expect(
      namesIn(dir),
      isEmpty,
      reason: '失败/取消后目标目录不能留下任何东西，否则下次启动会误判为"已安装"',
    );
    expect(RuntimeInstaller.hasUsableRuntime(dir), isFalse);

    expect(
      namesIn(parent()).where((String name) => name.startsWith('.zhuoyue-runtime-')),
      isEmpty,
      reason: '暂存与备份都不许留：用户不该为一次失败的下载多占 100MB',
    );
    expect(
      namesIn(parent()),
      isEmpty,
      reason: '父目录里只该有最终想要的 runtime，其余一律清掉',
    );
  }

  group('正常安装', () {
    test('下载 + 解压 + 就位：文件与内容都对', () async {
      final Uint8List zip = _buildZip(_payloadFiles());
      server.respondWith(zip);
      final List<int> progress = <int>[];

      final RuntimeInstallResult result = await installer().ensureInstalled(
        archiveUrl: server.url('runtime.zip'),
        expectedSha256: sha256.convert(zip).toString(),
        onProgress: (int received, int? total) {
          progress.add(received);
          expect(total, zip.length, reason: '有 Content-Length 时总大小必须如实上报');
        },
      );

      expect(result.alreadyInstalled, isFalse);
      expect(result.receivedBytes, zip.length);
      expect(result.sha256, sha256.convert(zip).toString());
      expect(result.directory.path, target().path);
      expect(server.requestCount, 1);

      // 最关键的一条：解压后的文件内容必须逐字节正确。
      // 只看"文件存在"会把 CRC / deflate 的 bug 全部放过。
      expect(_readText(target(), 'node/node.exe'), _payloadFiles()['node/node.exe']!);
      expect(
        _readText(target(), 'netease-api/launcher.js'),
        _payloadFiles()['netease-api/launcher.js']!,
      );
      expect(_readText(target(), 'netease-api/package.json'), contains('zhuoyue'));
      expect(RuntimeInstaller.hasUsableRuntime(target()), isTrue);

      expect(progress, isNotEmpty, reason: '进度回调必须被真正调用');
      expect(progress.last, zip.length);
      expect(_isNonDecreasing(progress), isTrue, reason: '进度必须单调不减');

      // 暂存目录必须建在目标**外面**。开在目标里面会和
      // "先把目标改名腾位置、再把新目录改名成目标"的就位流程自相矛盾。
      expect(
        namesIn(parent()),
        <String>['runtime'],
        reason: '装完之后父目录里只该剩 runtime（暂存与备份都已清理）',
      );
      expect(
        namesIn(target()),
        containsAll(<String>['node', 'netease-api']),
      );
      expect(
        namesIn(target()),
        isNot(contains('.tmp')),
        reason: '暂存不能开在目标目录里面',
      );
    });

    test('下载期间目标目录还没出现：暂存不在目标里（布局不变量）', () async {
      final Uint8List zip = _buildZip(_payloadFiles());
      server.respondWith(zip);
      bool? targetExistedDuringDownload;

      await installer().ensureInstalled(
        archiveUrl: server.url('runtime.zip'),
        onProgress: (int received, int? total) {
          // 第一次进度回调时下载已经开始，此时暂存目录应当已经建好，
          // 但它不能叫 target：target 只在最后一步"改名就位"时才出现。
          targetExistedDuringDownload ??= target().existsSync();
        },
      );

      expect(
        targetExistedDuringDownload,
        isFalse,
        reason: '下载/解压期间不该已经在目标路径上留下东西 —— '
            '否则失败时用户会看到一个半成品 runtime',
      );
      expect(RuntimeInstaller.hasUsableRuntime(target()), isTrue);
    });

    test('清理残留时不会误删用户放在同一目录下的其他文件', () async {
      // 应用数据目录里通常还住着设置、缓存等等，扫残留绝不能整目录清空。
      for (final String name in <String>['settings.json', 'cache', 'database.sqlite']) {
        File('${workspace.path}${Platform.pathSeparator}$name')
            .writeAsStringSync('用户的文件');
      }
      // 伪造上一次失败留下的暂存残骸。
      Directory('${workspace.path}${Platform.pathSeparator}.zhuoyue-runtime-staging-stale')
          .createSync(recursive: true);

      server.respondWith(_buildZip(_payloadFiles()));
      await installer().ensureInstalled(archiveUrl: server.url('runtime.zip'));

      expect(
        namesIn(parent()),
        containsAll(<String>['settings.json', 'cache', 'database.sqlite', 'runtime']),
        reason: '只删自己造的 .zhuoyue-runtime-* 残骸',
      );
      expect(
        Directory('${workspace.path}${Platform.pathSeparator}.zhuoyue-runtime-staging-stale')
            .existsSync(),
        isFalse,
        reason: '上一轮留下的暂存必须被扫掉',
      );
    });

    test('单层包裹的 zip（Node 官方发行包的形态）也能装上', () async {
      final Uint8List zip = _buildZip(
        _payloadFiles(),
        prefix: 'node-v22.11.0-win-x64/',
      );
      server.respondWith(zip);

      final RuntimeInstallResult result = await installer().ensureInstalled(
        archiveUrl: server.url('node-v22.11.0-win-x64.zip'),
      );

      expect(result.alreadyInstalled, isFalse);
      // 必须把内层目录"提"出来当运行时根，而不是留下
      // runtime/node-v22.11.0-win-x64/node/… 这种多一层的路径。
      expect(RuntimeInstaller.hasUsableRuntime(target()), isTrue);
      expect(
        Directory('${target().path}${Platform.pathSeparator}node-v22.11.0-win-x64')
            .existsSync(),
        isFalse,
      );
    });

    test('deflate 压缩的包与 stored 的包解出来完全一致', () async {
      final Map<String, String> files = _payloadFiles();

      server.respondWith(_buildZip(files, compress: false));
      await installer().ensureInstalled(archiveUrl: server.url('stored.zip'));
      final String stored = _readText(target(), 'netease-api/package.json');

      await installer().uninstall();

      server.respondWith(_buildZip(files, compress: true));
      await installer().ensureInstalled(archiveUrl: server.url('deflate.zip'));
      final String deflated = _readText(target(), 'netease-api/package.json');

      expect(stored, files['netease-api/package.json']);
      expect(deflated, stored);
    });
  });

  group('幂等', () {
    test('已就位时不发起第二次下载', () async {
      final Uint8List zip = _buildZip(_payloadFiles());
      server.respondWith(zip);

      await installer().ensureInstalled(archiveUrl: server.url('runtime.zip'));
      expect(server.requestCount, 1);

      final RuntimeInstallResult second = await installer().ensureInstalled(
        archiveUrl: server.url('runtime.zip'),
      );

      expect(second.alreadyInstalled, isTrue);
      expect(
        server.requestCount,
        1,
        reason: '已经装好了还去拉 121MB，是纯粹的流量与时间浪费',
      );
    });

    test('目录残缺（只有一个文件）不算已安装，会重新下载', () async {
      // 只造 node.exe、故意不造 launcher.js。
      Directory('${target().path}${Platform.pathSeparator}node')
          .createSync(recursive: true);
      File('${target().path}${Platform.pathSeparator}node${Platform.pathSeparator}node.exe')
          .writeAsStringSync('坏了');
      expect(RuntimeInstaller.hasUsableRuntime(target()), isFalse);

      server.respondWith(_buildZip(_payloadFiles()));
      final RuntimeInstallResult result = await installer().ensureInstalled(
        archiveUrl: server.url('runtime.zip'),
      );

      expect(result.alreadyInstalled, isFalse);
      expect(server.requestCount, 1);
      expect(RuntimeInstaller.hasUsableRuntime(target()), isTrue);
      expect(
        namesIn(parent()),
        <String>['runtime'],
        reason: '换掉残缺目录之后，旧的残骸不能还在',
      );
    });

    test('目标目录已存在但不可用：被整体换掉，旧残骸不留在用户盘上', () async {
      // 造一个"看着有东西、其实不可用"的旧目录（缺 launcher.js）。
      server.respondWith(_buildZip(_payloadFiles()));
      await installer().ensureInstalled(archiveUrl: server.url('runtime.zip'));
      File('${target().path}${Platform.pathSeparator}netease-api'
              '${Platform.pathSeparator}launcher.js')
          .deleteSync();
      expect(RuntimeInstaller.hasUsableRuntime(target()), isFalse);

      // 完整的那份会在幂等检查阶段直接返回，所以走到"替换"的一定是
      // 残缺目录 —— 不存在"完整旧版本被轮换掉"的路径，也就没有
      // 需要回滚的备份。
      server.respondWith(_buildZip(_payloadFiles()));
      final RuntimeInstallResult result = await installer().ensureInstalled(
        archiveUrl: server.url('runtime.zip'),
      );

      expect(result.alreadyInstalled, isFalse);
      expect(
        _readText(target(), 'netease-api/launcher.js'),
        _payloadFiles()['netease-api/launcher.js'],
      );
      expect(
        namesIn(target()),
        isNot(contains('.tmp')),
        reason: '暂存不能开在目标里面（否则替换时目标被挪走会让暂存路径失效）',
      );
      expect(
        namesIn(parent()),
        <String>['runtime'],
        reason: '换掉旧目录之后不能留下第二份或多套一层的怪路径',
      );
    });
  });

  group('失败必须如实且不留半成品', () {
    test('SHA-256 不匹配：拒绝安装，且不留半成品', () async {
      final Uint8List zip = _buildZip(_payloadFiles());
      server.respondWith(zip);

      await expectLater(
        installer().ensureInstalled(
          archiveUrl: server.url('runtime.zip'),
          expectedSha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
        ),
        throwsA(isA<RuntimeChecksumException>()),
      );

      expectNoLeftovers();
      expect(RuntimeInstaller.hasUsableRuntime(target()), isFalse);
    });

    test('校验和与 SHASUMS256.txt 原文（hash + 文件名）等价', () async {
      final Uint8List zip = _buildZip(_payloadFiles());
      server.respondWith(zip);
      final String expected = sha256.convert(zip).toString();

      await expectLater(
        installer().ensureInstalled(
          archiveUrl: server.url('runtime.zip'),
          // 故意写错，但用官方文件的整行格式：解析对了才会走到"校验失败"，
          // 解析错了会变成 ArgumentError，一眼能区分。
          expectedSha256: '$expected  runtime.zip',
        ),
        completes,
      );
    });

    test('HTTP 404：明确失败，不留半成品', () async {
      server.respondWith(Uint8List.fromList(<int>[1, 2, 3]), statusCode: 404);

      await expectLater(
        installer().ensureInstalled(archiveUrl: server.url('runtime.zip')),
        throwsA(isA<RuntimeHttpException>()),
      );

      expectNoLeftovers();
    });

    test('HTTP 500：明确失败', () async {
      server.respondWith(Uint8List.fromList(<int>[1, 2, 3]), statusCode: 500);

      await expectLater(
        installer().ensureInstalled(archiveUrl: server.url('runtime.zip')),
        throwsA(isA<RuntimeHttpException>()),
      );

      expectNoLeftovers();
    });

    test('连不上（端口已关闭）：明确失败，不留半成品', () async {
      // 先占一个端口再放掉，保证这个端口上确实没有服务。
      final ServerSocket probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int deadPort = probe.port;
      await probe.close();

      await expectLater(
        installer().ensureInstalled(
          archiveUrl: Uri.parse('http://127.0.0.1:$deadPort/runtime.zip'),
        ),
        throwsA(isA<RuntimeNetworkException>()),
      );

      expectNoLeftovers();
    });

    test('zip 损坏（随便几个字节冒充 zip）：明确失败，不留半成品', () async {
      server.respondWith(
        Uint8List.fromList(utf8.encode('这显然不是一个 zip 文件，只是几个字节。')),
      );

      await expectLater(
        installer().ensureInstalled(archiveUrl: server.url('broken.zip')),
        throwsA(isA<RuntimeArchiveException>()),
      );

      expectNoLeftovers();
    });

    test('zip 结构看着像、内容被截断：明确失败', () async {
      final Uint8List zip = _buildZip(_payloadFiles());
      server.respondWith(
        Uint8List.sublistView(zip, 0, zip.length ~/ 2),
      );

      await expectLater(
        installer().ensureInstalled(archiveUrl: server.url('truncated.zip')),
        throwsA(isA<RuntimeFailure>()),
      );

      expectNoLeftovers();
    });

    test('zip 里没有运行时（空包）：明确失败', () async {
      server.respondWith(_buildZip(<String, String>{'readme.txt': '空的'}));

      await expectLater(
        installer().ensureInstalled(archiveUrl: server.url('empty.zip')),
        throwsA(isA<RuntimeArchiveException>()),
      );

      expectNoLeftovers();
    });
  });

  group('取消', () {
    test('下载中被取消：抛出取消结果，且不留半成品', () async {
      // 分片慢发 + 足够的填充：保证"取消"发生在**下载仍在进行**的时候，
      // 而不是恰好卡在最后一字节（那种情况测不到取消逻辑）。
      // 填充刻意只要几 KB：太大时服务器把剩余分片灌完还要跑几十秒，
      // 测试本身早结束了却在白等 —— 慢测试没人愿意跑。
      server.respondWithTrickle(
        _buildZip(_payloadFiles(), padTo: 4000),
        chunkSize: 256,
        delay: const Duration(milliseconds: 10),
      );
      final RuntimeCancelSignal signal = RuntimeCancelSignal();

      await expectLater(
        installer().ensureInstalled(
          archiveUrl: server.url('runtime.zip'),
          cancelSignal: signal,
          // 收到第一块就取消：这样连"半截文件"都一定存在过，
          // 清理逻辑必须在它存在的前提下才谈得上被验证。
          onProgress: (int received, int? total) {
            if (received > 0) signal.cancel();
          },
        ),
        throwsA(isA<RuntimeCancelled>()),
      );

      expect(signal.isCancelled, isTrue);
      expectNoLeftovers();
    });

    test('开始之前就取消：根本不会去请求服务器', () async {
      server.respondWith(_buildZip(_payloadFiles()));
      final RuntimeCancelSignal signal = RuntimeCancelSignal()..cancel();

      await expectLater(
        installer().ensureInstalled(
          archiveUrl: server.url('runtime.zip'),
          cancelSignal: signal,
        ),
        throwsA(isA<RuntimeCancelled>()),
      );

      expect(server.requestCount, 0, reason: '取消之后不该还有任何网络动作');
      expectNoLeftovers();
    });
  });

  group('进度回调', () {
    test('总大小未知时要如实报 null，而不是编一个数', () async {
      final List<int?> totals = <int?>[];
      final List<int> received = <int>[];
      server.respondWithChunked(_buildZip(_payloadFiles()));

      final RuntimeInstallResult result = await installer().ensureInstalled(
        archiveUrl: server.url('runtime.zip'),
        onProgress: (int bytes, int? total) {
          received.add(bytes);
          totals.add(total);
        },
      );

      expect(result.alreadyInstalled, isFalse);
      expect(totals, isNotEmpty);
      expect(
        totals.every((int? total) => total == null),
        isTrue,
        reason: 'chunked 响应没有 Content-Length，报 0 或猜测值都是撒谎',
      );
      expect(_isNonDecreasing(received), isTrue);
      expect(received.last, result.receivedBytes);
    });
  });

  group('NodeRuntimeSource', () {
    test('从 SHASUMS256.txt 里挑出 win-x64 并拼出下载地址', () {
      final String body = <String>[
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  node-v22.11.0-darwin-arm64.tar.gz',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  node-v22.11.0-linux-x64.tar.xz',
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  node-v22.11.0-win-x64.zip',
        'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  node-v22.11.0-win-x86.zip',
      ].join('\n');

      final NodeRuntimeSource source = NodeRuntimeSource.parse(
        body,
        baseUrl: Uri.parse('https://nodejs.org/dist/latest-v22.x/'),
      );

      expect(source.fileName, 'node-v22.11.0-win-x64.zip');
      expect(
        source.sha256,
        'c' * 64,
      );
      expect(
        source.downloadUrl.toString(),
        'https://nodejs.org/dist/latest-v22.x/node-v22.11.0-win-x64.zip',
      );
    });

    test('正文里没有 win-x64 时抛明确错误', () {
      expect(
        () => NodeRuntimeSource.parse(
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  node-v22.11.0-linux-x64.tar.xz',
          baseUrl: Uri.parse('https://nodejs.org/dist/latest-v22.x/'),
        ),
        throwsA(isA<RuntimeArchiveException>()),
      );
    });
  });

  group('运行时搜索路径', () {
    tearDown(EmbeddedNeteaseApi.resetRegisteredRuntimeDirectories);

    test('安装后登记的位置排在最后（自带运行时优先于下载的那份）', () {
      final List<String> before = EmbeddedNeteaseApi.resolveSearchPaths();
      expect(before, isNotEmpty);

      EmbeddedNeteaseApi.registerInstalledRuntimeDirectory(target());
      final List<String> after = EmbeddedNeteaseApi.resolveSearchPaths();

      expect(after.last, target().path);
      expect(
        after.sublist(0, before.length),
        before,
        reason: '登记的位置只能是兜底，不能顶掉 exe 同级/上溯找到的运行时',
      );
    });

    test('包含应用数据目录下的标准位置', () {
      final List<String> candidates = EmbeddedNeteaseApi.resolveSearchPaths();
      final String? appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return; // 非 Windows 环境跳过

      expect(
        candidates.any(
          (String path) => path.startsWith(appData) && path.endsWith('runtime'),
        ),
        isTrue,
        reason: '下载安装的运行时放在应用数据目录，搜索路径必须能覆盖到',
      );
    });

    test('缺失提示面向安装后的用户，不再指向开发脚本', () {
      final String hint = EmbeddedNeteaseApi.missingRuntimeHint;
      expect(hint, isNot(contains('fetch-runtime')));
      expect(hint, isNot(contains('scripts/')));
      expect(hint, contains('下载'));
      expect(hint, contains('runtime'));
    });

    test('同步推导的位置就是 path_provider 会给出的那个（按版本资源推导）', () {
      // 这是整个设计的接缝：安装按 `getApplicationSupportDirectory()` 落盘，
      // 读取却必须在同步代码里（UI 的 build 会问 isAvailable）。
      // 两者一旦不一致，表现是"装好了但找不到"，而且只在真机上复现。
      //
      // 测试环境里 path_provider 没有插件实现（MissingPluginException），
      // 所以这里不调用插件，而是**照 path_provider_windows 的规则重算一遍**：
      // 它取 exe 版本资源里的 CompanyName\ProductName，本仓库的
      // windows/runner/Runner.rc 里是 com.zhuoyue / zhuoyue_player。
      // 字符串刻意写死在这里，改了路径规则就必须同时改这张表。
      final String? appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return; // 非 Windows 环境跳过

      final String expected = <String>[
        appData,
        'com.zhuoyue',
        'zhuoyue_player',
        'runtime',
      ].join(Platform.pathSeparator);

      expect(
        RuntimeInstaller.appDataRuntimeCandidates(),
        contains(expected),
        reason: '同步候选必须覆盖真实的应用数据目录，否则装到哪就读不到哪',
      );
      expect(
        RuntimeInstaller.appDataRuntimeCandidates().first,
        expected,
        reason: '顺序也要一致：首选就是 getApplicationSupportDirectory 的位置',
      );
    });
  });
}

// ======================================================================
// 测试脚手架
// ======================================================================

/// 一个最小可用的运行时负载：两个必需文件 + 一个额外文件。
Map<String, String> _payloadFiles() => <String, String>{
      'node/node.exe': '这不是真的可执行文件，但只要有它就算"看起来可用"。',
      'netease-api/launcher.js': '// launcher\nconsole.log("ZHUOYUE_API_READY 1");\n',
      'netease-api/package.json': '{"name":"zhuoyue-netease-runtime"}\n',
      'netease-api/node_modules/NeteaseCloudMusicApi/package.json':
          '{"version":"4.32.0"}\n',
    };

String _readText(Directory root, String relative) {
  final String path = <String>[
    root.path,
    ...relative.split('/'),
  ].join(Platform.pathSeparator);
  return File(path).readAsStringSync();
}

bool _isNonDecreasing(List<int> values) {
  for (int i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) return false;
  }
  return true;
}

/// 回环上的假下载服务。
class _FakeServer {
  _FakeServer._(this._server);

  final HttpServer _server;

  Uint8List _body = Uint8List(0);
  int _statusCode = 200;
  bool _trickle = false;
  bool _chunked = false;
  bool _clientGone = false;
  int _chunkSize = 8;
  Duration _trickleDelay = const Duration(milliseconds: 15);

  /// 收到的请求数。幂等与"取消后不再请求"都靠它断言。
  int requestCount = 0;

  static Future<_FakeServer> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeServer fake = _FakeServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Uri url(String path) =>
      Uri.parse('http://127.0.0.1:${_server.port}/$path');

  void reset() {
    _body = Uint8List(0);
    _statusCode = 200;
    _trickle = false;
    _chunked = false;
    _clientGone = false;
    _chunkSize = 8;
    _trickleDelay = const Duration(milliseconds: 15);
    requestCount = 0;
  }

  /// 一次性返回 [body]。[statusCode] 非 200 时用来测 HTTP 失败的文案。
  void respondWith(Uint8List body, {int statusCode = 200}) {
    _body = body;
    _statusCode = statusCode;
  }

  /// 不设 Content-Length，强制 chunked 传输，用来验证"总大小未知"。
  void respondWithChunked(Uint8List body) {
    _body = body;
    _chunked = true;
  }

  /// 一小块一小块地、带间隔地发，让取消有真实的"下载中"可打断。
  void respondWithTrickle(
    Uint8List body, {
    int chunkSize = 8,
    Duration delay = const Duration(milliseconds: 15),
  }) {
    _body = body;
    _trickle = true;
    _chunkSize = chunkSize;
    _trickleDelay = delay;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    final HttpResponse response = request.response;
    response.statusCode = _statusCode;
    if (_chunked) {
      response.headers.chunkedTransferEncoding = true;
    } else {
      response.contentLength = _body.length;
    }

    if (_trickle) {
      for (int offset = 0; offset < _body.length; offset += _chunkSize) {
        // 客户端取消之后，写进已关闭的 socket 会抛异常。
        // 必须在这里立刻停手：否则服务器会继续以 15ms/8字节 的速度
        // 把整份 fixture 灌完，测试虽然早就结束了，"套件时间"却白等半分钟。
        if (_clientGone) return;
        final int end = (offset + _chunkSize).clamp(0, _body.length);
        try {
          response.add(Uint8List.sublistView(_body, offset, end));
          await response.flush();
          await Future<void>.delayed(_trickleDelay);
        } on Object {
          // 客户端取消了连接，服务器端报错是预期内的。
          _clientGone = true;
          return;
        }
      }
    } else {
      response.add(_body);
    }
    try {
      await response.close();
    } on Object {
      // 同上。
    }
  }
}

/// 造一个真的 zip（不依赖任何 zip 库，也不依赖网络）。
///
/// 只用到 stored 与 deflate 两种方式 —— 也就是 Node 官方发行包会用的那两种。
Uint8List _buildZip(
  Map<String, String> files, {
  bool compress = false,
  String prefix = '',
  int padTo = 0,
}) {
  final BytesBuilder out = BytesBuilder();
  final List<List<int>> centralRecords = <List<int>>[];

  for (final MapEntry<String, String> file in files.entries) {
    final String name = '$prefix${file.key}';
    final Uint8List nameBytes = Uint8List.fromList(utf8.encode(name));
    final Uint8List data = Uint8List.fromList(utf8.encode(file.value));
    final Uint8List stored =
        compress ? Uint8List.fromList(ZLibEncoder(raw: true).convert(data)) : data;
    final int method = compress ? 8 : 0;
    final int crc = _crc32(data);
    final int localOffset = out.length;

    out.add(_le32(0x04034b50));
    out.add(_le16(20)); // version needed
    out.add(_le16(0)); // flags
    out.add(_le16(method));
    out.add(_le16(0)); // time
    out.add(_le16(0)); // date
    out.add(_le32(crc));
    out.add(_le32(stored.length));
    out.add(_le32(data.length));
    out.add(_le16(nameBytes.length));
    out.add(_le16(0)); // extra
    out.add(nameBytes);
    out.add(stored);

    centralRecords.add(<int>[
      ..._le32(0x02014b50),
      ..._le16(20), // version made by
      ..._le16(20), // version needed
      ..._le16(0), // flags
      ..._le16(method),
      ..._le16(0), // time
      ..._le16(0), // date
      ..._le32(crc),
      ..._le32(stored.length),
      ..._le32(data.length),
      ..._le16(nameBytes.length),
      ..._le16(0), // extra
      ..._le16(0), // comment
      ..._le16(0), // disk
      ..._le16(0), // internal attrs
      ..._le32(0), // external attrs
      ..._le32(localOffset),
      ...nameBytes,
    ]);
  }

  if (padTo > out.length) {
    // 填充必须是合法且"无害"的：放进一个不会被当成目录的额外文件。
    final String pad = 'x' * (padTo - out.length);
    return _buildZip(<String, String>{...files, 'padding/blob.txt': pad},
        compress: compress, prefix: prefix);
  }

  final int centralOffset = out.length;
  for (final List<int> record in centralRecords) {
    out.add(record);
  }
  final int centralSize = out.length - centralOffset;

  out.add(_le32(0x06054b50));
  out.add(_le16(0)); // disk
  out.add(_le16(0)); // disk with central
  out.add(_le16(centralRecords.length));
  out.add(_le16(centralRecords.length));
  out.add(_le32(centralSize));
  out.add(_le32(centralOffset));
  out.add(_le16(0)); // comment length

  return out.toBytes();
}

List<int> _le16(int value) => <int>[value & 0xFF, (value >> 8) & 0xFF];

List<int> _le32(int value) => <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];

int _crc32(List<int> data) {
  const int polynomial = 0xEDB88320;
  int crc = 0xFFFFFFFF;
  for (final int byte in data) {
    crc ^= byte;
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (polynomial ^ (crc >> 1)) : (crc >> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
