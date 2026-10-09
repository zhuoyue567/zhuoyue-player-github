import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/cache/collection_cache.dart';
import 'package:zhuoyue_player/core/cache/sync_policy.dart';
import 'package:zhuoyue_player/data/models/audio_quality.dart';
import 'package:zhuoyue_player/data/models/collection.dart';
import 'package:zhuoyue_player/data/models/lyric.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/data/repositories/music_repository.dart';

/// 构造一首测试用曲目。
///
/// [extra] 里刻意混入 int / String / bool / List，用来验证 extra 的往返；
/// 默认值是一份"每个字段都有值"的样本，方便逐字段断言。
Song makeSong(
  int index, {
  MediaSource source = MediaSource.bilibili,
  String? title,
  bool playable = true,
  Map<String, Object?> extra = const <String, Object?>{},
}) {
  return Song(
    id: 's$index',
    source: source,
    title: title ?? '曲目 $index',
    artists: <String>['歌手 $index'],
    album: '专辑 $index',
    albumId: 'al$index',
    coverUrl: 'https://example.com/c$index.jpg',
    duration: Duration(seconds: 60 + index),
    playable: playable,
    unplayableReason: playable ? null : '版权下架',
    extra: extra,
  );
}

/// 一个"按 offset/limit 切片"的假音源。
///
/// 只实现 `collectionTracks` / `allCollectionTracks`，其余成员一律
/// 用不到但也必须实现（`MusicRepository` 是 interface class），
/// 调用到就抛错，避免测试里悄悄依赖了不存在的能力。
///
/// 分页行为刻意与真实音源对齐：**按调用方给的 `limit` 从 [cloud] 里切片**。
/// 如果这里固定按 40 切、却忽略调用方传进来的 limit，就会掩盖
/// "offset 推进多少"这类真实的分页 bug。
class FakeRepository implements MusicRepository {
  FakeRepository({required this.cloud, this.total});

  /// 云端的完整曲目列表（按云端顺序）。
  final List<Song> cloud;

  /// `CollectionTracksPage.total`。
  ///
  /// `null` 表示"接口不回总数"（网易云歌单的常见情况）。
  final int? total;

  int pageCalls = 0;
  int allCalls = 0;
  int maxSongsSeen = 0;
  final List<int> requestedOffsets = <int>[];

  @override
  MediaSource get source => MediaSource.bilibili;

  @override
  Future<CollectionTracksPage> collectionTracks(
    String collectionId, {
    int offset = 0,
    int limit = 50,
  }) async {
    pageCalls++;
    requestedOffsets.add(offset);
    final int size = limit <= 0 ? 1 : limit;
    maxSongsSeen = maxSongsSeen > size ? maxSongsSeen : size;

    final int start = offset < 0 ? 0 : offset;
    if (start >= cloud.length) {
      return CollectionTracksPage(
        songs: <Song>[],
        hasMore: false,
        total: total,
      );
    }
    final int end = (start + size).clamp(0, cloud.length);
    return CollectionTracksPage(
      songs: cloud.sublist(start, end),
      hasMore: end < cloud.length,
      total: total,
    );
  }

  @override
  Future<List<Song>> allCollectionTracks(
    String collectionId, {
    int maxSongs = 3000,
  }) async {
    allCalls++;
    if (cloud.length > maxSongs) return cloud.sublist(0, maxSongs);
    return cloud;
  }

  Never _unsupported(String name) => throw UnsupportedError('测试用假音源不支持 $name');

  @override
  List<AudioQuality> get audioQualities => const <AudioQuality>[];

  @override
  String get preferredQualityId => kAutoQualityId;

  @override
  Future<void> setPreferredQuality(String qualityId) async =>
      _unsupported('setPreferredQuality');

  @override
  AudioQuality get effectiveQuality => throw UnimplementedError();

  @override
  bool get isAuthenticated => false;

  @override
  AccountProfile? get account => null;

  @override
  Stream<AccountProfile?> get accountChanges =>
      const Stream<AccountProfile?>.empty();

  @override
  Future<AccountProfile?> refreshAccount() async => null;

  @override
  Future<void> logout() async {}

