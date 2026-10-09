import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/runtime/embedded_netease_api.dart';
import '../../core/storage/preferences.dart';
import '../models/audio_quality.dart';
import '../models/collection.dart';
import '../models/lyric.dart';
import '../models/media_source.dart';
import '../models/song.dart';
import '../repositories/music_repository.dart';
import 'netease_api_client.dart';
import 'netease_login.dart';
import 'netease_parsers.dart';

/// 网易云音源的 [MusicRepository] 实现。
///
/// 全部数据都来自内嵌的 Node 服务（见 [EmbeddedNeteaseApi]），这里只做三件事：
/// 1. 把领域方法映射到具体接口路径，并把分页 / 权限 / 登录态这些差异吃掉；
/// 2. 缓存那些"查一次就够"的东西（uid、歌单曲目总数、红心 id 集合），
///    否则滚动一次列表就能打出十几个重复请求；
/// 3. 未登录时抛出 [MusicApiException]（`isAuthError = true`），
///    让 UI 能把用户引导到登录页，而不是给一个"操作失败"。
///
/// 需要登录的方法：我的歌单、红心（读 / 写）、每日推荐、刷新账号。
/// 匿名可用的方法：搜索、联想、发现页（歌单流）、公开歌单的曲目、歌词、取直链。
class NeteaseRepository implements MusicRepository {
  NeteaseRepository(
    this._client, {
    required NeteaseLoginService loginService,
    SharedPreferences? preferences,
  }) : _login = loginService,
       _prefs = preferences;

  /// 歌单曲目总数缓存的有效期。歌单会被作者改动，但没必要每次翻页都问一次。
  static const Duration _likedCacheTtl = Duration(seconds: 30);

  final NeteaseApiClient _client;
  final NeteaseLoginService _login;
  final SharedPreferences? _prefs;

  final StreamController<AccountProfile?> _accountController =
      StreamController<AccountProfile?>.broadcast();

  /// 集合 id → 类型。`collectionTracks` 只拿得到一个 id 字符串，
  /// 得靠这份映射才知道该走歌单接口还是专辑接口。
  final Map<String, CollectionKind> _collectionKinds =
      <String, CollectionKind>{};

  /// 集合 id → 曲目总数，用于算分页 `hasMore`。
  final Map<String, int> _collectionTotals = <String, int>{};

  final Set<String> _likedIds = <String>{};
  DateTime? _likedFetchedAt;

  AccountProfile? _account;
  bool _authenticated = false;
  bool _disposed = false;

  // ---------------------------------------------------------------- 音质

  /// 网易云的音质档位，**从高到低**。
  ///
  /// `requiredVipLevel` 只作为「自动」档位的选择依据，不是权限判定：
  /// 真正能不能拿到这个码率永远由服务端决定（它会按账号权益降级），
  /// 所以这里的标注猜错也不会导致播不了，最多是自动档选得保守一点。
  static const List<AudioQuality> _qualities = <AudioQuality>[
    AudioQuality(
      id: 'jymaster',
      label: '超清母带',
      description: '最高规格，需要黑胶 SVIP',
      requiredVipLevel: 2,
    ),
    AudioQuality(
      id: 'sky',
      label: '高清臻音',
      description: '沉浸声规格，需要黑胶 SVIP',
      requiredVipLevel: 2,
    ),
    AudioQuality(
      id: 'hires',
      label: 'Hi-Res',
      description: '高于 CD 规格，需要黑胶 SVIP',
      requiredVipLevel: 2,
    ),
    AudioQuality(
      id: 'lossless',
      label: '无损',
      description: 'FLAC 无损，黑胶 VIP 即可',
      requiredVipLevel: 1,
    ),
    AudioQuality(id: 'exhigh', label: '极高', description: '320 kbps'),
    AudioQuality(id: 'higher', label: '较高', description: '192 kbps'),
    AudioQuality(id: 'standard', label: '标准', description: '128 kbps'),
  ];

  static const String _qualityPrefKey = 'audio.quality.netease';

  /// 「自动」观测到的可用上限的存储键。
  static const String _qualityCeilingPrefKey = 'audio.quality.netease.ceiling';

  String? _qualityIdCache;

  /// 观测到的上限缓存：null = 还没读过盘（与 [preferredQualityId] 同样的懒读写法）。
  /// 空串表示"确实没有记录"，此时上限回落到按会员等级猜的那一档。
  String? _ceilingIdCache;

  @override
  List<AudioQuality> get audioQualities => _qualities;

  @override
  String get preferredQualityId =>
      _qualityIdCache ??= _prefs?.getString(_qualityPrefKey) ?? kAutoQualityId;

  @override
  Future<void> setPreferredQuality(String qualityId) async {
    _qualityIdCache = qualityId;
    await _prefs?.setString(_qualityPrefKey, qualityId);
  }

  /// 账号的会员等级：0 普通、1 黑胶 VIP、2 黑胶 SVIP。
  int get _vipLevel {
    final String? label = _account?.vipLabel;
    if (label == null) return 0;
    // 服务端只给了个展示文案，只能据此判档；判不出来时按 1 处理，
    // 这样最多是自动档多试一个无损，不会因为保守而让 SVIP 用户拿不到无损。
    return label.toUpperCase().contains('SVIP') ? 2 : 1;
  }

  /// 按会员等级猜出来的"理论上最高可用档位"。
  ///
  /// 它只是自动档的**初始值**与**上限**：真正能不能拿到由服务端说了算，
  /// 连续观测到"只有免费档"时 [autoQualityCeiling] 会把它收下来。
  AudioQuality get _vipCeiling {
    final int level = _vipLevel;
    for (final AudioQuality quality in _qualities) {
      if (!quality.requiresVip(level)) return quality;
    }
    return _qualities.last;
  }

  /// 读盘的"观测上限"；空串 = 没有记录。
  String get _storedCeilingId =>
      _ceilingIdCache ??= _prefs?.getString(_qualityCeilingPrefKey) ?? '';

  /// 「自动」当前实际可用的最高档。界面与诊断都看这一个值。
  ///
  /// 取"按会员等级猜的上限"与"观测记录"里**更低**的那个：
  /// 会员等级保证不会越过账号权益，观测记录保证不会越过服务端真给的档位。
  /// 没有任何记录时就是按会员等级猜的那一档 —— 老用户的行为完全不变。
  AudioQuality get autoQualityCeiling {
    final AudioQuality guess = _vipCeiling;
    // 记录可能是别的账号 / 旧版本留下的，认不出来就当作没有记录。
    final AudioQuality? recorded = qualityById(_storedCeilingId);
    if (recorded == null) return guess;
    // qualityRank 是索引（越小越高），记录比理论上限还高时以理论上限为准。
    return qualityRank(recorded.id) < qualityRank(guess.id) ? guess : recorded;
  }

