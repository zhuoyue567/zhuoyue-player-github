import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// 日志级别。顺序**就是**严重程度顺序，界面上的「警告以上」直接靠
/// `index` 比较，不要再自己维护一份映射表。
enum LogLevel {
  debug('调试'),
  info('信息'),
  warning('警告'),
  error('错误');

  const LogLevel(this.label);

  /// 中文标签。界面上只出现这个，[name] 只用于调试与测试断言。
  final String label;
}

/// 一条日志。
///
/// 刻意做成不可变对象：日志一旦进缓冲区就只应该被读，任何"原地修改"
/// 都会让列表重建时的 diff 失去意义（同一个位置换了内容却还是同一个
/// key，界面可能不刷新）。
@immutable
class LogEntry {
  const LogEntry({
    required this.at,
    required this.level,
    required this.message,
    this.tag,
    this.detail,
  });

  /// 记录时刻，仅用于展示与导出排序。
  final DateTime at;

  final LogLevel level;

  /// 摘要行 —— 一定只有一行，否则列表里每行的高度会失控。
  ///
  /// 首部的 `[xxx]` 前缀**已经被剥掉**并存进 [tag]：级别与来源在界面上
  /// 是独立的一小段（自带颜色、可对齐），如果 message 里还留着一份，
  /// 界面上就会变成「[netease] [netease] 消息」。
  final String message;

  /// 从消息首部的 `[xxx]` 前缀解析出来的来源标签，解析不出就是 null。
  final String? tag;

  /// 多行消息（堆栈）的后续行，默认折叠、按需展开。
  final String? detail;
}

/// 把消息首部的 `[xxx]` 前缀解析成来源标签。
///
/// 项目里几十处 `debugPrint('[netease] …')` 已经天然带着这个约定，
/// 与其新增一个"打日志时必须传 tag"的 API（旧调用点全都拿不到 tag），
/// 不如直接把既有约定读出来。
///
/// 只认**第一个**方括号，且标签里不允许再出现方括号 —— 否则
/// `[a][b] 消息` 会被整段吞掉，展示时很难看。
String? parseLogTag(String message) {
  if (!message.startsWith('[')) return null;
  final int end = message.indexOf(']');
  if (end <= 1) return null;
  final String tag = message.substring(1, end);
  if (tag.contains('[')) return null;
  return tag;
}

/// 解析出标签后把前缀从消息里剥掉。
///
/// 只剥第一个前缀。`[a][b] 消息` 会得到 tag=a、message=`[b] 消息`：
/// 项目里没有嵌套标签的写法，多做一层解析只会增加猜错的机会。
({String message, String? tag}) stripLogTag(String message) {
  final String? tag = parseLogTag(message);
  if (tag == null) return (message: message, tag: null);
  final int end = message.indexOf(']');
  return (message: message.substring(end + 1).trimLeft(), tag: tag);
}

/// 从消息内容推断级别。
///
/// 是个纯函数，单独拿出来既是为了能直接测，也是为了说明一件事：
/// **这是启发式推断，不是事实**。项目里的 debugPrint 没有级别参数，
/// 我们能做的只是从措辞里读出意图。宁可把「失败/异常」判成 error、
/// 其余一律 debug，也不要为了好看强行分级 —— 判错级别比不判更误导人。
LogLevel inferLogLevel(String message) {
  final String lower = message.toLowerCase();

  // 英文关键字用大小写不敏感匹配：日志里 Error / ERROR / error 都出现过。
  const List<String> errorMarkers = <String>[
    '失败',
    '错误',
    '异常',
    'error',
    'exception',
    'failed',
    'failure',
  ];
  for (final String marker in errorMarkers) {
    if (lower.contains(marker)) return LogLevel.error;
  }

  const List<String> warningMarkers = <String>[
    '警告',
    '超时',
    '忽略',
    '跳过',
    '退避',
    'warn',
    'timeout',
  ];
  for (final String marker in warningMarkers) {
    if (lower.contains(marker)) return LogLevel.warning;
  }

  return LogLevel.debug;
}

