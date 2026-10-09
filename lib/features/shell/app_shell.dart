import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/diagnostics/log_providers.dart';
import '../../core/runtime/embedded_netease_api.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/page_layout.dart';
import '../../data/models/collection.dart';
import '../../data/models/media_source.dart';
import '../../data/models/song.dart';
import '../account/account_providers.dart';
import '../account/accounts_page.dart';
import '../account/login_dialog.dart';
import '../discover/discover_page.dart';
import '../downloads/downloads_page.dart';
import '../player/now_playing_page.dart';
import '../player/player_bar.dart';
import '../player/player_controller.dart';
import '../player/queue_island.dart';
import '../playlists/playlists_page.dart';
import '../search/search_page.dart';
import '../settings/settings_page.dart';
import 'title_bar.dart';

/// 侧边栏的功能分区。
enum ShellSection {
  discover('发现音乐', Icons.explore_outlined, Icons.explore_rounded),
  neteasePlaylists(
    '我的歌单',
    Icons.queue_music_outlined,
    Icons.queue_music_rounded,
  ),
  bilibili('哔哩收藏', Icons.video_library_outlined, Icons.video_library_rounded),
  search('搜索', Icons.search_outlined, Icons.search_rounded),
  downloads('下载管理', Icons.download_outlined, Icons.download_rounded),
  // 「账户」必须排在「设置」**之前**：侧边栏是按这个枚举的顺序渲染的
  // （见 _Sidebar 里对 ShellSection.values 的遍历），所以顺序只由这里决定。
  // 账户是"我这几个账号现在什么状态"这种每天都会瞟一眼的东西，
  // 而设置是偶尔才进一次的，把它排在设置之后就会被埋进低频区。
  accounts('账户', Icons.manage_accounts_outlined, Icons.manage_accounts_rounded),
  settings('设置', Icons.tune_outlined, Icons.tune_rounded);

  const ShellSection(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// 应用主框架：自绘标题栏 + 侧边导航 + 内容区 + 常驻播放条。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WindowListener {
  ShellSection _section = ShellSection.discover;

  /// 搜索的音源。默认网易云（曲库更适合找歌），
  /// 切到哔哩就能搜稿件并加到收藏里。
  MediaSource _searchSource = MediaSource.netease;

  /// 让"同一个音源切回来、或反复点同一个音源"也能重新触发查询的计数器。
  /// （以前它还负责"标题栏同一个词再搜一次"，标题栏搜索框已经删掉，
  /// 现在只剩音源切换这一个用途。）
  int _searchEpoch = 0;

  /// 右侧队列 island 是否展开。
  bool _queueOpen = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);

    // ★ 在这里读一次日志缓冲区，让日志捕获**从应用启动就开始**。
    //
    // `logBufferProvider` 是懒加载的：不主动读，它要到用户第一次打开调试
    // 日志面板时才被创建。那样"我刚才那首歌为什么放不了"这段日志根本不在
    // 缓冲区里 —— 用户打开面板只会看到一片空白，而这恰好是这个功能唯一
    // 要解决的场景。外壳是启动时必定构建的节点，放在这里最早也最可靠。
    ref.read(logBufferProvider);

