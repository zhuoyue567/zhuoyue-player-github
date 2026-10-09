import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/preferences.dart';
import 'app_theme.dart';
import 'color_variant.dart';
import 'font_loader.dart';
import 'monet.dart';
import 'theme_settings.dart';
import 'window_material.dart';

/// 主题设置的持久化读写。
final Provider<ZhyThemeSettingsStore> themeSettingsStoreProvider =
    Provider<ZhyThemeSettingsStore>(
      (Ref ref) => ZhyThemeSettingsStore(ref.watch(sharedPreferencesProvider)),
    );

/// 用户主题设置。
///
/// [build] 里同步读盘：`sharedPreferencesProvider` 已经在 `main()` 里
/// 同步初始化过了，所以这里不需要 `AsyncNotifier`，也就不会有
/// "首帧用默认配色、第二帧才跳到用户配色"的闪烁。
class ThemeSettingsNotifier extends Notifier<ZhyThemeSettings> {
  @override
  ZhyThemeSettings build() => ref.watch(themeSettingsStoreProvider).load();

  void _commit(ZhyThemeSettings next) {
    if (next == state) return;
    state = next;
    // 写盘失败不该打断交互（顶多是下次启动回到旧设置），所以吞掉异常只记日志。
    unawaited(
      ref.read(themeSettingsStoreProvider).save(next).catchError((
        Object error,
      ) {
        debugPrint('[theme] 保存主题设置失败: $error');
      }),
    );
  }

  void setMode(ZhyThemeMode value) => _commit(state.copyWith(mode: value));

  void setSeedSource(ZhySeedSource value) =>
      _commit(state.copyWith(seedSource: value));

  void setCustomSeed(int argb) => _commit(
    state.copyWith(
      customSeedArgb: argb,
      // 选颜色这个动作本身就表达了"我要用自定义色"，
      // 顺手切过去比让用户再点一次开关更符合预期。
      seedSource: ZhySeedSource.custom,
    ),
  );

  void setVariant(ZhyColorVariant value) =>
      _commit(state.copyWith(variant: value));

  void setContrast(ZhyContrastLevel value) =>
      _commit(state.copyWith(contrast: value));

  void setMaterial(ZhyWindowMaterial value) =>
      _commit(state.copyWith(material: value));

  void setWindowOpacity(double value) =>
      _commit(state.copyWith(windowOpacity: value.clamp(0.30, 1.0)));

  void setBlurSigma(double value) =>
      _commit(state.copyWith(blurSigma: value.clamp(0.0, 80.0)));

  void setPanelOpacity(double value) =>
      _commit(state.copyWith(panelOpacity: value.clamp(0.0, 0.9)));

  void setCoverBackdrop(bool value) =>
      _commit(state.copyWith(coverBackdrop: value));

  void setAnimatedBackdrop(bool value) =>
      _commit(state.copyWith(animatedBackdrop: value));

  void setGaplessPlayback(bool value) =>
      _commit(state.copyWith(gaplessPlayback: value));

  void setCrossFade(bool value) => _commit(state.copyWith(crossFade: value));

  void setCrossFadeSeconds(double value) =>
      _commit(state.copyWith(crossFadeSeconds: value.clamp(1.0, 12.0)));

  void setFontSource(ZhyFontSource value) =>
      _commit(state.copyWith(fontSource: value));

  /// 导入一个自定义字体并立即生效。
  ///
  /// 只有**注册成功**才把设置切到自定义档：加载失败时保持原档位，
  /// 界面不会因为一个坏字体变成找不到字形的样子。
  /// 返回失败原因，供界面提示用户。
  Future<String?> importCustomFont(String path, String label) async {
    final bool ok = await ZhyFontLoader.loadCustomFont(path);
    if (!ok) return '字体加载失败，请确认是有效的 .ttf / .otf 文件';
    _commit(
      state.copyWith(
        fontSource: ZhyFontSource.custom,
        customFontPath: path,
        customFontLabel: label,
      ),
    );
    return null;
  }

  Future<void> resetToDefaults() async {
    await ref.read(themeSettingsStoreProvider).reset();
    state = const ZhyThemeSettings();
  }
}

