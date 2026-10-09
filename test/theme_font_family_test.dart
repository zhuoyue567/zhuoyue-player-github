import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';

/// 「全局字体」到底有没有作用到**组件级**文字样式上。
///
/// 这是一个真实踩过的坑：`ThemeData(fontFamily: …)` 只派生 `textTheme`
/// 那一套，而 `ButtonStyle.textStyle` / `AppBarTheme.titleTextStyle` /
/// `ListTileTheme.titleTextStyle` / `ChipTheme.labelStyle` 这些**组件级样式
/// 是"整体取代"对应那一档，不是与之合并**。所以只要这些地方写的是
/// `TextStyle(fontSize: …, fontWeight: …)` 而没有 `fontFamily`，那段文字就会
/// **掉回系统默认字体** —— 界面上正文是内置竹石、按钮却是系统黑体，
/// 字形与笔画粗细都对不上，用户看到的就是"部分字体的字重不对"。
///
/// 下面第一条把"主题里每一处显式样式都带字体族"钉死；第二条更直接：
/// 真的把按钮画出来，从渲染树里读回**解析后**的样式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ThemeData themeFor(ZhyFontSource source) {
    const ZhyWindowMaterial material = ZhyWindowMaterial.solid;
    final ZhyThemeSettings settings = ZhyThemeSettings(
      material: material,
      fontSource: source,
    );
    return buildZhyTheme(
      scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      tokens: buildZhyTokens(settings, Brightness.light),
      material: material,
      fontFamily: settings.effectiveFontFamily,
    );
  }

  test('选了内置字体时，主题里每一处组件级文字样式都要带上该字体族', () {
    final ThemeData theme = themeFor(ZhyFontSource.zhuzi);
    const String family = 'Zhuzi';

    final Map<String, TextStyle?> styles = <String, TextStyle?>{
      'appBarTheme.titleTextStyle': theme.appBarTheme.titleTextStyle,
      'dialogTheme.titleTextStyle': theme.dialogTheme.titleTextStyle,
      'dialogTheme.contentTextStyle': theme.dialogTheme.contentTextStyle,
      'inputDecorationTheme.hintStyle': theme.inputDecorationTheme.hintStyle,
      'listTileTheme.titleTextStyle': theme.listTileTheme.titleTextStyle,
      'listTileTheme.subtitleTextStyle':
          theme.listTileTheme.subtitleTextStyle,
      'chipTheme.labelStyle': theme.chipTheme.labelStyle,
      'popupMenuTheme.textStyle': theme.popupMenuTheme.textStyle,
      'tooltipTheme.textStyle': theme.tooltipTheme.textStyle,
      'snackBarTheme.contentTextStyle': theme.snackBarTheme.contentTextStyle,
      'filledButtonTheme.textStyle': theme
          .filledButtonTheme
          .style
          ?.textStyle
          ?.resolve(<WidgetState>{}),
      'textButtonTheme.textStyle': theme.textButtonTheme.style?.textStyle
          ?.resolve(<WidgetState>{}),
      'outlinedButtonTheme.textStyle': theme
          .outlinedButtonTheme
          .style
          ?.textStyle
          ?.resolve(<WidgetState>{}),
      'segmentedButtonTheme.textStyle': theme
          .segmentedButtonTheme
          .style
          ?.textStyle
          ?.resolve(<WidgetState>{}),
    };

    for (final MapEntry<String, TextStyle?> entry in styles.entries) {
      expect(
        entry.value,
        isNotNull,
        reason: '${entry.key} 读不到样式 —— 这条断言会空转，先确认字段名',
      );
      expect(
        entry.value!.fontFamily,
        family,
        reason:
            '${entry.key} 没带字体族：它会掉回系统默认字体，'
            '与正文（$family）不是同一个字体，看起来就是"字重/字形不一样"',
      );
    }
  });

  test('选「系统默认」时不要硬写字体族（我们的样式应当为 null）', () {
    final ThemeData theme = themeFor(ZhyFontSource.system);
    // null 的含义是"不指定，走 Flutter 默认字体链"。
    //
    // 注意**不要**去断言 `textTheme.bodyMedium.fontFamily` 为 null：
    // 那一档来自 Material 自带的 typography，名字固定是 'Roboto'，
    // 与我们设不设字体无关（我第一版就是这么写错的）。
    // 我们要钉的是"自己写的那几处"没有硬编码字体族。
    expect(
      theme.outlinedButtonTheme.style?.textStyle?.resolve(<WidgetState>{})
          ?.fontFamily,
      isNull,
      reason: '选系统默认时不该给按钮塞字体族',
    );
    expect(
      theme.appBarTheme.titleTextStyle?.fontFamily,
      isNull,
    );
    expect(theme.textTheme.bodyMedium?.fontFamily, isNot('Zhuzi'));
  });

  testWidgets('按钮文字真的用上了全局字体（读回渲染树里解析后的样式）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(ZhyFontSource.zhuzi),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('播放全部'),
              ),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.playlist_add_rounded, size: 18),
                label: const Text('添加到队列'),
              ),
              TextButton(onPressed: () {}, child: const Text('纯文本按钮')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final String label in <String>['播放全部', '添加到队列', '纯文本按钮']) {
      final RichText rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((RichText r) => r.text.toPlainText() == label);
      expect(
        rich.text.style?.fontFamily,
        'Zhuzi',
        reason: '「$label」实际渲染用的不是全局字体 —— 这正是用户看到的那处不一致',
      );
      // 顺带把字重也钉住：内置字体只有 w400 一个字面，
      // 请求 w600/w700 会被引擎描边合成（见 typography_weight_test.dart）。
      expect(rich.text.style?.fontWeight, FontWeight.w500);
    }
  });
}
