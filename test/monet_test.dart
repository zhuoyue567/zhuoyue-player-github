import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_color_utilities/material_color_utilities.dart' as mcu;
import 'package:zhuoyue_player/core/theme/color_utils.dart';
import 'package:zhuoyue_player/core/theme/monet.dart';
import 'package:zhuoyue_player/core/utils/format.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';

/// 构造一张纯色图并编码成 PNG。
Uint8List _solidPng(int r, int g, int b, {int size = 64}) {
  final img.Image image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodePng(image);
}

/// 白色背景 + 一小块彩色区域。
///
/// 这正是「用 Score 而不是"出现最多的颜色"」的价值所在：
/// 出现最多的是白色，但主题色应该是那块彩色。
Uint8List _whiteWithPatchPng(
  int r,
  int g,
  int b, {
  int size = 64,
  int patch = 16,
}) {
  final img.Image image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: patch - 1,
    y2: patch - 1,
    color: img.ColorRgb8(r, g, b),
  );
  return img.encodePng(image);
}

void main() {
  group('MonetExtractor', () {
    test('纯色封面能取回该颜色的色相', () async {
      // 不断言"我记得这个颜色是 328°"这类主观数字，而是拿同一个 ARGB
      // 交给 Hct 算出基准色相再比对 —— 这样测的是"量化 + 打分有没有保真"，
      // 而不是我对 CIE 色相的记忆准不准。
      const int sourceArgb = 0xFFDC28A0;
      final mcu.Hct reference = mcu.Hct.fromInt(sourceArgb);

      final Uint8List png = _solidPng(0xDC, 0x28, 0xA0);
      final MonetPalette? palette = await const MonetExtractor()
          .extractFromEncoded(png);

      expect(palette, isNotNull);
      final mcu.Hct seed = mcu.Hct.fromInt(palette!.seedArgb);
      expect(seed.hue, closeTo(reference.hue, 25));
      expect(seed.chroma, greaterThan(30));
      expect(palette.rankedArgb, isNotEmpty);
    });

    test('大面积白底上的小块彩色会被选为主题色', () async {
      final Uint8List png = _whiteWithPatchPng(20, 80, 220);
      final MonetPalette? palette = await const MonetExtractor()
          .extractFromEncoded(Uint8List.fromList(png));

      expect(palette, isNotNull);
      final mcu.Hct seed = mcu.Hct.fromInt(palette!.seedArgb);
      // 蓝色的色相在 250° 附近。取到白色（无彩度）或色相跑到别处都算失败。
      expect(seed.hue, closeTo(260, 40));
      expect(seed.chroma, greaterThan(20));
    });

    test('空白输入返回 null 而不是抛异常', () async {
      final MonetPalette? palette = await const MonetExtractor()
          .extractFromEncoded(Uint8List(0));
      expect(palette, isNull);
    });

    test('损坏的图片字节返回 null 而不是抛异常', () async {
      final MonetPalette? palette = await const MonetExtractor()
          .extractFromEncoded(
            Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
          );
      expect(palette, isNull);
    });

    test('gradientStops 在候选色不足时会循环补齐', () async {
      final Uint8List png = _solidPng(30, 160, 90);
      final MonetPalette? palette = await const MonetExtractor()
          .extractFromEncoded(Uint8List.fromList(png));
      expect(palette, isNotNull);
      final List<Color> stops = palette!.gradientStops(5);
      expect(stops, hasLength(5));
      expect(stops.every((Color c) => c.a == 1.0), isTrue);
    });
  });

  group('ZhyColor', () {
    test('解析各种写法的十六进制颜色', () {
      expect(ZhyColor.tryParseHex('#FF0000'), 0xFFFF0000);
      expect(ZhyColor.tryParseHex('ff0000'), 0xFFFF0000);
      expect(ZhyColor.tryParseHex('#f00'), 0xFFFF0000);
      expect(ZhyColor.tryParseHex('0xFF00FF00'), 0xFF00FF00);
      expect(ZhyColor.tryParseHex('  #00 00 ff  '), 0xFF0000FF);
    });

    test('非法输入返回 null 而不是抛异常', () {
      expect(ZhyColor.tryParseHex(''), isNull);
      expect(ZhyColor.tryParseHex('#12345'), isNull);
      expect(ZhyColor.tryParseHex('not-a-color'), isNull);
    });

    test('toHexRgb 与 tryParseHex 可以往返', () {
      const int argb = 0xFF12AB34;
      expect(ZhyColor.tryParseHex(ZhyColor.toHexRgb(argb)), argb);
    });

    test('深色背景上给出浅色前景', () {
      expect(ZhyColor.onColor(const Color(0xFF101010)), Colors.white);
      expect(ZhyColor.onColor(const Color(0xFFF5F5F5)), isNot(Colors.white));
    });
  });

  group('模型', () {
    test('Song.uid 跨音源唯一', () {
      const Song a = Song(id: '1', source: MediaSource.netease, title: 'x');
      const Song b = Song(id: '1', source: MediaSource.bilibili, title: 'x');
      expect(a.uid, isNot(b.uid));
      expect(a, isNot(b));
      expect(a, a.copyWith());
    });

    test('safeFileName 去掉 Windows 非法字符', () {
      const Song song = Song(
        id: '1',
        source: MediaSource.netease,
        title: 'A/B:C*D?E"F<G>H|I',
        artists: <String>['周杰伦'],
      );
      expect(song.safeFileName, '周杰伦 - A_B_C_D_E_F_G_H_I');
    });

    test('artistLabel 在空艺人列表时给出兜底文案', () {
      const Song song = Song(id: '1', source: MediaSource.local, title: 'x');
      expect(song.artistLabel, '未知艺人');
    });
  });

  group('ZhyFormat', () {
    test('时长格式化', () {
      expect(ZhyFormat.duration(null), '--:--');
      expect(ZhyFormat.duration(const Duration(seconds: 5)), '0:05');
      expect(
        ZhyFormat.duration(const Duration(minutes: 3, seconds: 7)),
        '3:07',
      );
      expect(
        ZhyFormat.duration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });

    test('大数字用中文单位', () {
      expect(ZhyFormat.count(999), '999');
      expect(ZhyFormat.count(12345), '1.2万');
      expect(ZhyFormat.count(345000000), '3.5亿');
    });

    test('字节数格式化', () {
      expect(ZhyFormat.bytes(null), '0 B');
      expect(ZhyFormat.bytes(512), '512 B');
      expect(ZhyFormat.bytes(1024 * 1024 * 3), '3.0 MB');
    });
  });
}
