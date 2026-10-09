import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/features/player/playback_extras.dart';

/// 用户应当看到的十个频段标签。
///
/// 刻意在这里重抄一遍而不是引用生产代码里的私有 `_kBandLabels`：
/// 测试钉的是"用户看到的十个频段"，谁把频段改少一个，这里就该红。
const List<String> _kExpectedBands = <String>[
  '31Hz',
  '62Hz',
  '125Hz',
  '250Hz',
  '500Hz',
  '1kHz',
  '2kHz',
  '4kHz',
  '8kHz',
  '16kHz',
];

Widget _host() {
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
      body: Builder(
        builder: (BuildContext context) => Center(
          child: TextButton(
            onPressed: () => showEqualizerDialog(context),
            child: const Text('打开均衡器'),
          ),
        ),
      ),
    ),
  );
}

/// 打开均衡器面板，并把测试窗口固定成给定逻辑尺寸。
///
/// 尺寸必须在 `pumpWidget` **之前**写好：AlertDialog 的可用宽度来自屏幕宽度，
/// pump 完再改就得重排，量到的也就不是这一轮布局了。
Future<void> _openEqualizer(
  WidgetTester tester, {
  Size size = const Size(1000, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_host());
  await tester.tap(find.text('打开均衡器'));
  await tester.pumpAndSettle();
}

/// 十个推子（Slider）在屏幕上的矩形，从左到右。
List<Rect> _faderRects(WidgetTester tester) {
  return <Rect>[
    for (int i = 0; i < _kExpectedBands.length; i++)
      tester.getRect(find.byType(Slider).at(i)),
  ];
}

/// 当前高亮的预设名。
String _selectedPresetName(WidgetTester tester) {
  final ChoiceChip chip = tester
      .widgetList<ChoiceChip>(find.byType(ChoiceChip))
      .firstWhere((ChoiceChip chip) => chip.selected);
  return (chip.label as Text).data!;
}

void main() {
  test('每个预设的增益数量都与十个频段对得上', () {
    // 面板永远渲染十列；预设少一个增益时生产代码会按 0 dB 补齐（不崩），
    // 但那是兜底，不是正常状态 —— 这条断言让"加了频段忘了补预设"立刻暴露。
    for (final EqualizerPreset preset in kEqualizerPresets) {
      expect(
        preset.gains.length,
        _kExpectedBands.length,
        reason: '预设「${preset.name}」的增益数量与频段数量不一致',
      );
    }
    // 「复位」按钮依赖这两条：预设表的第一项必须是"全平的原声"。
    expect(kEqualizerPresets.first.name, '原声');
    expect(
      kEqualizerPresets.first.gains.every((double gain) => gain == 0),
      isTrue,
      reason: '「原声」必须是一条全平曲线',
    );
  });

  testWidgets('打开后能看到十个频段标签与十个推子', (WidgetTester tester) async {
    await _openEqualizer(tester);

    for (final String band in _kExpectedBands) {
      expect(find.text(band), findsOneWidget, reason: '看不到频段标签 $band');
    }
    expect(find.byType(Slider), findsNWidgets(_kExpectedBands.length));

    // 改布局最容易顺手删掉的就是这条诚实提示：它必须一直在。
    expect(find.text('当前后端不生效'), findsOneWidget);
    expect(find.textContaining('不会改变声音'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('推子是竖向的，而且十列等宽、行程一致', (WidgetTester tester) async {
    await _openEqualizer(tester);

    final List<Rect> rects = _faderRects(tester);

    // "改成竖向"最直接的验收：每个 Slider 的可视区域高 > 宽。
    for (int i = 0; i < rects.length; i++) {
      expect(
        rects[i].height,
        greaterThan(rects[i].width),
        reason: '第 ${i + 1} 个推子不是竖的：${rects[i]}',
      );
    }

    // 十列等宽 = 相邻两列的中心间距处处相同（容差 1 逻辑像素）。
    final List<double> centers = rects
        .map((Rect rect) => rect.center.dx)
        .toList(growable: false);
    final double firstGap = centers[1] - centers[0];
    for (int i = 1; i < centers.length - 1; i++) {
      expect(
        centers[i + 1] - centers[i],
        closeTo(firstGap, 1.0),
        reason: '第 ${i + 1} 列与第 ${i + 2} 列的间距和前面不一致',
      );
    }

    // 行程一致**且上下沿对齐**，才是"0 dB 在同一条水平线上"：
    // 只比高度的话，两列等高但整体错开也会通过，而那样刻度是歪的。
    for (int i = 0; i < rects.length; i++) {
      expect(rects[i].height, closeTo(rects.first.height, 0.01));
      expect(
        rects[i].top,
        closeTo(rects.first.top, 0.01),
        reason: '第 ${i + 1} 个推子的顶边与其他列没对齐',
      );
      expect(
        rects[i].bottom,
        closeTo(rects.first.bottom, 0.01),
        reason: '第 ${i + 1} 个推子的底边与其他列没对齐',
      );
    }

    // 竖直方向上也必须真的在面板内（顶部数值行、底部频率标签都在）。
    expect(find.text('频段增益（dB）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动推子会更新该频段的 dB 文本', (WidgetTester tester) async {
    await _openEqualizer(tester);

    // 默认「原声」，十个频段都是 +0.0。
    expect(find.text('+0.0'), findsNWidgets(_kExpectedBands.length));

    // 向上拖 = 增益：把第一个推子一直推到顶。
    await tester.drag(find.byType(Slider).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('+12.0'), findsOneWidget, reason: '向上推到底应当是 +12.0');
    expect(find.text('+0.0'), findsNWidgets(_kExpectedBands.length - 1));

    // 反方向验证一次：往下拖到底应当是 -12.0（符号、单位都对）。
    await tester.drag(find.byType(Slider).first, const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(find.text('-12.0'), findsOneWidget, reason: '向下推到底应当是 -12.0');

    expect(tester.takeException(), isNull);
  });

  testWidgets('「复位」把增益归零并回到「原声」预设', (WidgetTester tester) async {
    await _openEqualizer(tester);

    // 先选一个非零预设，确认它确实改动了曲线。
    await tester.tap(find.text('摇滚'));
    await tester.pumpAndSettle();
    expect(_selectedPresetName(tester), '摇滚');
    expect(
      find.text('+0.0'),
      findsNothing,
      reason: '「摇滚」不该出现 0 dB 档位',
    );

    // 再手动推一个推子，模拟"用户自己调过"。
    await tester.drag(find.byType(Slider).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('+12.0'), findsOneWidget);

    await tester.tap(find.text('复位'));
    await tester.pumpAndSettle();

    expect(find.text('+0.0'), findsNWidgets(_kExpectedBands.length));
    expect(find.text('+12.0'), findsNothing);
    expect(_selectedPresetName(tester), '原声');

    expect(tester.takeException(), isNull);
  });

  testWidgets('默认窗口下十个频率标签都在可视区内（不用滚动）', (WidgetTester tester) async {
    // 竖推子把面板撑高了：一高就容易把最下面的频率标签顶出可视区，
    // 而标签是推子面板最不能少的东西。这里用默认窗口（1240x800）钉住。
    await _openEqualizer(tester, size: const Size(1240, 800));

    final double actionsTop = tester.getRect(find.text('复位')).top;
    for (final String band in _kExpectedBands) {
      expect(
        tester.getRect(find.text(band)).bottom,
        lessThan(actionsTop),
        reason: '$band 的频率标签被顶到操作按钮下面了',
      );
    }
    for (final Rect rect in _faderRects(tester)) {
      expect(rect.bottom, lessThan(actionsTop), reason: '推子行程被顶出了可视区');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口（480 宽）下不出现溢出条纹', (WidgetTester tester) async {
    await _openEqualizer(tester, size: const Size(480, 900));

    // 溢出条纹在测试里就是一条被记录下来的 FlutterError：
    // 一条都拿不到，才算真的没有溢出。
    expect(tester.takeException(), isNull);

    expect(find.byType(Slider), findsNWidgets(_kExpectedBands.length));

    // 溢出会表现为"最后一列被推出窗口"，所以直接拿窗口边界卡住十个推子。
    final Size window =
        tester.view.physicalSize / tester.view.devicePixelRatio;
    final List<Rect> rects = _faderRects(tester);
    final double firstGap = rects[1].center.dx - rects[0].center.dx;
    for (int i = 0; i < rects.length; i++) {
      expect(
        rects[i].height,
        greaterThan(rects[i].width),
        reason: '窄窗口下第 ${i + 1} 个推子不是竖的：${rects[i]}',
      );
      expect(rects[i].left, greaterThanOrEqualTo(0));
      expect(
        rects[i].right,
        lessThanOrEqualTo(window.width),
        reason: '窄窗口下第 ${i + 1} 个推子被挤出了窗口',
      );
      if (i > 0) {
        // 被挤窄之后十列仍然等宽。
        expect(
          rects[i].center.dx - rects[i - 1].center.dx,
          closeTo(firstGap, 1.0),
        );
      }
    }

    // 十个频段标签一个都不能少。
    for (final String band in _kExpectedBands) {
      expect(find.text(band), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
