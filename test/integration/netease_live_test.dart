import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/cache/collection_cache.dart';
import 'package:zhuoyue_player/core/net/http_client.dart';
import 'package:zhuoyue_player/core/runtime/embedded_netease_api.dart';
import 'package:zhuoyue_player/data/models/audio_quality.dart';
import 'package:zhuoyue_player/data/models/collection.dart';
import 'package:zhuoyue_player/data/models/lyric.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/data/netease/netease_api_client.dart';
import 'package:zhuoyue_player/data/netease/netease_login.dart';
import 'package:zhuoyue_player/data/netease/netease_repository.dart';
import 'package:zhuoyue_player/data/repositories/music_repository.dart';

/// 联网的集成测试。
///
/// 它验证的是整条最容易出问题的链路：拉起内嵌 Node 服务 → 走网易云接口
/// → 解析 → 拿到真实可播放地址。这条链路上任何一环坏了（端口、握手行、
/// 响应信封、字段名变更），纯单元测试都发现不了，只有真的连一次才知道。
///
/// 因为它依赖网络与 `runtime/`，默认**跳过**，显式开启：
///
/// ```powershell
/// $env:ZHY_LIVE_TESTS = '1'
/// flutter test test\integration
/// ```
///
/// 全部调用都是匿名可用的（搜索 / 歌单 / 播放地址 / 歌词），不需要凭据。
const String _enableFlag = 'ZHY_LIVE_TESTS';

/// 未开启时给每个用例的跳过原因。
final Object _skipReason = Platform.environment[_enableFlag] == '1'
    ? false
    : '联网集成测试：设置环境变量 $_enableFlag=1 后运行';

