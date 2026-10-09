/// 功能开关（feature flags）的定义、注册表、取值、持久化与 provider。
///
/// ## 为什么要有这一层
///
/// 有些能力是"能用，但还不该默认出现在界面上"：要么只在排查问题时才有用，
/// 要么受当前播放后端限制、做了也不会真的生效。这类能力直接删掉可惜，
/// 无条件摆出来又会误导用户。做成开关之后，代码只有一份，默认值和文案
/// 都集中在这里，界面那边不需要为每个开关写一遍。
///
/// ## 三条硬规矩（`test/feature_flags_test.dart` 会逐条扫描源码来守）
///
/// 1. **每个开关都必须真的管住某个行为**：注册表里每一条都要在 `lib/**`
///    里有一处读取点，写成 `flags.<id>`，并在那里分支。一个"点了没反应"的
///    开关比没有开关更糟 —— 用户会以为是自己点错了。
/// 2. **默认值要诚实**：没验证过、没做完、受后端限制的能力默认 `false`；
///    已经能正常工作、用户本来就在用的能力不要塞进开关（那叫藏功能）。
/// 3. **文案只陈述代码里的事实**：说明写"它管什么、为什么默认是关的"，
///    不写"即将上线""敬请期待"这类无法验证的话
///    （与 `lib/features/account/account_catalog.dart` 顶部同一条规定）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/preferences.dart';

/// 一个功能开关的**定义**（元数据 + 默认值）。
///
/// 定义与取值刻意分开：定义是编译期常量，能被界面、文档和测试引用；
/// 取值是运行时的、会被用户改、会落盘。混在一起迟早会出现
/// "把用户改过的值当成默认值"这类问题。
@immutable
class ZhyFeatureFlag {
  const ZhyFeatureFlag({
    required this.id,
    required this.label,
    required this.description,
    this.defaultValue = false,
  });

  /// 稳定标识。它同时是三样东西，必须完全一致：
  ///
  /// - 持久化键：`feature.<id>`；
  /// - [ZhyFeatureFlags] 上的**同名 getter**，读取点写成 `flags.<id>`；
  /// - 界面与测试里定位这一条的 key：`feature-flag-<id>`。
  ///
  /// 所以它必须是合法的 Dart 标识符（camelCase，不能带点）。
  final String id;

  /// 开关在界面上的名字。
  final String label;

  /// 一句说明：这个开关管什么、为什么默认是关的。
  ///
  /// 必须提到默认值（写"默认关闭：…"），否则读的人无法判断现在是开还是关。
  final String description;

  /// 缺省值。**没验证过 / 受后端限制的能力一律 false。**
  final bool defaultValue;

  /// `shared_preferences` 里的键。
  ///
  /// 统一前缀 `feature.`：与 `theme.` / `player.` / `sync.` 一样，
  /// 前缀就是这个键属于哪一块的凭据，清理和排查时不用逐个认。
  String get storageKey => 'feature.$id';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ZhyFeatureFlag && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ZhyFeatureFlag($id, 默认 $defaultValue)';
}

// ---------------------------------------------------------------------------
// 注册表：加一个开关 = 在这里加一条常量 + 在 ZhyFeatureFlags 上补一个同名 getter
// ---------------------------------------------------------------------------

/// 「实验」分区里「查看原始设置键值」这一条。
///
/// 它管住的能力就是那份面板本身（见 `settings_page.dart` 的
/// `_RawPreferencesPanel`）：关掉之后，界面上不存在任何地方能看到原始键值。
const ZhyFeatureFlag kRawPreferencesFlag = ZhyFeatureFlag(
  id: 'rawPreferences',
  label: '查看原始设置键值',
  description:
      '在设置页里原样列出本机保存的 feature.* 键与值，用来确认开关到底有没有落盘。'
      '默认关闭：它只对排查"改了却没生效"这类问题有用，日常看它没有意义。',
);

/// 「实验」分区里「设置页的均衡器入口」这一条。
///
/// 它管住的是**设置页里这个入口**：关掉之后设置页上没有打开均衡器的地方
/// （播放条上原有的入口不受影响，那是另一条链路）。默认关闭的理由是真实的：
/// 面板里的曲线在当前 Windows 播放后端不会改变声音，面板自己也如此标注。
const ZhyFeatureFlag kEqualizerEntryFlag = ZhyFeatureFlag(
  id: 'equalizerEntry',
  label: '设置页里的均衡器入口',
  description:
      '在设置页里多一个打开均衡器的入口（播放条上原有的入口不受它影响）。'
      '默认关闭：当前 Windows 播放后端（just_audio_windows / Media Foundation）'
      '没有暴露音频效果接口，均衡器的曲线与预设不会改变声音（均衡器面板内也如此标注），'
      '所以它先不进默认界面。',
);

/// 全部已注册的开关。
///
/// 界面（设置页的「实验」分区）和测试都**遍历这个清单**，而不是各自手写一遍：
/// 那样才能做到"加一个开关只需要动这一处"，也不会出现
/// "加了开关却忘了在设置页画出它的开关"。
const List<ZhyFeatureFlag> kFeatureFlags = <ZhyFeatureFlag>[
  kRawPreferencesFlag,
  kEqualizerEntryFlag,
];

/// 全部开关的当前取值。
///
/// 内部只存 `id -> bool`：新增一个开关时，[isEnabled] 会自动回落到它自己
/// 声明的默认值，这里不需要再补一行默认值 —— 少一处能写岔的地方。
@immutable
class ZhyFeatureFlags {
  const ZhyFeatureFlags(this._enabled);

  /// 全部取值（id -> bool）。
  final Map<String, bool> _enabled;

