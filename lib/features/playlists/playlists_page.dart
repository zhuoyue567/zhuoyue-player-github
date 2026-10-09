import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/collection_cache.dart';
import '../../core/cache/sync_policy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/page_layout.dart';
import '../../core/ui/song_list.dart';
import '../../data/models/collection.dart';
import '../../data/models/media_source.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';
import '../downloads/downloads_page.dart';
import '../player/player_controller.dart';

/// 「我的歌单 / 收藏夹」页。
///
/// 左侧是当前音源下我的集合列表，右侧是选中集合的曲目。
/// 音源由外壳通过 [source] 注入（网易云和哔哩各是一个入口），
/// 页面本身不认识任何具体实现 —— 这正是 `MusicRepository` 抽象的意义。
///
/// 两栏各自独立滚动：左侧几十个歌单、右侧上千首曲目，
/// 用一个外层滚动条串起来的话，滚哪边都不对。
class PlaylistsPage extends ConsumerStatefulWidget {
  const PlaylistsPage({super.key, required this.source, this.onRequestLogin});

  final MediaSource source;

  /// 请求登录的回调，由外壳（shell）注入：登录弹窗要跨音源共享凭据，
  /// 属于全局能力，不由内容页实现。
  final VoidCallback? onRequestLogin;

  @override
  ConsumerState<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends ConsumerState<PlaylistsPage> {
  static const int _pageSize = 50;

  final ScrollController _songScroll = ScrollController();
  final List<Song> _songs = <Song>[];

  List<MusicCollection> _collections = const <MusicCollection>[];
  bool _loadingCollections = true;
  Object? _collectionsError;

  AccountProfile? _account;
  bool _accountLoading = false;

  MusicCollection? _selected;
  bool _loadingSongs = false;
  bool _loadingMoreSongs = false;
  bool _hasMoreSongs = false;
  Object? _songsError;
  Object? _moreError;
  int? _total;

  // ------------------------------------------------------------ 同步状态

  /// 当前列表是否来自本地缓存（用于显示"来自本地缓存"）。
  bool _fromCache = false;

  /// 上次同步成功的时间。null 表示还没同步过（可能只有缓存）。
  DateTime? _lastSyncedAt;

  /// 正在与云端同步。
  bool _syncing = false;

  /// 最近一次同步的净变化，用来给用户一句"新增 2 首、移除 1 首"。
  int _syncAdded = 0;
  int _syncRemoved = 0;

  /// 同步失败的原因。**不影响已展示的缓存内容**：断网时歌单照样要能看。
  String? _syncNote;

  @override
  void initState() {
    super.initState();
    _songScroll.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadAll());
    });
  }

  @override
  void dispose() {
    _songScroll.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await Future.wait<void>(<Future<void>>[_loadAccount(), _loadCollections()]);
  }

  // -------------------------------------------------------------------------
  // 账号与歌单列表
  // -------------------------------------------------------------------------

  Future<void> _loadAccount() async {
    final MusicRepository? repository = repositoryForWidget(ref, widget.source);
    if (repository == null) return;

    final AccountProfile? cached = repository.account;
    if (cached != null) {
      setState(() => _account = cached);
      return;
    }
    // 未登录就别请求账号接口了：必然是一次 301，只会刷一条错误日志。
    if (!repository.isAuthenticated) return;

    setState(() => _accountLoading = true);
    try {
      final AccountProfile? profile = await repository.refreshAccount();
      if (!mounted) return;
      setState(() {
        _account = profile;
        _accountLoading = false;
      });
    } on Object catch (error) {
      debugPrint('[playlists] 账号信息加载失败: $error');
      if (!mounted) return;
      setState(() => _accountLoading = false);
    }
  }

  Future<void> _loadCollections() async {
    final MusicRepository? repository = repositoryForWidget(ref, widget.source);
    if (repository == null) {
      setState(() {
        _loadingCollections = false;
        _collectionsError = MusicApiException(
          '该音源的实现未注册，无法读取歌单',
          source: widget.source,
        );
      });
      return;
    }

    setState(() {
      _loadingCollections = true;
      _collectionsError = null;
    });

    if (!repository.isAuthenticated) {
      // 未登录时把列表清空并交给登录引导：不要留下上一次登录的残留歌单。
      setState(() {
        _collections = const <MusicCollection>[];
        _loadingCollections = false;
        _selected = null;
        _songs.clear();
      });
      return;
    }

    try {
      final List<MusicCollection> collections = await repository
          .myCollections();
      if (!mounted) return;
      setState(() {
        _collections = collections;
        _loadingCollections = false;
        _collectionsError = null;
      });
      await _syncSelection(collections);
    } on Object catch (error) {
      debugPrint('[playlists] 歌单列表加载失败: $error');
      if (!mounted) return;
      setState(() {
        _loadingCollections = false;
        _collectionsError = error;
      });
    }
  }

  /// 刷新后把选中项对齐到新列表上。
  ///
  /// 三种情况分开处理，是为了避免"刷一下歌单，右侧曲目被清空重载"：
  /// - 之前选着的还在 → 只换成新对象，曲目不动；
  /// - 之前选的没了（被删了）→ 落到第一个；
  /// - 之前没选（首次进入）→ 自动选中第一个，右侧空着会让人以为页面坏了。
  Future<void> _syncSelection(List<MusicCollection> collections) async {
    final MusicCollection? previous = _selected;
    if (previous != null) {
      for (final MusicCollection item in collections) {
        if (item.uid == previous.uid) {
          setState(() => _selected = item);
          return;
        }
      }
    }
    if (collections.isEmpty) {
      setState(() {
        _selected = null;
        _songs.clear();
        _total = null;
        _hasMoreSongs = false;
      });
      return;
    }
    await _select(collections.first);
  }

  Future<void> _refresh() async {
    await _loadAccount();
    await _loadCollections();
  }

  // -------------------------------------------------------------------------
  // 曲目
  // -------------------------------------------------------------------------

  Future<void> _select(MusicCollection collection) async {
    if (_selected?.uid == collection.uid && _songs.isNotEmpty) return;
    setState(() {
      _selected = collection;
      _songs.clear();
      _total = null;
      _songsError = null;
      _moreError = null;
      _hasMoreSongs = false;
    });
    await _loadSongs(reset: true);
  }

  void _maybeLoadMore() {
    if (!_songScroll.hasClients) return;
    // 提前 400px 预取：等滚到底再发请求，用户一定会看到"白一下"。
    if (_songScroll.position.extentAfter > 400) return;
    unawaited(_loadMoreSongs());
  }

  Future<void> _loadMoreSongs() async {
    if (_loadingSongs || _loadingMoreSongs || !_hasMoreSongs) return;
    await _loadSongs(reset: false);
  }

  /// 先把本地缓存显示出来。没有缓存就什么都不做（后面那次同步会给内容）。
  Future<void> _showCachedSongs(MusicCollection collection) async {
    final CollectionCacheEntry? entry = await ref
        .read(collectionCacheProvider)
        .read(collection.source, collection.id);
    if (entry == null || entry.songs.isEmpty) return;
    if (!mounted || _selected?.uid != collection.uid) return;
    setState(() {
      _songs
        ..clear()
        ..addAll(entry.songs);
      _hasMoreSongs = false;
      _total = entry.songs.length;
      _fromCache = true;
      _lastSyncedAt = entry.fetchedAt;
      _syncAdded = 0;
      _syncRemoved = 0;
      _syncNote = null;
      // 已经有内容可看了，首屏 loading 到此结束。
      _loadingSongs = false;
    });
  }

  /// 与云端差量同步。失败时返回 null 并把原因写进 [_syncNote]，
  /// **不清空已展示的缓存内容** —— 离线可用是这个功能的全部意义。
  Future<CollectionSyncOutcome?> _syncSongs(
    MusicCollection collection, {
    bool force = false,
  }) async {
    setState(() {
      _syncing = true;
      _syncNote = null;
    });
    try {
      final CollectionCache cache = ref.read(collectionCacheProvider);
      final MusicRepository? repository = repositoryForWidget(
        ref,
        collection.source,
      );
      if (repository == null) {
        if (mounted) setState(() => _syncing = false);
        return null;
      }

      final CollectionCacheEntry? entry = await cache.read(
        collection.source,
        collection.id,
      );
      final SyncPolicy policy = ref.read(syncPolicyProvider);
      final bool due = force || policy.isDue(entry?.fetchedAt);
      if (!due) {
        // 还没到同步时间：缓存就是当前结果，不发任何请求。
        if (mounted) setState(() => _syncing = false);
        return entry == null
            ? null
            : CollectionSyncOutcome(
                songs: entry.songs,
                added: 0,
                removed: 0,
                remoteTotal: entry.remoteTotal,
                pageRequests: 0,
              );
      }

      final CollectionSyncOutcome outcome = await cache.computeCollectionSync(
        repository: repository,
        collection: collection,
        cached: entry?.songs ?? const <Song>[],
      );
      await cache.write(
        collection.source,
        collection.id,
        songs: outcome.songs,
        remoteTotal: outcome.remoteTotal,
        name: collection.name,
      );
      if (mounted) {
        setState(() {
          _fromCache = false;
          _syncing = false;
        });
      }
      return outcome;
    } on Object catch (error) {
      debugPrint('[playlists] 同步失败 ${collection.uid}: $error');
      if (mounted) {
        setState(() {
          _syncing = false;
          _syncNote = error is MusicApiException ? error.message : '$error';
        });
      }
      return null;
    }
  }

  /// 用户点「立即同步」：无论频率怎么设都强制同步一次。
  Future<void> _forceSync() async {
    final MusicCollection? collection = _selected;
    if (collection == null) return;
    final CollectionSyncOutcome? outcome = await _syncSongs(
      collection,
      force: true,
    );
    if (outcome == null || !mounted || _selected?.uid != collection.uid) return;
    setState(() {
      _songs
        ..clear()
        ..addAll(outcome.songs);
      _total = outcome.songs.length;
      _lastSyncedAt = DateTime.now();
      _syncAdded = outcome.added;
      _syncRemoved = outcome.removed;
    });
  }

  Future<void> _loadSongs({required bool reset}) async {
    final MusicCollection? collection = _selected;
    if (collection == null) return;

    final MusicRepository? repository = repositoryForWidget(
      ref,
      collection.source,
    );
    if (repository == null) {
      setState(() {
        _loadingSongs = false;
        _loadingMoreSongs = false;
        _songsError = MusicApiException(
          '该音源的实现未注册，无法加载曲目',
          source: collection.source,
        );
      });
      return;
    }

    setState(() {
      if (reset) {
        _loadingSongs = true;
        _songsError = null;
      } else {
        _loadingMoreSongs = true;
      }
      _moreError = null;
    });

    try {
      if (reset) {
        // 打开歌单：**先出本地缓存，再和云端差量同步**。
        //
        // 两步是刻意的，不能合并成一次 await：
        // 1. 读缓存是一次本地文件读（毫秒级），所以歌单能"秒开"，
        //    断网时也照样能看、能播 —— 这是缓存这个功能的主要意义；
        // 2. 同步可能联网（最慢要一两秒），如果等它回来再渲染，
        //    用户每次打开歌单都要先看一次 loading，缓存就白做了。
        await _showCachedSongs(collection);

        final CollectionSyncOutcome? outcome = await _syncSongs(collection);
        if (outcome == null) return;
        if (!mounted || _selected?.uid != collection.uid) return;
        setState(() {
          _songs
            ..clear()
            ..addAll(outcome.songs);
          _hasMoreSongs = false;
          _total = outcome.songs.length;
          _lastSyncedAt = DateTime.now();
          _syncAdded = outcome.added;
          _syncRemoved = outcome.removed;
          _syncNote = null;
          _syncing = false;
          _loadingSongs = false;
          _loadingMoreSongs = false;
          _songsError = null;
        });
        return;
      }

      final CollectionTracksPage page = await repository.collectionTracks(
        collection.id,
        offset: _songs.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      // 用户可能在请求返回前切了歌单：这份结果已经过期，直接丢掉，
      // 否则上一个歌单的曲目会串进当前列表（分页场景下极难排查）。
      if (_selected?.uid != collection.uid) return;
      setState(() {
        if (reset) _songs.clear();
        _songs.addAll(page.songs);
        _hasMoreSongs = page.hasMore;
        _total = page.total ?? _total;
        _loadingSongs = false;
        _loadingMoreSongs = false;
        _songsError = null;
      });
    } on Object catch (error) {
      debugPrint('[playlists] 曲目加载失败 ${collection.uid}: $error');
      if (!mounted || _selected?.uid != collection.uid) return;
      setState(() {
        _loadingSongs = false;
        _loadingMoreSongs = false;
        // 首屏失败给整块错误态；翻页失败只在列表尾部提示，已加载的内容留着。
        if (reset) {
          _songsError = error;
        } else {
          _moreError = error;
        }
      });
    }
  }

  void _playAll() {
    unawaited(ref.read(playerControllerProvider.notifier).playQueue(_songs));
  }

  /// 把这个歌单**追加**到当前队列末尾（增量添加，不动正在播放的那首）。
  void _appendAll() {
    final int count = _songs.length;
    unawaited(
      ref.read(playerControllerProvider.notifier).appendToQueue(_songs),
    );
    _showMessage(context, '已把 $count 首加入播放队列');
  }

  void _explainFavorite() {
    // MusicRepository 只有曲目级的 isLiked / setLiked，没有"收藏歌单"这个动作。
    // 与其做成点了没反应的假开关，不如如实说明。
    _showMessage(context, '歌单收藏接口尚未接入：音源目前只提供曲目级红心，等 repository 支持后再接这里');
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final MusicRepository? repository = repositoryForWidget(ref, widget.source);
    final bool authenticated = repository?.isAuthenticated ?? false;

    // 中栏（歌单列表）与右栏（曲目列表）的上下留白这里**不写**：
    // 它们由 ThreeColumnBody 统一给出，与外壳左侧导航栏取自同一份定义。
    // 以前中栏是页面自己套一层 20/24、导航栏套的是 4/0，两栏差出 40px，
    // 中栏那张卡看起来就比旁边矮一截。
    return ThreeColumnBody(
      middleWidth: 292,
      middle: _buildSidebar(authenticated),
      content: _buildContent(authenticated),
    );
  }

  Widget _buildSidebar(bool authenticated) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildAccountCard(authenticated),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.source == MediaSource.bilibili ? '我的收藏夹' : '我的歌单',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                iconSize: 18,
                tooltip: '刷新歌单列表',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                onPressed: _loadingCollections
                    ? null
                    : () => unawaited(_refresh()),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildCollectionsArea(authenticated)),
          if (widget.source == MediaSource.bilibili)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '提示：收藏夹里音频区的内容是完整可播放的，视频稿件会取其中的音频轨。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(bool authenticated) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;
    final AccountProfile? profile = _account;

    Widget surface({required Widget child}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(tokens.cardRadius),
        ),
        child: child,
      );
    }

    if (!authenticated) {
      return surface(
        child: Row(
          children: <Widget>[
            Icon(
              Icons.account_circle_outlined,
              size: 34,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${widget.source.label}未登录',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '登录后可读取我的歌单',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (profile == null) {
      return surface(
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: 34,
              height: 34,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _accountLoading ? '正在读取账号…' : '已登录（账号信息未拉取）',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return surface(
      child: Row(
        children: <Widget>[
          ClipOval(
            child: CoverImage(
              url: profile.avatarUrl,
              size: 40,
              borderRadius: BorderRadius.circular(20),
              placeholderIcon: Icons.person_rounded,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        profile.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (profile.vipLabel != null) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(
                            tokens.pillRadius,
                          ),
                        ),
                        child: Text(
                          profile.vipLabel!,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.source.label} · ${_collections.length} 个歌单',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollectionsArea(bool authenticated) {
    if (!authenticated) {
      return EmptyStateView(
        icon: Icons.lock_outline_rounded,
        title: '需要登录',
        message: '${widget.source.label}账号登录后才能读取你的歌单',
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
        action: widget.onRequestLogin == null
            ? null
            : FilledButton.icon(
                onPressed: widget.onRequestLogin,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('登录'),
              ),
      );
    }

    if (_loadingCollections && _collections.isEmpty) {
      return const EmptyStateView(
        busy: true,
        icon: Icons.hourglass_empty_rounded,
        title: '正在读取歌单…',
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      );
    }

    final Object? error = _collectionsError;
    if (error != null && _collections.isEmpty) {
      return ErrorStateView(
        error: error,
        onRetry: () => unawaited(_refresh()),
        onRequestLogin: widget.onRequestLogin,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      );
    }

    if (_collections.isEmpty) {
      return const EmptyStateView(
        icon: Icons.queue_music_rounded,
        title: '还没有歌单',
        message: '这个账号下暂时读不到歌单 / 收藏夹',
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: _collections.length,
      itemBuilder: (BuildContext context, int index) {
        final MusicCollection collection = _collections[index];
        return _CollectionTile(
          collection: collection,
          selected: _selected?.uid == collection.uid,
          onTap: () => unawaited(_select(collection)),
        );
      },
    );
  }

  Widget _buildContent(bool authenticated) {
    if (!authenticated) {
      return EmptyStateView(
        icon: Icons.lock_outline_rounded,
        title: '${widget.source.label}账号未登录',
        message: '登录后这里会列出你的歌单 / 收藏夹，以及里面的曲目',
        action: widget.onRequestLogin == null
            ? null
            : FilledButton.icon(
                onPressed: widget.onRequestLogin,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('登录'),
              ),
      );
    }

    final MusicCollection? selected = _selected;
    if (selected == null) {
      if (_loadingCollections) {
        return const EmptyStateView(
          busy: true,
          icon: Icons.hourglass_empty_rounded,
          title: '正在读取歌单…',
        );
      }
      final Object? error = _collectionsError;
      if (error != null && _collections.isEmpty) {
        return ErrorStateView(
          error: error,
          onRetry: () => unawaited(_refresh()),
          onRequestLogin: widget.onRequestLogin,
        );
      }
      return const EmptyStateView(
        icon: Icons.playlist_play_rounded,
        title: '从左侧选择一个歌单',
        message: '左侧列出的都是这个音源里你自己的歌单 / 收藏夹',
      );
    }

    final Widget emptyState;
    final Object? songsError = _songsError;
    if (songsError != null && _songs.isEmpty) {
      emptyState = ErrorStateView(
        error: songsError,
        onRetry: () => unawaited(_loadSongs(reset: true)),
        onRequestLogin: widget.onRequestLogin,
      );
    } else if (_loadingSongs) {
      emptyState = const EmptyStateView(
        busy: true,
        icon: Icons.hourglass_empty_rounded,
        title: '正在加载曲目…',
      );
    } else {
      emptyState = const SongListEmptyState(message: '这个集合里还没有可播放的内容');
    }

    return SongListView(
      controller: _songScroll,
      songs: _songs,
      // ★ 纵向**不留**内边距，只留横向。
      //
      // `SongListView` 默认是 `symmetric(horizontal: 4, vertical: 6)`，那 6px
      // 会把整块内容（包括最上面的歌单总览卡）往下推 —— 而左边的歌单列表卡
      // 和它的顶部是一样高的。结果就是"右边总览卡的上沿比左边列表低一截"。
      // 纵向的呼吸空间由外层 `ThreeColumnBody` 的 20/24 留白提供，
      // 这里再来一份是重复的，也正是错位的来源。
      padding: const EdgeInsets.symmetric(horizontal: 4),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CollectionHeaderView(
            collection: selected,
            trackCount: _total,
            compact: true,
            onPlayAll: _songs.isEmpty ? null : _playAll,
            onAddToQueue: _songs.isEmpty ? null : _appendAll,
            onFavorite: _explainFavorite,
          ),
          _buildSyncBar(selected),
        ],
      ),
      footer: _buildSongsFooter(),
      showAlbum: true,
      // 歌单里的歌也要能直接下载：否则「下载管理」就只剩搜索一个入口。
      onDownload: _download,
      emptyState: emptyState,
      onRefresh: () => _loadSongs(reset: true),
    );
  }

  /// 把曲目交给下载队列。
  ///
  /// 下载器可能是 null（`downloadQueueProvider` 还没被 override），
  /// 这时给一句明确说明，而不是点了没反应。
  void _download(Song song) {
    final DownloadQueue? queue = ref.read(downloadQueueProvider);
    if (queue == null) {
      _showMessage(context, '下载器未启用');
      return;
    }
    if (!song.playable) {
      _showMessage(context, song.unplayableReason ?? '该曲目当前不可下载');
      return;
    }
    unawaited(queue.start(song));
    _showMessage(context, '已加入下载：${song.title}');
  }

  /// 同步状态条：来自哪里、上次同步于何时、立即同步、同步频率。
  ///
  /// 放在歌单头部而不是设置页：用户关心"这个歌单新不新"是**在这里**关心的，
  /// 频率又是一个很少改、但改了想立刻看到效果的选项。
  Widget _buildSyncBar(MusicCollection collection) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;
    final SyncFrequency frequency = ref.watch(syncFrequencyProvider);
    final DateTime? syncedAt = _lastSyncedAt;

    final String status;
    if (_syncing) {
      status = '正在与云端同步…';
    } else if (_syncNote != null) {
      // 同步失败时必须说清楚"你看到的是缓存"，否则用户会以为歌单丢了歌。
      status = '同步失败：${_syncNote!}（当前显示本地缓存）';
    } else if (syncedAt == null) {
      status = '还没有本地缓存';
    } else {
      final String relative = ZhyFormat.relativeTime(syncedAt);
      final String changes = (_syncAdded == 0 && _syncRemoved == 0)
          ? '云端无变化'
          : '新增 $_syncAdded 首${_syncRemoved > 0 ? '、移除 $_syncRemoved 首' : ''}';
      status = '${_fromCache ? "本地缓存" : "已同步"} · $relative · $changes';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Row(
        children: <Widget>[
          if (_syncing)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            )
          else
            Icon(
              _syncNote != null
                  ? Icons.cloud_off_rounded
                  : Icons.cloud_done_rounded,
              size: 14,
              color: _syncNote != null ? scheme.error : scheme.onSurfaceVariant,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: _syncNote != null
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 同步频率：改完立刻生效（provider 自己会写盘）。
          PopupMenuButton<SyncFrequency>(
            tooltip: '同步频率',
            initialValue: frequency,
            onSelected: (SyncFrequency value) {
              ref.read(syncFrequencyProvider.notifier).setFrequency(value);
            },
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<SyncFrequency>>[
                  for (final SyncFrequency value in SyncFrequency.values)
                    PopupMenuItem<SyncFrequency>(
                      value: value,
                      child: Row(
                        children: <Widget>[
                          Icon(
                            value == frequency
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 15,
                          ),
                          const SizedBox(width: 8),
                          Text(value.label),
                        ],
                      ),
                    ),
                ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(tokens.cardRadius),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.schedule_rounded, size: 13),
                  const SizedBox(width: 6),
                  Text(frequency.label, style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _syncing ? null : _forceSync,
            icon: const Icon(Icons.sync_rounded, size: 14),
            label: const Text('立即同步', style: TextStyle(fontSize: 11.5)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildSongsFooter() {
    if (_songs.isEmpty) return null;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Object? moreError = _moreError;

    if (moreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: <Widget>[
            Text(
              '加载更多失败：${describeApiError(moreError)}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: scheme.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => unawaited(_loadSongs(reset: false)),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_loadingMoreSongs) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              '正在加载更多…',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (_hasMoreSongs) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton.icon(
            onPressed: () => unawaited(_loadSongs(reset: false)),
            icon: const Icon(Icons.expand_more_rounded, size: 18),
            label: const Text('加载更多'),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: Text(
          '已经到底了 · 共 ${_songs.length} 首',
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

/// 左侧列表里的一行歌单。
class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.collection,
    required this.selected,
    required this.onTap,
  });

  final MusicCollection collection;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? creator = collection.creatorName;

    return HoverBuilder(
      builder: (BuildContext context, bool hovered) {
        Color background = Colors.transparent;
        if (selected) {
          background = scheme.primaryContainer.withValues(alpha: 0.5);
        } else if (hovered) {
          background = scheme.primary.withValues(alpha: ZhyTokens.hoverOverlay);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: tokens.fast,
            curve: ZhyTokens.standardCurve,
            height: 56,
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(tokens.cardRadius),
            ),
            child: Row(
              children: <Widget>[
                CoverImage(
                  url: collection.coverUrl,
                  size: 40,
                  borderRadius: BorderRadius.circular(8),
                  placeholderIcon: Icons.queue_music_rounded,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        collection.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          // 内置字体只有 w400 一个字面，请求 w600 会被引擎描边
                          // 合成（中文小字因此发虚、笔画不匀），所以这里恒为
                          // w500；选中态只靠下面的 color 区分。
                          fontWeight: FontWeight.w500,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        <String>[
                          '${collection.trackCount} 首',
                          if (creator != null && creator.isNotEmpty) creator,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 弹一条提示。取不到 messenger 时静默降级。
void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}
