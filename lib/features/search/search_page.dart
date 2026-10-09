import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/song_list.dart';
import '../../data/models/media_source.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';
import '../downloads/downloads_page.dart';

/// 搜索页。
///
/// 音源由外壳通过 [source] 注入，搜索行为完全是音源内部的实现细节。
///
/// 这一页真正的难点不是界面，而是**响应乱序**：
/// 输入时带 350ms 防抖地取联想词、回车时取结果，两者都是异步的。
/// 用户快速输入 "abc" 时至少会发出三个联想请求，而它们的返回顺序
/// 由网络决定。"abc" 的结果先回来的话，界面就会先显示 "abc" 的联想词，
/// 然后被随后返回的 "a" 的联想词覆盖 —— 这就是典型的"鬼影结果"。
/// 所以这里给联想和搜索各自维护一个递增的请求序号，
/// 回调里只接受"序号仍然是最新"的那一份，其余一律丢弃。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, required this.source, this.initialKeyword});

  final MediaSource source;

  /// 外部带过来的初始关键词（例如从歌单详情里点"搜索这首歌"）。
  final String? initialKeyword;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  /// 输入防抖时长。350ms 是手感与请求量的折中：
  /// 再短会导致每敲一个字都发一次请求，再长用户会觉得联想"迟钝"。
  static const Duration _debounceDuration = Duration(milliseconds: 350);

  /// 搜索历史只放在内存里：本次运行有效，退出即清空。
  /// 落盘属于"用户数据"，在没有明确的隐私说明之前不写。
  static const int _historyLimit = 10;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<String> _history = <String>[];

  Timer? _debounce;

  /// 联想词请求序号（只增不减，见类注释）。
  int _suggestSeq = 0;

  /// 搜索请求序号，作用同上。
  int _searchSeq = 0;

  List<String> _suggestions = const <String>[];
  bool _loadingSuggestions = false;
  bool _showSuggestions = false;

  List<Song> _results = const <Song>[];
  bool _searching = false;
  bool _hasSearched = false;
  String _keyword = '';
  Object? _error;

  @override
  void initState() {
    super.initState();
    final String? initial = widget.initialKeyword?.trim();
    if (initial != null && initial.isNotEmpty) {
      _controller.text = initial;
      // 首帧之后再搜：initState 里发请求会让页面"先白后内容"。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_runSearch(initial));
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 输入 / 联想
  // -------------------------------------------------------------------------

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final String keyword = value.trim();

    if (keyword.isEmpty) {
      // 清空输入立刻收起联想：等防抖到期才反应会显得"卡住了"。
      setState(() {
        _suggestions = const <String>[];
        _loadingSuggestions = false;
        _showSuggestions = false;
      });
      return;
    }

    setState(() {
      _loadingSuggestions = true;
      _showSuggestions = true;
    });

    final int seq = ++_suggestSeq;
    _debounce = Timer(_debounceDuration, () {
      unawaited(_loadSuggestions(keyword, seq));
    });
  }

  Future<void> _loadSuggestions(String keyword, int seq) async {
    try {
      final MusicRepository? repository = repositoryForWidget(
        ref,
        widget.source,
      );
      if (repository == null) {
        if (mounted && seq == _suggestSeq) {
          setState(() => _loadingSuggestions = false);
        }
        return;
      }
      final List<String> suggestions = await repository.searchSuggestions(
        keyword,
      );
      // 序号对不上 = 用户在等待期间又敲了字，这份结果已经过期。
      if (!mounted || seq != _suggestSeq) return;
      setState(() {
        _suggestions = suggestions;
        _loadingSuggestions = false;
        _showSuggestions = true;
      });
    } on Object catch (error) {
      // 联想失败不报错给用户：输入框不该因为联想接口抽风而弹错误提示。
      debugPrint('[search] 联想词加载失败: $error');
      if (!mounted || seq != _suggestSeq) return;
      setState(() => _loadingSuggestions = false);
    }
  }

  void _clearQuery() {
    _debounce?.cancel();
    _suggestSeq++;
    _searchSeq++;
    _controller.clear();
    setState(() {
      _suggestions = const <String>[];
      _loadingSuggestions = false;
      _showSuggestions = false;
      _results = const <Song>[];
      _searching = false;
      _hasSearched = false;
      _error = null;
    });
    _focusNode.requestFocus();
  }

  // -------------------------------------------------------------------------
  // 搜索
  // -------------------------------------------------------------------------

  Future<void> _runSearch(String input) async {
    final String keyword = input.trim();
    if (keyword.isEmpty) return;

    // 立刻失效掉在途的联想请求，并收起联想面板。
    _debounce?.cancel();
    _suggestSeq++;
    final int seq = ++_searchSeq;

    // 从联想词点进来时，输入框里的内容要跟着变（光标放到末尾），
    // 否则用户下一眼会看到"框里是 abc，结果却是 abcdef"。
    if (_controller.text != keyword) {
      _controller.value = TextEditingValue(
        text: keyword,
        selection: TextSelection.collapsed(offset: keyword.length),
      );
    }

    setState(() {
      _keyword = keyword;
      _searching = true;
      _hasSearched = true;
      _error = null;
      _suggestions = const <String>[];
      _showSuggestions = false;
    });

    try {
      final MusicRepository? repository = repositoryForWidget(
        ref,
        widget.source,
      );
      if (repository == null) {
        throw MusicApiException('该音源的实现未注册，无法搜索', source: widget.source);
      }
      final List<Song> songs = await repository.search(keyword);
      // 同样用序号挡住过期响应：连点两个联想词时，
      // 先发的请求可能后到，不能让旧结果盖掉新结果。
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = songs;
        _searching = false;
      });
      _rememberHistory(keyword);
    } on Object catch (error) {
      debugPrint('[search] 搜索失败「$keyword」: $error');
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _error = error;
        _results = const <Song>[];
      });
    }
  }

  /// 记一条搜索历史。只保留最近 [_historyLimit] 条，重复的提到最前。
  void _rememberHistory(String keyword) {
    setState(() {
      _history.removeWhere(
        (String item) => item.toLowerCase() == keyword.toLowerCase(),
      );
      _history.insert(0, keyword);
      if (_history.length > _historyLimit) {
        _history.removeRange(_historyLimit, _history.length);
      }
    });
  }

  void _clearHistory() {
    setState(() => _history.clear());
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool showSuggestions = _showSuggestions && _suggestions.isNotEmpty;

    return PageContentContainer(
      // 顶部搜索框固定、下方内容自己滚：所以要把可用高度撑满。
      fillHeight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TapRegion(
            // 点在输入框 + 联想面板之外时收起联想。
            // 用 TapRegion 而不是"失焦即隐藏"：点联想词本身也会让输入框失焦，
            // 那样会出现"手还没松开，面板已经没了"。
            onTapOutside: (_) {
              if (_showSuggestions) setState(() => _showSuggestions = false);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildField(),
                if (showSuggestions) _buildSuggestions(_suggestions),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildField() {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: (String value) => unawaited(_runSearch(value)),
      decoration: InputDecoration(
        hintText: '搜索${widget.source.label}的歌曲、歌手、专辑',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_loadingSuggestions)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (_controller.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '清空',
                onPressed: _clearQuery,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestions(List<String> suggestions) {
    final List<String> shown = suggestions.take(8).toList(growable: false);
    return GlassPanel(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final String suggestion in shown)
            _SuggestionRow(
              suggestion: suggestion,
              onTap: () => unawaited(_runSearch(suggestion)),
            ),
        ],
      ),
    );
  }

  /// 把搜索结果交给下载队列。
  ///
  /// 下载器可能是 null（`downloadQueueProvider` 还没被 override，
  /// 例如只挂了搜索页的测试）—— 这时给一句明确的说明，
  /// 而不是点了没反应或者抛一个空指针。
  void _download(Song song) {
    final DownloadQueue? queue = ref.read(downloadQueueProvider);
    if (queue == null) {
      _showMessage('下载器未启用');
      return;
    }
    if (!song.playable) {
      _showMessage(song.unplayableReason ?? '该曲目当前不可下载');
      return;
    }
    unawaited(queue.start(song));
    _showMessage('已加入下载：${song.title}');
  }

  void _showMessage(String message) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildContent() {
    if (_searching) {
      return EmptyStateView(
        busy: true,
        icon: Icons.hourglass_empty_rounded,
        title: '正在搜索「$_keyword」…',
      );
    }

    final Object? error = _error;
    if (error != null) {
      return ErrorStateView(
        error: error,
        onRetry: () => unawaited(_runSearch(_keyword)),
      );
    }

    if (_results.isNotEmpty) {
      return SongListView(
        songs: _results,
        showAlbum: true,
        // 搜索结果直接给下载入口：搜到想留的歌时不用先加进歌单再绕一圈。
        onDownload: _download,
        header: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
          child: Text(
            '「$_keyword」找到 ${_results.length} 首',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    if (_hasSearched) {
      return EmptyStateView(
        icon: Icons.search_off_rounded,
        title: '没有找到「$_keyword」',
        message: '换个关键词试试；如果是版权或会员曲目，音源可能确实给不出结果',
      );
    }

    return _buildIdle();
  }

  /// 还没开始搜索时的内容：搜索历史 + 使用说明。
  Widget _buildIdle() {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        if (_history.isEmpty)
          EmptyStateView(
            icon: Icons.search_rounded,
            title: '搜索${widget.source.label}的曲目',
            message: '输入关键词后按回车开始搜索，过程中会给出联想词',
          ),
        if (_history.isNotEmpty) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '搜索历史',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('清空'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String keyword in _history)
                ActionChip(
                  label: Text(keyword),
                  avatar: const Icon(Icons.history_rounded, size: 16),
                  onPressed: () => unawaited(_runSearch(keyword)),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        GlassPanel(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.tips_and_updates_outlined,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '搜索提示',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '输入时会给联想词，按回车或点联想词开始搜索；搜索结果里的歌曲'
                '可以直接双击播放，右侧按钮能接着加入队列或下载。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '「热门搜索」需要平台的热搜接口，当前音源没有提供，'
                '所以这里只显示本地搜索历史（仅本次运行有效）。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 联想词的一行。
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.onTap});

  final String suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return HoverBuilder(
      builder: (BuildContext context, bool hovered) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: tokens.fast,
            curve: ZhyTokens.standardCurve,
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: hovered
                  ? scheme.primary.withValues(alpha: ZhyTokens.hoverOverlay)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(tokens.cardRadius),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.search_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    suggestion,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  ),
                ),
                Icon(
                  Icons.north_west_rounded,
                  size: 14,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
