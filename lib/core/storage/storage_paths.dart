import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_file_io.dart';

// ---------------------------------------------------------------------------
// 这一层要解决的两个问题
//
// 1. **安装时选的路径和应用里的设置必须是同一份数据**。安装器把用户的选择写进
//    `installer.json`，应用如果各存一份（甚至根本不读），用户就会发现"我在安装
//    向导里选的目录不见了"，或者更糟：在设置里改完，重启又被安装器的旧值盖回去。
//    所以这里规定：安装器的值只在**第一次运行**被采纳一次，采纳后写成标记；
//    用户改过之后，`installer.json` 就再也不参与任何决策。
//
// 2. **三个目录（安装 / 缓存 / 下载）必须能在同一个地方被回答**。以前下载目录的
//    默认值算在 `DownloadManager` 里、缓存目录算在 `cover_cache.dart` 里，
//    设置页想知道"文件到底写在哪"只能各问一处。默认值还与安装器的默认值不一致，
//    于是"没装过（开发期直接跑 exe）"和"装过"两条路会给出两个不同的目录 ——
//    这正是要在这里收敛掉的东西。
// ---------------------------------------------------------------------------

/// 应用管理的目录种类。
enum StorageDirectoryKind {
  /// 缓存目录：封面磁盘缓存等可以随时重新生成的文件的根目录。
  ///
  /// 注意它**只写缓存**，`tasks.json` 这类"读不出来就丢状态"的存档不在这里
  /// （见本文件末尾的说明）。
  cache(
    id: 'cache',
    label: '缓存目录',
    preferenceKey: StoragePaths.cacheDirectoryKey,
    legacyPreferenceKey: null,
  ),

  /// 下载目录：下载回来的音频文件的根目录。
  download(
    id: 'download',
    label: '下载目录',
    preferenceKey: StoragePaths.downloadDirectoryKey,
    // 旧版本只认这个键。保留它当别名，是为了让"先前的版本里改过下载目录"的
    // 用户升级之后仍停在自己选的目录上，而不是被我们换回默认值。
    legacyPreferenceKey: StoragePaths.legacyDownloadDirectoryKey,
  );

  const StorageDirectoryKind({
    required this.id,
    required this.label,
    required this.preferenceKey,
    required this.legacyPreferenceKey,
  });

  final String id;
  final String label;

  /// 当前使用的偏好键。
  final String preferenceKey;

  /// 旧版本使用的偏好键（没有则为 null）。
  final String? legacyPreferenceKey;
}

/// 目录不可用 / 不能写时的失败原因。
///
/// 存在的意义和 `DownloadException` 一样：给用户一句**中文的、能照着做点什么**
/// 的话，而不是把 `FileSystemException` 的英文原样透出去。
class StoragePathException implements Exception {
  const StoragePathException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次安装器配置的读取结果。
///
/// 把"为什么没采纳"也带出来，是为了能把它显示给用户（而不是自己心里知道）。
/// 注意：**文件不存在不是错误** —— 开发期直接跑 exe 就是这样，没有任何问题。
@immutable
class InstallerChoiceReport {
  const InstallerChoiceReport({
    this.cacheDir,
    this.downloadDir,
    this.installDir,
    this.appVersion,
    this.skippedReason,
  });

  /// 安装器写下的缓存目录（没有则为 null）。
  final String? cacheDir;

  /// 安装器写下的下载目录（没有则为 null）。
  final String? downloadDir;

  /// 安装器写下的安装目录（只读信息，应用不拿它做任何决策）。
  final String? installDir;

  /// 安装器写下的应用版本，只用于排查。
  final String? appVersion;

  /// 没有采纳时的原因（中文，可直接显示给用户）。
  final String? skippedReason;

  /// 是否真的采纳到了至少一个目录。
  bool get adopted => cacheDir != null || downloadDir != null;
}

/// 一次"这个目录能不能用"的检查结果。
///
/// 成功与失败放在同一个对象里，而不是用"返回 null 表示失败 + 另找一个地方拿
/// 原因"：失败时**必须**能给出一个中文原因，否则界面只能显示一个干巴巴的
/// "不可用"，用户完全不知道该去做什么。
@immutable
class StorageDirectoryProbe {
  const StorageDirectoryProbe._({this.directory, this.failure});

  /// 可以用的目录（成功时非 null）。
  final String? directory;

  /// 不可用时的中文原因（成功时为 null）。
  final String? failure;

  bool get ok => directory != null;

