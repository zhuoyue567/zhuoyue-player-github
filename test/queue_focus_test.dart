import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/data/models/lyric.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/features/player/lyric_view.dart';
import 'package:zhuoyue_player/features/player/now_playing_page.dart';
import 'package:zhuoyue_player/features/player/player_controller.dart';
import 'package:zhuoyue_player/features/player/queue_view.dart';

// ---------------------------------------------------------------------------
// 测试夹具
// ---------------------------------------------------------------------------

/// 列表视口高度。
///
/// 400 / 50 = 8 行，远小于 60 首的队列，足够造出"滚到中间"与"贴顶 / 贴底"
/// 三种场景；同时又足够高，行框能把文字完整装下（挤压后量出来的矩形没有
/// 参考价值）。
const double _viewport = 400;

/// 队列长度与关键下标。
const int _count = 60;
const int _target = 42;

/// 只提供状态的假控制器。
///
/// 覆盖 `build()` 而不是驱动真实的 [PlayerController]：真实的 build 要读音频
/// 引擎与偏好设置，而这里要验证的只有"队列下标 → 滚动偏移"，与引擎无关。
/// 直接改 `state` 也绕开了"换曲就要解析播放地址"的联网路径。
class _StubPlayerController extends PlayerController {
  _StubPlayerController(this.initial);

  final PlayerUiState initial;

  @override
  PlayerUiState build() => initial;

  /// 切换当前曲目：自动下一首与"用户在别处点了另一首"在界面上的表现相同。
  void setIndex(int index) => state = state.copyWith(index: index);

  /// 推一次播放位置。真实控制器每 200ms 就会推一次，列表会跟着重建 ——
  /// 这条路径不该产生任何滚动。
  void setPosition(Duration position) =>
      state = state.copyWith(position: position);
}

/// 歌词永远"还在加载"：全屏播放页那一组用例只关心队列标签，
/// 不需要真的去音源取歌词（真实 notifier 会发网络请求）。
class _StubLyricNotifier extends CurrentLyricNotifier {
  @override
  Lyric? build() => null;
}

List<Song> _songs(int count) => <Song>[
  for (int i = 0; i < count; i++)
    Song(
      id: 'song-$i',
      source: MediaSource.netease,
      title: '第 $i 首',
      artists: const <String>['歌手'],
      duration: const Duration(seconds: 200),
    ),
];

/// 挂起**真实**的全屏播放页（不是副本）：歌词、封面、进度条都走生产接线，
/// 这样"切到队列标签"测的才是线上那条路径。
Widget _nowPlayingApp(ProviderContainer container) {
  const ZhyThemeSettings settings = ZhyThemeSettings(
    material: ZhyWindowMaterial.solid,
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildZhyTheme(
        scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        tokens: buildZhyTokens(settings, Brightness.light),
        material: settings.material,
      ),
      home: const NowPlayingPage(),
    ),
  );
}

/// 把队列列表挂进一棵最小可用的小树。
///
/// 用真的 [buildZhyTheme]：行高、圆角、动画时长都来自设计令牌，换成假主题就
/// 量不出真实的行框（"完整落在视口内"这条断言正是按行框算的）。
///
/// `active` 与生产里的 `QueueIsland.open` 一一对应：island 收起时列表**仍在
/// 树里**，所以"打开"必须靠这个字段告知列表，而不是靠重建。
Widget _app(ProviderContainer container, {bool active = true}) {
  const ZhyThemeSettings settings = ZhyThemeSettings(
    material: ZhyWindowMaterial.solid,
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildZhyTheme(
        scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        tokens: buildZhyTokens(settings, Brightness.light),
        material: settings.material,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: _viewport,
            child: QueueListView(active: active),
          ),
        ),
      ),
    ),
  );
}

