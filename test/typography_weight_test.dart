// 排版字重不变量：内置字体只有一个字面，代码里不许再请求 w600 / w700。
//
// 为什么存在这条不变量
// --------------------
// `assets/fonts/zhuzi.ttf` 只有**一个**字面：OS/2 usWeightClass = 400、
// subfamily = Regular，而且不是可变字体。用这个单字面字体做像素测量的结果：
//
//   * w500 与 w400 的墨迹**完全相同**（比值 1.0000）—— 引擎直接复用 w400，
//     不合成；
//   * w600 与 w700 的墨迹比 w400 多出 **51%**（比值 1.5124）—— 引擎在
//     **描边合成**（faux bold）。
//
// 合成加粗在中文小字上的表现就是"发虚、笔画粗细不匀"，也就是用户反馈的
// "部分字体的字重不对"。所以代码侧统一只请求 w400 / w500，不请求这个字体
// 根本没有的字重。
//
// 为什么写成"扫源码"而不是"渲染后量像素"
// --------------------------------------
// 量像素要跑引擎、要真字体、要设备像素比，还会被抗锯齿与 hinting 干扰，
// 换一台机器就可能晃；而"源码里有没有请求 w600"是可静态判定、与引擎行为
// 无关的事实。前者会闪，后者不会。
//
// 什么时候应该放宽这条测试
// ------------------------
// 只有一种情况：**主字体换成或新增了自带 Bold 字面的字体**（例如默认改用
// 系统字体 —— 它有真正的 Regular + Bold）。那时请把下面的白名单按
// "文件 + 行内特征"补一条，并在注释里写明换成的是什么字体、为什么它不再走
// 合成路径。**不要**因为"测试红了"就把它删掉或整条注释掉 —— 那等于把
// "中文小字靠描边加粗"这个回归重新放回代码里。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 白名单
// ---------------------------------------------------------------------------

/// 一条"允许保留 w600 / w700"的例外规则。
///
/// 刻意按 **文件 + 行内特征** 描述，不写死行号：行号会随任何一次增删行而
/// 漂移，写死行号的测试最后一定会退化成"为了让测试变绿而改数字"。
class _Allowance {
  const _Allowance({
    required this.file,
    required this.linePattern,
    required this.fontContextPattern,
    required this.why,
  });

  /// `lib/` 下的相对路径，正斜杠分隔。
  final String file;

  /// 命中行必须匹配它，这条豁免才生效。
  final RegExp linePattern;

  /// 命中处还必须落在匹配它的"字体上下文"里 —— 用来确认这处字重最终确实
  /// 交给了一个**自带真 Bold 字面**的字体，而不是靠合成。
  ///
  /// `null` 表示不检查字体上下文：那种豁免是"显式登记的欠账"，
  /// 加它的同时必须在 [why] 里写清什么时候还。
  final RegExp? fontContextPattern;

  /// 保留它的理由；测试失败信息里会一并打出来。
  final String why;
}

final List<_Allowance> _allowances = <_Allowance>[
  // Consolas 是 Windows 自带的等宽字体，它**有真正的 Bold 字面**，这里的
  // 加粗不走合成路径 —— 改小反而是损失。判定不看行号：只要这处字重落在
  // 同一个"字体上下文"（外层 TextSpan / TextStyle）里写了 Consolas
  // （或 `_mono` fallback）的节点之内，就认。
  _Allowance(
    file: 'lib/features/diagnostics/log_panel.dart',
    linePattern: RegExp(r'fontWeight:\s*FontWeight\.(w[6-9]00|bold)'),
    fontContextPattern: RegExp(r"fontFamily:\s*'Consolas'|_mono"),
    why: '这段日志文本的字体是 Consolas（有真 Bold 字面），这处加粗不是合成',
  ),
];

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

/// 要钉住的对象：内置字体没有这两种字重，请求了就只能靠合成。
final RegExp _weightRequest = RegExp(r'FontWeight\.(w600|w700)');

/// 同一类风险的扩展覆盖。
///
/// `FontWeight.bold` 的数值就是 w700，w800 / w900 比 w700 更粗、同样只能靠
/// 合成。这三者目前一处都没有；单独列一条测试是为了以后有人写
/// `FontWeight.bold` 时也能被立刻拦下，而不必等用户再来反馈一次"字重不对"。
final RegExp _weightRequestExtended = RegExp(r'FontWeight\.(bold|w800|w900)');

/// 一处命中。
class _Hit {
  _Hit({
    required this.file,
    required this.line,
    required this.text,
    required this.context,
  });

  /// 相对包根的路径，正斜杠分隔。
  final String file;

