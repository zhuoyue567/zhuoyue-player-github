import 'package:flutter/foundation.dart';

import '../../core/net/http_client.dart';
import '../models/collection.dart';
import '../models/media_source.dart';
import '../models/song.dart';
import '../repositories/music_repository.dart';

/// 哔哩哔哩接口响应 → 播放器模型 的解析层。
///
/// 这一层只做"翻译"，**不做网络请求、不抛业务异常**：所有函数在字段缺失、
/// 类型不对（哔哩同一字段在不同接口里是 int / String 混着来的）时都必须给出
/// 一个能用的默认值，而不是崩在 `type 'String' is not a subtype of 'int'` 上。
///
/// 唯一的例外是三个 `parseXxxStream`：它们的返回类型不是可空的
/// [ResolvedStream]，当整段响应里**确实**没有任何可用音轨时只能抛
/// [MusicApiException] —— 这不是"字段缺失"，而是"这首歌就是放不了"，
/// 上层必须拿到明确原因。
///
/// 文件里标注「实测」的结论都来自对线上接口的真实抓取，不是照抄文档：
/// 哔哩的接口文档与线上行为不一致的地方相当多。

// ---------------------------------------------------------------------------
// 通用取值助手
// ---------------------------------------------------------------------------

/// 宽松取 int。
///
/// 哔哩把同一个语义的字段在不同接口里给成 int / double / String 三种形态
/// （例如 `aid` 有时是数字，有时是 `"80433022"`），所以统一走这里。
int? asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.isFinite ? value.toInt() : null;
  if (value is bool) return value ? 1 : 0;
  if (value is String) {
    final String text = value.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text) ?? double.tryParse(text)?.toInt();
  }
  return null;
}

/// 宽松取非空字符串。空串与纯空白一律视作"没有"，返回 null。
///
/// 这样调用方可以直接写 `asString(x) ?? 兜底值`，不用再判断一次空串。
String? asString(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final String text = value.trim();
    return text.isEmpty ? null : text;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

/// 宽松取 bool。哔哩的 `isLogin` 基本都是真 bool，但 `has_more` 偶尔给 0/1。
bool? asBool(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final String text = value.trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
  }
  return null;
}

/// 取一个对象。不是 Map 就返回空 map，绝不返回 null。
Map<String, Object?> asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map<String, Object?>(
      (Object? key, Object? item) =>
          MapEntry<String, Object?>(key.toString(), item),
    );
  }
  return const <String, Object?>{};
}

/// 取一个对象数组，并丢掉里面所有不是对象的东西。
///
/// 这里刻意"宽容到近乎偏执"：实测搜索接口在无结果时会返回
/// `{"numResults":1000,"result":"         "}` —— `result` 是一个**字符串**。
/// 如果直接 `as List` 就会抛异常，整个搜索页白屏。
List<Map<String, Object?>> asMapList(Object? value) {
  final List<Map<String, Object?>> result = <Map<String, Object?>>[];
  if (value is Iterable) {
    for (final Object? item in value) {
      if (item is Map) {
        result.add(
          item.map<String, Object?>(
            (Object? key, Object? entry) =>
                MapEntry<String, Object?>(key.toString(), entry),
          ),
        );
      }
    }
  }
  return result;
}

/// 取一个数组；不是数组就返回空数组。
List<Object?> asList(Object? value) =>
    value is List ? value : const <Object?>[];

// ---------------------------------------------------------------------------
// 数值 / 文本 归一化
// ---------------------------------------------------------------------------

/// 哔哩的时长在不同接口里格式完全不同，实测：
/// - 收藏夹 `medias[].duration` 是**秒数**（159 / 431 / 61）
/// - 搜索 `result[].duration` 是**字符串**（`"222:28"` / `"403:18"`）
/// - `view` 的 `duration` 又是秒数（213）
///
/// 交叉验证过：搜索里 `"222:28"` 对应 `view.duration == 13348`，
/// 正好是 222×60+28，所以冒号格式就是 `总分钟:秒`（分钟数可以超过 59）。
Duration? parseDuration(Object? value) {
  if (value == null) return null;
  if (value is Duration) return value;
  if (value is num) {
    final int seconds = value.toInt();
    return seconds <= 0 ? null : Duration(seconds: seconds);
  }
  final String? text = asString(value);
  if (text == null) return null;
  if (!text.contains(':')) {
    final int? seconds = int.tryParse(text);
    return (seconds == null || seconds <= 0)
        ? null
        : Duration(seconds: seconds);
  }
  final List<String> parts = text.split(':');
  int seconds = 0;
  for (final String part in parts) {
    final int? piece = int.tryParse(part.trim());
    if (piece == null) return null;
    seconds = seconds * 60 + piece;
  }
  return seconds <= 0 ? null : Duration(seconds: seconds);
}