  @override
  AudioQuality get effectiveQuality {
    final String preferred = preferredQualityId;
    if (preferred != kAutoQualityId) {
      // 手动档位不受观测上限影响：用户明确选了哪一档就请求哪一档，
      // 服务端给不给我行我素，降级结果由 `ResolvedStream.qualityLabel` 如实展示。
      for (final AudioQuality quality in _qualities) {
        if (quality.id == preferred) return quality;
      }
    }
    // 自动：min(按会员等级猜的上限, 观测到的上限)，
    // 所以一旦观测认定"拿不到无损"，设置页那行会诚实地变成"极高"。
    return autoQualityCeiling;
  }

  /// 连续多少次"只能拿到免费档"才认定账号没有更高权益。
  ///
  /// 依据是实测数据（黑胶 VIP 账号抽 30 首）：**27 首无损、1 首只有 320k**、
  /// 2 首无版权。单曲没有无损是常态，所以门槛必须同时满足两点：
  /// 连续 [kAutoQualityDowngradeStreak] 次、且每次都只到免费档
  /// （见 [kAutoQualityDegradeFloorId]）。真正的"权益没被识别"是清一色的
  /// 免费档，不会夹杂无损。
  static const int _downgradeStreakLimit = kAutoQualityDowngradeStreak;

  /// 连续降级的计数。
  ///
  /// 刻意**不持久化**：它是个瞬时量，重启后从 0 重新累计即可 ——
  /// 要把这个中间状态写盘，就还得处理"计数写了一半应用被杀"的一致性问题，
  /// 而它最多让判定晚几首歌生效。
  int _downgradeStreak = 0;

  /// 上限写盘的串行链。
  ///
  /// 不直接 `unawaited(_prefs.setString(...))`：两次观测的写盘都是异步的，
  /// 完成顺序没有保证，可能出现"后一次观测先写完、前一次后写完"，把盘上的
  /// 值回退成旧的（后发先至）。串成一条链就与内存里的更新顺序一致了。
  Future<void> _qualityWriteChain = Future<void>.value();

  /// 等待上限写盘落地（测试与诊断用；播放路径不需要等它）。
  Future<void> get qualityStateSettled => _qualityWriteChain;

  /// 记一次"请求 X，服务端实际给了 Y"。
  ///
  /// 只在自动档调用：手动档是用户明确点的，服务端降级只影响这一首的展示
  /// （`ResolvedStream.qualityLabel`），不该反过来改用户没在看的「自动」。
  ///
  /// [actualId] 为 null 表示这次没有权威信号（走了不带 `level` 的老接口），
  /// 那就什么都不做 —— 宁可不动上限，也不要靠猜去改它。
  ///
  /// 并发：`resolveStream` 会被并发调用（预解析下一首 + 当前曲目），但下面这段
  /// 读改写是**同步**的（中间没有 await），Dart 的单线程事件循环里它是原子的，
  /// 两次观测不会交错把计数写乱；真正的并发风险只在写盘顺序上，那个交给
  /// [_qualityWriteChain]。也就是说：接受"并发观测按完成先后依次生效"这个取舍，
  /// 而不是给整个 resolveStream 加锁（那会平白让预解析排队）。
  void _observeQuality({required String requestedId, required String? actualId}) {
    if (actualId == null) return;

    final int streakBefore = _downgradeStreak;
    final QualityCeilingUpdate update = applyQualityObservation(
      currentCeilingId: autoQualityCeiling.id,
      requestedId: requestedId,
      actualId: actualId,
      streak: streakBefore,
      maxCeilingId: _vipCeiling.id,
      streakLimit: _downgradeStreakLimit,
    );

    final int actualRank = qualityRank(actualId);
    final int requestedRank = qualityRank(requestedId);
    if (actualRank != requestedRank &&
        actualRank != kUnknownQualityRank &&
        requestedRank != kUnknownQualityRank) {
      // 低于预期时把连续次数一起写出来：只看一首判断不了是单曲差异
      // 还是账号权益，连着看才看得出来。
      //
      // 但只有"落到免费档"的那一类才真的计入连续次数（判据见
      // [applyQualityObservation]）。措辞必须与计数一致，否则日志会
      // 把人带偏：看到"连续第 1 次"却半天不降级，会以为计数坏了。
      final String detail;
      if (actualRank > requestedRank) {
        detail = actualRank >= qualityRank(kAutoQualityDegradeFloorId)
            ? '（连续第 ${streakBefore + 1} 次低于预期）'
            : '（低于预期，但仍在免费档以上，不计数）';
      } else {
        detail = '（高于预期）';
      }
      debugPrint('[netease] 请求 $requestedId 实际返回 $actualId$detail');
    }

    final String ceilingBefore = autoQualityCeiling.id;
    _downgradeStreak = update.streak;
    _ceilingIdCache = update.ceilingId;
    if (update.ceilingId != ceilingBefore) {
      // 这一条会出现在应用内调试日志面板里，用户能看懂"自动档为什么变了"。
      debugPrint(
        '[netease] 自动音质上限调整为 '
        '${qualityById(update.ceilingId)?.label ?? update.ceilingId}',
      );
      _persistCeiling(update.ceilingId);
    }
  }

  /// 排队把上限写盘。写盘失败只记日志：它不影响这次播放。
  void _persistCeiling(String ceilingId) {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return; // 没注入持久化（部分测试）：只留内存值
    _qualityWriteChain = _qualityWriteChain
        .then<void>((void _) async {
          await prefs.setString(_qualityCeilingPrefKey, ceilingId);
        })
        .catchError((Object error) {
          debugPrint('[netease] 自动音质上限写盘失败，已忽略：$error');
        });
  }

  /// 丢掉观测到的上限（换账号时用）。
  ///
  /// 一个账号"要不到无损"推不出另一个账号也拿不到；更要紧的是这个上限只会
  /// 单向收紧（自动档请求的就是上限本身，服务端不可能给出比请求更高的档位），
  /// 跨账号继承下来就再也回不去了。
  void _resetObservedCeiling() {
    if (_downgradeStreak == 0 && _storedCeilingId.isEmpty) return;
    _downgradeStreak = 0;
    _ceilingIdCache = '';
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    _qualityWriteChain = _qualityWriteChain
        .then<void>((void _) async {
          await prefs.remove(_qualityCeilingPrefKey);
        })
        .catchError((Object error) {
          debugPrint('[netease] 清理自动音质上限失败，已忽略：$error');
        });
  }

