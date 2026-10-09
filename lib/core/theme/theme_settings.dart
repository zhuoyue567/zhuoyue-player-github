import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'color_utils.dart';
import 'color_variant.dart';
import 'font_loader.dart';
import 'window_material.dart';

/// 应用深浅色模式。
enum ZhyThemeMode {
  system('跟随系统'),
  light('浅色'),
  dark('深色');

  const ZhyThemeMode(this.label);

  final String label;

  static ZhyThemeMode fromName(String? name) {
    for (final ZhyThemeMode m in values) {
      if (m.name == name) return m;
    }
    return ZhyThemeMode.system;
  }
}

/// 主色（种子色）的来源。
enum ZhySeedSource {
  cover('封面莫奈取色', '跟随当前播放的专辑封面自动换色，切歌即换主题'),
  custom('自定义颜色', '固定使用你选定的颜色，不随封面变化');

  const ZhySeedSource(this.label, this.description);

  final String label;
  final String description;

  static ZhySeedSource fromName(String? name) {
    for (final ZhySeedSource s in values) {
      if (s.name == name) return s;
    }
    return ZhySeedSource.cover;
  }
}

/// 全局字体来源。
enum ZhyFontSource {
  zhuzi('竹石（内置）', '项目内置的 zhuzi.ttf，中文小字最清晰'),
  system('系统默认', '跟随 Windows 的 Segoe UI / 微软雅黑'),
  custom('自定义字体', '导入本机的 .ttf / .otf，应用到全部界面');

  const ZhyFontSource(this.label, this.description);

  final String label;
  final String description;

  static ZhyFontSource fromName(String? name) {
    for (final ZhyFontSource source in values) {
      if (source.name == name) return source;
    }
    return ZhyFontSource.zhuzi;
  }
}

/// 颜色选择器里的内置预设色。
@immutable
class ZhySeedPreset {
  const ZhySeedPreset(this.name, this.argb);

  final String name;
  final int argb;

  Color get color => Color(argb);
}

/// 内置种子色预设。
///
/// 第一项刻意是 Material 3 基线紫：它同时也是「没有封面可参考」时的兜底色，
/// 保证任何情况下界面都是一套成体系的配色，而不是临时拼出来的灰。
const List<ZhySeedPreset> kZhySeedPresets = <ZhySeedPreset>[
  ZhySeedPreset('Material 紫', 0xFF6750A4),
  ZhySeedPreset('云音乐红', 0xFFEC4141),
  ZhySeedPreset('哔哩粉', 0xFFFB7299),
  ZhySeedPreset('海蓝', 0xFF0984E3),
  ZhySeedPreset('青柠', 0xFF00B894),
  ZhySeedPreset('竹青', 0xFF10AC84),
  ZhySeedPreset('琥珀', 0xFFE17055),
  ZhySeedPreset('玫瑰', 0xFFE84393),
  ZhySeedPreset('夜紫', 0xFF6C5CE7),
  ZhySeedPreset('石墨', 0xFF4A4A4A),
];

/// 主题与窗口外观的全部可持久化设置。
///
/// 这里刻意只放「用户配置」，不放「运行时状态」：当前封面推导出来的调色板
/// 属于运行时，单独放在 `coverPaletteProvider` 里。混在一起会导致
/// 「切歌 → 写配置 → 触发一次无意义的磁盘 IO」，也容易把封面色误存成用户自定义色。
@immutable
class ZhyThemeSettings {
  const ZhyThemeSettings({
    this.mode = ZhyThemeMode.system,
    this.seedSource = ZhySeedSource.cover,
    this.customSeedArgb = ZhyColor.fallbackSeedArgb,
    this.variant = ZhyColorVariant.content,
    this.contrast = ZhyContrastLevel.standard,
    this.material = ZhyWindowMaterial.acrylic,
    this.windowOpacity = 0.78,
    this.blurSigma = 36,
    this.panelOpacity = 0.42,
    this.coverBackdrop = true,
    this.animatedBackdrop = true,
    this.fontSource = ZhyFontSource.zhuzi,
    this.customFontPath,
    this.customFontLabel,
    this.gaplessPlayback = true,
    this.crossFade = false,
    this.crossFadeSeconds = 4.0,
  });

