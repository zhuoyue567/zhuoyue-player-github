import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/collection_cache.dart';
import '../../core/cache/sync_policy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/song_list.dart';
import '../../data/models/collection.dart';
import '../../data/models/media_source.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';
import '../player/player_controller.dart';

/// 发现页。
///
/// 数据只来自网易云：哔哩这边没有"每日推荐"这种算法位，硬凑一个
/// 只会让用户困惑。以后哔哩若有推荐接口，加一个音源分区即可。
///
/// 两个区块（推荐流、推荐歌单）各自独立加载、独立失败、独立重试：
/// 一个接口挂了不应该让整页变成错误页。所以状态存在页面本地，
/// 而不是塞进一个全局 `AsyncNotifier` —— 全局状态会把局部失败放大成整页白屏。
class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key, this.onRequestLogin});

  /// 请求登录的回调，由外壳（shell）注入。
  /// 登录弹窗属于全局能力（要跨音源、要写凭据），内容页自己实现不合适。
  final VoidCallback? onRequestLogin;

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

/// 一个极简的「异步区块」状态。
///
/// 不用 `AsyncValue`：它需要配套一个 provider 才能真正省事，
/// 而这里刻意不要全局 provider（见类注释）。
@immutable
class _Loadable<T> {
  const _Loadable({this.data, this.loading = false, this.error});

  final T? data;
  final bool loading;
  final Object? error;

  bool get hasData => data != null;
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  _Loadable<List<DiscoverFeed>> _feeds = const _Loadable<List<DiscoverFeed>>();
  _Loadable<List<MusicCollection>> _collections =
      const _Loadable<List<MusicCollection>>();

  AccountProfile? _account;
  bool _accountLoading = false;