final NotifierProvider<ThemeSettingsNotifier, ZhyThemeSettings>
themeSettingsProvider =
    NotifierProvider<ThemeSettingsNotifier, ZhyThemeSettings>(
      ThemeSettingsNotifier.new,
    );

/// 当前封面推导出的莫奈调色板。
///
/// 与 [themeSettingsProvider] 刻意分开：调色板是**运行时状态**，
/// 每次切歌都会变。如果把它混进设置里，会出现"切歌 → 触发一次写盘"，
/// 更糟的是有可能把封面推出来的颜色当成用户的自定义色存下来。
class CoverPaletteNotifier extends Notifier<MonetPalette?> {
  static const MonetExtractor _extractor = MonetExtractor();

  @override
  MonetPalette? build() => null;

  /// 用封面字节更新调色板。传 null / 空数组表示清空（回到兜底色）。
  Future<void> updateFromBytes(Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) {
      if (state != null) state = null;
      return;
    }
    try {
      final MonetPalette? palette = await _extractor.extractFromEncoded(bytes);
      // 取色失败（图片损坏、像素太少）时保留上一个调色板，
      // 而不是把界面闪回默认紫 —— 视觉上更稳。
      if (palette != null) state = palette;
    } on Object catch (error) {
      debugPrint('[theme] 封面取色失败: $error');
    }
  }

  void clear() {
    if (state != null) state = null;
  }
}

final NotifierProvider<CoverPaletteNotifier, MonetPalette?>
coverPaletteProvider = NotifierProvider<CoverPaletteNotifier, MonetPalette?>(
  CoverPaletteNotifier.new,
);

/// 当前真正生效的种子色（ARGB）。
final Provider<int> activeSeedArgbProvider = Provider<int>((Ref ref) {
  final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
  final int? coverSeed = ref.watch(coverPaletteProvider)?.seedArgb;
  return settings.effectiveSeedArgb(coverSeed);
});

ColorScheme _buildScheme(
  int seedArgb,
  Brightness brightness,
  ZhyThemeSettings settings,
) {
  return ColorScheme.fromSeed(
    seedColor: Color(seedArgb),
    brightness: brightness,
    dynamicSchemeVariant: settings.variant.scheme,
    contrastLevel: settings.contrast.value,
  );
}

final Provider<ColorScheme> lightColorSchemeProvider = Provider<ColorScheme>(
  (Ref ref) => _buildScheme(
    ref.watch(activeSeedArgbProvider),
    Brightness.light,
    ref.watch(themeSettingsProvider),
  ),
);

final Provider<ColorScheme> darkColorSchemeProvider = Provider<ColorScheme>(
  (Ref ref) => _buildScheme(
    ref.watch(activeSeedArgbProvider),
    Brightness.dark,
    ref.watch(themeSettingsProvider),
  ),
);

final Provider<ThemeData> lightThemeProvider = Provider<ThemeData>((Ref ref) {
  final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
  return buildZhyTheme(
    scheme: ref.watch(lightColorSchemeProvider),
    tokens: buildZhyTokens(settings, Brightness.light),
    material: settings.material,
    fontFamily: settings.effectiveFontFamily,
  );
});

final Provider<ThemeData> darkThemeProvider = Provider<ThemeData>((Ref ref) {
  final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
  return buildZhyTheme(
    scheme: ref.watch(darkColorSchemeProvider),
    tokens: buildZhyTokens(settings, Brightness.dark),
    material: settings.material,
    fontFamily: settings.effectiveFontFamily,
  );
});

final Provider<ThemeMode> themeModeProvider = Provider<ThemeMode>((Ref ref) {
  return switch (ref.watch(themeSettingsProvider).mode) {
    ZhyThemeMode.light => ThemeMode.light,
    ZhyThemeMode.dark => ThemeMode.dark,
    ZhyThemeMode.system => ThemeMode.system,
  };
});

/// 当前窗口材质设置。
final Provider<ZhyWindowMaterial> windowMaterialProvider =
    Provider<ZhyWindowMaterial>(
      (Ref ref) => ref.watch(themeSettingsProvider).material,
    );

/// 当前窗口不透明度设置。
final Provider<double> windowOpacityProvider = Provider<double>(
  (Ref ref) => ref.watch(themeSettingsProvider).windowOpacity,
);
