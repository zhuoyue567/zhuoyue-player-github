import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/net/http_client.dart';
import '../../core/storage/preferences.dart';
import '../models/audio_quality.dart';
import '../models/collection.dart';
import '../models/lyric.dart';
import '../models/media_source.dart';
import '../models/song.dart';
import '../repositories/music_repository.dart';
import 'bilibili_api_client.dart';
import 'bilibili_login.dart';
import 'bilibili_parsers.dart';

/// 哔哩哔哩音源实现：收藏夹 → 曲目 → 播放地址。
///
/// 与网易云那一路最大的区别是**没有 Node 中转**，全部由 Dart 直连接口。
/// 因此这里必须自己承担三件在 Node 侧本来由库兜底的事：
/// 1. 防盗链头（`Referer` + 浏览器 UA），缺了 CDN 直接 403；
/// 2. cookie 与 CSRF（`bili_jct`）的携带；
/// 3. 播放地址的**过期重解析** —— 哔哩的地址是带签名的，过期后必然 403。
///
/// 关于「能播放什么」的边界，这里刻意做得保守：收藏夹里的失效稿件在
/// **列表阶段**就被标成 `playable: false`，而不是等用户点了才失败。
class BilibiliRepository implements MusicRepository {
  BilibiliRepository({
    required this._client,
    required this._auth,
    required this._preferences,
  });

  final BilibiliApiClient _client;
  final BilibiliLoginService _auth;
  final SharedPreferences _preferences;

  /// 界面上"要收藏到哪个收藏夹"的选择。
  static const String targetFolderPreferenceKey = 'bilibili.targetFolder';

  /// 播放地址缓存的有效期上限。
  ///
  /// 就算接口给的 `deadline` 更远，也只信 2 小时：签名地址既然会过期，
  /// 与其相信一个跨越半天的缓存，不如定期重解析一次（代价只有一个请求）。
  static const Duration _streamCacheTtl = Duration(hours: 2);

  final Map<String, _CachedStream> _streamCache = <String, _CachedStream>{};

  final StreamController<AccountProfile?> _accountController =
      StreamController<AccountProfile?>.broadcast();

  AccountProfile? _account;

  @override
  MediaSource get source => MediaSource.bilibili;

  /// 是否已登录。
  ///
  /// 判定依据是**账号信息是否已经成功拉取**，而不是"本地有没有 cookie"：
  /// cookie 还在但已被服务端作废时，说"已登录"只会让用户在点收藏的瞬间
  /// 撞上一个莫名其妙的错误。宁可先显示登录入口 —— 这也是为什么界面
  /// 启动时应该调一次 [refreshAccount]（或 `BilibiliLoginService.restore`）。
  @override
  bool get isAuthenticated => _account != null;

  @override
  AccountProfile? get account => _account;

  /// 账号变更广播。界面用 `StreamBuilder` 订阅即可，无需自己轮询。
  @override
  Stream<AccountProfile?> get accountChanges => _accountController.stream;

  /// 当前选定的收藏夹 id（未选择时为 null）。
  String? get targetFolderId =>
      asString(_preferences.getString(targetFolderPreferenceKey));

  /// 指定收藏到哪个收藏夹。
  ///
  /// 收藏接口必须给出一个明确的目标收藏夹；用户有多个收藏夹时，
  /// 由界面调用这个方法把选择固化下来。
  Future<void> setTargetFolder(String mediaId) async {
    await _preferences.setString(targetFolderPreferenceKey, mediaId);
  }

  @override
  Future<AccountProfile?> refreshAccount() async {
    final AccountProfile? profile = await _auth.fetchAccount();
    _account = profile;
    if (!_accountController.isClosed) _accountController.add(profile);
    return profile;
  }

  @override
  Future<void> logout() async {
    // cookie 都清了，缓存里的播放地址也不再属于这个账号，一并丢掉。
    _streamCache.clear();
    _account = null;
    await _auth.logout();
    if (!_accountController.isClosed) _accountController.add(null);
  }

  // -------------------------------------------------------------------------
  // 收藏夹
  // -------------------------------------------------------------------------

