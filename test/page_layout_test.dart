import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/core/ui/glass.dart';
import 'package:zhuoyue_player/core/ui/page_layout.dart';
import 'package:zhuoyue_player/core/ui/song_list.dart';

/// 标题栏 / 播放条在骨架里的占位高度。
///
/// 具体数值不重要 —— 这两条只是把内容区夹在中间，让"三栏拿到的可用高度"
/// 是一个有限值（和真机一样）。断言比的是**各栏之间的差值**，不是绝对坐标。
const double _titleBarHeight = 44;
const double _playerBarHeight = 110;

const Key _railKey = Key('rail');
const Key _middleKey = Key('middle');
const Key _contentKey = Key('content');
const Key _islandKey = Key('island');

/// 撑满一格高度的占位内容。
///
/// 带 `Spacer` 是刻意的：真实的导航栏里也有一个 `Spacer`，
/// 玻璃卡正是靠"Column(mainAxisSize.max) + 弹性子节点"把高度吃满。
/// 用一个固定高度的盒子会得到不一样的约束路径，测出来的就不是真布局了。
class _Fill extends StatelessWidget {
  const _Fill();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: <Widget>[SizedBox(height: 20), Spacer()],
    );
  }
}

/// 复刻 `AppShell` 的内容区结构：左导航 + 内容区（中栏 + 右栏）+ 浮层 island。
///
/// 为什么不直接 pump `AppShell`：它依赖窗口插件与音频引擎（window_manager、
/// just_audio），在 widget test 里根本起不来。这里只保留**布局骨架**，
/// 而且每一处留白都取生产代码里的那一份定义（`ZhyPageLayout` 与
/// `ThreeColumnBody`），所以只要有人把某一栏改回"自己一套"，
/// 这个测试就会红。
Widget _shellLike() {
  const ZhyThemeSettings settings = ZhyThemeSettings(
    material: ZhyWindowMaterial.solid,
  );

  return MaterialApp(
    theme: buildZhyTheme(
      scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      tokens: buildZhyTokens(settings, Brightness.light),
      material: settings.material,
    ),
    home: Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: <Widget>[
          const SizedBox(
            height: _titleBarHeight,
            child: ColoredBox(color: Color(0x22000000)),
          ),
          Expanded(
            child: Stack(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    SizedBox(
                      width: 216,
                      child: Padding(
                        // 与 _Sidebar 一模一样：留白只来自共享定义。
                        padding: ZhyPageLayout.navRailInsets,
                        child: const GlassPanel(
                          key: _railKey,
                          child: _Fill(),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ThreeColumnBody(
                        middleWidth: 292,
                        middle: const GlassPanel(
                          key: _middleKey,
                          child: _Fill(),
                        ),
                        content: const GlassPanel(
                          key: _contentKey,
                          child: _Fill(),
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: ZhyPageLayout.overlayColumnInsets.top,
                  bottom: ZhyPageLayout.overlayColumnInsets.bottom,
                  right: 8,
                  child: const SizedBox(
                    width: 320,
                    child: GlassPanel(key: _islandKey, child: _Fill()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(
            height: _playerBarHeight,
            child: ColoredBox(color: Color(0x22000000)),
          ),
        ],
      ),
    ),
  );
}

void main() {
  test('三栏的上下留白只有一处定义', () {
    // 这条不测像素，测的是"还有没有第二套数字"：三栏的上下必须都指向
    // columnTop / columnBottom，谁自己写一个常数这里就红。
    expect(ZhyPageLayout.navRailInsets.top, ZhyPageLayout.columnTop);
    expect(ZhyPageLayout.navRailInsets.bottom, ZhyPageLayout.columnBottom);
    expect(ZhyPageLayout.contentInsets.top, ZhyPageLayout.columnTop);
    expect(ZhyPageLayout.contentInsets.bottom, ZhyPageLayout.columnBottom);
    expect(ZhyPageLayout.overlayColumnInsets.top, ZhyPageLayout.columnTop);
    expect(
      ZhyPageLayout.overlayColumnInsets.bottom,
      ZhyPageLayout.columnBottom,
    );
  });

  test('单栏页面（发现 / 搜索 / 下载）用的默认留白与共享定义一致', () {
    // 这三页都用 PageContentContainer 的默认值。那个默认值是同一组数字的
    // 第二份拷贝，这里把它钉住：谁改歪了，单栏页面的上下就会和三栏错开。
    const PageContentContainer container = PageContentContainer(
      child: SizedBox.shrink(),
    );
    expect(container.padding, ZhyPageLayout.contentInsets);
  });

  testWidgets('三栏（导航 / 中栏 / 右栏 / 队列 island）的上下边界一致', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_shellLike());
    await tester.pumpAndSettle();

    final Rect rail = tester.getRect(find.byKey(_railKey));
    final Rect middle = tester.getRect(find.byKey(_middleKey));
    final Rect content = tester.getRect(find.byKey(_contentKey));
    final Rect island = tester.getRect(find.byKey(_islandKey));

    // 需求是"差值 ≤ 2 物理像素"，所以换算成物理像素再比。
    // 本测试里 devicePixelRatio 是 3，也就是逻辑像素上连 1px 都不许差。
    final double dpr = tester.view.devicePixelRatio;
    double gapTop(Rect other) => (rail.top - other.top).abs() * dpr;
    double gapBottom(Rect other) => (rail.bottom - other.bottom).abs() * dpr;

    expect(gapTop(middle), lessThanOrEqualTo(2.0), reason: '中栏顶部与导航栏没对齐');
    expect(
      gapBottom(middle),
      lessThanOrEqualTo(2.0),
      reason: '中栏底部与导航栏没对齐',
    );
    expect(gapTop(content), lessThanOrEqualTo(2.0), reason: '右栏顶部没对齐');
    expect(gapBottom(content), lessThanOrEqualTo(2.0), reason: '右栏底部没对齐');
    expect(gapTop(island), lessThanOrEqualTo(2.0), reason: 'island 顶部没对齐');
    expect(gapBottom(island), lessThanOrEqualTo(2.0), reason: 'island 底部没对齐');

    // 顺便证明这个断言不是空转：三块卡真的从内容区里缩进了，
    // 而不是"大家都等于全高所以当然一样高"。
    final Rect contentArea = tester.getRect(find.byType(Stack).first);
    expect(rail.top, greaterThan(contentArea.top));
    expect(rail.bottom, lessThan(contentArea.bottom));
    expect(rail.height, lessThan(contentArea.height));
  });
}
