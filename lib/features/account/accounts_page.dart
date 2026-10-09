import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/glass.dart';
import '../../core/ui/song_list.dart';
import '../../data/models/collection.dart';
import 'account_catalog.dart';
import 'account_providers.dart';
import 'login_dialog.dart';

/// 账户管理页：列出所有音源，逐个管理它们的登录状态。
///
/// 它回答的是一个以前没有归属的问题 ——「我这个客户端到底登了哪些账号、
/// 各自还有效吗」。以前这件事只在设置页的一个分区里能看，而且一次只能看
/// 一个音源（切 ChoiceChip）；导航栏的账户卡片又只显示网易云。
///
/// ## 与设置页的关系
///
/// 设置页里也有一段账户 UI（`settings_page.dart` 的 `_AccountSectionCard`，
/// 以及紧挨着的 `_BilibiliTargetFolderRow`）。**本页是独立实现**，刻意不复用：
/// 那个分区里混着只对设置页有意义的行（目标收藏夹、音质「自动」档位的依据……），
/// 要抽成公共组件就得改设置页，而设置页正处于另一条并行改动线上。
/// 两边表达的信息应当一致；**未来应当合并到一处**（让设置页直接复用本页的
/// 卡片，或者把本页降级成设置页的一个入口），合并前这里是唯一的一处新增。
class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return PageContentContainer(
      // 不画任何整页底色：窗口的亚克力 / 毛玻璃只在 Flutter 没画像素的地方
      // 透出来，这里铺一层不透明背景就等于把系统材质盖死。
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.manage_accounts_rounded,
                size: 20,
                color: scheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                '账户',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '在这里管理各音源的账号：登录、校验凭据、退出登录。',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          // 整页由清单驱动：这里没有第二个音源的名字，
          // 也因此不存在"加了音源却忘了在这里加一张卡"的可能。
          for (final AccountSourceSpec spec in kAccountSources) ...<Widget>[
            _AccountSourceCard(spec: spec),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}

/// 一个音源一张卡片。
class _AccountSourceCard extends ConsumerWidget {
  const _AccountSourceCard({required this.spec});

  final AccountSourceSpec spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final NotifierProvider<AccountNotifier, AccountProfile?>? provider =
        spec.accountProvider;
    final AccountProfile? profile = provider == null
        ? null
        : ref.watch(provider);

    return GlassPanel(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SourceIcon(icon: spec.icon, dimmed: !spec.implemented),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  spec.label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                _StatusLine(profile: profile, planned: !spec.implemented),
                if (spec.note != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    spec.note!,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _buildActions(context, ref, profile: profile),
        ],
      ),
    );
  }

  Widget _buildActions(
    BuildContext context,
    WidgetRef ref, {
    required AccountProfile? profile,
  }) {
    // 规划中的音源：按钮照常占位，但必须是 disabled 的。
    //
    // 这里刻意保留一个按钮而不是干脆不画：位置留着，用户才知道
    // "这个音源将来会在这里接入"；但它是灰的、点不动，绝不假装现在就能用。
    // 同理，文案里不写"即将上线"之类无法验证的话。
    //
    // 按钮上的字取 `spec.signInLabel`：NAS 这类音源没有账号可登，
    // 统一写「登录」会是一句不准确的话。
    if (!spec.implemented) {
      return FilledButton.icon(
        key: ValueKey<String>('account-action-${spec.id}'),
        onPressed: null,
        icon: const Icon(Icons.login_rounded, size: 15),
        label: Text(spec.signInLabel),
      );
    }

    if (profile == null) {
      // 弹窗签名是 `showLoginDialog(BuildContext)`，没有指定音源的参数 ——
      // 弹窗内部自带网易云 / 哔哩的切换，所以这里点任意一张卡的「登录」
      // 打开的是同一个弹窗，用户还要在弹窗里选一次音源。
      // 这是既有实现，本页不去改它（改 login_dialog 会牵动设置页那个分区）。
      return FilledButton.icon(
        key: ValueKey<String>('account-action-${spec.id}'),
        onPressed: () => unawaited(showLoginDialog(context)),
        icon: const Icon(Icons.login_rounded, size: 15),
        label: Text(spec.signInLabel),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        OutlinedButton.icon(
          key: ValueKey<String>('account-refresh-${spec.id}'),
          onPressed: () => unawaited(_refresh(context, ref)),
          icon: const Icon(Icons.refresh_rounded, size: 15),
          label: const Text('刷新'),
        ),
        OutlinedButton.icon(
          key: ValueKey<String>('account-logout-${spec.id}'),
          onPressed: () => unawaited(_logout(context, ref)),
          icon: const Icon(Icons.logout_rounded, size: 15),
          label: const Text('退出登录'),
        ),
      ],
    );
  }

  /// 重新校验凭据。
  ///
  /// 存在的理由：cookie 会在服务端静默失效，失败时 [AccountNotifier.refresh]
  /// 是**保留上一次结果**的（网络抖一下不该让头像变回未登录），所以界面可能
  /// 一直显示已登录而请求全部失败。这个按钮就是用户手上的那次强制校验，
  /// 因此无论结果如何都要给一句反馈。
  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final NotifierProvider<AccountNotifier, AccountProfile?>? provider =
        spec.accountProvider;
    if (provider == null) return;

    await ref.read(provider.notifier).refresh();
    if (!context.mounted) return;
    final AccountProfile? profile = ref.read(provider);
    _notify(
      context,
      profile == null
          ? '${spec.label}未登录或凭据已失效'
          : '${spec.label}账号信息已更新：${profile.nickname}',
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final NotifierProvider<AccountNotifier, AccountProfile?>? provider =
        spec.accountProvider;
    if (provider == null) return;

    await ref.read(provider.notifier).logout();
    if (!context.mounted) return;
    _notify(context, '已退出${spec.label}账户');
  }

  /// 提示操作结果。
  ///
  /// 用 `maybeOf` 而不是 `of`：这一页理论上可以被放进任何宿主，
  /// 没有 ScaffoldMessenger 时安静地什么都不做，也好过为了提示崩掉。
  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 音源图标。规划中的音源用中性色，一眼就和可用音源区分开。