  @override
  Future<List<MusicCollection>> myCollections() async {
    final AccountProfile? profile = await _ensureAccount();
    if (profile == null) {
      throw const MusicApiException(
        '请先登录哔哩哔哩账号以读取收藏夹',
        source: MediaSource.bilibili,
        isAuthError: true,
      );
    }
    return _foldersOf(profile.userId);
  }

  /// 浏览**别人**的公开收藏夹（额外能力，不属于 [MusicRepository] 接口）。
  ///
  /// 实测公开收藏夹无需登录即可读取：`media_id=313087073` 返回了完整的
  /// `data.info` 与 `data.medias`。所以"看看别人整理的音乐收藏夹"是可行的。
  Future<List<MusicCollection>> publicCollections(String mid) =>
      _foldersOf(mid);

  /// 分页读取公开收藏夹内容（额外能力，`page` 从 1 开始）。
  Future<CollectionTracksPage> publicCollectionTracks(
    String mediaId, {
    int page = 1,
  }) {
    return _fetchTracks(mediaId, page: page <= 0 ? 1 : page, limit: 20);
  }

  Future<List<MusicCollection>> _foldersOf(String mid) async {
    final Map<String, Object?> body = await _client.getJson(
      '/x/v3/fav/folder/created/list-all',
      query: <String, dynamic>{'up_mid': mid},
    );
    // 实测：该账号没有收藏夹、或收藏夹未公开时，`data` 是 **null**（不是空数组），
    // 此时 `code` 仍然是 0。所以必须容错成空列表，而不是抛错。
    final List<Map<String, Object?>> list = asMapList(
      asMap(body['data'])['list'],
    );
    return list.map(parseFavFolder).toList(growable: false);
  }

  /// 一次取回整个收藏夹的曲目。
  ///
  /// 哔哩的 `ps` 有 40 的硬上限（`ps=41` 直接 `-400`），所以这里只能
  /// **顺序翻页**：348 首的收藏夹是 9 次请求。刻意不并发：
  /// 收藏夹接口属于风控重点，并发翻页很容易撞上 `-412`，
  /// 而顺序拉完也就一两秒。
  @override
  Future<List<Song>> allCollectionTracks(
    String collectionId, {
    int maxSongs = 3000,
  }) async {
    final List<Song> all = <Song>[];
    int offset = 0;

    while (all.length < maxSongs) {
      final CollectionTracksPage page = await collectionTracks(
        collectionId,
        offset: offset,
        limit: maxPageSize,
      );
      all.addAll(page.songs);
      if (!page.hasMore || page.songs.isEmpty) break;
      offset += page.songs.length;
    }

    if (all.length > maxSongs) return all.sublist(0, maxSongs);
    return all;
  }

  // ---------------------------------------------------------------- 音质

  /// 哔哩的音质档位，从高到低。
  ///
  /// 与前两家不同，哔哩的杜比与 Hi-Res **不是"请求参数"而是"服务端是否下发"**：
  /// `playurl` 只在账号有权益且稿件支持时，才会在 `dash.flac` / `dash.dolby`
  /// 里给出音轨。所以这里的档位只表达"优先要哪一个"，
  /// 拿不到时解析器会自动往下降，并把**实际**拿到的档位写进
  /// `ResolvedStream.qualityLabel`。
  static const List<AudioQuality> _qualities = <AudioQuality>[
    AudioQuality(
      id: 'hires',
      label: 'Hi-Res 无损',
      description: '需要大会员，且稿件本身提供无损音轨',
      requiredVipLevel: 1,
    ),
    AudioQuality(
      id: 'dolby',
      label: '杜比全景声',
      description: '需要大会员，且稿件本身提供杜比音轨',
      requiredVipLevel: 1,
    ),
    AudioQuality(id: 'default', label: '默认', description: '取稿件提供的最高码率音轨'),
  ];

  static const String _qualityPrefKey = 'audio.quality.bilibili';

  String? _qualityIdCache;

  @override
  List<AudioQuality> get audioQualities => _qualities;

  @override
  String get preferredQualityId => _qualityIdCache ??=
      asString(_preferences.getString(_qualityPrefKey)) ?? kAutoQualityId;

  @override
  Future<void> setPreferredQuality(String qualityId) async {
    _qualityIdCache = qualityId;
    await _preferences.setString(_qualityPrefKey, qualityId);
  }

