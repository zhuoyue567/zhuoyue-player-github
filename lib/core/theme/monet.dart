import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:material_color_utilities/material_color_utilities.dart' as mcu;

/// 莫奈（Monet）取色的完整结果。
///
/// 除了可直接当作 Material You 种子色的 [seedArgb] 之外，还保留了按像素
/// 占比降序排列的候选色，供渐变背景、次级强调色、封面投影等处使用 ——
/// 只拿一个种子色会让界面"能用但单调"。
@immutable
class MonetPalette {
  const MonetPalette({
    required this.seedArgb,
    required this.rankedArgb,
    required this.hue,
    required this.chroma,
    required this.tone,
  });

  /// 由封面量化 + 打分得到的主色（ARGB），可直接作为 `ColorScheme.fromSeed` 的种子。
  final int seedArgb;

  /// 按像素占比降序的候选色（ARGB）。
  final List<int> rankedArgb;

  /// 种子色在 HCT 色彩空间中的色相 / 彩度 / 明度，便于调试与展示。
  final double hue;
  final double chroma;
  final double tone;

  Color get seedColor => Color(seedArgb);

  List<Color> get rankedColors =>
      List<Color>.unmodifiable(rankedArgb.map((int v) => Color(v)));

  /// 取第 [index] 个候选色；越界时回落到种子色，避免调用方到处判空。
  Color accentAt(int index) => index >= 0 && index < rankedArgb.length
      ? Color(rankedArgb[index])
      : seedColor;

  /// 用于大封面背后的柔和渐变：取前若干候选色，不够时用种子色补齐。
  List<Color> gradientStops(int count) {
    if (count <= 0) return const <Color>[];
    final List<Color> out = <Color>[];
    for (int i = 0; i < count; i++) {
      out.add(accentAt(i % (rankedArgb.isEmpty ? 1 : rankedArgb.length)));
    }
    return out;
  }

  @override
  String toString() =>
      'MonetPalette(seed: #${seedArgb.toRadixString(16).padLeft(8, '0')}, '
      'hct: ${hue.toStringAsFixed(1)}/${chroma.toStringAsFixed(1)}/${tone.toStringAsFixed(1)}, '
      'candidates: ${rankedArgb.length})';
}

/// `compute` 的入参打包。isolate 之间传的是普通对象，`Uint8List` 会被拷贝。
@immutable
class _MonetJob {
  const _MonetJob(this.bytes, this.maxDimension, this.maxColors, this.desired);
  final Uint8List bytes;
  final int maxDimension;
  final int maxColors;
  final int desired;
}

/// 与 Android Monet 同源的封面取色器。
///
/// 流程刻意与 Android 12 的 `DynamicColors` 保持一致，保证"同样的封面，
/// 这个播放器取出来的颜色和系统动态取色是一个味儿"：
///
/// 1. **降采样**：把封面缩到最长边 [maxDimension] px（Android 取 112×112）。
///    这一步既滤掉高频噪声（噪点会让量化器产出大量无意义色簇），
///    也让后面的量化足够快、可以在几十毫秒内跑完。
/// 2. **量化**：用 Celebi 量化器（基于 Wu 的混合算法）把像素聚成
///    不超过 [maxColors] 种颜色，得到 `颜色 -> 像素数` 的直方图。
/// 3. **打分**：用 Material 的 `Score` 挑出"最适合当主题色"的颜色，
///    而不是"出现最多的颜色"。这是关键差别 —— 一张白底专辑封面出现最多
///    的必然是白色，但 Score 会按彩度、明度、占比综合打分，
///    自动避开大面积白底、黑边和灰阶区域，选出真正有辨识度的彩色。
class MonetExtractor {
  const MonetExtractor({
    this.maxDimension = 112,
    this.maxColors = 128,
    this.desired = 5,
  });

  /// 量化前的最长边像素数。112 取自 Android Monet 的实现。
  final int maxDimension;

  /// 量化后允许的最大颜色数。
  final int maxColors;

  /// 期望返回的候选色数量。
  final int desired;

  /// 从编码后的图片字节（jpg / png / webp / bmp…）取色。
  ///
  /// 解码与量化都在独立 isolate 中完成：一张 1000×1000 的 JPEG 解码
  /// 在主 isolate 上要几十毫秒，正好卡在切歌的那一帧上。
  Future<MonetPalette?> extractFromEncoded(Uint8List bytes) {
    if (bytes.isEmpty) return Future<MonetPalette?>.value();
    return compute(
      _extractFromEncoded,
      _MonetJob(bytes, maxDimension, maxColors, desired),
      debugLabel: 'monet-extract',
    );
  }

  /// 从已解码的图片取色（异步，调用方自行保证不在关键路径上）。
  ///
  /// 注意：`material_color_utilities` 0.13 起 `Quantizer.quantize` 改成了
  /// 异步接口并返回 `QuantizerResult`（直方图在 `colorToCount` 里），
  /// 不再是早期版本的 `Map<int, int>`。`Score.score` 仍然吃 `Map<int, int>`。
  Future<MonetPalette?> extractFromImage(img.Image source) async {
    final img.Image small = _downscale(source);
    final List<int> pixels = _opaquePixels(small);
    // 像素太少时量化结果没有统计意义，直接放弃，交给调用方兜底。
    if (pixels.length < 16) return null;

    final mcu.QuantizerResult quantized = await mcu.QuantizerCelebi().quantize(
      pixels,
      maxColors,
    );
    final List<int> ranked = mcu.Score.score(
      quantized.colorToCount,
      desired: desired,
      filter: true,
    );
    if (ranked.isEmpty) return null;

    final mcu.Hct hct = mcu.Hct.fromInt(ranked.first);
    return MonetPalette(
      seedArgb: ranked.first,
      rankedArgb: List<int>.unmodifiable(ranked),
      hue: hct.hue,
      chroma: hct.chroma,
      tone: hct.tone,
    );
  }

  img.Image _downscale(img.Image source) {
    final int longest = source.width > source.height
        ? source.width
        : source.height;
    if (longest <= maxDimension) return source;
    // 只给一个维度，image 包会按原比例算出另一个维度。
    return img.copyResize(
      source,
      width: source.width >= source.height ? maxDimension : null,
      height: source.height > source.width ? maxDimension : null,
      interpolation: img.Interpolation.average,
    );
  }

  List<int> _opaquePixels(img.Image image) {
    final Uint8List rgba = image.getBytes(order: img.ChannelOrder.rgba);
    final List<int> out = <int>[];
    for (int i = 0; i + 3 < rgba.length; i += 4) {
      final int a = rgba[i + 3];
      // 丢弃半透明像素：它们与背景混合后的真实颜色未知，参与量化只会污染结果。
      if (a < 128) continue;
      out.add((a << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
    }
    return out;
  }
}

Future<MonetPalette?> _extractFromEncoded(_MonetJob job) async {
  final img.Image? decoded = img.decodeImage(job.bytes);
  if (decoded == null) return null;
  return MonetExtractor(
    maxDimension: job.maxDimension,
    maxColors: job.maxColors,
    desired: job.desired,
  ).extractFromImage(decoded);
}