final RegExp _htmlTag = RegExp(r'<[^>]*>');

/// 剥掉搜索结果标题里的 HTML 高亮标签并解掉基础实体。
///
/// **实测确认这个问题是真实存在的**：搜索接口返回的标题是
/// `【<em class="keyword">周杰伦</em>】50首精选合集/...`。原样塞进
/// [Song.title] 的话，列表里会显示成带标签的一串乱码。
///
/// 解实体的顺序很关键：`&amp;` 必须**最后**替换，否则 `&amp;lt;`
/// 会先变成 `&lt;` 再被解成 `<`，凭空多出一个尖括号。
String stripHtmlTags(String input) {
  return input
      .replaceAll(_htmlTag, '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .trim();
}

/// 把封面地址补成绝对地址。
///
/// 实测：收藏夹与 `view` 返回绝对地址（`http://i0.hdslb.com/...`），
/// 搜索接口返回**协议相对地址**（`//i0.hdslb.com/...`）。后者直接交给
/// 图片组件会解析失败，所以统一补协议；顺手把 `http` 升成 `https`，
/// 免得桌面端在混合内容策略上踩坑。
String? normalizeCoverUrl(Object? value) {
  final String? raw = asString(value);
  if (raw == null) return null;
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('http://')) return 'https://${raw.substring(7)}';
  return raw;
}

// ---------------------------------------------------------------------------
// 收藏夹
// ---------------------------------------------------------------------------

/// `GET /x/v3/fav/folder/created/list-all` 的 `data.list[]` → [MusicCollection]。
///
/// 实测字段：`{id, fid, mid, title, cover, intro, media_count, cnt_info:{play},
/// upper:{mid,name,face}, attr, state, ...}`。
MusicCollection parseFavFolder(Map<String, Object?> raw) {
  final String? id = asString(raw['id']);
  final Map<String, Object?> upper = asMap(raw['upper']);
  final Map<String, Object?> cntInfo = asMap(raw['cnt_info']);

  return MusicCollection(
    id: id ?? '',
    source: MediaSource.bilibili,
    name: asString(raw['title']) ?? '未命名收藏夹',
    // 收藏夹对播放器来说就是"可增删曲目的歌单"，与网易云歌单同语义。
    kind: CollectionKind.playlist,
    coverUrl: normalizeCoverUrl(raw['cover']),
    description: asString(raw['intro']),
    creatorName: asString(upper['name']),
    trackCount: asInt(raw['media_count']) ?? 0,
    playCount: asInt(cntInfo['play']),
    extra: <String, Object?>{'mediaId': asString(raw['id']) ?? id ?? ''},
  );
}

// ---------------------------------------------------------------------------
// 收藏夹条目 → Song
// ---------------------------------------------------------------------------