  @override
  AudioQuality get effectiveQuality {
    final String preferred = preferredQualityId;
    if (preferred != kAutoQualityId) {
      for (final AudioQuality quality in _qualities) {
        if (quality.id == preferred) return quality;
      }
    }
    // 自动：直接要最高的那档。拿不到时解析器会降级，
    // 于是"自动"在无权益账号上等价于默认音轨，在有权益时自动吃到无损。
    return _qualities.first;
  }

  /// `fav/resource/list` 的 `ps`（每页条数）硬上限。  ///
  /// 实测边界非常干脆：`ps=40` 正常返回，`ps=41` 立刻变成
  /// `code=-400, message="请求错误"` —— 报错文案完全看不出是分页大小的问题，
  /// 排查时极容易误判成"cookie 失效"或"参数写错"。
  ///
  /// 更要命的是 [MusicRepository.collectionTracks] 的 `limit` 默认值是 50，
  /// 也就是说**不夹紧的话，用默认参数调这个接口必挂**。
  static const int maxPageSize = 40;

  @override
  Future<CollectionTracksPage> collectionTracks(
    String collectionId, {
    int offset = 0,
    int limit = 50,
  }) {
    // 接口的 `pn` 从 1 开始，而播放器内部用 0 基的 offset，这里做换算。
    final int pageSize = limit <= 0 ? 20 : limit.clamp(1, maxPageSize);
    final int page = (offset < 0 ? 0 : offset) ~/ pageSize + 1;
    return _fetchTracks(collectionId, page: page, limit: pageSize);
  }

  Future<CollectionTracksPage> _fetchTracks(
    String mediaId, {
    required int page,
    required int limit,
  }) async {
    final Map<String, Object?> body = await _client.getJson(
      '/x/v3/fav/resource/list',
      query: <String, dynamic>{
        'media_id': mediaId,
        'pn': '$page',
        // 再夹一次：这个方法是所有收藏夹读取的唯一出口，
        // 把上限守在这里，调用方传什么都不可能踩到 -400。
        'ps': '${limit.clamp(1, maxPageSize)}',
        'platform': 'web',
        'order': 'mtime',
        'type': '0',
        'tid': '0',
      },
    );

    // 实测：`media_id` 不存在时接口返回的是 `{"code":0,"message":"OK","data":null}`，
    // 也就是说"收藏夹没了"并不是错误码，而是一个空 data。这里必须当成空页处理。
    final Map<String, Object?> data = asMap(body['data']);
    if (data.isEmpty) {
      return const CollectionTracksPage(songs: <Song>[], hasMore: false);
    }

    final Map<String, Object?> info = asMap(data['info']);
    return CollectionTracksPage(
      songs: parseFavMedias(data['medias'], mid: asString(info['mid'])),
      hasMore: asBool(data['has_more']) ?? false,
      total: asInt(info['media_count']),
    );
  }

  // -------------------------------------------------------------------------
  // 发现页
  // -------------------------------------------------------------------------

  /// 哔哩**没有**音乐推荐流这种东西，所以这里返回空列表。
  ///
  /// 与其编一个"猜你喜欢"出来，不如让发现页老实地只展示网易云的内容：
  /// 伪造一个推荐流会让用户以为哔哩这边真的有算法推荐，
  /// 然后对着一堆莫名其妙的结果怀疑播放器坏了。
  @override
  Future<List<DiscoverFeed>> discover() async => const <DiscoverFeed>[];

  /// 同上：哔哩没有"推荐收藏夹"这类公开接口，不伪造。
  @override
  Future<List<MusicCollection>> discoverCollections() async =>
      const <MusicCollection>[];

  // -------------------------------------------------------------------------
  // 搜索
  // -------------------------------------------------------------------------

