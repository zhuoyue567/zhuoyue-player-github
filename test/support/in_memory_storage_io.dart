import 'dart:collection';
import 'dart:io';

import 'package:zhuoyue_player/core/storage/storage_file_io.dart';

/// 纯内存的文件系统替身，**专供 widget 测试**。
///
/// 为什么必须有它：`testWidgets` 跑在 `fake_async` 的假时钟里，**真实文件
/// I/O 的 future 永远不会完成** —— 测试会挂死，而且连 `--timeout` 都不触发
/// （假时钟不前进，超时定时器也没机会跑）。这个替身不做任何磁盘访问，
/// 方法全部同步返回，所以在假时钟下照样立刻完成。
///
/// 它同时让用例可以**摆场景**：
///  * "这个文件不存在" → 不往 [files] 里放那个键（[readTextFile] 返回 null）；
///  * "这个目录不可写" → [markDirectoryUnwritable]（只读介质 / 权限不足）；
///  * "安装器配置的内容是什么" → 直接放那个键的 JSON。
///
/// 刻意**不**模拟真实盘的其它行为（大小写不敏感、盘符存不存在、权限位）：
/// 那些由 `storage_paths_test.dart` 用真实目录去验，这里只要能"表达场景"。
class InMemoryStorageFileIo implements StorageFileIo {
  InMemoryStorageFileIo({
    this.writable = true,
    Map<String, String>? files,
    Map<String, String>? environment,
  }) : _files = <String, String>{...?files},
       _environment = <String, String>{...?environment};

  /// 默认情况下 [isDirectoryWritable] 的回答。false 用来演"整台设备只读"。
  final bool writable;

  final Map<String, String> _files;
  final Map<String, String> _environment;
  final Set<String> _directories = <String>{};

  /// 被单独标成不可写的目录：**整棵子树**都写不进去（真实世界就是这样，
  /// 父目录没权限的话子目录也建不出来）。
  final Set<String> _readonlyDirectories = <String>{};

  /// 设备上的内容快照，便于断言"到底写进去了什么"。
  Map<String, String> get files =>
      UnmodifiableMapView<String, String>(_files);

  Set<String> get directories => UnmodifiableSetView<String>(_directories);

  // --------------------------------------------------------------- 场景摆放

  /// 放一份文件（父目录自动算作存在）。
  void placeFile(String path, String contents) => _files[path] = contents;

  /// 建一个空目录。
  void placeDirectory(String path) => _directories.add(path);

  /// 把这个目录标成"写不进去"，并让它的整棵子树也写不进去。
  void markDirectoryUnwritable(String path) {
    _readonlyDirectories.add(_normalize(path));
    _directories.add(path);
  }

  // --------------------------------------------------------- StorageFileIo

  @override
  bool exists(String path) =>
      _files.containsKey(path) || _directories.contains(path);

  @override
  String? readTextFile(String path) => _files[path];

  @override
  void writeTextFile(String path, String contents, {bool flush = true}) {
    final String? blocked = _readonlyAncestor(path);
    if (!writable || blocked != null) {
      // 和真盘一样**抛异常**：调用方（`StoragePaths`）就是靠捕获它来区分
      // "这个候选不可用"和"写成功了"。
      throw FileSystemException('内存替身被标成只读，拒绝写入', path);
    }
    _files[path] = contents;
  }

  @override
  void deleteFile(String path) => _files.remove(path);

  @override
  void createDirectory(String path) {
    if (_readonlyAncestor(path) != null) {
      throw FileSystemException('内存替身被标成只读，拒绝建目录', path);
    }
    _directories.add(path);
  }

  @override
  bool isDirectoryWritable(String path) =>
      writable && exists(path) && _readonlyAncestor(path) == null;

  @override
  Iterable<String> listFiles(String path) => _files.keys
      .where((String key) => key.startsWith(path))
      .toList(growable: false);

  @override
  int? fileSize(String path) => _files[path]?.length;

  @override
  String? environment(String name) => _environment[name];

  // ------------------------------------------------------------------ 内部

  /// 从这个路径往上找第一个被标成不可写的祖先（含它自己）。
  String? _readonlyAncestor(String path) {
    for (String current = _normalize(path);
        current.isNotEmpty;
        current = _parentOf(current)) {
      if (_readonlyDirectories.contains(current)) return current;
    }
    return null;
  }

  /// 去掉末尾分隔符，让 `C:\dir\` 与 `C:\dir` 视为同一个位置。
  static String _normalize(String path) {
    String result = path;
    while (result.length > 1 &&
        (result.endsWith(r'\') || result.endsWith('/')) &&
        // 盘根（`C:\`）不能剪，剪了就成了 `C:`（当前目录）。
        !(result.length == 3 && result[1] == ':')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  /// 上一级目录；已经是根时返回自己（调用方靠"没变化"终止）。
  static String _parentOf(String path) {
    final int index = path.lastIndexOf(r'\') > path.lastIndexOf('/')
        ? path.lastIndexOf(r'\')
        : path.lastIndexOf('/');
    if (index < 0) return '';
    if (index == 0) return path[0];
    final String parent = path.substring(0, index);
    if (parent.length == 2 && parent[1] == ':') return parent;
    return parent;
  }
}
