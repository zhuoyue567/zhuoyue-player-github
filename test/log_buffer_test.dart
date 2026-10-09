import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/diagnostics/log_buffer.dart';

/// debugPrint 替身：只把消息收进列表。
///
/// 断言"原输出仍然保留"必须靠它，而不是真的往控制台刷 ——
/// 刷屏会把测试输出淹掉，而且 CI 里根本没法断言。
class _SpyPrint {
  final List<String> messages = <String>[];

  void call(String? message, {int? wrapWidth}) {
    if (message != null) messages.add(message);
  }
}

void main() {
  group('环形缓冲', () {
    test('默认容量是 2000', () {
      final LogBuffer buffer = LogBuffer();
      expect(buffer.capacity, 2000);
      buffer.dispose();
    });

    test('超出容量后丢弃最旧的，droppedCount 与长度都正确', () {
      final LogBuffer buffer = LogBuffer(capacity: 4);
      for (int i = 1; i <= 6; i++) {
        buffer.add(LogLevel.info, '第 $i 条');
      }

      expect(buffer.entries.length, 4, reason: 'entries 永远不超过容量');
      expect(buffer.droppedCount, 2, reason: '写 6 条、留 4 条，应该丢 2 条');
      // 正序：留下的是最新的 4 条，且第一条是最早留下的那条。
      expect(
        buffer.entries.map((LogEntry e) => e.message).toList(),
        <String>['第 3 条', '第 4 条', '第 5 条', '第 6 条'],
      );
      buffer.dispose();
    });

    test('绕圈多次之后顺序依然正确（cursor 回绕）', () {
      final LogBuffer buffer = LogBuffer(capacity: 3);
      for (int i = 1; i <= 10; i++) {
        buffer.add(LogLevel.info, 'm$i');
      }
      expect(
        buffer.entries.map((LogEntry e) => e.message).toList(),
        <String>['m8', 'm9', 'm10'],
      );
      expect(buffer.droppedCount, 7);
      buffer.dispose();
    });

    test('恰好装满时不算丢弃', () {
      final LogBuffer buffer = LogBuffer(capacity: 3);
      buffer
        ..add(LogLevel.info, 'a')
        ..add(LogLevel.info, 'b')
        ..add(LogLevel.info, 'c');
      expect(buffer.droppedCount, 0);
      expect(buffer.entries.length, 3);
      buffer.dispose();
    });

    test('clear 清空内容但保留 droppedCount', () {
      final LogBuffer buffer = LogBuffer(capacity: 2);
      buffer
        ..add(LogLevel.info, 'a')
        ..add(LogLevel.info, 'b')
        ..add(LogLevel.info, 'c');
      expect(buffer.droppedCount, 1);

      buffer.clear();
      expect(buffer.entries, isEmpty);
      expect(buffer.isEmpty, isTrue);
      // 用户清空的是"现在看到的这些"，"这次会话丢过日志"这件事仍然成立。
      expect(buffer.droppedCount, 1);

      // 清空后还能继续正常写入。
      buffer.add(LogLevel.info, 'd');
      expect(buffer.entries.single.message, 'd');
      buffer.dispose();
    });

    test('entries 返回的是副本，改动它不影响缓冲区', () {
      final LogBuffer buffer = LogBuffer(capacity: 4);
      buffer.add(LogLevel.info, 'a');
      final List<LogEntry> snapshot = buffer.entries;
      snapshot.clear();
      expect(buffer.entries.length, 1);
      buffer.dispose();
    });
  });

  group('tag 解析', () {
    test('解析出首部的方括号前缀', () {
      expect(parseLogTag('[netease] 搜索联想失败，已忽略：x'), 'netease');
      expect(parseLogTag('[audio] 播放事件错误: e'), 'audio');
      expect(parseLogTag('[app] 进程退出'), 'app');
    });

    test('解析不出来就是 null', () {
      expect(parseLogTag('没有前缀的消息'), isNull);
      expect(parseLogTag('[] 空标签'), isNull);
      expect(parseLogTag('不是 [开头] 的前缀'), isNull);
      // 中途才出现的方括号不算前缀。
      expect(parseLogTag('加载 [cover] 失败'), isNull);
    });

    test('stripLogTag 把前缀从消息里摘掉', () {
      expect(
        stripLogTag('[netease] 搜索联想失败').message,
        '搜索联想失败',
        reason: '前缀不能同时留在 tag 和 message 里，否则界面会显示两遍',
      );
      expect(stripLogTag('没有前缀的消息').tag, isNull);
      expect(stripLogTag('没有前缀的消息').message, '没有前缀的消息');
    });

    test('add 之后 entry.tag 已填好、message 里不再带前缀', () {
      final LogBuffer buffer = LogBuffer();
      buffer.add(LogLevel.info, '[player] 已预解析下一首：某首歌');
      expect(buffer.entries.single.tag, 'player');
      expect(buffer.entries.single.message, '已预解析下一首：某首歌');
      buffer.dispose();
    });
  });

  group('多行消息（堆栈）', () {
    test('splitLogMessage 首行做摘要、其余行做 detail', () {
      const String raw =
          '[download] 123 下载失败：连接被重置\n'
          '#0      Foo.bar (package:x/foo.dart:12:3)\n'
          '#1      Baz.qux (package:x/baz.dart:7:1)';
      final ({String message, String? detail}) parts = splitLogMessage(raw);
      expect(parts.message, '[download] 123 下载失败：连接被重置');
      expect(
        parts.detail,
        '#0      Foo.bar (package:x/foo.dart:12:3)\n'
        '#1      Baz.qux (package:x/baz.dart:7:1)',
      );
    });

    test('单行消息没有 detail，且 \\r\\n 会被归一化', () {
      expect(splitLogMessage('只有一行').detail, isNull);
      expect(splitLogMessage('第一行\r\n第二行').message, '第一行');
      expect(splitLogMessage('第一行\r\n第二行').detail, '第二行');
    });

    test('空行作为尾部时 detail 视为没有', () {
      expect(splitLogMessage('第一行\n').detail, isNull);
    });

    test('add 一条多行消息：存成一条 entry，message 只有一行', () {
      final LogBuffer buffer = LogBuffer();
      buffer.add(
        LogLevel.error,
        '[http] 请求失败：超时\n'
        '#0 a\n'
        '#1 b',
      );
      expect(buffer.entries.length, 1);
      final LogEntry entry = buffer.entries.single;
      expect(entry.message, '请求失败：超时');
      expect(entry.detail, '#0 a\n#1 b');
      expect(entry.tag, 'http');
      buffer.dispose();
    });

    test('addDetail 把后续行追加到同一条上', () {
      final LogBuffer buffer = LogBuffer();
      buffer.add(LogLevel.error, '[download] 下载失败：连接被重置');
      buffer.addDetail(LogLevel.error, '堆栈', '#0 foo\n#1 bar');
      buffer.addDetail(LogLevel.error, '更多', '#2 baz');

      expect(buffer.entries.length, 1, reason: '堆栈不该变成新的日志行');
      expect(buffer.entries.single.detail, '#0 foo\n#1 bar\n#2 baz');
      buffer.dispose();
    });

    test('addDetail 在空缓冲区上退化成一条普通日志', () {
      final LogBuffer buffer = LogBuffer();
      buffer.addDetail(LogLevel.error, '摘要', '细节');
      expect(buffer.entries.single.message, '摘要');
      expect(buffer.entries.single.detail, '细节');
      buffer.dispose();
    });
  });

  group('级别推断', () {
    test('中文错误关键字判成 error', () {
      expect(inferLogLevel('[netease] 搜索联想失败，已忽略：x'), LogLevel.error);
      expect(inferLogLevel('[player] 解析播放地址异常'), LogLevel.error);
      expect(inferLogLevel('[cache] 读取错误'), LogLevel.error);
      expect(inferLogLevel('登录过期了，请求返回 401'), LogLevel.debug);
    });

    test('英文关键字大小写不敏感', () {
      expect(inferLogLevel('DioException: connection reset'), LogLevel.error);
      expect(inferLogLevel('ERROR: boom'), LogLevel.error);
      expect(inferLogLevel('request failed'), LogLevel.error);
    });

    test('警告类关键字判成 warning', () {
      expect(inferLogLevel('[http] 请求超时，准备重试'), LogLevel.warning);
      expect(inferLogLevel('[cache] 缓存已损坏，忽略该条目'), LogLevel.warning);
      expect(inferLogLevel('[sync] 警告：同步频率回填失败过'), LogLevel.error);
      expect(inferLogLevel('WARN: retry later'), LogLevel.warning);
    });

    test('普通输出是 debug', () {
      expect(inferLogLevel('[player] 已预解析下一首：某首歌'), LogLevel.debug);
      expect(inferLogLevel('[proxy] 媒体代理已启动'), LogLevel.debug);
    });

    test('error 优先于 warning（同时出现两种措辞时）', () {
      expect(inferLogLevel('超时，请求失败'), LogLevel.error);
    });

    test('addMessage 用推断结果', () {
      final LogBuffer buffer = LogBuffer();
      buffer.addMessage('[player] 预解析下一首失败（忽略）：$StateError');
      expect(buffer.entries.single.level, LogLevel.error);
      buffer.dispose();
    });
  });

  group('filtered', () {
    LogBuffer seeded() {
      final LogBuffer buffer = LogBuffer();
      buffer
        ..add(LogLevel.debug, '[player] 已预解析下一首：晴天')
        ..add(LogLevel.info, '[proxy] 媒体代理已启动')
        ..add(LogLevel.warning, '[http] 请求超时，准备重试')
        ..add(LogLevel.error, '[netease] song/url/v1 失败，改用旧接口');
      return buffer;
    }

    test('minLevel 过滤', () {
      final LogBuffer buffer = seeded();
      expect(buffer.filtered().length, 4);
      expect(buffer.filtered(minLevel: LogLevel.info).length, 3);
      expect(buffer.filtered(minLevel: LogLevel.warning).length, 2);
      expect(buffer.filtered(minLevel: LogLevel.error).length, 1);
      buffer.dispose();
    });

    test('关键字匹配消息，大小写不敏感', () {
      final LogBuffer buffer = seeded();
      expect(buffer.filtered(keyword: '超时').single.level, LogLevel.warning);
      expect(buffer.filtered(keyword: 'STREAM').length, 0);
      expect(buffer.filtered(keyword: 'song/URL').length, 1);
      buffer.dispose();
    });

    test('关键字也匹配 tag 与堆栈 detail', () {
      final LogBuffer buffer = LogBuffer();
      buffer.add(
        LogLevel.error,
        '[download] 下载失败\n#0 SocketException (socket.dart:1:1)',
      );
      buffer.add(LogLevel.info, '[player] 正常输出');

      expect(buffer.filtered(keyword: 'download').length, 1, reason: '匹配 tag');
      expect(
        buffer.filtered(keyword: 'socketexception').length,
        1,
        reason: '匹配 detail',
      );
      buffer.dispose();
    });

    test('minLevel 与 keyword 叠加', () {
      final LogBuffer buffer = seeded();
      expect(
        buffer.filtered(minLevel: LogLevel.warning, keyword: '接口').length,
        1,
      );
      expect(
        buffer.filtered(minLevel: LogLevel.error, keyword: '超时'),
        isEmpty,
      );
      buffer.dispose();
    });

    test('空关键字等于不过滤', () {
      final LogBuffer buffer = seeded();
      expect(buffer.filtered(keyword: '   ').length, 4);
      buffer.dispose();
    });
  });

  group('export', () {
    test('格式为 HH:mm:ss.SSS [级别] [tag] 消息，detail 换行缩进两格', () {
      final LogBuffer buffer = LogBuffer();
      buffer.add(LogLevel.error, '[netease] song/url/v1 失败\n#0 a\n#1 b');
      buffer.add(LogLevel.info, '[proxy] 媒体代理已启动');

      final List<String> lines = buffer.export().split('\n');
      // 第 1 条：消息 + 2 行 detail；第 2 条：消息；末尾换行再拆出一个空串。
      expect(lines.length, 5);

      expect(
        RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[错误\] \[netease\] song/url/v1 失败$')
            .hasMatch(lines[0]),
        isTrue,
        reason: '实际首行：${lines[0]}',
      );
      expect(lines[1], '  #0 a');
      expect(lines[2], '  #1 b');
      expect(
        RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[信息\] \[proxy\] 媒体代理已启动$')
            .hasMatch(lines[3]),
        isTrue,
        reason: '实际第 4 行：${lines[3]}',
      );
      buffer.dispose();
    });

    test('没有 tag 时不留空括号', () {
      final LogBuffer buffer = LogBuffer();
      buffer.add(LogLevel.debug, '没有前缀的消息');
      expect(
        buffer.export().trimRight(),
        matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[调试\] 没有前缀的消息$')),
      );
      buffer.dispose();
    });

    test('按时间正序导出', () {
      final LogBuffer buffer = LogBuffer(capacity: 2);
      buffer
        ..add(LogLevel.info, '第一')
        ..add(LogLevel.info, '第二')
        ..add(LogLevel.info, '第三');
      final String out = buffer.export();
      expect(out.indexOf('第二') < out.indexOf('第三'), isTrue);
      expect(out.contains('第一'), isFalse);
      buffer.dispose();
    });
  });

  group('合并通知', () {
    test('同一窗口内的多次 add 只通知一次', () async {
      final LogBuffer buffer = LogBuffer(
        mergeWindow: const Duration(milliseconds: 20),
      );
      int notifications = 0;
      buffer.addListener(() => notifications++);

      // 模拟刷屏：一次同步流程里连写 50 条。
      for (int i = 0; i < 50; i++) {
        buffer.add(LogLevel.debug, '刷屏 $i');
      }
      expect(notifications, 0, reason: '通知必须异步，不能在 add 里同步触发');
      expect(buffer.entries.length, 50);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(notifications, 1, reason: '50 条日志只应该重建界面一次');
      buffer.dispose();
    });

    test('flushNotification 立刻发通知', () {
      final LogBuffer buffer = LogBuffer(
        mergeWindow: const Duration(seconds: 5),
      );
      int notifications = 0;
      buffer.addListener(() => notifications++);
      buffer.add(LogLevel.debug, 'x');
      buffer.flushNotification();
      expect(notifications, 1);
      buffer.dispose();
    });

    test('dispose 之后不再通知、也不再收日志', () async {
      final LogBuffer buffer = LogBuffer(
        mergeWindow: const Duration(milliseconds: 20),
      );
      int notifications = 0;
      buffer.addListener(() => notifications++);
      buffer.add(LogLevel.debug, 'x');
      buffer.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 60));
      // 定时器被取消，撤销的通知不会到达已经销毁的监听者。
      expect(notifications, 0);
      // add 在 dispose 之后必须是无害的：debugPrint 仍可能在收尾阶段被调用。
      buffer.add(LogLevel.error, '收尾阶段的日志');
      expect(buffer.entries.length, 1);
    });
  });

  group('installLogCapture', () {
    // 这一组用例会真的替换全局 debugPrint。终端换成一个"只记录、不打印"
    // 的替身，测试输出就不会被刷花，同时还能断言"原实现确实被调用了"。
    final _SpyPrint terminal = _SpyPrint();

    setUpAll(() {
      // 把策略短路掉：测试环境本来**故意不装**钩子（见下面那条用例），
      // 但那只是策略；接线本身（幂等、保留原输出、防自环）必须能测，
      // 否则错了也没人知道。
      LogCaptureInstaller.alwaysInstall = true;
      debugPrint = terminal.call;
    });

    tearDownAll(() {
      LogCaptureInstaller.alwaysInstall = false;
    });

    setUp(() {
      terminal.messages.clear();
      debugPrint = terminal.call;
    });

    tearDown(() {
      // 还原成沉默的终端，而不是 debugPrintThrottled：
      // 后面还有用例，任何一个漏网的 debugPrint 都会喷进测试输出。
      debugPrint = terminal.call;
    });

    test('装钩子之后 debugPrint 进缓冲区，并且原实现仍然被调用', () {
      final _SpyPrint spy = _SpyPrint();
      debugPrint = spy.call;

      final LogBuffer buffer = LogBuffer();
      installLogCapture(buffer);
      debugPrint('[netease] song/url/v1 失败，改用旧接口：404');

      expect(buffer.entries.length, 1, reason: '必须捕获到');
      expect(
        buffer.entries.single.level,
        LogLevel.error,
        reason: '级别应该从消息内容推断',
      );
      expect(buffer.entries.single.tag, 'netease');
      expect(spy.messages, <String>['[netease] song/url/v1 失败，改用旧接口：404'],
          reason: '原输出必须保留，否则控制台就什么都看不到了');
      buffer.dispose();
    });

    test('当前这一层不是我们时，日志照样往下传', () {
      final LogBuffer buffer = LogBuffer();
      installLogCapture(buffer);
      // 模拟"别人后装了一层"：此时我们的包装已经不在最外层，
      // 必须把消息交给当前实现，而不是只走安装时记住的终端。
      final _SpyPrint spy = _SpyPrint();
      debugPrint = spy.call;

      debugPrint('[app] 后装的包装也要能收到');
      expect(spy.messages.length, 1);
      buffer.dispose();
    });

    test('多行 debugPrint 拆成 message + detail', () {
      final LogBuffer buffer = LogBuffer();
      installLogCapture(buffer);
      debugPrint('[download] 1 下载失败：连接被重置\n#0 Foo.bar\n#1 Baz.qux');

      expect(buffer.entries.single.message, '1 下载失败：连接被重置');
      expect(buffer.entries.single.tag, 'download');
      expect(buffer.entries.single.detail, '#0 Foo.bar\n#1 Baz.qux');
      buffer.dispose();
    });

    test('幂等：重复安装不会把原实现包成多层', () {
      final _SpyPrint spy = _SpyPrint();

      final LogBuffer first = LogBuffer();
      installLogCapture(first);
      // 假装别人插了一层，然后我们反复重装 —— 无论装几次，
      // 消息都应该只经过一层包装。
      debugPrint = spy.call;
      installLogCapture(first);
      installLogCapture(first);
      debugPrint('[app] 只应该出现一次');

      expect(spy.messages.length, 1, reason: '原实现被调用了多次说明包装叠了层');
      expect(first.entries.length, 1);
      first.dispose();
    });

    test('换成新缓冲区时旧缓冲区不再收到日志', () {
      final LogBuffer first = LogBuffer();
      final LogBuffer second = LogBuffer();
      installLogCapture(first);
      debugPrint('[app] 第一条');
      installLogCapture(second);
      debugPrint('[app] 第二条');

      expect(first.entries.length, 1);
      expect(second.entries.length, 1);
      expect(second.entries.single.message, '第二条');
      expect(second.entries.single.tag, 'app');
      expect(identical(LogCaptureInstaller.buffer, second), isTrue);
      expect(LogCaptureInstaller.installed, isTrue);
      // 重装之后原输出必须还在（沉默终端拿到了两条）。
      expect(terminal.messages.length, 2, reason: '重装不能把控制台输出弄丢');
      first.dispose();
      second.dispose();
    });

    test('debugPrint(null) 不产生日志也不会崩', () {
      final _SpyPrint spy = _SpyPrint();
      debugPrint = spy.call;
      final LogBuffer buffer = LogBuffer();
      installLogCapture(buffer);

      debugPrint(null);
      expect(buffer.entries, isEmpty);
      expect(spy.messages, isEmpty);
      buffer.dispose();
    });
  });

  group('测试环境下的策略', () {
    tearDown(() {
      debugPrint = debugPrintThrottled;
    });

    test('flutter test 能被识别为测试环境', () {
      expect(
        isRunningInTestHarness,
        isTrue,
        reason: '识别不出来就会去替换 debugPrint，然后每个 widget 测试收尾都炸',
      );
    });

    test('测试环境里 installLogCapture 是空操作', () {
      // 测试框架每个用例都会断言 debugPrint == debugPrintThrottled，
      // 所以本模块在 flutter test 里必须主动放弃安装全局钩子 ——
      // 否则任何碰到日志缓冲区的 widget 测试都会在收尾时报
      // "The value of a foundation debug variable was changed by the test"。
      final DebugPrintCallback before = debugPrint;
      final LogBuffer buffer = LogBuffer();
      installLogCapture(buffer);

      expect(identical(debugPrint, before), isTrue, reason: '不能替换 debugPrint');
      expect(isLogCaptureInstalled, isFalse);
      debugPrint('[app] 这条不应该被捕获');
      expect(buffer.entries, isEmpty);
      buffer.dispose();
    });
  });
}