    _applyDebugInitialState();
  }

  /// 仅 Debug 构建：用环境变量摆好初始界面，便于截图核对。
  ///
  /// 存在的理由很实际：本项目的界面验收方式是"跑起来截图看一眼"，
  /// 但在没有交互式桌面的会话里（远程 / CI），合成的鼠标事件送不到窗口上
  /// —— 连点四下按钮，四张截图完全一样。与其为了截图去装一套 UI 自动化，
  /// 不如让进程自己从环境变量里读出"打开就在哪一页"。
  ///
  /// 它只在 [kDebugMode] 下生效，Release 构建里这段逻辑整体不会执行，
  /// 也不会影响任何用户可见行为。
  void _applyDebugInitialState() {
    if (!kDebugMode) return;

    final String? section = Platform.environment['ZHY_DEBUG_SECTION'];
    if (section != null) {
      for (final ShellSection item in ShellSection.values) {
        if (item.name == section) {
          _section = item;
          break;
        }
      }
    }

    if (Platform.environment['ZHY_DEBUG_QUEUE'] == '1') {
      _queueOpen = true;
    }

    if (Platform.environment['ZHY_DEBUG_NOWPLAYING'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(openNowPlaying(context));
      });
    }

    // 把整棵 widget 树打到 stdout（debugPrint → 重定向的日志文件），
    // 用于在没有交互式桌面、无法点击的环境里核对界面结构。
    if (Platform.environment['ZHY_DEBUG_DUMP'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugDumpApp();
      });
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 窗口关闭：收掉内嵌服务后立刻结束进程。
  ///
  /// `window_bootstrap` 里开了 `setPreventClose(true)`，所以系统不会真的关掉
  /// 窗口，必须由这里收尾。
  @override
  void onWindowClose() {
    unawaited(_shutdownAndExit());
  }

  Future<void> _shutdownAndExit() async {
    final Stopwatch watch = Stopwatch()..start();
    debugPrint('[app] 收到关闭请求，开始收尾');

    // ★ 先让窗口消失，再做收尾。
    //
    // 用户点关闭之后的观感完全取决于"窗口什么时候不见"，而不是"进程什么时候
    // 真正结束"。收尾里还有两件事（停内嵌 node、退出 VM），哪怕每件只有
    // 一百多毫秒，窗口杵在那里等着就是"点了关闭要过一会才关"。
    // hide() 只是一次 DWM 调用，几乎瞬时；放在最前面，观感就是立刻关闭。
    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 200));
      debugPrint('[app] 窗口已隐藏（${watch.elapsedMilliseconds}ms）');
    } on Object catch (error) {
      debugPrint('[app] 隐藏窗口失败（忽略，继续退出）：$error');
    }

    // 硬性截止：2 秒后无条件结束进程。
    //
    // 定时器挂在事件循环上，而 await 卡住时事件循环是空闲的，所以它一定会
    // 触发 —— 它不依赖任何一次 await 返回。（历史上 await destroy() 曾经
    // 永远不返回，造成"点了关闭程序无响应"。）
    Timer(const Duration(seconds: 2), () {
      debugPrint('[app] 硬性截止触发，强制退出');
      exit(0);
    });

    // 内嵌的 node 服务是**子进程**：Windows 上它不会随父进程自动退出，
    // 所以必须主动收掉。但这里只发信号、不等它退出（见 stop 的说明），
    // 因此这一步基本不耗时，超时上限留着只为兜住异常。
    try {
      await shutdownEmbeddedNeteaseApi().timeout(
        const Duration(milliseconds: 500),
      );
      debugPrint('[app] 内嵌服务已发终止信号（${watch.elapsedMilliseconds}ms）');
    } on Object catch (error) {
      debugPrint('[app] 停止内嵌服务超时或失败：$error');
    }

    debugPrint('[app] 进程退出（总计 ${watch.elapsedMilliseconds}ms）');
    exit(0);
  }

  Future<void> _openLogin() => showLoginDialog(context);

  /// 监听一个音源的账号状态；登录态因为**凭据失效**而丢失时提示重新登录。
  ///
  /// 与"主动退出"区分开：主动退出时 notifier 已经把 `lastChangeWasExpiry`
  /// 清成 false，这里就不会重复弹提示。
  void _listenAccountExpiry(
    WidgetRef ref,
    NotifierProvider<AccountNotifier, AccountProfile?> provider,
    String sourceLabel, {
    required VoidCallback onRelogin,
  }) {
    ref.listen<AccountProfile?>(provider, (
      AccountProfile? previous,
      AccountProfile? next,
    ) {
      if (!mounted || next != null || previous == null) return;
      if (!ref.read(provider.notifier).lastChangeWasExpiry) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$sourceLabel 登录已失效，请重新登录'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(label: '重新登录', onPressed: onRelogin),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;

    // 窗口标题跟随当前曲目：任务栏和 Alt+Tab 里都能看出在放什么。
    ref.listen<Song?>(currentSongProvider, (Song? previous, Song? next) {
      final String title = next == null
          ? '卓越播放器'
          : '${next.title} — ${next.artistLabel}';
      unawaited(windowManager.setTitle(title));
    });

    // 任务栏进度条。做得很轻，但对"切到别的窗口还能看到进度"很有用。
    ref.listen<double>(
      playerControllerProvider.select((PlayerUiState s) => s.progress),
      (double? previous, double next) {
        final bool shouldShow =
            ref.read(playerControllerProvider).hasTrack &&
            next > 0.01 &&
            next < 0.999;
        unawaited(windowManager.setProgressBar(shouldShow ? next : -1));
      },
    );

    // 播放失败要立刻让用户看到，并且给一个明确的"重试"动作，
    // 而不是让播放条静静地停在那里。
    ref.listen<String?>(
      playerControllerProvider.select((PlayerUiState s) => s.error),
      (String? previous, String? next) {
        if (next == null || !mounted) return;
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Text(next),
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: '重试',
              onPressed: () =>
                  ref.read(playerControllerProvider.notifier).retry(),
            ),
          ),
        );
        ref.read(playerControllerProvider.notifier).dismissError();
      },
    );

    // 登录凭据失效要明确告知。
    //
    // 哔哩的 SESSDATA 生命周期明显短于网易云的 MUSIC_U，隔一段时间
    // 就会出现"网易云还好好的、哔哩莫名其妙变未登录"。以前这种情况
    // 界面只是安静地变回未登录，用户完全不知道发生了什么；
    // 现在会弹一条带"重新登录"动作的提示。
    _listenAccountExpiry(
      ref,
      neteaseAccountProvider,
      '网易云音乐',
      onRelogin: _openLogin,
    );
    _listenAccountExpiry(
      ref,
      bilibiliAccountProvider,
      '哔哩哔哩',
      onRelogin: _openLogin,
    );

    return Scaffold(
      // 必须透明：DWM 的毛玻璃只在 Flutter 没画像素的地方透出来。
      backgroundColor: Colors.transparent,
      body: Column(
        children: <Widget>[
          // 标题栏只有应用标识与窗口按钮：搜索统一走左侧导航的「搜索」分区，
          // 那里有完整的输入框、联想与历史记录。
          const AppTitleBar(title: '卓越播放器'),
          Expanded(
            child: Stack(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _Sidebar(
                      section: _section,
                      width: tokens.sidebarWidth,
                      onSelect: (ShellSection section) {
                        // 切分区时顺手收起队列 island：它是一块"临时浮层"，
                        // 跟着用户换页会显得很碍事。
                        setState(() {
                          _section = section;
                          _queueOpen = false;
                        });
                      },
                      onRequestLogin: _openLogin,
                    ),
                    Expanded(
                      // 内容区自带一个 Navigator：歌单详情之类的页面只在内容区里
                      // 入栈，侧边栏、标题栏和播放条始终可见可点。
                      // 如果直接用根 Navigator，打开详情会把窗口控制按钮也盖掉，
                      // 用户连"关闭窗口"都点不到。
                      //
                      // key 里带上所有会影响内容的状态：分区一变就整棵重建，
                      // 避免从某个详情页切走再切回来时残留上一层的页面栈
                      // ——「搜索」分区也靠它重建，SearchPage 的 autofocus
                      // 才会在每次从导航进来时重新生效。
                      // （原来还拼了标题栏搜索框传来的关键词，那个入口已经删掉。）
                      child: Navigator(
                        key: ValueKey<String>(
                          '${_section.name}|${_searchSource.key}|$_searchEpoch',
                        ),
                        onGenerateRoute: (RouteSettings settings) =>
                            MaterialPageRoute<void>(
                              settings: settings,
                              builder: (BuildContext context) =>
                                  _buildContent(),
                            ),
                      ),
                    ),
                  ],
                ),
                // 队列 island 浮在内容之上，但让出标题栏与播放条：
                // 它只回答"接下来放什么"，不该打断正在浏览的歌单。
                //
                // 上下留白与左侧导航栏、页面里的中栏取同一份定义：
                // 三栏同高，中栏才不会看起来比右边短一截。
                Positioned(
                  top: ZhyPageLayout.overlayColumnInsets.top,
                  bottom: ZhyPageLayout.overlayColumnInsets.bottom,
                  right: 8,
                  child: QueueIsland(
                    open: _queueOpen,
                    onClose: () => setState(() => _queueOpen = false),
                  ),
                ),
              ],
            ),
          ),
          PlayerBar(
            onOpenNowPlaying: () => openNowPlaying(context),
            // 队列按钮只开关 island，不再打开全屏播放页 ——
            // "看下一首是什么"不值得铺满整个窗口。
            onOpenQueue: () => setState(() => _queueOpen = !_queueOpen),
            queueOpen: _queueOpen,
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return switch (_section) {
      ShellSection.discover => DiscoverPage(onRequestLogin: _openLogin),
      ShellSection.neteasePlaylists => PlaylistsPage(
        source: MediaSource.netease,
        onRequestLogin: _openLogin,
      ),
      ShellSection.bilibili => PlaylistsPage(
        source: MediaSource.bilibili,
        onRequestLogin: _openLogin,
      ),
      ShellSection.search => Column(
        children: <Widget>[
          _SearchSourceBar(
            source: _searchSource,
            onChanged: (MediaSource source) => setState(() {
              _searchSource = source;
              _searchEpoch++;
            }),
          ),
          Expanded(
            child: SearchPage(
              // 音源变化时换 key，强制 SearchPage 重建并重新查询。
              // 不再传 initialKeyword：搜索页进来就是空白的，
              // 输入框由 SearchPage 自己的 autofocus 接管焦点。
              key: ValueKey<String>('${_searchSource.key}:$_searchEpoch'),
              source: _searchSource,
            ),
          ),
        ],
      ),
      ShellSection.downloads => const DownloadsPage(),
      ShellSection.accounts => const AccountsPage(),
      ShellSection.settings => const SettingsPage(),
    };
  }
}

