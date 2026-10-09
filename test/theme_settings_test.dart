import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/color_variant.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/theme_tokens.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';

/// 主题与播放设置的持久化往返。
///
/// 单独测这一层是因为它最容易"看起来没问题但实际没存住"：
/// 新增一个字段时忘了在 `save` / `load` / `reset` 三处都补上，
/// 表现是"设置改完当时生效，重启又回默认" —— 这种 bug 只有真的读写一遍才发现。
void main() {
  late ZhyThemeSettingsStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = ZhyThemeSettingsStore(await SharedPreferences.getInstance());
  });

  test('全部字段都能存住并读回', () async {
    const ZhyThemeSettings settings = ZhyThemeSettings(
      mode: ZhyThemeMode.dark,
      seedSource: ZhySeedSource.custom,
      customSeedArgb: 0xFF123456,
      variant: ZhyColorVariant.vibrant,
      contrast: ZhyContrastLevel.high,
      material: ZhyWindowMaterial.micaAlt,
      windowOpacity: 0.55,
      blurSigma: 12,
      panelOpacity: 0.33,
      coverBackdrop: false,
      animatedBackdrop: false,
      fontSource: ZhyFontSource.custom,
      customFontPath: r'C:\Fonts\my.ttf',
      customFontLabel: 'my.ttf',
      gaplessPlayback: false,
      crossFade: true,
      crossFadeSeconds: 7.5,
    );

    await store.save(settings);
    final ZhyThemeSettings loaded = store.load();

    expect(loaded, settings, reason: '往返后应当完全相等');
  });

  test('播放设置默认为「无缝衔接开、淡入淡出关」', () async {
    final ZhyThemeSettings defaults = store.load();
    expect(defaults.gaplessPlayback, isTrue);
    expect(defaults.crossFade, isFalse);
    expect(defaults.crossFadeSeconds, 4.0);
  });

  test('reset 之后回到默认值', () async {
    await store.save(
      const ZhyThemeSettings(
        mode: ZhyThemeMode.dark,
        material: ZhyWindowMaterial.solid,
        gaplessPlayback: false,
        crossFade: true,
      ),
    );
    await store.reset();
    expect(store.load(), const ZhyThemeSettings());
  });

  test('字体选择决定 ThemeData 的 fontFamily', () {
    // 内置竹石 → 用 Zhuzi；系统默认 → 不指定。
    expect(
      const ZhyThemeSettings(fontSource: ZhyFontSource.zhuzi)
          .effectiveFontFamily,
      'Zhuzi',
    );
    expect(
      const ZhyThemeSettings(fontSource: ZhyFontSource.system)
          .effectiveFontFamily,
      isNull,
    );
  });

  test('窗口材质与配色变体的名字能跨版本还原', () {
    expect(ZhyWindowMaterial.fromName('micaAlt'), ZhyWindowMaterial.micaAlt);
    expect(ZhyColorVariant.fromName('expressive'), ZhyColorVariant.expressive);
    // 未知名字回落到默认值而不是抛异常（改名/降级时不能让应用起不来）。
    expect(ZhyWindowMaterial.fromName('nope'), ZhyWindowMaterial.acrylic);
    expect(ZhyColorVariant.fromName('nope'), ZhyColorVariant.content);
  });

  test('buildZhyTheme 会把 fontFamily 与令牌一起装进 ThemeData', () {
    const ZhyThemeSettings settings = ZhyThemeSettings(
      material: ZhyWindowMaterial.solid,
    );
    final ThemeData theme = buildZhyTheme(
      scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      tokens: buildZhyTokens(settings, Brightness.light),
      material: settings.material,
      fontFamily: settings.effectiveFontFamily,
    );

    expect(theme.textTheme.bodyMedium?.fontFamily, 'Zhuzi');
    expect(theme.extension<ZhyTokens>(), isNotNull);
    // 实色材质下 Scaffold 必须是不透明的。
    expect(theme.scaffoldBackgroundColor, isNot(Colors.transparent));
  });
}