  @override
  String toString() =>
      ok ? 'StorageDirectoryProbe($directory)' : 'StorageDirectoryProbe(失败: $failure)';
}

/// 默认的环境变量读取：真实进程环境。
String? _platformEnvironment(String name) => Platform.environment[name];
/// 应用三个目录的唯一权威来源。
///
/// **同步的部分**（构造函数、`chosenDirectory` / `chosenDownloadRoot` /
/// `defaultDirectory`）刻意不碰 IO：`DownloadManager` 必须在构造函数里同步拿到
/// 一个目录，否则界面第一帧只会显示"正在准备…"。默认值全部由环境变量拼出来，
/// 这正是"同步也拿得到"的原因。
///
/// **异步的部分**（`ensureDirectory` / `adoptInstallerChoicesIfNeeded`）才做
/// 文件 IO：建目录、探测可写、读 `installer.json`。
///
/// 所有外部依赖（support 目录、环境变量、**文件系统**、安装器文件内容）都能
/// 注入，这样这一层可以在测试里完整跑一遍 —— `path_provider` 在单元测试里没有
/// 平台通道，不注入的话这一层就永远测不了。
/// 说明：这个类内部的磁盘操作**全部走 [StorageFileIo]**（默认是真实实现）。
///
/// 两个理由，一个是可测性、一个是正确性：
///  1. `testWidgets` 跑在 `fake_async` 的假时钟里，**真实异步 I/O 的 future
///     永远不会完成** —— 于是挂起（表现为零输出卡死，连 `--timeout` 都不触发，
///     因为假时钟不前进、超时定时器也没机会跑）。所以接缝上的动作**全是同步的**
///     （`bool` / `String?` / `void` / `Iterable<String>`），同步 API 不需要
///     事件循环，在假时钟下照样立刻完成；把它整体换成内存实现之后，widget
///     测试里一次真实磁盘调用都不会发生。
///  2. 这些都是"读一个小 JSON / 探一次目录能不能写"的微型动作，同步做完
///     反而让启动路径更确定（第一帧就能给出目录状态）。
///
/// 公开方法仍然返回 Future —— 调用方不需要知道里面是同步的，将来真要换成
/// 异步实现也不会破坏接口。
class StoragePaths {
  StoragePaths({
    SharedPreferences? preferences,
    Future<Directory> Function()? supportDirectory,
    String? Function(String name)? environment,
    this.installerFileDirectory,
    Future<Directory> Function()? tempDirectory,
    StorageFileIo? io,
  }) : _preferences = preferences, // ignore: prefer_initializing_formals
       _supportDirectoryProvider =
           supportDirectory ?? getApplicationSupportDirectory,
       // 默认读真实环境变量。测试注入一个 Map 就能假装自己是任何一台机器
       // （包括"USERPROFILE 根本没设"这种精简环境）。
       _environment = environment ?? _platformEnvironment,
       _tempDirectoryProvider =
           tempDirectory ?? Directory.systemTemp.createTemp,
       // **默认值就是真实实现**：生产代码与既有调用点一行都不用改，
       // 只有测试会显式换掉它（见 storage_file_io.dart 顶部的说明）。
       _fs = io ?? const SystemStorageFileIo();

  // ------------------------------------------------------------ 偏好键与常量

  /// 缓存目录在 SharedPreferences 里的键。
  ///
  /// 值刻意不放在 `theme.*` 命名空间下：它和主题无关，混进去只会让
  /// "重置主题设置"顺手把用户的目录选择也清掉。
  static const String cacheDirectoryKey = 'storage.cacheDirectory';

  /// 下载目录在 SharedPreferences 里的键。
  static const String downloadDirectoryKey = 'storage.downloadDirectory';

  /// 旧版本使用的下载目录键。
  ///
  /// 改名的理由：老键名 `download.directory` 是 `DownloadManager` 的内部实现
  /// 细节，不该被别的层直接依赖。改名时保留读取，见
  /// [StorageDirectoryKind.legacyPreferenceKey]。
  static const String legacyDownloadDirectoryKey = 'download.directory';

  /// 「安装器的选择已经被采纳过」的标记键。
  ///
  /// **这个键是"采纳只能发生一次"的唯一凭据**，它一旦写下，`installer.json`
  /// 就彻底退出决策链。所以它必须在**成功采纳之后**才写，且**永远不清除**
  /// （包括「恢复默认」：用户主动回到默认值，也不该被安装器的旧值再拉回去）。
  static const String installerAdoptionKey = 'storage.installerAdopted';

  /// 应用支持目录下安装器配置的文件名。
  static const String installerFileName = 'installer.json';

  /// 当前能理解的 `installer.json` schema 版本。
  static const int supportedInstallerSchema = 1;

  /// 安装器的默认目录名（与 `packaging/zhuoyue-player.iss` 保持一致）。
  static const String appFolderName = 'ZhuoYue Player';

  /// 缓存目录相对安装器默认值的那一段：`%APPDATA%\ZhuoYue Player\cache`。
  static const String defaultCacheFolder = 'cache';

  /// 下载目录相对安装器默认值的那几段：
  /// `%USERPROFILE%\Documents\ZhuoYue Player\Music`。
  static const List<String> defaultDownloadSegments = <String>[
    'Documents',
    'ZhuoYue Player',
    'Music',
  ];

  /// 安装目录相对默认值的那一段：`{autopf}\ZhuoYue Player`。
  static const List<String> defaultInstallSegments = <String>[
    'Programs',
    'ZhuoYue Player',
  ];

  /// 安装器文件里 `schema` 字段名。
  static const String _schemaField = 'schema';

