import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/core/ui/window_drag_region.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/features/search/search_page.dart';
import 'package:zhuoyue_player/features/shell/app_shell.dart';
import 'package:zhuoyue_player/features/shell/title_bar.dart';

/// 标题栏搜索框已被移除，这里钉住两件容易在后续改动里被弄回去的事：
///
/// 1. 标题栏里**真的没有输入框**了 —— 用户反馈"上方搜索栏与左侧导航重复"，
///    而"删掉一个控件"这种改动最容易在下次调标题栏布局时被顺手加回来。
/// 2. 删掉搜索框**不能顺带削弱拖动区**。拖动区铺在 `Stack` 最底层、
///    靠"上层组件先吃掉手势"来划分可点区域；搜索框一走，中间那一大片
///    就全是空白，如果拖动区还是按老尺寸铺的，用户会发现窗口拖不动了。
///    所以这里量的是它**仍然整条铺满**。
///
/// 同时验证搜索入口本身没被一起删掉：导航枚举里的「搜索」还在原位，
/// 而搜索页仍然自带可输入、自动聚焦的输入框。
void main() {
  /// `AppTitleBar` 的 `initState` 会问一次窗口是否最大化。
  /// 测试环境没有平台实现，不接管这个方法通道的话那次调用会以
  /// `MissingPluginException` 收场 —— 一条与本测试目的完全无关的异步失败。
  void mockWindowManager(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async {
        if (call.method == 'isMaximized') return false;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
  }

  ThemeData testTheme() {
    const ZhyThemeSettings settings = ZhyThemeSettings(
      material: ZhyWindowMaterial.solid,
    );
    return buildZhyTheme(
      scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      tokens: buildZhyTokens(settings, Brightness.light),
      material: settings.material,
    );
  }

  Future<void> pumpTitleBar(WidgetTester tester) async {
    mockWindowManager(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: Column(children: <Widget>[AppTitleBar(title: '卓越播放器')]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('标题栏', () {
    testWidgets('不再有搜索框，只剩应用标识与三个窗口按钮', (WidgetTester tester) async {
      await pumpTitleBar(tester);

      // 核心断言：整条标题栏里没有输入框。
      expect(
        find.byType(TextField),
        findsNothing,
        reason: '标题栏搜索框与左侧导航的「搜索」分区重复，必须整体移除',
      );
      // 清空按钮是搜索框的附属物，它读的是输入框的 controller，
      // 搜索框没了之后还能找到 IconButton 就说明有残留。
      expect(find.byType(IconButton), findsNothing, reason: '搜索框的"清空"按钮不应残留');
      expect(find.text('搜索歌曲、歌手、专辑'), findsNothing);

      // 留下的是：标题（左侧）+ 三个窗口按钮（右上）。
      expect(find.text('卓越播放器'), findsOneWidget);
      expect(find.byTooltip('最小化'), findsOneWidget);
      expect(find.byTooltip('最大化'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
    });

    testWidgets('标题仍在左侧，三个窗口按钮仍靠右上且顺序不变', (WidgetTester tester) async {
      await pumpTitleBar(tester);

      final double barWidth = tester.getSize(find.byType(AppTitleBar)).width;
      final Rect title = tester.getRect(find.text('卓越播放器'));
      final Rect minimize = tester.getRect(find.byTooltip('最小化'));
      final Rect maximize = tester.getRect(find.byTooltip('最大化'));
      final Rect close = tester.getRect(find.byTooltip('关闭'));

      // 标题贴左边：偏离左侧超过半个标题栏就说明布局被改坏了。
      expect(title.left, lessThan(barWidth / 4));

      // 三个按钮都在右半边，并且保持"最小化 → 最大化 → 关闭"的顺序。
      expect(minimize.left, greaterThan(barWidth / 2));
      expect(minimize.left, lessThan(maximize.left));
      expect(maximize.left, lessThan(close.left));
      // 关闭按钮贴右边缘（原生 Windows 的手感）。
      expect(close.right, moreOrLessEquals(barWidth, epsilon: 1));

      // 高度不变：三个按钮都还在标题栏那一条里，没有把标题栏撑高。
      final double barHeight = tester.getSize(find.byType(AppTitleBar)).height;
      for (final Rect button in <Rect>[minimize, maximize, close]) {
        expect(button.top, greaterThanOrEqualTo(0));
        expect(button.bottom, lessThanOrEqualTo(barHeight + 1));
      }
    });

    testWidgets('删掉搜索框后，拖动区仍然整条铺满标题栏', (WidgetTester tester) async {
      await pumpTitleBar(tester);

      final Size barSize = tester.getSize(find.byType(AppTitleBar));
      final Size dragSize = tester.getSize(find.byType(WindowDragRegion));

      expect(dragSize, barSize, reason: '拖动区必须仍然覆盖整条标题栏，中间那段空白也要能拖动');
      // 搜索框原来正好在标题栏中间，这里顺带钉住"中间确实是空的"：
      // 以标题栏中心点为原点做命中测试，应当命中不到任何输入框。
      final Offset center = Offset(barSize.width / 2, barSize.height / 2);
      expect(
        find.byType(EditableText).hitTestable().evaluate().isEmpty,
        isTrue,
        reason: '标题栏中心($center)附近不应再有可输入的控件',
      );
    });
  });

  group('搜索入口仍然可达', () {
    test('「搜索」导航项还在，且顺序未变', () {
      // 侧边栏就是按 ShellSection.values 的顺序渲染的，枚举顺序即渲染顺序，
      // 所以这里断言枚举本身就是最直接的"入口还在"证据
      //（widget test 起不来 AppShell，它依赖窗口插件与音频引擎）。
      expect(
        ShellSection.values.map((ShellSection s) => s.name).toList(),
        <String>[
          'discover',
          'neteasePlaylists',
          'bilibili',
          'search',
          'downloads',
          'accounts',
          'settings',
        ],
      );
      expect(ShellSection.search.label, '搜索');
    });

    testWidgets('进搜索页是一个空白且自动聚焦的输入框', (WidgetTester tester) async {
      // 标题栏不再传关键词进来了，搜索页必须靠自己撑住"进来就能打字"。
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: testTheme(),
            home: const Scaffold(body: SearchPage(source: MediaSource.netease)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).autofocus,
        isTrue,
        reason: '搜索页的输入框要自己自动聚焦，否则从导航进来还得再点一下',
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
        reason: '不再从标题栏带关键词进来，搜索页应当是空白的',
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
    });
  });
}