  @override
  void initState() {
    super.initState();
    // 放到首帧之后再发请求：initState 里同步启动 IO 会拖住第一帧，
    // 窗口刚出来时最容易看出卡顿。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadAll());
    });
  }

  Future<void> _loadAll() async {
    // 三个请求并行：它们互不依赖，串行会让首屏白等两轮网络。
    await Future.wait<void>(<Future<void>>[
      _loadFeeds(),
      _loadCollections(),
      _loadAccount(),
    ]);
  }

  Future<void> _loadFeeds() async {
    setState(() {
      _feeds = _Loadable<List<DiscoverFeed>>(data: _feeds.data, loading: true);
    });
    try {
      final MusicRepository? repository = repositoryForWidget(
        ref,
        MediaSource.netease,
      );
      if (repository == null) {
        throw const MusicApiException('网易云音源未注册', source: MediaSource.netease);
      }
      final List<DiscoverFeed> feeds = await repository.discover();
      if (!mounted) return;
      setState(() {
        _feeds = _Loadable<List<DiscoverFeed>>(
          // 空分区不渲染：一个只有标题没有内容的横向列表纯属占位垃圾。
          data: feeds
              .where((DiscoverFeed feed) => !feed.isEmpty)
              .toList(growable: false),
        );
      });
    } on Object catch (error) {
      debugPrint('[discover] 推荐流加载失败: $error');
      if (!mounted) return;
      setState(() {
        _feeds = _Loadable<List<DiscoverFeed>>(data: _feeds.data, error: error);
      });
    }
  }

  Future<void> _loadCollections() async {
    setState(() {
      _collections = _Loadable<List<MusicCollection>>(
        data: _collections.data,
        loading: true,
      );
    });
    try {
      final MusicRepository? repository = repositoryForWidget(
        ref,
        MediaSource.netease,
      );
      if (repository == null) {
        throw const MusicApiException('网易云音源未注册', source: MediaSource.netease);
      }
      final List<MusicCollection> collections = await repository
          .discoverCollections();
      if (!mounted) return;
      setState(() {
        _collections = _Loadable<List<MusicCollection>>(data: collections);
      });
    } on Object catch (error) {
      debugPrint('[discover] 推荐歌单加载失败: $error');
      if (!mounted) return;
      setState(() {
        _collections = _Loadable<List<MusicCollection>>(
          data: _collections.data,
          error: error,
        );
      });
    }
  }

  Future<void> _loadAccount() async {
    final MusicRepository? repository = repositoryForWidget(
      ref,
      MediaSource.netease,
    );
    if (repository == null) return;

    final AccountProfile? cached = repository.account;
    if (cached != null) {
      setState(() => _account = cached);
      return;
    }
    // 未登录就别去请求账号接口了：那必然是一次 301，白白刷一条错误日志。
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
      debugPrint('[discover] 账号信息加载失败: $error');
      if (!mounted) return;
      setState(() => _accountLoading = false);
    }
  }

  void _playFeed(DiscoverFeed feed) => _playSongs(feed.songs);

  void _playSongs(List<Song> songs) {
    unawaited(ref.read(playerControllerProvider.notifier).playQueue(songs));
  }

  void _openCollection(MusicCollection collection) {
    // 用最近的 Navigator：如果外壳在内容区里嵌了嵌套 Navigator，
    // 详情页就只会盖住内容区，侧边栏和播放条依然在。
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => CollectionDetailPage(
            collection: collection,
            onRequestLogin: widget.onRequestLogin,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MusicRepository? repository = repositoryForWidget(
      ref,
      MediaSource.netease,
    );
    final bool authenticated = repository?.isAuthenticated ?? false;

    return PageContentContainer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          _WelcomeHeader(
            account: _account,
            loading: _accountLoading,
            authenticated: authenticated,
            onRequestLogin: widget.onRequestLogin,
          ),
          const SizedBox(height: 22),
          _buildFeedsArea(),
          _buildCollectionsArea(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildFeedsArea() {
    final _Loadable<List<DiscoverFeed>> state = _feeds;

    if (state.loading && !state.hasData) {
      return const _SectionLoading(label: '正在加载每日推荐…');
    }

    final Object? error = state.error;
    final List<DiscoverFeed> feeds = state.data ?? const <DiscoverFeed>[];
    if (error != null && feeds.isEmpty) {
      return ErrorStateView(
        error: error,
        onRetry: () => unawaited(_loadFeeds()),
        onRequestLogin: widget.onRequestLogin,
      );
    }
    if (feeds.isEmpty) {
      return EmptyStateView(
        icon: Icons.explore_outlined,
        title: '暂时没有推荐内容',
        message: '「每日推荐」需要登录网易云账号后才有内容',
        action: OutlinedButton.icon(
          onPressed: () => unawaited(_loadFeeds()),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('重新加载'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final DiscoverFeed feed in feeds) ...<Widget>[
          _FeedSection(feed: feed, onPlayAll: () => _playFeed(feed)),
          const SizedBox(height: 24),
        ],
      ],
    );
  }

  Widget _buildCollectionsArea() {
    final _Loadable<List<MusicCollection>> state = _collections;

    if (state.loading && !state.hasData) {
      return const _SectionLoading(label: '正在加载推荐歌单…');
    }

    final Object? error = state.error;
    final List<MusicCollection> collections =
        state.data ?? const <MusicCollection>[];
    if (error != null && collections.isEmpty) {
      return ErrorStateView(
        error: error,
        onRetry: () => unawaited(_loadCollections()),
        onRequestLogin: widget.onRequestLogin,
      );
    }
    if (collections.isEmpty) {
      return EmptyStateView(
        icon: Icons.library_music_outlined,
        title: '暂时没有推荐歌单',
        action: OutlinedButton.icon(
          onPressed: () => unawaited(_loadCollections()),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('重新加载'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionTitle(title: '推荐歌单'),
        const SizedBox(height: 14),
        GridView.builder(
          shrinkWrap: true,
          // 整页只有一个滚动容器（外层 ListView），网格自己不再滚。
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            crossAxisSpacing: 16,
            mainAxisSpacing: 20,
            // 固定行高：卡片里的歌单名是两行，行高不固定会让网格出现参差。
            mainAxisExtent: 248,
          ),
          itemCount: collections.length,
          itemBuilder: (BuildContext context, int index) {
            final MusicCollection collection = collections[index];
            return CollectionCard(
              collection: collection,
              subtitle: _collectionSubtitle(collection),
              onTap: () => _openCollection(collection),
            );
          },
        ),
      ],
    );
  }

  String _collectionSubtitle(MusicCollection collection) {
    final String creator = collection.creatorName?.trim() ?? '';
    final String owner = creator.isEmpty ? collection.source.label : creator;
    return '$owner · ${collection.trackCount} 首';
  }
}

/// 顶部欢迎区：已登录显示账号卡片，未登录显示紧凑的登录引导。
class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader({
    required this.account,
    required this.authenticated,
    required this.loading,
    required this.onRequestLogin,
  });

  final AccountProfile? account;
  final bool authenticated;
  final bool loading;
  final VoidCallback? onRequestLogin;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AccountProfile? profile = account;

    if (profile != null) {
      return GlassPanel(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: <Widget>[
            ClipOval(
              child: CoverImage(
                url: profile.avatarUrl,
                size: 56,
                borderRadius: BorderRadius.circular(28),
                placeholderIcon: Icons.person_rounded,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _greeting(DateTime.now()),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          profile.nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      if (profile.vipLabel != null) ...<Widget>[
                        const SizedBox(width: 8),
                        _VipBadge(label: profile.vipLabel!),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    profile.signature?.isNotEmpty ?? false
                        ? profile.signature!
                        : '欢迎回来，今天想听点什么？',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onRequestLogin != null)
              TextButton.icon(
                onPressed: onRequestLogin,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('切换账号'),
              ),
          ],
        ),
      );
    }

    return GlassPanel(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: <Widget>[
          if (loading)
            const SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
            )
          else
            Icon(
              Icons.account_circle_outlined,
              size: 40,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '网易云账号未登录',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  onRequestLogin == null
                      ? '登录后可见「每日推荐」；当前登录入口尚未接入，请先在设置里登录'
                      : '登录后可见「每日推荐」、我喜欢的音乐和私人歌单',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onRequestLogin,
            icon: const Icon(Icons.login_rounded, size: 18),
            label: const Text('登录'),
          ),
        ],
      ),
    );
  }

  /// 问候语跟着系统时间走：一个静态的"欢迎回来"其实很敷衍。
  String _greeting(DateTime now) {
    final int hour = now.hour;
    if (hour < 6) return '夜深了';
    if (hour < 11) return '早上好';
    if (hour < 13) return '中午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }
}

/// 会员身份的小胶囊。
class _VipBadge extends StatelessWidget {
  const _VipBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(context.tokens.pillRadius),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// 一个推荐分区：标题 + 播放全部 + 横向滚动的歌曲卡片。
class _FeedSection extends StatelessWidget {
  const _FeedSection({required this.feed, required this.onPlayAll});

  final DiscoverFeed feed;
  final VoidCallback onPlayAll;

  @override
  Widget build(BuildContext context) {
    final String subtitle = feed.subtitle?.trim().isNotEmpty ?? false
        ? feed.subtitle!
        : '${feed.songs.length} 首 · ${feed.source.label}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionTitle(
          title: feed.title,
          subtitle: subtitle,
          trailing: TextButton.icon(
            onPressed: onPlayAll,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('播放全部'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          // 高度要覆盖「封面 164 + 文字块 48 + 上下留白 16」，再留几像素给
          // 悬浮抬起。SongCard 现在会让封面自己吸收多余空间，
          // 所以这个值偏大也不会溢出，只是封面会略小一点。
          height: 236,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
            itemCount: feed.songs.length,
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(width: 14),
            itemBuilder: (BuildContext context, int index) =>
                SongCard(song: feed.songs[index], queue: feed.songs),
          ),
        ),
      ],
    );
  }
}

/// 分区标题：主标题 + 说明 + 右侧操作。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ?trailing,
      ],
    );
  }
}

