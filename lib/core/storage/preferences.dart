import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局 [SharedPreferences] 实例。
///
/// **必须在 `main()` 里用 `overrideWithValue` 注入**：主题设置在首帧就要同步
/// 读出来，如果改成异步 Provider，用户每次启动都会先看到默认配色闪一下，
/// 再跳到自己的设置 —— 这种闪现在桌面端非常明显。
///
/// 这里的实现直接抛错而不是"帮忙"异步初始化，是为了让漏掉注入的情况
/// 在开发阶段立刻暴露，而不是变成线上一个难以复现的白屏。
final Provider<SharedPreferences> sharedPreferencesProvider =
    Provider<SharedPreferences>(
      (ref) => throw UnimplementedError(
        'sharedPreferencesProvider 未注入：请在 ProviderScope.overrides 中提供实例',
      ),
    );
