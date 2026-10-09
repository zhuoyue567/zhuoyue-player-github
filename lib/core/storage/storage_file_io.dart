import 'dart:io';

/// 存储层用到的**全部**文件系统动作，抽成一个可替换的接缝。
///
/// 为什么需要这一层（而不是继续让 `StoragePaths` 直接调 `dart:io`）：
///
/// `testWidgets` 跑在 `fake_async` 的假时钟里，而**真实异步 I/O 的 future
/// 永远不会完成** —— 事件循环不前进，`File.exists()` / `readAsString()` 这类
/// 平台调用回来的那一刻永远不会到。于是"引导页"这种必须用 widget 测试验的
/// 界面会挂死：零输出、无失败、无汇总，**连 `--timeout` 都不触发**（假时钟
/// 不前进，超时定时器也没机会跑）。已经逐条换成同步 API 之后它依然不结束，
/// 因为剩下的 await 链（support/temp 目录、prefs、可写性探测、安装器文件读取）
/// 里总有真实 I/O 的入口。
///
/// 所以这里把"文件系统"整体换掉，而不是继续在里面找同步/异步：
///  * **全部同步** —— 同步 API 不需要事件循环，在假时钟下照样立刻完成，这正是
///    绕开那个挂起的关键；
///  * 返回类型因此都是 `bool` / `String?` / `void` / `Iterable<String>`，
///    没有一个 Future；
///  * 生产代码的默认实现就是 [SystemStorageFileIo]（薄薄一层 `dart:io`
///    包装），所以真实行为的语义没有改变；测试注入一个纯内存实现即可完全
///    不碰磁盘。
///
/// 接口只包含 `StoragePaths` **真正用到**的动作，不做通用文件系统抽象：
/// 多出来的能力只会变成"没人用的 API + 没人测的分支"。
abstract interface class StorageFileIo {
  /// 路径存在（文件或目录都算）。不存在、或访问出错都返回 false。
  bool exists(String path);

  /// 读文本文件。不存在时返回 null（**不是抛异常**：安装器配置不存在是完全
  /// 正常的一种情况，调用方不该为此写 try/catch）。
  String? readTextFile(String path);

  /// 写文本文件，[flush] 为 true 时要求落盘后再返回。
  void writeTextFile(String path, String contents, {bool flush = true});

  /// 删文件。不存在时什么都不做。
  void deleteFile(String path);

  /// 建目录（含递归）。已经存在时什么都不做。
  void createDirectory(String path);

  /// 这个目录现在能不能真的写进去。
  ///
  /// 单独一个方法（而不是让调用方自己拼临时文件）是因为**它是 `StoragePaths`
  /// 语义的一部分**：判据、探测文件的命名与清理都归这一层负责，换成内存实现
  /// 时才能整体替换掉。真实实现的判据是"真的写一个文件再删掉"，见
  /// [SystemStorageFileIo.isDirectoryWritable]。
  bool isDirectoryWritable(String path);

  /// 递归列出一个目录下的**文件**路径（不含目录本身，不看符号链接）。
  ///
  /// 目录不存在时返回空。
  Iterable<String> listFiles(String path);

  /// 文件字节数。读不到（例如遍历时被删了）返回 null。
  int? fileSize(String path);

  /// 读进程环境变量。保留 [StoragePaths] 现在"注入一个 environment 回调"
  /// 的形状：测试注入一个 Map 就能假装自己是任何一台机器。
  String? environment(String name);
}

/// 默认实现：直接转给 `dart:io`。
///
/// 刻意保持"薄"和"笨"：它不解释任何策略（不建父目录、不重试、不吞掉
/// 不该吞的异常）。策略全部留在 `StoragePaths` 里，那里才是能被测试钉住的
/// 地方。
class SystemStorageFileIo implements StorageFileIo {
  const SystemStorageFileIo();

  @override
  bool exists(String path) {
    // 目录与文件都算"存在"：调用方关心的都是"这个位置有没有东西"。
    return FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound;
  }

  @override
  String? readTextFile(String path) {
    if (!exists(path)) return null;
    return File(path).readAsStringSync();
  }

  @override
  void writeTextFile(String path, String contents, {bool flush = true}) {
    // flush: true —— 目录"可写"的探测与偏好落盘都要求"返回时真的写下去了"。
    File(path).writeAsStringSync(contents, flush: flush);
  }

  @override
  void deleteFile(String path) {
    if (!exists(path)) return;
    File(path).deleteSync();
  }

  @override
  void createDirectory(String path) {
    // recursive: true 且允许已存在：用户挑一个已经存在的目录是最常见的情况。
    Directory(path).createSync(recursive: true);
  }

  @override
  bool isDirectoryWritable(String path) {
    // 判据是**真的写一个文件再删掉**，而不是看权限位：Windows 上还有只读介质、
    // 网络盘掉线、被安全软件拦住这些权限位完全看不出来的情况，而它们的表现
    // 都是"写到一半失败"。
    final File probe = File(
      '${_trimTrailingSeparator(path)}${Platform.pathSeparator}'
      // 时间戳后缀：同一目录并发探测（不同实例 / 不同 isolate）不会互相覆盖。
      '.zhuoyue_write_test_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      probe.writeAsStringSync('ok', flush: true);
      return true;
    } on Object {
      return false;
    } finally {
      // 探测文件必须清掉：在用户的音乐目录里留下垃圾是不可接受的。
      try {
        if (probe.existsSync()) probe.deleteSync();
      } on Object catch (_) {
        // 删不掉也无所谓：它只有一个字节，而且下次探测会再写一个同前缀的文件。
      }
    }
  }

  @override
  Iterable<String> listFiles(String path) {
    if (!exists(path)) return const <String>[];
    try {
      // listSync 而不是 await for：见本文件顶部关于假时钟的说明。返回的是文件
      // 路径而不是 File 对象，这样内存实现不必伪造 dart:io 的类型。
      return Directory(path)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((File file) => file.path)
          .toList(growable: false);
    } on Object {
      // 遍历中途目录被删掉之类的情况：当成"什么都没有"，
      // 让调用方走它既有的"目录不存在"分支。
      return const <String>[];
    }
  }

  @override
  int? fileSize(String path) {
    try {
      return File(path).lengthSync();
    } on Object {
      return null;
    }
  }

  @override
  String? environment(String name) => Platform.environment[name];

  /// 去掉末尾分隔符，避免探针文件路径出现 `C:\dir\\name` 这种双分隔符。
  static String _trimTrailingSeparator(String path) {
    final String separator = Platform.pathSeparator;
    String result = path;
    while (result.length > separator.length &&
        result.endsWith(separator) &&
        // `C:\` 这种盘根不能把分隔符也剪掉，否则就变成 `C:`（当前目录）。
        !(result.length == 3 && result[1] == ':')) {
      result = result.substring(0, result.length - separator.length);
    }
    return result;
  }
}