  @override
  Future<List<MusicCollection>> myCollections() async =>
      _unsupported('myCollections');

  @override
  Future<List<DiscoverFeed>> discover() async => _unsupported('discover');

  @override
  Future<List<MusicCollection>> discoverCollections() async =>
      _unsupported('discoverCollections');

  @override
  Future<List<Song>> search(String keyword, {int limit = 30}) async =>
      _unsupported('search');

  @override
  Future<List<String>> searchSuggestions(String keyword) async =>
      _unsupported('searchSuggestions');

  @override
  Future<ResolvedStream> resolveStream(Song song) async =>
      _unsupported('resolveStream');

  @override
  Future<Lyric> lyric(Song song) async => _unsupported('lyric');

  @override
  Future<bool> isLiked(Song song) async => _unsupported('isLiked');

  @override
  Future<void> setLiked(Song song, bool liked) async =>
      _unsupported('setLiked');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('zhy_cache_test_');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 必须先 getInstance 一次：`setMockInitialValues` 只是换了后端，
    // 之后再 `setString(...)` 一个类型不对的值会让读取端抛
    // `SharedPreferencesException`。这里先拿到实例，顺便验证
    // "缓存实例与后端绑定"这条生产路径也成立。
    await SharedPreferences.getInstance();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  CollectionCache newCache() => CollectionCache(root: tempRoot);

  MusicCollection collectionOf({String id = '100', int trackCount = 0}) {
    return MusicCollection(
      id: id,
      source: MediaSource.bilibili,
      name: '测试收藏夹',
      kind: CollectionKind.favorite,
      trackCount: trackCount,
    );
  }

  // -------------------------------------------------------------------------
  // 序列化
  // -------------------------------------------------------------------------

