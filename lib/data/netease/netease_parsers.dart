/// 网易云接口响应 → 应用模型 的纯函数集合。
///
/// 为什么单独成文件、且全是无副作用的顶层函数：
/// - 网易云的字段形态在不同接口之间差异极大：搜索用 `album`/`artists`/`duration`，
///   云搜索用 `al`/`ar`/`dt`，权限有时在歌曲里（`privilege`）有时在容器上
///   （`privileges` 数组），艺人 / 专辑经常整个是 `null`。把这些兼容逻辑
///   集中在解析层，repository 就只剩下"取数据、组装、报错"三件事。
/// - 纯函数可以脱离网络单测：拿一份真实的 JSON 就能验证。
/// - **这里任何函数都不允许因为字段缺失而抛异常**。接口偶尔返回 null 字段，
///   一次解析崩溃会让整个页面白屏，代价远大于少显示一个封面。
///   读不到就给默认值；只有"确实拿不到播放地址"这种业务失败才抛
///   [MusicApiException]（由 UI 原样展示原因）。
library;

import '../models/collection.dart';
import '../models/media_source.dart';
import '../models/song.dart';
import '../repositories/music_repository.dart';

/// 封面缩略图参数。网易云的图片 CDN 支持按 `?param=WxH` 让服务端裁剪，
/// 不缩放的话一张 2000x2000 的图会白白吃掉几 MB 内存。
const String kCoverParam = 'param=512y512';

/// 给封面地址补上缩略参数（已经有了就不重复加）。
String? neteaseCoverUrl(String? url) {
  final String? value = asString(url);
  if (value == null) return null;
  if (value.contains(kCoverParam)) return value;
  final String separator = value.contains('?') ? '&' : '?';
  return '$value$separator$kCoverParam';
}

// ------------------------------------------------------------------ 基础转换

/// 宽容地取整数。接口里同一个字段可能是 `1`、`"1"`、`1.0` 或 null。
int? asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// 宽容地取非空字符串。空白字符串按"没有值"处理
/// （网易云大量使用 `""` 表示缺失，直接透传会让 UI 显示空白项）。
String? asString(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num || value is bool) return '$value';
  return null;
}

/// 把任意 Map 归一化成 `Map<String, Object?>`；不是 Map 时返回 null。
Map<String, Object?>? asMap(Object? value) {
  if (value is! Map) return null;
  final Map<String, Object?> result = <String, Object?>{};
  value.forEach((Object? key, Object? item) {
    if (key == null) return;
    result[key is String ? key : '$key'] = item;
  });
  return result;
}

/// 把任意列表归一化成 `List<Map<String, Object?>>`，自动跳过非 Map 元素。
List<Map<String, Object?>> asMapList(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  final List<Map<String, Object?>> result = <Map<String, Object?>>[];
  for (final Object? item in value) {
    final Map<String, Object?>? map = asMap(item);
    if (map != null) result.add(map);
  }
  return result;
}

/// 毫秒时间戳 → [Duration]。非正数按"未知"处理（接口用 0 表示缺失）。
Duration? msToDuration(Object? value) {
  final int? ms = asInt(value);
  if (ms == null || ms <= 0) return null;
  return Duration(milliseconds: ms);
}

/// 在若干候选键里取第一个非空列表。
///
/// 为什么不是 `map['ar'] ?? map['artists']`：`ar` 存在但为空数组时 `??` 不会
/// 继续往后取，而这种"字段在、内容是空"的形态在网易云里非常常见。
List<Map<String, Object?>> _pickMapList(
  Map<String, Object?> map,
  List<String> keys,
) {
  for (final String key in keys) {
    final List<Map<String, Object?>> list = asMapList(map[key]);
    if (list.isNotEmpty) return list;
  }
  return const <Map<String, Object?>>[];
}

// ---------------------------------------------------------------------- 曲目