/// 把多行消息拆成"摘要 + 堆栈"。
///
/// 只按 `\n` 拆（先把 `\r\n` 归一化），保留空行 —— 堆栈里的空行本身
/// 就是结构的一部分，顺手 `where(isNotEmpty)` 会让堆栈变得难读。
({String message, String? detail}) splitLogMessage(String raw) {
  final List<String> lines = raw.replaceAll('\r\n', '\n').split('\n');
  final String message = lines.first.trimRight();
  if (lines.length == 1) {
    return (message: message, detail: null);
  }
  final String detail = lines.skip(1).join('\n').trimRight();
  return (message: message, detail: detail.isEmpty ? null : detail);
}

/// 应用内日志缓冲区：环形缓冲 + 合并通知。
///
/// 为什么是环形缓冲：日志面板的价值在于"最近发生了什么"，
/// 而刷屏（下载进度、HTTP 重试）随时可能一秒来上百条。用普通 List
/// 存着再 `removeAt(0)` 是 O(n) 的搬移，日志越多越卡 —— 正好在
/// 最需要它流畅的时候拖慢整个应用。固定长度的环形数组写入永远是 O(1)。
///
/// 为什么通知要合并：`add` 可能在**任意时刻**被调用，包括一帧的
/// build 过程中（`debugPrint` 就可能在 build 里被触发）。此时同步
/// `notifyListeners()` 会让监听者（ListenableBuilder）在 build 期间
/// 再次 setState，Flutter 直接抛错。所以通知一律推迟到微任务之后的
/// 定时器里，并且窗口期内只排一次 —— 刷屏时界面每 120ms 才重建一次，
/// 而不是每条日志重建一次。
class LogBuffer extends ChangeNotifier {
  LogBuffer({this.capacity = 2000, Duration? mergeWindow})
    : _mergeWindow = mergeWindow ?? const Duration(milliseconds: 120) {
    assert(capacity > 0);
    _slots = List<LogEntry?>.filled(capacity, null);
  }

  /// 最多保留多少条。超出后丢弃最旧的。
  final int capacity;

  /// 合并通知的时间窗口。测试里可以调小到 0 附近的量级。
  final Duration _mergeWindow;

  late List<LogEntry?> _slots;

  /// 下一个写入位置。缓冲区满了之后它会绕回 0 并覆盖最旧的一条。
  int _cursor = 0;
  int _length = 0;
  int _dropped = 0;

  Timer? _notifyTimer;
  bool _disposed = false;
  int _revision = 0;

  /// 被丢弃（因为超过 [capacity]）的条数，用来在界面上说明
  /// 「更早的日志已被丢弃」。不清零 —— 清空缓冲区是用户主动行为，
  /// 但他仍然应该知道这次会话里丢过东西。
  int get droppedCount => _dropped;

  int get length => _length;

  bool get isEmpty => _length == 0;

  /// 当前缓冲区的内容版本号。界面用它来避免"通知到了但内容没变"的
  /// 无谓重建（例如只改了过滤条件）。
  int get revision => _revision;

  /// 按时间正序的日志。返回的是**新列表**（元素本身不可变），
  /// 调用方随便存、随便排序都不会影响缓冲区。
  ///
  /// 刻意返回可增长的 List：调用方（界面）会拿它做 `.toList()`、
  /// `..sort()` 之类的加工，扔回来一个定长 List 只会让这些操作
  /// 在意想不到的地方抛 "Cannot clear a fixed-length list"。
  List<LogEntry> get entries {
    return List<LogEntry>.generate(
      _length,
      (int i) => _slots[_slotAt(i)]!,
    );
  }

  /// 逻辑下标 i（0 = 最旧）对应的物理槽位。
  int _slotAt(int i) {
    final int start = _length == capacity ? _cursor : 0;
    return (start + i) % capacity;
  }