  /// 自动档的兜底档位。
  ///
  /// 自动挑的是 [autoQualityCeiling]（该账号观测到的上限），万一服务端因为
  /// 权益对不上而返回不了音源，就退到 320k 再试一次 —— 宁可音质低一档，
  /// 也不能让一首本来能播的歌因为"音质偏好"而播不出来。
  ///
  /// 它恰好等于 [kAutoQualityDegradeFloorId]（免费账号的上限），这不是巧合：
  /// 兜底要的就是"几乎人人都拿得到"的那一档。
  static const String _fallbackQualityId = 'exhigh';

  /// 会话是否已经校验过（无论结果如何）。避免每次调用接口都白跑一次 /login/status。
  bool _sessionChecked = false;
  Future<void>? _sessionRestore;
  String? _uid;

  @override
  MediaSource get source => MediaSource.netease;

  @override
  AccountProfile? get account => _account;

  /// cookie 存在 **且** 最近一次账号校验成功。
  ///
  /// 只看 cookie 是不够的：cookie 可能已经过期，那时候界面该显示登录入口，
  /// 而不是让用户点进每个页面都吃一个 301。
  /// 登录流程结束后由调用方显式调一次 [refreshAccount]（或任意一个数据方法）
  /// 来刷新这个状态 —— 登录服务写下的凭据与账号信息都在它自己手里。
  @override
  bool get isAuthenticated => _client.hasCookie && _authenticated;

  /// 账号变化广播：登录 / 退出 / 凭据失效都会推一次。
  @override
  Stream<AccountProfile?> get accountChanges => _accountController.stream;

