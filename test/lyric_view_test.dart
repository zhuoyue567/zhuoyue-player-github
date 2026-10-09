import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/audio/audio_engine.dart';
import 'package:zhuoyue_player/core/storage/preferences.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/data/models/lyric.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/features/player/lyric_view.dart';
import 'package:zhuoyue_player/features/player/player_controller.dart';

// ---------------------------------------------------------------------------
// 测试夹具
// ---------------------------------------------------------------------------

/// 测试用的行高与视口高度。
///
/// 行高直接取生产值：居中的断言比的是"行框中心"与"可视区中心"的差，
/// 行高越小，字体把行框撑开造成的相对误差越大，小行高量出来的像素差
/// 没有参考价值。视口 400 ≈ 7 行（行高放大到 56 之后），
/// 仍然远小于 12 行的歌词，足够造出"滚到中间"的场景。
/// **本文件里所有与偏移有关的期望值都必须写成 `行号 × _rowExtent`**，
/// 写死像素就会在行高变化时变成假绿。
const double _rowExtent = kLyricRowExtent;
const double _viewport = 400;

const Key _centerKey = Key('lyric-center-line');

/// 包住歌词区的重绘边界：像素级断言要在它上面取图。
const Key _boundaryKey = Key('lyric-boundary');

/// 只记录 `seek` 的假引擎：点击歌词跳转不该真的去碰音频。
///
/// 它同时是播放位置的来源 —— 测试通过 [emitPosition] 手动推位置，
/// 于是"每 200ms 来一次位置更新"这件事在测试里完全可控。
class _FakeEngine implements AudioEngine {
  final List<Duration> seeks = <Duration>[];
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playing = StreamController<bool>.broadcast();

  void emitPosition(Duration position) {
    if (!_positions.isClosed) _positions.add(position);
  }

  Future<void> close() async {
    await _positions.close();
    await _playing.close();
  }

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  final Stream<Duration?> durationStream = const Stream<Duration?>.empty();

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  final Stream<bool> bufferingStream = const Stream<bool>.empty();

  @override
  final Stream<Object> errorStream = const Stream<Object>.empty();

  @override
  final Stream<void> completionStream = const Stream<void>.empty();

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 4);

  @override
  bool get playing => false;

  @override
  double get volume => 0.8;

  @override
  double get speed => 1;

  @override
  Future<Duration?> load(
    ResolvedStream stream, {
    Duration? initialPosition,
  }) async => null;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> setSpeed(double value) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// 直接给歌词区喂一份歌词，绕开音源与网络。
///
/// 覆盖 [CurrentLyricNotifier] 而不是覆盖 repository：`build()` 是同步的，
/// 而真实的 notifier 会去 `ref.watch(currentSongProvider)` 并发起一次异步加载
/// —— 那会把每条断言都变成"等一个不存在的网络请求"。null 表示
/// "还在加载"，与真实 notifier 的首帧状态一致。
class _StubLyricNotifier extends CurrentLyricNotifier {
  _StubLyricNotifier(this.stub);

  final Lyric? stub;

  @override
  Lyric? build() => stub;
}

/// 第 n 行的时间：10 秒一行。
Duration _startOf(int index) => Duration(seconds: 10 * index);

/// 12 行歌词：位置充裕，既能测"滚到中间"，也能测"贴顶"。
Lyric _lyric({int count = 12}) => Lyric(
  lines: <LyricLine>[
    for (int i = 0; i < count; i++)
      LyricLine(start: _startOf(i), text: '第 $i 行歌词'),
  ],
);

/// 复刻 `now_playing_page.dart` 里 `_LyricPanel` 的接线方式：
/// 位置来自 provider、点击走 `PlayerController.seek`。
///
/// 测试里不直接复制生产代码的接线，而是让它跟生产代码走同一条链路 ——
/// "点击歌词会 seek"这条断言测的才是真的集成点，而不是一个假的回调。
class _LyricPanelLike extends ConsumerStatefulWidget {
  const _LyricPanelLike({required this.onSeek});

  /// 额外记录一次 seek，用来断言"真的跳到了那一行的时间"。
  final ValueChanged<Duration> onSeek;

  @override
  ConsumerState<_LyricPanelLike> createState() => _LyricPanelLikeState();
}