/// 搜索页顶部的音源切换条。
///
/// 单独放在外壳而不是塞进 SearchPage：搜索逻辑对音源是无感的，
/// 让页面自己去管"当前能搜哪些音源"会把外壳的导航职责漏进页面里。
class _SearchSourceBar extends StatelessWidget {
  const _SearchSourceBar({required this.source, required this.onChanged});

  final MediaSource source;
  final ValueChanged<MediaSource> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 本地音源没有搜索接口，不列出来。
    const List<MediaSource> supported = <MediaSource>[
      MediaSource.netease,
      MediaSource.bilibili,
    ];

    return Padding(
      // 顶部留白与三栏一致：它是搜索页内容栏最上面那一条，
      // 停在自己的 4px 上会顶到导航栏玻璃卡的上沿之上，看着就是没对齐。
      padding: const EdgeInsets.fromLTRB(
        ZhyPageLayout.columnHorizontal,
        ZhyPageLayout.columnTop,
        ZhyPageLayout.columnHorizontal,
        8,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search_rounded, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            '搜索音源',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          for (final MediaSource item in supported)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(item.label),
                selected: source == item,
                onSelected: (_) => onChanged(item),
              ),
            ),
        ],
      ),
    );
  }
}

/// 左侧导航栏。
class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.section,
    required this.width,
    required this.onSelect,
    required this.onRequestLogin,
  });

  final ShellSection section;
  final double width;
  final ValueChanged<ShellSection> onSelect;
  final VoidCallback onRequestLogin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: width,
      child: Padding(
        // 上下留白取自三栏共享定义（原来是 4/0，比中栏高出 40px）。
        padding: ZhyPageLayout.navRailInsets,
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Column(
            children: <Widget>[
              const _AccountCard(),
              const SizedBox(height: 10),
              for (final ShellSection item in ShellSection.values)
                _NavItem(
                  section: item,
                  selected: section == item,
                  onTap: () => onSelect(item),
                ),
              // 这里以前还有一条页脚：系统版本/窗口材质文案 + 「账号登录」按钮。
              // 两者都去掉了：
              // - 版本号是给排查问题用的，用户不需要在导航栏里一直看着它
              //   （设置页的「窗口材质」分区里已经有系统与材质状态）；
              // - 底部那个登录按钮与顶部账户卡片、以及各页面自己的登录入口重复，
              //   三个入口指向同一件事只会让人不知道点哪个。
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final ShellSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool selected = widget.selected;

    final Color background = selected
        ? scheme.secondaryContainer
        : _hovered
        ? scheme.onSurface.withValues(alpha: ZhyTokens.hoverOverlay)
        : Colors.transparent;
    final Color foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: tokens.fast,
            curve: ZhyTokens.standardCurve,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(tokens.pillRadius),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? widget.section.activeIcon : widget.section.icon,
                  size: 18,
                  color: foreground,
                ),
                const SizedBox(width: 12),
                Text(
                  widget.section.label,
                  style: TextStyle(
                    fontSize: 13,
                    // 内置字体只有 w400 一个字面，请求 w600 会被引擎描边合成
                    // （中文小字因此发虚、笔画不匀），所以这里恒为 w500；
                    // 选中态只靠上面的 foreground 颜色区分。
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 账号卡片：显示当前网易云账号，未登录时退化成"未登录"提示。
class _AccountCard extends ConsumerWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AccountProfile? profile = ref.watch(neteaseAccountProvider);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(tokens.cardRadius),
      ),
      child: Row(
        children: <Widget>[
          ClipOval(
            child: SizedBox(
              width: 32,
              height: 32,
              child: profile?.avatarUrl == null
                  ? ColoredBox(
                      color: scheme.primaryContainer,
                      child: Icon(
                        Icons.person_rounded,
                        size: 18,
                        color: scheme.onPrimaryContainer,
                      ),
                    )
                  : CoverImage(url: profile!.avatarUrl, size: 32),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  profile?.nickname ?? '未登录',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                Text(
                  profile == null ? '登录后可同步歌单' : (profile.vipLabel ?? '网易云音乐'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
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
}