  /// 写入一条日志，级别由调用方明确给出。
  ///
  /// [message] 里的换行会被拆成 detail，首部的 `[xxx]` 会被拆成 tag。
  /// 只有字符串（例如来自 debugPrint）时用 [addMessage]，由它去推断级别。
  void add(LogLevel level, String message) {
    if (_disposed) return;
    final ({String message, String? detail}) parts = splitLogMessage(message);
    final ({String message, String? tag}) tagged = stripLogTag(parts.message);
    _push(
      LogEntry(
        at: DateTime.now(),
        level: level,
        message: tagged.message,
        tag: tagged.tag,
        detail: parts.detail,
      ),
    );
  }

  /// 追加多行堆栈：第一条是摘要，后续行作为 [detail] 追加到同一条上。
  ///
  /// 分成两次调用是刻意的 —— 调用点通常先 `debugPrint` 摘要、
  /// 再 `debugPrint` 堆栈，两条在面板里应该读成一条。
  void addDetail(LogLevel level, String message, String detail) {
    if (_disposed) return;
    final LogEntry? last = _length == 0 ? null : _slots[_slotAt(_length - 1)];
    if (last == null) {
      // 还没有任何日志时，"追加细节"没有可挂靠的条目，退化成一条普通日志。
      add(level, '$message\n$detail');
      return;
    }
    final String trimmed = detail.trimRight();
    if (trimmed.isEmpty) return;
    final String merged = last.detail == null || last.detail!.isEmpty
        ? trimmed
        : '${last.detail}\n$trimmed';
    _slots[_slotAt(_length - 1)] = LogEntry(
      at: last.at,
      level: last.level,
      message: last.message,
      tag: last.tag,
      detail: merged,
    );
    _revision++;
    _scheduleNotify();
  }

  /// 用一个"字符串消息"写入，级别由 [inferLogLevel] 推断。
  ///
  /// 这是 [installLogCapture] 的落点：debugPrint 只有字符串、没有级别，
  /// 只能推断。要给准确的级别就用 [add]。
  void addMessage(String message) => add(inferLogLevel(message), message);

  void _push(LogEntry entry) {
    if (_length == capacity) {
      // 覆盖最旧的一条：cursor 指向的就是它。
      _dropped++;
    } else {
      _length++;
    }
    _slots[_cursor] = entry;
    _cursor = (_cursor + 1) % capacity;
    _revision++;
    _scheduleNotify();
  }

  /// 清空所有日志，但**不清零** [droppedCount]：用户想知道的
  /// "这次会话里有没有日志被挤掉"不应该因为一次清空就失忆。
  void clear() {
    for (int i = 0; i < capacity; i++) {
      _slots[i] = null;
    }
    _cursor = 0;
    _length = 0;
    _revision++;
    _scheduleNotify();
  }

  /// 过滤。[minLevel] 是"最低严重程度"，[keyword] 大小写不敏感地
  /// 匹配消息、tag 与 detail 三处 —— 用户搜"播放不了"时既可能
  /// 命中消息，也可能命中堆栈里的异常类名。
  List<LogEntry> filtered({LogLevel? minLevel, String? keyword}) {
    final String needle = (keyword ?? '').trim().toLowerCase();
    final List<LogEntry> result = <LogEntry>[];
    for (int i = 0; i < _length; i++) {
      final LogEntry entry = _slots[_slotAt(i)]!;
      if (minLevel != null && entry.level.index < minLevel.index) continue;
      if (needle.isNotEmpty && !_matches(entry, needle)) continue;
      result.add(entry);
    }
    return result;
  }

  static bool _matches(LogEntry entry, String needle) {
    if (entry.message.toLowerCase().contains(needle)) return true;
    final String? tag = entry.tag;
    if (tag != null && tag.toLowerCase().contains(needle)) return true;
    final String? detail = entry.detail;
    return detail != null && detail.toLowerCase().contains(needle);
  }