  /// 1-based 行号。
  final int line;

  /// 命中行的原文（不含换行）。
  final String text;

  /// 命中处所有包围它的 `TextStyle(...)` / `TextSpan(...)` 区间原文。
  final String context;

  /// 失败信息里让人一眼定位的那一行。
  String get location => '$file:$line';

  @override
  String toString() => '$location  $text';
}

/// 一个 `TextStyle(` / `TextSpan(` 的配对区间。
class _Region {
  const _Region(this.start, this.end);

  final int start;
  final int end;
}

/// 找到包根：往上最多找 4 层。
///
/// 测试进程的工作目录不一定是包根（IDE 有时从别处起进程），找错了就会去扫
/// 一个空目录 —— 那样这条不变量会变成**空转的绿**，比红更危险。
Directory _packageRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/lib').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到包根（含 pubspec.yaml 与 lib/ 的目录），当前工作目录：${Directory.current.path}');
}

/// 递归扫 `lib/**.dart`，返回 [needle] 的全部命中。
List<_Hit> _scan(RegExp needle) {
  final Directory root = _packageRoot();
  final Directory lib = Directory('${root.path}/lib');

  final List<File> files =
      lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((File file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  expect(files, isNotEmpty, reason: 'lib/ 下一个 .dart 都没扫到 —— 路径解析错了，这条测试就失去意义了');

  final String rootPath = root.path.replaceAll(r'\', '/');
  final List<_Hit> hits = <_Hit>[];
  for (final File file in files) {
    final String source = file.readAsStringSync();
    final List<int> lineStarts = <int>[0];
    for (int i = 0; i < source.length; i++) {
      if (source.codeUnitAt(i) == 0x0A) lineStarts.add(i + 1);
    }
    final String relative = file.path
        .replaceAll(r'\', '/')
        .replaceFirst('$rootPath/', '');

    for (final RegExpMatch match in needle.allMatches(source)) {
      final int line = _lineNumberOf(lineStarts, match.start);
      final int lineStart = lineStarts[line - 1];
      final int lineEnd = line < lineStarts.length
          ? lineStarts[line] - 1
          : source.length;
      hits.add(
        _Hit(
          file: relative,
          line: line,
          text: source.substring(lineStart, lineEnd).trimRight(),
          context: _fontContextAt(source, match.start),
        ),
      );
    }
  }
  return hits;
}

/// 命中偏移落在第几行（1-based）。
int _lineNumberOf(List<int> lineStarts, int offset) {
  int low = 0;
  int high = lineStarts.length - 1;
  while (low < high) {
    final int mid = (low + high + 1) ~/ 2;
    if (lineStarts[mid] <= offset) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low + 1;
}

/// 命中处的"字体上下文"：所有包住它的 `TextStyle(` / `TextSpan(` 区间原文。
///
/// 为什么要往外找、而不是只看命中行：`log_panel.dart` 里保留的那处 w600，
/// 它自己的 `TextStyle` 并没有写字体，Consolas 来自外层 `TextSpan` 的 style
/// （Flutter 的 `TextSpan` 会把父级 style 继承给子 span）。只看命中行就会
/// 把这条合法的例外误判成违规。
String _fontContextAt(String source, int offset) {
  final StringBuffer buffer = StringBuffer();
  for (final _Region region in _regions(source)) {
    if (region.start <= offset && offset < region.end) {
      buffer.writeln(source.substring(region.start, region.end));
    }
  }
  return buffer.toString();
}

/// 所有 `TextStyle(...)` / `TextSpan(...)` 的配对区间。
///
/// 用括号配平来切区间，不引 analyzer：为一条静态不变量在测试里拉进整个语法
/// 树不划算。已知的粗糙之处是字符串字面量里的括号也会参与配平 ——
/// 本项目里没有这种写法；真写错了会让区间偏大或偏小，从而让白名单**匹配不到**
/// （测试变红），不会让本该报的问题被悄悄放过。
List<_Region> _regions(String source) {
  final RegExp opener = RegExp(r'(TextStyle|TextSpan)\s*\(');
  final List<_Region> regions = <_Region>[];
  for (final RegExpMatch match in opener.allMatches(source)) {
    final int open = source.indexOf('(', match.start);
    int depth = 0;
    int i = open;
    for (; i < source.length; i++) {
      final int unit = source.codeUnitAt(i);
      if (unit == 0x28) {
        depth++;
      } else if (unit == 0x29) {
        depth--;
        if (depth == 0) break;
      }
    }
    regions.add(_Region(open, i));
  }
  return regions;
}

/// 一处命中是否被白名单放过；返回命中的那条规则（没有则返回 null）。
_Allowance? _allowanceFor(_Hit hit) {
  for (final _Allowance rule in _allowances) {
    if (rule.file != hit.file) continue;
    if (!rule.linePattern.hasMatch(hit.text)) continue;
    final RegExp? contextPattern = rule.fontContextPattern;
    if (contextPattern != null && !contextPattern.hasMatch(hit.context)) {
      continue;
    }
    return rule;
  }
  return null;
}

/// 扫一遍并把"不被允许的命中"渲染成一份可直接定位的报告。
void _expectOnlyAllowlisted(RegExp needle, String what) {
  final List<_Hit> hits = _scan(needle);
  final List<_Hit> unexpected = <_Hit>[];
  for (final _Hit hit in hits) {
    if (_allowanceFor(hit) == null) unexpected.add(hit);
  }

  if (unexpected.isEmpty) return;

  final StringBuffer message = StringBuffer()
    ..writeln('发现 $what 的粗体请求（共 ${unexpected.length} 处）：')
    ..writeln()
    ..writeln('内置字体 assets/fonts/zhuzi.ttf 只有 w400 一个字面，')
    ..writeln('请求 w600/w700 时引擎只能描边"合成"：w600/w700 的墨迹比 w400')
    ..writeln('多 51%（比值 1.5124），中文小字因此发虚、笔画粗细不匀。')
    ..writeln()
    ..writeln('这些位置请求了内置字体没有的字重，请改成 w500：')
    ..writeln();
  for (final _Hit hit in unexpected) {
    message
      ..writeln('  ${hit.location}')
      ..writeln('    ${hit.text}');
  }
  message
    ..writeln()
    ..writeln('如果这处加粗确实交给了一个自带真 Bold 字面的字体（例如 Consolas），')
    ..writeln('或者它属于正在并行编辑、本次不动的手尾，请到本文件的 `_allowances`')
    ..writeln('里按"文件 + 行内特征"补一条，并写清理由与什么时候还这笔账；')
    ..writeln('不要直接把这条测试删掉或注释掉。');

  fail(message.toString());
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

void main() {
  test('lib 下不再请求内置字体没有的字重 w600 / w700', () {
    _expectOnlyAllowlisted(_weightRequest, 'FontWeight.w600 / FontWeight.w700');
  });

  test('同一类风险：FontWeight.bold 与 w800 / w900 同样不被请求', () {
    // bold 的数值就是 w700；w800/w900 只会被合成得更糊。
    // 目前一处都没有，所以这条同时也是"新写法不许溜进来"的前置闸门。
    _expectOnlyAllowlisted(
      _weightRequestExtended,
      'FontWeight.bold / w800 / w900',
    );
  });

  test('白名单的判定条件本身有效：能认出从外层 TextSpan 继承来的 Consolas', () {
    // 这条防的是"白名单退化成永远匹配不上的死配置"：真出现违规时它不是被
    // 报出来、而是被静默放过。用一段最小片段验证判定路径，片段形状照抄
    // `log_panel.dart` —— Consolas 写在外层 TextSpan 的 style 上，
    // 挨着 w600 的那层 TextStyle 本身并不写字体，这正是容易判错的地方。
    const String snippet = '''
final TextSpan head = TextSpan(
  style: TextStyle(
    fontFamily: 'Consolas',
    fontFamilyFallback: _mono, fontSize: 11.5,
  ),
  children: <InlineSpan>[
    TextSpan(
      text: '  [info]',
      style: TextStyle(color: levelColor, fontWeight: FontWeight.w600),
    ),
  ],
);
''';

    expect(_weightRequest.hasMatch(snippet), isTrue, reason: '扫描用的正则没匹配上');

    final String context = _fontContextAt(
      snippet,
      snippet.indexOf('FontWeight.w600'),
    );
    expect(
      context,
      contains("fontFamily: 'Consolas'"),
      reason: '没能往上找到外层 TextSpan 的字体声明，Consolas 那条例外就永远不会生效',
    );

    // 反过来也要成立：片段里如果没有 Consolas（也没有等宽的 `_mono` 兜底），
    // 这处 w600 必须被判成违规。
    final String bare = snippet
        .replaceAll("'Consolas'", "'SomeProportionalFont'")
        .replaceAll('_mono', '_otherFallback');
    final String bareContext = _fontContextAt(
      bare,
      bare.indexOf('FontWeight.w600'),
    );
    expect(
      _allowances.first.fontContextPattern!.hasMatch(bareContext),
      isFalse,
      reason: 'Consolas 那条例外的字体上下文条件太松，会把普通合成加粗一起放过',
    );
  });
}
