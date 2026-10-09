import 'package:dio/dio.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/cache/cover_cache.dart';
import 'package:zhuoyue_player/core/storage/preferences.dart';
import 'package:zhuoyue_player/core/storage/storage_paths.dart';
import 'support/in_memory_storage_io.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/data/models/collection.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/features/account/account_providers.dart';
import 'package:zhuoyue_player/features/settings/settings_page.dart';

/// 测试替身：直接给出一个固定的账号状态，完全不碰网络与内嵌服务。
class _StubAccountNotifier extends AccountNotifier {
  _StubAccountNotifier(this._profile)
    : super((Ref ref) => throw StateError('测试替身不应该去取 repository'));

  final AccountProfile? _profile;

  @override
  AccountProfile? build() => _profile;

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

/// 精确匹配一段**可选中/可复制**的路径文字。
///
/// 路径是用 `SelectableText` 画的（用户要能选中复制），所以这里按
/// `EditableText.controller.text` 匹配，并且必须允许换行 —— 完整路径
/// 在窄窗口里是折行的，`find.text('C:\\整\\条\\路径')` 会匹配不上折行后的文本。
Finder selectableText(String text) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is EditableText &&
      widget.controller.text.trim() == text.trim(),
);

void main() {
  /// 一份全新的空偏好。
  ///
  /// 存储路径的用例需要在挂载之前先把目录写进偏好，所以它们会自己建一份实例
  /// 再传进来；这里只是给"不关心偏好内容"的用例一个默认值。
  Future<SharedPreferences> newPrefs() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return SharedPreferences.getInstance();
  }

  /// 挂载设置页。[profile] 为 null 表示"未登录"。
  ///
  /// [bundledFontAvailable] 覆盖"内置字体在不在包里"这个事实：默认注入 false，
  /// 既是为了让"字体缺失"这条提示真的被画出来，也是为了不真去读那个 17MB 的
  /// ttf（widget 测试里读它纯属浪费时间）。
  Future<void> pumpSettings(
    WidgetTester tester,
    AccountProfile? profile, {
    SharedPreferences? prefs,
    StoragePaths? storagePaths,
    bool bundledFontAvailable = false,
    bool settle = true,
  }) async {
    final SharedPreferences readyPrefs = prefs ?? await newPrefs();

    final ZhyThemeSettings settings = const ZhyThemeSettings(
      material: ZhyWindowMaterial.solid,
    );

    await tester.pumpWidget(
      ProviderScope(
        // 不写显式类型参数：Riverpod 3 没有从 flutter_riverpod 导出 Override。
        overrides: [
          sharedPreferencesProvider.overrideWithValue(readyPrefs),
          coverCacheProvider.overrideWithValue(_StubCoverCache()),
          if (storagePaths != null)
            storagePathsProvider.overrideWithValue(storagePaths),
          bundledFontAvailableProvider.overrideWith(
            (Ref ref) async => bundledFontAvailable,
          ),
          neteaseAccountProvider.overrideWith(
            () => _StubAccountNotifier(profile),
          ),
          bilibiliAccountProvider.overrideWith(
            () => _StubAccountNotifier(null),
          ),
        ],
        child: MaterialApp(
          theme: buildZhyTheme(
            scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            tokens: buildZhyTokens(settings, Brightness.light),
            material: settings.material,
          ),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('账户分区：一级标题、音源切换与二级标题都在', (WidgetTester tester) async {
    await pumpSettings(tester, null);

    // 一级标题。
    expect(find.text('账户'), findsOneWidget);
    // 顶部音源切换。
    expect(find.widgetWithText(ChoiceChip, '网易云音乐'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '哔哩哔哩'), findsOneWidget);
    // 二级标题 + 正文。
    expect(find.text('登录状态'), findsOneWidget);
    expect(find.text('刷新账号信息'), findsOneWidget);
    expect(find.text('用户 ID'), findsNothing);
  });

  testWidgets('未登录时给出「登录」按钮，而不是只显示"未登录"', (WidgetTester tester) async {
    await pumpSettings(tester, null);

    // 这一条是本测试的重点。
    // 截图核对时曾经出现过"整行只有 未登录 三个字、右侧按钮不见了"的观感，
    // 于是把"按钮必须真的在树里"固化成断言 —— 靠肉眼看浅色主题下的
    // 低对比度按钮非常不可靠。
    expect(
      find.widgetWithText(FilledButton, '登录'),
      findsOneWidget,
      reason: '未登录时账户分区必须提供一个明确的登录入口',
    );
  });

  testWidgets('已登录时展示账号信息并提供退出入口', (WidgetTester tester) async {
    const AccountProfile profile = AccountProfile(
      source: MediaSource.netease,
      userId: '1535266197',
      nickname: '君游虚无',
      vipLabel: '黑胶VIP',
    );
    await pumpSettings(tester, profile);

    expect(find.text('君游虚无'), findsWidgets);
    expect(find.text('用户 ID'), findsOneWidget);
    expect(find.text('1535266197'), findsOneWidget);
    expect(find.text('会员身份'), findsOneWidget);
    expect(find.text('黑胶VIP'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '退出登录'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '登录'), findsNothing);
  });

  testWidgets('「播放」菜单里有音质、无缝衔接与淡入淡出', (WidgetTester tester) async {
    await pumpSettings(tester, null);
    final Finder list = find.byType(Scrollable).first;

    // 「播放」在列表靠下的位置，需要滚动才会被构建 —— 顺带证明它真的
    // 是一个可滚到的分区，而不是写了却没挂上去。
    await tester.scrollUntilVisible(find.text('播放'), 300, scrollable: list);
    expect(find.text('播放'), findsOneWidget, reason: '播放菜单必须存在');

    await tester.scrollUntilVisible(
      find.text('无缝衔接'),
      300,
      scrollable: list,
    );
    expect(find.text('无缝衔接'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('淡入淡出'),
      300,
      scrollable: list,
    );
    expect(find.text('淡入淡出'), findsOneWidget);

    // 音质分组也在这个菜单里（按用户要求从独立分区并进来）。
    expect(find.text('音质'), findsOneWidget);
    // 两个音源各有一条「自动（目标：…）」，所以是 2 个。
    expect(find.textContaining('自动（目标：'), findsNWidgets(2));
  });

  testWidgets('「存储路径」分区：完整路径、四个动作与代价说明都在', (WidgetTester tester) async {
    // 这一条验的是**界面**，所以所有异步步骤都不做真实磁盘 IO：
    // `pumpAndSettle` 不会为真实 IO 让出事件循环，一个"正在等磁盘"的 Future
    // 会让它一直转下去（实测会挂到超时）。这里把目录创建、可写性探测、占用
    // 统计全部换成立即完成的注入实现 —— 真实 IO 的行为由
    // `storage_paths_test.dart` 覆盖，那里用的是真目录。
    const String fakeCache = r'Z:\Fake\ZhuoYue\cache';
    const String fakeMusic = r'Z:\Fake\Music';
    SharedPreferences.setMockInitialValues(<String, Object>{
      StoragePaths.cacheDirectoryKey: fakeCache,
      StoragePaths.downloadDirectoryKey: fakeMusic,
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    await pumpSettings(
      tester,
      null,
      prefs: prefs,
      // 真实例，但环境变量、安装器目录、应用支持目录、可写性探测全是假的。
      storagePaths: StoragePaths(
        preferences: prefs,
      io: InMemoryStorageFileIo(),
        environment: (String name) => null,
        installerFileDirectory: Directory.systemTemp,
        supportDirectory: () async => Directory.systemTemp,
        tempDirectory: () async => Directory.systemTemp,
      ),
    );

    final Finder list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('存储路径'),
      300,
      scrollable: list,
    );
    await tester.pump();

    // 完整路径必须原样出现在界面上（长路径不能被截成看不出是哪个盘）。
    // 而且它必须是**同步**就上屏的：用户选中/存下来的值不该等任何探测。
    expect(selectableText(fakeCache), findsOneWidget);
    expect(selectableText(fakeMusic), findsOneWidget);

    // 两个目录各有「更改… / 打开 / 复制路径 / 恢复默认」。
    expect(find.textContaining('更改缓存目录'), findsOneWidget);
    expect(find.textContaining('更改下载目录'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '打开'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, '复制路径'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, '恢复默认'), findsNWidgets(2));

    // 代价必须写出来：这里没有实现自动搬运，所以只能如实说旧文件留在原地。
    expect(
      find.textContaining('不会被搬走'),
      findsOneWidget,
      reason: '只给一个按钮却不写清楚代价，用户会以为改完缓存就跟着走了',
    );
    // 以及"哪一部分还没跟着走"。
    expect(
      find.textContaining('歌单 / 收藏的本地缓存仍然写在应用支持目录'),
      findsOneWidget,
      reason: '不能假装所有缓存都跟着这个目录走',
    );
    // 安装目录是只读信息。
    expect(find.text('安装目录'), findsOneWidget);
  });

  testWidgets('内置字体没随包分发时：选项被标注并禁用，且给出解释', (WidgetTester tester) async {
    await pumpSettings(tester, null, bundledFontAvailable: false);

    final Finder list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('字体'), 300, scrollable: list);

    // 这一档还在（设置里可能正存着它），但被标注了。
    final Finder marked = find.text('竹石（内置）（未随本安装包分发）');
    expect(marked, findsOneWidget);

    // 解释里必须出现"没有随附"与"系统默认"两件事。
    expect(find.textContaining('没有随附内置字体'), findsOneWidget);
    expect(find.textContaining('系统默认字体'), findsWidgets);

    // 点了不会改变设置：它是个禁用项，而不是一个"点了没反应"的假选项。
    await tester.ensureVisible(marked);
    await tester.pumpAndSettle();
    await tester.tap(marked, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.text('项目内置的 zhuzi.ttf，中文小字最清晰'),
      findsOneWidget,
      reason: '禁用之后点击不该把设置切走',
    );
  });

  testWidgets('内置字体在包里时：选项正常可选，不出现缺失提示', (WidgetTester tester) async {
    await pumpSettings(tester, null, bundledFontAvailable: true);

    final Finder list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('字体'), 300, scrollable: list);

    expect(find.text('竹石（内置）'), findsOneWidget);
    expect(find.textContaining('未随本安装包分发'), findsNothing);
    expect(find.textContaining('没有随附内置字体'), findsNothing);
  });
}
