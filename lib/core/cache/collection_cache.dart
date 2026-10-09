import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/collection.dart';
import '../../data/models/media_source.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';
import 'sync_policy.dart';

// ---------------------------------------------------------------------------
// 序列化
//
// `Song` 上没有 `toJson`（它属于 `lib/data/**`，本次改动不碰），
// 所以这里自己实现一份。原则有两条：
// 1. **只存展示与"重新解析地址"所需的最小字段**，不存整个 extra 的原始
//    响应 —— 缓存文件会在用户机器上放很久，多存一个字节都是长期成本；
// 2. **读回时逐字段容错**。缓存文件可能来自旧版本、可能被外部工具改过、
//    也可能是半截写入。任何一个字段脏了都只应该让"这一首歌"退化，
//    绝不能把整个歌单变成读不出来。
// ---------------------------------------------------------------------------

/// 单个字符串字段的容错读取：不是字符串就当成"没有值"。
String? _asString(Object? value) => value is String ? value : null;

/// 把任意值收敛成"jsonEncode 一定能处理"的形式。
///
/// `Song.extra` 的约定是"音源私有字段"，实际出现过的类型有 int / String /
/// bool / `List<String>` / num。但接口是开放的，理论上可能塞进任何东西
/// （例如某个音源一时图省事放了 Map）。这里做递归清洗：
/// - 认识的基本类型原样留下；
/// - List 递归清洗（元素里出现 Map 时该元素被丢掉）；
/// - 其它（Map、对象、函数…）返回 null，由调用方丢掉这个键。
///
/// 关键点是**返回 null 而不是抛异常**：一个字段不值得让整次写盘失败。
Object? _sanitizeForJson(Object? value, {int depth = 0}) {
  if (value == null) return null;
  if (value is String || value is num || value is bool) return value;
  if (value is List) {
    if (depth >= 3) return null;
    final List<Object?> cleaned = <Object?>[];
    for (final Object? item in value) {
      final Object? normalized = _sanitizeForJson(item, depth: depth + 1);
      if (normalized != null) cleaned.add(normalized);
    }
    return cleaned;
  }
  return null;
}