void main() {
  late EmbeddedNeteaseApi api;
  late NeteaseApiClient apiClient;
  late NeteaseRepository repository;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    api = EmbeddedNeteaseApi();
    final Dio dio = createZhyDio(receiveTimeout: const Duration(seconds: 30));
    apiClient = NeteaseApiClient(api, dio);
    repository = NeteaseRepository(
      apiClient,
      loginService: NeteaseLoginService(
        apiClient: apiClient,
        preferences: prefs,
      ),
    );
  });

  tearDownAll(() async {
    // 显式停掉本次测试用的实例。
    // （`EmbeddedNeteaseApi` 的构造函数也会把自己登记成活动实例，
    //   所以这里的 stop() 与 shutdownEmbeddedNeteaseApi() 是等价的；
    //   直接调 stop() 更直白，不依赖全局状态。）
    await api.stop();
  });

  test(
    '内嵌运行时能被找到并拉起（且并发调用只拉一个进程）',
    () async {
      expect(
        api.isAvailable,
        isTrue,
        reason: '找不到 runtime/。请先执行 pwsh -File scripts/fetch-runtime.ps1',
      );

      final int port = await api.ensureStarted();
      expect(port, greaterThan(0));
      expect(port, lessThan(65536));

      // 幂等性：再调一次必须复用同一个进程，而不是又拉一个 node。
      expect(await api.ensureStarted(), port);
      expect(api.runtimeDirectory, isNotNull);

      debugPrint('[live] 内嵌服务端口=$port，运行时=${api.runtimeDirectory}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skipReason,
  );

  test(
    '搜索能返回带封面的曲目',
    () async {
      final List<Song> songs = await repository.search('周杰伦', limit: 10);

      expect(songs, isNotEmpty);
      final Song first = songs.first;
      expect(first.title, isNotEmpty);
      expect(first.artists, isNotEmpty);
      expect(first.source.key, 'netease');
      // 封面是莫奈取色的输入：缺了它整个"封面驱动主题"的链路就断了，
      // 所以这里必须断言，而不是"有就用没有就算了"。
      expect(first.coverUrl, isNotNull);
      debugPrint('[live] 搜索首条：${first.title} — ${first.artistLabel}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skipReason,
  );

  test(
    '推荐歌单能取到集合，且集合内曲目可分页',
    () async {
      final List<MusicCollection> collections = await repository
          .discoverCollections();
      expect(collections, isNotEmpty);

      final MusicCollection first = collections.first;
      debugPrint(
        '[live] 推荐歌单 ${collections.length} 个，'
        '首个：${first.name}（${first.trackCount} 首）',
      );

      final CollectionTracksPage page = await repository.collectionTracks(
        first.id,
        limit: 10,
      );
      expect(page.songs, isNotEmpty);
      debugPrint('[live] 已取到 ${page.songs.length} 首，hasMore=${page.hasMore}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skipReason,
  );

  test(
    '能解析出真实的播放地址并带失效时间',
    () async {
      final List<Song> songs = await repository.search('晴天 周杰伦', limit: 5);
      expect(songs, isNotEmpty);

      final Song playable = songs.firstWhere(
        (Song s) => s.playable,
        orElse: () => songs.first,
      );
      final ResolvedStream stream = await repository.resolveStream(playable);

      expect(stream.url.scheme, anyOf('http', 'https'));
      expect(stream.url.host, isNotEmpty);
      // 网易云的直链带时效签名，必须带失效时间，否则播到一半会 403。
      expect(stream.expiresAt, isNotNull);
      expect(stream.isValidAt(DateTime.now()), isTrue);

      debugPrint(
        '[live] 播放地址：${stream.url.host}${stream.url.path} · '
        '${stream.bitrate} bps · ${stream.mimeType}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skipReason,
  );

  test(
    '歌词能解析成升序时间轴，并支持二分定位',
    () async {
      final List<Song> songs = await repository.search('晴天 周杰伦', limit: 5);
      final Lyric lyric = await repository.lyric(songs.first);

      expect(lyric.isEmpty, isFalse, reason: '这首应当有歌词');
      // 时间轴必须单调不减，否则歌词高亮的二分查找会错位。
      for (int i = 1; i < lyric.lines.length; i++) {
        expect(
          lyric.lines[i].start >= lyric.lines[i - 1].start,
          isTrue,
          reason: '第 $i 行时间倒退了',
        );
      }
      expect(lyric.indexAt(lyric.lines.first.start), 0);
      debugPrint(
        '[live] 歌词 ${lyric.lines.length} 行，'
        '翻译 ${lyric.translatedLines.length} 行',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skipReason,
  );

  test(
    '音质档位真的生效：无损不应低于极高',
    () async {
      final List<Song> songs = await repository.search('晴天 周杰伦', limit: 5);
      final Song song = songs.firstWhere(
        (Song s) => s.playable,
        orElse: () => songs.first,
      );

      await repository.setPreferredQuality('exhigh');
      final ResolvedStream exhigh = await repository.resolveStream(song);

      await repository.setPreferredQuality('lossless');
      final ResolvedStream lossless = await repository.resolveStream(song);

      await repository.setPreferredQuality(kAutoQualityId);

      debugPrint(
        '[live] 极高 br=${exhigh.bitrate} label=${exhigh.qualityLabel}'
        ' / 无损 br=${lossless.bitrate} label=${lossless.qualityLabel}',
      );

      expect(exhigh.qualityLabel, isNotNull);
      expect(lossless.bitrate, isNotNull);
      // 不断言"无损一定更高"：账号没有会员时服务端会静默降级成同码率。
      // 这里只断言"更高档位不会拿到更差的结果"，以及实际档位被如实报告。
      expect(
        lossless.bitrate! >= exhigh.bitrate!,
        isTrue,
        reason: '更高档位不应拿到更低码率（无损 ${lossless.bitrate} vs 极高 ${exhigh.bitrate}）',
      );
      expect(repository.audioQualities, isNotEmpty);
      expect(repository.effectiveQuality.id, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skipReason,
  );

  test(
    '歌单能一次取全（不再只取 50 首）',
    () async {
      final List<MusicCollection> collections = await repository
          .discoverCollections();
      // 挑一个体量明显大于一页的歌单，否则测不出"是否取全"。
      final MusicCollection big = collections.firstWhere(
        (MusicCollection c) => c.trackCount > 60,
        orElse: () => collections.first,
      );

      final List<Song> all = await repository.allCollectionTracks(big.id);
      debugPrint(
        '[live] ${big.name}：接口报 ${big.trackCount} 首，实取 ${all.length} 首',
      );

      expect(all, isNotEmpty);
      if (big.trackCount > 50) {
        expect(all.length > 50, isTrue, reason: '歌单页现在是一次取全，"播放全部"必须覆盖整个歌单');
      }
      // uid 不应重复 —— 翻页拼接时最容易出的错就是重复追加同一页。
      expect(all.map((Song s) => s.uid).toSet().length, all.length);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _skipReason,
  );

  test(
    '差量同步：首次全量、第二次只发 1 次分页请求',
    () async {
      final List<MusicCollection> collections =
          await repository.discoverCollections();
      final MusicCollection collection = collections.firstWhere(
        (MusicCollection c) => c.trackCount > 60,
        orElse: () => collections.first,
      );

      final Directory root = Directory.systemTemp.createTempSync('zhy_live_cache_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final CollectionCache cache = CollectionCache(root: root);

      // 第一次：没有缓存 → 全量取。
      final CollectionSyncOutcome first = await cache.computeCollectionSync(
        repository: repository,
        collection: collection,
        cached: const <Song>[],
      );
      expect(first.songs, isNotEmpty);

      // 第二次：拿第一次的结果当缓存 → 云端没变化，应当在第 1 页就停住。
      final CollectionSyncOutcome second = await cache.computeCollectionSync(
        repository: repository,
        collection: collection,
        cached: first.songs,
      );

      debugPrint(
        '[live] ${collection.name}：首次 ${first.pageRequests} 次请求取 '
        '${first.songs.length} 首；再次 ${second.pageRequests} 次请求，'
        '新增 ${second.added}、移除 ${second.removed}',
      );

      expect(second.added, 0, reason: '缓存就是刚同步的，不该有新增');
      expect(second.removed, 0, reason: '云端没变化，不该判定有删除');
      expect(
        second.songs.length,
        first.songs.length,
        reason: '没有变化时不能多也不能少 —— 少了就是"同步一次少一半歌"',
      );
      expect(
        second.pageRequests,
        1,
        reason: '这就是省请求的判据：第一页没有新 uid 就停',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _skipReason,
  );

  test(
    '未登录时「我的歌单」给出明确的鉴权错误',
    () async {
      expect(repository.isAuthenticated, isFalse);
      await expectLater(
        repository.myCollections(),
        throwsA(
          isA<Object>().having(
            (Object e) => e.toString(),
            'toString',
            contains('登录'),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skipReason,
  );
}