  group('Song 序列化', () {
    test('往返不丢关键字段', () {
      final Song original = Song(
        id: 'BV1xx',
        source: MediaSource.bilibili,
        title: '标题',
        artists: <String>['A', 'B'],
        album: '专辑',
        albumId: 'al1',
        coverUrl: 'https://example.com/x.jpg',
        duration: const Duration(minutes: 3, seconds: 7),
        playable: false,
        unplayableReason: '需要大会员',
        extra: <String, Object?>{
          'cid': 12345,
          'bvid': 'BV1xx',
          'vip': true,
          'tags': <String>['a', 'b'],
          'score': 9.5,
        },
      );

      // 走一遍真实的 JSON 编解码，而不是只调两个函数：
      // 只有这样才能发现"extra 里塞了 jsonEncode 处理不了的东西"。
      final String encoded = jsonEncode(songToCacheJson(original));
      final Song? restored = songFromCacheJson(jsonDecode(encoded));

      expect(restored, isNotNull);
      final Song value = restored!;
      expect(value.uid, original.uid);
      expect(value.id, 'BV1xx');
      expect(value.source, MediaSource.bilibili);
      expect(value.title, '标题');
      expect(value.artists, <String>['A', 'B']);
      expect(value.album, '专辑');
      expect(value.albumId, 'al1');
      expect(value.coverUrl, 'https://example.com/x.jpg');
      expect(value.duration, const Duration(minutes: 3, seconds: 7));
      expect(value.playable, isFalse);
      expect(value.unplayableReason, '需要大会员');
      expect(value.extra['cid'], 12345);
      expect(value.extra['bvid'], 'BV1xx');
      expect(value.extra['vip'], true);
      expect(value.extra['tags'], <String>['a', 'b']);
      expect(value.extra['score'], 9.5);
    });

    test('字段缺失或类型错误时不抛异常，只逐项退化', () {
      // 全是脏数据：缺 id 之外的字段、类型全错、extra 里还有 Map。
      final Song? song = songFromCacheJson(<String, Object?>{
        'id': 's1',
        'source': 42,
        'title': <String>['不是我'],
        'artists': 'not-a-list',
        'durationMs': -5,
        'playable': 'yes',
        'extra': <String, Object?>{
          'nested': <String, Object?>{'a': 1},
          'ok': 'v',
        },
      });

      expect(song, isNotNull);
      expect(song!.id, 's1');
      expect(song.title, 's1'); // 标题脏了就用 id 兜底
      expect(song.source, MediaSource.local); // 来源认不出来时回落到 local
      expect(song.artists, isEmpty);
      expect(song.duration, isNull);
      expect(song.playable, isTrue);
      // Map 类型的 extra 字段被丢掉，其它字段保留。
      expect(song.extra.containsKey('nested'), isFalse);
      expect(song.extra['ok'], 'v');
    });

    test('没有 id 的条目直接丢弃', () {
      expect(songFromCacheJson(<String, Object?>{'title': '无 id'}), isNull);
      expect(songFromCacheJson('不是 Map'), isNull);
      expect(songFromCacheJson(null), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 缓存读写
  // -------------------------------------------------------------------------

  group('CollectionCache 读写', () {
    test('write → read 往返一致', () async {
      final CollectionCache cache = newCache();
      final List<Song> songs = <Song>[makeSong(1), makeSong(2), makeSong(3)];

      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: songs,
        remoteTotal: 5,
        name: '测试收藏夹',
      );

      final CollectionCacheEntry? entry = await cache.read(
        MediaSource.bilibili,
        '100',
      );
      expect(entry, isNotNull);
      expect(
        entry!.songs.map((Song s) => s.uid).toList(),
        songs.map((Song s) => s.uid).toList(),
      );
      expect(entry.songs.first.title, '曲目 1');
      expect(entry.remoteTotal, 5);
      expect(entry.name, '测试收藏夹');
      // fetchedAt 必须是刚刚，而不是"1970"之类的兜底值。
      expect(
        DateTime.now().difference(entry.fetchedAt).inMinutes.abs(),
        lessThan(1),
      );
    });

    test('没有缓存时返回 null', () async {
      expect(await newCache().read(MediaSource.bilibili, '不存在'), isNull);
    });

    test('文件被截断成半截 JSON 时返回 null 而不是抛异常', () async {
      final CollectionCache cache = newCache();
      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: <Song>[makeSong(1)],
        remoteTotal: 1,
      );
      final File file = File(
        '${tempRoot.path}${Platform.pathSeparator}collections'
        '${Platform.pathSeparator}bilibili${Platform.pathSeparator}100.json',
      );
      expect(file.existsSync(), isTrue);

      final String full = await file.readAsString();
      await file.writeAsString(full.substring(0, full.length ~/ 2));

      expect(await cache.read(MediaSource.bilibili, '100'), isNull);
    });

    test('文件内容不是 JSON 时返回 null', () async {
      final CollectionCache cache = newCache();
      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: <Song>[makeSong(1)],
        remoteTotal: 1,
      );
      final File file = File(
        '${tempRoot.path}${Platform.pathSeparator}collections'
        '${Platform.pathSeparator}bilibili${Platform.pathSeparator}100.json',
      );
      await file.writeAsString('这显然不是 JSON {{{');

      expect(await cache.read(MediaSource.bilibili, '100'), isNull);
    });

    test('songs 字段被写成非列表时返回 null', () async {
      final CollectionCache cache = newCache();
      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: <Song>[makeSong(1)],
        remoteTotal: 1,
      );
      final File file = File(
        '${tempRoot.path}${Platform.pathSeparator}collections'
        '${Platform.pathSeparator}bilibili${Platform.pathSeparator}100.json',
      );
      await file.writeAsString(
        jsonEncode(<String, Object?>{'songs': 'not-a-list'}),
      );

      expect(await cache.read(MediaSource.bilibili, '100'), isNull);
    });

    test('remove 之后读不到，totalSize / clear 正常工作', () async {
      final CollectionCache cache = newCache();
      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: <Song>[makeSong(1), makeSong(2)],
        remoteTotal: 2,
      );
      await cache.write(
        MediaSource.netease,
        '200',
        songs: <Song>[makeSong(3)],
        remoteTotal: 1,
      );

      expect(await cache.totalSize(), greaterThan(0));

      await cache.remove(MediaSource.bilibili, '100');
      expect(await cache.read(MediaSource.bilibili, '100'), isNull);
      // 只删了 bilibili 的那一份，netease 的还在。
      expect(await cache.read(MediaSource.netease, '200'), isNotNull);

      await cache.clear();
      expect(await cache.totalSize(), 0);
      expect(await cache.read(MediaSource.netease, '200'), isNull);
    });

    test('不同音源的同名 id 不会互相覆盖', () async {
      final CollectionCache cache = newCache();
      await cache.write(
        MediaSource.bilibili,
        '777',
        songs: <Song>[makeSong(1)],
        remoteTotal: 1,
      );
      await cache.write(
        MediaSource.netease,
        '777',
        songs: <Song>[makeSong(2, source: MediaSource.netease)],
        remoteTotal: 1,
      );

      final CollectionCacheEntry? bili = await cache.read(
        MediaSource.bilibili,
        '777',
      );
      final CollectionCacheEntry? netease = await cache.read(
        MediaSource.netease,
        '777',
      );
      expect(bili!.songs.single.id, 's1');
      expect(netease!.songs.single.id, 's2');
    });
  });