  /// 释放资源（关闭账号广播流）。由 Provider 在销毁时调用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_accountController.close());
  }

  /// 登记一个集合 id 的类型。
  ///
  /// 网易云的 id 空间在不同实体间会**重叠**（同一个数字既是某张专辑、
  /// 又是某个歌单），所以只凭 [collectionTracks] 的参数无法判断该走哪个接口。
  /// 本类列出的集合会自动登记；界面若自己拼了一个专辑集合
  /// （例如从某首歌的 `albumId`），先调这里登记一下再取曲目。
  void rememberCollectionKind(String collectionId, CollectionKind kind) {
    if (collectionId.isEmpty) return;
    _collectionKinds[collectionId] = kind;
  }

  // -------------------------------------------------------------------- 账号

  @override
  Future<AccountProfile?> refreshAccount() async {
    await _ensureSession();
    if (!_client.hasCookie) {
      _setSession(profile: null, authenticated: false);
      return null;
    }
    try {
      final Map<String, Object?> body = await _client.get(
        '/login/status',
        bypassCache: true,
        receiveTimeout: const Duration(seconds: 20),
      );
      final AccountProfile? profile = tryParseProfile(body);
      _uid = profile?.userId;
      _setSession(profile: profile, authenticated: profile != null);
      return profile;
    } on MusicApiException catch (error) {
      if (!error.isAuthError) rethrow;
      // cookie 已经不被服务端认了，清掉本地凭据并回到未登录状态。
      await _login.forgetSession();
      _setSession(profile: null, authenticated: false);
      return null;
    }
  }

  @override
  Future<void> logout() async {
    await _login.logout();
    _sessionChecked = true; // 已经确认是未登录状态，不必再去校验
    _likedIds.clear();
    _likedFetchedAt = null;
    _uid = null;
    _setSession(profile: null, authenticated: false);
  }

  // ------------------------------------------------------------------ 我的

  @override
  Future<List<MusicCollection>> myCollections() async {
    await _ensureSession();
    if (!isAuthenticated) {
      throw _authRequired('请先登录网易云账号，登录后才能查看我的歌单');
    }

    final String uid = await _requireUid();
    final Map<String, Object?> body = await _client.get(
      '/user/playlist',
      query: <String, Object?>{'uid': uid, 'limit': 1000, 'offset': 0},
      receiveTimeout: const Duration(seconds: 30),
    );

    final List<MusicCollection> favorites = <MusicCollection>[];
    final List<MusicCollection> others = <MusicCollection>[];
    for (final Map<String, Object?> item in asMapList(body['playlist'])) {
      final bool isFavorite = asInt(item['specialType']) == 5;
      final MusicCollection collection = parsePlaylist(
        item,
        kind: isFavorite ? CollectionKind.favorite : CollectionKind.playlist,
      );
      if (collection.id.isEmpty) continue;
      _rememberCollection(collection);
      (isFavorite ? favorites : others).add(collection);
    }

    // 「我喜欢的音乐」置顶：它是使用频率最高的入口，混在几十个歌单里很难找。
    // 这里用两个列表拼接而不是 sort，是为了保持接口返回的原始顺序（sort 不稳定）。
    return <MusicCollection>[...favorites, ...others];
  }

  // ------------------------------------------------------------------ 曲目

  /// 一次取回整个集合的曲目。
  ///
  /// 网易云的 `/playlist/track/all` 支持很大的 `limit`，所以正常情况下
  /// 一两次请求就能拿完；这里仍然写成循环，是为了对"服务端悄悄截断
  /// limit"这种情况保持正确 —— 靠单次请求拿全，一旦对方改了上限就会
  /// 静默少歌，而少歌是很难被发现的。
  @override
  Future<List<Song>> allCollectionTracks(
    String collectionId, {
    int maxSongs = 3000,
  }) async {
    const int pageSize = 500;
    final List<Song> all = <Song>[];
    int offset = 0;

    while (all.length < maxSongs) {
      final CollectionTracksPage page = await collectionTracks(
        collectionId,
        offset: offset,
        limit: pageSize,
      );
      all.addAll(page.songs);
      if (!page.hasMore || page.songs.isEmpty) break;
      offset += page.songs.length;
    }

    if (all.length > maxSongs) return all.sublist(0, maxSongs);
    return all;
  }

  @override
  Future<CollectionTracksPage> collectionTracks(
    String collectionId, {
    int offset = 0,
    int limit = 50,
  }) async {
    await _ensureSessionQuietly();
    if (collectionId.isEmpty) {
      return const CollectionTracksPage(songs: <Song>[]);
    }

    // 只有在通过 myCollections / discoverCollections 见过这个集合时才知道类型。
    final CollectionKind? known = _collectionKinds[collectionId];
    if (known == CollectionKind.album) {
      return _albumTracks(collectionId, offset: offset, limit: limit);
    }
    if (known == CollectionKind.chart) {
      // 榜单要用详情接口里的 trackCount 才能算 hasMore，且只在第一次取。
      await _warmPlaylistTotal(collectionId);
    }

    try {
      return await _playlistTracks(collectionId, offset: offset, limit: limit);
    } on MusicApiException {
      // 类型未知的 id（例如界面直接拿某首歌的 albumId 拼出来的专辑集合）
      // 在歌单接口上必然失败，退回专辑接口再试一次。
      if (known == null) {
        return _albumTracks(collectionId, offset: offset, limit: limit);
      }
      rethrow;
    }
  }

  Future<CollectionTracksPage> _playlistTracks(
    String collectionId, {
    required int offset,
    required int limit,
  }) async {
    // 多要一条：网易云的分页接口不回总数，多取一条就能判断"后面还有没有"。
    final Map<String, Object?> body = await _client.get(
      '/playlist/track/all',
      query: <String, Object?>{
        'id': collectionId,
        'limit': limit + 1,
        'offset': offset,
      },
      receiveTimeout: const Duration(seconds: 30),
    );

    final List<Song> parsed = parseSongs(body, hasVip: _hasVip);
    final bool probedMore = parsed.length > limit;
    final List<Song> songs = probedMore ? parsed.sublist(0, limit) : parsed;

    final int? total = _collectionTotals[collectionId];
    return CollectionTracksPage(
      songs: songs,
      // 有总数就用总数（更准），没有就用"多取一条"的结果推。
      hasMore: total != null ? offset + songs.length < total : probedMore,
      total: total,
    );
  }

  /// 专辑曲目。`/album` 不支持分页，只能整张取回再本地切片。
  Future<CollectionTracksPage> _albumTracks(
    String albumId, {
    required int offset,
    required int limit,
  }) async {
    final Map<String, Object?> body = await _client.get(
      '/album',
      query: <String, Object?>{'id': albumId},
      receiveTimeout: const Duration(seconds: 30),
    );

    final List<Song> all = parseSongs(body, hasVip: _hasVip);
    final int total = asInt(asMap(body['album'])?['size']) ?? all.length;
    final List<Song> page = all.skip(offset).take(limit).toList();
    return CollectionTracksPage(
      songs: page,
      hasMore: offset + page.length < total,
      total: total,
    );
  }

  /// 取一次歌单详情，仅为了拿到 trackCount（详情响应很大，所以只取一次）。
  Future<void> _warmPlaylistTotal(String collectionId) async {
    if (_collectionTotals.containsKey(collectionId)) return;
    try {
      final Map<String, Object?> body = await _client.get(
        '/playlist/detail',
        query: <String, Object?>{'id': collectionId},
        receiveTimeout: const Duration(seconds: 30),
      );
      final Map<String, Object?>? playlist = asMap(body['playlist']);
      final int? total = asInt(playlist?['trackCount']);
      if (total != null) _collectionTotals[collectionId] = total;
    } on MusicApiException {
      // 拿不到总数不影响播放，退化成"多取一条"的推断即可。
    }
  }

  // ------------------------------------------------------------------ 发现

  @override
  Future<List<DiscoverFeed>> discover() async {
    await _ensureSessionQuietly();

    // 三个分区并行取：任何一个失败都只影响它自己（副标题写明原因），
    // 不能因为"每日推荐拿不到"就让整个发现页空白。
    return Future.wait(<Future<DiscoverFeed>>[
      _dailyFeed(),
      _songFeed(
        '新歌速递',
        '刚刚上架的新歌',
        () => _client.get(
          '/personalized/newsong',
          query: <String, Object?>{'limit': 30},
          receiveTimeout: const Duration(seconds: 30),
        ),
      ),
      _songFeed(
        '新歌榜',
        '按地区实时更新',
        () => _client.get(
          '/top/song',
          query: <String, Object?>{'type': 0},
          receiveTimeout: const Duration(seconds: 30),
        ),
        // /top/song 服务端不支持 limit（模块里把 limit 注释掉了），本地截断。
        limit: 30,
      ),
    ]);
  }

  Future<DiscoverFeed> _dailyFeed() async {
    if (!isAuthenticated) {
      return const DiscoverFeed(
        title: '每日推荐',
        subtitle: '登录后根据你的口味生成',
        songs: <Song>[],
        source: MediaSource.netease,
      );
    }
    return _songFeed(
      '每日推荐',
      '根据你的口味生成',
      () => _client.get(
        '/recommend/songs',
        bypassCache: true,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
  }

  Future<DiscoverFeed> _songFeed(
    String title,
    String subtitle,
    Future<Map<String, Object?>> Function() load, {
    int? limit,
  }) async {
    try {
      final Map<String, Object?> body = await load();
      List<Song> songs = parseSongs(body, hasVip: _hasVip);
      if (limit != null && songs.length > limit) {
        songs = songs.sublist(0, limit);
      }
      return DiscoverFeed(
        title: title,
        subtitle: subtitle,
        songs: songs,
        source: MediaSource.netease,
      );
    } on MusicApiException catch (error) {
      // 单个分区失败（未登录 / 风控 / 网络抖动）不该让整页空掉：
      // 把原因写进副标题，其余分区照常展示。
      return DiscoverFeed(
        title: title,
        subtitle: error.message,
        songs: const <Song>[],
        source: MediaSource.netease,
      );
    }
  }

  @override
  Future<List<MusicCollection>> discoverCollections() async {
    await _ensureSessionQuietly();

    final List<Map<String, Object?>> pages = await Future.wait(
      <Future<Map<String, Object?>>>[
        // 个性化推荐在前：它比"热门"更贴近用户。
        _client.get(
          '/personalized',
          query: <String, Object?>{'limit': 12},
          receiveTimeout: const Duration(seconds: 30),
        ),
        _client.get(
          '/top/playlist',
          query: <String, Object?>{'limit': 30, 'order': 'hot'},
          receiveTimeout: const Duration(seconds: 30),
        ),
      ],
    );

    final List<MusicCollection> result = <MusicCollection>[];
    final Set<String> seen = <String>{};
    for (final Map<String, Object?> body in pages) {
      // /personalized 用 result，/top/playlist 用 playlists。
      final List<Map<String, Object?>> items = asMapList(
        body['result'] ?? body['playlists'],
      );
      for (final Map<String, Object?> item in items) {
        final MusicCollection collection = parsePlaylist(
          item,
          kind: CollectionKind.playlist,
        );
        if (collection.id.isEmpty || !seen.add(collection.id)) continue;
        _rememberCollection(collection);
        result.add(collection);
      }
    }
    return result;
  }

  // ------------------------------------------------------------------ 搜索

  @override
  Future<List<Song>> search(String keyword, {int limit = 30}) async {
    await _ensureSessionQuietly();
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) return const <Song>[];

    Map<String, Object?> body = await _client.get(
      '/cloudsearch',
      query: <String, Object?>{'keywords': trimmed, 'type': 1, 'limit': limit},
      receiveTimeout: const Duration(seconds: 30),
    );

    // 极少数版本里 cloudsearch 的结构不一样（没有 result.songs），
    // 这时退回老搜索接口，它的字段形态不同但解析器都吃得住。
    final bool hasSongList = asMap(body['result'])?['songs'] is List;
    if (!hasSongList) {
      body = await _client.get(
        '/search',
        query: <String, Object?>{
          'keywords': trimmed,
          'type': 1,
          'limit': limit,
        },
        receiveTimeout: const Duration(seconds: 30),
      );
    }

    return parseSongs(body, hasVip: _hasVip);
  }

  @override
  Future<List<String>> searchSuggestions(String keyword) async {
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) return const <String>[];

    try {
      await _ensureSessionQuietly();
      final Map<String, Object?> body = await _client.get(
        '/search/suggest',
        query: <String, Object?>{'keywords': trimmed, 'type': 'mobile'},
        receiveTimeout: const Duration(seconds: 12),
      );
      final Map<String, Object?>? result = asMap(body['result']);

      final List<String> words = <String>[];
      void add(Object? value) {
        final String? word = asString(value);
        if (word != null && !words.contains(word)) words.add(word);
      }

      // mobile 形态：result.allMatch[].keyword。
      for (final Map<String, Object?> item in asMapList(result?['allMatch'])) {
        add(item['keyword']);
      }
      // web 形态兜底：歌名 / 艺人名 / 专辑名。
      if (words.isEmpty) {
        for (final Map<String, Object?> item in asMapList(result?['songs'])) {
          add(item['name']);
        }
        for (final Map<String, Object?> item in asMapList(result?['artists'])) {
          add(item['name']);
        }
        for (final Map<String, Object?> item in asMapList(result?['albums'])) {
          add(item['name']);
        }
      }
      return words;
    } catch (error) {
      // 联想失败不能弹错误框：用户一边打字一边报错是最烦人的体验。
      debugPrint('[netease] 搜索联想失败，已忽略：$error');
      return const <String>[];
    }
  }

  // -------------------------------------------------------------- 播放与歌词

  @override
  Future<ResolvedStream> resolveStream(Song song) async {
    if (song.id.isEmpty) {
      throw const MusicApiException(
        '曲目 id 为空，无法解析播放地址',
        source: MediaSource.netease,
      );
    }
    // 列表阶段已经判过"放不了"（版权下架 / 会员限制 / 需购买），
    // 这里直接给出原因，省掉一次注定失败的请求。
    if (!song.playable) {
      throw MusicApiException(
        song.unplayableReason ?? '版权受限或需要会员',
        source: MediaSource.netease,
      );
    }

    await _ensureSessionQuietly();

    // 按当前音质偏好取值。自动档取到的是 [autoQualityCeiling]（已经吃过历史
    // 观测），但服务端仍可能再降级，所以下面还要用响应里的 level 反查实际档位。
    final String level = effectiveQuality.id;
    final bool auto = preferredQualityId == kAutoQualityId;

    Future<Map<String, Object?>> requestUrl(String requestedLevel) =>
        _client.get(
          '/song/url/v1',
          query: <String, Object?>{'id': song.id, 'level': requestedLevel},
          receiveTimeout: const Duration(seconds: 30),
        );

    Map<String, Object?> body;
    try {
      body = await requestUrl(level);
    } on MusicApiException catch (error) {
      // v1 在个别版本 / 风控下会不可用，退回旧接口按码率取。
      debugPrint('[netease] song/url/v1 失败，改用旧接口：${error.message}');
      body = await _client.get(
        '/song/url',
        query: <String, Object?>{'id': song.id, 'br': 320000},
        receiveTimeout: const Duration(seconds: 30),
      );
    }

    ResolvedStream? stream;
    MusicApiException? failure;
    try {
      stream = parseSongUrl(body);
    } on MusicApiException catch (error) {
      // 解析失败不在这里抛：自动档还要退一档重试，而重试前必须先把
      // 这次失败的原因留住（重试也失败时要抛原始的、更准确的那条）。
      failure = error;
    }

    // 自动档拿不到音源时退一档重试：宁可音质低一点，也不能让一首本来
    // 能播的歌因为"音质偏好"而播不出来。
    if (stream == null && auto && level != _fallbackQualityId) {
      debugPrint(
        '[netease] $level 取音源失败（${failure!.message}），'
        '退回 $_fallbackQualityId',
      );
      try {
        body = await requestUrl(_fallbackQualityId);
        stream = parseSongUrl(body);
      } on MusicApiException {
        // 兜底也失败就保留原始结果：原始请求的错误更能说明问题
        // （"版权受限"比兜底的"暂无音源"有用得多）。
      }
    }

    if (stream == null) {
      // 拿不到直链：抛带中文原因的异常，UI 原样展示。
      throw failure!;
    }

    if (auto) {
      // 观测用的"请求档位"是**最初**请求的那一档：走了兜底重试时，兜底本身
      // 就是"这一档要不到"的证据，拿兜底档位去比会把这次信号抹掉。
      _observeQuality(
        requestedId: level,
        actualId: neteaseActualLevelId(body),
      );
    }
    return stream;
  }

  @override
  Future<Lyric> lyric(Song song) async {
    if (song.id.isEmpty) return const Lyric.empty();
    await _ensureSessionQuietly();

    final Map<String, Object?> body = await _client.get(
      '/lyric',
      query: <String, Object?>{'id': song.id},
      receiveTimeout: const Duration(seconds: 20),
    );

    final String lrc = asString(asMap(body['lrc'])?['lyric']) ?? '';
    if (lrc.isEmpty) {
      // 没有歌词不一定是出错：纯音乐 / 未收录都会走到这里。
      final bool instrumental =
          body['nolyric'] == true || body['pureMusic'] == true;
      return Lyric(lines: const <LyricLine>[], isPureMusic: instrumental);
    }

    return parseLrc(
      lrc,
      translatedLrc: asString(asMap(body['tlyric'])?['lyric']),
      romanizedLrc: asString(asMap(body['romalrc'])?['lyric']),
    );
  }

  // ------------------------------------------------------------------ 红心

  @override
  Future<bool> isLiked(Song song) async {
    await _ensureSession();
    if (!isAuthenticated) {
      throw _authRequired('请先登录网易云账号，登录后才能同步红心状态');
    }
    return (await _likedSet()).contains(song.id);
  }

  @override
  Future<void> setLiked(Song song, bool liked) async {
    await _ensureSession();
    if (!isAuthenticated) {
      throw _authRequired('请先登录网易云账号，登录后才能设置红心');
    }

    await _client.get(
      '/like',
      query: <String, Object?>{'id': song.id, 'like': liked ? 'true' : 'false'},
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 20),
    );

    // 本地同步改一份：刚点完红心马上再查时，不该因为 30 秒缓存拿到旧状态。
    if (liked) {
      _likedIds.add(song.id);
    } else {
      _likedIds.remove(song.id);
    }
    _likedFetchedAt = DateTime.now();
  }

  /// 红心 id 集合。收藏量可能上千条，每次点红心都拉一遍太浪费，
  /// 因此内存缓存 30 秒（超过时限再拉一次）。
  Future<Set<String>> _likedSet() async {
    final DateTime? fetchedAt = _likedFetchedAt;
    final bool fresh =
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _likedCacheTtl;
    if (fresh) return _likedIds;

    final String uid = await _requireUid();
    final Map<String, Object?> body = await _client.get(
      '/likelist',
      query: <String, Object?>{'uid': uid},
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 20),
    );

    _likedIds.clear();
    final Object? ids = body['ids'];
    if (ids is List) {
      for (final Object? item in ids) {
        final String? id = asString(item) ?? asInt(item)?.toString();
        if (id != null) _likedIds.add(id);
      }
    }
    _likedFetchedAt = DateTime.now();
    return _likedIds;
  }

  // -------------------------------------------------------------------- 内部

  bool get _hasVip => _account?.vipLabel != null;

  /// 强制要求登录的异常。文案交给调用方，因为"为什么需要登录"每个入口都不同。
  MusicApiException _authRequired(String message) {
    return MusicApiException(
      message,
      source: MediaSource.netease,
      code: 301,
      isAuthError: true,
    );
  }

  void _rememberCollection(MusicCollection collection) {
    _collectionKinds[collection.id] = collection.kind;
    if (collection.trackCount > 0) {
      _collectionTotals[collection.id] = collection.trackCount;
    }
  }

  void _setSession({
    required AccountProfile? profile,
    required bool authenticated,
  }) {
    final String? previousUid = _account?.uid;
    final String? nextUid = profile?.uid;
    // 换账号（uid 变了）时丢掉上一个账号观测出来的上限：那是"那个账号能拿到
    // 什么"的结论，跨账号复用会把新账号也按旧账号的水平压着。只认"两个 uid
    // 都非空且不同"，所以冷启动（null → 有值）与退出登录都不会误清。
    if (previousUid != null && nextUid != null && previousUid != nextUid) {
      _resetObservedCeiling();
    }
    _account = profile;
    _authenticated = authenticated && profile != null;
    if (!_disposed && !_accountController.isClosed) {
      // 广播给 UI：登录 / 退出 / 换账号都能立刻反映到界面上。
      _accountController.add(_account);
    }
  }

  /// 首次调用时恢复本地 cookie 并校验；之后就是空操作。
  ///
  /// 每次都会先做一次零成本的"登录服务同步"：二维码/手机号登录成功后，
  /// 凭据与账号信息是登录服务写下的，repository 并不知道。如果只靠调用方
  /// 记得再调一次 [refreshAccount]，很容易出现"刚登录完列表还是空的"。
  Future<void> _ensureSession() {
    _syncFromLoginService();
    if (_sessionChecked) return Future<void>.value();
    final Future<void>? pending = _sessionRestore;
    if (pending != null) return pending;

    final Future<void> restore = _restoreSession();
    _sessionRestore = restore;
    unawaited(restore.then<void>((void _) {}, onError: (Object _) {}));
    return restore.whenComplete(() {
      if (identical(_sessionRestore, restore)) _sessionRestore = null;
    });
  }

  /// 把登录服务刚拿到的账号信息同步进来（不联网）。
  void _syncFromLoginService() {
    final AccountProfile? profile = _login.cachedProfile;
    if (profile == null || !_client.hasCookie) return;
    if (_authenticated && _account?.uid == profile.uid) return;
    _uid = profile.userId;
    _setSession(profile: profile, authenticated: true);
  }

  /// 匿名也能用的方法用这个：会话恢复失败（例如内嵌服务没起来）时不要挡路，
  /// 真正的错误会在紧随其后的接口调用里以更准确的文案抛出。
  Future<void> _ensureSessionQuietly() async {
    try {
      await _ensureSession();
    } on MusicApiException {
      // 忽略：请求本身会报错。
    }
  }

  Future<void> _restoreSession() async {
    // 先用本地缓存的账号信息点亮界面，再联网校验（冷启动能省一次闪烁）。
    // 前提是本地确实存着凭据，否则会出现"未登录却先显示账号卡片"。
    if (_account == null && _login.hasStoredCookie) {
      final AccountProfile? cached = _login.readCachedProfile();
      if (cached != null) {
        _account = cached;
        _uid = cached.userId;
        _setSession(profile: cached, authenticated: true);
      }
    }

    final String? cookie = await _login.restore();
    if (cookie == null) {
      _authenticated = false;
      _uid = null;
      _setSession(profile: null, authenticated: false);
      _sessionChecked = true;
      return;
    }

    final AccountProfile? profile = _login.cachedProfile;
    _uid = profile?.userId ?? _uid;
    _setSession(
      profile: profile ?? _account,
      authenticated: (profile ?? _account) != null,
    );
    _sessionChecked = true;
  }

  /// 取当前用户 id。缓存起来是因为 `/user/account` 只需要问一次。
  Future<String> _requireUid() async {
    final String? cached = _uid;
    if (cached != null && cached.isNotEmpty) return cached;

    final Map<String, Object?> body = await _client.get(
      '/user/account',
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 20),
    );
    final AccountProfile? profile = tryParseProfile(body);
    final Map<String, Object?>? raw = asMap(body['account']);
    final String? uid =
        profile?.userId ??
        asString(raw?['id']) ??
        asInt(raw?['id'])?.toString();
    if (uid == null) {
      throw _authRequired('登录状态已失效，请重新登录');
    }

    _uid = uid;
    if (profile != null) {
      _setSession(profile: profile, authenticated: true);
    }
    return uid;
  }
}