  /// 搜索稿件。
  ///
  /// **接口路径与需求文档里写的不一样，这是实测结论**：
  /// 文档写的 `/x/web-interface/search/type` 现在返回的是
  /// `HTTP 200 + text/html` 的一整页「出错啦! - aba.bilibili.com」，
  /// 根本不是 JSON；同参数换成 `/x/web-interface/wbi/search/type` 立刻
  /// 返回 `{"code":0,...,"data":{"result":[...20 条...]}}`。
  /// 所以这里用带 `wbi` 的路径，并按 WBI 规范签名（实测签名与不签名都能成功，
  /// 签名是为了不依赖服务端这个"宽松"行为）。
  ///
  /// 另外两点实测坑：
  /// - 标题里带 `<em class="keyword">` 高亮标签，必须先剥掉（见 [stripHtmlTags]）；
  /// - 时长字段是字符串 `"222:28"`，不是秒数（见 [parseDuration]）。
  ///
  /// 搜索结果**不带 cid**。给每一行都补一次 `view` 请求意味着一次搜索要发
  /// 30 个请求，既慢又极易触发风控，所以 cid 留到 [resolveStream] 里再懒加载。
  @override
  Future<List<Song>> search(String keyword, {int limit = 30}) async {
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) return const <Song>[];

    final Map<String, Object?> body = await _client.getJson(
      '/x/web-interface/wbi/search/type',
      query: <String, dynamic>{
        'search_type': 'video',
        'keyword': trimmed,
        'page': '1',
      },
      signed: true,
    );

    // 实测无结果时 `result` 会退化成一个纯空格**字符串**而不是数组，
    // asMapList 已经把这个情况吃掉了。
    final List<Map<String, Object?>> results = asMapList(
      asMap(body['data'])['result'],
    );