class _LyricPanelLikeState extends ConsumerState<_LyricPanelLike> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Lyric? lyric = ref.watch(currentLyricProvider);
    final Duration position = ref.watch(
      playerControllerProvider.select((PlayerUiState state) => state.position),
    );
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );

    return RepaintBoundary(
      key: _boundaryKey,
      child: LyricView(
        lyric: lyric,
        // 与生产接线一致：provider 的 null 就是"还在取歌词"。
        loading: lyric == null,
        position: position,
        scrollController: _scroll,
        onSeek: (Duration target) {
          widget.onSeek(target);
          controller.seek(target);
        },
        centerDecoration:
            (BuildContext context, int index, Widget child) =>
                KeyedSubtree(key: _centerKey, child: child),
      ),
    );
  }
}

/// 组装一个接了假引擎的播放器容器；同时给出设置播放位置的小工具。
Future<
  ({
    ProviderContainer container,
    _FakeEngine engine,
    void Function(Duration) setPosition,
  })
>
_player(Lyric? lyric) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'player.volume': 0.8,
  });
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final _FakeEngine engine = _FakeEngine();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      audioEngineProvider.overrideWithValue(engine),
      currentLyricProvider.overrideWith(() => _StubLyricNotifier(lyric)),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(engine.close);
  return (
    container: container,
    engine: engine,
    setPosition: (Duration position) =>
        container.read(playerControllerProvider.notifier).state = container
            .read(playerControllerProvider)
            .copyWith(position: position),
  );
}

/// 把测试替身组成的歌词区挂进一棵最小可用的小树。
///
/// 用真的 [buildZhyTheme] 与 `context.tokens`：布局参数正是测试要量的东西，
/// 换成假主题就量不出真实观感了。
Widget _app(ProviderContainer container, ValueChanged<Duration> onSeek) {
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
            child: _LyricPanelLike(onSeek: onSeek),
          ),
        ),
      ),
    ),
  );
}

/// 当前行行框中心与可视区中心的垂直距离（逻辑像素）。
double _centerGap(WidgetTester tester) {
  final Rect viewport = tester.getRect(find.byType(LyricView));
  final Rect row = tester.getRect(find.byKey(_centerKey));
  return (row.center.dy - viewport.center.dy).abs();
}