/// 造一个只带队列状态的容器。
ProviderContainer _container({required int count, required int index}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      playerControllerProvider.overrideWith(
        () => _StubPlayerController(
          PlayerUiState(queue: _songs(count), index: index),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 起一棵带队列的树，返回容器与假控制器。
///
/// [WidgetTester.pumpWidget] 之后那一次 `pump` 是必要的：聚焦偏移的**帧尾
/// 校正**发生在首帧结束时，多泵一帧才能看到它的结果（正常情况下它是空操作，
/// 因为首帧已经由 `initialScrollOffset` 摆正）。
Future<({ProviderContainer container, _StubPlayerController controller})>
_pumpQueue(
  WidgetTester tester, {
  required int count,
  required int index,
  bool active = true,
}) async {
  final ProviderContainer container = _container(count: count, index: index);
  await tester.pumpWidget(_app(container, active: active));
  await tester.pump();
  return (
    container: container,
    controller: container.read(
      playerControllerProvider.notifier,
    ) as _StubPlayerController,
  );
}

/// 列表可视区的矩形（"完整落在视口内"拿它当边界）。
Rect _listViewport(WidgetTester tester) =>
    tester.getRect(find.byType(Scrollable).first);

/// 第 [index] 行的矩形。
Rect _rowRect(WidgetTester tester, int index) =>
    tester.getRect(find.byKey(QueueListView.rowKey(index)));

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// 断言某一行的行框完整落在可视区内，并回传它与视口中心的垂直距离。
double _expectFullyVisible(WidgetTester tester, int index) {
  final Rect viewport = _listViewport(tester);
  final Rect row = _rowRect(tester, index);
  expect(
    row.top,
    greaterThanOrEqualTo(viewport.top - 0.001),
    reason: '第 $index 行的上边被视口裁掉了',
  );
  expect(
    row.bottom,
    lessThanOrEqualTo(viewport.bottom + 0.001),
    reason: '第 $index 行的下边被视口裁掉了',
  );
  return (row.center.dy - viewport.center.dy).abs();
}

/// 偏移必须落在可滚范围内。
void _expectInRange(ScrollPosition position) {
  expect(position.pixels, greaterThanOrEqualTo(0));
  expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // 纯函数：下标 → 目标偏移
  // -------------------------------------------------------------------------
  group('queueScrollOffsetFor 目标偏移', () {
    const double row = kQueueRowExtent;

    test('居中：上内边距 + 下标×槽高 + 半行 - 半视口', () {
      // 下标取中段：否则目标会被夹到 0，就验不出这条换算了。
      const int index = 30;
      expect(
        queueScrollOffsetFor(
          index: index,
          itemCount: _count,
          viewportDimension: _viewport,
        ),
        kQueueListPadding + index * row + row / 2 - _viewport / 2,
      );
    });

    test('行高 + 间距 = 槽高（行布局与 itemExtent 共用这一份）', () {
      expect(kQueueRowExtent, kQueueRowHeight + kQueueRowGap);
    });

    test('首行夹到 0：目标本来是负数，第一行永远无法真正居中', () {
      expect(
        queueScrollOffsetFor(
          index: 0,
          itemCount: _count,
          viewportDimension: _viewport,
        ),
        0,
      );
    });

    test('末行夹到 maxScrollExtent，不会滚过内容底部', () {
      final double content = kQueueListPadding * 2 + _count * row;
      final double maxScroll = content - _viewport;
      expect(maxScroll, greaterThan(0), reason: '这个夹具必须有可滚空间');

      expect(
        queueScrollOffsetFor(
          index: _count - 1,
          itemCount: _count,
          viewportDimension: _viewport,
        ),
        maxScroll,
      );
    });

    test('队列比视口还短：无处可滚', () {
      expect(
        queueScrollOffsetFor(
          index: 2,
          itemCount: 3,
          viewportDimension: _viewport,
        ),
        0,
      );
    });

    test('下标或长度非法时回落到 0', () {
      expect(
        queueScrollOffsetFor(
          index: -1,
          itemCount: _count,
          viewportDimension: _viewport,
        ),
        0,
      );
      expect(
        queueScrollOffsetFor(
          index: 0,
          itemCount: 0,
          viewportDimension: _viewport,
        ),
        0,
      );
    });

    test('视口高度未知（0 / 无穷）时也给出范围内的偏移', () {
      final double content = kQueueListPadding * 2 + _count * row;
      for (final double viewport in <double>[0, double.infinity]) {
        final double offset = queueScrollOffsetFor(
          index: 5,
          itemCount: _count,
          viewportDimension: viewport,
        );
        expect(offset, greaterThanOrEqualTo(0));
        expect(offset, lessThanOrEqualTo(content));
      }
    });
  });

  // -------------------------------------------------------------------------
  // 打开即聚焦
  // -------------------------------------------------------------------------
  group('打开队列时聚焦当前曲目', () {
    testWidgets('首帧就到位：偏移来自 initialScrollOffset，首帧里没有任何滚动', (
      WidgetTester tester,
    ) async {
      // 刻意不走 _pumpQueue：它多泵一帧，会把帧尾校正的结果也算进来。
      // 这里在树外面套一层通知监听，用来证明第一帧里**没有发生过滚动** ——
      // 如果偏移是靠在帧尾补一次 jumpTo 才对的，这里必然会收到若干条
      // ScrollStart / ScrollUpdate / ScrollEnd（那正是用户会看到的"跳一下"）。
      final ProviderContainer container = _container(
        count: _count,
        index: _target,
      );
      int scrollNotifications = 0;
      await tester.pumpWidget(
        NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification notification) {
            scrollNotifications++;
            return false;
          },
          child: _app(container),
        ),
      );

      final double gap = _expectFullyVisible(tester, _target);
      expect(gap, lessThan(1));
      expect(
        scrollNotifications,
        0,
        reason: '首帧不该有滚动：位置必须由挂载前的 initialScrollOffset 给出',
      );
    });

    testWidgets('当前曲目完整落在视口内，并且垂直居中', (WidgetTester tester) async {
      await _pumpQueue(tester, count: _count, index: _target);

      // 先确认它真的滚了：只断言"offset != 0"说明不了位置对不对。
      expect(_position(tester).pixels, greaterThan(0));

      final double gap = _expectFullyVisible(tester, _target);
      expect(
        gap,
        lessThanOrEqualTo(kQueueRowExtent / 2),
        reason: '当前曲目偏离视口中线超过半行，就不叫"居中"了',
      );
      // 这一首在队列中段，理应能真正居中，而不是夹取之后的贴边结果。
      expect(gap, lessThan(1), reason: '中段的曲目应当精确居中');
    });

    testWidgets('index = 0：贴顶，不越界且当前行完整可见', (WidgetTester tester) async {
      await _pumpQueue(tester, count: _count, index: 0);

      final ScrollPosition position = _position(tester);
      _expectInRange(position);
      expect(position.pixels, 0);
      _expectFullyVisible(tester, 0);
    });

    testWidgets('index = 59：贴底，不越界且当前行完整可见', (WidgetTester tester) async {
      await _pumpQueue(tester, count: _count, index: _count - 1);

      final ScrollPosition position = _position(tester);
      _expectInRange(position);
      expect(
        position.pixels,
        closeTo(position.maxScrollExtent, 0.001),
        reason: '末行只能贴底，绝不能滚过内容底部',
      );
      _expectFullyVisible(tester, _count - 1);
    });

    testWidgets('列表收起时不滚动，打开的那一刻才对准当前曲目', (WidgetTester tester) async {
      final ({ProviderContainer container, _StubPlayerController controller})
      harness = await _pumpQueue(
        tester,
        count: _count,
        index: _target,
        active: false,
      );
      // 收起状态下第一次挂载就已经摆好位置（挂载时算一次偏移，代价为零）。
      final double whenClosed = _position(tester).pixels;
      expect(whenClosed, greaterThan(0));

      // 收起期间换曲：不为一个看不见的列表做滚动动画。
      harness.controller.setIndex(_target + 3);
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, closeTo(whenClosed, 0.001));

      // 打开：同一个 State 从 active=false 翻到 true —— 正是 island 滑入那条路径。
      await tester.pumpWidget(_app(harness.container));
      await tester.pumpAndSettle();

      expect(
        _position(tester).pixels,
        isNot(closeTo(whenClosed, 0.5)),
        reason: '打开时应当重新对准当前曲目',
      );
      final double gap = _expectFullyVisible(tester, _target + 3);
      expect(gap, lessThan(1));
    });
  });

  // -------------------------------------------------------------------------
  // 打开期间换曲
  // -------------------------------------------------------------------------
  group('打开期间当前曲目变化', () {
    testWidgets('用户没滚过：列表跟着滚过去', (WidgetTester tester) async {
      final ({ProviderContainer container, _StubPlayerController controller})
      harness = await _pumpQueue(tester, count: _count, index: _target);
      final double before = _position(tester).pixels;

      harness.controller.setIndex(_target + 8);
      await tester.pumpAndSettle();

      final double after = _position(tester).pixels;
      expect(after, isNot(closeTo(before, 0.5)), reason: '换曲之后没有跟过去');
      final double gap = _expectFullyVisible(tester, _target + 8);
      expect(gap, lessThan(1), reason: '跟过去之后也应当居中');
    });

    testWidgets('用户手动滚动过：绝不把他拽回当前曲目', (WidgetTester tester) async {
      final ({ProviderContainer container, _StubPlayerController controller})
      harness = await _pumpQueue(tester, count: _count, index: _target);
      final double focused = _position(tester).pixels;

      // 往下拖：内容下移 = 往回滚。拖 300 ≈ 6 行，当前曲目被远远甩出中线。
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
      await tester.pumpAndSettle();
      final double dragged = _position(tester).pixels;
      expect(dragged, lessThan(focused - 100), reason: '这一拖必须真的滚走');

      harness.controller.setIndex(_target + 8);
      await tester.pumpAndSettle();

      expect(
        _position(tester).pixels,
        closeTo(dragged, 0.001),
        reason: '用户滚过之后换曲，列表位置必须原地不动',
      );
    });

    testWidgets('播放位置每 200ms 更新一次：列表不会跟着反复滚', (WidgetTester tester) async {
      final ({ProviderContainer container, _StubPlayerController controller})
      harness = await _pumpQueue(tester, count: _count, index: _target);
      final double focused = _position(tester).pixels;

      // 宿主 watch 的是整个播放状态，位置每 200ms 来一次就会重建列表一次；
      // 每一次重建都重新算一遍滚动目标的话，滚动动画永远重启不完。
      for (int i = 1; i <= 5; i++) {
        harness.controller.setPosition(Duration(seconds: i));
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(_position(tester).pixels, closeTo(focused, 0.001));
    });

    testWidgets('用户滚回当前曲目附近后恢复跟随', (WidgetTester tester) async {
      final ({ProviderContainer container, _StubPlayerController controller})
      harness = await _pumpQueue(tester, count: _count, index: _target);
      final double focused = _position(tester).pixels;

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
      await tester.pumpAndSettle();
      final double dragged = _position(tester).pixels;
      expect(dragged, lessThan(focused - 100));

      // 再拖回来：当前曲目重新落回视口中线附近（容差半行，够稳）。
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, closeTo(focused, kQueueRowExtent / 2));

      // 跟随即刻恢复：此时换曲应当重新跟过去。
      harness.controller.setIndex(_target + 8);
      await tester.pumpAndSettle();
      expect(
        _position(tester).pixels,
        isNot(closeTo(focused, 0.5)),
        reason: '滚回当前曲目附近之后应当恢复跟随',
      );
      _expectFullyVisible(tester, _target + 8);
    });
  });

  // -------------------------------------------------------------------------
  // 全屏播放页的「队列 (N)」标签
  // -------------------------------------------------------------------------
  group('全屏播放页切到队列标签', () {
    testWidgets('首帧就在位：切过去的那一刻当前曲目已经完整可见', (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          playerControllerProvider.overrideWith(
            () => _StubPlayerController(
              PlayerUiState(queue: _songs(_count), index: _target),
            ),
          ),
          currentLyricProvider.overrideWith(_StubLyricNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_nowPlayingApp(container));

      // 初始是歌词标签，队列列表还不存在 —— 切过去时它是**全新建出来**的，
      // 首帧的偏移只能来自 initialScrollOffset。
      expect(find.byType(QueueListView), findsNothing);

      await tester.tap(find.text('队列 ($_count)'));
      // 只泵一帧：这一刻排版出来的就是用户切过去看到的第一帧。
      await tester.pump();

      final double gap = _expectFullyVisible(tester, _target);
      expect(gap, lessThan(1), reason: '切到队列标签时应当已经居中，而不是从头滚过去');
    });
  });
}