    final List<Song> songs = <Song>[];
    for (final Map<String, Object?> item in results) {
      if (songs.length >= limit) break;
      songs.add(_songFromSearchResult(item));
    }
    return songs;
  }

  Song _songFromSearchResult(Map<String, Object?> raw) {
    final int? aid = asInt(raw['aid']) ?? asInt(raw['id']);
    final String? bvid = asString(raw['bvid']);
    final String title = stripHtmlTags(asString(raw['title']) ?? '');
    final bool playable = bvid != null;

    return Song(
      id: bvid ?? 'av${aid ?? 0}',
      source: MediaSource.bilibili,
      title: title.isEmpty ? '未命名稿件' : title,
      artists: <String>[asString(raw['author']) ?? '未知 UP 主'],
      // 这里用「哔哩哔哩」而不是收藏夹那边的「哔哩哔哩收藏」：搜索结果
      // 未必来自收藏夹，标成"收藏"会误导用户以为它已经在自己的收藏里。
      album: '哔哩哔哩',
      coverUrl: normalizeCoverUrl(raw['pic']),
      duration: parseDuration(raw['duration']),
      playable: playable,
      unplayableReason: playable ? null : '该稿件缺少 bvid，无法解析播放地址',
      extra: <String, Object?>{
        'aid': aid,
        'bvid': bvid,
        'type': asString(raw['type']) ?? 'video',
        'isAudio': false,
        'upMid': asInt(raw['mid']),
        'playCount': asInt(raw['play']),
      },
    );
  }

  /// 哔哩没有一个"值得冒风险去调"的公开联想词接口。
  ///
  /// 能用的那几个（`s.search.bilibili.com` 系列）既没有稳定文档，
  /// 又需要额外的风控参数，实测失败率不低。搜索框不该因为联想失败而弹错，
  /// 所以直接返回空列表 —— 让用户把词打完，比给他一个时灵时不灵的联想更体面。
  @override
  Future<List<String>> searchSuggestions(String keyword) async =>
      const <String>[];

  // -------------------------------------------------------------------------
  // 播放地址
  // -------------------------------------------------------------------------

  /// 解析可播放地址。
  ///
  /// 缓存策略是本方法的核心，两个方向都必须做对：
  /// - **命中缓存且未过期**就直接复用：重复播放同一首歌不必再发请求。
  /// - **一旦过期必须重新解析**：哔哩的 CDN 地址是带签名的，签名过期后
  ///   必然 403。返回一个"看起来还在"的死链接，用户看到的是"点了没反应"，
  ///   这是最糟糕的失败方式 —— 所以宁可多请求一次。
  @override
  Future<ResolvedStream> resolveStream(Song song) async {
    final DateTime now = DateTime.now();
    final _CachedStream? cached = _streamCache[song.uid];
    if (cached != null && cached.isValidAt(now)) return cached.stream;

    final ResolvedStream stream = await _resolveRemote(song);
    _streamCache[song.uid] = _CachedStream(
      stream,
      DateTime.now().add(_streamCacheTtl),
    );
    return stream;
  }

  Future<ResolvedStream> _resolveRemote(Song song) {
    if (song.extra['isAudio'] == true) {
      return _resolveAudio(song);
    }
    return _resolveVideo(song);
  }

  /// 音频区条目：`sid` → 音频专有接口。
  ///
  /// **`platform=web` 是必需参数，不是可选装饰**。实测漏掉它时接口返回
  /// `{"code":72000000,"msg":null}`，而 `msg` 还是 null —— 光看响应完全
  /// 不知道少了什么。补上后才返回 `code: 0` 与 `data.cdns`。
  Future<ResolvedStream> _resolveAudio(Song song) async {
    final int? sid =
        asInt(song.extra['sid']) ??
        (song.id.startsWith('au') ? int.tryParse(song.id.substring(2)) : null);
    if (sid == null) {
      throw MusicApiException(
        '音频条目缺少 sid，无法解析播放地址',
        source: MediaSource.bilibili,
      );
    }

    final int? mid = asInt(song.extra['mid']);
    final Map<String, Object?> body = await _client.getJson(
      '/audio/music-service-c/url',
      query: <String, dynamic>{
        'songid': '$sid',
        'quality': '2',
        'privilege': '2',
        'mid': '${mid ?? 0}',
        'platform': 'web',
      },
    );
    return parseAudioUrl(body, referer: kBilibiliCdnReferer);
  }

  /// 视频稿件：先确保 bvid 与 cid，再取 DASH 音轨。
  Future<ResolvedStream> _resolveVideo(Song song) async {
    String? bvid =
        asString(song.extra['bvid']) ??
        (song.id.startsWith('BV') ? song.id : null);
    int? cid = asInt(song.extra['cid']);

    if (bvid == null || cid == null) {
      // 实测：`view` 接口 bvid 和 aid 都收（`?aid=80433022` → code 0，
      // 并且会把 bvid 一并返回），但 `playurl` **只认 bvid**
      // （用 `?aid=...` 查会拿到 `code: -400 请求错误`）。
      // 所以缺 bvid 时先用 aid 把它换出来，缺 cid 时顺路一起拿。
      final int? aid = asInt(song.extra['aid']);
      if (bvid == null && (aid == null || aid == 0)) {
        throw MusicApiException(
          '该条目缺少 bvid 与 aid，无法解析播放地址',
          source: MediaSource.bilibili,
        );
      }

      final BilibiliView view = parseView(
        await _client.getJson(
          '/x/web-interface/view',
          query: <String, dynamic>{
            if (bvid != null) 'bvid': bvid else 'aid': '$aid',
          },
        ),
      );
      bvid ??= view.bvid;
      // 多 P 合集必须按收藏时的那一 P 取 cid（实测有 151 P 的合集，
      // 如果一律用第一 P 的 cid，点第 37 首永远放第 1 首）。
      cid ??= view.cidForPage(asInt(song.extra['page']));

      if (bvid == null) {
        throw MusicApiException(
          '未能获取该稿件的 bvid，无法解析播放地址',
          source: MediaSource.bilibili,
        );
      }
      if (cid == null) {
        throw MusicApiException(
          '未能获取稿件 $bvid 的 cid，无法解析播放地址',
          source: MediaSource.bilibili,
        );
      }
    }

    final Map<String, Object?> dash = await _playurl(bvid, cid, fnval: '16');
    if (hasDashAudio(dash)) {
      return parseDashAudio(
        dash,
        referer: kBilibiliCdnReferer,
        qualityId: effectiveQuality.id,
      );
    }

    // 没有独立音轨时退回渐进式 mp4（`fnval=1`）。这条路径拿到的是混流文件，
    // **没有单独的音频轨**，码率等信息也拿不到，但至少能出声 —— 对会员/付费
    // 稿件来说这是唯一能播的可能性。
    final Map<String, Object?> progressive = await _playurl(
      bvid,
      cid,
      fnval: '1',
    );
    return parseDashAudio(progressive, referer: kBilibiliCdnReferer);
  }

  Future<Map<String, Object?>> _playurl(
    String bvid,
    int cid, {
    required String fnval,
  }) {
    return _client.getJson(
      '/x/player/playurl',
      query: <String, dynamic>{
        'bvid': bvid,
        'cid': '$cid',
        'fnval': fnval,
        'fnver': '0',
        'fourk': '1',
        'otype': 'json',
      },
    );
  }

  // -------------------------------------------------------------------------
  // 歌词
  // -------------------------------------------------------------------------

  /// 恒返回空歌词。
  ///
  /// 哔哩没有面向视频稿件的歌词接口（只有 UP 主自己上传的 CC 字幕，
  /// 而且并非所有稿件都有、格式也不统一）。歌词页应该显示「暂无歌词」，
  /// 而不是编一份出来或者把视频简介当歌词塞进去。
  @override
  Future<Lyric> lyric(Song song) async => const Lyric.empty();

  // -------------------------------------------------------------------------
  // 收藏状态
  // -------------------------------------------------------------------------

  /// 该条目是否已在当前账号的收藏夹里。
  ///
  /// 未登录一律 false（接口约定：这类查询失败不该让界面崩）。
  @override
  Future<bool> isLiked(Song song) async {
    final AccountProfile? profile = await _ensureAccount();
    if (profile == null) return false;

    final int? rid = asInt(song.extra['sid']) ?? asInt(song.extra['aid']);
    if (rid == null || rid == 0) return false;

    // 音频区（type 12）与普通稿件（type 2）要用不同的资源类型去查。
    final int type = song.extra['isAudio'] == true ? 12 : 2;

    final Object? data = await _client.getData(
      '/x/v3/fav/resource/ids',
      query: <String, dynamic>{'rid': '$rid', 'type': '$type'},
    );

    // 这个接口需要登录，实测未登录时返回 `code: -400`，因此上面必须先
    // 确认登录态，否则会把"没登录"误报成"请求参数错误"。
    //
    // 返回值的确切形状在未登录状态下无法验证，所以这里两种形态都兼容：
    // 纯 id 数组（`[313087073, ...]`）或对象数组（`[{"id":...}, ...]`）。
    final List<String> hitIds = <String>[];
    for (final Object? item in asList(data)) {
      if (item is Map) {
        final String? id =
            asString(asMap(item)['id']) ?? asString(asMap(item)['media_id']);
        if (id != null) hitIds.add(id);
      } else {
        final String? id = asString(item);
        if (id != null) hitIds.add(id);
      }
    }
    if (hitIds.isEmpty) return false;

    final List<MusicCollection> folders = await _foldersOf(profile.userId);
    if (folders.isEmpty) {
      // 拿不到收藏夹列表时，只要命中非空就认为"已收藏"。
      return true;
    }
    final Set<String> mine = <String>{
      for (final MusicCollection f in folders) f.id,
    };
    return hitIds.any(mine.contains);
  }

  /// 收藏 / 取消收藏。
  ///
  /// **`csrf` 是写操作的硬性要求**：它就是 cookie 里的 `bili_jct`，
  /// 少了它服务端一律拒绝。这里在发请求前先把它取出来并给出明确提示，
  /// 而不是等一个 `code: -111`（csrf 校验失败）回来再猜。
  @override
  Future<void> setLiked(Song song, bool liked) async {
    final AccountProfile? profile = await _ensureAccount();
    if (profile == null) {
      throw const MusicApiException(
        '请先登录哔哩哔哩账号后再收藏',
        source: MediaSource.bilibili,
        isAuthError: true,
      );
    }

    final String? csrf = _client.cookieValue('bili_jct');
    if (csrf == null) {
      throw const MusicApiException(
        '缺少 bili_jct cookie，无法执行收藏操作，请重新登录',
        source: MediaSource.bilibili,
        isAuthError: true,
      );
    }

    final String? folderId = await _resolveTargetFolder(profile);
    if (folderId == null) {
      throw const MusicApiException(
        '你有多个收藏夹，请先在界面上选择一个要加入的收藏夹',
        source: MediaSource.bilibili,
      );
    }

    final int? rid = asInt(song.extra['sid']) ?? asInt(song.extra['aid']);
    if (rid == null || rid == 0) {
      throw MusicApiException(
        '该条目缺少资源 id（aid/sid），无法收藏',
        source: MediaSource.bilibili,
      );
    }
    final int type = song.extra['isAudio'] == true ? 12 : 2;

    await _client.postForm(
      '/x/v3/fav/resource/deal',
      form: <String, String>{
        'rid': '$rid',
        'type': '$type',
        // 加收藏用 add_media_ids，取消用 del_media_ids，二者只出现一个。
        if (liked) 'add_media_ids': folderId else 'del_media_ids': folderId,
        'csrf': csrf,
      },
    );
    // 收藏状态变了，但播放地址不受影响，因此不动 _streamCache。
  }

  /// 决定收藏到哪个收藏夹。
  ///
  /// 优先级：界面显式选过的 > 只有一个收藏夹时自动用它 > 让界面去问用户。
  Future<String?> _resolveTargetFolder(AccountProfile profile) async {
    final String? configured = targetFolderId;
    if (configured != null && configured.isNotEmpty) return configured;

    final List<MusicCollection> folders = await _foldersOf(profile.userId);
    if (folders.isEmpty) {
      throw const MusicApiException(
        '当前账号还没有可用的收藏夹，请先在哔哩哔哩上创建一个',
        source: MediaSource.bilibili,
      );
    }
    if (folders.length == 1) return folders.first.id;

    // 多个收藏夹时不敢替用户猜：猜错了就是"我明明收藏了却找不到"。
    return null;
  }

  // -------------------------------------------------------------------------

  /// 确保拿到账号信息；未登录返回 null（而不是抛错，调用方各自决定怎么处理）。
  Future<AccountProfile?> _ensureAccount() async {
    final AccountProfile? cached = _account;
    if (cached != null) return cached;
    // 本地连 SESSDATA 都没有，就不必白跑一次网络请求了。
    if (!_client.hasSession) return null;
    try {
      return await refreshAccount();
    } on MusicApiException catch (error) {
      if (error.isAuthError) return null;
      rethrow;
    }
  }

  void dispose() {
    _streamCache.clear();
    _accountController.close();
  }
}