// ------------------------------------------------------- 音质档位（纯逻辑）
//
// 这几个函数刻意放在类外面，因为"自动档能不能降级"必须是纯函数：
// 判据一旦写错（把"某首歌没有无损"当成"账号没有无损"），用户的无损会被
// 静默降成 320k，而且现场很难复现 —— 到底是哪几首歌触发的，事后无从查起。
// 抽成纯函数就能把所有分支钉死在单测里，不用联网、不用起内嵌服务。

/// 连续多少次"只能拿到免费档"才认定账号没有更高权益。
///
/// 8 这个数字来自实测：黑胶 VIP 账号「君游虚无」抽 30 首，27 首是正常无损、
/// 1 首只有 320k、2 首无版权。单曲没有无损很常见，但**不会连续 8 首**；
/// 而真的"权益没被识别"时是清一色的免费档。门槛取小了（例如 3）会把
/// 那些本来能无损的歌一起打成 320k，比不改更糟。
const int kAutoQualityDowngradeStreak = 8;

/// 「免费账号就能拿到」的上限档位。
///
/// 实测表明"实际只能给到这一档"才是权益信号：只要实际档位**高于**它
/// （无损及以上），就说明服务端认得这个账号的权益 —— 哪怕这次请求的档位
/// 要不到，那也只是单曲 / 档位差异，绝不能拿来降级。
const String kAutoQualityDegradeFloorId = 'exhigh';