/// 解析一首曲目。
///
/// [hasVip] 表示当前账号是否会员：`fee == 1`（VIP 专享）的歌曲对会员是可播的，
/// 对非会员只能试听 45 秒。列表阶段标出"能不能放"是刻意的（见 [Song] 的文档），
/// 但把会员歌一律标成不可播会让付费用户完全没法用，所以把账号身份作为入参传进来，
/// 保持函数本身无状态。不传时按非会员处理。
Song parseSong(Map<String, Object?> raw, {bool hasVip = false}) {
  // 推荐类接口（/personalized/newsong）把曲目包在 `song` 里，
  // 外层还单独给了一份封面，展开后外层信息仍然作为兜底。
  final Map<String, Object?> map = asMap(raw['song']) ?? raw;

  final String id = asString(map['id']) ?? asInt(map['id'])?.toString() ?? '';
  final String title = asString(map['name']) ?? '未知曲目';

  final List<String> artists = <String>[
    for (final Map<String, Object?> artist in _pickMapList(map, <String>[
      'ar',
      'artists',
    ]))
      if (asString(artist['name']) != null) asString(artist['name'])!,
  ];

  final Map<String, Object?>? albumMap =
      asMap(map['al']) ?? asMap(map['album']);
  final String? album = asString(albumMap?['name']);
  final String? albumId =
      asString(albumMap?['id']) ?? asInt(albumMap?['id'])?.toString();

  // 封面兜底顺序：专辑 picUrl → 曲目自带 picUrl（新歌速递）→ 模糊图。
  final String? coverUrl = neteaseCoverUrl(
    asString(albumMap?['picUrl']) ??
        asString(map['picUrl']) ??
        asString(raw['picUrl']) ??
        asString(albumMap?['blurPicUrl']),
  );

  final Duration? duration =
      msToDuration(map['dt']) ?? msToDuration(map['duration']);

  // 权限对象可能长在歌曲上，也可能由容器按下标注入（见 [parseSongs]）。
  final Map<String, Object?>? privilege = asMap(map['privilege']);
  final int? fee = asInt(map['fee']);
  final int? st = asInt(privilege?['st']) ?? asInt(map['st']);
  final int? pl = asInt(privilege?['pl']) ?? asInt(map['pl']);
  final int? fl = asInt(privilege?['fl']) ?? asInt(map['fl']);
  final int? payed = asInt(privilege?['payed']);
  final bool hasCopyrightNotice = asMap(map['noCopyrightRcmd']) != null;

  bool playable = true;
  String? unplayableReason;

  if (hasCopyrightNotice) {
    // 接口明确给了"无版权推荐"，歌曲已下架。
    playable = false;
    unplayableReason = '该歌曲暂无版权，已下架';
  } else if (st != null && st < 0) {
    // st < 0（常见 -200）是服务端给出的"无权播放"，最权威。
    playable = false;
    unplayableReason = '版权受限或需要会员';
  } else if (fee == 4 && (payed == null || payed == 0)) {
    // fee == 4 是数字专辑：会员也没用，要单独购买。
    playable = false;
    unplayableReason = '需购买数字专辑后播放';
  } else if (fee == 1 && !hasVip) {
    // fee == 1 是 VIP 专享。有权限对象时再看一眼可用码率：
    // pl / fl 全为 0 说明连试听码率都没给，才判不可播。
    final bool bitrateBlocked =
        (pl != null || fl != null) && (pl ?? 0) == 0 && (fl ?? 0) == 0;
    if (privilege == null || bitrateBlocked) {
      playable = false;
      unplayableReason = '版权受限或需要会员';
    }
  }

  return Song(
    id: id,
    source: MediaSource.netease,
    title: title,
    artists: artists,
    album: album,
    albumId: albumId,
    coverUrl: coverUrl,
    duration: duration,
    playable: playable,
    unplayableReason: unplayableReason,
    extra: <String, Object?>{
      'fee': fee,
      'st': st,
      'mvId': asInt(map['mv']) ?? asInt(map['mvid']),
      'pop': asInt(map['pop']),
    },
  );
}

