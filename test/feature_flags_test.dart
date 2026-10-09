import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/cache/cover_cache.dart';
import 'package:zhuoyue_player/core/flags/feature_flags.dart';
import 'package:zhuoyue_player/core/storage/preferences.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/data/models/collection.dart';
import 'package:zhuoyue_player/features/account/account_providers.dart';
import 'package:zhuoyue_player/features/settings/settings_page.dart';

/// 测试替身：给出"未登录"，完全不碰网络与内嵌服务。
///
/// 与 `settings_page_test.dart` 里的同名替身是同一套写法（那边是另一条
/// 并行改动线，不能共用文件）。
class _StubAccountNotifier extends AccountNotifier {
  _StubAccountNotifier()
    : super((Ref ref) => throw StateError('测试替身不应该去取 repository'));

  @override
  AccountProfile? build() => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> logout() async {}
}

/// 测试替身：绕开 path_provider（widget 测试里没有平台通道）。
class _StubCoverCache extends CoverCache {
  _StubCoverCache() : super(Dio());

  @override
  Future<int> sizeOnDisk() async => 0;

  @override
  Future<void> clear() async {}
}

void main() {
  /// 一份全新的存档（"刚装好、什么都没改过"）。
  Future<SharedPreferences> freshPrefs([
    Map<String, Object> values = const <String, Object>{},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  /// 一个注入了存档的容器；设置页里每个 ConsumerWidget 都从它取开关。
  ProviderContainer containerWith(SharedPreferences prefs) {
    final ProviderContainer container = ProviderContainer(
      // 不写显式类型参数：Riverpod 3 没有从 flutter_riverpod 导出 Override。
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        coverCacheProvider.overrideWithValue(_StubCoverCache()),
        neteaseAccountProvider.overrideWith(() => _StubAccountNotifier()),
        bilibiliAccountProvider.overrideWith(() => _StubAccountNotifier()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 点「实验」分区里某个开关那一行。
  Future<void> toggleFlag(WidgetTester tester, String id) async {
    final Finder tile = find.byKey(ValueKey<String>('feature-flag-$id'));
    // 分区在列表底部，很可能还没进视口 —— 直接 tap 会落在视口之外。
    await tester.scrollUntilVisible(tile, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  test('注册表自检：id 唯一且是合法标识符，键名与文案都符合约定', () {
    // 注册表为空的话，下面所有按清单遍历的断言都会空转、变成永远绿。
    expect(kFeatureFlags, isNotEmpty, reason: '至少要注册一个开关');

    final Set<String> ids = <String>{};
    for (final ZhyFeatureFlag flag in kFeatureFlags) {
      // id 就是读取点里的名字（`flags.<id>`），必须是合法标识符。
      expect(
        flag.id,
        matches(RegExp(r'^[a-z][a-zA-Z0-9]*$')),
        reason: '${flag.id} 必须是 camelCase 标识符：它同时是 getter 名与存档键的一部分',
      );
      expect(ids.add(flag.id), isTrue, reason: '${flag.id} 被注册了两次');
      // 持久化键统一 `feature.<id>`。
      expect(flag.storageKey, 'feature.${flag.id}');
      expect(flag.label.trim(), isNotEmpty, reason: '${flag.id} 缺界面上的名字');
      // 文案必须说明默认值（写"默认关闭：…"），否则读的人无法判断现在开没开。
      expect(
        flag.description,
        contains('默认'),
        reason: '${flag.id} 的说明必须写清默认值',
      );
      // 说明只许陈述代码里的事实：不写无法验证的承诺
      // （`account_catalog.dart` 顶部与 `feature_flags.dart` 顶部同一条规定）。
      for (final String promise in <String>['即将', '敬请期待', '马上', '稍后支持']) {
        expect(
          flag.description.contains(promise),
          isFalse,
          reason: '不要给开关写无法验证的承诺，命中词：「$promise」',
        );
      }
    }
  });

  test('默认值：全新安装时每个开关都等于它声明的默认值', () async {
    final SharedPreferences prefs = await freshPrefs();
    final ZhyFeatureFlags flags = ZhyFeatureFlagStore(prefs).load();

    for (final ZhyFeatureFlag flag in kFeatureFlags) {
      expect(
        flags.isEnabled(flag),
        flag.defaultValue,
        reason: '${flag.id} 在全新安装时应当是它声明的默认值',
      );
    }
    expect(flags.isAllDefault, isTrue);

    // 今天注册的两个开关都是"尚未验证 / 受后端限制"，必须默认关闭：
    // 把断言按 id 写出来，是为了让"哪天有人把它们偷偷改成默认开"也能被挡住。
    expect(flags.rawPreferences, isFalse);
    expect(flags.equalizerEntry, isFalse);
  });

  test('持久化：改成非默认值 → 重新 load() 还是改后的值', () async {
    final SharedPreferences prefs = await freshPrefs();
    final ProviderContainer container = containerWith(prefs);
    const ZhyFeatureFlag flag = kRawPreferencesFlag;

    expect(container.read(featureFlagsProvider).isEnabled(flag), isFalse);

    container.read(featureFlagsProvider.notifier).setEnabled(flag, true);

    // 立即生效：不需要重启，同一个容器里马上就能读到新值。
    expect(container.read(featureFlagsProvider).isEnabled(flag), isTrue);

    // 落盘是异步的，等它写完。
    await Future<void>.delayed(Duration.zero);
    expect(
      prefs.getBool(flag.storageKey),
      isTrue,
      reason: '存档键必须是 feature.<id>',
    );

    // 重新 load()（等价于"下次启动"）：还是用户改过的值。
    final ZhyFeatureFlags reloaded = ZhyFeatureFlagStore(prefs).load();
    expect(reloaded.isEnabled(flag), isTrue);
    expect(reloaded.isAllDefault, isFalse);
  });

  test('未知键容错：存档里有已删掉的开关或写坏类型的值，也要能加载', () async {
    final SharedPreferences prefs = await freshPrefs(<String, Object>{
      'feature.已经被删掉的开关': true, // 未来删掉的开关留下的键
      'feature.legacyFlag': false, // 同上，另一个未知键
      'feature.rawPreferences': true, // 已注册的键：要照常读到
      'feature.equalizerEntry': 'yes', // 已注册的键，但类型被写坏
      'theme.mode': 'dark', // 不是 feature.*：与本模块无关
    });

    late ZhyFeatureFlags flags;
    expect(
      () => flags = ZhyFeatureFlagStore(prefs).load(),
      returnsNormally,
      reason: '未知键不该让加载抛异常（将来的存档里必然会有它们）',
    );

    // 未知键被忽略，已注册的键照常生效。
    expect(flags.rawPreferences, isTrue);
    // 类型写坏的值按"读不出来"处理，回落到它自己的默认值。
    expect(flags.equalizerEntry, kEqualizerEntryFlag.defaultValue);
    for (final ZhyFeatureFlag flag in kFeatureFlags) {
      if (flag.id == kRawPreferencesFlag.id) continue;
      expect(
        flags.isEnabled(flag),
        flag.defaultValue,
        reason: '${flag.id} 不该被别的键影响',
      );
    }

    // 读取本身是只读的：既不该把未知键删掉，也不该把它们改写成别的样子。
    expect(prefs.getBool('feature.已经被删掉的开关'), isTrue);
    expect(prefs.getBool('feature.legacyFlag'), isFalse);
  });

  // 这条防的是"注册了一个永远没人读的开关"：那种开关在设置里点了不会有任何
  // 反应，比没有开关更糟（用户会以为是自己点错了）。所以用源码扫描把它挡住。
  //
  // 扫描约定（生产代码与这条测试共同遵守）：
  //
  //  1. id 必须是合法 Dart 标识符，并且 [ZhyFeatureFlags] 上有一个**同名**
  //     bool getter；
  //  2. 读取点一律写成 `flags.<id>`（局部变量名固定用 `flags`），也就是
  //     `if (!flags.<id>) …` 这样的真实分支；
  //  3. 设置页「实验」分区里那个**通用**的开关列表走 `isEnabled(flag)` 与
  //     注册表，不会产生 `flags.<id>` 这种写法。
  //
  // 有了第 3 条，"源码里出现过一次 `flags.<id>`"就等价于"确实有一处代码在
  // 按这个名字读这个开关"，扫描才有意义。读取点还必须写在定义文件之外，
  // 免得有人只在 `feature_flags.dart` 里自说自话。
  test('每个注册的开关都有真实读取点：lib/** 里必须出现 flags.<id>', () {
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '测试的工作目录应当是仓库根目录');

    final List<File> dartFiles = lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'))
        .toList();
    expect(dartFiles, isNotEmpty, reason: 'lib/** 里应当有源码可扫');

    const String flagsDefinitionFile = 'feature_flags.dart';
    final String flagsSource = File(
      'lib/core/flags/feature_flags.dart',
    ).readAsStringSync();

    final List<String> problems = <String>[];
    for (final ZhyFeatureFlag flag in kFeatureFlags) {
      // ① 同名 getter：没有它，`flags.<id>` 根本编译不过。
      if (!flagsSource.contains('bool get ${flag.id} =>')) {
        problems.add(
          '开关「${flag.id}」在 ZhyFeatureFlags 上没有同名 getter。'
          '建议补一行 `bool get ${flag.id} => isEnabled(kXxxFlag);`。',
        );
      }

      // ② 至少一处读取点，且不能只在定义文件里。
      final RegExp pattern = RegExp(
        r'\bflags\.' + RegExp.escape(flag.id) + r'\b',
      );
      final List<String> hits = <String>[];
      for (final File file in dartFiles) {
        if (file.path.endsWith(flagsDefinitionFile)) continue;
        final int count = pattern.allMatches(file.readAsStringSync()).length;
        if (count > 0) hits.add('${file.path}（$count 处）');
      }
      if (hits.isEmpty) {
        problems.add(
          '开关「${flag.id}」在 lib/** 里没有任何 `flags.${flag.id}` 读取点：'
          '注册了却没人读的开关，用户在设置里点了不会有任何反应。'
          '建议在它管住的那个能力处写 `if (!flags.${flag.id}) return const SizedBox.shrink();`，'
          '或者把它从 kFeatureFlags 里删掉。',
        );
      }
    }

    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('「实验」分区：开关真的管住能力，且改完立刻生效（不需要重启）', (
    WidgetTester tester,
  ) async {
    final SharedPreferences prefs = await freshPrefs();
    final ProviderContainer container = containerWith(prefs);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildZhyTheme(
            scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            tokens: buildZhyTokens(
              const ZhyThemeSettings(material: ZhyWindowMaterial.solid),
              Brightness.light,
            ),
            material: ZhyWindowMaterial.solid,
          ),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 分区是照注册表渲染的：每个开关都必须有一条自己的开关行。
    for (final ZhyFeatureFlag flag in kFeatureFlags) {
      final Finder tile = find.byKey(ValueKey<String>('feature-flag-${flag.id}'));
      await tester.scrollUntilVisible(
        tile,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tile, findsOneWidget, reason: '${flag.id} 应当在「实验」分区里出现');
      expect(
        find.descendant(of: tile, matching: find.text(flag.label)),
        findsOneWidget,
      );
    }

    // 默认关闭：两个能力都没有任何入口。
    expect(find.text('feature.rawPreferences'), findsNothing);
    expect(find.text('打开均衡器'), findsNothing);

    // 打开「查看原始设置键值」：面板立刻出现，里面就是这个开关的真实存档键。
    await toggleFlag(tester, kRawPreferencesFlag.id);
    expect(
      find.text('feature.${kRawPreferencesFlag.id}'),
      findsOneWidget,
      reason: '开关打开后必须真的能看到原始键值',
    );

    // 再关掉：面板立刻消失（即时生效，不需要重启）。
    await toggleFlag(tester, kRawPreferencesFlag.id);
    expect(find.text('feature.${kRawPreferencesFlag.id}'), findsNothing);

    // 打开「设置页里的均衡器入口」：按钮出现，而且点下去真的能打开面板 ——
    // 证明这个开关管住的是一个真能力，不是画了个按钮。
    await toggleFlag(tester, kEqualizerEntryFlag.id);
    expect(find.text('打开均衡器'), findsOneWidget);
    await tester.ensureVisible(find.text('打开均衡器'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开均衡器'));
    await tester.pumpAndSettle();
    expect(
      find.text('均衡器'),
      findsOneWidget,
      reason: '入口必须真的能打开均衡器面板',
    );
  });
}