  // -------------------------------------------------------------------------
  // 同步策略
  // -------------------------------------------------------------------------

  group('SyncPolicy.isDue', () {
    test('manual 永远不同步', () {
      const SyncPolicy policy = SyncPolicy(SyncFrequency.manual);
      expect(policy.frequency.interval, isNull);
      expect(policy.isDue(null), isFalse);
      expect(policy.isDue(DateTime.now()), isFalse);
      expect(
        policy.isDue(DateTime.now().subtract(const Duration(days: 365))),
        isFalse,
      );
    });

    test('onLaunch 在"今天还没同步过"时为真', () {
      const SyncPolicy policy = SyncPolicy(SyncFrequency.onLaunch);
      expect(policy.frequency.interval, isNull);
      expect(policy.isDue(null), isTrue);
      expect(policy.isDue(DateTime.now()), isFalse);
      // 同一天但更早的时刻：不算过期（按自然日比较，而不是按 24 小时）。
      final DateTime todayEarly = DateTime.now().copyWith(
        hour: 0,
        minute: 1,
        second: 0,
        millisecond: 0,
        microsecond: 0,
      );
      expect(policy.isDue(todayEarly), isFalse);
      // 昨天：过期。
      expect(
        policy.isDue(DateTime.now().subtract(const Duration(days: 1))),
        isTrue,
      );
    });

    test('hourly 按间隔判定', () {
      const SyncPolicy policy = SyncPolicy(SyncFrequency.hourly);
      expect(policy.frequency.interval, const Duration(hours: 1));
      expect(policy.isDue(null), isTrue);
      expect(policy.isDue(DateTime.now()), isFalse);
      expect(
        policy.isDue(DateTime.now().subtract(const Duration(minutes: 30))),
        isFalse,
      );
      expect(
        policy.isDue(DateTime.now().subtract(const Duration(minutes: 61))),
        isTrue,
      );
    });

    test('every6Hours / daily 的间隔正确', () {
      expect(
        const SyncPolicy(SyncFrequency.every6Hours).frequency.interval,
        const Duration(hours: 6),
      );
      expect(
        const SyncPolicy(SyncFrequency.daily).frequency.interval,
        const Duration(days: 1),
      );
      expect(
        const SyncPolicy(SyncFrequency.every6Hours)
            .isDue(DateTime.now().subtract(const Duration(hours: 5))),
        isFalse,
      );
      expect(
        const SyncPolicy(SyncFrequency.every6Hours)
            .isDue(DateTime.now().subtract(const Duration(hours: 7))),
        isTrue,
      );
      expect(
        const SyncPolicy(SyncFrequency.daily)
            .isDue(DateTime.now().subtract(const Duration(hours: 23))),
        isFalse,
      );
    });

    test('SyncPolicyStore 读写 shared_preferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // 必须注入实例：`load()` 是同步的，没有实例时只能回落默认值
      // （这正是"应用还没初始化 SharedPreferences"时的正确行为）。
      final SyncPolicyStore store = SyncPolicyStore(preferences: prefs);
      // 没写过时回落到默认值。
      expect(store.load(), SyncFrequency.onLaunch);

      await store.save(SyncFrequency.hourly);
      expect(store.load(), SyncFrequency.hourly);
      expect(prefs.getString(SyncPolicyStore.storageKey), 'hourly');

      await store.save(SyncFrequency.manual);
      expect(store.load(), SyncFrequency.manual);

      // 值被写坏时回落到默认值而不是抛异常。
      await prefs.setString(SyncPolicyStore.storageKey, '不是合法枚举值');
      expect(store.load(), SyncFrequency.onLaunch);
    });
  });

  // -------------------------------------------------------------------------
  // 差量合并（纯函数）
  // -------------------------------------------------------------------------

  group('mergeCollectionSongs 差量合并', () {
    test('前面新增若干条：新增在前，旧的照旧', () {
      final List<Song> cached = <Song>[makeSong(1), makeSong(2), makeSong(3)];
      // 云端最新顺序：s9、s8 是新的，后面跟着原来的 s1、s2、s3。
      final List<Song> remote = <Song>[
        makeSong(9),
        makeSong(8),
        makeSong(1),
        makeSong(2),
        makeSong(3),
      ];

      final MergeOutcome outcome = mergeCollectionSongs(
        cached: cached,
        remote: remote,
      );

      expect(outcome.songs.map((Song s) => s.id).toList(), <String>[
        's9',
        's8',
        's1',
        's2',
        's3',
      ]);
      expect(outcome.added, 2);
      expect(outcome.removed, 0);
      expect(
        outcome.songs.map((Song s) => s.uid).toSet().length,
        outcome.songs.length,
        reason: 'uid 不能重复',
      );
    });

    test('远端只给了最前面一页（差量拉取）：尾部靠缓存补上，顺序不乱', () {
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 10; i++) makeSong(i),
      ];
      // 只取到前 4 条：2 首新的 + 原来的前 2 首。
      final List<Song> remote = <Song>[
        makeSong(11),
        makeSong(12),
        makeSong(1),
        makeSong(2),
      ];

      final MergeOutcome outcome = mergeCollectionSongs(
        cached: cached,
        remote: remote,
        preferRemoteCount: 4,
      );

      expect(outcome.songs.map((Song s) => s.id).toList(), <String>[
        's11',
        's12',
        's1',
        's2',
        's3',
        's4',
        's5',
        's6',
        's7',
        's8',
        's9',
        's10',
      ]);
      expect(outcome.added, 2);
      expect(outcome.removed, 0);
      // 前 4 条用远端的新副本（这里就是同一个对象）。
      expect(outcome.songs[0], same(remote[0]));
      expect(outcome.songs[2], same(remote[2]));
      // 从第 5 条起沿用缓存对象。
      expect(outcome.songs[4], same(cached[2]));
    });

    test('删除若干条：被删的不再出现，removed 计数正确', () {
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 5; i++) makeSong(i),
      ];
      final List<Song> remote = <Song>[makeSong(1), makeSong(3), makeSong(5)];

      // 必须显式声明"远端是完整列表"：只有全量重取时，"远端没返回"
      // 才等于"云端已删除"。增量拉取时同样的输入必须保留缓存尾部，
      // 那一条由上面的 partial 用例守着。
      final MergeOutcome outcome = mergeCollectionSongs(
        cached: cached,
        remote: remote,
        remoteIsComplete: true,
      );

      expect(outcome.songs.map((Song s) => s.id).toList(), <String>[
        's1',
        's3',
        's5',
      ]);
      expect(outcome.added, 0);
      expect(outcome.removed, 2);
    });

    test('同时新增与删除，顺序与计数都正确', () {
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 6; i++) makeSong(i),
      ];
      // 新增 s7、s8 在最前；s2、s4 被删掉。
      final List<Song> remote = <Song>[
        makeSong(8),
        makeSong(7),
        makeSong(1),
        makeSong(3),
        makeSong(5),
        makeSong(6),
      ];

      final MergeOutcome outcome = mergeCollectionSongs(
        cached: cached,
        remote: remote,
        remoteIsComplete: true,
      );

      expect(outcome.songs.map((Song s) => s.id).toList(), <String>[
        's8',
        's7',
        's1',
        's3',
        's5',
        's6',
      ]);
      expect(outcome.added, 2);
      expect(outcome.removed, 2);
      expect(
        outcome.songs.map((Song s) => s.uid).toSet().length,
        outcome.songs.length,
      );
    });

    test('两侧都存在重复 uid 时结果里也不重复', () {
      final Song a = makeSong(1);
      final List<Song> cached = <Song>[a, a, makeSong(2)];
      final List<Song> remote = <Song>[makeSong(2), makeSong(2), makeSong(1)];

      final MergeOutcome outcome = mergeCollectionSongs(
        cached: cached,
        remote: remote,
      );

      expect(outcome.songs.map((Song s) => s.id).toList(), <String>[
        's2',
        's1',
      ]);
      expect(outcome.added, 0);
      expect(outcome.removed, 1, reason: '重复的 s1 只算删掉了一条');
      expect(
        outcome.songs.map((Song s) => s.uid).toSet().length,
        outcome.songs.length,
      );
    });

    test('preferRemoteCount 之外沿用缓存对象（保字段新鲜度的边界）', () {
      final List<Song> cached = <Song>[
        makeSong(1, title: '旧标题'),
        makeSong(2, title: '旧标题'),
      ];
      final List<Song> remote = <Song>[
        makeSong(1, title: '新标题'),
        makeSong(2, title: '新标题'),
      ];

      final MergeOutcome onlyFirst = mergeCollectionSongs(
        cached: cached,
        remote: remote,
        preferRemoteCount: 1,
      );
      expect(onlyFirst.songs[0].title, '新标题');
      expect(onlyFirst.songs[1].title, '旧标题');

      final MergeOutcome allFresh = mergeCollectionSongs(
        cached: cached,
        remote: remote,
        preferRemoteCount: 9,
      );
      expect(allFresh.songs[0].title, '新标题');
      expect(allFresh.songs[1].title, '新标题');
    });

    test('缓存为空时就是远端内容本身', () {
      final List<Song> remote = <Song>[makeSong(1), makeSong(2)];
      final MergeOutcome outcome = mergeCollectionSongs(
        cached: const <Song>[],
        remote: remote,
      );
      expect(outcome.songs.length, 2);
      expect(outcome.added, 2);
      expect(outcome.removed, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 差量拉取（省请求的判据）
  // -------------------------------------------------------------------------

  group('computeCollectionSync 差量拉取', () {
    test('一页里没有新内容就立刻停止翻页（只发 1 次请求）', () async {
      final CollectionCache cache = newCache();
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 100; i++) makeSong(i),
      ];
      // 云端：2 首新的 + 原来的内容；分页按 40 切割。
      final List<Song> cloud = <Song>[makeSong(101), makeSong(102), ...cached];
      final FakeRepository repository = FakeRepository(
        cloud: cloud,
        total: cloud.length,
      );

      final CollectionSyncOutcome outcome = await cache.computeCollectionSync(
        repository: repository,
        collection: collectionOf(trackCount: cloud.length),
        cached: cached,
      );

      expect(outcome.added, 2);
      expect(outcome.removed, 0);
      expect(outcome.songs.length, 102);
      expect(outcome.songs.first.id, 's101');
      expect(outcome.pageRequests, 1, reason: '新内容都在第一页，一页就够');
      expect(repository.pageCalls, 1);
      expect(repository.allCalls, 0, reason: '不该退回全量重取');
      expect(repository.maxSongsSeen, kCollectionSyncPageSize);
    });

    test('云端没有变化时也只发 1 次请求', () async {
      final CollectionCache cache = newCache();
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 120; i++) makeSong(i),
      ];
      final FakeRepository repository = FakeRepository(
        cloud: cached,
        total: cached.length,
      );

      final CollectionSyncOutcome outcome = await cache.computeCollectionSync(
        repository: repository,
        collection: collectionOf(trackCount: cached.length),
        cached: cached,
      );

      expect(outcome.added, 0);
      expect(outcome.removed, 0);
      expect(outcome.songs.length, 120);
      expect(outcome.pageRequests, 1);
      expect(repository.allCalls, 0);
    });

    test('新增内容超过一页时会连续翻页，直到某页没有新 uid', () async {
      final CollectionCache cache = newCache();
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 50; i++) makeSong(i),
      ];
      // 45 首新的（>1 页），后面接原来的内容。
      final List<Song> cloud = <Song>[
        for (int i = 1000; i < 1045; i++) makeSong(i),
        ...cached,
      ];
      final FakeRepository repository = FakeRepository(
        cloud: cloud,
        total: cloud.length,
      );

      final CollectionSyncOutcome outcome = await cache.computeCollectionSync(
        repository: repository,
        collection: collectionOf(trackCount: cloud.length),
        cached: cached,
      );

      expect(outcome.added, 45);
      expect(outcome.removed, 0);
      expect(outcome.songs.length, 95);
      // 第 1 页（全是新的）→ 第 2 页（5 新 + 35 旧，有新 uid）→
      // 第 3 页（全是旧 uid）→ 停止。
      expect(outcome.pageRequests, 3);
      expect(repository.allCalls, 0);
    });

    test('云端总数变少（有删除）时必须继续翻到末尾，差集才正确', () async {
      final CollectionCache cache = newCache();
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 100; i++) makeSong(i),
      ];
      // 云端删掉了 s5、s6，只剩 98 首。
      final List<Song> cloud = <Song>[
        for (int i = 1; i <= 100; i++)
          if (i != 5 && i != 6) makeSong(i),
      ];
      final FakeRepository repository = FakeRepository(
        cloud: cloud,
        total: cloud.length,
      );

      final CollectionSyncOutcome outcome = await cache.computeCollectionSync(
        repository: repository,
        collection: collectionOf(trackCount: cloud.length),
        cached: cached,
      );

      expect(outcome.songs.length, 98);
      expect(outcome.removed, 2);
      expect(outcome.added, 0);
      expect(outcome.songs.map((Song s) => s.id).contains('s5'), isFalse);
      expect(outcome.songs.map((Song s) => s.id).contains('s6'), isFalse);
      // 98 首要翻 3 页（40 + 40 + 18）。
      expect(outcome.pageRequests, 3);
      expect(repository.allCalls, 0);
    });

    test('分页顺序与缓存对不上时退回全量重取', () async {
      final CollectionCache cache = newCache();
      final List<Song> cached = <Song>[
        for (int i = 1; i <= 10; i++) makeSong(i),
      ];
      // 云端顺序被彻底打乱（模拟"不是新内容在前"的音源 / 顺序变更）。
      final List<Song> cloud = <Song>[
        for (int i = 10; i >= 1; i--) makeSong(i),
      ];
      final FakeRepository repository = FakeRepository(
        cloud: cloud,
        total: cloud.length,
      );

      final CollectionSyncOutcome outcome = await cache.computeCollectionSync(
        repository: repository,
        collection: collectionOf(trackCount: cloud.length),
        cached: cached,
      );

      expect(repository.allCalls, 1, reason: '前缀对不上就必须走全量');
      expect(
        outcome.songs.map((Song s) => s.id).toList(),
        cloud.map((Song s) => s.id).toList(),
      );
      expect(outcome.added, 0);
      expect(outcome.removed, 0);
      expect(
        outcome.songs.map((Song s) => s.uid).toSet().length,
        outcome.songs.length,
      );
    });

    test('首次加载（没有缓存）走全量', () async {
      final CollectionCache cache = newCache();
      final List<Song> cloud = <Song>[makeSong(1), makeSong(2)];
      final FakeRepository repository = FakeRepository(
        cloud: cloud,
        total: cloud.length,
      );

      final CollectionSyncOutcome outcome = await cache.computeCollectionSync(
        repository: repository,
        collection: collectionOf(trackCount: cloud.length),
        cached: const <Song>[],
      );

      expect(repository.allCalls, 1);
      expect(repository.pageCalls, 0);
      expect(outcome.songs.length, 2);
      expect(outcome.added, 2);
    });
  });

  // -------------------------------------------------------------------------
  // loadOrSync：缓存优先 + 去重 + 容错
  // -------------------------------------------------------------------------

  group('loadOrSync', () {
    test('manual 策略下有缓存就完全不联网', () async {
      final CollectionCache cache = newCache();
      final List<Song> cached = <Song>[makeSong(1), makeSong(2)];
      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: cached,
        remoteTotal: 2,
      );

      final FakeRepository repository = FakeRepository(cloud: cached, total: 2);
      final CachedCollectionResult result = await cache.loadOrSync(
        repository: repository,
        collection: collectionOf(trackCount: 2),
        policy: const SyncPolicy(SyncFrequency.manual),
      );

      expect(result.fromCache, isTrue);
      expect(result.synced, isFalse);
      expect(result.songs.length, 2);
      expect(result.fetchedAt, isNotNull);
      expect(repository.pageCalls + repository.allCalls, 0);
    });

    test('force 时跳过频率限制并把合并结果写回缓存', () async {
      final CollectionCache cache = newCache();
      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: <Song>[makeSong(1), makeSong(2)],
        remoteTotal: 2,
      );

      final FakeRepository repository = FakeRepository(
        cloud: <Song>[makeSong(3), makeSong(1), makeSong(2)],
        total: 3,
      );

      final CachedCollectionResult result = await cache.loadOrSync(
        repository: repository,
        collection: collectionOf(trackCount: 3),
        policy: const SyncPolicy(SyncFrequency.manual),
        force: true,
      );

      expect(result.synced, isTrue);
      expect(result.fromCache, isTrue);
      expect(result.added, 1);
      expect(result.songs.first.id, 's3');

      final CollectionCacheEntry? written = await cache.read(
        MediaSource.bilibili,
        '100',
      );
      expect(written!.songs.map((Song s) => s.id).toList(), <String>[
        's3',
        's1',
        's2',
      ]);
      expect(written.remoteTotal, 3);
    });

    test('同步失败时继续返回缓存内容并把原因写进 error', () async {
      final CollectionCache cache = newCache();
      final List<Song> cached = <Song>[makeSong(1)];
      await cache.write(
        MediaSource.bilibili,
        '100',
        songs: cached,
        remoteTotal: 1,
      );

      final CachedCollectionResult result = await cache.loadOrSync(
        repository: _ThrowingRepository(),
        collection: collectionOf(trackCount: 1),
        policy: const SyncPolicy(SyncFrequency.manual),
        force: true,
      );

      expect(result.synced, isFalse);
      expect(result.fromCache, isTrue);
      expect(result.songs.single.id, 's1');
      expect(result.error, isNotNull);
      expect(result.error, contains('网络炸了'));
    });

    test('同一个集合并发同步只发一次请求', () async {
      final CollectionCache cache = newCache();
      final List<Song> cloud = <Song>[makeSong(1), makeSong(2)];
      final FakeRepository repository = FakeRepository(
        cloud: cloud,
        total: cloud.length,
      );

      final List<CachedCollectionResult> results =
          await Future.wait<CachedCollectionResult>(
            <Future<CachedCollectionResult>>[
              cache.loadOrSync(
                repository: repository,
                collection: collectionOf(trackCount: 2),
                policy: const SyncPolicy(SyncFrequency.manual),
                force: true,
              ),
              cache.loadOrSync(
                repository: repository,
                collection: collectionOf(trackCount: 2),
                policy: const SyncPolicy(SyncFrequency.manual),
                force: true,
              ),
            ],
          );

      expect(results.length, 2);
      expect(repository.allCalls, 1, reason: 'in-flight 去重让第二次复用了第一次的 Future');
      expect(cache.inflightCount, 0);
    });
  });
}

/// 所有取曲目的接口都抛错的假音源，用来测"失败也要给缓存"。
class _ThrowingRepository extends FakeRepository {
  _ThrowingRepository() : super(cloud: const <Song>[]);

  @override
  Future<List<Song>> allCollectionTracks(
    String collectionId, {
    int maxSongs = 3000,
  }) async {
    allCalls++;
    throw const MusicApiException('网络炸了');
  }

  @override
  Future<CollectionTracksPage> collectionTracks(
    String collectionId, {
    int offset = 0,
    int limit = 50,
  }) async {
    pageCalls++;
    throw const MusicApiException('网络炸了');
  }
}
