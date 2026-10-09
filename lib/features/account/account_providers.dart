import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bilibili/bilibili_repository.dart';
import '../../data/models/collection.dart';
import '../../data/netease/netease_repository.dart';
import '../../data/repositories/music_repository.dart';

/// 订阅一个音源的账号状态。
///
/// 之所以要单独做一层：repository 只在接口调用时才知道自己掉线了，
/// 而界面需要在**任何时刻**都能反映"现在登录的是谁"。这里把
/// repository 的 `accountChanges` 流桥接成 Riverpod 状态，
/// 登录/退出后所有监听它的组件都会自动刷新。
class AccountNotifier extends Notifier<AccountProfile?> {
  AccountNotifier(this.selectRepository);

  /// 从容器里取出目标音源的 repository。
  ///
  /// 用回调而不是直接传实例：`Notifier` 在 `build` 之前拿不到 `ref`，
  /// 而网易云与哔哩的账号状态逻辑完全一样，没必要写两遍。
  final MusicRepository Function(Ref ref) selectRepository;

  /// 最近一次「从已登录变成未登录」是不是因为**凭据失效**，而不是用户主动退出。
  ///
  /// 界面靠这个标志区分两件事：主动退出已经弹过"已退出…"，
  /// 再叠一条"登录已失效"就是噪音；而凭据失效必须明确告知 ——
  /// 否则用户只会看到账号莫名其妙变回未登录，完全不知道发生了什么
  /// （哔哩的 SESSDATA 生命周期明显短于网易云的 MUSIC_U，
  /// 这个场景是必然会遇到的）。
  bool lastChangeWasExpiry = false;

  @override
  AccountProfile? build() {
    final MusicRepository repository = selectRepository(ref);
    final StreamSubscription<AccountProfile?> subscription = repository
        .accountChanges
        .listen((AccountProfile? profile) {
          state = profile;
        });
    ref.onDispose(() => unawaited(subscription.cancel()));

    // 启动时主动校验一次本地凭据：cookie 可能已经在服务端失效，
    // 不校验的话界面会一直显示"已登录"，但每个请求都失败。
    unawaited(refresh());
    return repository.account;
  }

  /// 重新拉取账号信息。失败时保留上一次的结果，只记日志 ——
  /// 网络抖一下就让头像变回"未登录"是很糟的体验。
  Future<void> refresh() async {
    final MusicRepository repository = selectRepository(ref);
    final AccountProfile? before = state ?? repository.account;
    state = repository.account ?? state;
    try {
      final AccountProfile? after = await repository.refreshAccount();
      lastChangeWasExpiry = before != null && after == null;
      state = after;
    } on Object catch (error) {
      debugPrint('[account] 刷新账号失败: $error');
    }
  }

  /// 退出登录。
  Future<void> logout() async {
    // 主动退出不算"失效"，先清标志再登出。
    lastChangeWasExpiry = false;
    await selectRepository(ref).logout();
    state = null;
  }
}

/// 网易云账号。
final NotifierProvider<AccountNotifier, AccountProfile?>
neteaseAccountProvider = NotifierProvider<AccountNotifier, AccountProfile?>(
  () => AccountNotifier((Ref ref) => ref.watch(neteaseRepositoryProvider)),
);

/// 哔哩哔哩账号。
final NotifierProvider<AccountNotifier, AccountProfile?>
bilibiliAccountProvider = NotifierProvider<AccountNotifier, AccountProfile?>(
  () => AccountNotifier((Ref ref) => ref.watch(bilibiliRepositoryProvider)),
);

/// 是否至少有一个音源处于登录状态。
final Provider<bool> hasAnyAccountProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(neteaseAccountProvider) != null ||
      ref.watch(bilibiliAccountProvider) != null,
);