  /// 安装器配置文件所在的目录（测试注入；null 表示走应用支持目录）。
  final Directory? installerFileDirectory;

  final Future<Directory> Function() _supportDirectoryProvider;
  final String? Function(String name) _environment;
  final Future<Directory> Function() _tempDirectoryProvider;

  /// 所有磁盘动作都走这个接缝。生产是 [SystemStorageFileIo]，测试是内存实现。
  final StorageFileIo _fs;

  /// 全局实例。`main.dart` 不需要做任何装配：这里自己取
  /// `SharedPreferences.getInstance()`（它本来就有内存缓存，第二次拿到的是
  /// 同一个实例），安装器配置则等到第一次真的解析目录时才读一次。
  static final StoragePaths instance = StoragePaths();

  SharedPreferences? _preferences;
  Directory? _supportDirectoryCache;
  Directory? _tempDirectoryCache;

  /// 只做一次：读安装器配置并采纳。后续所有调用共用同一个 Future。
  Future<InstallerChoiceReport>? _adoption;

  /// 只警告一次：同一个坏文件不该每次解析失败都往日志里刷一条。
  bool _installerParseWarned = false;

  // ------------------------------------------------------------ 三个目录

  /// 安装目录（**只读信息**）。
  ///
  /// 应用运行期不拿它做任何决策：真正的安装位置由"当前 exe 在哪"决定，
  /// 这里显示的是安装器当初写下的值（没有安装器配置时为 null）。
  Future<String?> installDirectory() async {
    final InstallerChoiceReport report = await adoptInstallerChoicesIfNeeded();
    if (report.installDir != null && report.installDir!.trim().isNotEmpty) {
      return report.installDir;
    }
    // 安装器没有留下记录时，至少给出与安装器一致的默认位置。
    final String? localAppData = _environment('LOCALAPPDATA');
    if (localAppData == null || localAppData.trim().isEmpty) return null;
    return joinPath(localAppData, joinAll(defaultInstallSegments));
  }

  /// 某个目录的**默认值**。
  ///
  /// **纯计算，不碰 IO**：这样"第一帧要显示的路径"和"最终真正用的路径"是同一
  /// 条公式算出来的，不会出现"先显示一个、写盘时换成另一个"。
  ///
  /// 两个默认值与 `packaging/zhuoyue-player.iss` 里安装器的默认值**逐字一致**
  /// （见 `packaging/README.md` 的表），否则"装过"和"没装过"两条路会给用户
  /// 两个不同的目录 —— 而用户完全无从判断哪个才是"对的"。
  String? defaultDirectory(StorageDirectoryKind kind) {
    switch (kind) {
      case StorageDirectoryKind.cache:
        // %APPDATA%\ZhuoYue Player\cache
        final String? appData = _environment('APPDATA');
        if (appData == null || appData.trim().isEmpty) return null;
        return joinPath(
          joinPath(appData, appFolderName),
          defaultCacheFolder,
        );
      case StorageDirectoryKind.download:
        // %USERPROFILE%\Documents\ZhuoYue Player\Music
        final String? profile = _environment('USERPROFILE');
        if (profile == null || profile.trim().isEmpty) return null;
        return joinPath(profile, joinAll(defaultDownloadSegments));
    }
  }

  /// 用户当前**选中**的目录：自己选的优先，否则默认值（顺序即优先级）。
  ///
  /// 同步返回，只读偏好与内存。可能不存在、也可能不可写 —— 那是
  /// [ensureDirectory] 的活，不在这一步判（判了就要碰 IO，也就没法同步了）。
  String? chosenDirectory(StorageDirectoryKind kind) {
    final String? custom = _readDirectoryPreference(kind);
    if (custom != null && custom.trim().isNotEmpty) return custom;
    return defaultDirectory(kind);
  }

  /// 下载根目录的同步取值（给必须在构造函数里拿到目录的 `DownloadManager` 用）。
  ///
  /// 它**不探测可写性**：探测是 IO。真正写任务目录之前会走一次
  /// [ensureDirectory]，那里才会把"盘不存在 / 没权限"的情况兜住并回退。
  String? chosenDownloadRoot() => chosenDirectory(StorageDirectoryKind.download);

  /// 解析出**可以真正写**的目录，顺带该建就建。
  ///
  /// 回退链：用户选的 → 该目录的默认值 → 应用支持目录 → 临时目录。
  /// 每一级都要过 [isDirectoryWritable]，所以"盘符不存在 / 只读介质 /
  /// 权限不足"都会在这里被换掉，而不是等到下载到一半、缓存写盘时才炸。
  Future<StorageDirectoryProbe> ensureDirectory(
    StorageDirectoryKind kind,
  ) async {
    final Directory support = await _supportDirectory();
    final List<String> candidates = <String>[
      ..._candidateChain(kind, support),
    ];

    String? lastFailure;
    for (final String candidate in candidates) {
      final String failure = await _prepareCandidate(candidate);
      if (failure.isEmpty) {
        return StorageDirectoryProbe._(directory: candidate);
      }
      lastFailure = failure;
    }

    // 全都不行：临时目录是最后的兜底。它随系统清理，但"能用"永远好过"炸掉"。
    final Directory temp = await _tempDirectory();
    final String tail = kind == StorageDirectoryKind.cache
        ? defaultCacheFolder
        : joinAll(defaultDownloadSegments);
    final String fallback = joinPath(temp.path, tail);
    final String fallbackFailure = await _prepareCandidate(fallback);
    if (fallbackFailure.isEmpty) {
      return StorageDirectoryProbe._(directory: fallback);
    }

    // 连临时目录都写不了：如实说出最后遇到的那个问题，不假装成功。
    return StorageDirectoryProbe._(failure: lastFailure ?? fallbackFailure);
  }

