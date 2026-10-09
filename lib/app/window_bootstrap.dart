import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/ui/glass.dart';
import '../core/window/window_effects.dart';

/// 窗口的初始逻辑尺寸。桌面播放器不需要占满屏幕，
/// 但必须放得下「侧边栏 + 歌单表格 + 播放条」。
const Size kInitialWindowSize = Size(1240, 800);

/// 再小就会挤坏布局（侧边栏 + 至少 4 列歌曲信息）。
const Size kMinimumWindowSize = Size(900, 560);

/// 创建窗口并做好启用系统材质的准备。
///
/// 顺序很关键：
/// 1. 先 `ensureInitialized`；
/// 2. `waitUntilReadyToShow` 里再设圆角 —— 窗口句柄此时才存在，
///    更早调用 `DwmSetWindowAttribute` 只会拿到 0 句柄然后静默失败；
/// 3. 最后把窗口背景刷成透明。这一步是亚克力能不能看见的前提：
///    Flutter 的渲染面必须允许 alpha 通过，DWM 的模糊才有地方透出来。
///
/// ⚠️ **尺寸单位：`window_manager` 在 Windows 上收发的就是逻辑像素**
/// （它内部自己按窗口 DPI 换算），**不要再去乘 devicePixelRatio**。
///
/// 这里翻过一次车，值得记下来：早先用一个 DPI 不感知的脚本量窗口尺寸，
/// 读到的是"虚拟化"坐标（按 96 DPI 缩放），于是得出了"setSize 收的是物理像素"
/// 的错误结论，并加了一层 ×devicePixelRatio 的"修正"。
/// 后果是初始 1240 被放大到 1860（又被夹到接近全屏），
/// 最小尺寸 900 被放大到 1470 —— **窗口最小只能缩到 1470×960，
/// 用户根本没法把窗口调小**。
/// 修正后：直接传逻辑尺寸，并用 DPI 感知的方式复核（见 docs/development.md）。
Future<void> bootstrapWindow() async {
  await windowManager.ensureInitialized();

  const WindowOptions options = WindowOptions(
    size: kInitialWindowSize,
    minimumSize: kMinimumWindowSize,
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: '卓越播放器',
    // hidden 保留系统的缩放边框（用户仍然能拖动边缘改变大小），
    // 只把标题栏交给 Flutter 自绘。
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(options, () {
    // 必须在帧后调用：窗口刚创建时句柄缓存可能是空的。
    WindowEffects.invalidateHandleCache();
    WindowEffects.setRoundedCorners(true);
    unawaited(windowManager.show());
    unawaited(windowManager.focus());
  });

  await windowManager.setBackgroundColor(Colors.transparent);

  // 再补一次尺寸并居中。
  // `waitUntilReadyToShow` 阶段窗口还没落到目标显示器上，DPI 取不准；
  // 窗口真正创建完之后再设一次，位置和尺寸才是确定的。
  await windowManager.setMinimumSize(kMinimumWindowSize);
  await windowManager.setSize(kInitialWindowSize);
  await windowManager.setAlignment(Alignment.center);

  // 拦截关闭动作：内嵌的 node 服务是子进程，必须由我们显式收掉，
  // 否则主窗口关掉之后它还会在后台驻留（下次启动就会越堆越多）。
  await windowManager.setPreventClose(true);

  // 噪点纹理提前生成，避免第一帧背景上出现"没颗粒"的突兀感。
  unawaited(ZhyNoise.warmUp());
}