  final ZhyThemeMode mode;
  final ZhySeedSource seedSource;
  final int customSeedArgb;
  final ZhyColorVariant variant;
  final ZhyContrastLevel contrast;
  final ZhyWindowMaterial material;

  /// 窗口背景的不透明度（0.30 ~ 1.00）。
  ///
  /// 对系统材质而言它是染色层的 alpha：越小越"透"，越大越接近实色；
  /// 对模拟磨砂而言它是自绘背景层的整体不透明度。
  final double windowOpacity;

  /// 磨砂模糊半径（0 ~ 80）。
  final double blurSigma;

  /// 玻璃面板自身的染色强度（0.00 ~ 0.90）。
  ///
  /// 调低更通透但文字可读性下降，调高更清晰但会盖住系统毛玻璃。
  final double panelOpacity;

  /// 「模拟磨砂」模式下是否用封面图做底色（否则用主题色的渐变）。
  final bool coverBackdrop;

  /// 封面切换 / 切歌时是否让背景做交叉淡入，而不是瞬间跳变。
  final bool animatedBackdrop;

  /// 全局字体来源。
  final ZhyFontSource fontSource;

  /// 自定义字体文件的绝对路径（[ZhyFontSource.custom] 时有效）。
  final String? customFontPath;

  /// 自定义字体在界面上显示的名字（一般就是文件名）。
  final String? customFontLabel;

  /// 无缝衔接：**预解析**下一首的播放地址。
  ///
  /// 说明清楚它是什么：真正的"采样级无缝"要由播放后端把两段音频连续送给
  /// 声卡，`just_audio_windows`（Media Foundation）不提供这个能力。
  /// 这里做的是**消除可听见的空档** —— 切歌时最大的延迟其实来自
  /// "调接口解析地址"（几百毫秒到一秒），提前解析好之后，
  /// 切歌只剩一次本地换流，听感上就是连着的。
  final bool gaplessPlayback;

  /// 淡入淡出：切歌时做音量渐变，避免突然起音/掐断。
  final bool crossFade;

  /// 淡入淡出的单边时长（秒）。
  final double crossFadeSeconds;

  /// 需要交给 `ThemeData.fontFamily` 的 family。
  ///
  /// 返回 null 表示"不指定"，也就是走 Flutter 的默认字体链
  /// （系统默认那一档）。自定义字体只在**确实注册成功**之后才生效，
  /// 否则会得到一个找不到字体的空白观感。
  String? get effectiveFontFamily {
    switch (fontSource) {
      case ZhyFontSource.zhuzi:
        return ZhyFontLoader.bundledFamily;
      case ZhyFontSource.system:
        return null;
      case ZhyFontSource.custom:
        return ZhyFontLoader.customLoaded ? ZhyFontLoader.customFamily : null;
    }
  }

  /// 当前真正生效的种子色：跟随封面还是用自定义色。
  ///
  /// [coverSeedArgb] 为 null 表示"还没有解析出封面色"（例如刚启动、歌单为空、
  /// 封面下载失败），此时回落到兜底种子色，而不是让界面变成灰色。
  int effectiveSeedArgb(int? coverSeedArgb) {
    if (seedSource == ZhySeedSource.custom) return customSeedArgb;
    return coverSeedArgb ?? ZhyColor.fallbackSeedArgb;
  }