/// 区块级的加载提示（不是整页转圈：其他区块可能已经加载好了）。
class _SectionLoading extends StatelessWidget {
  const _SectionLoading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 歌单详情页（发现页点开一张歌单卡片进来）。
///
/// 分页：滚到离底部 400px 就预取下一页，同时保留一个显式的「加载更多」按钮 ——
/// 桌面端用户更习惯"点一下"，而滚动预取只是为了不让人等。
class CollectionDetailPage extends ConsumerStatefulWidget {
  const CollectionDetailPage({
    super.key,
    required this.collection,
    this.onRequestLogin,
  });

  final MusicCollection collection;
  final VoidCallback? onRequestLogin;

  @override
  ConsumerState<CollectionDetailPage> createState() =>
      _CollectionDetailPageState();
}

class _CollectionDetailPageState extends ConsumerState<CollectionDetailPage> {
  static const int _pageSize = 50;

  final ScrollController _scroll = ScrollController();
  final List<Song> _songs = <Song>[];

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  Object? _error;
  Object? _moreError;
  int? _total;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load(reset: true));
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    // 提前 400px 预取：等到滚到底再发请求，用户一定会看到"白一下"。
    if (_scroll.position.extentAfter > 400) return;
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    await _load(reset: false);
  }

  /// 加载曲目。[force] 为 true 时跳过同步频率限制（下拉刷新用：
  /// 用户主动下拉就是明确表达"现在就要最新的"）。
  Future<void> _load({required bool reset, bool force = false}) async {
    final MusicRepository? repository = repositoryForWidget(
      ref,
      widget.collection.source,
    );
    if (repository == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = MusicApiException(
          '该音源的实现未注册，无法加载歌单内容',
          source: widget.collection.source,
        );
      });
      return;
    }

    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
      _moreError = null;
    });

    try {
      if (reset) {
        // 与歌单页一致：**先出本地缓存，再和云端差量同步**。
        //
        // 发现页打开的是公开歌单，同样值得缓存 —— 断网时"我上次看过的那个
        // 歌单"照样能打开，而不是给一块错误态。
        final CollectionCache cache = ref.read(collectionCacheProvider);
        final CollectionCacheEntry? entry = await cache.read(
          widget.collection.source,
          widget.collection.id,
        );
        if (entry != null && entry.songs.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _songs
              ..clear()
              ..addAll(entry.songs);
            _hasMore = false;
            _total = entry.songs.length;
            _loading = false;
            _loadingMore = false;
            _error = null;
          });
        }

        final SyncPolicy policy = ref.read(syncPolicyProvider);
        if (force || policy.isDue(entry?.fetchedAt)) {
          final CollectionSyncOutcome outcome = await cache
              .computeCollectionSync(
                repository: repository,
                collection: widget.collection,
                cached: entry?.songs ?? const <Song>[],
              );
          await cache.write(
            widget.collection.source,
            widget.collection.id,
            songs: outcome.songs,
            remoteTotal: outcome.remoteTotal,
            name: widget.collection.name,
          );
          if (!mounted) return;
          setState(() {
            _songs
              ..clear()
              ..addAll(outcome.songs);
            _hasMore = false;
            _total = outcome.songs.length;
            _loading = false;
            _loadingMore = false;
            _error = null;
          });
          return;
        }

        if (entry != null) {
          // 还没到同步时间：缓存就是当前内容，不发请求。
          return;
        }

        // 没有缓存且不需要同步（例如"仅手动"）→ 退回一次完整拉取，
        // 否则用户点进来只会看到空白。
        final List<Song> all = await repository.allCollectionTracks(
          widget.collection.id,
        );
        if (!mounted) return;
        setState(() {
          _songs
            ..clear()
            ..addAll(all);
          _hasMore = false;
          _total = all.length;
          _loading = false;
          _loadingMore = false;
          _error = null;
        });
        return;
      }

      final CollectionTracksPage page = await repository.collectionTracks(
        widget.collection.id,
        offset: _songs.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _songs.clear();
        _songs.addAll(page.songs);
        _hasMore = page.hasMore;
        _total = page.total ?? _total;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } on Object catch (error) {
      debugPrint('[collection] 加载曲目失败 ${widget.collection.uid}: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        // 首屏失败给整块错误态；翻页失败只在列表尾部提示，已加载的内容留着。
        if (reset) {
          _error = error;
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
    // MusicRepository 目前只暴露曲目级的 isLiked / setLiked，没有"收藏歌单"
    // 这个动作。与其把按钮做成一个点了没反应的假开关，不如如实说明。
    _showMessage(context, '歌单收藏接口尚未接入：音源目前只提供曲目级红心，等 repository 支持后再接这里');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 详情页是 Navigator 推上来的独立路由，给它一个透明 Scaffold：
      // 1. SnackBar 需要有 Scaffold 才能落地，否则会飘到被盖住的下层去；
      // 2. 底色必须透明，窗口的毛玻璃要能透出来。
      backgroundColor: Colors.transparent,
      body: PageContentContainer(
        child: Column(
          children: <Widget>[
            _DetailTopBar(title: widget.collection.name),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final Widget header = CollectionHeaderView(
      collection: widget.collection,
      trackCount: _total,
      onPlayAll: _songs.isEmpty ? null : _playAll,
            onAddToQueue: _songs.isEmpty ? null : _appendAll,
      onFavorite: _explainFavorite,
    );

    final Widget emptyState;
    final Object? error = _error;
    if (error != null && _songs.isEmpty) {
      emptyState = ErrorStateView(
        error: error,
        onRetry: () => unawaited(_load(reset: true)),
        onRequestLogin: widget.onRequestLogin,
      );
    } else if (_loading) {
      emptyState = const EmptyStateView(
        busy: true,
        icon: Icons.hourglass_empty_rounded,
        title: '正在加载曲目…',
      );
    } else {
      emptyState = const SongListEmptyState(message: '这个歌单 / 收藏夹里还没有可播放的内容');
    }

    return SongListView(
      controller: _scroll,
      songs: _songs,
      header: header,
      footer: _buildFooter(),
      showAlbum: true,
      emptyState: emptyState,
      onRefresh: () => _load(reset: true, force: true),
    );
  }

  Widget? _buildFooter() {
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
              onPressed: () => unawaited(_load(reset: false)),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_loadingMore) {
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

    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton.icon(
            onPressed: () => unawaited(_load(reset: false)),
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

/// 详情页顶栏：返回按钮 + 歌单名。
class _DetailTopBar extends StatelessWidget {
  const _DetailTopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹一条提示。取不到 messenger 时静默降级（页面可能被放在没有 Scaffold 的地方）。
void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}