  /// 导出成纯文本，供「复制全部」使用。
  ///
  /// 每行 `HH:mm:ss.SSS [级别] [tag] 消息`；有 detail 就换行、缩进两格。
  /// 不带日期：日志面板是**本次会话**的调试窗口，日期只会把行读散；
  /// 真要长时间留档，用户复制出去后自己会贴上时间上下文。
  String export() {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < _length; i++) {
      final LogEntry entry = _slots[_slotAt(i)]!;
      out.write(_formatTime(entry.at));
      out.write(' [${entry.level.label}] ');
      final String? tag = entry.tag;
      if (tag != null) out.write('[$tag] ');
      out.write(entry.message);
      out.write('\n');
      final String? detail = entry.detail;
      if (detail != null && detail.isNotEmpty) {
        for (final String line in detail.split('\n')) {
          out.write('  $line');
          out.write('\n');
        }
      }
    }
    return out.toString();
  }

  static String _formatTime(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${three(at.millisecond)}';
  }

  /// 合并通知：窗口期内重复调用只排一次定时器。
  ///
  /// 用 `Timer`（而不是 `scheduleMicrotask`）是因为微任务仍然可能落在
  /// 同一次 build 的同步流程里（例如 build 里连续 add 之后再 addPostFrame），
  /// 而定时器一定会回到事件循环顶部，天然躲开"build 期间 setState"。
  void _scheduleNotify() {
    if (_disposed || _notifyTimer != null) return;
    _notifyTimer = Timer(_mergeWindow, () {
      _notifyTimer = null;
      if (_disposed) return;
      notifyListeners();
    });
  }

  /// 立刻把待发的通知发出去（例如面板刚打开、退出前需要一次最终刷新）。
  void flushNotification() {
    if (_disposed) return;
    final Timer? timer = _notifyTimer;
    if (timer == null) return;
    timer.cancel();
    _notifyTimer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    super.dispose();
  }
}

/// 已经被装上钩子的缓冲区。
///
/// 用模块级变量而不是"检查 debugPrint 是不是我们的闭包"：闭包无法可靠
/// 自省，而幂等性必须可靠 —— 每次打开日志面板都包一层，
/// 控制台就会被同一批日志刷 N 遍。
LogBuffer? _capturedBuffer;

/// `debugPrint` 当前的值中，我们自己那一层的位置。
///
/// 别的代码也可能替换 debugPrint（Flutter 自己的 debugPrintOverride、
/// 测试框架等）。如果它被换掉了，我们的包装就不在最外层，再安装时必须
/// **重新包一层**，否则那些日志就漏掉了。
DebugPrintCallback? _installMarker;

/// 真正把字打出去的那一层，安装钩子时记下来。
DebugPrintCallback? _terminalPrint;

/// 当前是否跑在测试环境里。
///
/// 存在的理由：**测试框架会把"全局 debugPrint 被换掉"当成失败**。
/// `TestWidgetsFlutterBinding._verifyInvariants` 每个用例结束都会检查
/// `debugPrint == debugPrintThrottled`，所以只要有 widget 测试碰到了
/// 日志缓冲区（例如"从维护分区打开日志面板"），钩子一装就会在用例尾部
/// 抛 "The value of a foundation debug variable was changed by the test"。
///
/// 那个检查是合理的（它在保护测试自己的输出通道），我们不该去绕它。
/// 生产环境（`flutter run` / 正式包）读不到这些变量，钩子照常安装。
bool get isRunningInTestHarness {
  try {
    final Map<String, String> env = Platform.environment;
    return env['FLUTTER_TEST'] == 'true' ||
        (env['DART_TEST_CONFIG']?.isNotEmpty ?? false);
  } on Object {
    // 拿不到环境变量（受限平台）时按"不是测试"处理：
    // 宁可多装一次钩子，也不要让正常运行的日志收集失效。
    return false;
  }
}

/// 把应用里所有 debugPrint 都收进缓冲区，**同时保留原输出**。
///
/// 用替换全局 `debugPrint` 的方式而不是逐个改调用点：项目里已经有几十处
/// debugPrint，逐个改既容易漏、也会让"加日志"这件事变成负担。
///
/// 两点必须做对：
/// 1. **一定调用原实现**。丢掉原输出等于把控制台变成空的，
///    而控制台恰恰是开发时最直接的输出 —— 收集日志不能以牺牲它为代价。
/// 2. **幂等**。重复安装只换缓冲区，不会在原实现外面再包一层。
///
/// 这个函数只管**策略**（什么时候该装），真正的接线交给
/// [LogCaptureInstaller.install]，后者可以脱离策略单独测。
void installLogCapture(LogBuffer buffer) {
  if (LogCaptureInstaller.alwaysInstall == false &&
      (kDebugMode == false || isRunningInTestHarness)) {
    // 测试环境不装：见 [isRunningInTestHarness]。
    return;
  }
  LogCaptureInstaller.install(buffer);
}