/// 曲目 → 可 JSON 化的 Map。
Map<String, Object?> songToCacheJson(Song song) {
  final Map<String, Object?> extra = <String, Object?>{};
  song.extra.forEach((String key, Object? value) {
    final Object? normalized = _sanitizeForJson(value);
    if (normalized != null) extra[key] = normalized;
  });

  return <String, Object?>{
    'id': song.id,
    'source': song.source.key,
    'title': song.title,
    'artists': song.artists,
    if (song.album != null) 'album': song.album,
    if (song.albumId != null) 'albumId': song.albumId,
    if (song.coverUrl != null) 'coverUrl': song.coverUrl,
    // 存毫秒而不是 ISO8601：读回时不需要再处理时区与格式差异。
    if (song.duration != null) 'durationMs': song.duration!.inMilliseconds,
    'playable': song.playable,
    if (song.unplayableReason != null)
      'unplayableReason': song.unplayableReason,
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// 可 JSON 化的 Map → 曲目。字段缺失或类型不对时逐项退化，永不抛异常。
Song? songFromCacheJson(Object? raw) {
  if (raw is! Map) return null;

  final String id = _asString(raw['id']) ?? '';
  if (id.isEmpty) return null;

  final List<String> artists = <String>[];
  final Object? rawArtists = raw['artists'];
  if (rawArtists is List) {
    for (final Object? item in rawArtists) {
      if (item is String) artists.add(item);
    }
  }

  final Map<String, Object?> extra = <String, Object?>{};
  final Object? rawExtra = raw['extra'];
  if (rawExtra is Map) {
    rawExtra.forEach((Object? key, Object? value) {
      if (key is! String) return;
      final Object? normalized = _sanitizeForJson(value);
      if (normalized != null) extra[key] = normalized;
    });
  }

  // durationMs 可能是 int，也可能被写成 double 或字符串。
  Duration? duration;
  final Object? rawDuration = raw['durationMs'];
  if (rawDuration is int && rawDuration >= 0) {
    duration = Duration(milliseconds: rawDuration);
  } else if (rawDuration is num && rawDuration >= 0) {
    duration = Duration(milliseconds: rawDuration.round());
  }

  final Object? rawTitle = raw['title'];
  final Object? rawPlayable = raw['playable'];

  return Song(
    id: id,
    source: MediaSource.fromKey(_asString(raw['source'])),
    title: rawTitle is String && rawTitle.isNotEmpty ? rawTitle : id,
    artists: artists,
    album: _asString(raw['album']),
    albumId: _asString(raw['albumId']),
    coverUrl: _asString(raw['coverUrl']),
    duration: duration,
    playable: rawPlayable is bool ? rawPlayable : true,
    unplayableReason: _asString(raw['unplayableReason']),
    extra: extra,
  );
}

// ---------------------------------------------------------------------------
// 差量合并（纯函数）
// ---------------------------------------------------------------------------

/// 一次合并的产出。
@immutable
class MergeOutcome {
  const MergeOutcome({
    required this.songs,
    required this.added,
    required this.removed,
  });

  /// 合并后的曲目列表，顺序与云端一致。
  final List<Song> songs;

  /// 相对缓存**新增**的曲目数。
  final int added;

  /// 相对缓存**消失**（云端已删）的曲目数。
  final int removed;

  @override
  String toString() => 'MergeOutcome(+$added, -$removed, ${songs.length} 首)';
}

/// 按 uid 合并「缓存内容」与「新取到的远端内容」。
///
/// **这个函数必须在两种语义完全相反的输入下都正确**，[remoteIsComplete]
/// 就是用来区分它们的开关 —— 这是整个差量合并的正确性枢纽：
/// - 差量拉取时远端只给了最前面若干页（`remoteIsComplete: false`）：
///   "缓存里有、远端没给"只是因为**我们没去取**，必须原样保留；
/// - 全量重取时远端是权威列表（`remoteIsComplete: true`）：
///   "缓存里有、远端没给"就是**云端已经删了**，必须丢掉。
///
/// 如果只有一个参数、靠 [preferRemoteCount] 之类去猜，两件事就会被混成
/// 一件："这次没返回"既被当成"被删了"又被当成"要保留"，逻辑自相矛盾，
/// 结果就是删除永远生效不了（或者差量拉取把没取到的尾部全删掉）。
///
/// 其余规则：
/// 1. **顺序以远端为准**。远端返回的就是云端当前的真实顺序
///    （收藏夹 `order=mtime`、歌单也是新内容在前），重排只会把顺序搞乱；
/// 2. **远端包含的内容默认用缓存里的对象**（[preferRemoteCount] 给出例外），
///    这样多页拼出来的列表里，同一首取到两次也只会留下一份；
/// 3. **任意一侧的重复 uid 都被折叠**，所以结果里 uid 一定不重复
///    （列表里出现两行同一首歌，是这个功能最刺眼的 bug）。
MergeOutcome mergeCollectionSongs({
  required List<Song> cached,
  required List<Song> remote,
  bool remoteIsComplete = false,
  int preferRemoteCount = 0,
}) {
  // 去重时"先到先得"：远端列表内部就算有重复，也只保留第一次出现的那条。
  final Map<String, Song> remoteByUid = <String, Song>{};
  final List<String> remoteOrder = <String>[];
  for (final Song song in remote) {
    if (remoteByUid.containsKey(song.uid)) continue;
    remoteByUid[song.uid] = song;
    remoteOrder.add(song.uid);
  }

  final Map<String, Song> cachedByUid = <String, Song>{};
  for (final Song song in cached) {
    cachedByUid.putIfAbsent(song.uid, () => song);
  }

  final List<Song> merged = <Song>[];
  final Set<String> placed = <String>{};
  int index = 0;
  int added = 0;

  for (final String uid in remoteOrder) {
    final Song fresh = remoteByUid[uid]!;
    final Song? cachedSong = cachedByUid[uid];
    if (cachedSong == null) added++;
    // 前 preferRemoteCount 条用远端的新副本（封面、可播放状态等可能变了），
    // 其余沿用缓存里的对象，避免"同一个歌单里前半段和后半段字段不一致"。
    final bool useFresh = cachedSong == null || index < preferRemoteCount;
    merged.add(useFresh ? fresh : cachedSong);
    placed.add(uid);
    index++;
  }

  // 远端这次**没返回**的内容怎么处理，完全取决于这次取的是不是完整列表 ——
  // [remoteIsComplete] 就是整个差量合并的正确性枢纽：
  //
  // - `false`（增量：只取了最前面若干页）：必须**保留**。后面那些页根本没
  //   请求过，把它们当成"已删除"会直接删掉半张歌单 —— 这是这个功能最坏的
  //   失败方式，比多打几个请求严重得多；
  // - `true`（全量重取：远端是权威列表）：缓存里有、远端没有，就是云端已删。
  if (!remoteIsComplete) {
    for (final Song song in cached) {
      if (placed.contains(song.uid)) continue;
      merged.add(cachedByUid[song.uid]!);
      placed.add(song.uid);
    }
  }

  // `removed` = 缓存里有多少条目在合并结果中已经不存在。
  //
  // 用"缓存条目数 − 结果里能对上的缓存 uid 数"，而不是"远端没返回的条数"：
  // 后者在两处会算错 —— 缓存自身带重复条目时（重复项没了也算少一条），
  // 以及增量拉取时（尾部靠缓存补上，其实一首都没少，`removed` 必须是 0）。
  int retained = 0;
  for (final String uid in cachedByUid.keys) {
    if (placed.contains(uid)) retained++;
  }

  return MergeOutcome(
    songs: merged,
    added: added,
    removed: cached.length - retained,
  );
}

// ---------------------------------------------------------------------------
// 缓存条目与结果
// ---------------------------------------------------------------------------

/// 一条集合缓存。
@immutable
class CollectionCacheEntry {
  const CollectionCacheEntry({
    required this.songs,
    required this.fetchedAt,
    this.remoteTotal,
    this.name,
  });

  final List<Song> songs;
  final DateTime fetchedAt;

  /// 云端声明的总数（可能为 null：网易云的分页接口不一定回总数）。
  final int? remoteTotal;

  /// 缓存写入时的集合名，仅用于排查问题。
  final String? name;
}

/// [CollectionCache.loadOrSync] 的结果。
@immutable
class CachedCollectionResult {
  const CachedCollectionResult({
    required this.songs,
    required this.fromCache,
    required this.synced,
    this.added = 0,
    this.removed = 0,
    this.fetchedAt,
    this.error,
  });

  /// 当前可用的完整曲目列表。
  ///
  /// **即使 [error] 不为 null 这里也一定有内容**（要么是缓存，要么是空列表）：
  /// 离线可用是这个功能的全部意义，失败时把缓存内容清掉是最糟的处理方式。
  final List<Song> songs;

  /// 这批内容是否来自本地缓存。
  final bool fromCache;

  /// 本次调用是否真的完成了联网同步。
  final bool synced;

  /// 本次同步相对缓存新增的曲目数。
  final int added;

  /// 本次同步相对缓存消失的曲目数。
  final int removed;

  /// 缓存的同步时间（无论是否刚刚同步过）。
  final DateTime? fetchedAt;

  /// 同步失败的原因（已转成可读文案）。为 null 表示这次没有出错。
  final String? error;

  @override
  String toString() =>
      'CachedCollectionResult(${songs.length} 首, '
      'fromCache=$fromCache, synced=$synced, +$added, -$removed, '
      'error=$error)';
}

/// 一次差量同步的中间产物。
@immutable
class CollectionSyncOutcome {
  const CollectionSyncOutcome({
    required this.songs,
    required this.added,
    required this.removed,
    required this.remoteTotal,
    this.pageRequests = 0,
  });

  final List<Song> songs;
  final int added;
  final int removed;
  final int? remoteTotal;

  /// 这次同步实际发出的分页请求次数。测试用它证明"省请求"确实发生了。
  final int pageRequests;

  @override
  String toString() =>
      'CollectionSyncOutcome(${songs.length} 首, '
      '+$added, -$removed, $pageRequests 次请求)';
}

/// 单个集合一页最多取多少首。
///
/// 40 是被哔哩逼出来的：`fav/resource/list` 的 `ps` 硬上限就是 40
/// （`ps=41` 直接 -400），而 40 对网易云来说只是"多翻几页"。
/// 统一取 40 而不是"按音源取 200"，是因为这里的请求数取决于**新增了多少**，
/// 而不是取决于集合有多大 —— 只有"今天新增了几百首"这种极端情况才会
/// 连翻十几页，而那种情况本来就该多花几个请求。
const int kCollectionSyncPageSize = 40;

/// 差量拉取最多翻多少页就放弃并退回全量。
///
/// 8 页 ×40 = 320 首。收藏夹一次新增 320 首以上是不正常的；
/// 真碰到了说明"按页翻"这条路不划算，交给
/// [MusicRepository.allCollectionTracks]（它内部也是翻页，但至少语义清晰、
/// 终止条件只有一处）。
const int kCollectionSyncMaxPages = 8;

// ---------------------------------------------------------------------------
// 缓存本体
// ---------------------------------------------------------------------------

/// 单个集合的本地缓存。
///
/// 目录结构：`<support>/collections/<source.key>/<collectionId>.json`。
/// 按音源分目录是因为不同音源的自增 id 完全可能撞号
/// （网易云的 `1234567` 和哔哩的 `1234567` 是两个东西），
/// 放到一个目录里迟早会互相覆盖。
class CollectionCache {
  CollectionCache({Directory? root}) : _injectedRoot = root;

  /// 测试注入的缓存根目录。
  ///
  /// 不注入时用 `getApplicationSupportDirectory()`。做成可注入是必须的：
  /// `path_provider` 在单元测试里没有平台通道，直接调用会抛
  /// `MissingPluginException`，那样缓存层就永远测不了。
  final Directory? _injectedRoot;

  Directory? _resolvedRoot;

  /// 每个集合同时只做一次同步。
  ///
  /// 不加这个的话，用户快速在两个歌单之间来回点、或者列表重建触发两次
  /// `loadOrSync`，就会对同一个收藏夹并发翻页 —— 哔哩的收藏夹接口属于
  /// 风控重点，并发翻页很容易撞上 -412，而且多出来的请求纯属浪费。
  final Map<String, Future<CachedCollectionResult>> _inflight =
      <String, Future<CachedCollectionResult>>{};

  /// 正在同步的集合数（界面可以据此显示"后台更新中"）。
  int get inflightCount => _inflight.length;

  Future<Directory> _root() async {
    final Directory? ready = _resolvedRoot;
    if (ready != null) return ready;
    final Directory base =
        _injectedRoot ?? await getApplicationSupportDirectory();
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}collections',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _resolvedRoot = dir;
    return dir;
  }

  /// collectionId 只用于拼文件名，这里把路径分隔符与 Windows 非法字符
  /// 换掉 —— 音源 id 理论上都是数字，但"理论上"不该出现在文件名里。
  String _safeId(String id) =>
      id.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');

  Future<File> _fileFor(MediaSource source, String collectionId) async {
    final Directory root = await _root();
    final Directory sourceDir = Directory(
      '${root.path}${Platform.pathSeparator}${source.key}',
    );
    if (!await sourceDir.exists()) {
      await sourceDir.create(recursive: true);
    }
    return File(
      '${sourceDir.path}${Platform.pathSeparator}${_safeId(collectionId)}.json',
    );
  }

  /// 读缓存。文件不存在、JSON 损坏、字段脏、IO 失败，一律返回 null。
  Future<CollectionCacheEntry?> read(
    MediaSource source,
    String collectionId,
  ) async {
    try {
      final File file = await _fileFor(source, collectionId);
      if (!await file.exists()) return null;

      final String text = await file.readAsString();
      if (text.trim().isEmpty) return null;

      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) return null;

      final Object? rawSongs = decoded['songs'];
      if (rawSongs is! List) return null;

      final List<Song> songs = <Song>[];
      for (final Object? raw in rawSongs) {
        final Song? song = songFromCacheJson(raw);
        if (song != null) songs.add(song);
      }

      // 一条都解析不出来：这个文件对我们没有价值，当成没有缓存。
      // 界面会走一次全量同步，下一次写盘自然把它覆盖掉。
      if (songs.isEmpty && rawSongs.isNotEmpty) return null;

      final DateTime fetchedAt =
          DateTime.tryParse(_asString(decoded['fetchedAt']) ?? '') ??
          await file.lastModified();

      final Object? rawRemoteTotal = decoded['remoteTotal'];

      return CollectionCacheEntry(
        songs: songs,
        fetchedAt: fetchedAt,
        remoteTotal: rawRemoteTotal is int ? rawRemoteTotal : null,
        name: _asString(decoded['name']),
      );
    } on Object catch (error) {
      // 半截写入 / 非法 JSON / 权限问题都会走到这里。返回 null 而不是
      // 抛异常：调用方唯一能做的补救就是"当成没有缓存重新同步"。
      debugPrint('[cache] 读取失败 $collectionId: $error');
      return null;
    }
  }

  /// 写缓存。先写 `.part` 再 rename，保证永远读不到半截文件。
  Future<void> write(
    MediaSource source,
    String collectionId, {
    required List<Song> songs,
    required int? remoteTotal,
    String? name,
  }) async {
    try {
      final File file = await _fileFor(source, collectionId);
      final Map<String, Object?> payload = <String, Object?>{
        'collectionId': collectionId,
        'source': source.key,
        'name': name,
        'fetchedAt': DateTime.now().toIso8601String(),
        'total': songs.length,
        'remoteTotal': remoteTotal,
        'songs': songs.map(songToCacheJson).toList(growable: false),
      };

      final File part = File('${file.path}.part');
      // 上一次写盘如果被杀进程，`.part` 会留在盘上；先清掉再写，
      // 否则残留文件会一直占着空间。
      if (await part.exists()) {
        try {
          await part.delete();
        } on Object catch (_) {
          // 删不掉也无所谓：后面的 writeAsString 会覆盖它。
        }
      }
      await part.writeAsString(jsonEncode(payload), flush: true);
      await part.rename(file.path);
    } on Object catch (error) {
      // 写盘失败只记日志。缓存是"锦上添花"，它失败不该影响用户看歌单。
      debugPrint('[cache] 写入失败 $collectionId: $error');
    }
  }

  /// 删除某个集合的缓存。
  Future<void> remove(MediaSource source, String collectionId) async {
    try {
      final File file = await _fileFor(source, collectionId);
      if (await file.exists()) await file.delete();
      final File part = File('${file.path}.part');
      if (await part.exists()) await part.delete();
    } on Object catch (error) {
      debugPrint('[cache] 删除失败 $collectionId: $error');
    }
  }

  /// 缓存占用的总字节数（给"清空缓存"显示大小用）。
  Future<int> totalSize() async {
    try {
      final Directory root = await _root();
      if (!await root.exists()) return 0;
      int total = 0;
      await for (final FileSystemEntity entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } on Object catch (_) {
            // 文件在遍历过程中被删掉了，跳过即可。
          }
        }
      }
      return total;
    } on Object catch (error) {
      debugPrint('[cache] 统计缓存大小失败: $error');
      return 0;
    }
  }

  /// 清空全部集合缓存。
  Future<void> clear() async {
    try {
      final Directory root = await _root();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      await root.create(recursive: true);
      // 目录被删掉又重建过，下次重新解析一次，避免继续用已经失效的引用。
      _resolvedRoot = root;
    } on Object catch (error) {
      debugPrint('[cache] 清空缓存失败: $error');
    }
  }

  // -------------------------------------------------------------------------
  // 缓存优先 + 差量同步
  // -------------------------------------------------------------------------

  /// 读缓存（不联网）。界面用它实现"秒开"。
  ///
  /// 这是 [loadOrSync] 第 1 步单独抽出来的版本：`loadOrSync` 在需要同步时
  /// 必须等到网络返回才能给出最终结果，而界面不应该为此把已有内容挡在
  /// loading 后面。所以页面先 [read] 一次把内容铺上，再 await [loadOrSync]。
  Future<CollectionCacheEntry?> readEntry(
    MediaSource source,
    String collectionId,
  ) => read(source, collectionId);

  /// 缓存优先加载，必要时做差量同步。
  ///
  /// 行为完全按"先给内容、再更新"的顺序设计：
  /// 1. 先读缓存。**有缓存就立刻返回**（`fromCache: true`），不联网；
  /// 2. 若 `force` 或 [SyncPolicy.isDue] 判定该同步，再做一次差量同步，
  ///    完成后返回**合并结果**（`synced: true`）；
  /// 3. 任何失败都不抛：原因写进 [CachedCollectionResult.error]，
  ///    同时把缓存内容原样返回 —— 断网时歌单必须还能看、还能播。
  ///
  /// 同一个集合的并发调用会被合并成一次请求（见 `_inflight`）。
  Future<CachedCollectionResult> loadOrSync({
    required MusicRepository repository,
    required MusicCollection collection,
    required SyncPolicy policy,
    bool force = false,
  }) async {
    final String key = '${collection.source.key}:${collection.id}';
    final Future<CachedCollectionResult>? pending = _inflight[key];
    if (pending != null) return pending;

    final Future<CachedCollectionResult> task = _loadOrSync(
      repository: repository,
      collection: collection,
      policy: policy,
      force: force,
    );
    _inflight[key] = task;
    try {
      return await task;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<CachedCollectionResult> _loadOrSync({
    required MusicRepository repository,
    required MusicCollection collection,
    required SyncPolicy policy,
    required bool force,
  }) async {
    final CollectionCacheEntry? entry = await read(
      collection.source,
      collection.id,
    );
    final bool shouldSync = force || policy.isDue(entry?.fetchedAt);

    if (!shouldSync) {
      return CachedCollectionResult(
        songs: entry?.songs ?? const <Song>[],
        fromCache: entry != null,
        synced: false,
        fetchedAt: entry?.fetchedAt,
      );
    }

    try {
      final CollectionSyncOutcome outcome = await computeCollectionSync(
        repository: repository,
        collection: collection,
        cached: entry?.songs ?? const <Song>[],
      );

      await write(
        collection.source,
        collection.id,
        songs: outcome.songs,
        remoteTotal: outcome.remoteTotal,
        name: collection.name,
      );

      return CachedCollectionResult(
        songs: outcome.songs,
        fromCache: entry != null,
        synced: true,
        added: outcome.added,
        removed: outcome.removed,
        fetchedAt: DateTime.now(),
      );
    } on Object catch (error) {
      // 失败也要把缓存内容继续给出去。这就是"离线可用"的全部意义。
      debugPrint('[cache] 同步失败 ${collection.uid}: $error');
      return CachedCollectionResult(
        songs: entry?.songs ?? const <Song>[],
        fromCache: entry != null,
        synced: false,
        fetchedAt: entry?.fetchedAt,
        error: error is MusicApiException ? error.message : '$error',
      );
    }
  }

  /// 差量拉取 + 合并。抽成公开方法是为了能在测试里直接驱动。
  ///
  /// 判据（为什么这样能省请求）：
  /// 收藏夹与歌单都是**新内容在最前**（哔哩收藏夹固定 `order=mtime`，
  /// 网易云的歌单也是新增的排在前面）。所以：
  ///
  /// 1. 从 `offset: 0` 起按 [kCollectionSyncPageSize] 逐页取，
  ///    逐页与缓存里的 uid 集合比对；
  /// 2. **某一页里没有任何新 uid，就说明"更新的内容"已经取完了** ——
  ///    新内容只会在前面，一页都不新就意味着更后面也不会新；
  /// 3. 再加一条保护：**云端总数没有变少**。总数变少意味着后面发生了
  ///    删除，而删除会把后面的内容整体前移，此时不能只看前缀，
  ///    必须继续翻到云端末尾才能算准差集；
  /// 4. 再加一条更强的一致性检查：**这一页必须与缓存的同一段逐位相同**。
  ///    如果某个音源的分页顺序不是"新内容在前"（或者顺序在两次请求之间
  ///    变了），前缀就会对不上，这时立刻放弃省请求、退回全量重取。
  ///
  /// 于是最常见的场景（348 首的收藏夹、今天新增了 3 首）只需要 **1 次**
  /// 请求，而不是全量重取的 9 次。
  Future<CollectionSyncOutcome> computeCollectionSync({
    required MusicRepository repository,
    required MusicCollection collection,
    required List<Song> cached,
  }) async {
    final Set<String> cachedUids = cached.map((Song song) => song.uid).toSet();

    // 云端总数。`page.total` 更准；拿不到时用列表接口给的 trackCount。
    // 注意 trackCount 为 0 只代表"不知道"，不代表"空的"：
    // 有些接口在没预热的情况下就是回 0，把它当成"云端 0 首"
    // 会立刻误判成"全都删了"，把用户的缓存清空。
    int? remoteTotal = collection.trackCount > 0 ? collection.trackCount : null;
    int pageRequests = 0;

    // 缓存为空时不必玩差值：直接全量取，省得把"首次加载"写成两套逻辑。
    if (cached.isEmpty) {
      final List<Song> all = await repository.allCollectionTracks(
        collection.id,
      );
      final MergeOutcome merged = mergeCollectionSongs(
        cached: const <Song>[],
        remote: all,
        // 首次加载：远端就是全部内容。
        remoteIsComplete: true,
      );
      return CollectionSyncOutcome(
        songs: merged.songs,
        added: merged.added,
        removed: merged.removed,
        remoteTotal: _maxOf(remoteTotal, all.length),
        pageRequests: 1,
      );
    }

    final List<Song> remote = <Song>[];
    int offset = 0;
    int pageIndex = 0;
    bool exhausted = false;
    bool prefixMatched = true;
    // 云端总数是否比缓存少（有删除）。跨迭代保留：循环外判断"前缀对不上
    // 要不要退回全量"时要用到它。
    bool shrank = false;
    // 已按序对上的缓存条目数。跨页累加 —— 这正是关键：分页的第一页
    // **通常以新内容开头**（order=mtime），所以不能拿"页内第 i 项"去和
    // "缓存第 i 项"逐位比，那样第一页必然对不上，于是永远退化成全量重取，
    // "省请求"也就无从谈起。
    int knownSeen = 0;

    while (pageIndex < kCollectionSyncMaxPages) {
      final CollectionTracksPage page = await repository.collectionTracks(
        collection.id,
        offset: offset,
        limit: kCollectionSyncPageSize,
      );
      pageRequests++;
      final int? pageTotal = page.total;
      if (pageTotal != null && pageTotal > 0) {
        remoteTotal = _maxOf(remoteTotal, pageTotal);
      }

      remote.addAll(page.songs);
      pageIndex++;
      offset += page.songs.length;

      if (page.songs.isEmpty) {
        exhausted = true;
        break;
      }

      final int pageNewCount = page.songs
          .where((Song song) => !cachedUids.contains(song.uid))
          .length;

      // 一致性检查：挑出这一页里"缓存中已有"的那些，按出现顺序必须与
      // 缓存从 [knownSeen] 起的那一段逐位相同；同时新内容只能出现在
      // 已知内容**之前**（新内容在前是这个省请求策略成立的前提）。
      // 任一不成立就放弃省请求、退回全量重取。
      if (prefixMatched) {
        bool sawKnownInPage = false;
        for (final Song song in page.songs) {
          if (!cachedUids.contains(song.uid)) {
            if (sawKnownInPage) {
              // 已知内容之后又冒出新的 → 顺序不是"新内容在前"。
              prefixMatched = false;
              break;
            }
            continue;
          }
          sawKnownInPage = true;
          if (knownSeen >= cached.length || cached[knownSeen].uid != song.uid) {
            prefixMatched = false;
            break;
          }
          knownSeen++;
        }
      }

      // 云端总数变少 → 后面有删除，必须一直翻到云端末尾才能算准差集。
      final int? knownTotal = remoteTotal;
      final bool remoteShrank =
          knownTotal != null && knownTotal < cached.length;
      shrank = remoteShrank;

      // 终止条件 A：已经覆盖了云端声明的全部内容。
      if (knownTotal != null && remote.length >= knownTotal) {
        exhausted = true;
        break;
      }

      // 终止条件 B：这一页没有任何新内容，且总数没变少，且前缀对得上。
      // 这就是"省请求"的核心：新内容只会在最前面（order=mtime），
      // 一页都不新就意味着后面也不可能新。
      if (pageNewCount == 0 && !remoteShrank && prefixMatched) break;

      // 终止条件 C：这一页里的新内容**正好等于**云端相对缓存增加的总数。
      // 新增量既然已经在这一页里全找到了，后面必然全是缓存里已有的内容，
      // 不必再多翻一页去确认。
      //
      // 用"本页新 uid 数"而不是"累计新 uid 数"：累计相同只说明"到目前为止
      // 找齐了"，而本页相同才说明"新增全部落在这一页"。少了这一条，
      // "只有 2 首新歌"的 348 首收藏夹也要翻两页才能停。
      final int? increase = knownTotal == null
          ? null
          : knownTotal - cached.length;
      if (increase != null &&
          increase > 0 &&
          pageNewCount == increase &&
          prefixMatched) {
        break;
      }

      // 没有 hasMore 就不要继续翻（网易云的专辑接口一次给全）。
      if (!page.hasMore) {
        exhausted = true;
        break;
      }
    }

    // 翻到页数上限还没停：说明"按页翻"这条路不成立（例如顺序不是
    // 新内容在前）。这时用全量重取保证正确 —— 全量那条路的终止条件
    // 只有一处，比继续按页翻更不容易出错。
    final bool needFullFetch =
        !exhausted && pageIndex >= kCollectionSyncMaxPages;

    // 前缀对不上时要不要退回全量，取决于总数有没有变少：
    //
    // - **总数变少**（`shrank`）：顺序对不上是"中间删了几首"造成的，
    //   而我们已经翻到了云端末尾，拿到的就是权威列表，直接合并即可 ——
    //   再全量重取一遍纯属浪费；
    // - **总数没变却对不上**：说明这个音源的分页顺序不是"新内容在前"
    //   （或者顺序在两次请求之间变了），那条"尾部靠缓存补上"的省请求
    //   策略前提已经不成立，必须退回全量。
    if (needFullFetch || (!prefixMatched && !shrank)) {
      final List<Song> all = await repository.allCollectionTracks(
        collection.id,
      );
      final MergeOutcome merged = mergeCollectionSongs(
        cached: cached,
        remote: all,
        // 全量重取：远端是权威列表，缓存里没被返回的确实是云端已删。
        remoteIsComplete: true,
      );
      return CollectionSyncOutcome(
        songs: merged.songs,
        added: merged.added,
        removed: merged.removed,
        remoteTotal: _maxOf(remoteTotal, all.length),
        pageRequests: pageRequests + 1,
      );
    }

    // 走到这里只有两种情况：
    // - `exhausted`：已经把云端翻完了（此时"缓存里有、远端没给"确实是删除）；
    // - 靠"终止条件 B"停下的（`exhausted == false`）：只取了最前面若干页，
    //   尾部根本没请求，缓存里剩下的必须原样保留 —— 这正是条件 B 能省请求
    //   的前提，也是 `remoteIsComplete` 必须跟着 `exhausted` 走的原因。
    //
    // 至于"取到但顺序对不上"（`prefixMatched == false`），上面已经
    // 换成全量重取了，不会走到这里。
    final MergeOutcome merged = mergeCollectionSongs(
      cached: cached,
      remote: remote,
      remoteIsComplete: exhausted,
      // 前 kCollectionSyncPageSize 条用远端的新副本（封面、可播放状态
      // 可能变了），更靠后的沿用缓存对象。
      preferRemoteCount: kCollectionSyncPageSize,
    );

    return CollectionSyncOutcome(
      songs: merged.songs,
      added: merged.added,
      removed: merged.removed,
      remoteTotal: _maxOf(remoteTotal, remote.length),
      pageRequests: pageRequests,
    );
  }
}

/// 取两个整数里较大的一个。
int _maxOf(int? a, int b) => a == null || a < b ? b : a;

/// 全局缓存实例。目录可注入是给测试用的，生产路径走默认目录。
final Provider<CollectionCache> collectionCacheProvider =
    Provider<CollectionCache>((Ref ref) => CollectionCache());

/// 按需同步一个集合。
///
/// 参数直接用 [MusicCollection]：它已经实现了 `==` / `hashCode`（按 uid），
/// 满足 `family` 对 key 判等的要求，而且同步恰好需要它身上的
/// `trackCount`（云端总数）和 `name`（排查用）。
///
/// **并发安全**由 [CollectionCache.loadOrSync] 内部的 in-flight 表保证：
/// 同一个集合被 watch 两次也只会产生一次网络请求。
///
/// 这里不写显式类型：Riverpod 3 没有导出 `FutureProviderFamily`，
/// 让类型推断从 `FutureProvider.family` 自己算出来即可。
final collectionSyncProvider =
    FutureProvider.family<CachedCollectionResult, MusicCollection>((
      Ref ref,
      MusicCollection collection,
    ) async {
      final MusicRepository? repository = repositoryFor(ref, collection.source);
      if (repository == null) {
        // 音源没注册时也要把缓存给出去：能不能联网和能不能看已缓存的内容
        // 是两件事。
        final CollectionCacheEntry? entry = await ref
            .read(collectionCacheProvider)
            .read(collection.source, collection.id);
        return CachedCollectionResult(
          songs: entry?.songs ?? const <Song>[],
          fromCache: entry != null,
          synced: false,
          fetchedAt: entry?.fetchedAt,
          error: '${collection.source.label}音源未注册，无法同步',
        );
      }

      return ref
          .read(collectionCacheProvider)
          .loadOrSync(
            repository: repository,
            collection: collection,
            policy: ref.read(syncPolicyProvider),
          );
    });
