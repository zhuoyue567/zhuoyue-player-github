import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/runtime/embedded_netease_api.dart';
import 'package:zhuoyue_player/core/runtime/runtime_installer.dart';
import 'package:zhuoyue_player/core/storage/preferences.dart';
import 'package:zhuoyue_player/core/storage/storage_paths.dart';
import 'package:zhuoyue_player/features/onboarding/onboarding_page.dart';
import 'package:zhuoyue_player/features/onboarding/onboarding_providers.dart';

import 'support/in_memory_storage_io.dart';

/// 首启引导页的行为钉子。
///
/// 这个功能只有三条硬要求，但三条都"错了就很难受"：
///  1. **只出现一次** —— 包括"跳过"也算走过。漏了标记就是每次启动都被拦一次；
///  2. **随时能走** —— 下载失败、目录不可写、不登录，都不许变成死路；
///  3. **不许撒谎** —— 总大小未知时不能说一个编出来的百分比，失败原因要用
///     下载器自己写好的那句话。
///
/// 全部离线跑：下载器、运行时目录、存储路径三个外部世界都从 Provider 注入
/// （见 onboarding_providers.dart 顶部的说明），所以这里不会联网、
/// 也不会真的去下 121MB 的运行时或读那个 17MB 的字体。
///
/// ## 这个文件里最容易踩的坑（已经踩过四轮，别再走回头路）
///
/// `testWidgets` 的**测试体整体**跑在 `fake_async` 的假时钟里，而**真实异步
/// I/O 的 future 永远不会完成** —— 事件循环不前进，I/O 回来的那一刻永远不到。
/// 表现是**零输出挂死**：没有失败、没有汇总，连 `--timeout` 都不触发
/// （假时钟不前进，超时定时器也没机会跑）。
///
/// 所以这个文件里满足两条规矩：
///  * **不用 `pumpAndSettle()`**：它的语义是"反复 pump 直到没有待处理帧"，
///    默认超时 **10 分钟**。屏幕上只要有一个不确定的动画（不确定进度条、
///    持续的过渡），它就永远不会 settle，表现为挂死几十分钟而不是失败。
///    用下面的 [settle] 固定推进 600ms 的假时钟，它永远不会挂。
///  * **测试体里不做真实异步 I/O**：不只是被测代码，**连测试自己的准备代码
///    也算**。最后一处挂起就是测试体里的 `await Directory.create()` ——
///    它比 `pumpWidget` 还早三行，照样把整个用例挂在那里。
///    准备阶段一律用 `...Sync()`（`createTempSync` / `createSync` /
///    `deleteSync`）；被测代码的磁盘动作走注入的
///    `test/support/in_memory_storage_io.dart`。
///    （`await prefs.setString()` 是安全的：`setMockInitialValues` 装的是
///    纯内存 store，不经过平台通道。）
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 假安装器成功时会往"内嵌服务"里登记运行时目录（静态状态）。
    // 用例之间不该互相看见对方登记过什么。
    EmbeddedNeteaseApi.resetRegisteredRuntimeDirectories();
  });

  /// 一份偏好实例。[values] 用来摆"用户在这台机器上早就设过什么"的场景。
  ///
  /// `setMockInitialValues` 必须在 `getInstance()` **之前**调用（它会把单例
  /// 置空并换掉底层 store），所以这里给的是"初值"，而不是"事后改一个键" ——
  /// 这正好也更接近真实：应用是在启动时读一次偏好的。
  Future<SharedPreferences> newPrefs([Map<String, Object>? values]) {
    SharedPreferences.setMockInitialValues(values ?? <String, Object>{});
    return SharedPreferences.getInstance();
  }

  /// `AppTitleBar` 的 `initState` 会问一次窗口是否最大化。
  /// 测试环境没有平台实现，不接管这个方法通道的话那次调用会以
  /// `MissingPluginException` 收场 —— 一条与本测试目的完全无关的异步失败
  /// （title_bar_test.dart 里是同样的做法）。
  void mockWindowManager(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async {
        if (call.method == 'isMaximized') return false;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
  }

  /// 造一个真假运行时目录。
  ///
  /// [ready] 为 true 时把两个必需文件写进去（`RuntimeInstaller.hasUsableRuntime`
  /// 只看它们在不在），于是"已就绪"这条路径可以用真实文件系统验，
  /// 而不必去碰 path_provider（单元测试里没有它的平台通道）。
  ///
  /// **同步**建、**同步**清：这是测试体里的真实 I/O，异步的话整个用例会挂在
  /// 假时钟上（见文件顶部说明）。它只是"假装盘上有一套运行时"，同步做完完全够。
  Directory createRuntimeDir({required bool ready}) {
    final Directory dir = Directory.systemTemp.createTempSync(
      'zhy_onboarding_runtime_',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    if (ready) {
      for (final String relative in RuntimeInstaller.requiredRelativePaths) {
        final File file = File(
          '${dir.path}${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}',
        );
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('stub');
      }
    }
    return dir;
  }

  /// 测试里"发布时配置好的"那份下载源。
  ///
  /// 真实构建里 [kRuntimeArchiveUrl] 是 null（发布时才会填），所以下载这条
  /// 路径在测试里必须自己给一份假配置 —— 这也是"地址只在一处"的好处：
  /// 测试注入的就是发布时要改的那一处。
  const String testArchiveUrl = 'https://example.invalid/runtime-merged.zip';
  // 64 位十六进制的假校验和（下载器会按这个形状校验，形状不对会直接抛）。
  const String testArchiveSha =
      '00000000000000000000000000000000'
      '00000000000000000000000000000000';
  const RuntimeArchiveConfig testArchiveConfig = RuntimeArchiveConfig(
    url: testArchiveUrl,
    sha256: testArchiveSha,
  );

  /// 一套"完全注入"的 StoragePaths：环境变量、**文件系统**、临时目录、
  /// 支持目录全部由测试决定。于是默认值可预测，也不会在开发机的 %APPDATA%
  /// 下留东西，更不会去碰 path_provider（单元测试里没有它的平台通道）。
  ///
  /// **文件系统必须是内存实现**：`testWidgets` 跑在 `fake_async` 的假时钟里，
  /// 真实异步 I/O 的 future 永远不会完成 —— 引导页的第 3 步（存放位置）会调
  /// `ensureDirectory` / `adoptInstallerChoicesIfNeeded`，只要其中任何一次落回
  /// 真实磁盘，这个文件就会再一次"零输出挂死"（连 `--timeout` 都不触发）。
  /// 换成内存实现之后，`_supportDirectory` / `_tempDirectory` / `_prefs` 之外
  /// 已经没有任何真实 I/O 入口了。
  StoragePaths testStoragePaths(SharedPreferences prefs, Directory root) {
    return StoragePaths(
      preferences: prefs,
      environment: (String name) => <String, String>{
        'APPDATA': root.path,
        'LOCALAPPDATA': root.path,
        'USERPROFILE': root.path,
      }[name],
      supportDirectory: () async =>
          Directory('${root.path}${Platform.pathSeparator}support'),
      installerFileDirectory: Directory(
        '${root.path}${Platform.pathSeparator}installer',
      ),
      tempDirectory: () async => root,
      // 磁盘被整体换掉：测试里不该有任何真实文件系统调用。
      io: InMemoryStorageFileIo(),
    );
  }

  /// 造一个临时根目录并据此给出一套注入版 [StoragePaths]。
  ///
  /// 同步建、同步清：理由同 [createRuntimeDir]。
  StoragePaths defaultTestStoragePaths(SharedPreferences prefs) {
    final Directory root = Directory.systemTemp.createTempSync(
      'zhy_onboarding_paths_',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return testStoragePaths(prefs, root);
  }

  /// 测试用的下载器：把"字节从哪来"整段换掉。
  ///
  /// 真实 `RuntimeInstaller` 的可测性设计是"字节来源走注入的
  /// [RuntimeStreamOpener]"，这里直接在更外面一层替换掉 `ensureInstalled`，
  /// 于是连"下载一百多 MB"这件事本身都不会发生。
  Future<void> pumpGate(
    WidgetTester tester, {
    required SharedPreferences prefs,
    required Directory runtimeDirectory,
    RuntimeInstaller? installer,
    StoragePaths? storagePaths,
    RuntimeArchiveConfig archiveConfig = testArchiveConfig,
  }) async {
    mockWindowManager(tester);

    // 存储路径**永远**是注入的：默认实例会去读 path_provider，
    // 并在真实的 %APPDATA% 下建目录 —— 单元测试不该有这种副作用。
    final StoragePaths paths = storagePaths ?? defaultTestStoragePaths(prefs);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          runtimeDirectoryProvider.overrideWith(
            (Ref ref) async => runtimeDirectory,
          ),
          // 默认塞一个"被调用就是测试写错了"的安装器：任何用例都不会
          // 真的联网下载。
          runtimeInstallerProvider.overrideWithValue(
            installer ?? _FakeRuntimeInstaller(_unexpectedDownload),
          ),
          // 下载源：测试里给一份假地址（真实构建默认是 null，见常量注释）。
          runtimeArchiveConfigProvider.overrideWithValue(archiveConfig),
          storagePathsProvider.overrideWithValue(paths),
        ],
        // child 是"主界面"的替身。真实的 AppShell 要拉起 window_manager、
        // 播放器与内嵌服务一大串东西，而这条用例要验的是**门槛有没有拦住它**，
        // 用一个能被 finder 精确认出来的占位 widget 更准也更稳。
        child: const OnboardingGate(child: _MainShellStub()),
      ),
    );
    await settle(tester);
  }

  testWidgets('首次运行显示引导页，而不是直接进主界面', (WidgetTester tester) async {
    final SharedPreferences prefs = await newPrefs();
    await pumpGate(
      tester,
      prefs: prefs,
      runtimeDirectory: createRuntimeDir(ready: true),
    );

    expect(find.text('欢迎使用卓越播放器'), findsOneWidget);
    expect(find.text('主界面占位'), findsNothing, reason: '第一次运行不该直接进主界面');
    expect(find.widgetWithText(FilledButton, '开始'), findsOneWidget);
    // 还没走过，什么都不该写进偏好。
    expect(prefs.getString(kOnboardingCompletedKey), isNull);
  });

  testWidgets('走完五步：写标记，第二次启动不再出现', (WidgetTester tester) async {
    final SharedPreferences prefs = await newPrefs();
    final Directory runtime = createRuntimeDir(ready: true);
    await pumpGate(tester, prefs: prefs, runtimeDirectory: runtime);

    await tester.tap(find.text('开始'));
    await settle(tester);
    // 第 2 步：运行时已就绪，不需要点任何东西。
    expect(find.text('准备运行组件'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('存放位置'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('登录（可跳过）'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('可以开始听了'), findsOneWidget);

    await tester.tap(find.text('开始使用'));
    await settle(tester);

    expect(find.text('主界面占位'), findsOneWidget, reason: '完成引导后应当进入应用');
    expect(prefs.getString(kOnboardingCompletedKey), kOnboardingFlowVersion);

    // 第二次启动：同一份偏好下重新建一棵树（等价于重建 ProviderContainer）。
    await pumpGate(tester, prefs: prefs, runtimeDirectory: runtime);
    expect(find.text('主界面占位'), findsOneWidget);
    expect(find.text('欢迎使用卓越播放器'), findsNothing, reason: '引导只出现一次');
  });

  testWidgets('中途跳过也写标记，第二次启动不再出现', (WidgetTester tester) async {
    final SharedPreferences prefs = await newPrefs();
    final Directory runtime = createRuntimeDir(ready: false);
    await pumpGate(tester, prefs: prefs, runtimeDirectory: runtime);

    // 每一步都能退出引导：先走到第 2 步确认入口还在。
    await tester.tap(find.text('开始'));
    await settle(tester);
    expect(find.text('跳过引导'), findsOneWidget, reason: '第二步也要能退出引导');

    await tester.tap(find.text('跳过引导'));
    await settle(tester);

    expect(find.text('主界面占位'), findsOneWidget);
    expect(
      prefs.getString(kOnboardingCompletedKey),
      kOnboardingFlowVersion,
      reason: '跳过也必须写标记，否则每次启动都被拦一次',
    );

    await pumpGate(tester, prefs: prefs, runtimeDirectory: runtime);
    expect(find.text('主界面占位'), findsOneWidget);
    expect(find.text('欢迎使用卓越播放器'), findsNothing);
  });

  testWidgets('运行时已就绪时，那一步不要求用户点下载', (WidgetTester tester) async {
    final SharedPreferences prefs = await newPrefs();
    await pumpGate(
      tester,
      prefs: prefs,
      runtimeDirectory: createRuntimeDir(ready: true),
    );

    await tester.tap(find.text('开始'));
    await settle(tester);

    expect(find.text('运行组件已就绪'), findsOneWidget);
    expect(find.textContaining('正在检查'), findsNothing);
    expect(
      find.widgetWithText(FilledButton, '下载运行组件'),
      findsNothing,
      reason: '已经装好了就不该再让用户点一次没必要的下载',
    );
    expect(find.widgetWithText(FilledButton, '重试下载'), findsNothing);
  });

  testWidgets('下载失败：显示可操作的失败原因，并且仍然能继续', (WidgetTester tester) async {
    final SharedPreferences prefs = await newPrefs();
    final _FakeRuntimeInstaller installer = _FakeRuntimeInstaller((
      {required Uri? archiveUrl,
      required String? expectedSha256,
      required RuntimeProgressCallback? onProgress,
      required RuntimeCancelSignal? cancelSignal}) async {
      // 抛的是下载器自己的失败类型：文案由它写好，界面原样显示。
      throw const RuntimeNetworkException('无法连接下载服务器：测试里刻意失败');
    });

    await pumpGate(
      tester,
      prefs: prefs,
      runtimeDirectory: createRuntimeDir(ready: false),
      installer: installer,
    );
    await tester.tap(find.text('开始'));
    await settle(tester);

    expect(find.text('还没有安装运行组件'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '下载运行组件'));
    await settle(tester);

    // 1) 失败原因原样显示（用的是下载器的 message，不是另编的一句）。
    expect(find.textContaining('无法连接下载服务器：测试里刻意失败'), findsOneWidget);
    // 2) 重试是明确的、可操作的。
    expect(find.widgetWithText(FilledButton, '重试下载'), findsOneWidget);
    // 3) 没有卡死：告知可以直接往下走，而且真的能走。
    expect(find.textContaining('也可以直接点「下一步」'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('存放位置'), findsOneWidget);
  });

  testWidgets('总大小未知时如实显示"未知"，不编一个百分比，并证明装完即可用', (
    WidgetTester tester,
  ) async {
    final SharedPreferences prefs = await newPrefs();
    final Directory runtime = createRuntimeDir(ready: false);
    final Completer<void> hold = Completer<void>();
    // 下载器收到的"源"要原样是配置里那一份 —— 地址只在一处配置，
    // 这里顺带把它钉住（改错了会立刻红，而不是等到发布后下不动才发现）。
    Uri? seenUrl;
    String? seenSha;

    final _FakeRuntimeInstaller installer = _FakeRuntimeInstaller((
      {required Uri? archiveUrl,
      required String? expectedSha256,
      required RuntimeProgressCallback? onProgress,
      required RuntimeCancelSignal? cancelSignal}) async {
      seenUrl = archiveUrl;
      seenSha = expectedSha256;
      // Content-Length 缺失：total 就是 null。
      onProgress?.call(1024 * 1024, null);
      await hold.future;
      // 成功的下载会真的把文件写到 runtime 目录里；测试里用桩文件
      // 代替（hasUsableRuntime 只看那两个必需文件在不在）。
      for (final String relative in RuntimeInstaller.requiredRelativePaths) {
        final File file = File(
          '${runtime.path}${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}',
        );
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('stub');
      }
      return RuntimeInstallResult(
        directory: runtime,
        alreadyInstalled: false,
        receivedBytes: 1024 * 1024,
      );
    });

    await pumpGate(
      tester,
      prefs: prefs,
      runtimeDirectory: runtime,
      installer: installer,
    );
    await tester.tap(find.text('开始'));
    await settle(tester);

    // 登记之前，这个临时目录当然不在运行时的搜索路径里
    //（它是唯一的，所以"出现在路径里"只可能来自下载成功那一刻的登记）。
    expect(
      EmbeddedNeteaseApi.resolveSearchPaths(),
      isNot(contains(runtime.path)),
      reason: '还没下载时它不该在搜索路径里，否则后面的断言证明不了什么',
    );

    await tester.tap(find.widgetWithText(FilledButton, '下载运行组件'));
    // 不用 pumpAndSettle：下载中的不确定进度条永远不会"settle"。
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('总大小未知'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing, reason: '总大小未知时不许显示百分比');
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(
      bar.value,
      isNull,
      reason: '总大小未知时要走"不确定"进度条，而不是一个假的确定值',
    );

    // 放行之后仍然会正常收尾（这条同时证明"下载中"不是死状态）。
    hold.complete();
    await settle(tester);
    expect(find.text('运行组件已就绪'), findsOneWidget);

    // 源确实来自"那一处"配置。
    expect(seenUrl, Uri.parse(testArchiveUrl));
    expect(seenSha, testArchiveSha);

    // 装完之后同一进程内应当立刻认得这个运行时（不必重启）：
    //  * 磁盘上它确实是一套可用的运行时；
    //  * 它已经被登记进运行时的搜索路径（内嵌服务找运行时用的就是这份列表）。
    expect(RuntimeInstaller.hasUsableRuntime(runtime), isTrue);
    expect(
      EmbeddedNeteaseApi.resolveSearchPaths(),
      contains(runtime.path),
      reason: '下载成功必须登记确切路径，否则这次运行里仍然被认为"没有运行时"',
    );
  });

  testWidgets('没有配置下载地址时：按钮禁用并说明原因，且仍然能往下走', (
    WidgetTester tester,
  ) async {
    final SharedPreferences prefs = await newPrefs();
    await pumpGate(
      tester,
      prefs: prefs,
      runtimeDirectory: createRuntimeDir(ready: false),
      // 真实构建里默认就是这样（发布时才填地址）。
      archiveConfig: const RuntimeArchiveConfig(),
    );
    await tester.tap(find.text('开始'));
    await settle(tester);

    final FilledButton button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '下载运行组件'),
    );
    expect(button.onPressed, isNull, reason: '没配地址就该禁用，而不是点了才报错');
    expect(find.textContaining('没有配置运行组件的下载地址'), findsOneWidget);

    // 依旧不是死路。
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('存放位置'), findsOneWidget);
  });

  testWidgets('存放位置：显示 StoragePaths 给出的当前值，并能一键用回默认值', (
    WidgetTester tester,
  ) async {
    // 用户"自己选过"的缓存目录：模拟一个改过目录的机器。
    //
    // 这里有两个刻意的选择，都是被"挂死"教出来的：
    //  * 目录用 **createTempSync + createSync** 建：测试体跑在假时钟里，
    //    `await Directory.create()` 的 future 永远不会完成（最后一处挂起就是它）；
    //  * "用户选过的值"用 `setMockInitialValues` 当**初值**摆进去，而不是
    //    挂载之后再 `prefs.setString` —— 真实应用本来也是在启动时读一次偏好，
    //    而且这样一来这条用例就不需要"先写偏好再挂载"的两步语义。
    final Directory root = Directory.systemTemp.createTempSync(
      'zhy_onboarding_storage_',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final Directory custom = Directory(
      '${root.path}${Platform.pathSeparator}custom_cache',
    );
    custom.createSync(recursive: true);
    final SharedPreferences prefs = await newPrefs(<String, Object>{
      StoragePaths.cacheDirectoryKey: custom.path,
    });

    // 真实的 StoragePaths，但环境变量、文件系统、临时目录全部注入 ——
    // 于是默认值可预测，也不会在开发机的 %APPDATA% 下留东西。
    final StoragePaths paths = testStoragePaths(prefs, root);
    final String expectedDefault =
        paths.defaultDirectory(StorageDirectoryKind.cache)!;
    expect(expectedDefault, isNot(custom.path), reason: '这条用例要区分"用户选的"和"默认值"');

    await pumpGate(
      tester,
      prefs: prefs,
      runtimeDirectory: createRuntimeDir(ready: true),
      storagePaths: paths,
    );
    await tester.tap(find.text('开始'));
    await settle(tester);
    await tester.tap(find.text('下一步'));
    await settle(tester);

    expect(find.text('存放位置'), findsOneWidget);
    expect(find.text(custom.path), findsOneWidget, reason: '要显示当前真正在用的值');
    // 安装器那件事如实说出来（这台机器没有安装器配置）。
    expect(find.textContaining('安装器配置'), findsOneWidget);
    // "默认值"这条路必须存在：这一步的目的是确认，不是强迫用户改。
    expect(find.byKey(kOnboardingResetCacheKey), findsOneWidget);
    expect(find.byKey(kOnboardingResetDownloadKey), findsOneWidget);

    await tester.tap(find.byKey(kOnboardingResetCacheKey));
    await settle(tester);

    expect(
      find.text(expectedDefault),
      findsOneWidget,
      reason: '「用默认值」之后要显示 StoragePaths 算出来的默认目录',
    );
    expect(find.text(custom.path), findsNothing);
    expect(prefs.getString(StoragePaths.cacheDirectoryKey), isNull);
  });
}

/// 被调用就说明用例写错了：一个真实的运行时下载（一百多 MB）不该在测试里发生。
Future<RuntimeInstallResult> _unexpectedDownload({
  required Uri? archiveUrl,
  required String? expectedSha256,
  required RuntimeProgressCallback? onProgress,
  required RuntimeCancelSignal? cancelSignal,
}) async {
  throw StateError('这条用例没有注入假的下载器：测试里不允许真的去下载运行时');
}

/// 假安装器的剧本签名。
typedef _EnsureScript =
    Future<RuntimeInstallResult> Function({
      required Uri? archiveUrl,
      required String? expectedSha256,
      required RuntimeProgressCallback? onProgress,
      required RuntimeCancelSignal? cancelSignal,
    });

/// 把"下载"整段替换成一段剧本的安装器。
class _FakeRuntimeInstaller extends RuntimeInstaller {
  _FakeRuntimeInstaller(this._script);

  final _EnsureScript _script;

  @override
  Future<RuntimeInstallResult> ensureInstalled({
    Uri? archiveUrl,
    String? expectedSha256,
    NodeRuntimeSource? source,
    RuntimeProgressCallback? onProgress,
    RuntimeCancelSignal? cancelSignal,
  }) {
    return _script(
      archiveUrl: archiveUrl,
      expectedSha256: expectedSha256,
      onProgress: onProgress,
      cancelSignal: cancelSignal,
    );
  }
}

/// "主界面"的替身：只需要能被精确认出来，且自带 Directionality/Material
/// （引导结束之后门槛会把整棵树换成它，就像真实的 ZhuoYueApp 自带 MaterialApp）。
class _MainShellStub extends StatelessWidget {
  const _MainShellStub();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('主界面占位'))),
    );
  }
}