/// debugPrint 钩子的接线方式。
///
/// 单独抽出来是为了把两件事分开：
/// - `installLogCapture` 负责**策略**（测试里不装、release 不装）；
/// - `LogCaptureInstaller.install` 负责**机制**（幂等、保留原输出、防自环）。
///
/// 否则机制的正确性就只能在"假装自己不是测试"的前提下才测得到，
/// 而那恰好是最容易把生产行为改坏的测法。
abstract final class LogCaptureInstaller {
  /// 当前是否已经装上了捕获钩子。
  static bool get installed => identical(_installMarker, debugPrint);

  /// 已经捕获进去的缓冲区，没装就是 null。
  static LogBuffer? get buffer => _capturedBuffer;

  /// 仅供测试：把 [installLogCapture] 的策略短路掉，用来验证接线本身。
  ///
  /// 命名带 `debug` 前缀是 Flutter 的惯例（这类开关不会出现在 release 里）。
  @visibleForTesting
  static bool alwaysInstall = false;

  /// 真正替换全局 debugPrint，并让原实现继续收到消息。
  static void install(LogBuffer buffer) {
    _capturedBuffer = buffer;
    if (installed) {
      // 已经装过：只换目标缓冲区，_capturePrint 每次现读 `_capturedBuffer`，
      // 天然指向新缓冲区。
      return;
    }
    // 每当我们**重新成为最外层**时，重记一次"真实输出"。
    //
    // 为什么需要重记：如果这期间别人把 debugPrint 换成了它自己的一层
    // （调试器、zone 收集器），我们重新安装时那一层已经不在链上了。
    // 继续沿用更早记下的实现，等于把之后所有日志偷偷改道到旧的目的地 ——
    // 表现为"重装之后控制台反而什么都看不到"。
    //
    // 但如果当前最外层**就是我们自己**（把钩子换到另一个缓冲区），
    // 就绝不能重记：那样 `_terminalPrint` 会指向 `_capturePrint`，
    // 兜底那一跳立刻变成自己调自己。
    if (!identical(debugPrint, _capturePrint)) {
      _terminalPrint = debugPrint;
    }
    debugPrint = _capturePrint;
    _installMarker = _capturePrint;
  }
}

/// 当前是否已经装上了捕获钩子。
///
/// 测试环境恒为 false（策略上不装），所以它同时也能用来断言
/// "测试里不应该装钩子"。
bool get isLogCaptureInstalled =>
    !isRunningInTestHarness && LogCaptureInstaller.installed;

void _capturePrint(String? message, {int? wrapWidth}) {
  if (message != null) {
    // 级别先推断，再拆行：推断看的是整条消息（首行通常就带着"失败"），
    // 拆行只是为了让界面每行高度稳定。
    _capturedBuffer?.addMessage(message);
  }

  // 继续往下传，**必须**保证控制台仍然能看到日志。
  //
  // 优先调用"当前"的 debugPrint：这样别人后装的包装（调试器、测试替身、
  // zone 里的收集器）也能收到；只有当它绕回我们自己的时候才回退到
  // 安装时记下的终端实现 —— 否则就是自己调自己，直接爆栈。
  if (identical(debugPrint, _capturePrint)) {
    _terminalPrint?.call(message, wrapWidth: wrapWidth);
    return;
  }
  debugPrint(message, wrapWidth: wrapWidth);
}

/// 已经装上的缓冲区，没装就是 null。
///
/// 与 `LogCaptureInstaller.buffer` 是同一个值；保留这个更短的名字是因为
/// 「现在到底有没有人在收日志」是排查时最常问的一句话，值得一个直接的入口。
LogBuffer? get capturedLogBuffer => _capturedBuffer;
