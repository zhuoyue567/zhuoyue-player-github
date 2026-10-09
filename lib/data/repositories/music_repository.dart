import 'package:flutter/foundation.dart';

import '../models/audio_quality.dart';
import '../models/collection.dart';
import '../models/lyric.dart';
import '../models/media_source.dart';
import '../models/song.dart';

/// 音源接口调用失败。
///
/// 刻意区分 [isAuthError]：登录态失效（网易云 code 301 / 哔哩 -101）
/// 需要 UI 引导重新登录，而网络超时只需要重试。把这两种混在一个
/// 通用异常里，界面上就只能给出"操作失败"这种没用的提示。
class MusicApiException implements Exception {
  const MusicApiException(
    this.message, {
    this.source,
    this.code,
    this.isAuthError = false,
    this.unplayable = false,
    this.cause,
  });

  final String message;
  final MediaSource? source;

  /// 平台返回的业务错误码。
  final int? code;

  /// 是否需要重新登录。
  final bool isAuthError;

  /// 这首歌**根本放不了**（版权下架 / 需要购买 / 音源里没有），
  /// 而不是"这次请求碰巧失败了"。
  ///
  /// 这个区分决定了播放器的行为，所以必须是**类型化的信号**而不是去匹配
  /// 错误文案：
  /// - `true` → 像播完一样按队列**切歌**（换一首歌是真的能解决问题）；
  /// - `false`（默认，例如网络超时、403 地址过期）→ 停在原地显示原因 + 重试，
  ///   因为换歌并不会让网络恢复，反而会把用户真正想听的那首跳过去。
  final bool unplayable;

  final Object? cause;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('MusicApiException');
    if (source != null) buffer.write('[${source!.label}]');
    if (code != null) buffer.write('(code=$code)');
    if (unplayable) buffer.write('(unplayable)');
    buffer.write(': $message');
    if (cause != null) buffer.write(' <- $cause');
    return buffer.toString();
  }
}

/// 分页结果。
@immutable
class CollectionTracksPage {
  const CollectionTracksPage({
    required this.songs,
    this.hasMore = false,
    this.total,
  });

  final List<Song> songs;
  final bool hasMore;
  final int? total;
}

/// 一个音源向播放器暴露的全部能力。
///
/// 分层约定：**UI 只依赖这个接口，不依赖任何具体音源**。
/// 网易云走内嵌 Node 服务、哔哩直连 HTTP，两者实现完全不同，
/// 但对上层必须长得一模一样 —— 这是"播放器与音源解耦"的全部意义。
///
/// 实现约定：
/// - 所有方法都可能在未登录时被调用，未登录应返回空列表 / 抛出
///   [MusicApiException]（[MusicApiException.isAuthError] = true），
///   而不是返回 null 让调用方猜。
/// - 所有方法都必须自行完成响应信封解包与错误码判断，
///   不要把"code 不是 200"这种平台细节泄漏到上层。
abstract interface class MusicRepository {
  /// 本实现对应的音源。
  MediaSource get source;

  /// 该音源支持的音质档位，**从高到低**排列。
  ///
  /// 顺序有意义：界面直接按这个顺序渲染，「自动」档位也按它取第一个可用的。
  List<AudioQuality> get audioQualities;

  /// 当前偏好的音质 id。取值来自 [audioQualities]，或 [kAutoQualityId]。
  String get preferredQualityId;

  /// 设置偏好音质（`auto` 表示按账号权益自动取最高可用）。
  ///
  /// 放在 repository 上而不是当成 `resolveStream` 的参数，是因为
  /// "我要什么音质"是**用户对音源的长期偏好**，不是某一次解析的属性。
  /// 这样所有调用点（播放器、预取、重试）自动一致，不用每处都传一遍。
  Future<void> setPreferredQuality(String qualityId);

  /// 「自动」档位下当前**实际**会用的档位，供界面显示"自动（当前：无损）"。
  AudioQuality get effectiveQuality;

  /// 当前是否已登录（用于决定界面显示登录入口还是账号卡片）。
  bool get isAuthenticated;

  /// 已缓存的账号信息。未登录或尚未拉取时为 null。
  AccountProfile? get account;

  /// 账号状态变化通知（登录成功 / 退出登录 / 凭据失效）。
  ///
  /// 界面靠它把"当前登录的是谁"做成响应式，而不必自己轮询
  /// 或者在各处手动 invalidate。
  Stream<AccountProfile?> get accountChanges;

  /// 拉取（或刷新）当前账号信息。
  Future<AccountProfile?> refreshAccount();

  /// 退出登录并清理本地凭据。
  Future<void> logout();

  /// 「我的」歌单 / 收藏夹列表。
  Future<List<MusicCollection>> myCollections();

  /// 拉取集合内的曲目，支持分页。
  Future<CollectionTracksPage> collectionTracks(
    String collectionId, {
    int offset = 0,
    int limit = 50,
  });

  /// 一次把集合里的曲目**全部**取回。
  ///
  /// 与 [collectionTracks] 的区别不是"多取一点"，而是**语义不同**：
  /// 它保证返回当前集合的完整曲目表。
  ///
  /// 为什么必须单独有这个方法：分页加载的列表在"播放全部"时只能把
  /// 已加载的那一部分入队 —— 用户点开一个 348 首的收藏夹、按下
  /// "播放全部"，结果只播了 50 首，这是不能接受的。
  /// 用"加载到第 N 页"来间接达成同样效果也可以，但那样每个调用方
  /// 都要自己写循环、自己判终止条件，迟早有一处写漏。
  ///
  /// [maxSongs] 只是防御性上限，防止异常数据（例如服务端返回了
  /// 一个荒谬的 total）把内存和请求次数打爆。
  Future<List<Song>> allCollectionTracks(
    String collectionId, {
    int maxSongs = 3000,
  });

  /// 发现页的推荐内容，按分区返回。
  Future<List<DiscoverFeed>> discover();

  /// 发现页推荐歌单（用于卡片流）。
  Future<List<MusicCollection>> discoverCollections();

  /// 搜索曲目。
  Future<List<Song>> search(String keyword, {int limit = 30});

  /// 搜索联想词，失败时应返回空列表而不是抛错（输入框不该因为联想失败而报错）。
  Future<List<String>> searchSuggestions(String keyword);

  /// 解析出可播放地址（含必要的请求头）。
  ///
  /// 无法播放时抛 [MusicApiException]，并把原因写在 message 里，
  /// UI 需要原样展示给用户。
  Future<ResolvedStream> resolveStream(Song song);

  /// 歌词。无歌词时返回 [Lyric.empty]，不要返回 null。
  Future<Lyric> lyric(Song song);

  /// 是否已红心 / 收藏。
  Future<bool> isLiked(Song song);

  /// 设置红心 / 收藏状态。
  Future<void> setLiked(Song song, bool liked);
}

/// 按 [MediaSource] 找到对应的 repository。
///
/// 播放器拿到一首歌后只知道它的 source，靠这个注册表路由到具体实现。
/// 用注册表而不是 `switch (source)`，是为了让"新增音源"不需要修改播放器代码。
abstract interface class MusicSourceRegistry {
  /// 取某个音源的实现；不支持该音源时返回 null。
  MusicRepository? bySource(MediaSource source);

  /// 所有已注册的实现。
  List<MusicRepository> get all;
}
