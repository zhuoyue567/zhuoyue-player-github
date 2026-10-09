import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/preferences.dart';

/// 集合曲目的同步频率。
///
/// **为什么 [manual] 与 [onLaunch] 的 `interval` 都是 null 却必须分开**：
/// 两者虽然都没有"时间间隔"这个属性，但语义完全相反 ——
/// - [manual]：只有用户点「立即同步」才同步。`isDue` 永远返回 false，
///   自动同步一次都不会发生；
/// - [onLaunch]：每次启动应用时同步一次。`isDue` 在"今天还没同步过"时返回 true。
///
/// 如果把两者合并成一个 `interval == null` 的分支去判断，就必然要把
/// "从不" 和 "每次启动" 映射到同一个结果上，二者只能保一个。
/// `interval` 只表达"隔多久算过期"，这两个值的过期规则不由它表达。
enum SyncFrequency {
  /// 仅手动：不做任何自动同步。
  manual('仅手动', null),

  /// 每次启动：同一天内只同步一次，避免反复切页时重复拉取。
  onLaunch('每次启动', null),

  /// 每小时。
  hourly('每小时', Duration(hours: 1)),

  /// 每 6 小时。
  every6Hours('每 6 小时', Duration(hours: 6)),

  /// 每天。
  daily('每天', Duration(days: 1));

  const SyncFrequency(this.label, this.interval);

  /// 界面上展示的名称。
  final String label;

  /// 自动同步的最小间隔。
  ///
  /// `null` 表示"这个频率不是用时间间隔表达的"，具体含义见枚举本身的文档：
  /// [manual] 从不自动同步，[onLaunch] 按"是否跨天"判断。
  final Duration? interval;

  /// 解析持久化的字符串；无法识别时回落到 [onLaunch]。
  ///
  /// 默认值选 [onLaunch] 而不是 [manual]：用户没表达过偏好时，
  /// 打开歌单看到的应该是云端的最新内容；反过来（默认永不同步）
  /// 会让"本地缓存"这个功能表现成"数据一直是旧的"。
  static SyncFrequency fromKey(String? key) {
    for (final SyncFrequency value in values) {
      if (value.name == key) return value;
    }
    return SyncFrequency.onLaunch;
  }
}

/// 一次同步判定的输入。
///
/// 刻意做成不可变的小对象而不是直接在 UI 里写 `if`：
/// "该不该同步"是这个功能里唯一有分支的逻辑，集中在一处才好测。
@immutable
class SyncPolicy {
  const SyncPolicy(this.frequency);

  final SyncFrequency frequency;

  /// 现在是否应该自动同步一次。
  ///
  /// [lastSyncAt] 为空表示本地从来没有同步过（没有缓存），此时
  /// 除了 [SyncFrequency.manual] 之外都应该同步 —— 首次打开歌单
  /// 本来就是必须联网的。
  bool isDue(DateTime? lastSyncAt) {
    switch (frequency) {
      case SyncFrequency.manual:
        // 仅手动：无论多久没同步都不自动发起。
        return false;
      case SyncFrequency.onLaunch:
        if (lastSyncAt == null) return true;
        final DateTime last = lastSyncAt.toLocal();
        final DateTime now = DateTime.now();
        // 按"自然日"比较而不是比较 24 小时：用户对"每次启动同步"
        // 的预期是"今天打开就是新的"，而不是"距上次满 24 小时"。
        return last.year != now.year ||
            last.month != now.month ||
            last.day != now.day;
      case SyncFrequency.hourly:
      case SyncFrequency.every6Hours:
      case SyncFrequency.daily:
        if (lastSyncAt == null) return true;
        final Duration? interval = frequency.interval;
        if (interval == null) return false;
        return DateTime.now().difference(lastSyncAt.toLocal()) >= interval;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncPolicy && other.frequency == frequency);

  @override
  int get hashCode => frequency.hashCode;

  @override
  String toString() => 'SyncPolicy(${frequency.name})';
}

/// 同步频率的持久化。
///
/// 单独成一个类而不是直接写进 Notifier：设置页 / 以后可能出现的
/// "启动时清理"都要读同一个键，键名散落在各处迟早会写错。
class SyncPolicyStore {
  const SyncPolicyStore({this.preferences});