  /// 候选目录链（去掉重复项，保持优先级顺序）。
  List<String> _candidateChain(StorageDirectoryKind kind, Directory support) {
    final List<String> chain = <String>[];
    void add(String? path) {
      if (path == null) return;
      final String trimmed = path.trim();
      if (trimmed.isEmpty) return;
      if (chain.contains(trimmed)) return;
      chain.add(trimmed);
    }

    add(_readDirectoryPreference(kind));
    add(defaultDirectory(kind));
    // 应用支持目录：`installer.json` 与 `shared_preferences` 就在这儿，
    // 它的存在性最不需要怀疑。
    add(joinPath(support.path, kind.id));
    return chain;
  }

  /// 准备一个候选目录。
  ///
  /// 返回**空串表示这个候选可用**，否则返回不可用的中文原因。
  ///
  /// 两个动作都走 [StorageFileIo]（同步）：见 storage_file_io.dart 顶部
  /// 关于假时钟的说明 —— 这一层过去就是"测试里跑不完"的最后一段 await 链。
  Future<String> _prepareCandidate(String path) async {
    try {
      if (!_fs.exists(path)) {
        _fs.createDirectory(path);
      }
      if (!_fs.isDirectoryWritable(path)) {
        return '「$path」不可写';
      }
      return '';
    } on Object catch (error) {
      return '「$path」不可用（$error）';
    }
  }

  // ------------------------------------------------------------ 目录的写入

  /// 用户在设置里挑了一个新目录。
  ///
  /// 只做"检查 + 记住"两件事：**不搬文件**。见 [changeEffectNotice]。
  /// 目录还不存在时会先建出来（用户挑一个空的 U 盘目录是最正常不过的操作），
  /// 建不出来或不可写就抛 [StoragePathException]，由调用方原样显示给用户。
  Future<String> setDirectory(
    StorageDirectoryKind kind,
    String path,
  ) async {
    final String trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw const StoragePathException('目录路径为空，没有做任何改动');
    }

    final String failure = await _prepareCandidate(trimmed);
    if (failure.isNotEmpty) {
      throw StoragePathException('$failure，没有保存这个目录');
    }

    final SharedPreferences? prefs = await _prefs();
    if (prefs == null) {
      throw const StoragePathException('设置存储不可用，无法保存目录');
    }

    await prefs.setString(kind.preferenceKey, trimmed);
    // 写入的同时就把安装器的选择标记上：用户的主动选择必须能压住安装器的旧值，
    // 哪怕这台机器上 adoption 因为某些原因还没跑过。
    await prefs.setBool(installerAdoptionKey, true);
    return trimmed;
  }

  /// 把某个目录恢复成默认值。
  ///
  /// **不动「已采纳」标记**：用户按的是"这个目录回默认"，不是"让安装器重新
  /// 决定一次"。后者会让"恢复默认"变成"回到安装时那个目录"，与字面意思不符，
  /// 而且用户永远猜不到。
  Future<String?> resetDirectory(StorageDirectoryKind kind) async {
    final SharedPreferences? prefs = await _prefs();
    if (prefs != null) {
      await prefs.remove(kind.preferenceKey);
      final String? legacy = kind.legacyPreferenceKey;
      if (legacy != null) await prefs.remove(legacy);
    }
    return defaultDirectory(kind);
  }

  /// 改目录**真正的代价**，直接作为设置页的文案来源。
  ///
  /// 说实话比说得漂亮重要：这里刻意**没有**实现"自动搬运"，
  /// 所以只能如实告诉用户旧文件还在原地。
  static String changeEffectNotice(StorageDirectoryKind kind) {
    switch (kind) {
      case StorageDirectoryKind.cache:
        return '新目录立刻生效（之后下载的封面写进新目录），'
            '但已经缓存在旧目录里的封面不会被搬走，也不会被删掉 —— '
            '需要自己清理，或者直接留在那里（它只占空间，不影响使用）。';
      case StorageDirectoryKind.download:
        return '对之后新增的下载立刻生效。已经下载好的文件仍留在原目录，'
            '下载记录里指向旧路径的条目也不会自动改写。';
    }
  }

  // ------------------------------------------------------------ 安装器配置

