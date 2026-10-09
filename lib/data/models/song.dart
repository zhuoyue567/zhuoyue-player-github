import 'package:flutter/foundation.dart';

import 'media_source.dart';

/// 与音源无关的统一曲目模型。
///
/// 设计要点：
/// - [id] 只需在**同一个音源内**唯一，跨音源的唯一性由 [uid] 提供。
///   队列去重、下载记录、"正在播放"判断一律用 [uid]。
/// - 各平台的私有字段（哔哩的 bvid/cid、网易云的 fee/level 等）不往这里塞，
///   统一放进 [extra]，由各自的 repository 自行解释。这样加音源不用改模型。
/// - [playable] 与 [unplayableReason] 是刻意保留的：第三方客户端最常见的
///   体验事故就是点了歌什么都不发生。这里要求音源在**列表阶段**就标出
///   "这首放不了"（版权下架 / 需要付费 / 需要登录），UI 才能给出明确反馈。
@immutable
class Song {
  const Song({
    required this.id,
    required this.source,
    required this.title,
    this.artists = const <String>[],
    this.album,
    this.albumId,
    this.coverUrl,
    this.duration,
    this.playable = true,
    this.unplayableReason,
    this.extra = const <String, Object?>{},
  });

  /// 音源内的唯一 id（网易云为歌曲 id，哔哩为 bvid 或音频 sid）。
  final String id;

  final MediaSource source;

  final String title;

  final List<String> artists;

  final String? album;
  final String? albumId;

  /// 封面地址。允许为空：有些歌就是没有封面，UI 需要有占位方案。
  final String? coverUrl;

  final Duration? duration;

  final bool playable;

  /// 不可播放的原因，用于给用户一个明确交代。
  final String? unplayableReason;

  /// 音源私有字段。约定见各 repository 的文档注释。
  final Map<String, Object?> extra;

  /// 跨音源的稳定唯一键。
  String get uid => '${source.key}:$id';

  /// 展示用艺人串，空列表时回落到"未知艺人"。
  String get artistLabel => artists.isEmpty ? '未知艺人' : artists.join(' / ');

  /// 下载文件名（已去掉 Windows 非法字符）。
  String get safeFileName {
    final String raw =
        '${artists.isEmpty ? '' : '${artists.join('、')} - '}$title';
    return raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Song copyWith({
    String? id,
    MediaSource? source,
    String? title,
    List<String>? artists,
    String? album,
    String? albumId,
    String? coverUrl,
    Duration? duration,
    bool? playable,
    String? unplayableReason,
    Map<String, Object?>? extra,
  }) {
    return Song(
      id: id ?? this.id,
      source: source ?? this.source,
      title: title ?? this.title,
      artists: artists ?? this.artists,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration ?? this.duration,
      playable: playable ?? this.playable,
      unplayableReason: unplayableReason ?? this.unplayableReason,
      extra: extra ?? this.extra,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Song && other.uid == uid);

  @override
  int get hashCode => uid.hashCode;

  @override
  String toString() => 'Song($uid, $title — $artistLabel)';
}

/// 解析后的可播放地址。
///
/// 为什么不是简单返回一个 URL：
/// - 哔哩的音频 CDN 会校验 `Referer`，不带的话直接 403，
///   所以请求头必须跟着 URL 一起传递，交给播放器设置。
/// - 网易云的直链带时效签名，过期要重新解析，[expiresAt] 让播放器能提前续期。
@immutable
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    this.headers = const <String, String>{},
    this.mimeType,
    this.bitrate,
    this.sizeBytes,
    this.expiresAt,
    this.duration,
    this.qualityLabel,
  });

  final Uri url;

  /// 播放该地址时必须携带的请求头（哔哩的 Referer / UA 就靠它）。
  final Map<String, String> headers;

  final String? mimeType;

  /// 码率（bps）。
  final int? bitrate;

  final int? sizeBytes;

  /// 地址失效时间。null 表示无签名、不会过期。
  final DateTime? expiresAt;

  final Duration? duration;

  /// 实际拿到的音质展示名（例如「无损」「Hi-Res」「320 kbps」）。
  ///
  /// 由音源解析时填入，**反映服务端真正给了什么**，而不是用户选了什么 ——
  /// 会员权益不够时服务端会静默降级，把选择当成结果展示就是在骗用户。
  final String? qualityLabel;

  /// 到 [now] 为止地址是否仍然可用；留 60 秒安全边界。
  bool isValidAt(
    DateTime now, {
    Duration safety = const Duration(seconds: 60),
  }) {
    final DateTime? expiry = expiresAt;
    if (expiry == null) return true;
    return now.add(safety).isBefore(expiry);
  }

  @override
  String toString() =>
      'ResolvedStream($url, ${mimeType ?? "?"}, ${bitrate ?? 0}bps)';
}