  /// 外部注入的实例。为 null 时走 [SharedPreferences.getInstance]。
  ///
  /// 注入是为了测试：`SharedPreferences.setMockInitialValues` 之后拿到的
  /// 实例与生产路径是同一个类型，不需要为测试改写任何逻辑。
  final SharedPreferences? preferences;

  /// `shared_preferences` 的键。带 `sync.` 前缀，与音质偏好等键分开。
  static const String storageKey = 'sync.frequency';

  /// 读取用户选择。任何异常（未初始化、值被写坏）都回落到默认值，
  /// 绝不抛 —— 一个同步频率不配有让页面崩掉的能力。
  SyncFrequency load() {
    final SharedPreferences? preferences = this.preferences;
    if (preferences == null) return SyncFrequency.onLaunch;
    try {
      final Object? raw = preferences.get(SyncPolicyStore.storageKey);
      // 存的是枚举的 `name`；被写成别的类型（外部改过配置文件 / 旧版本
      // 写过别的格式）时统一当成"读不出来"，回落到默认值。
      return SyncFrequency.fromKey(raw is String ? raw : null);
    } on Object catch (error) {
      debugPrint('[sync] 读取同步频率失败: $error');
      return SyncFrequency.onLaunch;
    }
  }

  /// 保存用户选择。写盘失败只记日志。
  Future<void> save(SyncFrequency frequency) async {
    try {
      final SharedPreferences preferences =
          this.preferences ?? await SharedPreferences.getInstance();
      await preferences.setString(storageKey, frequency.name);
    } on Object catch (error) {
      debugPrint('[sync] 保存同步频率失败: $error');
    }
  }
}

/// 当前同步频率（界面上的下拉框直接读写它）。
class SyncFrequencyNotifier extends Notifier<SyncFrequency> {
  /// 同步读取 [sharedPreferencesProvider]。
  ///
  /// 捕获异常是刻意的：这个 provider 在 `main()` 里被 `overrideWithValue`
  /// 注入（主题需要同步读取设置），但 widget 测试 / 独立预览不会注入，
  /// 那时 `ref.read` 会抛 `UnimplementedError`。一条同步频率的默认值
  /// 远不值得让整个页面崩掉，回落到 null 走 [SharedPreferences.getInstance]。
  SharedPreferences? _tryReadPreferences() {
    try {
      return ref.read(sharedPreferencesProvider);
    } on Object catch (error) {
      debugPrint('[sync] SharedPreferences 未注入，改用异步实例: $error');
      return null;
    }
  }

  @override
  SyncFrequency build() {
    final SharedPreferences? injected = _tryReadPreferences();
    if (injected == null) {
      // 没有注入实例时不能同步读，先用默认值把界面撑起来，
      // 随后异步纠正（用户看到的是"下拉框从默认值跳到自己的选择"，
      // 而不会是一个空白的头部）。
      unawaited(_hydrate());
      return SyncFrequency.onLaunch;
    }
    return SyncPolicyStore(preferences: injected).load();
  }

  Future<void> _hydrate() async {
    try {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      state = SyncPolicyStore(preferences: preferences).load();
    } on Object catch (error) {
      debugPrint('[sync] 同步频率回填失败: $error');
    }
  }

  /// 切换频率并持久化。
  Future<void> setFrequency(SyncFrequency frequency) async {
    if (state == frequency) return;
    state = frequency;
    await SyncPolicyStore(preferences: _tryReadPreferences()).save(frequency);
  }
}

final NotifierProvider<SyncFrequencyNotifier, SyncFrequency>
syncFrequencyProvider = NotifierProvider<SyncFrequencyNotifier, SyncFrequency>(
  SyncFrequencyNotifier.new,
);

/// 把频率包装成 [SyncPolicy]，供缓存层做"该不该同步"的判断。
final Provider<SyncPolicy> syncPolicyProvider = Provider<SyncPolicy>(
  (Ref ref) => SyncPolicy(ref.watch(syncFrequencyProvider)),
);

/// 给用户看的一句频率说明（下拉框下方的灰字）。
String describeSyncFrequency(SyncFrequency frequency) => switch (frequency) {
  SyncFrequency.manual => '只在你点「立即同步」时更新',
  SyncFrequency.onLaunch => '每次启动应用时更新一次',
  SyncFrequency.hourly => '每小时自动更新一次',
  SyncFrequency.every6Hours => '每 6 小时自动更新一次',
  SyncFrequency.daily => '每天自动更新一次',
};