  /// 采纳 `installer.json` 里的路径选择。**整个生命周期里只会真正执行一次。**
  ///
  /// 为什么必须"只一次"：安装器写下的值在磁盘上是**静态**的，而用户在设置里
  /// 改出来的值是**活的**。如果每次启动都拿静态值去覆盖活值，用户就会看到
  /// "我明明改了，重启又回去了" —— 这是这类功能最不能接受的失败方式。
  /// 所以采纳成功后立刻写下 [installerAdoptionKey]，此后这个文件就不再被读。
  ///
  /// 不采纳（文件不存在 / 坏 JSON / schema 未来版 / 字段缺失 / 盘不存在）时
  /// **不写标记**：那台机器下次启动还可以再试一次（例如用户后来把盘插上了）。
  Future<InstallerChoiceReport> adoptInstallerChoicesIfNeeded() {
    return _adoption ??= _adopt();
  }

  Future<InstallerChoiceReport> _adopt() async {
    final SharedPreferences? prefs = await _prefs();
    if (prefs == null) {
      // 设置存储不可用时唯一安全的做法是"什么都不采纳"：
      // 没有地方记标记，采纳了就会变成每次启动都盖一次。
      return const InstallerChoiceReport(
        skippedReason: '设置存储不可用，未读取安装器配置',
      );
    }

    // 已经采纳过：这是唯一一个让安装器文件彻底退出决策链的分支。
    if (prefs.getBool(installerAdoptionKey) ?? false) {
      return const InstallerChoiceReport(
        skippedReason: '安装时选择的路径已经采纳过，不再重复读取',
      );
    }

    final File file = await installerFile();
    final InstallerChoiceReport report = await readInstallerChoices(file);

    if (!report.adopted) {
      // 没有任何可采纳的值：不写标记（下次还能再试），并把原因交给界面。
      return report;
    }

    final bool wrote = await _adoptValue(
      prefs: prefs,
      kind: StorageDirectoryKind.cache,
      path: report.cacheDir,
    );
    final bool wroteDownload = await _adoptValue(
      prefs: prefs,
      kind: StorageDirectoryKind.download,
      path: report.downloadDir,
    );

    if (wrote || wroteDownload) {
      await prefs.setBool(installerAdoptionKey, true);
      debugPrint(
        '[storage] 已采纳安装器选择的路径：'
        '缓存=${report.cacheDir ?? '（未提供）'}，'
        '下载=${report.downloadDir ?? '（未提供）'}',
      );
    }
    return report;
  }

  /// 写入一个被采纳的路径。返回是否真的写成功了。
  ///
  /// 不可用的路径**直接跳过**（留 null，界面上就是"用默认值"）：
  /// 安装器允许用户填一个还没插上的移动硬盘，应用不能因为那个盘不在就
  /// 把用户锁死在一个不可写的目录上。
  Future<bool> _adoptValue({
    required SharedPreferences prefs,
    required StorageDirectoryKind kind,
    required String? path,
  }) async {
    if (path == null || path.trim().isEmpty) return false;
    final String trimmed = path.trim();
    if (!isAbsolutePath(trimmed)) {
      debugPrint('[storage] 忽略安装器给的相对路径：$trimmed');
      return false;
    }

    final String failure = await _prepareCandidate(trimmed);
    if (failure.isNotEmpty) {
      debugPrint('[storage] 忽略安装器给的不可用路径：$failure');
      return false;
    }

    await prefs.setString(kind.preferenceKey, trimmed);
    // 旧键一并写上：让回退到旧版本运行时也停在这个目录上。
    final String? legacy = kind.legacyPreferenceKey;
    if (legacy != null) await prefs.setString(legacy, trimmed);
    return true;
  }

  /// 安装器配置文件：`<应用支持目录>/installer.json`。
  Future<File> installerFile() async {
    final Directory? injected = installerFileDirectory;
    if (injected != null) {
      return File(joinPath(injected.path, installerFileName));
    }
    final Directory support = await _supportDirectory();
    return File(joinPath(support.path, installerFileName));
  }