/// 从任意"歌曲容器"里解析出曲目列表。
///
/// 能吃下的形态：`{songs: []}`（搜索 / 详情）、`{data: []}`（新歌榜）、
/// `{data: {dailySongs: []}}`（每日推荐）、`{result: {songs: []}}`（云搜索）、
/// `{playlist: {tracks: []}}`（歌单详情）、`{result: []}`（推荐新歌），
/// 以及直接传一个 List。目的是让调用方不必记住每个接口的包裹层级。
List<Song> parseSongs(Object? raw, {bool hasVip = false}) {
  final List<Song> songs = <Song>[];
  for (final Map<String, Object?> item in _songMaps(raw)) {
    final Song song = parseSong(item, hasVip: hasVip);
    // 没有 id 的条目（接口偶尔会混进广告位）无法去重、也无法播放，直接丢掉。
    if (song.id.isEmpty) continue;
    songs.add(song);
  }
  return songs;
}

List<Map<String, Object?>> _songMaps(Object? raw) {
  final Map<String, Object?>? container = asMap(raw);
  final Object? source;
  if (raw is List) {
    source = raw;
  } else if (container == null) {
    return const <Map<String, Object?>>[];
  } else {
    source = _pickSongList(container);
  }

  final List<Map<String, Object?>> songs = asMapList(source);

  // 容器级 `privileges` 与 songs 按下标一一对应（/playlist/detail、
  // /song/detail、/playlist/track/all 都是这个形态）。塞回每首歌里之后，
  // [parseSong] 就不必关心权限信息到底从哪来。
  final List<Map<String, Object?>> privileges = asMapList(
    container?['privileges'],
  );
  if (privileges.isEmpty) return songs;

  return <Map<String, Object?>>[
    for (int i = 0; i < songs.length; i++)
      if (songs[i]['privilege'] != null || i >= privileges.length)
        songs[i]
      else
        <String, Object?>{...songs[i], 'privilege': privileges[i]},
  ];
}

/// 在容器里递归找第一个非空的歌曲数组。
Object? _pickSongList(Map<String, Object?> map) {
  for (final String key in <String>['songs', 'dailySongs', 'tracks', 'data']) {
    final Object? value = map[key];
    if (value is List && value.isNotEmpty) return value;
    final Map<String, Object?>? nested = asMap(value);
    if (nested != null) {
      final Object? found = _pickSongList(nested);
      if (found != null) return found;
    }
  }
  // `playlist` / `result` 只是多包一层，本身不是歌曲字段，放最后递归。
  for (final String key in <String>['playlist', 'result']) {
    final Map<String, Object?>? nested = asMap(map[key]);
    if (nested != null) {
      final Object? found = _pickSongList(nested);
      if (found != null) return found;
    }
    final Object? value = map[key];
    if (value is List && value.isNotEmpty) return value;
  }
  // 传进来的就是一首歌（少见，但接口文档里存在这种单曲返回）。
  if (map['id'] != null && map['name'] != null) {
    return <Map<String, Object?>>[map];
  }
  return null;
}

// ---------------------------------------------------------------------- 集合

/// 解析歌单 / 专辑 / 榜单。
///
/// [kind] 不传时按 `specialType == 5`（网易云里"我喜欢的音乐"的标记）
/// 推断，其余一律当普通歌单。
MusicCollection parsePlaylist(
  Map<String, Object?> raw, {
  CollectionKind? kind,
}) {
  // `/playlist/detail` 包了一层 playlist，其余接口是平铺的。
  final Map<String, Object?> map = asMap(raw['playlist']) ?? raw;

  final String id = asString(map['id']) ?? asInt(map['id'])?.toString() ?? '';
  final String name = asString(map['name']) ?? '未命名歌单';
  final Map<String, Object?>? creator = asMap(map['creator']);

  return MusicCollection(
    id: id,
    source: MediaSource.netease,
    name: name,
    kind:
        kind ??
        (asInt(map['specialType']) == 5
            ? CollectionKind.favorite
            : CollectionKind.playlist),
    // 歌单用 coverImgUrl，推荐歌单用 picUrl。
    coverUrl: neteaseCoverUrl(
      asString(map['coverImgUrl']) ?? asString(map['picUrl']),
    ),
    description: asString(map['description']) ?? asString(map['copywriter']),
    creatorName: asString(creator?['nickname']) ?? asString(creator?['name']),
    trackCount: asInt(map['trackCount']) ?? 0,
    playCount: asInt(map['playCount']) ?? asInt(map['playcount']),
    extra: <String, Object?>{
      'specialType': asInt(map['specialType']),
      'subscribed': map['subscribed'],
      'updateTime': asInt(map['updateTime']),
    },
  );
}