  ZhyThemeSettings copyWith({
    ZhyThemeMode? mode,
    ZhySeedSource? seedSource,
    int? customSeedArgb,
    ZhyColorVariant? variant,
    ZhyContrastLevel? contrast,
    ZhyWindowMaterial? material,
    double? windowOpacity,
    double? blurSigma,
    double? panelOpacity,
    bool? coverBackdrop,
    bool? animatedBackdrop,
    ZhyFontSource? fontSource,
    String? customFontPath,
    String? customFontLabel,
    bool? gaplessPlayback,
    bool? crossFade,
    double? crossFadeSeconds,
  }) {
    return ZhyThemeSettings(
      mode: mode ?? this.mode,
      seedSource: seedSource ?? this.seedSource,
      customSeedArgb: customSeedArgb ?? this.customSeedArgb,
      variant: variant ?? this.variant,
      contrast: contrast ?? this.contrast,
      material: material ?? this.material,
      windowOpacity: windowOpacity ?? this.windowOpacity,
      blurSigma: blurSigma ?? this.blurSigma,
      panelOpacity: panelOpacity ?? this.panelOpacity,
      coverBackdrop: coverBackdrop ?? this.coverBackdrop,
      animatedBackdrop: animatedBackdrop ?? this.animatedBackdrop,
      fontSource: fontSource ?? this.fontSource,
      customFontPath: customFontPath ?? this.customFontPath,
      customFontLabel: customFontLabel ?? this.customFontLabel,
      gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
      crossFade: crossFade ?? this.crossFade,
      crossFadeSeconds: crossFadeSeconds ?? this.crossFadeSeconds,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ZhyThemeSettings &&
        other.mode == mode &&
        other.seedSource == seedSource &&
        other.customSeedArgb == customSeedArgb &&
        other.variant == variant &&
        other.contrast == contrast &&
        other.material == material &&
        other.windowOpacity == windowOpacity &&
        other.blurSigma == blurSigma &&
        other.panelOpacity == panelOpacity &&
        other.coverBackdrop == coverBackdrop &&
        other.animatedBackdrop == animatedBackdrop &&
        other.fontSource == fontSource &&
        other.customFontPath == customFontPath &&
        other.customFontLabel == customFontLabel &&
        other.gaplessPlayback == gaplessPlayback &&
        other.crossFade == crossFade &&
        other.crossFadeSeconds == crossFadeSeconds;
  }

  @override
  int get hashCode => Object.hash(
    mode,
    seedSource,
    customSeedArgb,
    variant,
    contrast,
    material,
    windowOpacity,
    blurSigma,
    panelOpacity,
    coverBackdrop,
    animatedBackdrop,
    fontSource,
    customFontPath,
    customFontLabel,
    gaplessPlayback,
    crossFade,
    crossFadeSeconds,
  );
}

/// 主题设置的读写。
///
/// 把持久化细节挡在 provider 之外：设置项加一个字段只需要改这里和
/// [ZhyThemeSettings]，UI 层完全不用知道存在 SharedPreferences。
class ZhyThemeSettingsStore {
  const ZhyThemeSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _kMode = 'theme.mode';
  static const String _kSeedSource = 'theme.seedSource';
  static const String _kCustomSeed = 'theme.customSeedArgb';
  static const String _kVariant = 'theme.variant';
  static const String _kContrast = 'theme.contrast';
  static const String _kMaterial = 'theme.material';
  static const String _kWindowOpacity = 'theme.windowOpacity';
  static const String _kBlurSigma = 'theme.blurSigma';
  static const String _kPanelOpacity = 'theme.panelOpacity';
  static const String _kCoverBackdrop = 'theme.coverBackdrop';
  static const String _kAnimatedBackdrop = 'theme.animatedBackdrop';
  static const String _kFontSource = 'theme.fontSource';
  static const String _kCustomFontLabel = 'theme.customFontLabel';
  static const String _kGapless = 'player.gapless';
  static const String _kCrossFade = 'player.crossFade';
  static const String _kCrossFadeSeconds = 'player.crossFadeSeconds';

