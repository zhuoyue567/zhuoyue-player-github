import 'package:flutter/material.dart';

import 'song_list.dart';

/// 三栏（外壳左侧导航 / 中栏列表 / 右栏内容或队列 island）共用的高度基准。
///
/// 为什么必须有这一处定义：
/// 这三栏的上下留白以前是**各写一套**的 —— 导航栏写 `fromLTRB(10, 4, 0, 0)`，
/// 页面内容走 `PageContentContainer` 的 `(24, 20, 24, 24)`，右侧队列 island
/// 又是 `top: 6, bottom: 6`。于是同一屏里三块玻璃卡的上沿相差 14~16px、
/// 下沿相差 18~24px：中栏那张卡比其余两栏矮一截，底部永远对不齐。
///
/// 现在只在这里定义一次，三栏都从这里取值（[navRailInsets] / [contentInsets] /
/// [overlayColumnInsets]）。想改三栏的上下留白，改这一个文件就够；想只改一栏
/// 就必须先绕过它，评审时一眼能看见。
abstract final class ZhyPageLayout {
  /// 三栏统一的顶部留白（从内容区顶端往下算）。
  static const double columnTop = 20;

  /// 三栏统一的底部留白（内容区底端往上算，也就是播放条上方那道缝）。
  static const double columnBottom = 24;

  /// 页面内容区的左右留白。
  static const double columnHorizontal = 24;

  /// 页面内容区的完整留白，喂给 `PageContentContainer`。
  ///
  /// 单栏页面（发现 / 搜索 / 下载）不显式传参，走的是它的默认值 —— 那默认值
  /// 是同一组数字的**第二份拷贝**，而本文件才是唯一出处。
  /// `test/page_layout_test.dart` 里有一条断言把两者钉成相等：谁改歪了，
  /// 单栏页面的上下就会和三栏错开，测试立刻红。
  static const EdgeInsets contentInsets = EdgeInsets.fromLTRB(
    columnHorizontal,
    columnTop,
    columnHorizontal,
    columnBottom,
  );

  /// 外壳左侧导航栏的留白。
  ///
  /// 左右不对称是刻意的：左边距 10 是导航栏贴着窗口左沿时自己的呼吸位，
  /// 右边不留缝 —— 它与内容区之间的间隔由内容区那份 24px 留白提供。
  /// 上下则必须与其余两栏一致，这正是这次修掉的问题。
  static const EdgeInsets navRailInsets = EdgeInsets.fromLTRB(
    10,
    columnTop,
    0,
    columnBottom,
  );

  /// 浮层栏（右侧队列 island）的上下留白，与另外两栏同高。
  ///
  /// 它是 `Positioned`，所以只需要上下两条边：左右由 island 自己的宽度决定。
  static const EdgeInsets overlayColumnInsets = EdgeInsets.only(
    top: columnTop,
    bottom: columnBottom,
  );

  /// 中栏与右栏之间的固定间距。
  static const double columnGap = 18;
}

/// 「中栏 + 右栏」两列骨架（外壳的左侧导航是第三栏）。
///
/// 为什么抽成组件而不是让页面自己拼 Row：中栏与右栏同高**只能靠"两栏用同一份
/// 上下留白"来保证**。以前两栏各自被一层 Padding 包着（中栏在页面里、右栏在
/// 外壳里），改一处忘一处就会错位，而且错位只有肉眼看得出来。
/// 现在留白由这里统一施加，页面只负责往两个槽里放内容：
/// [middle] 是固定宽度的列表栏，[content] 是自适应宽度的内容栏，
/// 两栏共用同一份高度约束（[CrossAxisAlignment.stretch]），上下边界必然相同。
///
/// 页面**不要**再给这两个槽里的任意一栏加额外的上下 margin / padding，
/// 那会立刻把中栏和右栏拉成两个高度。
class ThreeColumnBody extends StatelessWidget {
  const ThreeColumnBody({
    super.key,
    required this.middle,
    required this.content,
    required this.middleWidth,
  });

  /// 中栏（歌单 / 收藏夹列表）。
  final Widget middle;

  /// 右栏（选中集合的曲目列表）。
  final Widget content;

  /// 中栏宽度。各页可以不同，它不影响上下高度。
  final double middleWidth;

  @override
  Widget build(BuildContext context) {
    return PageContentContainer(
      // 左右分栏各自滚动、整页不滚：所以要把可用高度撑满。
      fillHeight: true,
      padding: ZhyPageLayout.contentInsets,
      child: Row(
        // 两栏吃同一份高度约束：这是"中栏和右栏一样高"的直接来源。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: middleWidth, child: middle),
          const SizedBox(width: ZhyPageLayout.columnGap),
          Expanded(child: content),
        ],
      ),
    );
  }
}