// ---------------------------------------------------------------------- 账号

/// 解析账号信息；未登录（profile 为 null）时返回 null。
///
/// 能吃下 `/login/status`（`{data: {profile, account}}`）、
/// `/user/account`（`{profile, account}`）以及裸 profile 三种形态。
AccountProfile? tryParseProfile(Map<String, Object?> raw) {
  final Map<String, Object?> unwrapped = asMap(raw['data']) ?? raw;

  Map<String, Object?>? profile = asMap(unwrapped['profile']);
  // 直接把 profile 本身传进来（例如从本地缓存反序列化后）。
  if (profile == null && unwrapped['userId'] != null) profile = unwrapped;
  if (profile == null) return null;

  final String? userId =
      asString(profile['userId']) ?? asInt(profile['userId'])?.toString();
  if (userId == null) return null;

  final Map<String, Object?>? account = asMap(unwrapped['account']);
  final int? vipType = asInt(account?['vipType']) ?? asInt(profile['vipType']);

  return AccountProfile(
    source: MediaSource.netease,
    userId: userId,
    nickname: asString(profile['nickname']) ?? '网易云用户',
    avatarUrl: asString(profile['avatarUrl']),
    signature: asString(profile['signature']),
    // vipType > 0 即黑胶会员（含音乐包与黑胶 VIP，展示上不细分）。
    vipLabel: (vipType ?? 0) > 0 ? '黑胶VIP' : null,
    follows: asInt(profile['follows']),
    followers: asInt(profile['followers']),
  );
}

/// 与 [tryParseProfile] 相同，但未登录时抛 [MusicApiException]。
///
/// 提供两个入口是因为两种调用场景都真实存在：刷新账号时"未登录"是正常状态
/// （返回 null 让 UI 显示登录入口），而登录流程里拿不到 profile 就是失败。
AccountProfile parseProfile(Map<String, Object?> raw) {
  final AccountProfile? profile = tryParseProfile(raw);
  if (profile == null) {
    throw const MusicApiException(
      '未登录或登录状态已失效，请重新登录',
      source: MediaSource.netease,
      code: 301,
      isAuthError: true,
    );
  }
  return profile;
}

// ------------------------------------------------------------------ 播放地址

