import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../net/http_client.dart';
import '../storage/storage_paths.dart';

/// 封面磁盘 + 内存缓存。
///
/// **为什么不直接用 `cached_network_image`**：它会拖进
/// `flutter_cache_manager` → `sqflite`，而 `sqflite` 在 Windows 上必须额外
/// 初始化 `sqflite_common_ffi` 并处理数据库路径，对一个"取色 + 显示封面"
/// 的需求来说过重。这里用文件系统 + URI 摘要做键，行为完全可预测，
/// 而且取色和显示可以复用同一份字节，不会把同一张图下载两遍。
class CoverCache {
  /// [root] 是**注入的缓存根目录**（一般传 [cacheRootProvider] 解析出来的值）。
  ///
  /// 为什么要有这个参数：缓存目录现在是用户在设置里能改的（见
  /// `core/storage/storage_paths.dart`），而磁盘布局必须跟着它走 ——
  /// 否则"设置里改了缓存目录"就成了一句空话。不注入时（单元测试、
  /// 还没解析出目录的那一帧）退回应用支持目录，行为与以前完全一致。
  CoverCache(this._dio, {Directory? root}) : _injectedRoot = root;

  final Dio _dio;

  /// 注入的缓存根目录；null 表示用应用支持目录。
  final Directory? _injectedRoot;

  /// 内存层。封面是列表里最热的数据，命中内存就完全不用碰磁盘和 IO。
  ///
  /// 用 [LinkedHashMap] 手工实现 LRU：Flutter 自带的 `ImageCache` 只缓存
  /// 已解码的 `ui.Image`，而我们需要的是**原始字节**（要交给莫奈取色器）。
  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();

  /// 内存层上限，约 40 张 500×500 的 JPEG。
  static const int _memoryBudgetBytes = 24 * 1024 * 1024;

  /// 磁盘层上限。
  static const int _diskBudgetBytes = 256 * 1024 * 1024;

  int _memoryBytes = 0;

  /// 同一张封面的并发请求合并成一次下载。
  final Map<String, Future<Uint8List?>> _inflight =
      <String, Future<Uint8List?>>{};

  Directory? _directory;
  bool _diskBudgetChecked = false;

  static String _keyFor(String url) =>
      sha1.convert(utf8.encode(url)).toString();

  Future<Directory> _ensureDirectory() async {
    Directory? dir = _directory;
    if (dir != null) return dir;
    Directory? base = _injectedRoot;
    if (base == null) {
      try {
        base = await getApplicationSupportDirectory();
      } on Object catch (error) {
        // 没有插件注册（单元测试）或支持目录不可用时退到系统临时目录：
        // 缓存本来就是"丢了也没关系"的东西，不值得为此让封面加载失败。
        debugPrint('[cover] 应用支持目录不可用（$error），改用系统临时目录');
        base = Directory.systemTemp;
      }
    }
    dir = Directory('${base.path}${Platform.pathSeparator}covers');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _directory = dir;
    if (!_diskBudgetChecked) {
      _diskBudgetChecked = true;
      // 不 await：预算整理属于后台维护，不该拖慢首屏第一张封面的加载。
      unawaited(enforceDiskBudget());
    }
    return dir;
  }

  /// 取封面字节：内存 → 磁盘 → 网络。
  Future<Uint8List?> bytesFor(String? url) {
    if (url == null || url.isEmpty) return Future<Uint8List?>.value();

    final Uint8List? cached = _memory[url];
    if (cached != null) {
      // 命中后挪到队尾，维持 LRU 顺序。
      _memory.remove(url);
      _memory[url] = cached;
      return Future<Uint8List?>.value(cached);
    }

    final Future<Uint8List?>? pending = _inflight[url];
    if (pending != null) return pending;

    final Future<Uint8List?> task = _load(url);
    _inflight[url] = task;
    return task.whenComplete(() => _inflight.remove(url));
  }

