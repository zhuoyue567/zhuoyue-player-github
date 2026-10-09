import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/data/models/collection.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/features/account/account_catalog.dart';
import 'package:zhuoyue_player/features/account/account_providers.dart';
import 'package:zhuoyue_player/features/account/accounts_page.dart';
import 'package:zhuoyue_player/features/account/login_dialog.dart';
import 'package:zhuoyue_player/features/shell/app_shell.dart';

/// 测试替身：给出一个固定的账号状态，完全不碰网络与内嵌服务。
///
/// 与 `settings_page_test.dart` 里的同名替身是同一套写法（那边是另一条
/// 并行改动线，不能共用文件），额外记一下调用次数，用来证明按钮真的走到了
/// notifier 上，而不是只画了一个按钮。
class _StubAccountNotifier extends AccountNotifier {
  _StubAccountNotifier(this._profile)
    : super((Ref ref) => throw StateError('测试替身不应该去取 repository'));

  final AccountProfile? _profile;

  int refreshCount = 0;
  int logoutCount = 0;

  @override
  AccountProfile? build() => _profile;

  @override
  Future<void> refresh() async {
    refreshCount++;
  }

  @override
  Future<void> logout() async {
    logoutCount++;
  }
}

void main() {
  /// 挂载账户页。[netease] / [bilibili] 为 null 表示该音源未登录。
  /// 返回两个替身，便于断言"按钮确实调到了 notifier"。
  Future<({_StubAccountNotifier netease, _StubAccountNotifier bilibili})>
  pumpAccounts(
    WidgetTester tester, {
    AccountProfile? netease,
    AccountProfile? bilibili,
  }) async {
    final _StubAccountNotifier neteaseStub = _StubAccountNotifier(netease);
    final _StubAccountNotifier bilibiliStub = _StubAccountNotifier(bilibili);

    final ZhyThemeSettings settings = const ZhyThemeSettings(
      material: ZhyWindowMaterial.solid,
    );

    await tester.pumpWidget(
      ProviderScope(
        // 不写显式类型参数：Riverpod 3 没有从 flutter_riverpod 导出 Override。
        overrides: [
          neteaseAccountProvider.overrideWith(() => neteaseStub),
          bilibiliAccountProvider.overrideWith(() => bilibiliStub),
        ],
        child: MaterialApp(
          theme: buildZhyTheme(
            scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            tokens: buildZhyTokens(settings, Brightness.light),
            material: settings.material,
          ),
          // 给一个 Scaffold：页面用 ScaffoldMessenger.maybeOf 提示结果，
          // 这里必须真的有一个 messenger，提示才有地方去。
          home: const Scaffold(body: AccountsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    return (netease: neteaseStub, bilibili: bilibiliStub);
  }

  FilledButton actionButton(WidgetTester tester, AccountSourceSpec spec) {
    return tester.widget<FilledButton>(
      find.byKey(ValueKey<String>('account-action-${spec.id}')),
    );
  }

  testWidgets('每个音源在页面上各出现一次，且都给出了一句说明', (WidgetTester tester) async {
    await pumpAccounts(tester);

    // 遍历清单断言，而不是把两个音源名写死在测试里：
    // 以后清单里加了音源，这条测试会自动开始检查它有没有被渲染出来。
    for (final AccountSourceSpec spec in kAccountSources) {
      expect(
        find.text(spec.label),
        findsOneWidget,
        reason: '${spec.label} 应在账户页上出现，且只出现一次',
      );
      expect(
        find.text(spec.note!),
        findsOneWidget,
        reason: '${spec.label} 需要一句说明它现在能做什么',
      );
    }

    // 题目要求的锚点：按 MediaSource 的 label 找两个已支持音源。
    expect(find.text(MediaSource.netease.label), findsOneWidget);
    expect(find.text(MediaSource.bilibili.label), findsOneWidget);

    // 页面用途说明。
    expect(find.textContaining('在这里管理各音源的账号'), findsOneWidget);
  });

  testWidgets('未登录时给出可点的「登录」，且没有「退出登录」', (WidgetTester tester) async {
    await pumpAccounts(tester);

    for (final AccountSourceSpec spec in kAccountSources) {
      if (!spec.implemented) continue;
      expect(
        actionButton(tester, spec).onPressed,
        isNotNull,
        reason: '${spec.label} 未登录时登录按钮必须可点',
      );
    }

    expect(find.text('未登录'), findsNWidgets(2));
    expect(
      find.widgetWithText(OutlinedButton, '退出登录'),
      findsNothing,
      reason: '谁都没登录，就不该有退出入口',
    );
  });

  testWidgets('已登录时显示昵称与会员身份，并出现「退出登录」', (WidgetTester tester) async {
    const AccountProfile profile = AccountProfile(
      source: MediaSource.netease,
      userId: '1535266197',
      nickname: '君游虚无',
      vipLabel: '黑胶VIP',
    );
    await pumpAccounts(tester, netease: profile);

    expect(find.text('君游虚无'), findsOneWidget);
    expect(find.text('已登录'), findsOneWidget);
    expect(find.text('黑胶VIP'), findsOneWidget);

    // 已登录的一侧不再有「登录」，而是「刷新」+「退出登录」。
    expect(
      find.byKey(const ValueKey<String>('account-action-netease')),
      findsNothing,
    );
    expect(find.widgetWithText(OutlinedButton, '刷新'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, '退出登录'),
      findsOneWidget,
      reason: '已登录必须有退出入口',
    );

    // 另一个音源没登录，各自的状态互不串味。
    expect(find.text('未登录'), findsOneWidget);
  });

  testWidgets('会员身份为空时显示「普通用户」，而不是留空', (WidgetTester tester) async {
    const AccountProfile profile = AccountProfile(
      source: MediaSource.bilibili,
      userId: '42',
      nickname: '某用户',
    );
    await pumpAccounts(tester, bilibili: profile);

    expect(find.text('某用户'), findsOneWidget);
    expect(find.text('普通用户'), findsOneWidget);
  });

  testWidgets('规划中的音源显示「规划中」，且按钮是禁用的（防止假装已支持）', (WidgetTester tester) async {
    await pumpAccounts(tester);

    final List<AccountSourceSpec> planned = kAccountSources
        .where((AccountSourceSpec spec) => !spec.implemented)
        .toList();
    // 这条断言本身也是事实检查：清单里必须真的有"还没接入"的音源，
    // 否则下面那个循环会空转，测试变成永远绿。
    expect(planned, isNotEmpty);
    expect(find.text('规划中'), findsNWidgets(planned.length));

    for (final AccountSourceSpec spec in planned) {
      expect(find.text(spec.label), findsOneWidget);

      final FilledButton button = actionButton(tester, spec);
      expect(
        button.onPressed,
        isNull,
        reason: '${spec.label} 尚未接入，按钮必须禁用，不能假装已经支持',
      );

      // 点一下也不能有任何反应：没有反应正是"禁用"该有的行为。
      await tester.tap(
        find.byKey(ValueKey<String>('account-action-${spec.id}')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(LoginDialog),
        findsNothing,
        reason: '${spec.label} 的按钮不该打开登录弹窗',
      );
    }
  });

  testWidgets('NAS 卡片：登记为「规划中」、按钮写「连接」且禁用、说明只讲代码事实', (
    WidgetTester tester,
  ) async {
    await pumpAccounts(tester);

    final AccountSourceSpec nas = kAccountSources.firstWhere(
      (AccountSourceSpec spec) => spec.id == 'nas',
    );

    // 先确认它确实是"还没实现"的那一类，否则下面的断言会失去意义。
    expect(nas.implemented, isFalse, reason: 'NAS 目前只有占位，没有真实音源');
    expect(nas.source, isNull);

    expect(find.text('NAS'), findsOneWidget);
    expect(find.text('规划中'), findsWidgets);

    // NAS 没有账号可登 —— 按钮上写「登录」是一句不准确的话。
    expect(nas.signInLabel, '连接');
    final FilledButton button = actionButton(tester, nas);
    expect(button.onPressed, isNull, reason: '尚未接入，按钮必须禁用');

    // 说明文字只允许陈述代码里的事实：不许写"即将上线/敬请期待"这类
    // 无法验证的承诺（清单文件顶部就是这么规定的）。
    final String note = nas.note ?? '';
    expect(note, isNotEmpty, reason: '规划中的音源必须说明为什么现在不能用');
    for (final String promise in <String>['即将', '敬请期待', '马上', '稍后支持']) {
      expect(
        note.contains(promise),
        isFalse,
        reason: '不要给规划中的音源写无法验证的承诺，命中词：「$promise」',
      );
    }
    // 它给出的理由是"本仓库还没有这个能力"，而不是"服务器/网络问题"。
    expect(note.contains('repository') || note.contains('还没有'), isTrue);
  });

  testWidgets('「刷新」调用 notifier 并提示结果', (WidgetTester tester) async {
    const AccountProfile profile = AccountProfile(
      source: MediaSource.netease,
      userId: '1535266197',
      nickname: '君游虚无',
      vipLabel: '黑胶VIP',
    );
    final ({_StubAccountNotifier netease, _StubAccountNotifier bilibili})
    stubs = await pumpAccounts(tester, netease: profile);

    await tester.tap(
      find.byKey(const ValueKey<String>('account-refresh-netease')),
    );
    await tester.pumpAndSettle();

    expect(stubs.netease.refreshCount, 1);
    expect(find.textContaining('账号信息已更新'), findsOneWidget);
  });

  testWidgets('「退出登录」调用 notifier 并提示结果', (WidgetTester tester) async {
    const AccountProfile profile = AccountProfile(
      source: MediaSource.netease,
      userId: '1535266197',
      nickname: '君游虚无',
    );
    final ({_StubAccountNotifier netease, _StubAccountNotifier bilibili})
    stubs = await pumpAccounts(tester, netease: profile);

    await tester.tap(
      find.byKey(const ValueKey<String>('account-logout-netease')),
    );
    await tester.pumpAndSettle();

    expect(stubs.netease.logoutCount, 1);
    expect(find.textContaining('已退出网易云音乐账户'), findsOneWidget);
  });

  // 侧边栏的顺序测试写成纯 Dart 断言，而不是把侧边栏 pump 起来量 y 坐标。
  //
  // 理由：`_Sidebar` 对导航项的渲染就是 `for (final item in ShellSection.values)`
  // —— 枚举顺序**就是**渲染顺序，两者不是"碰巧一致"，是同一份数据。
  // 而 widget test 里起不来 `AppShell`（它依赖 window_manager 与 just_audio 的
  // 平台通道，`page_layout_test.dart` 里也记着同一件事），真要量 y 坐标就只能
  // 复刻一份侧边栏；那份复刻会随生产代码漂移，反而给出虚假的安全感。
  // 所以这里钉住的是**顺序的唯一来源**：枚举本身。
  test('导航项顺序：「账户」紧挨在「设置」之前', () {
    final List<String> names = ShellSection.values
        .map((ShellSection section) => section.name)
        .toList();

    expect(names, <String>[
      'discover',
      'neteasePlaylists',
      'bilibili',
      'search',
      'downloads',
      'accounts',
      'settings',
    ]);

    expect(
      ShellSection.values.indexOf(ShellSection.accounts),
      ShellSection.values.indexOf(ShellSection.settings) - 1,
      reason: '「账户」必须在「设置」之前（题目要求的相对位置）',
    );
    expect(
      ShellSection.values.indexOf(ShellSection.accounts),
      ShellSection.values.indexOf(ShellSection.downloads) + 1,
      reason: '「账户」应放在「下载管理」之后，即下载 → 账户 → 设置',
    );
  });
}
