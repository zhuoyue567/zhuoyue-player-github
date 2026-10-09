import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局字体的加载与注册。
///
/// 职责边界：这里只管"把字体字节注册成一个 Flutter 能用的 family"，
/// **不负责界面选择逻辑**（那在设置页），也**不负责持久化字段的定义**
/// （那在 `ZhyThemeSettings`）。这样换字体这件事只有一个入口。
class ZhyFontLoader {
  const ZhyFontLoader._();

  /// 内置字体的 family（对应 pubspec 里声明的 `Zhuzi`）。
  static const String bundledFamily = 'Zhuzi';

  /// 用户导入字体统一注册到这个 family。
  ///
  /// 刻意用一个固定名字，而不是去解析 TTF 的 `name` 表拿真实字体名：
  /// `FontLoader` 本来就允许我们随便指定 family，
  /// 读取 `name` 表（要处理 platformID / encodingID / UTF-16BE 多套编码）
  /// 唯一的收益只是能在界面上显示字体的真实名字 —— 而显示文件名已经够用，
  /// 不值得为此引入一段容易出错的二进制解析。
  static const String customFamily = 'ZhyCustom';

  /// 自定义字体是否已经成功注册。
  static bool get customLoaded => _customLoaded;
  static bool _customLoaded = false;

  /// 从磁盘加载一个字体文件并注册为 [customFamily]。
  ///
  /// 返回是否成功。失败只记日志、不抛异常：字体是个纯装饰性的设置，
  /// 为了一个坏掉的 ttf 让应用起不来是完全不成比例的。
  static Future<bool> loadCustomFont(String path) async {
    if (path.isEmpty) return false;
    try {
      final File file = File(path);
      if (!await file.exists()) {
        debugPrint('[font] 字体文件不存在：$path');
        return false;
      }
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        debugPrint('[font] 字体文件为空：$path');
        return false;
      }

      final FontLoader loader = FontLoader(customFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      _customLoaded = true;
      debugPrint('[font] 已注册自定义字体：$path（${bytes.length} 字节）');
      return true;
    } on Object catch (error) {
      debugPrint('[font] 加载自定义字体失败：$error');
      return false;
    }
  }

  /// 应用启动时按已保存的设置恢复自定义字体。
  ///
  /// **必须在 `runApp` 之前调用**：字体注册是异步的，如果放到第一帧之后，
  /// 用户会先看到一次系统字体的闪烁再换成自己的字体。
  static Future<void> restoreFromPreferences(SharedPreferences prefs) async {
    final String? path = prefs.getString(customFontPathKey);
    if (path == null || path.isEmpty) return;
    await loadCustomFont(path);
  }

  /// 持久化键。与 `ZhyThemeSettingsStore` 共用同一份 key，
  /// 避免"设置里存的路径"和"启动时读的路径"两处各写一遍字符串。
  static const String customFontPathKey = 'theme.customFontPath';
}