  /// 把安装器配置解析成路径选择。
  ///
  /// **这个方法不允许抛异常**：它面对的是一份应用管不着、可能被外部工具改过、
  /// 也可能来自未来版本的文件。所有异常一律转成"不采纳 + 一句中文原因"。
  ///
  /// 抽成公开的顶层可测方法，是因为这一层值得被单独钉住：一条坏数据不该让
  /// 应用起不来，也不该让用户的目录设置被半个值覆盖。
  ///
  /// 读文件走 [StorageFileIo]，所以测试换掉文件系统之后这里的"配置内容"完全
  /// 由测试摆放（见 storage_file_io.dart 顶部说明）。
  Future<InstallerChoiceReport> readInstallerChoices(File file) async {
    final String path = file.path;
    try {
      final String? text = _fs.readTextFile(path);
      if (text == null) {
        // 开发期直接跑 exe 就是这样：没有安装器、也就没有安装器配置。
        // **这不是错误**，界面文案里也不该把它说成错误。
        return const InstallerChoiceReport(
          skippedReason: '没有安装器配置（开发运行或非安装方式运行），沿用默认目录',
        );
      }

      if (text.trim().isEmpty) {
        _warnOnce('[storage] 安装器配置是空文件，沿用默认目录：$path');
        return const InstallerChoiceReport(
          skippedReason: '安装器配置为空文件，沿用默认目录',
        );
      }

      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) {
        _warnOnce('[storage] 安装器配置不是 JSON 对象，沿用默认目录：$path');
        return const InstallerChoiceReport(
          skippedReason: '安装器配置格式不对（不是 JSON 对象），沿用默认目录',
        );
      }

      final Map<String, Object?> map = <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in decoded.entries)
          '${entry.key}': entry.value,
      };

      final Object? rawSchema = map[_schemaField];
      // schema 缺失未必是坏文件（手写的配置、早期安装器），但**高于我们认识的
      // 版本一定是**：字段语义可能已经变了，照旧去读只会读到错误的值。
      if (rawSchema is int && rawSchema > supportedInstallerSchema) {
        _warnOnce(
          '[storage] 安装器配置 schema=$rawSchema 高于本版本支持的 '
          '$supportedInstallerSchema，不采纳：$path',
        );
        return InstallerChoiceReport(
          skippedReason:
              '安装器配置来自更新的版本（schema $rawSchema），'
              '当前版本只认到 $supportedInstallerSchema，沿用默认目录',
        );
      }

      final InstallerChoiceReport report = InstallerChoiceReport(
        cacheDir: _usableString(map['cacheDir']),
        downloadDir: _usableString(map['downloadDir']),
        installDir: _usableString(map['installDir']),
        appVersion: _usableString(map['appVersion']),
      );

      if (!report.adopted) {
        return const InstallerChoiceReport(
          skippedReason: '安装器配置里没有可用的缓存 / 下载目录，沿用默认目录',
        );
      }
      return report;
    } on FormatException catch (error) {
      // 坏 JSON：最常见的一种，单独给一句更好懂的话。
      _warnOnce('[storage] 安装器配置不是合法 JSON，沿用默认目录：'
          '$path -> ${error.message}');
      return const InstallerChoiceReport(
        skippedReason: '安装器配置不是合法 JSON，沿用默认目录',
      );
    } on Object catch (error) {
      _warnOnce('[storage] 读取安装器配置失败，沿用默认目录：$path -> $error');
      return const InstallerChoiceReport(
        skippedReason: '读取安装器配置失败，沿用默认目录',
      );
    }
  }

  /// 同一个坏文件只警告一次：读取失败会被界面反复触发，刷屏的日志等于没有日志。
  void _warnOnce(String message) {
    if (_installerParseWarned) return;
    _installerParseWarned = true;
    debugPrint(message);
  }

  // ------------------------------------------------------------ 可写性检查

  /// 目录当前占用字节数（给设置页显示"这个目录现在有多少东西"用）。
  ///
  /// 目录不存在时返回 null，而不是 0：**"没有这个目录"和"这个目录是空的"
  /// 是两件不同的事**，用户需要能区分。
  ///
  /// 遍历有 [maxFiles] 上限：用户完全可能把缓存目录指到一个巨大的目录上，
  /// 而设置页只是想知道"有多大"，不该为此把界面卡住几十秒。到上限就返回已经
  /// 数到的值 —— 那是个下限而不是精确值，但总比一直转圈好。
  Future<int?> sizeOnDisk(String path, {int maxFiles = 20000}) async {
    try {
      if (!_fs.exists(path)) return null;
      int total = 0;
      int seen = 0;
      // 走接缝的同步枚举：不经过事件循环，假时钟下也一样能跑完
      // （见 storage_file_io.dart 顶部说明）。
      for (final String file in _fs.listFiles(path)) {
        seen++;
        if (seen > maxFiles) {
          debugPrint('[storage] 目录条目超过 $maxFiles 个，大小统计提前结束：$path');
          break;
        }
        // 遍历过程中文件被删掉了：跳过即可，不该让统计整个失败。
        total += _fs.fileSize(file) ?? 0;
      }
      return total;
    } on Object catch (error) {
      debugPrint('[storage] 统计目录大小失败（$path）：$error');
      return null;
    }
  }

  // ------------------------------------------------------------ 内部工具

  String? _readDirectoryPreference(StorageDirectoryKind kind) {
    final SharedPreferences? prefs = _preferences;
    if (prefs == null) return null;
    final String? current = prefs.getString(kind.preferenceKey);
    if (current != null && current.trim().isNotEmpty) return current;
    final String? legacy = kind.legacyPreferenceKey;
    if (legacy == null) return null;
    final String? old = prefs.getString(legacy);
    return (old != null && old.trim().isNotEmpty) ? old : null;
  }

  /// 惰性拿 `SharedPreferences`。
  ///
  /// 刻意返回 null 而不是抛异常：这一层会在很多"只是想读一下设置"的路径上被
  /// 调用（例如设置页首帧），在那里抛异常只会变成一个没人接的异步错误。
  /// 真的拿不到时，所有调用方都有一个安全的退化行为（用默认目录 / 不采纳）。
  Future<SharedPreferences?> _prefs() async {
    final SharedPreferences? ready = _preferences;
    if (ready != null) return ready;
    try {
      return _preferences = await SharedPreferences.getInstance();
    } on Object catch (error) {
      debugPrint('[storage] 读取设置存储失败：$error');
      return null;
    }
  }

  Future<Directory> _supportDirectory() async {
    final Directory? ready = _supportDirectoryCache;
    if (ready != null) return ready;
    try {
      return _supportDirectoryCache = await _supportDirectoryProvider();
    } on Object catch (error) {
      debugPrint('[storage] 应用支持目录不可用（$error），改用环境变量 / 临时目录');
    }
    final String? appData = _environment('APPDATA');
    if (appData != null && appData.trim().isNotEmpty) {
      return _supportDirectoryCache = Directory(joinPath(appData, appFolderName));
    }
    return _supportDirectoryCache = Directory.systemTemp;
  }

  Future<Directory> _tempDirectory() async {
    final Directory? ready = _tempDirectoryCache;
    if (ready != null) return ready;
    try {
      return _tempDirectoryCache = await _tempDirectoryProvider();
    } on Object catch (error) {
      debugPrint('[storage] 临时目录不可用（$error），改用系统临时目录');
      return _tempDirectoryCache = Directory.systemTemp;
    }
  }
}