/// 收藏夹 `medias[]` → [Song]。传进来的可以是 `medias` 数组本身，
/// 也可以是整个 `data`（会自动去取里面的 `medias`）。
///
/// 实测条目字段：
/// ```
/// {"id":75680533,"type":2,"title":"...","cover":"http://...","intro":"...",
///  "page":1,"duration":159,"upper":{"mid":15207794,"name":"鬼瞳","face":"..."},
///  "attr":0,"cnt_info":{"collect":22972,"play":250698,...},
///  "bv_id":"BV1VJ411D71C","bvid":"BV1VJ411D71C","ugc":{"first_cid":129557477},
///  "fav_time":1594035454}
/// ```
///
/// 关于「已失效」的判定，实测拿到的失效条目长这样：
/// `{"title":"已失效视频","attr":9,"bvid":"BV1kt411S7nq"}` ——
/// **`bvid` 居然是有的**，所以「bvid 为空」这一条并不能单独作为失效依据，
/// 必须以标题为准，`attr` 的最低位（实测失效项为 1）作为补充信号。
///
/// 关于音频区条目（`type == 12`）：实测它**同样带着一个非空 `bvid`**
/// （哔哩会给音频自动生成一个稿件）。如果先看 bvid 再判类型，就会把音频
/// 当成视频去请求 playurl，结果是彻底放不出声。所以这里**必须先判 type**，
/// 音频一律用 `au<id>`（`id` 是音频 sid）作为 [Song.id]，走音频区接口。
List<Song> parseFavMedias(Object? raw, {String? mid}) {
  final Map<String, Object?> container = asMap(raw);
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[
    ...asMapList(raw),
    ...asMapList(container['medias']),
  ];

  final List<Song> songs = <Song>[];
  for (final Map<String, Object?> entry in entries) {
    final int? biliType = asInt(entry['type']);
    final bool isAudio = biliType == 12;
    final int? rid = asInt(entry['id']);
    final String? bvid = asString(entry['bvid']) ?? asString(entry['bv_id']);
    final String? title = asString(entry['title']);
    final int attr = asInt(entry['attr']) ?? 0;

    // attr 是位域，最低位（实测失效项为 1）代表稿件已失效。
    // 音频条目必须额外要求 `id`（音频 sid）存在：它的 bvid 是自动生成的，
    // 光有 bvid 根本播不出声，不能算"有效"。
    final bool invalid =
        title == '已失效视频' ||
        (attr & 1) == 1 ||
        (isAudio ? rid == null : bvid == null) ||
        (rid == null && bvid == null);

    final Map<String, Object?> upper = asMap(entry['upper']);
    final Map<String, Object?> cntInfo = asMap(entry['cnt_info']);
    final Map<String, Object?> ugc = asMap(entry['ugc']);

    // Song.id 必须在音源内稳定且唯一：
    // 视频用 bvid；音频用 au<sid>（音频的 bvid 是自动生成的，不能用来标识）。
    final String id = isAudio ? 'au${rid ?? 0}' : (bvid ?? 'av${rid ?? 0}');

    songs.add(
      Song(
        id: id,
        source: MediaSource.bilibili,
        title: title ?? (invalid ? '已失效视频' : '未命名稿件'),
        artists: <String>[asString(upper['name']) ?? '未知 UP 主'],
        album: '哔哩哔哩收藏',
        coverUrl: normalizeCoverUrl(entry['cover']),
        duration: parseDuration(entry['duration']),
        playable: !invalid,
        unplayableReason: invalid ? '稿件已失效或被删除' : null,
        extra: <String, Object?>{
          'aid': rid,
          'bvid': bvid,
          'type': biliType,
          'isAudio': isAudio,
          if (isAudio) 'sid': rid,
          // 收藏夹里的 `page` 是多 P 稿件被收藏的那一 P。多 P 合集
          // （实测有 151 P 的 MV 合集）如果忽略它，点第 37 首永远放第 1 首。
          if (asInt(entry['page']) != null && (asInt(entry['page']) ?? 1) > 1)
            'page': asInt(entry['page']),
          // 这里**故意不使用** `ugc.first_cid`：它只是第 1 P 的 cid，
          // 而收藏夹可能收藏的是第 N P。把它降级成 firstCid 只作排查用，
          // 真正解析播放地址时由 resolveStream 按 `page` 去 view 里取正确的 cid。
          if (asInt(ugc['first_cid']) != null)
            'firstCid': asInt(ugc['first_cid']),
          'mid': asInt(upper['mid']) ?? mid,
          'attr': attr,
          'cntInfo': cntInfo,
        },
      ),
    );
  }
  return songs;
}

// ---------------------------------------------------------------------------
// 稿件详情
// ---------------------------------------------------------------------------

/// 稿件详情 `GET /x/web-interface/view` 的解析结果。
@immutable
class BilibiliView {
  const BilibiliView({
    this.aid,
    this.bvid,
    this.cid,
    this.pages = const <BilibiliPage>[],
    this.duration,
    this.title,
    this.ownerName,
    this.pic,
  });

  final int? aid;
  final String? bvid;

  /// 第一 P 的 cid。单 P 稿件就是它；多 P 稿件要按 [pages] 里对应的一 P 取。
  final int? cid;

  /// 实测多 P 稿件：`[{cid, page, part, duration}, ...]`，`page` 从 1 开始。
  final List<BilibiliPage> pages;

  /// 整稿总时长（秒）。注意多 P 稿件这里是**所有 P 相加**，不是单 P 时长。
  final Duration? duration;

  final String? title;
  final String? ownerName;
  final String? pic;

