import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/cache/cover_cache.dart';
import 'package:zhuoyue_player/core/diagnostics/log_buffer.dart';
import 'package:zhuoyue_player/core/diagnostics/log_providers.dart';
import 'package:zhuoyue_player/core/storage/preferences.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/data/models/collection.dart';
import 'package:zhuoyue_player/features/account/account_providers.dart';
import 'package:zhuoyue_player/features/diagnostics/log_panel.dart';
import 'package:zhuoyue_player/features/settings/settings_page.dart';

/// 测试替身：直接给出一个固定的账号状态，完全不碰网络与内嵌服务。
class _StubAccountNotifier extends AccountNotifier {
  _StubAccountNotifier()
    : super((Ref ref) => throw StateError('测试替身不应该去取 repository'));

  @override
  AccountProfile? build() => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> logout() async {}
}

/// 测试替身：绕开 path_provider（widget 测试里没有平台通道）。
class _StubCoverCache extends CoverCache {
  _StubCoverCache() : super(Dio());

  @override
  Future<int> sizeOnDisk() async => 0;

  @override
  Future<void> clear() async {}
}

void main() {
  // 面板的"已打开"标志是模块级状态。上一个用例结束时面板要是还开着，
  // 后面的用例会连面板都打不开 —— 那种失败看起来像"按钮没反应"。
  setUp(debugResetLogPanelState);
  tearDown(debugResetLogPanelState);

  /// 挂一个只包含日志面板的统一测试环境，并返回本次用例自己的缓冲区。
  ///
  /// 每个用例一个新的 [ProviderContainer]：`logBufferProvider` 的生命周期
  /// 挂在容器上，共用一个容器就会让上一个用例的日志漏进下一个用例 ——
  /// 断言"丢弃了 3 条"变成"丢弃了 5 条"这种失败非常难查。
  Future<LogBuffer> pumpPanel(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final ProviderContainer container = ProviderContainer(
      // 不写显式类型参数：Riverpod 3 没有从 flutter_riverpod 导出 Override。
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        coverCacheProvider.overrideWithValue(_StubCoverCache()),
        neteaseAccountProvider.overrideWith(() => _StubAccountNotifier()),
        bilibiliAccountProvider.overrideWith(() => _StubAccountNotifier()),
      ],
    );
    addTearDown(container.dispose);
    final LogBuffer buffer = container.read(logBufferProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildZhyTheme(
            scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            tokens: buildZhyTokens(
              const ZhyThemeSettings(material: ZhyWindowMaterial.solid),
              Brightness.light,
            ),
            material: ZhyWindowMaterial.solid,
          ),
          home: Scaffold(body: LogPanel(onClose: () {})),
        ),
      ),
    );
    await tester.pump();
    return buffer;
  }

  /// 等一次合并通知（120ms）落地并重建界面。
  Future<void> settleBuffer(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
  }

  testWidgets('空状态提示去播放一首歌', (WidgetTester tester) async {
    await pumpPanel(tester);
    expect(find.text('还没有日志。播放一首歌再回来看看。'), findsOneWidget);
    expect(find.text('调试日志'), findsOneWidget);
    // 标题栏和底栏各有一处条数，所以是 2 个。
    expect(find.textContaining('共 0 条'), findsNWidgets(2));
  });

  testWidgets('渲染日志行、来源标签与丢弃计数', (WidgetTester tester) async {
    final LogBuffer buffer = await pumpPanel(tester);
    buffer
      ..add(LogLevel.error, '[netease] song/url/v1 失败，改用旧接口')
      ..add(LogLevel.warning, '[http] 请求超时，准备重试');
    await settleBuffer(tester);

    expect(find.textContaining('song/url/v1 失败'), findsOneWidget);
    expect(find.textContaining('请求超时'), findsOneWidget);
    // tag 只显示一次：前缀已经从 message 里剥掉了。
    expect(find.textContaining('[netease]'), findsOneWidget);

    // 超容量之后界面必须说明"更早的日志已被丢弃"。
    // 先进去 2 条，再写 capacity + 3 条：丢的是最旧的 2 + 3 = 5 条。
    for (int i = 0; i < buffer.capacity + 3; i++) {
      buffer.add(LogLevel.debug, '第 $i 条');
    }
    await settleBuffer(tester);
    expect(buffer.length, buffer.capacity);
    expect(buffer.droppedCount, 5);
    expect(find.textContaining('已丢弃 5 条更早日志'), findsOneWidget);
  });

  testWidgets('级别过滤与关键字搜索', (WidgetTester tester) async {
    final LogBuffer buffer = await pumpPanel(tester);
    buffer
      ..add(LogLevel.debug, '[player] 已预解析下一首：晴天')
      ..add(LogLevel.warning, '[http] 请求超时，准备重试')
      ..add(LogLevel.error, '[netease] song/url/v1 失败，改用旧接口');
    await settleBuffer(tester);

    expect(find.textContaining('已预解析下一首'), findsOneWidget);

    // 「仅错误」应当把 debug 与 warning 都藏起来。
    // 点 ChoiceChip 而不是里面的 Text：Text 的宽度只有两个字，
    // 它自己的中心点可能落在 chip 的 padding 上，命中判定会很脆。
    await tester.tap(find.widgetWithText(ChoiceChip, '仅错误'));
    await tester.pump();
    expect(find.textContaining('已预解析下一首'), findsNothing);
    expect(find.textContaining('请求超时'), findsNothing);
    expect(find.textContaining('song/url/v1 失败'), findsOneWidget);
    expect(find.textContaining('显示 1 / 3 条'), findsOneWidget);

    // 级别筛选还停在"仅错误"，超时属于 warning，所以是空结果而不是报错。
    await tester.enterText(find.byType(TextField), '超时');
    await tester.pump();
    expect(find.textContaining('song/url/v1 失败'), findsNothing);
    expect(find.textContaining('没有符合条件的日志'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
    await tester.pump();
    expect(find.textContaining('请求超时'), findsOneWidget);
    expect(find.textContaining('已预解析下一首'), findsNothing);
  });

  testWidgets('用户手动往上滚之后不再被强行拉到底部', (WidgetTester tester) async {
    final LogBuffer buffer = await pumpPanel(tester);
    for (int i = 0; i < 120; i++) {
      buffer.add(LogLevel.debug, '第 $i 条日志');
    }
    await settleBuffer(tester);

    // ListView 里会套出不止一个 Scrollable（Scrollbar 也会贡献一个），
    // 取第一个，它就是真正滚日志的那个。
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    // 初始应该贴着底部（自动跟随）。先确认它真的可滚，否则
    // maxScrollExtent == 0，下面所有断言都会退化成"0 约等于 0"。
    expect(
      scrollable.position.maxScrollExtent,
      greaterThan(0),
      reason: '120 条日志必须撑出可滚动的高度，否则这个用例什么都没测到',
    );
    expect(
      scrollable.position.pixels,
      closeTo(scrollable.position.maxScrollExtent, 1),
      reason: '新日志到来时应该自动滚到底',
    );

    // 手动往上翻。
    await tester.drag(find.byType(ListView), const Offset(0, 250));
    await tester.pump();
    expect(
      scrollable.position.pixels,
      lessThan(scrollable.position.maxScrollExtent - 1),
    );
    expect(find.text('回到最新'), findsOneWidget, reason: '应该出现"回到最新"入口');

    // 这时候再来一大批日志，视图必须停在原地。
    final double before = scrollable.position.pixels;
    for (int i = 0; i < 40; i++) {
      buffer.add(LogLevel.error, '刷屏 $i');
    }
    await settleBuffer(tester);
    expect(
      scrollable.position.pixels,
      closeTo(before, 1),
      reason: '用户正在翻日志，绝不能被强行拉到底部',
    );

    // 点「回到最新」之后恢复跟随。
    await tester.tap(find.text('回到最新'));
    await settleBuffer(tester);
    expect(
      scrollable.position.pixels,
      closeTo(scrollable.position.maxScrollExtent, 1),
    );
    expect(find.text('回到最新'), findsNothing);
  });

  testWidgets('详情默认折叠，点开之后显示堆栈', (WidgetTester tester) async {
    final LogBuffer buffer = await pumpPanel(tester);
    buffer.add(LogLevel.error, '[download] 1 下载失败：连接被重置\n#0 DioException');
    await settleBuffer(tester);

    expect(find.textContaining('#0 DioException'), findsNothing);
    await tester.tap(find.byIcon(Icons.unfold_more_rounded));
    await tester.pump();
    expect(find.textContaining('#0 DioException'), findsOneWidget);
  });

  testWidgets('复制全部与清空都会给提示', (WidgetTester tester) async {
    // 测试环境没有真的剪贴板：把通道接管掉，避免依赖平台实现的超时行为。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final LogBuffer buffer = await pumpPanel(tester);
    buffer.add(LogLevel.error, '[netease] song/url/v1 失败');
    await settleBuffer(tester);

    // 面板挂在 Overlay 里，SnackBar 仍然要能找到 Messenger ——
    // 找不到的话这里会一句话都不提示，用户会以为按钮没反应。
    await tester.tap(find.byIcon(Icons.content_copy_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('已复制 1 条日志'), findsOneWidget);
    expect(copied, isNotNull, reason: '导出的文本要真的写进剪贴板');
    expect(copied, contains('song/url/v1 失败'));
    expect(copied, contains('[错误]'));

    // 先把上一条提示收掉：ScaffoldMessenger 是**排队**的，
    // 第二条要等第一条自己消失（默认 4 秒）才会显示。
    ScaffoldMessenger.of(
      tester.element(find.byType(LogPanel)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('已清空 1 条日志'), findsOneWidget);
    expect(buffer.isEmpty, isTrue);
    expect(find.text('还没有日志。播放一首歌再回来看看。'), findsOneWidget);
  });

  testWidgets('维护分区可以打开日志面板，且设置页本身不受影响', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        // 不写显式类型参数：Riverpod 3 没有从 flutter_riverpod 导出 Override。
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          coverCacheProvider.overrideWithValue(_StubCoverCache()),
          neteaseAccountProvider.overrideWith(() => _StubAccountNotifier()),
          bilibiliAccountProvider.overrideWith(() => _StubAccountNotifier()),
        ],
        child: MaterialApp(
          theme: buildZhyTheme(
            scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            tokens: buildZhyTokens(
              const ZhyThemeSettings(material: ZhyWindowMaterial.solid),
              Brightness.light,
            ),
            material: ZhyWindowMaterial.solid,
          ),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('打开调试日志'),
      300,
      scrollable: list,
    );
    expect(find.text('打开调试日志'), findsOneWidget);

    // scrollUntilVisible 只保证"进了视口"，按钮可能正好压在底边外面，
    // 直接 tap 会落在视口之外。ensureVisible 再滚一次把它完整露出来。
    await tester.ensureVisible(find.text('打开调试日志'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开调试日志'));
    await tester.pumpAndSettle();

    // 面板是插进 Overlay 的，不和设置页争地盘。
    expect(find.text('调试日志'), findsOneWidget);
    expect(find.text('还没有日志。播放一首歌再回来看看。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
