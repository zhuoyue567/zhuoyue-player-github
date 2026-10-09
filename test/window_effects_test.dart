import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/core/window/window_effects.dart';

/// 窗口效果层里最容易写错、又最难从界面看出来的是两块：
///
/// 1. `RtlGetVersion` 的**结构体布局**。`OSVERSIONINFOEXW` 里夹着
///    一个 `WCHAR[128]` 和一个 `BYTE`，少一个字段或者对齐错了，
///    读出来的 build number 就是垃圾值 —— 而界面只会表现为
///    "Mica 有时能用有时不能用"，极难定位。
/// 2. 能力判定的分支。Win10 / Win11 21H2 / Win11 22H2 三条路径不同，
///    写错任何一个都会让某个版本的窗口变成一片黑。
///
/// 所以这里直接断言真实探测结果，而不是只跑 Dart 侧的纯逻辑。
void main() {
  final bool isWindows = Platform.isWindows;

  group('WindowEffects 系统能力探测', () {
    test('能读到真实的 Windows build number', () {
      final WindowsBackdropSupport support = WindowEffects.support;

      if (!isWindows) {
        expect(support.buildNumber, 0);
        return;
      }

      // 项目要求的最低系统是 Windows 10，其 build 至少是 10240。
      // 读出 0 或离谱的大值都说明 OSVERSIONINFOEXW 的布局错了。
      expect(support.buildNumber, greaterThan(10000));
      expect(support.buildNumber, lessThan(100000));
      expect(support.majorVersion, 10);
    });

    test('能力判定与 build number 自洽', () {
      final WindowsBackdropSupport support = WindowEffects.support;
      if (!isWindows) return;

      expect(support.isWindows11, support.buildNumber >= 22000);
      expect(support.supportsMica, support.buildNumber >= 22000);
      expect(support.supportsBackdropType, support.buildNumber >= 22621);
      expect(support.supportsAcrylic, support.buildNumber >= 17134);

      // Mica 必然要求 Win11，这条蕴含关系要是破了，说明判定写反了。
      if (support.supportsMica) {
        expect(support.isWindows11, isTrue);
      }
      // backdrop type 是 Mica 的超集能力。
      if (support.supportsBackdropType) {
        expect(support.supportsMica, isTrue);
      }
    });

    test('label 能给出可读的系统描述', () {
      final WindowsBackdropSupport support = WindowEffects.support;
      if (!isWindows) return;
      expect(support.label, contains('Windows'));
      expect(support.label, contains('build'));
    });

    test('在没有真实窗口的环境里，取句柄失败但不抛异常', () {
      // `flutter test` 跑在无窗口的 headless 环境里，GetWindowThreadProcessId
      // 过滤后必然找不到窗口。这里要的是"安全地失败"：
      // 返回 0 而不是抛异常，这样应用在窗口还没创建时调也不会崩。
      expect(() => WindowEffects.windowHandle(), returnsNormally);
    });

    test('直接应用材质时也安全失败（不会抛）', () {
      late AppliedBackdrop result;
      expect(() {
        result = WindowEffects.applyMaterial(
          ZhyWindowMaterial.acrylic,
          tintArgb: const Color(0xFF202020),
          opacity: 0.78,
          dark: true,
        );
      }, returnsNormally);

      if (isWindows) {
        // 无窗口时应当给出 false 的结论，而不是谎报成功 ——
        // 界面靠 isSystemEffect 决定要不要提示用户"材质降级了"。
        expect(result.isSystemEffect, isFalse);
        expect(result.note, isNotNull);
      }
    });
  });

  group('ZhyWindowMaterial', () {
    test('系统效果与自绘效果的划分正确', () {
      expect(ZhyWindowMaterial.acrylic.usesSystemEffect, isTrue);
      expect(ZhyWindowMaterial.mica.usesSystemEffect, isTrue);
      expect(ZhyWindowMaterial.micaAlt.usesSystemEffect, isTrue);
      expect(ZhyWindowMaterial.blur.usesSystemEffect, isTrue);

      // 这两个必须不走系统效果，否则在远程桌面 / 虚拟机里会变成一片黑。
      expect(ZhyWindowMaterial.simulated.usesSystemEffect, isFalse);
      expect(ZhyWindowMaterial.solid.usesSystemEffect, isFalse);
      expect(ZhyWindowMaterial.simulated.isSimulated, isTrue);
      expect(ZhyWindowMaterial.solid.isOpaque, isTrue);
    });

    test('fromName 对未知输入回落到默认值', () {
      expect(ZhyWindowMaterial.fromName('mica'), ZhyWindowMaterial.mica);
      expect(ZhyWindowMaterial.fromName(null), ZhyWindowMaterial.acrylic);
      expect(ZhyWindowMaterial.fromName('不存在的材质'), ZhyWindowMaterial.acrylic);
    });
  });
}
