import 'package:flutter/foundation.dart';

import 'media_source.dart';
import 'song.dart';

/// 与音源无关的「歌单 / 收藏夹 / 专辑 / 榜单」统一模型。
///
/// 这四者在各平台叫法不同（网易云叫歌单，哔哩叫收藏夹），
/// 但对播放器来说都是"一个有序的曲目集合"，因此统一成一个类型，
/// 用 [kind] 区分展示方式与可用操作。
@immutable
class MusicCollection {
  const MusicCollection({
    required this.id,
    required this.source,
    required this.name,
    this.kind = CollectionKind.playlist,
    this.coverUrl,
    this.description,
    this.creatorName,
    this.trackCount = 0,
    this.playCount,
    this.extra = const <String, Object?>{},
  });

  final String id;
  final MediaSource source;
  final String name;
  final CollectionKind kind;
  final String? coverUrl;
  final String? description;
  final String? creatorName;
  final int trackCount;

  /// 播放量，仅用于展示。
  final int? playCount;

  final Map<String, Object?> extra;

  String get uid => '${source.key}:${kind.name}:$id';

  /// 是否允许增删曲目。哔哩的收藏夹可以，榜单和"每日推荐"不可以。
  bool get isEditable =>
      kind == CollectionKind.playlist || kind == CollectionKind.favorite;

  MusicCollection copyWith({
    String? id,
    MediaSource? source,
    String? name,
    CollectionKind? kind,
    String? coverUrl,
    String? description,
    String? creatorName,
    int? trackCount,
    int? playCount,
    Map<String, Object?>? extra,
  }) {
    return MusicCollection(
      id: id ?? this.id,
      source: source ?? this.source,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      coverUrl: coverUrl ?? this.coverUrl,
      description: description ?? this.description,
      creatorName: creatorName ?? this.creatorName,
      trackCount: trackCount ?? this.trackCount,
      playCount: playCount ?? this.playCount,
      extra: extra ?? this.extra,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MusicCollection && other.uid == uid);

  @override
  int get hashCode => uid.hashCode;
}

/// 集合的语义类型。
enum CollectionKind {
  /// 用户创建 / 收藏的歌单、收藏夹。可编辑。
  playlist,

  /// 「我喜欢的音乐」这类由平台托管的收藏。语义上可编辑（加/删），但不可删除。
  favorite,

  /// 专辑。
  album,

  /// 榜单 / 排行榜。只读。
  chart,

  /// 平台算法推荐（每日推荐、私人 FM）。只读且每次内容不同。
  daily,

  /// 艺人热门曲目。只读。
  artist,
}

/// 已登录账号的公开信息。
@immutable
class AccountProfile {
  const AccountProfile({
    required this.source,
    required this.userId,
    required this.nickname,
    this.avatarUrl,
    this.signature,
    this.vipLabel,
    this.follows,
    this.followers,
  });

  final MediaSource source;
  final String userId;
  final String nickname;
  final String? avatarUrl;
  final String? signature;

  /// 会员身份的展示文案（例如「黑胶VIP」「大会员」），无会员则为 null。
  final String? vipLabel;

  final int? follows;
  final int? followers;

  String get uid => '${source.key}:$userId';
}

/// 一个音源贡献的「发现」内容。
@immutable
class DiscoverFeed {
  const DiscoverFeed({
    required this.title,
    required this.songs,
    this.subtitle,
    this.source = MediaSource.local,
  });

  const DiscoverFeed.empty(this.title, this.subtitle)
    : songs = const <Song>[],
      source = MediaSource.local;

  final String title;
  final String? subtitle;
  final List<Song> songs;
  final MediaSource source;

  bool get isEmpty => songs.isEmpty;
}