/// 档位顺序之外的值：服务端回了我们没声明过的档位（例如 `jyeffect`）。
const int kUnknownQualityRank = 1 << 20;

/// 档位优先级：**索引越小档位越高**，顺序与 [NeteaseRepository.audioQualities] 一致。
///
/// 认不出来的 id 给 [kUnknownQualityRank]（比最低档还"低"），这样调用方必须先
/// 判未知再比较，不会把陌生档位误当成最低档去降级。
int qualityRank(String id) {
  for (int i = 0; i < NeteaseRepository._qualities.length; i++) {
    if (NeteaseRepository._qualities[i].id == id) return i;
  }
  return kUnknownQualityRank;
}

/// 按 id 取档位；认不出来时返回 null。
AudioQuality? qualityById(String id) {
  for (final AudioQuality quality in NeteaseRepository._qualities) {
    if (quality.id == id) return quality;
  }
  return null;
}

/// 优先级 → 档位 id。越界时夹到两端（调用方只应传 [qualityRank] 的结果）。
String qualityIdAtRank(int rank) {
  if (rank <= 0) return NeteaseRepository._qualities.first.id;
  if (rank >= NeteaseRepository._qualities.length) {
    return NeteaseRepository._qualities.last.id;
  }
  return NeteaseRepository._qualities[rank].id;
}

