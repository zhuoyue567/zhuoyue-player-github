import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/runtime/embedded_netease_api.dart';
import '../../core/runtime/runtime_installer.dart';
import '../../core/storage/preferences.dart';
import '../../core/storage/storage_paths.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_providers.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/window_backdrop.dart';
import '../../core/utils/format.dart';
import '../../core/window/window_providers.dart';
import '../account/login_dialog.dart';
import '../shell/title_bar.dart';
import 'onboarding_providers.dart';

/// 「用默认值」按钮的键。
///
/// 两个目录各有一个同名（「用默认值」）按钮，界面上靠所在行区分就够了，
/// 但测试与无障碍朗读需要一个明确的身份，所以把键导出来当公开契约：
/// 改了这两个键，`test/onboarding_test.dart` 会立刻红。
const Key kOnboardingResetCacheKey = Key('onboarding.reset.cache');
const Key kOnboardingResetDownloadKey = Key('onboarding.reset.download');

/// 首次运行的门槛：没走过引导就先把引导页铺满窗口，走完/跳过后才挂上
/// [child]（应用外壳）。
///
/// 为什么是"包一层"而不是写进 `app.dart`：这次改动只允许落在 `main.dart`
/// 上，而 `ZhuoYueApp` 的 `home` 是写死的 `AppShell` —— 包一层是不动别人
/// 文件、又能让引导页先于外壳出现的唯一做法。
///
/// 引导页必须自带 MaterialApp：它出现在外壳之前，拿不到外壳那棵树里的
/// Theme / Navigator（「登录网易云」要弹窗，没有 Navigator 就弹不出来）。
/// 下面的主题与背景装配刻意与 `app.dart` 保持一致 —— 不一致的话，用户会在
/// 第一屏看到与之后完全不同的配色和窗口材质，像是打开了另一个程序。
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({super.key, required this.child});

  /// 引导结束后要显示的东西（正常情况下就是应用根组件）。
  final Widget child;

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  /// 首帧就定下来，避免"先闪一下主界面、再把引导页盖上去"。
  late bool _showOnboarding;

  @override
  void initState() {
    super.initState();
    _showOnboarding = !ref.read(onboardingCompletedProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (!_showOnboarding) return widget.child;

    return MaterialApp(
      title: '卓越播放器',
      debugShowCheckedModeBanner: false,
      theme: ref.watch(lightThemeProvider),
      darkTheme: ref.watch(darkThemeProvider),
      themeMode: ref.watch(themeModeProvider),
      builder: (BuildContext context, Widget? child) {
        return WindowEffectSync(
          child: WindowBackdrop(
            // 引导时还没有"当前播放的歌"，也就没有封面可取色：
            // 传 null 让背景回落到主题色渐变（WindowBackdrop 的既有行为）。
            coverUrl: null,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: OnboardingPage(
        // 完成与跳过走同一个出口：标记已经写好，这里只负责换掉整棵树。
        onFinished: () => setState(() => _showOnboarding = false),
      ),
    );
  }
}

/// 引导页的步骤。顺序就是这个枚举的顺序。
enum _OnboardingStep {
  welcome('欢迎使用卓越播放器', '先花一分钟了解一下它是什么'),
  runtime('准备运行组件', '播放所需的一百多 MB 组件，需要联网下载'),
  storage('存放位置', '缓存与下载放在哪里'),
  login('登录（可跳过）', '只影响同步，不影响浏览'),
  done('完成', '一切就绪');

  const _OnboardingStep(this.title, this.subtitle);

  final String title;
  final String subtitle;
}

/// 分步的首启引导页。
///
/// 五步：欢迎 → 准备运行时 → 存放位置 → 登录（可跳过）→ 完成。
///
/// 两条贯穿全页的规矩：
///  1. **不能变成"不联网/不下载完就不让走"**。底部的「下一步」在任何状态下
///     都可点，右上角任何一步都能「跳过引导」——运行时没装好也一定能进应用，
///     需要它的功能会自己给出提示。
///  2. **不画不透明整页底色**。窗口是半透明/亚克力的，铺一层实色会把它整个
///     盖死；这里只用 `GlassPanel` 与 `scheme` 的角色色，尺寸取自
///     `context.tokens`（与外壳同一套设计令牌）。
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key, required this.onFinished});

  /// 引导结束（完成或跳过）时调用。调用前标记一定已经写好。
  final VoidCallback onFinished;

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  int _index = 0;

  /// 正在写"已走过引导"这个标记：防止连点两次写两遍，也顺手把按钮禁掉。
  bool _finishing = false;

  static const int _stepCount = 5;

  bool get _isLast => _index == _stepCount - 1;

  void _go(int delta) {
    final int next = (_index + delta).clamp(0, _stepCount - 1);
    if (next == _index) return;
    setState(() => _index = next);
  }

  /// 结束引导：先写标记，再让外层换掉整棵树。
  ///
  /// 顺序不能反。先换树的话这个 State 会被立刻销毁，写盘那次异步操作就落在
  /// 一个没人等的 Future 上 —— 表现是"跳过之后下次启动又被拦一次"，
  /// 而且看日志也看不出哪里错了。
  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await markOnboardingCompleted(ref.read(sharedPreferencesProvider));
    if (!mounted) return;
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final _OnboardingStep step = _OnboardingStep.values[_index];

    // 五个步骤一次性建出来，但只有当前这一步可见：
    //
    //  * **必须**保留它们的 State（`maintainState: true`）。"运行时已就绪"、
    //    正在跑的下载进度、用户刚改过的目录，切走再切回来不该从头再来一遍；
    //  * 但不能让没显示的那些继续跑动画、也**不能接受点击**，否则下载中的
    //    那个不确定进度条会一直在后台动（测试里 `pumpAndSettle` 会永远等下去），
    //    而且 finder 会连别的步骤里的文字一起找到，断言就没意义了。
    //    `maintainAnimation: false` + `maintainSize: false` 两个都关正好
    //    同时解决这两件事（隐藏的步骤在 finder 眼里等同于"真的不在"）。
    final List<Widget> steps = <Widget>[
      const _WelcomeStep(),
      const _RuntimeStep(),
      const _StorageStep(),
      _LoginStep(onNext: () => _go(1)),
      const _DoneStep(),
    ];

    return Scaffold(
      // 必须透明：DWM 的毛玻璃/亚克力只在 Flutter 没画像素的地方透出来。
      backgroundColor: Colors.transparent,
      body: Column(
        children: <Widget>[
          // 复用外壳的标题栏。引导页出现时窗口还没有别的关闭入口，
          // 少了这三个按钮，用户只能靠 Alt+F4 关掉它。
          const AppTitleBar(title: '卓越播放器'),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                // 宽度收窄到一栏，是刻意的：引导页是"读一段话 + 做一个决定"，
                // 铺满 1240px 的话视线要横扫整屏。
                constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
                child: GlassPanel(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.fromLTRB(26, 20, 26, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _buildHeader(scheme, step),
                      const SizedBox(height: 14),
                      _buildStepIndicator(scheme),
                      const SizedBox(height: 6),
                      Text(
                        '第 ${_index + 1} 步 / 共 $_stepCount 步',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: Stack(
                          children: <Widget>[
                            for (int i = 0; i < steps.length; i++)
                              Visibility(
                                visible: i == _index,
                                maintainState: true,
                                maintainAnimation: false,
                                maintainSize: false,
                                child: steps[i],
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      _buildFooter(tokens),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme, _OnboardingStep step) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                step.title,
                style: TextStyle(
                  fontSize: 17,
                  // 内置字体只有 w400 一个字面，请求更粗只会被引擎描边合成
                  // （中文小字会发虚），所以全项目字体字重上限是 w500。
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                step.subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        // 最后一步的「开始使用」本身就是"完成"，再放一个「跳过引导」
        // 只是同义重复（两步都写同一个标记）。
        if (!_isLast)
          TextButton(
            onPressed: _finishing ? null : () => unawaited(_finish()),
            child: const Text('跳过引导'),
          ),
      ],
    );
  }

  Widget _buildStepIndicator(ColorScheme scheme) {
    return Row(
      children: <Widget>[
        for (int i = 0; i < _stepCount; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == _stepCount - 1 ? 0 : 6),
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: i <= _index
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFooter(ZhyTokens tokens) {
    final bool isFirst = _index == 0;
    return Row(
      children: <Widget>[
        if (!isFirst)
          TextButton.icon(
            onPressed: _finishing ? null : () => _go(-1),
            icon: const Icon(Icons.arrow_back_rounded, size: 16),
            label: const Text('上一步'),
          ),
        const Spacer(),
        FilledButton.icon(
          // 这个按钮在任何状态下都可点：运行时没装好、目录不可写、
          // 没登录，都不构成"不许进应用"的理由。
          onPressed: _finishing
              ? null
              : () => _isLast ? unawaited(_finish()) : _go(1),
          icon: Icon(
            _isLast ? Icons.play_arrow_rounded : Icons.arrow_forward_rounded,
            size: 16,
          ),
          label: Text(_isLast ? '开始使用' : (isFirst ? '开始' : '下一步')),
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(tokens.pillRadius),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 第 1 步：欢迎
// ---------------------------------------------------------------------------

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const List<String> highlights = <String>[
      '网易云音乐的搜索、歌单、每日推荐（公开内容不用登录就能看）',
      '哔哩哔哩的公开收藏夹，可以直接当歌单播放',
      '下载到本地、封面缓存、歌词与音质选择',
    ];

    return _StepScroll(
      children: <Widget>[
        Text(
          '这是一个桌面音乐播放器，把网易云音乐和哔哩哔哩的收藏放在一起听。',
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        for (final String item in highlights)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        _Notice(
          '接下来会让你准备两件事：下载播放所需的运行组件（一百多 MB，'
          '只需要下载这一次），然后确认缓存与下载目录。登录是可选的。\n'
          '每一步都可以跳过 —— 跳过之后随时能在应用里补做，'
          '设置里也能改。',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 第 2 步：准备运行组件
// ---------------------------------------------------------------------------

/// 运行组件这一步当前处于哪种状态。
enum _RuntimePhase {
  /// 还在问"装到哪、装好没有"。
  checking,

  /// 盘上已经有一套可用的运行时。
  ready,

  /// 缺运行时（还没下、下失败了、或者被取消了）——这一步的主要状态。
  missing,

  /// 正在下载。
  downloading,
}

class _RuntimeStep extends ConsumerStatefulWidget {
  const _RuntimeStep();

  @override
  ConsumerState<_RuntimeStep> createState() => _RuntimeStepState();
}

class _RuntimeStepState extends ConsumerState<_RuntimeStep> {
  _RuntimePhase _phase = _RuntimePhase.checking;

  /// 运行时的安装位置。检查和下载之后都会更新成一模一样的那个目录。
  String _directoryPath = '';

  /// 给用户看的一句说明：失败原因（直接来自 [RuntimeFailure.message]）、
  /// "已取消"、或者"连装到哪都问不出来"。
  String? _message;

  /// [_message] 是不是一条错误（决定用不用报错配色）。
  bool _messageIsError = false;

  /// 上一次尝试过下载并失败了：按钮改成「重试下载」，比原地重复一个
  /// 「下载运行时」更像话。
  bool _lastAttemptFailed = false;

  /// 已下载字节数与总字节数。[_total] 为 null 表示对方没给 `Content-Length`。
  int _received = 0;
  int? _total;

  /// 当前这次下载的取消信号；没在下载时为 null。
  RuntimeCancelSignal? _cancelSignal;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    try {
      final Directory directory = await ref.read(
        runtimeDirectoryProvider.future,
      );
      if (!mounted) return;
      setState(() {
        _directoryPath = directory.path;
        _phase = RuntimeInstaller.hasUsableRuntime(directory)
            ? _RuntimePhase.ready
            : _RuntimePhase.missing;
      });
    } on Object catch (error) {
      // 连"装到哪"都问不出来（例如平台通道不可用）：按"没装好"处理并说明，
      // 绝不把界面停在"正在检查…"上不动 —— 那会变成一个死界面。
      if (!mounted) return;
      setState(() {
        _phase = _RuntimePhase.missing;
        _message = '无法确认运行组件的状态：$error';
        _messageIsError = true;
      });
    }
  }

  /// 进度回调。**每收到一个网络分片就会调一次**，几万次是常事；
  /// 每次都 `setState` 会让界面把时间全花在重建上，所以这里只在
  /// "涨了至少 256KB"或"总大小刚出现/变了"的时候才刷新。
  void _onProgress(int received, int? total) {
    if (_received != 0 && total == _total && received - _received < 262144) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _received = received;
      _total = total;
    });
  }

  Future<void> _download() async {
    // 没配置下载源就什么都不做：按钮本来就是禁用的，这里是第二道闸门
    // （禁用状态是"说明原因"，而不是"点了才报错"）。
    final RuntimeArchiveConfig config = ref.read(
      runtimeArchiveConfigProvider,
    );
    if (!config.isConfigured) return;

    setState(() {
      _phase = _RuntimePhase.downloading;
      _received = 0;
      _total = null;
      _message = null;
      _messageIsError = false;
      _lastAttemptFailed = false;
    });

    final RuntimeCancelSignal cancelSignal = RuntimeCancelSignal();
    _cancelSignal = cancelSignal;
    try {
      // 下载地址与校验和来自**一处**配置（见 onboarding_providers.dart）：
      // 散落多处的 URL 迟早会有一处忘了改。这里不做任何"猜一个地址"的回退。
      final RuntimeInstallResult result = await ref
          .read(runtimeInstallerProvider)
          .ensureInstalled(
            archiveUrl: Uri.parse(config.url!.trim()),
            expectedSha256: config.sha256,
            onProgress: _onProgress,
            cancelSignal: cancelSignal,
          );

      // 装完必须把确切位置登记给内嵌服务：否则**这一次运行**里应用仍然会
      // 认为运行时不存在（要重启才生效）—— 用户刚看完进度条走到 100%，
      // 回头点搜索却被告知"缺少运行时"，是最伤信任的一种体验。
      EmbeddedNeteaseApi.registerInstalledRuntimeDirectory(result.directory);

      if (!mounted) return;
      setState(() {
        _phase = _RuntimePhase.ready;
        _directoryPath = result.directory.path;
        _received = result.receivedBytes;
      });
    } on RuntimeFailure catch (error) {
      // 失败原因**直接用下载器写好的那句话**，不在这里另编一套：
      // 它按"网络 / HTTP 状态码 / 校验和 / 压缩包 / 磁盘 / 取消"分了类，
      // 那正是用户拿去判断"该重试还是该清空间"的信息。
      if (!mounted) return;
      setState(() {
        _phase = _RuntimePhase.missing;
        _message = error.message;
        _messageIsError = error is! RuntimeCancelled;
        _lastAttemptFailed = true;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _RuntimePhase.missing;
        _message = '下载运行组件失败：$error';
        _messageIsError = true;
        _lastAttemptFailed = true;
      });
    } finally {
      _cancelSignal = null;
    }
  }

  /// 进度文案。
  ///
  /// 总大小未知时**如实说"未知"**，不算百分比：`Content-Length` 缺失时
  /// 任何百分比都是编的，而用户会在进度条卡在某个假数字上时更沮丧。
  String get _progressText {
    final int? total = _total;
    if (total == null || total <= 0) {
      return '已下载 ${ZhyFormat.bytes(_received)} · 总大小未知';
    }
    final int percent = ((_received / total) * 100).clamp(0, 100).round();
    return '已下载 ${ZhyFormat.bytes(_received)} / ${ZhyFormat.bytes(total)}'
        '（$percent%）';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return _StepScroll(
      children: <Widget>[
        switch (_phase) {
          _RuntimePhase.checking => Text(
            '正在检查运行组件…',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          _RuntimePhase.ready => _buildReady(scheme),
          _RuntimePhase.missing => _buildMissing(scheme),
          _RuntimePhase.downloading => _buildDownloading(scheme),
        },
      ],
    );
  }

  Widget _buildReady(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.check_circle_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              '运行组件已就绪',
              style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '需要它的功能（搜索、歌单、每日推荐等）可以直接用了，这一步不用做任何事。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        _PathLine(label: '已安装到', path: _directoryPath),
      ],
    );
  }

  Widget _buildMissing(ColorScheme scheme) {
    // 没有配置下载源时**禁用**按钮并说明原因，而不是让用户点一下才报错。
    final bool canDownload = ref
        .watch(runtimeArchiveConfigProvider)
        .isConfigured;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '还没有安装运行组件',
          style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
        ),
        const SizedBox(height: 6),
        Text(
          '播放所需的 Node 与网易云 API 是一个一百多 MB 的组件包，'
          '需要联网下载、校验后解压，只需要下载这一次。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        _PathLine(label: '将安装到', path: _directoryPath),
        if (_message != null) ...<Widget>[
          const SizedBox(height: 10),
          _Notice(_message!, isError: _messageIsError),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.icon(
              onPressed: canDownload ? () => unawaited(_download()) : null,
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text(_lastAttemptFailed ? '重试下载' : '下载运行组件'),
            ),
            if (!canDownload)
              // 禁用的按钮必须自己解释清楚为什么不能点。
              Text(
                '本次构建没有配置运行组件的下载地址，这里下不了。'
                '这不影响进入应用：需要它的功能会自己提示缺少组件；'
                '也可以手动把 runtime 目录（含 node/ 与 netease-api/）'
                '放到程序所在目录（exe 同级）后重启应用。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else if (_lastAttemptFailed)
              // 这一条是"不许把引导做成死路"的正面说明：失败之后必须让用户
              // 知道还能直接往下走，而不是自己去找那个「下一步」。
              Text(
                '装不上也可以直接点「下一步」：'
                '没有它应用照样能打开，需要它的功能会自己提示。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownloading(ColorScheme scheme) {
    // 总大小未知时 value 传 null：进度条走"不确定"形态，
    // 而不是一个假装知道总量的百分比。
    final int? total = _total;
    final double? value = (total == null || total <= 0)
        ? null
        : (_received / total).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '正在下载运行组件…',
          style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: value, minHeight: 6),
        ),
        const SizedBox(height: 10),
        Text(
          _progressText,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          // 取消只是发一个信号：真正的停止由下载器做（它会关掉底层连接），
          // 所以按钮点完界面还要等它抛回 RuntimeCancelled 才切状态 ——
          // 这里不去猜"是不是已经停了"。
          onPressed: () => _cancelSignal?.cancel(),
          icon: const Icon(Icons.close_rounded, size: 15),
          label: const Text('取消下载'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 第 3 步：存放位置
// ---------------------------------------------------------------------------

class _StorageStep extends ConsumerStatefulWidget {
  const _StorageStep();

  @override
  ConsumerState<_StorageStep> createState() => _StorageStepState();
}

class _StorageStepState extends ConsumerState<_StorageStep> {
  String? _cacheDir;
  String? _downloadDir;

  /// 真正**能写**的缓存目录。用户选的目录不可写时它与之不同，
  /// 这时必须两个都说出来，不能假装用户选的那个正在生效。
  String? _effectiveCache;
  String? _cacheProblem;

  /// 安装器写的目录有没有被采纳，以及没采纳的原因。
  bool _installerAdopted = false;
  String? _installerNote;

  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 同步段：只读偏好与内存，不碰磁盘，所以第一帧就有东西可显示。
    final StoragePaths paths = ref.read(storagePathsProvider);
    _cacheDir = paths.chosenDirectory(StorageDirectoryKind.cache);
    _downloadDir = paths.chosenDirectory(StorageDirectoryKind.download);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    // 探测还没回来就离开这一步时，别把定时器留着。
    _probeTimeout?.cancel();
    _probeTimeout = null;
    super.dispose();
  }

  /// 探测超时的定时器。存在字段里是为了能在 [dispose] 里取消。
  ///
  /// 为什么不用 `Future.timeout()`：它内部也建定时器，但**外面拿不到、也取消
  /// 不了**。组件在探测完成前被销毁时，那个定时器会一直挂到 5 秒后才结束 ——
  /// 在 widget 测试里这会直接命中 `A Timer is still pending even after the
  /// widget tree was disposed`（而且那条断言**每一个**用到本步骤的用例都会失败），
  /// 真机上也是白白占着一个定时器。自己持有它就能在销毁时立刻取消。
  Timer? _probeTimeout;

  Future<void> _refresh() async {
    final StoragePaths paths = ref.read(storagePathsProvider);

    _probeTimeout?.cancel();
    final Completer<void> timedOut = Completer<void>();
    _probeTimeout = Timer(const Duration(seconds: 5), () {
      if (!timedOut.isCompleted) {
        timedOut.completeError(
          TimeoutException('读取目录详情超时（5 秒）'),
        );
      }
    });

    try {
      // 整段共用一个超时：读安装器配置、探测可写性是一串依赖，
      // 每一步各挂一个定时器只会把"卡住"变成一个更复杂的问题。
      await Future.any(<Future<void>>[_probe(paths), timedOut.future]);
    } on Object catch (error) {
      debugPrint('[onboarding] 读取目录详情失败：$error');
      if (!mounted) return;
      setState(() => _error = '读取目录详情失败（目录本身仍然可用）：$error');
    }
  }

  Future<void> _probe(StoragePaths paths) async {
    // 主动触发一次"采纳安装器的选择"。这个动作整个生命周期只会真的执行一次
    // （storage_paths 里用标记钉住了），但必须在第一次解析目录之前发生，
    // 否则安装时选的目录会被默认值顶掉、而且**错过就真错过了**。
    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();
    final StorageDirectoryProbe probe = await paths.ensureDirectory(
      StorageDirectoryKind.cache,
    );
    if (!mounted) return;
    setState(() {
      _installerAdopted = report.adopted;
      _installerNote = report.adopted
          ? '安装时选择的目录已经生效（安装器的选择只会被采纳这一次）'
          : (report.skippedReason ?? '没有安装器留下的目录，沿用默认值');
      _effectiveCache = probe.directory;
      _cacheProblem = probe.failure;
      _cacheDir = paths.chosenDirectory(StorageDirectoryKind.cache);
      _downloadDir = paths.chosenDirectory(StorageDirectoryKind.download);
      _error = null;
    });
  }

  Future<String?> _pickDirectory() async {
    try {
      return await getDirectoryPath(confirmButtonText: '用这个文件夹');
    } on Object catch (error) {
      debugPrint('[onboarding] 打开目录选择框失败：$error');
      if (mounted) setState(() => _error = '无法打开目录选择框：$error');
      return null;
    }
  }

  Future<void> _change(StorageDirectoryKind kind) async {
    final StoragePaths paths = ref.read(storagePathsProvider);
    final String? picked = await _pickDirectory();
    if (picked == null || picked.trim().isEmpty) return;
    if (!mounted) return;

    setState(() => _busy = true);
    try {
      await paths.setDirectory(kind, picked);
      // 这两个 Provider 是 keepAlive 的：不作废的话界面会继续显示旧目录，
      // 也就是最忌讳的"点了没反应"。
      ref.invalidate(cacheRootProvider);
      ref.invalidate(coverCacheDirectoryProvider);
      await _refresh();
    } on StoragePathException catch (error) {
      // 这一层给的已经是中文原因（不可写 / 路径为空），直接显示。
      if (mounted) setState(() => _error = error.message);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '保存${kind.label}失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset(StorageDirectoryKind kind) async {
    final StoragePaths paths = ref.read(storagePathsProvider);
    setState(() => _busy = true);
    try {
      await paths.resetDirectory(kind);
      ref.invalidate(cacheRootProvider);
      ref.invalidate(coverCacheDirectoryProvider);
      await _refresh();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '恢复${kind.label}的默认值失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return _StepScroll(
      children: <Widget>[
        Text(
          '默认值就能用。这里只是让你确认一下：想换位置可以现在换，'
          '之后在设置里也能改。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        _buildDirectoryRow(
          kind: StorageDirectoryKind.cache,
          path: _cacheDir,
          hint: '封面等可以随时重新生成的文件放在这里',
          resetKey: kOnboardingResetCacheKey,
        ),
        const SizedBox(height: 14),
        _buildDirectoryRow(
          kind: StorageDirectoryKind.download,
          path: _downloadDir,
          hint: '下载回来的音频文件放在这里',
          resetKey: kOnboardingResetDownloadKey,
        ),
        if (_cacheProblem != null) ...<Widget>[
          const SizedBox(height: 10),
          _Notice(
            '当前选的缓存目录不可用（$_cacheProblem）。'
            '不会因此出错：实际会写到 ${_effectiveCache ?? '临时目录'}。',
            isError: true,
          ),
        ],
        const SizedBox(height: 10),
        // 安装器那件事如实说：用户可能刚在安装向导里选过目录，
        // 不说清楚他会以为"我选的东西不见了"。
        Text(
          _installerAdopted ? '✓ $_installerNote' : '安装器配置：$_installerNote',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        // 文案直接复用存储层的同一句：两处各写一份，迟早会有一处变成谎话。
        Text(
          StoragePaths.changeEffectNotice(StorageDirectoryKind.download),
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          _Notice(_error!, isError: true),
        ],
      ],
    );
  }

  Widget _buildDirectoryRow({
    required StorageDirectoryKind kind,
    required String? path,
    required String hint,
    required Key resetKey,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          kind.label,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        // 用 Text 而不是 SelectableText：这一步只要用户"看一眼确认"，
        // 要复制完整路径的地方在设置页（那里就是可选中可复制的）。
        Text(
          path ?? '（环境变量缺失，算不出默认值）',
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: scheme.onSurfaceVariant,
          ),
        ),
        Row(
          children: <Widget>[
            TextButton(
              key: resetKey,
              onPressed: _busy ? null : () => unawaited(_reset(kind)),
              child: const Text('用默认值'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_change(kind)),
              icon: const Icon(Icons.folder_open_rounded, size: 15),
              label: const Text('更改…'),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 第 4 步：登录（可跳过）
// ---------------------------------------------------------------------------

class _LoginStep extends StatelessWidget {
  const _LoginStep({required this.onNext});

  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return _StepScroll(
      children: <Widget>[
        Text(
          '不登录也能浏览哔哩哔哩的公开收藏夹，也能搜索和试听网易云的公开内容。',
          style: TextStyle(fontSize: 13, height: 1.6, color: scheme.onSurface),
        ),
        const SizedBox(height: 8),
        Text(
          '登录网易云之后能同步你自己的歌单、收藏与播放记录；'
          '哔哩哔哩的登录用来读你自己的账号内容。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.6,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        // 不在这里内联一个自研登录表单：扫码/手机号那套逻辑在 login_dialog
        // 里已经完整实现（含二维码轮询、失效处理），再抄一份只会多一份要同步
        // 维护的登录代码。引导页只负责提供入口和"可以跳过"。
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: () => unawaited(showLoginDialog(context)),
              icon: const Icon(Icons.login_rounded, size: 16),
              label: const Text('登录网易云'),
            ),
            TextButton(onPressed: onNext, child: const Text('稍后再说')),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 第 5 步：完成
// ---------------------------------------------------------------------------

class _DoneStep extends StatelessWidget {
  const _DoneStep();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return _StepScroll(
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.graphic_eq_rounded, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              '可以开始听了',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '播放、搜索、歌单、下载都在左侧导航里。\n'
          '如果刚才跳过了运行组件，需要它的功能会自己给出提示，'
          '不影响先听本地的音乐。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.6,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 两个共用的小零件
// ---------------------------------------------------------------------------

/// 每一步的内容都套一层滚动视图。
///
/// 窗口最小可以缩到 900×560，加上标题栏与页脚，留给内容的高度并不多；
/// 不套滚动的话窄窗口里会直接溢出（黄黑条）而不是让用户滚一下。
class _StepScroll extends StatelessWidget {
  const _StepScroll({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// 路径行：一行"标签 + 路径"。
class _PathLine extends StatelessWidget {
  const _PathLine({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      '$label：$path',
      style: TextStyle(
        fontSize: 11.5,
        height: 1.5,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// 一句需要被看见的话（提示 / 失败原因）。
///
/// 用 `scheme` 的角色色 + 低透明度，不铺不透明底色：窗口是亚克力的，
/// 一块实色方块会显得像贴上去的补丁。
class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: (isError ? scheme.errorContainer : scheme.surfaceContainerHigh)
            .withValues(alpha: isError ? 0.55 : 0.45),
        borderRadius: BorderRadius.circular(context.tokens.cardRadius),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, height: 1.55, color: foreground),
      ),
    );
  }
}