  /// 某个开关现在是不是开的。
  ///
  /// 取不到（尚未落盘、刚新增）时返回它自己的默认值。
  bool isEnabled(ZhyFeatureFlag flag) => _enabled[flag.id] ?? flag.defaultValue;

  /// 每个开关一个**同名** getter：读取点只写 `flags.<id>`。
  ///
  /// 「实验」分区里那个通用开关列表走的是 [isEnabled]，不会产生
  /// `flags.<id>` 这样的引用 —— 于是源码里每出现一次 `flags.<id>`，
  /// 都是一处真正的行为分支（`feature_flags_test.dart` 靠这一点扫源码）。
  bool get rawPreferences => isEnabled(kRawPreferencesFlag);
  bool get equalizerEntry => isEnabled(kEqualizerEntryFlag);

  /// 改过某一项之后的副本。
  ZhyFeatureFlags withFlag(ZhyFeatureFlag flag, bool value) =>
      ZhyFeatureFlags(<String, bool>{..._enabled, flag.id: value});

  /// 是否与注册表声明的默认值完全一致。
  bool get isAllDefault =>
      kFeatureFlags.every((ZhyFeatureFlag flag) => isEnabled(flag) == flag.defaultValue);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ZhyFeatureFlags && mapEquals(other._enabled, _enabled));

  @override
  int get hashCode =>
      Object.hashAll(kFeatureFlags.map((ZhyFeatureFlag flag) => isEnabled(flag)));

  @override
  String toString() =>
      'ZhyFeatureFlags(${kFeatureFlags.map((ZhyFeatureFlag flag) => '${flag.id}=${isEnabled(flag)}').join(', ')})';
}

/// 开关的读写。
///
/// 与 `ZhyThemeSettingsStore` 是同一套路：持久化细节挡在 provider 之外，
/// UI 层完全不需要知道存在 SharedPreferences。
class ZhyFeatureFlagStore {
  const ZhyFeatureFlagStore(this._prefs);

  final SharedPreferences _prefs;

  /// 读出全部开关的取值。
  ///
  /// 遍历**注册表**而不是 `prefs.getKeys()`：存档里那些已经不存在的
  /// `feature.*` 键因此永远不会被读到 —— 删掉一个开关之后，老存档既不会让
  /// 应用起不来，也不会凭空多出一个没人认识的开关。
  ZhyFeatureFlags load() {
    final Map<String, bool> values = <String, bool>{};
    for (final ZhyFeatureFlag flag in kFeatureFlags) {
      values[flag.id] = _read(flag);
    }
    return ZhyFeatureFlags(values);
  }

  bool _read(ZhyFeatureFlag flag) {
    try {
      return _prefs.getBool(flag.storageKey) ?? flag.defaultValue;
    } on Object catch (error) {
      // 值被写成了别的类型（外部改过配置文件、旧版本存过别的格式）时，
      // 按"读不出来"处理：一个开关不值得让设置页整页崩掉。
      debugPrint('[flags] 读取 ${flag.storageKey} 失败，按默认值处理: $error');
      return flag.defaultValue;
    }
  }

  /// 写下某个开关。写盘失败只记日志，不打断交互。
  Future<void> save(ZhyFeatureFlag flag, bool value) async {
    try {
      await _prefs.setBool(flag.storageKey, value);
    } on Object catch (error) {
      debugPrint('[flags] 保存 ${flag.storageKey} 失败: $error');
    }
  }

  /// 把注册表里的开关全部清回默认值。
  ///
  /// 只删**已注册**的键：存档里的未知 `feature.*` 键不是这里产生的，
  /// 也不该被一次"恢复默认开关"顺手抹掉。
  Future<void> resetAll() async {
    for (final ZhyFeatureFlag flag in kFeatureFlags) {
      try {
        await _prefs.remove(flag.storageKey);
      } on Object catch (error) {
        debugPrint('[flags] 清除 ${flag.storageKey} 失败: $error');
      }
    }
  }
}

/// 开关的持久化读写。
final Provider<ZhyFeatureFlagStore> featureFlagStoreProvider =
    Provider<ZhyFeatureFlagStore>(
      (Ref ref) => ZhyFeatureFlagStore(ref.watch(sharedPreferencesProvider)),
    );

/// 当前开关取值。
///
/// [build] 里同步读盘：`sharedPreferencesProvider` 已经在 `main()` 里同步
/// 初始化过，所以这里不需要 `AsyncNotifier`，也就不会有"第一帧按默认值渲染、
/// 第二帧才跳成用户的选择"的闪烁。
class FeatureFlagsNotifier extends Notifier<ZhyFeatureFlags> {
  @override
  ZhyFeatureFlags build() => ref.watch(featureFlagStoreProvider).load();

  /// 改一个开关。
  ///
  /// **立即生效**：新取值直接进 state，界面这一帧就跟着变，不需要重启
  /// （与仓库里其它设置一致）。落盘是异步的，失败也不打断交互
  /// （顶多是下次启动回到旧值）。
  void setEnabled(ZhyFeatureFlag flag, bool value) {
    if (state.isEnabled(flag) == value) return;
    state = state.withFlag(flag, value);
    unawaited(ref.read(featureFlagStoreProvider).save(flag, value));
  }

  /// 全部回到默认值。
  Future<void> resetAll() async {
    final ZhyFeatureFlagStore store = ref.read(featureFlagStoreProvider);
    await store.resetAll();
    state = store.load();
  }
}

final NotifierProvider<FeatureFlagsNotifier, ZhyFeatureFlags>
featureFlagsProvider =
    NotifierProvider<FeatureFlagsNotifier, ZhyFeatureFlags>(
      FeatureFlagsNotifier.new,
    );