  /// 按收藏夹记录的 P 号取正确的 cid。
  ///
  /// 传 null / 1 或找不到对应 P 时回落到第一 P 的 cid —— 多 P 合集的
  /// 「播放第 N 首却是第 1 首」这个 bug 就是在这里被消掉的。
  int? cidForPage(int? page) {
    if (page == null || page <= 1) return cid;
    for (final BilibiliPage item in pages) {
      if (item.page == page && item.cid != null) return item.cid;
    }
    return cid;
  }
}

/// 稿件详情里的一 P。
@immutable
class BilibiliPage {
  const BilibiliPage({this.cid, this.page, this.part, this.duration});

  final int? cid;
  final int? page;

  /// 分 P 标题（实测形如 `001.周杰伦-晴天`）。
  final String? part;

  final Duration? duration;
}

/// `GET /x/web-interface/view` 的 `data`（也接受整个信封）→ [BilibiliView]。
BilibiliView parseView(Map<String, Object?> raw) {
  final Map<String, Object?> data = asMap(raw['data']).isNotEmpty
      ? asMap(raw['data'])
      : raw;
  final Map<String, Object?> owner = asMap(data['owner']);

  return BilibiliView(
    aid: asInt(data['aid']),
    bvid: asString(data['bvid']),
    cid: asInt(data['cid']),
    duration: parseDuration(data['duration']),
    title: asString(data['title']),
    ownerName: asString(owner['name']),
    pic: normalizeCoverUrl(data['pic']),
    pages: <BilibiliPage>[
      for (final Map<String, Object?> page in asMapList(data['pages']))
        BilibiliPage(
          cid: asInt(page['cid']),
          page: asInt(page['page']),
          part: asString(page['part']),
          duration: parseDuration(page['duration']),
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// 播放地址
// ---------------------------------------------------------------------------

/// CDN 地址里带的 `deadline` 参数就是这条签名地址的过期时间（unix 秒）。
///
/// 实测 dash 与音频区的地址里都有它（例如 `deadline=1791439457`）。
/// 它比"从现在起算 N 小时"准确得多：签名过期后 CDN 直接 403，
/// 提前按真实 deadline 重新解析能避免用户听到一半断流。
DateTime? streamDeadline(String url) {
  final int? deadline;
  try {
    deadline = int.tryParse(Uri.parse(url).queryParameters['deadline'] ?? '');
  } on FormatException {
    return null;
  }
  if (deadline == null || deadline <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(deadline * 1000);
}

/// 组装播放该地址所必须携带的请求头。
///
/// **这是哔哩这一路最容易踩的坑，务必不要"优化"掉**：
/// CDN 会校验防盗链，缺 `Referer` 直接 403。实测对照：
/// - 音频区 CDN（`upos-sz-mirrorhw.bilivideo.com`）：
///   不带 Referer → 403；带 `Referer: https://www.bilibili.com/` + 浏览器 UA → 200 / 206
/// - DASH 渐进轨（`*.bilivideo.com` 的 durl）：同样 403 → 206
/// - 但同一批 `*.mcdn.bilivideo.cn` 的 DASH 音轨实测**不校验**，
///   不带任何头也返回 206。也就是说"要不要 Referer"取决于被调度到哪个
///   CDN 节点，而不是取决于接口。既然节点是随机的，就必须**一律带上**。
Map<String, String> bilibiliStreamHeaders(String referer) => <String, String>{
  'Referer': referer,
  'User-Agent': kBrowserUserAgent,
};

/// 判断 playurl 响应里是否存在独立的 DASH 音轨。
///
/// 给上层用：`fnval=16` 拿不到独立音轨时（会员/付费稿件常见），
/// 需要退回 `fnval=1` 的渐进式 mp4 再解析一次。
bool hasDashAudio(Map<String, Object?> raw) {
  final Map<String, Object?> data = asMap(raw['data']).isNotEmpty
      ? asMap(raw['data'])
      : raw;
  final Map<String, Object?> dash = asMap(data['dash']);
  // 别漏掉 flac / dolby：有些稿件只在 `dash.flac.audio` 里给音轨，
  // 只判 `dash.audio` 会误判成"没有独立音轨"，然后错误地退到混流 mp4。
  if (asMapList(dash['audio']).isNotEmpty) return true;
  if (asMap(asMap(dash['flac'])['audio']).isNotEmpty) return true;
  if (asMap(asMap(dash['dolby'])['audio']).isNotEmpty) return true;
  return false;
}

/// `GET /x/player/playurl?fnval=16` → [ResolvedStream]。
///
/// 实测 `data.dash.audio` 是一个数组，每项形如：
/// ```
/// {"id":30280,"baseUrl":"https://...mcdn.bilivideo.cn:8082/...",
///  "base_url":"(与 baseUrl 相同)","backupUrl":["...","..."],"backup_url":[...],
///  "bandwidth":203786,"codecs":"mp4a.40.2","mimeType":"audio/mp4"}
/// ```
/// 同一个稿件会给出多档音轨（实测 43962 / 102931 / 203786 bps），
/// 这里取 `bandwidth` 最大的一档（码率越高越接近无损）。
///
/// `dash` 缺失但 `durl` 存在时走渐进式兜底：**那条路径没有独立音轨**，
/// 拿到的是一个把音视频混在一起的 mp4，播放器只能整个播，
/// 也因此拿不到音轨码率等元信息。
ResolvedStream parseDashAudio(
  Map<String, Object?> raw, {
  required String referer,
  String qualityId = 'default',
}) {
  final Map<String, Object?> data = asMap(raw['data']).isNotEmpty
      ? asMap(raw['data'])
      : raw;
  final Map<String, Object?> dash = asMap(data['dash']);

  // 三条候选轨，按"用户偏好 → 可用性"排序。
  //
  // 实测：`dash.flac.audio` 与 `dash.dolby.audio` 是**独立字段**，
  // 不在 `dash.audio[]` 里 —— 只读 `dash.audio` 的话，大会员用户
  // 永远拿不到 Hi-Res 无损和杜比全景声，而界面上却显示已经开了无损。
  // 另外服务端只在**有权益时**才返回这两个字段，所以"字段存在"本身就等于
  // "可用"，不需要再单独判会员。
  final List<({Map<String, Object?> track, String label})> candidates =
      <({Map<String, Object?> track, String label})>[];

  final Map<String, Object?> flac = asMap(asMap(dash['flac'])['audio']);
  final Map<String, Object?> dolby = asMap(asMap(dash['dolby'])['audio']);

  void addFlac() {
    if (flac.isNotEmpty) candidates.add((track: flac, label: 'Hi-Res 无损'));
  }

  void addDolby() {
    if (dolby.isNotEmpty) candidates.add((track: dolby, label: '杜比全景声'));
  }

  final List<Map<String, Object?>> audios = asMapList(dash['audio']);

  switch (qualityId) {
    case 'hires':
      addFlac();
      addDolby();
    case 'dolby':
      addDolby();
      addFlac();
    default:
      break;
  }

  if (audios.isNotEmpty) {
    Map<String, Object?> best = audios.first;
    int bestBandwidth = asInt(best['bandwidth']) ?? 0;
    for (final Map<String, Object?> item in audios) {
      final int bandwidth = asInt(item['bandwidth']) ?? 0;
      if (bandwidth > bestBandwidth) {
        bestBandwidth = bandwidth;
        best = item;
      }
    }
    candidates.add((
      track: best,
      // 标签只写"实际拿到的是什么"。选择与实际不一致（会员不够被降级）
      // 由界面分别展示"你选了 Hi-Res"与"实际 默认"，不在这里混着写。
      label: '默认',
    ));
  }

  for (final ({Map<String, Object?> track, String label}) candidate
      in candidates) {
    final String? url =
        asString(candidate.track['baseUrl']) ??
        asString(candidate.track['base_url']) ??
        _firstString(candidate.track['backupUrl']) ??
        _firstString(candidate.track['backup_url']);
    if (url == null) continue;

    final int bandwidth = asInt(candidate.track['bandwidth']) ?? 0;
    return ResolvedStream(
      url: Uri.parse(url),
      headers: bilibiliStreamHeaders(referer),
      mimeType:
          asString(candidate.track['mimeType']) ??
          asString(candidate.track['mime_type']) ??
          'audio/mp4',
      bitrate: bandwidth > 0 ? bandwidth : null,
      expiresAt: streamDeadline(url),
      qualityLabel: candidate.label,
    );
  }

  // 渐进式兜底：没有独立音轨，只有一条混流 mp4。
  final List<Map<String, Object?>> durl = asMapList(data['durl']);
  if (durl.isNotEmpty) {
    final String? url =
        asString(durl.first['url']) ?? _firstString(durl.first['backup_url']);
    if (url != null) {
      return ResolvedStream(
        url: Uri.parse(url),
        headers: bilibiliStreamHeaders(referer),
        mimeType: 'video/mp4',
        sizeBytes: asInt(durl.first['size']),
        expiresAt: streamDeadline(url),
        qualityLabel: '混流（无独立音轨）',
      );
    }
  }

  throw MusicApiException(
    (asString(raw['message']) ?? asString(raw['msg'])) ??
        '该稿件没有可用的音频流，可能是付费/会员专属内容或已下架',
    source: MediaSource.bilibili,
    code: asInt(raw['code']),
  );
}

/// `GET /audio/music-service-c/url` → [ResolvedStream]。
///
/// 实测响应（**注意这个接口用的是 `msg` 而不是 `message`**）：
/// ```
/// {"code":0,"msg":"success","data":{"sid":2478206,"type":2,"info":"",
///  "timeout":10800,"size":168,"cdns":["https://upos-sz-mirrorhw.bilivideo.com/...-320k.m4a?...&deadline=1791439542&..."],
///  "qualities":[{"type":2,"desc":"高品质","size":168,"bps":"320kbit/s","tag":"HQ"}, ...]}}
/// ```
/// - [ResolvedStream.expiresAt] 由 `deadline` 决定，拿不到时退回
///   `timeout`（实测 10800 秒 = 3 小时）。
/// - `data.size` **刻意不映射到 [ResolvedStream.sizeBytes]**：实测该字段是
///   168，而同一个地址的 HTTP `Content-Length` 是 4533496 字节，
///   数量级完全对不上（既不是字节也不是 KB/MB）。宁可不给，
///   也不要给一个会让下载进度条算错的假数字。
/// - 码率从 `qualities` 里与 `data.type` 对应的那一档的 `bps`
///   （实测 `"320kbit/s"`）解出来。
ResolvedStream parseAudioUrl(
  Map<String, Object?> raw, {
  required String referer,
}) {
  final Map<String, Object?> data = asMap(raw['data']).isNotEmpty
      ? asMap(raw['data'])
      : raw;

  final String? url = _firstString(data['cdns']);
  if (url == null) {
    throw MusicApiException(
      asString(raw['msg']) ??
          asString(raw['message']) ??
          '未能取到音频播放地址，该音频可能已下架或需要登录',
      source: MediaSource.bilibili,
      code: asInt(raw['code']),
    );
  }

  final DateTime? deadline = streamDeadline(url);
  final int? timeoutSeconds = asInt(data['timeout']);
  final DateTime? expiresAt =
      deadline ??
      (timeoutSeconds == null
          ? null
          : DateTime.now().add(Duration(seconds: timeoutSeconds)));

  return ResolvedStream(
    url: Uri.parse(url),
    headers: bilibiliStreamHeaders(referer),
    mimeType: _audioMimeTypeFromUrl(url) ?? 'audio/mp4',
    bitrate: _bitrateFromQualities(data, asInt(data['type'])),
    expiresAt: expiresAt,
  );
}

String? _firstString(Object? value) {
  if (value is String) return asString(value);
  if (value is Iterable) {
    for (final Object? item in value) {
      final String? text = asString(item);
      if (text != null) return text;
    }
  }
  return null;
}

/// 音频区返回的地址后缀能直接反映容器格式（实测 `-320k.m4a`）。
String? _audioMimeTypeFromUrl(String url) {
  final String path;
  try {
    path = Uri.parse(url).path.toLowerCase();
  } on FormatException {
    return null;
  }
  if (path.endsWith('.m4a') || path.endsWith('.mp4')) return 'audio/mp4';
  if (path.endsWith('.mp3')) return 'audio/mpeg';
  if (path.endsWith('.flac')) return 'audio/flac';
  return null;
}

/// 从 `qualities` 里找出当前档位的码率描述并换算成 bps。
///
/// 实测 `bps` 形如 `"320kbit/s"`，所以取数字部分乘以 1000。
int? _bitrateFromQualities(Map<String, Object?> data, int? currentType) {
  if (currentType == null) return null;
  for (final Map<String, Object?> quality in asMapList(data['qualities'])) {
    if (asInt(quality['type']) != currentType) continue;
    final String? bps = asString(quality['bps']);
    if (bps == null) return null;
    final int? number = int.tryParse(bps.replaceAll(RegExp(r'[^0-9]'), ''));
    if (number == null) return null;
    return bps.toLowerCase().contains('kbit') ? number * 1000 : number;
  }
  return null;
}