/// 一次观测给「自动」上限带来的变化（纯值，便于断言）。
@immutable
class QualityCeilingUpdate {
  const QualityCeilingUpdate({
    required this.ceilingId,
    required this.streak,
    required this.lowered,
  });

  /// 更新后的上限档位 id。
  final String ceilingId;

  /// 更新后的"连续只拿到免费档"计数。
  final int streak;

  /// 本次是否真的把上限降下来了（只有它需要写日志 / 落盘）。
  final bool lowered;
}

/// 根据一次"请求 [requestedId]、服务端实际给 [actualId]"算出新的上限。
///
/// 判定顺序即优先级：
/// 1. 认不出的档位不参与判断 —— 既不当最高也不当最低；
/// 2. 实际 == 请求：要到了，清零计数（这是真实数据里最常见的形态）；
/// 3. 实际 比 请求 高：按实际抬高，但不越过 [maxCeilingId]（按会员等级猜的
///    上限），清零计数；
/// 4. 实际 比 请求 低：
///    - 实际**高于** [degradeFloorId]（例如请求母带给了无损）→ 权益是被认的，
///      清零计数、上限不动，只当作单曲 / 档位差异；
///    - 实际 ≤ [degradeFloorId]（免费档）→ 计数 +1，连续 [streakLimit] 次才把
///      上限降到 [degradeFloorId] 并清零。
QualityCeilingUpdate applyQualityObservation({
  required String currentCeilingId,
  required String requestedId,
  required String actualId,
  required int streak,
  required String maxCeilingId,
  int streakLimit = kAutoQualityDowngradeStreak,
  String degradeFloorId = kAutoQualityDegradeFloorId,
}) {
  final int actualRank = qualityRank(actualId);
  final int requestedRank = qualityRank(requestedId);
  final int currentRank = qualityRank(currentCeilingId);
  final int maxRank = qualityRank(maxCeilingId);
  final int floorRank = qualityRank(degradeFloorId);

  QualityCeilingUpdate keep(int nextStreak) => QualityCeilingUpdate(
    ceilingId: currentCeilingId,
    streak: nextStreak,
    lowered: false,
  );

  // 认不出来就整条不判：宁可不动上限，也不要基于一个陌生字符串把用户的
  // 音质降下去（或者错误地抬上去）。
  if (actualRank == kUnknownQualityRank ||
      requestedRank == kUnknownQualityRank ||
      currentRank == kUnknownQualityRank ||
      maxRank == kUnknownQualityRank) {
    return keep(streak);
  }

  if (actualRank == requestedRank) {
    // 要到了：之前攒的"连续只有免费档"作废。
    return keep(0);
  }

  if (actualRank < requestedRank) {
    // 服务端给了比请求更高的档位（罕见）：按实际抬高，但不能越过按会员等级
    // 猜出来的上限 —— 否则一次异常响应就能让自动档超出账号权益。
    final int raised = actualRank < maxRank ? maxRank : actualRank;
    final int next = raised < currentRank ? raised : currentRank;
    return QualityCeilingUpdate(
      ceilingId: qualityIdAtRank(next),
      streak: 0,
      lowered: false,
    );
  }

  // 到这里一定是 actualRank > requestedRank：这一首要不到请求的档位。
  if (actualRank < floorRank) {
    // 只是没到请求的那一档，但高于免费档：服务端认得账号权益，
    // 这更像"这首歌没有更高规格"，不该算进"没权益"的连续计数。
    return keep(0);
  }

  final int nextStreak = streak + 1;
  if (nextStreak < streakLimit) return keep(nextStreak);

  // 清一色的免费档：这才是"权益没被识别"的形态，把自动档收到免费上限。
  // 落点用 [degradeFloorId] 而不是"这一次实际给到的档位"：单曲可能更低
  // （例如 192k），但账号权益未必只有 192k，按实际值降会白丢一档。
  final int loweredRank = floorRank < maxRank ? maxRank : floorRank;
  return QualityCeilingUpdate(
    ceilingId: qualityIdAtRank(loweredRank),
    streak: 0,
    lowered: loweredRank != currentRank,
  );
}

