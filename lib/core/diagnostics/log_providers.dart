import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'log_buffer.dart';

/// 全局日志缓冲区。
///
/// 在这里建、顺手装上 debugPrint 钩子，是刻意的选择：只要有人第一次
/// 读这个 provider，捕获就已经生效了。反过来，如果钩子要等到"用户打开
/// 日志面板"才装，面板里永远是空的 —— 用户想看的是**打开面板之前**
/// 发生过什么（"这首歌为什么播不了"）。
///
/// 面板只是这个缓冲区的一个视图，所以生命周期挂在 provider 上，
/// 面板开关多少次都不会丢日志。
///
/// 注意：`installLogCapture` 在测试环境下会主动跳过安装
/// （见 `isRunningInTestHarness`），所以 widget 测试里这个缓冲区是空的，
/// 测试要断言渲染就得自己 `add`。
final Provider<LogBuffer> logBufferProvider = Provider<LogBuffer>((Ref ref) {
  final LogBuffer buffer = LogBuffer();
  installLogCapture(buffer);
  ref.onDispose(buffer.dispose);
  return buffer;
});
