import 'package:flutter/material.dart';

/// Material You 动态配色方案的「变体」。
///
/// 这是 [DynamicSchemeVariant] 的展示层包装：底层直接用 Flutter SDK 自带的
/// 枚举（`package:flutter/material.dart` 里就有，和 `ColorScheme.fromSeed`
/// 的参数是同一个类型），这里只补上中文名称、适用场景说明和分组顺序，
/// 供设置页渲染成可选项。
///
/// 之所以不自己实现 scheme 生成：`ColorScheme.fromSeed` 内部就是
/// material_color_utilities 的 `SchemeXxx` 系列，和 Android 系统动态取色
/// 用的是同一份算法，跟手写一遍没有区别，还容易跟上游跑偏。
enum ZhyColorVariant {
  content(DynamicSchemeVariant.content, '内容', '色相与彩度都紧贴封面，最"像这张专辑"，也是本应用的默认值'),
  tonalSpot(
    DynamicSchemeVariant.tonalSpot,
    '色调点缀',
    'Android 12 Material You 的默认方案，低彩度、柔和，任何封面都不翻车',
  ),
  fidelity(DynamicSchemeVariant.fidelity, '保真', '尽量还原封面原色，适合色彩本身就很讲究的专辑封面'),
  vibrant(DynamicSchemeVariant.vibrant, '鲜艳', '彩度拉满，界面更跳脱，适合流行 / 电子乐'),
  expressive(DynamicSchemeVariant.expressive, '表现力', '主色相会主动偏离封面，配色更有变化和惊喜感'),
  neutral(DynamicSchemeVariant.neutral, '中性', '接近灰阶、只留一丝色彩，适合长时间阅读歌单'),
  monochrome(DynamicSchemeVariant.monochrome, '单色', '完全灰阶，最克制、最不抢封面风头'),
  rainbow(DynamicSchemeVariant.rainbow, '彩虹', '玩味方案，封面的色相不会出现在主题里'),
  fruitSalad(DynamicSchemeVariant.fruitSalad, '水果沙拉', '另一种玩味方案，色相同样刻意与原封面错开');

  const ZhyColorVariant(this.scheme, this.label, this.description);

  /// 交给 `ColorScheme.fromSeed` 的底层变体。
  final DynamicSchemeVariant scheme;

  /// 设置页展示用的中文名。
  final String label;

  /// 一句话说明「什么时候该选它」。
  final String description;

  /// 从持久化的名字还原（跨版本改名时回落到默认值）。
  static ZhyColorVariant fromName(String? name) {
    if (name == null) return ZhyColorVariant.content;
    for (final ZhyColorVariant v in values) {
      if (v.name == name) return v;
    }
    return ZhyColorVariant.content;
  }
}

/// 主题对比度档位。
///
/// 对应 `ColorScheme.fromSeed(contrastLevel: ...)`，取值区间为 -1.0 ~ 1.0，
/// 0.0 是 Material 的标准对比度。Material 3 的表达式主题（Expressive）
/// 正是通过它来满足 WCAG 的。
enum ZhyContrastLevel {
  standard(0.0, '标准', 'Material 默认对比度'),
  medium(0.5, '中等', '前景更实，弱光环境下更清楚'),
  high(1.0, '高', '最高对比度，等同系统「高对比度文字」设置'),
  reduced(-1.0, '柔和', '对比度低于标准，观感更轻，可读性会下降');

  const ZhyContrastLevel(this.value, this.label, this.description);

  final double value;
  final String label;
  final String description;

  static ZhyContrastLevel fromValue(double value) {
    ZhyContrastLevel best = ZhyContrastLevel.standard;
    double bestDistance = double.infinity;
    for (final ZhyContrastLevel level in values) {
      final double distance = (level.value - value).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = level;
      }
    }
    return best;
  }
}