/// 解析 `/song/url/v1`（或旧版 `/song/url`）的响应。
///
/// 拿不到直链时抛 [MusicApiException]：这是业务失败而不是解析失败，
/// 界面必须把原因原样告诉用户（"点了歌什么都不发生"是最差的体验）。
ResolvedStream parseSongUrl(Map<String, Object?> raw) {
  final Map<String, Object?>? item = songUrlItem(raw);
  if (item == null) {
    throw const MusicApiException(
      '该歌曲暂无可用音源（可能是版权或会员限制）',
      source: MediaSource.netease,
      // 服务端连条目都没给 —— 换一首歌才是出路，所以标成"根本放不了"。
      unplayable: true,
    );
  }

  final String? url = asString(item['url']);
  if (url == null) {
    final int? inner = asInt(item['code']);
    throw MusicApiException(
      inner == null || inner == 200
          ? '该歌曲暂无可用音源（可能是版权或会员限制）'
          : '该歌曲暂无可用音源（接口返回 $inner，通常是版权或会员限制）',
      source: MediaSource.netease,
      code: inner,
      unplayable: true,
    );
  }

  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    throw const MusicApiException(
      '音源地址无法解析，请稍后重试',
      source: MediaSource.netease,
    );
  }

  final String? type = asString(item['type']) ?? asString(item['encodeType']);

  return ResolvedStream(
    url: uri,
    // 网易云的 CDN 不校验 Referer（这一点与哔哩不同），所以不需要额外请求头。
    mimeType: _mimeTypeOf(type),
    bitrate: asInt(item['br']),
    sizeBytes: asInt(item['size']),
    duration: msToDuration(item['time']),
    // 实际拿到的音质。
    //
    // 用接口回的 `level` 而不是我们请求的参数：会员权益不够时服务端会
    // **静默降级**（请求 lossless 也只会给你 320k），把请求值当成结果显示
    // 就是在骗用户。回落到按码率猜一个可读文案。
    qualityLabel:
        neteaseLevelLabel(asString(item['level'])) ??
        _labelForBitrate(asInt(item['br'])),
    // 直链本身带签名，服务端 `expi` 给的是 1200 秒（20 分钟）。
    // 这里显式给出过期时间，播放器才知道什么时候该重新解析，
    // 否则一首长歌放到一半会突然 403。
    expiresAt: DateTime.now().add(const Duration(minutes: 20)),
  );
}

/// 从播放地址响应里取出那一条音频条目。
///
/// `/song/url` 的 `data` 有时是数组、有时是单个对象（老接口），两种都要吃。
Map<String, Object?>? songUrlItem(Map<String, Object?> raw) {
  final List<Map<String, Object?>> list = asMapList(raw['data']);
  return list.isNotEmpty ? list.first : asMap(raw['data']);
}

/// 从播放地址响应里读出**服务端实际给了哪一档**（`level` 字段）。
///
/// 这是唯一权威的"实际音质"信号：`level` 是服务端按账号权益回填的，
/// 比我们请求的参数可信 —— 请求 lossless 拿到 320k 时，只有这个字段说实话。
/// 因此"自动档到底能拿到哪一档"的观测只能靠它，不能靠请求参数。
///
/// 读不到时返回 null（老的 `/song/url` 不带 `level`），调用方必须当作
/// "这次没有观测到"，而不是"降级到了最低档" —— 否则一次接口回退
/// 就能把自动档的预算判成"没权益"。
String? neteaseActualLevelId(Map<String, Object?> raw) {
  final String? level = asString(songUrlItem(raw)?['level']);
  if (level == null) return null;
  // 只认档位表里的值：服务端偶尔回 'none' 之类的占位，它不代表任何档位。
  return neteaseLevelLabel(level) == null ? null : level;
}

String? _mimeTypeOf(String? type) {
  switch (type?.toLowerCase()) {
    case 'mp3':
      return 'audio/mpeg';
    case 'flac':
      return 'audio/flac';
    case 'm4a':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'wav':
      return 'audio/wav';
    case 'ape':
      return 'audio/x-ape';
    default:
      return null;
  }
}

/// 网易云 `level` 字段 → 展示名。认不出来时返回 null，交给码率兜底。
String? neteaseLevelLabel(String? level) {
  switch (level) {
    case 'jymaster':
      return '超清母带';
    case 'sky':
      return '高清臻音';
    case 'jyeffect':
      return '沉浸环绕声';
    case 'hires':
      return 'Hi-Res';
    case 'lossless':
      return '无损';
    case 'exhigh':
      return '极高 320k';
    case 'higher':
      return '较高 192k';
    case 'standard':
      return '标准 128k';
    default:
      return null;
  }
}

/// 接口没给 `level` 时（例如走了老的 `/song/url`），按码率给一个可读档位。
String? _labelForBitrate(int? br) {
  if (br == null || br <= 0) return null;
  if (br >= 900000) return 'Hi-Res';
  if (br >= 800000) return '无损';
  if (br >= 300000) return '极高 320k';
  if (br >= 180000) return '较高 192k';
  return '标准 128k';
}