// ---------------------------------------------------------------------------
// Riverpod 装配
// ---------------------------------------------------------------------------

/// 全局 [StoragePaths]。默认实例自己会去读偏好与安装器配置，`main.dart` 不用管。
final Provider<StoragePaths> storagePathsProvider = Provider<StoragePaths>(
  (Ref ref) => StoragePaths.instance,
);

/// 缓存目录：**真正可以写**的那一个，`covers/` 之类的子目录挂在它下面。
///
/// 为什么必须是异步的：解析目录要读偏好、还要探测可写性（真写一个文件再删），
/// 这两件事都没有同步的 API。切到新目录之后的整个会话里它只算一次，
/// 所以界面不会每次重建都去做一次磁盘探测。
///
/// `keepAlive` 是必须的：这个 Future 的结果会被封面缓存长期持有，
/// 页面切走时不该让它被回收，否则回来时又白探一次盘。
final FutureProvider<String> cacheRootProvider = FutureProvider<String>((
  Ref ref,
) async {
  final StoragePaths paths = ref.watch(storagePathsProvider);
  // 先确保安装器写的路径已经被采纳过：否则"首次运行"这一次解析会用默认目录，
  // 把安装器选的位置整场会话都错过（采纳只发生一次，错过就真的错过了）。
  await paths.adoptInstallerChoicesIfNeeded();
  final StorageDirectoryProbe probe = await paths.ensureDirectory(
    StorageDirectoryKind.cache,
  );
  return probe.directory ?? Directory.systemTemp.path;
}, isAutoDispose: false);

/// 封面磁盘缓存真正在用的目录：`<缓存目录>/covers`。
///
/// 单独给一个 provider，是为了让界面能显示"缓存到底写在哪"，而不是只显示一个
/// 用户选的根目录 —— 两者不一致时（例如根目录被回退过）用户看到的信息才是真的。
final FutureProvider<String> coverCacheDirectoryProvider =
    FutureProvider<String>((Ref ref) async {
      final String root = await ref.watch(cacheRootProvider.future);
      return joinPath(root, 'covers');
    }, isAutoDispose: false);

// ---------------------------------------------------------------------------
// 内置字体是否存在
//
// 安装包**不含** `assets/fonts/zhuzi.ttf`（再分发许可未经核实，见
// `packaging/README.md`）。字体不存在时 Flutter 不会崩，只会静默回退到系统
// 字体 —— 于是一个不存在的字体会变成一个"选了没效果"的选项，而且用户完全
// 不知道发生了什么。所以这个存在性判断必须能被界面问到。
//
// 做成 provider 而不是一个静态布尔量，是为了让测试能注入"字体不存在"这个
// 事实，而不必真的去读一个 17MB 的文件（那会让每个测试都慢一个数量级）。
// ---------------------------------------------------------------------------

/// 内置字体在 bundle 里的资源路径。
const String kBundledFontAsset = 'assets/fonts/zhuzi.ttf';

/// 检查内置字体是否真的随当前安装包分发。
///
/// `rootBundle.load` 在资源不存在时**抛异常**（而不是返回空），这就是判据。
/// 资源读取失败只可能是"没打进去"，没有任何其它含义。
///
/// 用 `FutureProvider` 而不是 `Provider<Future<bool>>`：界面要的是"还在查 /
/// 有结果"这个三态（查的时候不能先把选项禁掉），`FutureProvider` 的
/// `AsyncValue` 正好表达它，而且结果会自动缓存，不会每次重建都读一遍资源。
final FutureProvider<bool> bundledFontAvailableProvider =
    FutureProvider<bool>((Ref ref) async {
      try {
        await rootBundle.load(kBundledFontAsset);
        return true;
      } on Object catch (error) {
        debugPrint('[font] 内置字体不可用（$kBundledFontAsset 未随包分发）：$error');
        return false;
      }
    });