  Future<Uint8List?> _load(String url) async {
    try {
      final Directory dir = await _ensureDirectory();
      final File file = File(
        '${dir.path}${Platform.pathSeparator}${_keyFor(url)}',
      );

      if (await file.exists()) {
        final Uint8List bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _putMemory(url, bytes);
          return bytes;
        }
        // 空文件说明上次写盘被打断（例如进程被杀），删掉重新下载。
        await file.delete();
      }

      final Response<List<int>> response = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          // 封面 CDN 对 Referer 敏感的音源（哔哩）在 repository 里已处理，
          // 这里只做纯粹的下载。
          followRedirects: true,
          validateStatus: (int? status) => status != null && status < 400,
        ),
      );

      final List<int>? data = response.data;
      if (data == null || data.isEmpty) return null;
      final Uint8List bytes = Uint8List.fromList(data);
      _putMemory(url, bytes);

      // 先写临时文件再改名：避免用户看到"下载了一半的封面"
      // 或者下次启动读到损坏文件。
      final File tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);

      return bytes;
    } on Object catch (error) {
      debugPrint('[cover] 加载失败 $url: $error');
      return null;
    }
  }

  void _putMemory(String url, Uint8List bytes) {
    _memory.remove(url);
    _memory[url] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > _memoryBudgetBytes && _memory.isNotEmpty) {
      final String oldest = _memory.keys.first;
      _memoryBytes -= _memory.remove(oldest)?.length ?? 0;
    }
  }

  /// 本地已缓存的封面文件（供"离线可用"判断使用）。
  Future<File?> fileFor(String? url) async {
    if (url == null || url.isEmpty) return null;
    final Directory dir = await _ensureDirectory();
    final File file = File(
      '${dir.path}${Platform.pathSeparator}${_keyFor(url)}',
    );
    return await file.exists() ? file : null;
  }

  /// 缓存目录当前占用字节数。
  Future<int> sizeOnDisk() async {
    final Directory dir = await _ensureDirectory();
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// 把磁盘占用压回预算内：按最后访问时间从旧到新删，直到总量达标。
  ///
  /// 之所以按"最后访问时间"而不是"创建时间"：用户反复播放的那几张封面
  /// 应该活下来，而不是因为下载得早就被清掉。
  Future<void> enforceDiskBudget() async {
    try {
      final Directory dir = await _ensureDirectory();
      final List<File> files = <File>[];
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is File) files.add(entity);
      }

      int total = 0;
      final List<({File file, DateTime at, int size})> entries =
          <({File file, DateTime at, int size})>[];
      for (final File file in files) {
        final FileStat stat = await file.stat();
        total += stat.size;
        entries.add((file: file, at: stat.accessed, size: stat.size));
      }
      if (total <= _diskBudgetBytes) return;

      entries.sort(
        (
          ({File file, DateTime at, int size}) a,
          ({File file, DateTime at, int size}) b,
        ) => a.at.compareTo(b.at),
      );
      for (final ({File file, DateTime at, int size}) entry in entries) {
        if (total <= _diskBudgetBytes) break;
        // `.part` 是写盘中间态，删掉是安全的。
        await entry.file.delete();
        total -= entry.size;
      }
      debugPrint(
        '[cover] 磁盘缓存已整理至 ${(total / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } on Object catch (error) {
      debugPrint('[cover] 整理磁盘缓存失败: $error');
    }
  }

  /// 清空全部缓存。
  Future<void> clear() async {
    _memory.clear();
    _memoryBytes = 0;
    final Directory dir = await _ensureDirectory();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }
}

/// 封面缓存实例。
///
/// [root] 来自用户可改的缓存目录设置（`storage_paths.dart` 的
/// `cacheRootProvider`）。它异步解析，所以这里先给一个"还没有目录"的实例：
/// 那一帧里封面走应用支持目录，解析完成后 provider 重建，新实例改用用户选的
/// 目录。**这是刻意的取舍** —— 把缓存目录解析放在 `main()` 里做，就要动
/// `main.dart`，而"多一层注入点"比"启动期多一次等待"划算。
final Provider<CoverCache> coverCacheProvider = Provider<CoverCache>((Ref ref) {
  final AsyncValue<String> root = ref.watch(cacheRootProvider);
  // 用模式匹配取"已经算出来的值"，而不是 `requireValue`：第一帧它一定还没算完，
  // 那时需要的是"退回默认目录"，而不是让整个封面缓存炸掉。
  final String? path = switch (root) {
    AsyncData<String>(:final String value) => value,
    _ => null,
  };
  return CoverCache(
    ref.watch(dioProvider),
    root: (path == null || path.trim().isEmpty) ? null : Directory(path),
  );
});
