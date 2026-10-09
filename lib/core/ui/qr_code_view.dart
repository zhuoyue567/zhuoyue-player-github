import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// 把一个字符串画成二维码。
///
/// 为什么自己画而不用现成的二维码组件：哔哩的扫码登录接口只返回一个 URL，
/// 必须由客户端生成二维码图形。`qr_flutter` 最后一次发版是 2023 年，
/// 对 Flutter 版本的耦合是个隐患；而纯 Dart 的 `qr` 只依赖 `meta`，
/// 绘图部分用 [CustomPainter] 自己实现反而更可控。
class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    required this.data,
    this.size = 200,
    this.foreground = Colors.black,
    this.background = Colors.white,
    this.padding = 10,
    this.errorCorrectLevel = QrErrorCorrectLevel.medium,
    this.semanticLabel = '登录二维码',
  });

  final String data;
  final double size;
  final Color foreground;
  final Color background;
  final double padding;

  /// 纠错等级。扫码登录的二维码会被手机摄像头在各种角度下拍，
  /// 用 M 级（15%）比 L 级更稳，代价只是模块数略增。
  final QrErrorCorrectLevel errorCorrectLevel;

  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: background,
          // 二维码必须贴在纯色底上，圆角只放在外层容器上，
          // 不能裁到码本身，否则会破坏定位图案。
          borderRadius: BorderRadius.circular(12),
        ),
        child: CustomPaint(
          painter: _QrPainter(
            data: data,
            foreground: foreground,
            errorCorrectLevel: errorCorrectLevel,
          ),
          size: Size.square(size - padding * 2),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter({
    required this.data,
    required this.foreground,
    required this.errorCorrectLevel,
  });

  final String data;
  final Color foreground;
  final QrErrorCorrectLevel errorCorrectLevel;

  /// 静区宽度（单位：模块）。规范要求至少 4 个模块，
  /// 少了它扫码识别率会明显下降 —— 这是最容易被忽略的一步。
  static const int _quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final QrImage image;
    try {
      image = QrImage(
        QrCode(
          payload: QrPayload.fromString(data),
          errorCorrectLevel: errorCorrectLevel,
        ),
      );
    } on Object {
      // 内容过长等极端情况下画一个提示，而不是抛异常炸掉整个登录弹窗。
      final TextPainter painter = TextPainter(
        text: const TextSpan(
          text: '二维码生成失败',
          style: TextStyle(color: Colors.black54, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      painter.paint(canvas, Offset.zero);
      return;
    }

    final int modules = image.moduleCount;
    final double total = modules + _quietZone * 2;
    final double cell = size.width / total;
    final Paint paint = Paint()..color = foreground;

    for (int row = 0; row < modules; row++) {
      for (int col = 0; col < modules; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (col + _quietZone) * cell,
            (row + _quietZone) * cell,
            // 加一点重叠，避免浮点取整在模块之间留下 1px 白缝。
            cell + 0.5,
            cell + 0.5,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) =>
      oldDelegate.data != data ||
      oldDelegate.foreground != foreground ||
      oldDelegate.errorCorrectLevel != errorCorrectLevel;
}