/// 内置字体缺失时给用户的那一句话（字体存在时为 null）。
///
/// 提成顶层函数是为了能在测试里直接钉住这句文案 —— 它承担的是"解释为什么
/// 选了没效果"的全部责任，改坏了应该让测试红。
String? bundledFontMissingNotice() {
  return '本安装包没有随附内置字体 zhuzi.ttf —— 它的再分发许可未经核实，'
      '打包时被移除了，所以「竹石（内置）」在当前安装里用不了：'
      '界面已经回退到系统默认字体。想用竹石，请在源码仓库里运行，'
      '或者用「自定义字体」导入本机的 ttf。';
}

/// 字体是否缺失时的另一个说法：只在"用户仍然选了竹石"时才需要的补充。
String? bundledFontFallbackNotice() {
  return '你之前选的是「竹石（内置）」，但当前安装包里没有这个字体，'
      '所以现在实际显示的是系统默认字体。';
}

// ---------------------------------------------------------------------------
// 目录工具（下载页与设置页共用同一套实现）
// ---------------------------------------------------------------------------

/// 在资源管理器中打开一个目录，不存在就先建出来。
///
/// `explorer` 是 Windows 上唯一不需要额外依赖的方式。用它而不是 ShellExecute，
/// 是因为它足够"笨"：失败时能拿到退出码，也不会因为我们传错参数而静默什么都
/// 不做。
///
/// 失败时抛 [StoragePathException]（中文），调用方可以直接把 `'$error'` 显示出去。
Future<void> openDirectoryInExplorer(String path) async {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) {
    throw const StoragePathException('目录路径为空，无法打开');
  }
  try {
    Directory(trimmed).createSync(recursive: true);
    await Process.run('explorer', <String>[trimmed]);
  } on Object catch (error) {
    debugPrint('[storage] 打开目录失败（$trimmed）：$error');
    throw StoragePathException('无法打开目录：$trimmed');
  }
}

/// 在资源管理器里定位到某个文件（选中它）。
Future<void> revealPathInExplorer(String path) async {
  try {
    // `/select,` 与路径必须是**同一个参数**：分成两个参数时 explorer 会把
    // 路径当成"要打开的文件夹"，结果是打开目录而不是选中文件。
    await Process.run('explorer', <String>['/select,$path']);
  } on Object catch (error) {
    debugPrint('[storage] 定位文件失败（$path）：$error');
    throw StoragePathException('无法打开文件所在位置：$path');
  }
}

/// 目录是不是真的能写。
///
/// 判据是**真的写一个文件再删掉**，而不是看权限位：Windows 上还有只读介质、
/// 网络盘掉线、以及被安全软件拦住这些权限位完全看不出来的情况，而它们的表现
/// 都是"写到一半失败"。宁可在这里多花一次 IO，也不要让用户在下载到 90% 时
/// 才看到错误。
///
/// 保留这个顶层函数是为了 `DownloadManager` 这类**拿到 `Directory` 就想探一下**
/// 的调用点；`StoragePaths` 内部走 [StorageFileIo.isDirectoryWritable]，
/// 这样同一个动作在测试里能被整体换成内存实现。
Future<bool> isDirectoryWritable(Directory directory) async {
  return const SystemStorageFileIo().isDirectoryWritable(directory.path);
}

/// 拼路径。
///
/// 刻意不 import `package:path`：它不是本项目的直接依赖
/// （`depend_on_referenced_packages` 会报出来），而这里只需要两次字符串拼接。
String joinPath(String parent, String child) {
  if (parent.isEmpty) return child;
  if (child.isEmpty) return parent;
  return parent.endsWith(Platform.pathSeparator)
      ? '$parent$child'
      : '$parent${Platform.pathSeparator}$child';
}

/// 依次拼接多段路径，空段自动跳过。
String joinAll(List<String> segments) {
  String result = '';
  for (final String segment in segments) {
    if (segment.trim().isEmpty) continue;
    result = joinPath(result, segment);
  }
  return result;
}

/// 是不是一个绝对的本地路径。
///
/// 判据取"盘符 + 冒号"或"以分隔符开头"：安装器写的是 Windows 路径，
/// 而相对路径（或空串）写进设置只会让所有后续 IO 都落到当前工作目录上 ——
/// 那是个用户永远找不到的地方。
bool isAbsolutePath(String path) {
  if (path.isEmpty) return false;
  if (path.startsWith(Platform.pathSeparator)) return true;
  // `C:\...` / `D:/...`：盘符必须是字母，且紧跟冒号。
  return path.length >= 2 &&
      path[1] == ':' &&
      RegExp(r'^[A-Za-z]$').hasMatch(path[0]);
}

/// JSON 字段的容错读取：不是字符串、或者全是空白，都当成"没有这个值"。
String? _usableString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
