import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/runtime/runtime_installer.dart';
import '../../core/storage/preferences.dart';

// ---------------------------------------------------------------------------
// 「引导已经走过」这件事怎么记
//
// 需求是"安装后第一次运行出现、可跳过、只出现一次"。这三件事里最容易做错的
// 是最后一件：**跳过也必须写标记**，否则每次启动都会被拦一次 —— 而"跳过"这个
// 动作本身恰恰表达了"我不想再看到它"。
//
// 所以这里只留一个键、一个版本号，完成与跳过写的是同一个值：都表示
// "这一版引导在本机已经结束"。用版本号而不是 bool，是为了让"以后重大更新
// 再引导一次"不必清任何键 —— 见 [kOnboardingFlowVersion]。
// ---------------------------------------------------------------------------

/// 「引导已经走过」的偏好键。
const String kOnboardingCompletedKey = 'onboarding.completed';

/// 当前这一版引导的版本号，也就是写进 [kOnboardingCompletedKey] 的值。
///
/// 语义（写清楚，是因为将来一定会有人想"重大更新后再引导一次"）：
/// 存的是**用户完成或跳过的最后一版引导的版本号**；启动时只有
/// `存值 != 当前版本` 才显示引导页。于是：
///  * 值缺失 —— 这台机器从来没走过引导（全新安装，或从没有引导的旧版本升上来）；
///  * 值 == 当前版本 —— 走过了，不再打扰；
///  * 将来想把引导再放一次（例如多了必须让用户知道的步骤），把这里加到
///    `'2'` 就够了：旧值 `'1'` 会被判成"没走过这一版"，于是再引导一次，
///    既不用清键、也不会变成每次都出现。
///
/// 用字符串而不是 bool 就是这个原因：bool 说不出"是哪一版"，
/// 而"只出现一次"与"重大更新后再出现一次"要能共存，只能靠记住版本。
const String kOnboardingFlowVersion = '1';

/// 这台机器是不是已经走过引导（**完成与跳过都算**）。
bool isOnboardingCompleted(SharedPreferences preferences) {
  return preferences.getString(kOnboardingCompletedKey) ==
      kOnboardingFlowVersion;
}

/// 记下"引导已经结束"。
///
/// 写盘失败**不抛给界面**：它最坏的后果只是下次启动再看一遍引导，
/// 而把用户拦在一个他明明已经点了"跳过"的页面上（或者弹一个看不懂的错误）
/// 是更糟的结果。所以这里吞掉异常，只留一条日志。
Future<void> markOnboardingCompleted(SharedPreferences preferences) async {
  try {
    await preferences.setString(
      kOnboardingCompletedKey,
      kOnboardingFlowVersion,
    );
  } on Object catch (error) {
    debugPrint('[onboarding] 记录引导完成状态失败（下次启动会再显示一次）：$error');
  }
}

/// 本机是否已经走过引导。`OnboardingGate` 在首帧读它一次。
///
/// 走同步的 [SharedPreferences]（`main()` 里已经注入）而不是异步 Provider：
/// 引导页要不要出现必须在**第一帧**就定下来，异步的话用户会先看到主界面
/// 闪一下，再被引导页盖上。
final Provider<bool> onboardingCompletedProvider = Provider<bool>(
  (Ref ref) => isOnboardingCompleted(ref.watch(sharedPreferencesProvider)),
);

// ---------------------------------------------------------------------------
// 运行时下载源：**必须显式配置**，不许猜
// ---------------------------------------------------------------------------

