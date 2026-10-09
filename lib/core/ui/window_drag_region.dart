import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 一块「可以拖动窗口」的透明区域。
///
/// 为什么不用 `window_manager` 自带的 `DragToMoveArea`：
/// 它的手势识别依赖子树参与命中测试，铺在标题栏里时**只有子组件真正画了像素
/// 的地方**才拖得动。标题栏中间那些"看起来什么都没有"的空白就成了死区，
/// 用户拖到那里会觉得"这块拖不动"。
///
/// 这里的做法是 [HitTestBehavior.translucent] + `SizedBox.expand()`：
/// 整块区域无条件参与命中测试，同时**不遮挡**上层组件 ——
/// 所以正确的用法是把它当作 `Stack` 的**第一个**子节点铺满整条标题栏，
/// 让搜索框、窗口按钮这些上层的交互组件照常吃掉自己的手势，
/// 剩下的空隙全部归拖动区。
///
/// 沉浸式页面（如全屏播放页）会盖住标题栏，所以它也必须在自己的顶栏里
/// 铺一层这个 —— 否则窗口一旦进入沉浸页就再也拖不动了。
class WindowDragRegion extends StatelessWidget {
  const WindowDragRegion({super.key, this.onDoubleTap});

  /// 双击行为。默认最大化 / 还原，符合 Windows 的原生习惯。
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => unawaited(windowManager.startDragging()),
      onDoubleTap: onDoubleTap ?? () => unawaited(toggleMaximize()),
      child: const SizedBox.expand(),
    );
  }
}

/// 在最大化与还原之间切换。
Future<void> toggleMaximize() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}
