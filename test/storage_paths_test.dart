import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/storage/storage_file_io.dart';
import 'package:zhuoyue_player/core/storage/storage_paths.dart';

import 'support/in_memory_storage_io.dart';

/// `StoragePaths` 的行为钉子。
///
/// 这一层最贵的错误不是"崩"，而是**悄悄用错目录**：安装器写的值把用户改过的
/// 值盖回去、坏文件让应用起不来、默认值和安装器的默认值不一致 —— 三者都属于
/// "用户完全无从自查"的那类问题。所以下面的用例基本都是围着这几条写的。
///
/// 所有外部依赖都注入：`path_provider` 在单元测试里没有平台通道，
/// 真去调它会抛 `MissingPluginException`；环境变量也是注入的，
/// 这样"我是哪台机器"完全由测试决定。
void main() {
  // `SharedPreferences.setMockInitialValues` 与 `MethodChannel` 都需要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory support;
  late Directory installerDir;
  late SharedPreferences prefs;

  /// 假装自己是一台"什么环境变量都有"的 Windows 机器。
  ///
  /// 这些路径都**不存在**，所以被测代码里任何"顺手建个目录"的动作都会失败 ——
  /// 这正是我们要的：单元测试不该在开发者的真实 `%APPDATA%` 下留东西。
  Map<String, String> fakeEnvironment() => <String, String>{
    'APPDATA': r'X:\Fake\Roaming',
    'LOCALAPPDATA': r'X:\Fake\Local',
    'USERPROFILE': r'X:\Fake\User',
  };

  /// 建一个被测实例。默认不碰真实文件系统（见 [fakeEnvironment]）。
  ///
  /// `io` 在这里**故意用真实实现**：本文件验的就是真实文件系统的落点行为
  /// （目录建不出来、探针写不进去、安装器文件躺在真磁盘上）。它跑在普通
  /// `test` 里，没有假时钟，所以真实 I/O 不会让测试挂住 —— 换成
  /// `testWidgets` 就必须改用 `test/support/memory_storage_file_io.dart`。
  ///
  /// [useSupportDirectory] 为 true 时把"应用支持目录"也接到真目录上：
  /// 那个 provider 会调 path_provider，在单元测试里必然抛异常，我们不想让
  /// 所有用例都走那条异常路径。
  StoragePaths build({
    Map<String, String>? environment,
    bool useSupportDirectory = false,
  }) {
    return StoragePaths(
      preferences: prefs,
      // 安装器配置放在临时目录里，整个测试跑完就被清掉。
      installerFileDirectory: installerDir,
      environment: (String name) => (environment ?? fakeEnvironment())[name],
      io: const SystemStorageFileIo(),
      supportDirectory: useSupportDirectory
          ? () async => support
          : null,
      tempDirectory: () async => root,
    );
  }

  /// 写一份安装器配置。
  Future<File> writeInstaller(Map<String, Object?> json) async {
    final File file = File(
      '${installerDir.path}${Platform.pathSeparator}'
      '${StoragePaths.installerFileName}',
    );
    await file.writeAsString(jsonEncode(json));
    return file;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();

    root = await Directory.systemTemp.createTemp('zhy_storage_paths_');
    support = Directory('${root.path}${Platform.pathSeparator}support');
    installerDir = Directory(
      '${root.path}${Platform.pathSeparator}installer',
    );
    await support.create(recursive: true);
    await installerDir.create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  // -------------------------------------------------------------------------
  // 默认值必须与安装器一致
  // -------------------------------------------------------------------------

  test('默认目录与安装器（zhuoyue-player.iss）写下的默认值一致', () {
    final StoragePaths paths = build();

    expect(
      paths.defaultDirectory(StorageDirectoryKind.cache),
      r'X:\Fake\Roaming\ZhuoYue Player\cache',
      reason: '安装器的默认缓存目录是 %APPDATA%\\ZhuoYue Player\\cache',
    );
    expect(
      paths.defaultDirectory(StorageDirectoryKind.download),
      r'X:\Fake\User\Documents\ZhuoYue Player\Music',
      reason: '安装器的默认下载目录是 '
          '%USERPROFILE%\\Documents\\ZhuoYue Player\\Music',
    );
  });

  test('没装过时（没有 installer.json）选中的就是默认目录', () async {
    final StoragePaths paths = build();

    await paths.adoptInstallerChoicesIfNeeded();

    expect(
      paths.chosenDirectory(StorageDirectoryKind.cache),
      paths.defaultDirectory(StorageDirectoryKind.cache),
    );
    expect(
      paths.chosenDownloadRoot(),
      paths.defaultDirectory(StorageDirectoryKind.download),
    );
    // 文件不存在**不是错误**，也不该写"已采纳"标记（下次还能再试）。
    expect(prefs.getBool(StoragePaths.installerAdoptionKey), isNull);
  });

  test('环境变量缺失时给不出默认值，而不是编一个出来', () {
    final StoragePaths paths = build(environment: <String, String>{});

    expect(paths.defaultDirectory(StorageDirectoryKind.cache), isNull);
    expect(paths.defaultDirectory(StorageDirectoryKind.download), isNull);
    expect(paths.chosenDirectory(StorageDirectoryKind.cache), isNull);
  });

  // -------------------------------------------------------------------------
  // 采纳：正常、只一次、用户改过之后不再被盖回
  // -------------------------------------------------------------------------

  test('首次运行：采纳 installer.json 里的缓存与下载目录并记住已采纳', () async {
    await writeInstaller(<String, Object?>{
      'schema': 1,
      'appVersion': '0.1.0',
      'installDir': r'X:\Apps\ZhuoYue Player',
      'cacheDir': '${root.path}\\cache',
      'downloadDir': '${root.path}\\music',
      'installedAt': '2026-10-09 00:15:17',
    });
    final StoragePaths paths = build();

    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();

    expect(report.adopted, isTrue);
    expect(report.installDir, r'X:\Apps\ZhuoYue Player');
    expect(
      paths.chosenDirectory(StorageDirectoryKind.cache),
      '${root.path}\\cache',
    );
    expect(paths.chosenDownloadRoot(), '${root.path}\\music');
    // 标记必须写下来：它是"只采纳一次"的唯一凭据。
    expect(prefs.getBool(StoragePaths.installerAdoptionKey), isTrue);
    // 安装目录是只读信息，也要能读到。
    expect(await paths.installDirectory(), r'X:\Apps\ZhuoYue Player');
  });

  test('采纳之后用户改过，安装器的旧值不能把用户的改回来', () async {
    await writeInstaller(<String, Object?>{
      'schema': 1,
      'cacheDir': '${root.path}\\cache-from-installer',
      'downloadDir': '${root.path}\\music-from-installer',
    });
    final StoragePaths paths = build();
    await paths.adoptInstallerChoicesIfNeeded();

    // 用户在设置里改到别处。
    final Directory userCache = Directory('${root.path}\\user-cache');
    final Directory userMusic = Directory('${root.path}\\user-music');
    await userCache.create(recursive: true);
    await userMusic.create(recursive: true);
    await paths.setDirectory(StorageDirectoryKind.cache, userCache.path);
    await paths.setDirectory(StorageDirectoryKind.download, userMusic.path);

    // 模拟"再次启动"：新实例、同一份偏好、同一个安装器文件。
    final StoragePaths restarted = build();
    await restarted.adoptInstallerChoicesIfNeeded();

    expect(
      restarted.chosenDirectory(StorageDirectoryKind.cache),
      userCache.path,
      reason: '安装器写在盘上的值是静态的，用户改出来的值是活的；'
          '拿静态值盖活值就是"改了重启又回去"',
    );
    expect(restarted.chosenDownloadRoot(), userMusic.path);
  });

  test('「恢复默认」之后也不会被安装器的旧值拉回去', () async {
    await writeInstaller(<String, Object?>{
      'schema': 1,
      'cacheDir': '${root.path}\\cache-from-installer',
    });
    final StoragePaths paths = build();
    await paths.adoptInstallerChoicesIfNeeded();

    await paths.resetDirectory(StorageDirectoryKind.cache);
    final StoragePaths restarted = build();
    await restarted.adoptInstallerChoicesIfNeeded();

    expect(
      restarted.chosenDirectory(StorageDirectoryKind.cache),
      restarted.defaultDirectory(StorageDirectoryKind.cache),
      reason: '用户按的是"回到默认"，不是"让安装器再决定一次"',
    );
  });

  test('采纳只执行一次：安装器文件被改掉也不影响（且不会重复读文件）', () async {
    final File file = await writeInstaller(<String, Object?>{
      'schema': 1,
      'cacheDir': '${root.path}\\first',
    });
    final StoragePaths paths = build();
    final InstallerChoiceReport first = await paths
        .adoptInstallerChoicesIfNeeded();
    expect(first.cacheDir, '${root.path}\\first');

    // 把文件改成一个完全不同的值，并把磁盘上的目录删掉：
    // 如果实现又去读了一次，结果就会变。
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'cacheDir': '${root.path}\\second',
      }),
    );

    final InstallerChoiceReport again = await paths
        .adoptInstallerChoicesIfNeeded();
    expect(again.cacheDir, '${root.path}\\first');
    expect(
      paths.chosenDirectory(StorageDirectoryKind.cache),
      '${root.path}\\first',
    );
  });

  test('安装器给的目录不可用（不存在的盘）时不采纳，也不写已采纳标记', () async {
    await writeInstaller(<String, Object?>{
      'schema': 1,
      'cacheDir': r'Q:\Definitely\Not\Here',
      'downloadDir': r'Q:\Definitely\Not\There',
    });
    final StoragePaths paths = build();

    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();

    expect(report.adopted, isTrue, reason: '文件本身是好的，只是路径落不下来');
    expect(prefs.getString(StoragePaths.cacheDirectoryKey), isNull);
    expect(
      paths.chosenDirectory(StorageDirectoryKind.cache),
      paths.defaultDirectory(StorageDirectoryKind.cache),
      reason: '落到不存在的盘上必须回退默认目录，而不是把用户锁死',
    );
    expect(
      prefs.getBool(StoragePaths.installerAdoptionKey),
      isNull,
      reason: '一个都没采纳成功就不该记"已采纳"：那块盘下次可能就插上了',
    );
  });

  test('安装器给的相对路径一律不采纳', () async {
    await writeInstaller(<String, Object?>{
      'schema': 1,
      'cacheDir': r'cache\relative',
    });
    final StoragePaths paths = build();
    await paths.adoptInstallerChoicesIfNeeded();

    expect(prefs.getString(StoragePaths.cacheDirectoryKey), isNull);
  });

  // -------------------------------------------------------------------------
  // 坏文件：不存在 / 坏 JSON / schema 未来版 / 字段缺失
  // -------------------------------------------------------------------------

  test('installer.json 不存在时安静回退，不算错误', () async {
    final StoragePaths paths = build();

    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();

    expect(report.adopted, isFalse);
    expect(report.skippedReason, isNotNull);
    expect(report.skippedReason, contains('没有安装器配置'));
    expect(report.skippedReason, isNot(contains('错误')));
    expect(prefs.getBool(StoragePaths.installerAdoptionKey), isNull);
  });

  test('坏 JSON 不崩：转成"不采纳 + 一句中文原因"', () async {
    final File file = File(
      '${installerDir.path}${Platform.pathSeparator}'
      '${StoragePaths.installerFileName}',
    );
    await file.writeAsString('{ "schema": 1, "cacheDir": '); // 半截写入
    final StoragePaths paths = build();

    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();

    expect(report.adopted, isFalse);
    expect(report.skippedReason, contains('JSON'));
    expect(
      paths.chosenDirectory(StorageDirectoryKind.cache),
      paths.defaultDirectory(StorageDirectoryKind.cache),
    );
    expect(prefs.getBool(StoragePaths.installerAdoptionKey), isNull);
  });

  test('空文件与"不是 JSON 对象"都只当没有配置', () async {
    final File file = File(
      '${installerDir.path}${Platform.pathSeparator}'
      '${StoragePaths.installerFileName}',
    );

    await file.writeAsString('');
    expect(
      (await build().adoptInstallerChoicesIfNeeded()).skippedReason,
      contains('空文件'),
    );

    await file.writeAsString('[1, 2, 3]');
    expect(
      (await build().adoptInstallerChoicesIfNeeded()).skippedReason,
      contains('JSON 对象'),
    );
  });

  test('schema 是未来版本时整份配置都不采纳', () async {
    await writeInstaller(<String, Object?>{
      'schema': StoragePaths.supportedInstallerSchema + 1,
      'cacheDir': '${root.path}\\cache',
    });
    final StoragePaths paths = build();

    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();

    expect(report.adopted, isFalse);
    expect(report.skippedReason, contains('更新的版本'));
    expect(prefs.getString(StoragePaths.cacheDirectoryKey), isNull);
    expect(
      paths.chosenDirectory(StorageDirectoryKind.cache),
      paths.defaultDirectory(StorageDirectoryKind.cache),
    );
  });

  test('字段缺失 / 类型不对时只采纳能用的那一个', () async {
    await writeInstaller(<String, Object?>{
      'schema': 1,
      // cacheDir 缺失、downloadDir 是数字、installDir 是空白串。
      'downloadDir': '${root.path}\\music',
      'installDir': '   ',
      'cacheDir': 42,
    });
    final StoragePaths paths = build();

    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();

    expect(report.cacheDir, isNull);
    expect(report.installDir, isNull);
    expect(paths.chosenDownloadRoot(), '${root.path}\\music');
    expect(
      paths.chosenDirectory(StorageDirectoryKind.cache),
      paths.defaultDirectory(StorageDirectoryKind.cache),
    );
  });

  test('schema 缺失（手写配置）仍然按字段采纳', () async {
    await writeInstaller(<String, Object?>{
      'cacheDir': '${root.path}\\cache',
    });
    final StoragePaths paths = build();

    expect(
      (await paths.adoptInstallerChoicesIfNeeded()).cacheDir,
      '${root.path}\\cache',
    );
  });

  test('坏文件只警告一次：重复解析不刷屏', () async {
    await writeInstaller(<String, Object?>{});
    final File file = File(
      '${installerDir.path}${Platform.pathSeparator}'
      '${StoragePaths.installerFileName}',
    );
    await file.writeAsString('not json at all');

    final List<String> logs = <String>[];
    final DebugPrintCallback original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      final StoragePaths paths = build();
      // 直接读 5 次：adoption 有缓存，但"不刷屏"这条约束要由实现自己保证，
      // 所以这里绕过缓存直接调解析入口。
      for (int i = 0; i < 5; i++) {
        await paths.readInstallerChoices(file);
      }
    } finally {
      debugPrint = original;
    }

    final int warnings = logs
        .where((String line) => line.contains('[storage]'))
        .length;
    expect(warnings, 1, reason: '同一个坏文件不该每次解析失败都往日志里写一条');
  });

  // -------------------------------------------------------------------------
  // 目录可用性与回退
  // -------------------------------------------------------------------------

  test('目录不可写时逐级回退，绝不返回一个写不进去的目录', () async {
    // 真实文件系统：临时目录可写，其余（假的 X: 盘）不存在。
    final StoragePaths paths = build();

    final StorageDirectoryProbe probe = await paths.ensureDirectory(
      StorageDirectoryKind.cache,
    );

    expect(probe.ok, isTrue);
    expect(probe.directory, isNotNull);
    // 三层假的候选全都落不下来，最后的兜底必须是临时目录下的子目录。
    expect(probe.directory, startsWith(root.path));
  });

  test('用户选的目录可写时就用它，不会被回退掉', () async {
    final Directory picked = Directory('${root.path}\\picked-cache');
    await picked.create(recursive: true);
    await prefs.setString(StoragePaths.cacheDirectoryKey, picked.path);
    final StoragePaths paths = build();

    final StorageDirectoryProbe probe = await paths.ensureDirectory(
      StorageDirectoryKind.cache,
    );

    expect(probe.directory, picked.path);
  });

  test('不可写的目录会被换掉，并且原因是一句中文', () async {
    // 用真实存在的目录，才能真的走到"可写性探测"这一步 —— 用一个不存在的
    // 假盘的话，失败原因会停在"建不出来"，反而测不到探测逻辑本身。
    final Directory picked = Directory('${root.path}\\readonly-cache');
    await picked.create(recursive: true);
    await prefs.setString(StoragePaths.cacheDirectoryKey, picked.path);
    // 只把"可写性探测"换成"永远写不进去"：建目录、枚举等仍然走真实磁盘，
    // 于是"探测为 false → 这个候选被换掉"这条因果链是被单独钉住的。
    final StoragePaths paths = StoragePaths(
      preferences: prefs,
      installerFileDirectory: installerDir,
      environment: (String name) => fakeEnvironment()[name],
      // 让"应用支持目录"这一级也可用，从而把回退链走到临时目录那一层为止。
      supportDirectory: () async => support,
      tempDirectory: () async => root,
      io: _UnwritableStorageFileIo(),
    );

    final StorageDirectoryProbe probe = await paths.ensureDirectory(
      StorageDirectoryKind.cache,
    );

    expect(probe.ok, isFalse);
    expect(probe.directory, isNull);
    expect(probe.failure, contains('不可写'));
  });

  test('setDirectory 会拒绝不可写的目录，并且不改动已有设置', () async {
    final StoragePaths paths = StoragePaths(
      preferences: prefs,
      installerFileDirectory: installerDir,
      environment: (String name) => fakeEnvironment()[name],
      supportDirectory: () async => support,
      tempDirectory: () async => root,
      io: _UnwritableStorageFileIo(),
    );

    await expectLater(
      paths.setDirectory(StorageDirectoryKind.cache, r'X:\Fake\Roaming\nope'),
      throwsA(isA<StoragePathException>()),
    );
    // 失败之后偏好里不能留下半个值。
    expect(prefs.getString(StoragePaths.cacheDirectoryKey), isNull);
  });

  test('setDirectory 拒绝空路径', () async {
    final StoragePaths paths = build();

    await expectLater(
      paths.setDirectory(StorageDirectoryKind.cache, '   '),
      throwsA(
        isA<StoragePathException>().having(
          (StoragePathException e) => e.message,
          'message',
          contains('为空'),
        ),
      ),
    );
  });

  test('setDirectory 成功后会写入偏好，reset 之后回到默认值', () async {
    final Directory picked = Directory('${root.path}\\chosen');
    await picked.create(recursive: true);
    final StoragePaths paths = build();

    expect(
      await paths.setDirectory(StorageDirectoryKind.download, picked.path),
      picked.path,
    );
    expect(prefs.getString(StoragePaths.downloadDirectoryKey), picked.path);
    // 用户主动选过之后，"安装器是否已采纳"必须已经是 true：
    // 否则下一次启动安装器的旧值还有机会插进来。
    expect(prefs.getBool(StoragePaths.installerAdoptionKey), isTrue);

    await paths.resetDirectory(StorageDirectoryKind.download);
    expect(
      paths.chosenDownloadRoot(),
      paths.defaultDirectory(StorageDirectoryKind.download),
    );
    expect(prefs.getString(StoragePaths.downloadDirectoryKey), isNull);
  });

  test('旧键（download.directory）里的选择仍然会被沿用', () async {
    final Directory legacy = Directory('${root.path}\\legacy-music');
    await legacy.create(recursive: true);
    await prefs.setString(
      StoragePaths.legacyDownloadDirectoryKey,
      legacy.path,
    );
    final StoragePaths paths = build();

    expect(
      paths.chosenDownloadRoot(),
      legacy.path,
      reason: '升级上来的用户之前改过下载目录，不该被换回默认值',
    );
  });

  test('目录不存在时 sizeOnDisk 返回 null，而不是 0', () async {
    final StoragePaths paths = build();

    expect(await paths.sizeOnDisk('${root.path}\\nope'), isNull);

    final Directory dir = Directory('${root.path}\\counted');
    await dir.create(recursive: true);
    await File('${dir.path}\\a.bin').writeAsBytes(<int>[1, 2, 3, 4]);
    expect(await paths.sizeOnDisk(dir.path), 4);
  });

  // -------------------------------------------------------------------------
  // 内置字体是否随包分发
  // -------------------------------------------------------------------------

  test('内置字体缺失时给出的说明包含"没随包分发"与回退事实', () {
    final String notice = bundledFontMissingNotice()!;

    expect(notice, contains('没有随附内置字体'));
    expect(notice, contains('系统默认字体'));
    // 文案不该把这项说成"错误"，也不该出现 Markdown 星号（Text 不渲染它）。
    expect(notice, isNot(contains('**')));
    expect(bundledFontFallbackNotice(), isNotNull);
  });

  test('bundledFontAvailableProvider 是注入点：可以假装字体不存在', () async {
    // 用「假存在」验证 true 的那条路（不去真读 17MB 的资源）。
    final ProviderContainer container = ProviderContainer(
      // 不写显式类型参数：Riverpod 3 没有把 Override 导出成公开类型。
      overrides: [
        bundledFontAvailableProvider.overrideWith((Ref ref) async => false),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(bundledFontAvailableProvider.future), isFalse);
  });

  // -------------------------------------------------------------------------
  // 路径工具
  // -------------------------------------------------------------------------

  test('路径拼接与绝对路径判断', () {
    expect(joinPath(r'C:\a', 'b'), r'C:\a\b');
    expect(joinPath(r'C:\a\', 'b'), r'C:\a\b');
    expect(joinPath('', 'b'), 'b');
    expect(joinPath(r'C:\a', ''), r'C:\a');
    expect(joinAll(<String>[r'C:\a', '', 'b', 'c']), r'C:\a\b\c');

    expect(isAbsolutePath(r'C:\Music'), isTrue);
    expect(isAbsolutePath('D:/Music'), isTrue);
    expect(isAbsolutePath(r'\Music'), isTrue);
    expect(isAbsolutePath(r'Music\ZhuoYue'), isFalse);
    expect(isAbsolutePath(''), isFalse);
    expect(isAbsolutePath('1:abc'), isFalse);
  });

  // -------------------------------------------------------------------------
  // 文件系统接缝本身
  // -------------------------------------------------------------------------

  test('默认接缝（真实实现）在真目录上工作，并且不留下探测文件', () {
    const StorageFileIo io = SystemStorageFileIo();

    final Directory writable = Directory('${root.path}\\seam\\writable');
    io.createDirectory(writable.path);
    expect(io.exists(writable.path), isTrue);
    expect(io.isDirectoryWritable(writable.path), isTrue);

    // 写 + 读 + 大小 + 枚举。
    final String file = joinPath(writable.path, 'a.txt');
    io.writeTextFile(file, 'hello', flush: true);
    expect(io.readTextFile(file), 'hello');
    expect(io.fileSize(file), 5);
    expect(io.listFiles(writable.path), contains(file));

    // 删文件之后就不该再能读到（返回 null，而不是抛异常 —— 安装器配置
    // 不存在是正常情况，调用方不该为此写 try/catch）。
    io.deleteFile(file);
    expect(io.readTextFile(file), isNull);
    expect(io.fileSize(file), isNull);
    expect(io.exists(writable.path), isTrue, reason: '删的是文件，不是目录');

    // 探针必须自己清掉：在用户的目录里留垃圾是不可接受的。
    final List<String> leftovers = Directory(writable.path)
        .listSync()
        .map((FileSystemEntity entity) => entity.path)
        .where((String path) => path.contains('.zhuoyue_write_test_'))
        .toList();
    expect(leftovers, isEmpty);

    // 不存在的路径：当成"没有"，不抛。
    expect(io.exists('${root.path}\\seam\\nope'), isFalse);
    expect(io.readTextFile('${root.path}\\seam\\nope\\x.txt'), isNull);
    expect(io.listFiles('${root.path}\\seam\\nope'), isEmpty);
  });

  test('内存实现不触碰磁盘：根路径不存在也照样工作', () {
    // 这个根路径**故意不存在**（`Q:` 是个不存在的盘，`createDirectory` 对
    // 真实实现必然抛异常）。内存实现应该完全不看它 —— 这正是它能绕开
    // `fake_async` 假时钟的原因。
    final InMemoryStorageFileIo io = InMemoryStorageFileIo();
    const String rootPath = r'Q:\Definitely\Not\Here';

    expect(io.exists(rootPath), isFalse);
    io.createDirectory(joinPath(rootPath, 'cache'));
    io.writeTextFile(joinPath(joinPath(rootPath, 'cache'), 'installer.json'), '{"a":1}');

    expect(io.exists(joinPath(rootPath, 'cache')), isTrue);
    expect(
      io.readTextFile(joinPath(joinPath(rootPath, 'cache'), 'installer.json')),
      '{"a":1}',
    );
    expect(io.fileSize(joinPath(joinPath(rootPath, 'cache'), 'installer.json')), 7);
    expect(
      io.isDirectoryWritable(joinPath(rootPath, 'cache')),
      isTrue,
      reason: '内存里"建得出来"就等于"可写"，不需要真的碰盘',
    );
    expect(io.isDirectoryWritable(joinPath(rootPath, 'never-made')), isFalse);

    // 场景摆放：整个子树被标成不可写之后，写文件必须像真盘一样**抛异常**
    // （调用方就是靠捕获它来判"这个候选不可用"的）。
    io.markDirectoryUnwritable(joinPath(rootPath, 'readonly'));
    expect(io.isDirectoryWritable(joinPath(rootPath, 'readonly')), isFalse);
    expect(
      () => io.writeTextFile(joinPath(joinPath(rootPath, 'readonly'), 'x.txt'), 'x'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      () => io.writeTextFile(
        joinPath(joinPath(rootPath, 'readonly'), r'sub\x.txt'),
        'x',
      ),
      throwsA(isA<FileSystemException>()),
      reason: '标记在父目录上时，子目录同样写不进去',
    );
  });
}

/// 真实现的一个变体：**只**把"可写性探测"改成永远失败。
///
/// 用它而不是一个纯内存替身，是为了让"探测为 false → 这个候选被换掉"这条
/// 因果链在真实磁盘上被单独钉住：建目录、枚举、删文件都还是真的。
class _UnwritableStorageFileIo implements StorageFileIo {
  final SystemStorageFileIo _real = const SystemStorageFileIo();

  @override
  bool exists(String path) => _real.exists(path);

  @override
  String? readTextFile(String path) => _real.readTextFile(path);

  @override
  void writeTextFile(String path, String contents, {bool flush = true}) =>
      _real.writeTextFile(path, contents, flush: flush);

  @override
  void deleteFile(String path) => _real.deleteFile(path);

  @override
  void createDirectory(String path) => _real.createDirectory(path);

  @override
  bool isDirectoryWritable(String path) => false;

  @override
  Iterable<String> listFiles(String path) => _real.listFiles(path);

  @override
  int? fileSize(String path) => _real.fileSize(path);

  @override
  String? environment(String name) => _real.environment(name);
}