/// 发布时上传到 GitHub Release 的**合并包**地址。
///
/// 为什么不能用 Node 官方那个 zip：`node-vXX-win-x64.zip` 里只有 node.exe 与
/// npm，**没有** `netease-api/launcher.js` 和它的 node_modules。拿它当下载源，
/// 装完仍是一套不可用的运行时（`hasUsableRuntime` 判"没装好"），
/// 用户下次启动还得再下一遍一百多 MB —— 这是一种最坏的"看起来成功了"。
/// 所以地址指向我们自己发布的合并包，那里 `node/` 与 `netease-api/` 都齐。
///
/// **默认留空（空串）是刻意的**：填上之前下载功能不可用，界面会把「下载」按钮禁掉并
/// 说明原因。地址写错必须显式失败 —— 猜一个"看起来差不多"的 URL 然后失败得
/// 莫名其妙，比"明确告诉你这次构建没配"糟糕得多。
const String kRuntimeArchiveUrl = 'https://github.com/zhuoyue567/zhuoyue-player-github/releases/download/v0.1.0/runtime-v1.zip';

/// 与 [kRuntimeArchiveUrl] 配套的 SHA-256（64 位十六进制小写；下载器也接受
/// `sha256:<hash>` 与 `SHASUMS256.txt` 整行两种写法）。
///
/// 留空（空串）表示"不校验"，但**发布时必须填**：不校验的话，被截断/被替换的压缩包
/// 要等到解压阶段才可能暴露，那时错误信息已经指向"压缩包损坏"，排查方向会被
/// 带偏（下载器的文档里写了同一件事）。
const String kRuntimeArchiveSha256 = '01d4bc7fff01d88c180526b4c47d1380a7973f38a85221a81f6c11d2ca0472fc';

/// 一次构建里配置好的运行时下载源。
@immutable
class RuntimeArchiveConfig {
  const RuntimeArchiveConfig({this.url, this.sha256});

  /// 合并包地址；null 或空白表示这次构建没有配置 —— 下载功能不可用。
  final String? url;

  /// 期望的 SHA-256；null 表示不校验。
  final String? sha256;

  /// 能不能下载。界面用它决定"显示下载按钮"还是"禁用 + 说明原因"。
  bool get isConfigured => url != null && url!.trim().isNotEmpty;
}

/// 供界面（以及测试）读的一份下载源配置。
///
/// 做成 Provider 而不是让页面直接读上面两个常量：发布后只改一处常量；
/// 测试则可以直接把它换成假地址，于是"下载"整条路径完全离线可跑。
final Provider<RuntimeArchiveConfig> runtimeArchiveConfigProvider =
    Provider<RuntimeArchiveConfig>(
      (Ref ref) => const RuntimeArchiveConfig(
        url: kRuntimeArchiveUrl,
        sha256: kRuntimeArchiveSha256,
      ),
    );

// ---------------------------------------------------------------------------
// 「准备运行时」这一步需要的其余注入点
//
// 全部做成 Provider，而不是在页面里直接 new：
//  * 真实的运行时是一百多 MB 的下载 + 真实磁盘写入，测试里绝不能碰；
//  * `path_provider` 在单元测试里没有平台通道，`defaultTargetDirectory()`
//    必然抛 MissingPluginException —— 不注入就根本测不了"已就绪"这条路径。
// 于是测试只要 override 这三个 Provider，就能离线演完
// "已就绪 / 缺失 / 未配置 / 下载中 / 下载失败"几种剧本
// （见 test/onboarding_test.dart）。
// ---------------------------------------------------------------------------

/// 运行时下载器。默认就是真家伙（真下载、真校验、真解压）。
final Provider<RuntimeInstaller> runtimeInstallerProvider =
    Provider<RuntimeInstaller>((Ref ref) => RuntimeInstaller());

/// 运行时的安装目标目录（"装到哪"）。
///
/// 默认值与 [RuntimeInstaller.ensureInstalled] 内部用的是同一个函数，
/// 所以界面上说的"将安装到 <路径>"就是它真正会写的地方 ——
/// 两处各算一次路径迟早会给出两个答案。
///
/// `isAutoDispose: false`：这个结果在一次运行里只可能有一个，
/// 引导页每次重建（切步骤、改目录）都重新解析一遍纯属浪费。
final FutureProvider<Directory> runtimeDirectoryProvider =
    FutureProvider<Directory>(
      (Ref ref) => RuntimeInstaller.defaultTargetDirectory(),
      isAutoDispose: false,
    );