  ZhyThemeSettings load() {
    const ZhyThemeSettings defaults = ZhyThemeSettings();
    return ZhyThemeSettings(
      mode: ZhyThemeMode.fromName(_prefs.getString(_kMode)),
      seedSource: ZhySeedSource.fromName(_prefs.getString(_kSeedSource)),
      customSeedArgb: _prefs.getInt(_kCustomSeed) ?? defaults.customSeedArgb,
      variant: ZhyColorVariant.fromName(_prefs.getString(_kVariant)),
      contrast: ZhyContrastLevel.fromValue(
        _prefs.getDouble(_kContrast) ?? defaults.contrast.value,
      ),
      material: ZhyWindowMaterial.fromName(_prefs.getString(_kMaterial)),
      windowOpacity:
          _prefs.getDouble(_kWindowOpacity) ?? defaults.windowOpacity,
      blurSigma: _prefs.getDouble(_kBlurSigma) ?? defaults.blurSigma,
      panelOpacity: _prefs.getDouble(_kPanelOpacity) ?? defaults.panelOpacity,
      coverBackdrop: _prefs.getBool(_kCoverBackdrop) ?? defaults.coverBackdrop,
      animatedBackdrop:
          _prefs.getBool(_kAnimatedBackdrop) ?? defaults.animatedBackdrop,
      fontSource: ZhyFontSource.fromName(_prefs.getString(_kFontSource)),
      // 键定义在 ZhyFontLoader 上：启动时恢复字体也是读这个键，
      // 两处共用同一个常量，避免字符串写岔导致"设了但重启就没了"。
      customFontPath: _prefs.getString(ZhyFontLoader.customFontPathKey),
      customFontLabel: _prefs.getString(_kCustomFontLabel),
      gaplessPlayback: _prefs.getBool(_kGapless) ?? defaults.gaplessPlayback,
      crossFade: _prefs.getBool(_kCrossFade) ?? defaults.crossFade,
      crossFadeSeconds:
          _prefs.getDouble(_kCrossFadeSeconds) ?? defaults.crossFadeSeconds,
    );
  }

  Future<void> save(ZhyThemeSettings s) async {
    await Future.wait(<Future<bool>>[
      _prefs.setString(_kMode, s.mode.name),
      _prefs.setString(_kSeedSource, s.seedSource.name),
      _prefs.setInt(_kCustomSeed, s.customSeedArgb),
      _prefs.setString(_kVariant, s.variant.name),
      _prefs.setDouble(_kContrast, s.contrast.value),
      _prefs.setString(_kMaterial, s.material.name),
      _prefs.setDouble(_kWindowOpacity, s.windowOpacity),
      _prefs.setDouble(_kBlurSigma, s.blurSigma),
      _prefs.setDouble(_kPanelOpacity, s.panelOpacity),
      _prefs.setBool(_kCoverBackdrop, s.coverBackdrop),
      _prefs.setBool(_kAnimatedBackdrop, s.animatedBackdrop),
      _prefs.setString(_kFontSource, s.fontSource.name),
      if (s.customFontPath != null)
        _prefs.setString(ZhyFontLoader.customFontPathKey, s.customFontPath!)
      else
        _prefs.remove(ZhyFontLoader.customFontPathKey),
      if (s.customFontLabel != null)
        _prefs.setString(_kCustomFontLabel, s.customFontLabel!)
      else
        _prefs.remove(_kCustomFontLabel),
      _prefs.setBool(_kGapless, s.gaplessPlayback),
      _prefs.setBool(_kCrossFade, s.crossFade),
      _prefs.setDouble(_kCrossFadeSeconds, s.crossFadeSeconds),
    ]);
  }

  Future<void> reset() async {
    for (final String key in const <String>[
      _kMode,
      _kSeedSource,
      _kCustomSeed,
      _kVariant,
      _kContrast,
      _kMaterial,
      _kWindowOpacity,
      _kBlurSigma,
      _kPanelOpacity,
      _kCoverBackdrop,
      _kAnimatedBackdrop,
      _kFontSource,
      _kCustomFontLabel,
      ZhyFontLoader.customFontPathKey,
      _kGapless,
      _kCrossFade,
      _kCrossFadeSeconds,
    ]) {
      await _prefs.remove(key);
    }
  }
}