/// 让第 [index] 行居中所需的偏移，用真实的滚动区间算出来（不写死数字）。
double _expectedOffset(WidgetTester tester, int index) {
  final ScrollPosition position = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  return lyricScrollOffsetFor(
    index: index,
    rowExtent: _rowExtent,
    maxScrollExtent: position.maxScrollExtent,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // 渐隐遮罩的语义（这一条是"歌词只显示一行"的回归测试）
  // -------------------------------------------------------------------------
  group('lyricFadeGradient 渐隐遮罩', () {
    test('两端透明、中间不透明 —— 写反就会把歌词中间整片擦掉', () {
      // `ShaderMask` + `BlendMode.dstIn` 保留的是遮罩里**不透明**的地方。
      // 所以"上下渐隐、中间清晰"要求渐变两端 alpha=0、中间 alpha=1。
      // 之前这里写成了"两端不透明、中间透明"，结果把中间擦掉，
      // 界面上只剩顶端一行 —— 而基于 getRect 的布局断言看不出这种错。
      final LinearGradient gradient = lyricFadeGradient(
        const Color(0xFF123456),
        fade: 0.12,
      );

      expect(gradient.colors.first.a, 0, reason: '顶端必须透明，否则顶部不渐隐');
      expect(gradient.colors.last.a, 0, reason: '底端必须透明，否则底部不渐隐');
      expect(
        gradient.colors[1].a,
        1,
        reason: '中间必须不透明 —— 这里不透明才不会被 dstIn 擦掉',
      );
      expect(gradient.colors[2].a, 1);
      expect(gradient.stops, <double>[0, 0.12, 0.88, 1]);
    });

    test('渐隐带宽度随传入的 fade 变化，且端点顺序不乱', () {
      final LinearGradient wide = lyricFadeGradient(
        const Color(0xFF123456),
        fade: 0.4,
      );
      expect(wide.stops, <double>[0, 0.4, 0.6, 1]);
    });
  });

  // -------------------------------------------------------------------------
  // 纯函数：位置 → 当前行
  // -------------------------------------------------------------------------
  group('lyricIndexAt', () {
    final List<Duration> starts = <Duration>[
      const Duration(seconds: 10),
      const Duration(seconds: 20),
      const Duration(seconds: 30),
    ];

    test('空歌词返回 -1', () {
      expect(lyricIndexAt(const <Duration>[], const Duration(seconds: 5)), -1);
    });

    test('位置在第一行之前返回 -1（前奏还没到第一句）', () {
      expect(lyricIndexAt(starts, Duration.zero), -1);
      expect(lyricIndexAt(starts, const Duration(milliseconds: 9999)), -1);
    });

    test('位置正好等于某行时间时，该行就是当前行', () {
      expect(lyricIndexAt(starts, const Duration(seconds: 10)), 0);
      expect(lyricIndexAt(starts, const Duration(seconds: 20)), 1);
      expect(lyricIndexAt(starts, const Duration(seconds: 30)), 2);
    });

    test('位置落在两行之间时取前一行', () {
      expect(lyricIndexAt(starts, const Duration(milliseconds: 15500)), 0);
      expect(lyricIndexAt(starts, const Duration(milliseconds: 29999)), 1);
    });

    test('位置超过最后一行时停在最后一行', () {
      expect(lyricIndexAt(starts, const Duration(seconds: 31)), 2);
      expect(lyricIndexAt(starts, const Duration(minutes: 10)), 2);
    });

    test('与 Lyric.indexAt 的判断一致（不另立一套语义）', () {
      final Lyric lyric = _lyric(count: 5);
      final List<Duration> all = lyric.lines
          .map((LyricLine line) => line.start)
          .toList(growable: false);
      for (final Duration probe in <Duration>[
        Duration.zero,
        const Duration(seconds: 1),
        const Duration(seconds: 10),
        const Duration(seconds: 25),
        const Duration(seconds: 40),
        const Duration(seconds: 99),
      ]) {
        expect(lyricIndexAt(all, probe), lyric.indexAt(probe));
      }
    });
  });

  // -------------------------------------------------------------------------
  // 纯函数：居中所需的滚动偏移
  // -------------------------------------------------------------------------
  group('lyricScrollOffsetFor', () {
    const double row = 40;

    test('第 0 行不需要滚动', () {
      expect(
        lyricScrollOffsetFor(index: 0, rowExtent: row, maxScrollExtent: 440),
        0,
      );
    });

    test('第 i 行的居中偏移就是 i × 行高', () {
      // 这是新的几何关系：列表上下各留 (视口−行高)/2 的内边距之后，
      // 第 i 行的中心落在 视口/2 + i*行高，所以只需滚 i*行高。
      expect(
        lyricScrollOffsetFor(index: 5, rowExtent: row, maxScrollExtent: 440),
        200,
      );
      expect(
        lyricScrollOffsetFor(index: 11, rowExtent: row, maxScrollExtent: 440),
        440,
      );
    });

    test('首行与末行都够得着，不会被夹取（这正是以前做不到的地方）', () {
      // 12 行 × 40，上下各留 180，内容高 840，视口 400 → 可滚 440。
      const double maxScroll = 12 * row - row;
      for (int i = 0; i < 12; i++) {
        final double target = lyricScrollOffsetFor(
          index: i,
          rowExtent: row,
          maxScrollExtent: maxScroll,
        );
        expect(target, i * row, reason: '第 $i 行被夹住了，说明留白算错了');
        expect(target, lessThanOrEqualTo(maxScroll));
      }
    });

    test('行高之外的安全网：超出可滚范围时夹住', () {
      expect(
        lyricScrollOffsetFor(index: 11, rowExtent: row, maxScrollExtent: 160),
        160,
      );
    });

    test('没有当前行时返回 0', () {
      expect(
        lyricScrollOffsetFor(index: -1, rowExtent: row, maxScrollExtent: 440),
        0,
      );
    });
  });

  group('lyricListPadding', () {
    test('上下留白 = (视口 − 行高) / 2，首末行才能居中', () {
      final EdgeInsets padding = lyricListPadding(400, 40);
      expect(padding.top, 180);
      expect(padding.bottom, 180);
    });

    test('视口比一行还矮时退回 0，不留负边距', () {
      final EdgeInsets padding = lyricListPadding(20, 40);
      expect(padding.top, 0);
      expect(padding.bottom, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 空状态
  // -------------------------------------------------------------------------
  testWidgets('歌词中间区域必须真的被画出来（渐隐写反会把中间擦成透明）', (
    WidgetTester tester,
  ) async {
    // 这是"歌词只显示一行、下面一片空白"最直接的回归测试：
    // 不量布局，直接取图数像素 —— 布局全对但被遮罩擦掉的情况只有这样才看得见。
    final player = await _player(_lyric());
    await tester.pumpWidget(_app(player.container, (Duration _) {}));
    player.setPosition(const Duration(seconds: 55));
    await tester.pumpAndSettle();

    final RenderRepaintBoundary boundary =
        tester.renderObject(find.byKey(_boundaryKey)) as RenderRepaintBoundary;

    int imageWidth = 0;
    int imageHeight = 0;
    Uint8List? pixels;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      imageWidth = image.width;
      imageHeight = image.height;
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      pixels = data?.buffer.asUint8List();
      image.dispose();
    });

    expect(pixels, isNotNull, reason: '取图失败，这条断言就没有意义了');
    expect(imageWidth, greaterThan(0));

    /// 数一条水平带里有 alpha 的像素。
    int paintedInBand(double fromFraction, double toFraction) {
      final int rowBytes = imageWidth * 4;
      final int top = (imageHeight * fromFraction).round();
      final int bottom = (imageHeight * toFraction).round();
      int painted = 0;
      for (int y = top; y < bottom; y++) {
        for (int x = 0; x < imageWidth; x++) {
          if (pixels![y * rowBytes + x * 4 + 3] > 0) painted++;
        }
      }
      return painted;
    }

    final int middle = paintedInBand(0.4, 0.6);
    final int topBand = paintedInBand(0.0, 0.2);

    // 先证明这条断言不是空转：上下渐隐带本来就应该有内容（当前行附近是实心的
    // 区域外沿），如果连顶部都没有像素，说明整块都没画，下面的断言就无意义。
    expect(
      topBand + paintedInBand(0.8, 1.0),
      greaterThan(0),
      reason: '整块歌词一个像素都没有，说明取图或渲染本身有问题',
    );
    expect(
      middle,
      greaterThan(0),
      reason: '视口中部一个像素都没有 —— 渐隐把中间擦掉了（dstIn 写反的典型症状）',
    );
  });

  testWidgets('没有歌词时给出明确文案，而不是一片空白', (WidgetTester tester) async {
    final player = await _player(const Lyric.empty());
    await tester.pumpWidget(_app(player.container, (Duration _) {}));
    await tester.pumpAndSettle();

    expect(find.text('暂无歌词'), findsOneWidget);
  });

  testWidgets('纯音乐时文案与"暂无歌词"区分开', (WidgetTester tester) async {
    final player = await _player(
      const Lyric(lines: <LyricLine>[], isPureMusic: true),
    );
    await tester.pumpWidget(_app(player.container, (Duration _) {}));
    await tester.pumpAndSettle();

    expect(find.text('纯音乐，请欣赏'), findsOneWidget);
  });

  testWidgets('歌词还没加载出来时显示加载态', (WidgetTester tester) async {
    final player = await _player(null);
    await tester.pumpWidget(_app(player.container, (Duration _) {}));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(player.container.read(currentLyricProvider), isNull);
  });

  // -------------------------------------------------------------------------
  // 居中与跟随
  // -------------------------------------------------------------------------
  testWidgets('当前行始终位于可视区垂直中心', (WidgetTester tester) async {
    final player = await _player(_lyric());
    await tester.pumpWidget(_app(player.container, (Duration _) {}));

    // 中间的行：必须真的滚动才可能居中。
    player.setPosition(const Duration(seconds: 55)); // 第 5 行
    await tester.pumpAndSettle();
    expect(_centerGap(tester), lessThanOrEqualTo(2.0), reason: '第 5 行没有居中');

    // 更靠后的行：滚动目标变了，仍然要居中。
    player.setPosition(const Duration(seconds: 115)); // 第 11 行
    await tester.pumpAndSettle();
    expect(_centerGap(tester), lessThanOrEqualTo(2.0), reason: '第 11 行没有居中');

    // 第 0 行的偏移被夹在 0：不需要滚动，但也应当贴住中心。
    player.setPosition(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_centerGap(tester), lessThanOrEqualTo(2.0), reason: '第 0 行没有贴住中心');
  });

  // -------------------------------------------------------------------------
  // 字号放大（"歌词不够大"的回归测试）
  // -------------------------------------------------------------------------
  testWidgets('当前行字号明显更大，且放大后仍然垂直居中', (WidgetTester tester) async {
    final player = await _player(_lyric());
    await tester.pumpWidget(_app(player.container, (Duration _) {}));

    player.setPosition(const Duration(seconds: 55)); // 第 5 行为当前行
    await tester.pumpAndSettle();

    // 字号来自 `AnimatedDefaultTextStyle`，`Text` 自己的 style 是 null ——
    // 所以只能从**真正渲染出来的段落**上读字号，这也正是用户看到的那个值。
    // （读 widget 树的 style 会拿到 null，读不到就等于没测。）
    double fontSizeOf(int index) {
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.text('第 $index 行歌词'),
      );
      return paragraph.text.style!.fontSize!;
    }

    final double current = fontSizeOf(5);
    final double other = fontSizeOf(4);

    // 这两条是"防止以后有人把它改回去"的底线：数值写死在这里，
    // 不跟着生产常量走，否则把常量改小这条断言也会跟着变绿。
    expect(current, greaterThanOrEqualTo(23), reason: '当前行字号被改小了');
    expect(other, greaterThanOrEqualTo(17), reason: '非当前行字号被改小了');
    expect(
      current,
      greaterThanOrEqualTo(other + 4),
      reason: '当前行与非当前行拉不开差距，就没有"聚焦在中间"的感觉',
    );

    // 行高与字号是一起改的，所以放大之后必须重新量一次居中：
    // 只改字号不改行高会裁字，只改行高不改字号会变空，哪一种都会让这条挂掉。
    expect(
      _centerGap(tester),
      lessThanOrEqualTo(2.0),
      reason: '放大字号后当前行没有垂直居中',
    );
  });

  test('行高与字号同步：容得下"正文 + 译文"，且仍是正文的 2.2~2.6 倍', () {
    // 正文与译文的行高倍数跟着 `_buildRow` 里的 `height` 走：
    // 这里把它写成断言，是为了让"只改字号不改行高"立刻红掉 ——
    // 那一步的后果是文字上下被行框裁掉，界面上看是歌词缺了一半。
    const double textLineHeight = 1.25;
    const double translationLineHeight = 1.2;
    final double tallest =
        kLyricActiveFontSize * textLineHeight +
        kLyricTranslationFontSize * translationLineHeight;

    expect(
      kLyricRowExtent,
      greaterThanOrEqualTo(tallest),
      reason: '行高容不下"当前行正文 + 译文"，文字会被裁',
    );
    expect(
      kLyricRowExtent / kLyricActiveFontSize,
      inInclusiveRange(2.2, 2.6),
      reason: '行高与当前行字号的比例跑出了"够呼吸但不空旷"的经验区间',
    );
  });

  testWidgets('放大后"长正文 + 译文"仍在行框内：行高不被撑开、也不溢出', (
    WidgetTester tester,
  ) async {
    // 最坏情况：正文与译文都远超一行宽度，而且是"当前行"（字号最大）。
    // 只要"正文 + 译文"的总高度超过行高，布局时就会抛 RenderFlex 溢出，
    // 这条测试会直接红掉 —— 那正是"只改字号不改行高"的典型症状。
    final Lyric lyric = Lyric(
      lines: <LyricLine>[
        for (int i = 0; i < 12; i++)
          LyricLine(start: _startOf(i), text: '第 $i 行很长的歌词' * 12),
      ],
      translatedLines: <LyricLine>[
        for (int i = 0; i < 12; i++)
          LyricLine(start: _startOf(i), text: '第 $i 行很长的译文' * 12),
      ],
    );
    final player = await _player(lyric);
    await tester.pumpWidget(_app(player.container, (Duration _) {}));

    player.setPosition(const Duration(seconds: 55)); // 第 5 行 = 当前行
    await tester.pumpAndSettle();

    final Rect row = tester.getRect(find.byKey(LyricView.rowKey(5)));
    expect(
      row.height,
      moreOrLessEquals(kLyricRowExtent, epsilon: 0.5),
      reason: '行框被内容撑高了 —— 行高已经容不下放大后的文字',
    );
    expect(_centerGap(tester), lessThanOrEqualTo(2.0));

    // 长句仍然是单行省略（放大前就是这个行为），没有退步成多行裁切。
    final Finder texts = find.descendant(
      of: find.byKey(LyricView.rowKey(5)),
      matching: find.byType(Text),
    );
    expect(texts, findsNWidgets(2), reason: '当前行应当是"正文 + 译文"两行');
    for (final Text text in tester.widgetList<Text>(texts)) {
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    }
  });

  testWidgets('首行与末行也能真居中（靠对齐首末行的留白做到）', (WidgetTester tester) async {
    final player = await _player(_lyric());
    await tester.pumpWidget(_app(player.container, (Duration _) {}));

    final ScrollController scroll = tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!;

    // 第 0 行：偏移就是 0，首行正好压在视口中线上。
    player.setPosition(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(_centerGap(tester), lessThanOrEqualTo(2.0), reason: '第 0 行没有居中');

    // 末行（第 11 行）：偏移是 (行数-1) × 行高，正好是可滚动的尽头。
    player.setPosition(const Duration(seconds: 111));
    await tester.pumpAndSettle();
    expect(scroll.offset, moreOrLessEquals(11 * _rowExtent, epsilon: 0.5));
    expect(scroll.offset, moreOrLessEquals(scroll.position.maxScrollExtent, epsilon: 0.5));
    expect(_centerGap(tester), lessThanOrEqualTo(2.0), reason: '末行没有居中');
  });

  testWidgets('当前行变化时滚动；位置刷新但行号不变时不滚', (WidgetTester tester) async {
    final player = await _player(_lyric());
    await tester.pumpWidget(_app(player.container, (Duration _) {}));

    player.setPosition(const Duration(seconds: 25)); // 第 2 行
    await tester.pumpAndSettle();

    final ScrollController scroll = tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!;
    final double expectedLine2 = _expectedOffset(tester, 2);
    expect(scroll.offset, moreOrLessEquals(expectedLine2, epsilon: 0.5));

    // 模拟播放位置的 200ms 心跳：行号没变，滚动位置必须一动不动。
    // 这条防的正是"每次都重滚一下"的抖动。
    final double before = scroll.offset;
    for (int i = 1; i <= 5; i++) {
      player.setPosition(Duration(seconds: 25, milliseconds: 200 * i));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        scroll.offset,
        before,
        reason: '行号没变却滚动了 —— 每 200ms 都在滚',
      );
    }

    // 行号变了：要滚过去，并且再次居中。
    player.setPosition(const Duration(seconds: 55)); // 第 5 行
    await tester.pumpAndSettle();

    final double expectedLine5 = _expectedOffset(tester, 5);
    expect(expectedLine5, greaterThan(expectedLine2));
    expect(scroll.offset, moreOrLessEquals(expectedLine5, epsilon: 0.5));
    expect(_centerGap(tester), lessThanOrEqualTo(2.0));

    // 而且是"滚过去"而不是瞬移：动画中途还没到位。
    player.setPosition(const Duration(seconds: 85)); // 第 8 行
    await tester.pump(); // 触发 post-frame 里的 animateTo
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      scroll.offset,
      lessThan(expectedLine5 + 100),
      reason: '滚动是瞬移的，没有动画',
    );
    await tester.pumpAndSettle();
    expect(_centerGap(tester), lessThanOrEqualTo(2.0));
  });

  testWidgets('点击某一行会 seek 到该行时间', (WidgetTester tester) async {
    final player = await _player(_lyric());
    final List<Duration> seeks = <Duration>[];
    await tester.pumpWidget(_app(player.container, seeks.add));

    player.setPosition(const Duration(seconds: 5)); // 第 0 行
    await tester.pumpAndSettle();

    // 第 3 行的行框中心；点它应当 seek 到 30s。
    final Rect row = tester.getRect(find.byKey(LyricView.rowKey(3)));
    await tester.tapAt(row.center);
    await tester.pump();

    expect(seeks, <Duration>[const Duration(seconds: 30)]);
    expect(player.engine.seeks, <Duration>[const Duration(seconds: 30)]);
    // 乐观更新：位置当场就变了，不用等引擎把位置流回灌。
    expect(
      player.container.read(playerControllerProvider).position,
      const Duration(seconds: 30),
    );
  });

  testWidgets('用户手动滚动后暂停跟随，滚回当前行附近恢复', (WidgetTester tester) async {
    final player = await _player(_lyric());
    final List<Duration> seeks = <Duration>[];
    await tester.pumpWidget(_app(player.container, seeks.add));

    player.setPosition(const Duration(seconds: 55)); // 第 5 行
    await tester.pumpAndSettle();

    final ScrollController scroll = tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!;
    // 5 行 × 行高：数值随行高走，不写死像素（行高放大过，写死就会假绿）。
    expect(scroll.offset, 5 * _rowExtent);

    // 用户往回想看后面的词。先真的拖一下（这是"用户操作"的唯一可靠信号，
    // 程序化的 jumpTo 不算），再用 jumpTo 把落点摆到确定的位置 ——
    // 拖动带惯性，落点会飘，"现在离当前行多远"就没法精确构造了。
    // 拖动距离同样按行高换算（约 4.5 行），行高变了语义才不变。
    await tester.drag(
      find.byType(LyricView),
      const Offset(0, -4.5 * _rowExtent),
    );
    await tester.pumpAndSettle();
    expect(find.text('回到当前'), findsOneWidget, reason: '手动滚动后没有出现提示');

    scroll.jumpTo(7 * _rowExtent); // 比当前行（第 5 行）靠后 2 行
    await tester.pumpAndSettle();
    expect(find.text('回到当前'), findsOneWidget, reason: 'jumpTo 不该把跟随打开');

    // 位置推进到第 6 行：跟随已暂停，滚动位置不许被拽回去。
    player.setPosition(const Duration(seconds: 65));
    await tester.pumpAndSettle();
    expect(
      scroll.offset,
      7 * _rowExtent,
      reason: '用户滚走后仍被自动跟随拽回去了',
    );
    expect(find.text('回到当前'), findsOneWidget);

    // 用户滚回当前行（第 6 行 = 偏移 6 × 行高）附近：恢复跟随。
    scroll.jumpTo(6 * _rowExtent);
    await tester.pumpAndSettle();
    expect(find.text('回到当前'), findsNothing, reason: '已回到当前行附近却没恢复跟随');
    expect(scroll.offset, moreOrLessEquals(6 * _rowExtent, epsilon: 0.5));

    // 恢复之后，位置再推进就应当重新自动滚动并居中。
    player.setPosition(const Duration(seconds: 95)); // 第 9 行
    await tester.pumpAndSettle();
    expect(
      scroll.offset,
      greaterThan(6 * _rowExtent),
      reason: '恢复跟随之后没有重新自动滚动',
    );
    expect(scroll.offset, moreOrLessEquals(9 * _rowExtent, epsilon: 0.5));
    expect(_centerGap(tester), lessThanOrEqualTo(2.0));

    // 滚动与跳转都不该触发 seek。
    expect(seeks, isEmpty);
  });

  testWidgets('拖动同样会暂停跟随（真实手势路径）', (WidgetTester tester) async {
    final player = await _player(_lyric());
    await tester.pumpWidget(_app(player.container, (Duration _) {}));

    player.setPosition(const Duration(seconds: 55)); // 第 5 行
    await tester.pumpAndSettle();

    // 拖得足够远（5 行），无论惯性把它多带一点，落点都远离当前行。
    // 距离按行高换算，行高一旦变化，这条"拖 5 行"的语义不会跟着走样。
    await tester.timedDrag(
      find.byType(LyricView),
      const Offset(0, -5 * _rowExtent),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();

    final ScrollController scroll = tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!;
    final double afterDrag = scroll.offset;
    expect(afterDrag, greaterThan(5 * _rowExtent), reason: '拖动没生效');

    expect(find.text('回到当前'), findsOneWidget);
    player.setPosition(const Duration(seconds: 115)); // 第 11 行
    await tester.pumpAndSettle();
    expect(scroll.offset, afterDrag, reason: '拖动之后仍被自动跟随拽回去了');
  });
}