// ---------------------------------------------------------------------- LRC

/// LRC 时间标签：`[mm:ss]`、`[mm:ss.xxx]`、`[mm:ss:xxx]` 三种写法都吃。
final RegExp _kTimeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// 整体偏移标签 `[offset:-500]`。
final RegExp _kOffsetTag = RegExp(r'\[offset:\s*([+-]?\d+)\s*\]');

/// 解析 LRC 歌词。
///
/// 处理了这些真实存在的坑：
/// - `[offset:...]` 头部偏移，应用到每一行的 [LyricLine.start]；
/// - 一行挂多个时间标签（副歌复用同一句词），要展开成多行；
/// - `[mm:ss.5]` 这种不足三位的毫秒（`.5` 是 500ms 而不是 5ms）；
/// - 空文本行（间奏）保留，模型里用 `LyricLine.isMetadata` 区分；
/// - 每行的 [LyricLine.end] 由下一行的开始时间补出来（LRC 本身不带结束时间）；
/// - LRC 里行序不保证有序（尤其是翻译歌词），统一按时间排序。
///
/// 注意：只有制作信息（`作词 :` / `作曲 :`）的歌词**不算**纯音乐 ——
/// 大量歌曲都会带这几行，把它们当纯音乐会让用户看到"纯音乐"却其实有歌词。
/// 真正判纯音乐只看歌词体里有没有 `纯音乐` 字样。
Lyric parseLrc(String lrc, {String? translatedLrc, String? romanizedLrc}) {
  final String normalized = _normalize(lrc);
  if (normalized.trim().isEmpty) return const Lyric.empty();

  if (normalized.contains('纯音乐')) {
    // 纯音乐：保留"无歌词"的语义，让 UI 展示专门的占位而不是空白。
    return const Lyric(lines: <LyricLine>[], isPureMusic: true);
  }

  final Duration offset = _parseOffset(normalized);
  final List<LyricLine> lines = _parseTimedLines(normalized, offset);
  if (lines.isEmpty) return const Lyric.empty();

  return Lyric(
    lines: lines,
    translatedLines: translatedLrc == null
        ? const <LyricLine>[]
        : _parseTimedLines(
            translatedLrc,
            // 翻译歌词自带 offset 时按自己的算，再叠加主歌词的偏移才能对齐。
            _parseOffset(translatedLrc) + offset,
          ),
    romanizedLines: romanizedLrc == null
        ? const <LyricLine>[]
        : _parseTimedLines(romanizedLrc, _parseOffset(romanizedLrc) + offset),
    offset: offset,
  );
}

String _normalize(String source) =>
    source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

Duration _parseOffset(String source) {
  final RegExpMatch? match = _kOffsetTag.firstMatch(source);
  final int? ms = match == null ? null : int.tryParse(match.group(1)!);
  return Duration(milliseconds: ms ?? 0);
}

List<LyricLine> _parseTimedLines(String source, Duration offset) {
  final List<_TimedText> collected = <_TimedText>[];
  int order = 0;

  for (final String raw in _normalize(source).split('\n')) {
    final Iterable<RegExpMatch> tags = _kTimeTag.allMatches(raw);
    if (tags.isEmpty) continue;
    // 标签之后的才是歌词文本；一行多个标签时文本只写一次。
    final String text = raw.substring(tags.last.end).trim();
    for (final RegExpMatch tag in tags) {
      final int? ms = _tagToMs(tag);
      if (ms == null) continue;
      collected.add(_TimedText(_shift(ms, offset), text, order++));
    }
  }
  if (collected.isEmpty) return const <LyricLine>[];

  // 按时间排序；同一时间的保持原始出现顺序（Dart 的 sort 不稳定，
  // 所以把出现顺序一起参与比较，保证结果可复现）。
  collected.sort((_TimedText a, _TimedText b) {
    final int byTime = a.start.compareTo(b.start);
    return byTime != 0 ? byTime : a.order.compareTo(b.order);
  });

  // 同一行被重复标注（`[00:10.00][00:10.00] 词`）去个重。
  final List<_TimedText> unique = <_TimedText>[];
  for (final _TimedText item in collected) {
    if (unique.isNotEmpty &&
        unique.last.start == item.start &&
        unique.last.text == item.text) {
      continue;
    }
    unique.add(item);
  }

  final List<LyricLine> lines = <LyricLine>[];
  for (int i = 0; i < unique.length; i++) {
    lines.add(
      LyricLine(
        start: Duration(milliseconds: unique[i].start),
        // 结束时间 = 下一行的开始时间；最后一行没有结束时间。
        end: i + 1 < unique.length
            ? Duration(milliseconds: unique[i + 1].start)
            : null,
        text: unique[i].text,
      ),
    );
  }
  return lines;
}

int? _tagToMs(RegExpMatch tag) {
  final int? minutes = int.tryParse(tag.group(1)!);
  final int? seconds = int.tryParse(tag.group(2)!);
  if (minutes == null || seconds == null) return null;

  int millis = 0;
  final String? fraction = tag.group(3);
  if (fraction != null) {
    // 毫秒位是左对齐的：`.5` 是 500ms、`.50` 也是 500ms，
    // 直接 int.parse 会变成 5ms / 50ms，歌词会整体跑偏。
    millis = int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0;
  }
  return minutes * 60000 + seconds * 1000 + millis;
}

int _shift(int milliseconds, Duration offset) {
  final int shifted = milliseconds + offset.inMilliseconds;
  return shifted < 0 ? 0 : shifted;
}

/// 解析过程中的中间结构：时间 + 文本 + 出现顺序。
class _TimedText {
  const _TimedText(this.start, this.text, this.order);

  final int start;
  final String text;
  final int order;
}

/// 全局唯一的网易云 repository。
///
/// 注意它依赖的是**同一个** [NeteaseApiClient] 与 [NeteaseLoginService]：
/// cookie 存在客户端上，各自 new 一个的话登录完 repository 依旧没有凭据。
final Provider<NeteaseRepository> neteaseRepositoryProvider =
    Provider<NeteaseRepository>((Ref ref) {
      final NeteaseRepository repository = NeteaseRepository(
        ref.watch(neteaseApiClientProvider),
        loginService: ref.watch(neteaseLoginServiceProvider),
        // 注入偏好存储：音质偏好与「自动」观测到的上限都要落盘，
        // 否则每次重启都会退回到"按会员等级猜"的初始值。
        preferences: ref.watch(sharedPreferencesProvider),
      );
      ref.onDispose(repository.dispose);
      return repository;
    });