/// 缓存条目：既记住地址自身的过期时间，也记住我们愿意信它多久。
@immutable
class _CachedStream {
  const _CachedStream(this.stream, this.cacheExpiresAt);

  final ResolvedStream stream;

  /// 本地缓存上限（与签名地址自身的 deadline 取更早的那个）。
  final DateTime cacheExpiresAt;

  bool isValidAt(DateTime now) =>
      now.isBefore(cacheExpiresAt) && stream.isValidAt(now);
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// 哔哩哔哩接口客户端。
final Provider<BilibiliApiClient> bilibiliApiClientProvider =
    Provider<BilibiliApiClient>((Ref ref) {
      final Dio dio = createZhyDio();
      final BilibiliApiClient client = BilibiliApiClient(
        dio: dio,
        preferences: ref.watch(sharedPreferencesProvider),
      );
      ref.onDispose(() {
        client.dispose();
        dio.close(force: true);
      });
      return client;
    });

/// 哔哩哔哩登录服务（二维码登录界面需要它）。
final Provider<BilibiliLoginService> bilibiliLoginServiceProvider =
    Provider<BilibiliLoginService>((Ref ref) {
      return BilibiliLoginService(
        client: ref.watch(bilibiliApiClientProvider),
        preferences: ref.watch(sharedPreferencesProvider),
      );
    });

/// 哔哩哔哩音源实现。
///
/// 类型刻意声明成接口 [MusicRepository]：界面只应该依赖音源接口。
/// 需要哔哩专有能力（扫码登录、`setTargetFolder`、浏览他人公开收藏夹）时，
/// 用对应的 provider，或把取到的实例转型成 [BilibiliRepository]。
final Provider<BilibiliRepository> bilibiliRepositoryProvider =
    Provider<BilibiliRepository>((Ref ref) {
      final BilibiliRepository repository = BilibiliRepository(
        client: ref.watch(bilibiliApiClientProvider),
        auth: ref.watch(bilibiliLoginServiceProvider),
        preferences: ref.watch(sharedPreferencesProvider),
      );
      ref.onDispose(repository.dispose);
      return repository;
    });