class _SourceIcon extends StatelessWidget {
  const _SourceIcon({required this.icon, required this.dimmed});

  final IconData icon;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: dimmed
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(tokens.cardRadius),
      ),
      child: Icon(
        icon,
        size: 20,
        color: dimmed ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
      ),
    );
  }
}

/// 登录状态一行：已登录显示"已登录 + 昵称 + 会员身份"，
/// 否则显示「未登录」或「规划中」。
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.profile, required this.planned});

  final AccountProfile? profile;
  final bool planned;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AccountProfile? account = profile;

    if (account != null) {
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _StatusChip(
            label: '已登录',
            background: scheme.primaryContainer,
            foreground: scheme.onPrimaryContainer,
          ),
          Text(
            account.nickname,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          // 会员身份直接决定「自动」音质能选到哪一档，所以它和昵称一样
          // 是账号状态的一部分；没有会员时写「普通用户」而不是留空，
          // 免得用户以为这一项没加载出来。
          _StatusChip(
            label: account.vipLabel ?? '普通用户',
            background: scheme.tertiaryContainer,
            foreground: scheme.onTertiaryContainer,
          ),
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: <Widget>[
        if (planned)
          _StatusChip(
            label: '规划中',
            background: scheme.secondaryContainer,
            foreground: scheme.onSecondaryContainer,
          )
        else
          _StatusChip(
            label: '未登录',
            background: scheme.surfaceContainerHighest,
            foreground: scheme.onSurfaceVariant,
          ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(tokens.pillRadius),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, color: foreground)),
    );
  }
}
