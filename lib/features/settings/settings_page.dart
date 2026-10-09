import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/cache/cover_cache.dart';
import '../../core/flags/feature_flags.dart';
import '../../core/storage/preferences.dart';
import '../../core/storage/storage_paths.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_utils.dart';
import '../../core/theme/color_variant.dart';
import '../../core/theme/monet.dart';
import '../../core/theme/theme_providers.dart';
import '../../core/theme/theme_settings.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/theme/window_material.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/glass.dart';
import '../../core/utils/format.dart';
import '../../core/window/window_effects.dart';
import '../../core/window/window_providers.dart';
import '../../data/bilibili/bilibili_repository.dart';
import '../../data/models/audio_quality.dart';
import '../../data/models/collection.dart';
import '../../data/models/media_source.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';
import '../account/account_providers.dart';
import '../account/login_dialog.dart';
import '../diagnostics/log_panel.dart';
import '../player/playback_extras.dart';

/// 设置页：账户 / 外观 / 字体 / 音质 / 主题色 / 配色方案 / 窗口材质 / 维护 / 实验。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: const <Widget>[
        _PageHeader(),
        SizedBox(height: 16),
        _AccountSectionCard(),
        SizedBox(height: 14),
        _SectionCard(
          title: '外观模式',
          subtitle: '深浅色跟随系统，或手动固定',
          child: _ModeSelector(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '字体',
          subtitle: '内置竹石 / 系统默认 / 导入本机 ttf 应用到全局',
          child: _FontSection(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '播放',
          subtitle: '播放策略：音质、无缝衔接与淡入淡出',
          child: _PlaybackSection(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '主题色来源',
          subtitle: '主色可以由专辑封面实时推导，也可以由你指定',
          child: _SeedSourceSection(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '配色方案',
          subtitle: 'Material You 的配色变体与对比度',
          child: _VariantSection(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '窗口材质',
          subtitle: '亚克力 / Mica / 自绘磨砂，以及透明度与磨砂强度',
          child: _WindowMaterialSection(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '维护',
          subtitle: '封面缓存与设置重置',
          child: _MaintenanceSection(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '存储路径',
          subtitle: '缓存与下载文件写在哪，以及安装时选过的路径是否还在生效',
          child: _StoragePathsSection(),
        ),
        SizedBox(height: 14),
        _SectionCard(
          title: '实验',
          subtitle: '还没验证过、或只在特定场景里才有用的能力，默认关闭',
          child: _ExperimentalSection(),
        ),
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '设置',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '所有改动即时生效，并会自动保存到本地',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 一级/二级标题与正文的排版骨架
// ---------------------------------------------------------------------------

/// 二级分组的一级标题。
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.title, this.caption});

  final String title;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        if (caption != null) ...<Widget>[
          const SizedBox(width: 8),
          Text(
            caption!,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(width: 12),
        Expanded(
          child: Divider(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// 一行设置项：左侧二级标题 + 正文说明，右侧取值与操作。
///
/// 左侧列宽固定，保证整列标签对齐；右侧用 [Expanded] 吃掉剩余宽度，
/// 于是「取值」列也天然对齐 —— 这是设置页最影响可读性的一点。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    this.description,
    this.value,
    this.leading,
    this.trailing,
    this.last = false,
  });

  final String label;
  final String? description;
  final String? value;
  final Widget? leading;
  final Widget? trailing;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 132,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (description != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        description!,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.35,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  value ?? '',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
        if (!last)
          Divider(
            color: scheme.outlineVariant.withValues(alpha: 0.3),
            height: 1,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 外观模式
// ---------------------------------------------------------------------------

class _ModeSelector extends ConsumerWidget {
  const _ModeSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final ThemeSettingsNotifier notifier = ref.read(
      themeSettingsProvider.notifier,
    );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final ZhyThemeMode mode in ZhyThemeMode.values)
          ChoiceChip(
            label: Text(mode.label),
            selected: settings.mode == mode,
            onSelected: (_) => notifier.setMode(mode),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 账户
// ---------------------------------------------------------------------------

/// 账户设置。
///
/// 三级层次：一级标题（账户 / 某音源账户）、二级标题（选项名，左列固定宽）、
/// 正文（取值与说明）。两个音源共用一个卡片、顶部切换 —— 绝大多数设置对
/// 两者是共用的，只有账户信息本身分源。
class _AccountSectionCard extends ConsumerStatefulWidget {
  const _AccountSectionCard();

  @override
  ConsumerState<_AccountSectionCard> createState() =>
      _AccountSectionCardState();
}

class _AccountSectionCardState extends ConsumerState<_AccountSectionCard> {
  MediaSource _source = MediaSource.netease;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AccountProfile? profile = _source == MediaSource.netease
        ? ref.watch(neteaseAccountProvider)
        : ref.watch(bilibiliAccountProvider);

    return GlassPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '账户',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '登录凭据只保存在本机，用于直接访问你自己的账号数据',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final MediaSource item in const <MediaSource>[
                MediaSource.netease,
                MediaSource.bilibili,
              ])
                ChoiceChip(
                  label: Text(item.label),
                  // 已登录的一侧带个点，切之前就能看出两边状态。
                  avatar:
                      (item == MediaSource.netease
                              ? ref.watch(neteaseAccountProvider)
                              : ref.watch(bilibiliAccountProvider)) !=
                          null
                      ? Icon(
                          Icons.check_circle_rounded,
                          size: 14,
                          color: scheme.primary,
                        )
                      : null,
                  selected: _source == item,
                  onSelected: (_) => setState(() => _source = item),
                ),
            ],
          ),
          const SizedBox(height: 18),
          _GroupHeading(
            title: '${_source.label}账户',
            caption: profile == null ? '未登录' : '已登录',
          ),
          const SizedBox(height: 6),
          _SettingRow(
            label: '登录状态',
            description: profile == null ? '登录后可同步歌单与收藏' : '凭据有效',
            value: profile?.nickname ?? '未登录',
            leading: profile?.avatarUrl == null
                ? null
                : ClipOval(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CoverImage(url: profile!.avatarUrl, size: 28),
                    ),
                  ),
            trailing: profile == null
                ? FilledButton.icon(
                    onPressed: () => showLoginDialog(context),
                    icon: const Icon(Icons.login_rounded, size: 15),
                    label: const Text('登录'),
                  )
                : OutlinedButton.icon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout_rounded, size: 15),
                    label: const Text('退出登录'),
                  ),
          ),
          if (profile != null) ...<Widget>[
            _SettingRow(
              label: '用户 ID',
              description: '账号在${_source.label}的唯一标识',
              value: profile.userId,
            ),
            _SettingRow(
              label: '会员身份',
              description: '决定「自动」音质能选到哪一档',
              value: profile.vipLabel ?? '普通用户',
            ),
          ],
          _SettingRow(
            label: '刷新账号信息',
            description: '凭据可能在服务端失效，重新校验一次',
            trailing: OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 15),
              label: const Text('刷新'),
            ),
            last: _source != MediaSource.bilibili,
          ),
          if (_source == MediaSource.bilibili) ...<Widget>[
            if (profile == null)
              const _SettingRow(
                label: '为什么容易掉线',
                // 这是必然会发生、且最容易被当成 bug 的现象：
                // 网易云还好好的、哔哩却变未登录。
                description:
                    '哔哩的 SESSDATA 有效期明显短于网易云的 MUSIC_U，'
                    '过期后只能重新扫码；扫码登录拿不到续期所需的 ac_time_value，'
                    '所以客户端无法替你自动续期',
                value: '需要重新扫码',
              ),
            const _BilibiliTargetFolderRow(),
          ],
        ],
      ),
    );
  }

  Future<void> _refresh() async {
    final AccountNotifier notifier = _source == MediaSource.netease
        ? ref.read(neteaseAccountProvider.notifier)
        : ref.read(bilibiliAccountProvider.notifier);
    await notifier.refresh();
    if (!mounted) return;
    final AccountProfile? profile = _source == MediaSource.netease
        ? ref.read(neteaseAccountProvider)
        : ref.read(bilibiliAccountProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          profile == null
              ? '${_source.label}未登录或登录已失效'
              : '账户信息已更新：${profile.nickname}',
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final AccountNotifier notifier = _source == MediaSource.netease
        ? ref.read(neteaseAccountProvider.notifier)
        : ref.read(bilibiliAccountProvider.notifier);
    await notifier.logout();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已退出${_source.label}账户')));
  }
}

/// 哔哩的「收藏到哪个收藏夹」。
///
/// 不是可有可无的装饰：哔哩的收藏接口必须指定明确的目标收藏夹，
/// 用户有多个收藏夹时不指定就直接报错。与其等收藏失败再让用户猜，
/// 不如把选择摆在设置里。
class _BilibiliTargetFolderRow extends ConsumerStatefulWidget {
  const _BilibiliTargetFolderRow();

  @override
  ConsumerState<_BilibiliTargetFolderRow> createState() =>
      _BilibiliTargetFolderRowState();
}

class _BilibiliTargetFolderRowState
    extends ConsumerState<_BilibiliTargetFolderRow> {
  List<MusicCollection>? _folders;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final List<MusicCollection> folders = await ref
          .read(bilibiliRepositoryProvider)
          .myCollections();
      if (mounted) setState(() => _folders = folders);
    } on Object {
      // 未登录时拿不到收藏夹是正常状态，不当错误处理。
      if (mounted) setState(() => _folders = const <MusicCollection>[]);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick() async {
    final List<MusicCollection> folders = _folders ?? const <MusicCollection>[];
    if (folders.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('还没有可用的收藏夹，请先登录哔哩哔哩')));
      return;
    }
    final String? current = ref.read(bilibiliRepositoryProvider).targetFolderId;

    final MusicCollection? picked = await showDialog<MusicCollection>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('选择收藏目标夹'),
        children: <Widget>[
          for (final MusicCollection folder in folders)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(folder),
              child: Row(
                children: <Widget>[
                  Icon(
                    folder.id == current
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 16,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(folder.name)),
                  Text(
                    '${folder.trackCount} 首',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    if (picked == null || !mounted) return;
    await ref.read(bilibiliRepositoryProvider).setTargetFolder(picked.id);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('收藏目标夹已设为「${picked.name}」')));
  }

  @override
  Widget build(BuildContext context) {
    final String? targetId = ref
        .watch(bilibiliRepositoryProvider)
        .targetFolderId;
    final List<MusicCollection> folders = _folders ?? const <MusicCollection>[];
    String label = '未设置';
    if (targetId != null) {
      for (final MusicCollection folder in folders) {
        if (folder.id == targetId) {
          label = folder.name;
          break;
        }
      }
      // 列表还没加载出来时至少显示 id，别让用户以为设置丢了。
      if (label == '未设置') label = '收藏夹 $targetId';
    }

    return _SettingRow(
      label: '收藏目标夹',
      description: '收藏歌曲时写入哪个哔哩收藏夹',
      value: _loading ? '读取中…' : label,
      trailing: OutlinedButton.icon(
        onPressed: _loading ? null : _pick,
        icon: const Icon(Icons.folder_outlined, size: 15),
        label: const Text('选择'),
      ),
      last: true,
    );
  }
}

// ---------------------------------------------------------------------------
// 字体
// ---------------------------------------------------------------------------

/// 全局字体设置。
///
/// 附带**实时预览**（粗体 / 密集笔画 / 拉丁数字）：字体好不好看很难靠
/// 「竹石 / 系统默认」这两个词判断，用户真正关心的是"中文小字糊不糊"。
///
/// 另一件必须在这里做的事：**内置字体可能根本不在安装包里**
/// （`packaging/README.md`：它的再分发许可未经核实，打包时被移除）。
/// 那种情况下「竹石（内置）」如果还画成一个能选的选项，用户点了之后什么都
/// 不会变 —— 这比少一个选项糟得多，所以这里根据实际资源存在性把它禁掉，
/// 并明确写出"为什么没有"。
class _FontSection extends ConsumerWidget {
  const _FontSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final ThemeSettingsNotifier notifier = ref.read(
      themeSettingsProvider.notifier,
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;

    // 资源存在性是异步查出来的（`rootBundle.load` 要读资源表）。
    // 还没查完时**先按"存在"渲染**：源码仓库里绝大多数情况它确实存在，
    // 而反过来先禁用再启用会让选项闪一下、还会把已经选中的档位吞掉。
    final AsyncValue<bool> bundledFont = ref.watch(
      bundledFontAvailableProvider,
    );
    final bool? bundledAvailable = switch (bundledFont) {
      AsyncData<bool>(:final bool value) => value,
      _ => null,
    };
    final bool bundledMissing = bundledAvailable == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final ZhyFontSource source in ZhyFontSource.values)
              _buildFontChip(
                ref: ref,
                notifier: notifier,
                settings: settings,
                source: source,
                bundledMissing: bundledMissing,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          settings.fontSource.description,
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        if (bundledMissing) ...<Widget>[
          const SizedBox(height: 10),
          // 一句话说清"为什么这一档没用了" + "默认字体现在实际是什么"。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.tertiary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(tokens.cardRadius),
              border: Border.all(
                color: scheme.tertiary.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: scheme.tertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _bundledFontNotice(settings.fontSource),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: scheme.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (settings.fontSource == ZhyFontSource.custom) ...<Widget>[
          const SizedBox(height: 14),
          _SettingRow(
            label: '字体文件',
            description: settings.customFontPath == null
                ? '尚未导入'
                : _shortenPath(settings.customFontPath!),
            value: settings.customFontLabel ?? '未选择',
            trailing: OutlinedButton.icon(
              onPressed: () => unawaited(_pickFont(context, ref)),
              icon: const Icon(Icons.file_open_outlined, size: 15),
              label: const Text('导入'),
            ),
            last: true,
          ),
        ],
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(tokens.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '字体预览 · 卓越播放器',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '中文小字：正在播放 发现音乐 我的歌单 哔哩收藏 下载管理 设置',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                '密集笔画：摩羯座 曦 鑫 龘 懿 囊 疆 赢',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                'Latin & digits: ZhuoYue Player 0123456789',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '次要文字与行高：还没有正在播放的曲目，去发现音乐挑一首吧',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 内置字体缺失时的那段说明。
  ///
  /// 分开写的原因是它有两种情况要交代：用户**当前选的就是竹石**（必须解释
  /// "你选的那个现在没生效"），以及用户选的是别的档位（只需要说清现状）。
  /// 两者混在一句话里会变成一段没人读得懂的括号套括号。
  static String _bundledFontNotice(ZhyFontSource current) {
    // `bundledFontMissingNotice()` 是可空返回（它在"字体其实在"时给 null）。
    // 这个函数只在字体确实缺失时才被调用，所以正常情况下不会是 null；
    // 这里按空串兜底，免得为了一个不该发生的情况崩掉设置页。
    final String missing = bundledFontMissingNotice() ?? '';
    if (current == ZhyFontSource.zhuzi) {
      return '$missing\n${bundledFontFallbackNotice() ?? ''}'
          '下面改选「系统默认」可以明确地表达这个状态。';
    }
    if (current == ZhyFontSource.custom) {
      return '$missing\n当前生效的是：自定义字体（与内置字体无关）。';
    }
    return '$missing\n当前生效的是：系统默认字体。';
  }

  /// 一个字体档位的选项。
  ///
  /// 内置字体不在包里时：**标签上标注 + 直接禁用**。禁用（`onSelected: null`）
  /// 比"点了不生效"诚实得多 —— 后者会让用户以为是应用坏了。
  /// 如果它恰好正是当前选中的档位，仍然要把它画成选中状态：因为设置里确实
  /// 存的就是它，假装没选过反而会让"设置为什么和界面不一致"变成一个谜。
  static Widget _buildFontChip({
    required WidgetRef ref,
    required ThemeSettingsNotifier notifier,
    required ZhyThemeSettings settings,
    required ZhyFontSource source,
    required bool bundledMissing,
  }) {
    final bool unavailable =
        bundledMissing && source == ZhyFontSource.zhuzi;
    final ChoiceChip chip = ChoiceChip(
      key: ValueKey<String>('font-source-${source.name}'),
      label: Text(
        unavailable ? '${source.label}（未随本安装包分发）' : source.label,
      ),
      selected: settings.fontSource == source,
      onSelected: unavailable ? null : (_) => notifier.setFontSource(source),
      tooltip: unavailable
          ? '当前安装包里没有 assets/fonts/zhuzi.ttf，这一档装了也不会生效'
          : null,
    );
    return chip;
  }

  /// 路径太长会把整行撑开，只保留末尾两级。
  static String _shortenPath(String path) {
    final List<String> parts = path
        .split(RegExp(r'[\\/]'))
        .where((String p) => p.isNotEmpty)
        .toList();
    if (parts.length <= 2) return path;
    return '…\\${parts[parts.length - 2]}\\${parts.last}';
  }

  static Future<void> _pickFont(BuildContext context, WidgetRef ref) async {
    try {
      const XTypeGroup group = XTypeGroup(
        label: '字体文件',
        extensions: <String>['ttf', 'otf', 'ttc'],
      );
      final XFile? file = await openFile(
        acceptedTypeGroups: <XTypeGroup>[group],
      );
      if (file == null) return;

      final String? error = await ref
          .read(themeSettingsProvider.notifier)
          .importCustomFont(file.path, file.name);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error ?? '已应用字体「${file.name}」'),
          duration: const Duration(seconds: 4),
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开文件选择器失败：$error')));
    }
  }
}

// ---------------------------------------------------------------------------
// 播放
// ---------------------------------------------------------------------------

/// 「播放」菜单：把与"怎么播"有关的设置集中到一处。
///
/// 分成两组：
/// - **音质**：选哪一档（本来是一个独立分区，按用户要求归进播放菜单，
///   因为它本质上是"播放策略"的一部分，而不是外观类设置）；
/// - **衔接**：切歌时怎么过渡 —— 无缝衔接（预解析下一首）与淡入淡出。
class _PlaybackSection extends ConsumerWidget {
  const _PlaybackSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final ThemeSettingsNotifier notifier = ref.read(
      themeSettingsProvider.notifier,
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _GroupHeading(title: '音质', caption: '按音源分别选择'),
        const SizedBox(height: 12),
        const _QualitySection(),

        const SizedBox(height: 4),
        Divider(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
          height: 24,
        ),
        const _GroupHeading(title: '衔接', caption: '切歌时怎么过渡'),
        const SizedBox(height: 2),

        // SwitchListTile 是 ListTile，背景与水波纹画在**最近的 Material** 上。
        // 外面套着 GlassPanel（带背景色的 DecoratedBox），Flutter 会断言
        // "水波纹看不见"并直接抛异常 —— 必须给它自己一层透明 Material。
        //
        // `borderRadius` + 左右各 12 的 `contentPadding` 是给悬停高亮留出
        // **横向余量**：原来 `contentPadding: zero` 让文字正好压在底色块的
        // 左边缘上，鼠标一移上去就像"阴影和字贴在一起"。现在底色块比文字
        // 左右各宽 12，并收成圆角，读起来才像一块独立的条目。
        Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            children: <Widget>[
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                dense: true,
                value: settings.gaplessPlayback,
                onChanged: notifier.setGaplessPlayback,
                title: const Text('无缝衔接', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  '提前解析下一首的播放地址，切歌时只差一次本地换流，不再有"卡一下"的空档。'
                  '（采样级无缝需要播放后端支持，Windows 后端不提供）',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                dense: true,
                value: settings.crossFade,
                onChanged: notifier.setCrossFade,
                title: const Text('淡入淡出', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  '曲尾渐弱、曲首渐强，避免突然起音或被硬掐断',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),

        if (settings.crossFade)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _SettingSlider(
              label: '渐变时长',
              hint: '单边时长，越长越柔',
              value: settings.crossFadeSeconds,
              min: 1,
              max: 12,
              display: '${settings.crossFadeSeconds.round()}s',
              onChanged: notifier.setCrossFadeSeconds,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 音质
// ---------------------------------------------------------------------------

/// 音质选择：每个音源各自一组档位。
///
/// 两者的音质体系根本对不上（网易云 128k→320k→无损→Hi-Res→母带，
/// 哔哩 64k→132k→192k + 杜比 + Hi-Res），用一套枚举硬套只会到处写 if。
///
/// 「自动」的含义是**按账号权益取最高**。原则只有一条：
/// 实际拿到什么由 `ResolvedStream.qualityLabel` 如实反映 ——
/// 服务端降级时播放条不会继续显示用户选的那一档。
class _QualitySection extends StatelessWidget {
  const _QualitySection();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MediaSource source in const <MediaSource>[
          MediaSource.netease,
          MediaSource.bilibili,
        ]) ...<Widget>[
          _QualityGroup(source: source),
          const SizedBox(height: 14),
        ],
        Text(
          '说明：会员权益不足时服务端会静默降级，播放条上显示的是实际拿到的音质。',
          style: TextStyle(
            fontSize: 10.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _QualityGroup extends ConsumerStatefulWidget {
  const _QualityGroup({required this.source});

  final MediaSource source;

  @override
  ConsumerState<_QualityGroup> createState() => _QualityGroupState();
}

class _QualityGroupState extends ConsumerState<_QualityGroup> {
  /// repository 不是 Notifier，改完不会自动触发重建，用它手动刷一次。
  int _epoch = 0;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final MusicRepository? repository = repositoryForWidget(ref, widget.source);
    if (repository == null) {
      return Text(
        '${widget.source.label}：音源实现未注册',
        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
      );
    }

    final String preferred = repository.preferredQualityId;
    final AudioQuality effective = repository.effectiveQuality;
    final AccountProfile? profile = widget.source == MediaSource.netease
        ? ref.watch(neteaseAccountProvider)
        : ref.watch(bilibiliAccountProvider);

    return Column(
      key: ValueKey<int>(_epoch),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              widget.source == MediaSource.netease
                  ? Icons.music_note_rounded
                  : Icons.video_library_rounded,
              size: 14,
              color: scheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              widget.source.label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 10),
            // 当前账号的会员身份 —— 「自动」选到哪一档直接取决于它。
            Text(
              profile == null ? '未登录' : (profile.vipLabel ?? '普通账号'),
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ChoiceChip(
              // 说"目标"而不是"当前"：自动档请求的是**账号允许的最高档**，
              // 单曲不一定有这一档（网易云里有些歌就是没有无损），那时
              // 服务端会给低一档，播放条上显示的是实际拿到的那一档。
              // 写"当前：无损"会让人以为"现在放的就是无损"，那才是误导。
              label: Text('自动（目标：${effective.label}）'),
              selected: preferred == kAutoQualityId,
              onSelected: (_) => _apply(repository, kAutoQualityId),
            ),
            for (final AudioQuality quality in repository.audioQualities)
              Tooltip(
                message: quality.description ?? quality.label,
                child: ChoiceChip(
                  label: Text(quality.label),
                  selected: preferred == quality.id,
                  onSelected: (_) => _apply(repository, quality.id),
                ),
              ),
          ],
        ),
      ],
    );
  }

  void _apply(MusicRepository repository, String qualityId) {
    unawaited(repository.setPreferredQuality(qualityId));
    setState(() => _epoch++);
  }
}

// ---------------------------------------------------------------------------
// 主题色来源
// ---------------------------------------------------------------------------

class _SeedSourceSection extends ConsumerWidget {
  const _SeedSourceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final ThemeSettingsNotifier notifier = ref.read(
      themeSettingsProvider.notifier,
    );
    final MonetPalette? palette = ref.watch(coverPaletteProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final ZhySeedSource source in ZhySeedSource.values)
              ChoiceChip(
                label: Text(source.label),
                selected: settings.seedSource == source,
                onSelected: (_) => notifier.setSeedSource(source),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          settings.seedSource.description,
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (settings.seedSource == ZhySeedSource.cover)
          _PalettePreview(palette: palette),
        if (settings.seedSource == ZhySeedSource.custom)
          _CustomColorPicker(
            current: settings.customSeedArgb,
            onChanged: notifier.setCustomSeed,
          ),
      ],
    );
  }
}

/// 展示莫奈取色的实际结果：候选色 + HCT 分量。
class _PalettePreview extends StatelessWidget {
  const _PalettePreview({required this.palette});

  final MonetPalette? palette;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final MonetPalette? current = palette;

    if (current == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(tokens.cardRadius),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.palette_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '还没有解析出封面色。播放一首带封面的歌，主题色会自动跟随封面变化。',
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final List<Color> candidates = current.rankedColors.take(8).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final Color color in candidates)
              Expanded(
                child: Tooltip(
                  message: ZhyColor.toHexRgb(color.toARGB32()),
                  child: Container(
                    height: 34,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '种子色 ${ZhyColor.toHexRgb(current.seedArgb)} · '
          'HCT ${current.hue.toStringAsFixed(0)}° / '
          '${current.chroma.toStringAsFixed(0)} / '
          '${current.tone.toStringAsFixed(0)} · '
          '候选 ${current.rankedArgb.length} 色',
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurfaceVariant,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 自定义颜色：预设 + 色相/饱和度/明度滑杆 + 十六进制输入。
///
/// 没有用二维取色盘：桌面端用三个滑杆加十六进制输入，精确度和可复现性
/// 都比「用鼠标在一个方框里戳」更好。
class _CustomColorPicker extends StatefulWidget {
  const _CustomColorPicker({required this.current, required this.onChanged});

  final int current;
  final ValueChanged<int> onChanged;

  @override
  State<_CustomColorPicker> createState() => _CustomColorPickerState();
}

class _CustomColorPickerState extends State<_CustomColorPicker> {
  late final TextEditingController _hexController = TextEditingController(
    text: ZhyColor.toHexRgb(widget.current),
  );
  late HSLColor _hsl = HSLColor.fromColor(Color(widget.current));

  @override
  void didUpdateWidget(covariant _CustomColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有外部真的换了颜色（例如点了预设）才同步回本地控件，
    // 否则会把用户正在输入的十六进制值覆盖掉。
    if (oldWidget.current != widget.current &&
        Color(widget.current).toARGB32() != _hsl.toColor().toARGB32()) {
      _hsl = HSLColor.fromColor(Color(widget.current));
      _hexController.text = ZhyColor.toHexRgb(widget.current);
    }
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _emit() {
    final int argb = _hsl.toColor().toARGB32();
    _hexController.text = ZhyColor.toHexRgb(argb);
    widget.onChanged(argb);
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color preview = _hsl.toColor();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final ZhySeedPreset preset in kZhySeedPresets)
              Tooltip(
                message: preset.name,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _hsl = HSLColor.fromColor(preset.color);
                      _hexController.text = ZhyColor.toHexRgb(preset.argb);
                    });
                    widget.onChanged(preset.argb);
                  },
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: preset.color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.current == preset.argb
                            ? scheme.onSurface
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                children: <Widget>[
                  _LabelledSlider(
                    label: '色相',
                    value: _hsl.hue,
                    max: 360,
                    gradient: const LinearGradient(
                      colors: <Color>[
                        Color(0xFFFF0000),
                        Color(0xFFFFFF00),
                        Color(0xFF00FF00),
                        Color(0xFF00FFFF),
                        Color(0xFF0000FF),
                        Color(0xFFFF00FF),
                        Color(0xFFFF0000),
                      ],
                    ),
                    onChanged: (double value) {
                      setState(() => _hsl = _hsl.withHue(value));
                      _emit();
                    },
                  ),
                  _LabelledSlider(
                    label: '饱和度',
                    value: _hsl.saturation * 100,
                    max: 100,
                    activeColor: preview,
                    onChanged: (double value) {
                      setState(
                        () => _hsl = _hsl.withSaturation(
                          (value / 100).clamp(0.0, 1.0),
                        ),
                      );
                      _emit();
                    },
                  ),
                  _LabelledSlider(
                    label: '明度',
                    value: _hsl.lightness * 100,
                    max: 100,
                    activeColor: preview,
                    onChanged: (double value) {
                      setState(
                        () => _hsl = _hsl.withLightness(
                          (value / 100).clamp(0.0, 1.0),
                        ),
                      );
                      _emit();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Column(
              children: <Widget>[
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: preview,
                    borderRadius: BorderRadius.circular(tokens.cardRadius),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: 118,
                  child: TextField(
                    controller: _hexController,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, letterSpacing: 0.5),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9a-fA-F#]'),
                      ),
                      LengthLimitingTextInputFormatter(9),
                    ],
                    onSubmitted: (String value) {
                      final int? parsed = ZhyColor.tryParseHex(value);
                      if (parsed == null) {
                        // 输入非法就退回当前值：改错一个字符就报错会很吵。
                        _hexController.text = ZhyColor.toHexRgb(widget.current);
                        return;
                      }
                      setState(() => _hsl = HSLColor.fromColor(Color(parsed)));
                      widget.onChanged(parsed);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _LabelledSlider extends StatelessWidget {
  const _LabelledSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
    this.gradient,
    this.activeColor,
  });

  final String label;
  final double value;
  final double max;
  final ValueChanged<double> onChanged;
  final Gradient? gradient;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              if (gradient != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: gradient != null ? 0 : 4,
                  inactiveTrackColor: gradient != null
                      ? Colors.transparent
                      : scheme.surfaceContainerHighest,
                  activeTrackColor: gradient != null
                      ? Colors.transparent
                      : activeColor,
                ),
                child: Slider(
                  value: value.clamp(0, max),
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            value.toStringAsFixed(0),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 配色方案
// ---------------------------------------------------------------------------

class _VariantSection extends ConsumerWidget {
  const _VariantSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final ThemeSettingsNotifier notifier = ref.read(
      themeSettingsProvider.notifier,
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            for (final ZhyColorVariant variant in ZhyColorVariant.values)
              _VariantCard(
                variant: variant,
                selected: settings.variant == variant,
                onTap: () => notifier.setVariant(variant),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          '对比度',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final ZhyContrastLevel level in ZhyContrastLevel.values)
              ChoiceChip(
                label: Text(level.label),
                selected: settings.contrast == level,
                onSelected: (_) => notifier.setContrast(level),
                tooltip: level.description,
              ),
          ],
        ),
      ],
    );
  }
}

class _VariantCard extends StatelessWidget {
  const _VariantCard({
    required this.variant,
    required this.selected,
    required this.onTap,
  });

  final ZhyColorVariant variant;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 用当前种子色现场算一遍这个变体，色票就是"它长什么样"的真实预览。
    final ColorScheme preview = ColorScheme.fromSeed(
      seedColor: scheme.primary,
      brightness: scheme.brightness,
      dynamicSchemeVariant: variant.scheme,
      contrastLevel: 0,
    );

    return SizedBox(
      width: 232,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: tokens.fast,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.secondaryContainer.withValues(alpha: 0.55)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(tokens.cardRadius),
              border: Border.all(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.7)
                    : scheme.outlineVariant.withValues(alpha: 0.4),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    for (final Color color in <Color>[
                      preview.primary,
                      preview.secondary,
                      preview.tertiary,
                      preview.primaryContainer,
                      preview.surfaceContainerHighest,
                    ])
                      Container(
                        width: 16,
                        height: 16,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    const Spacer(),
                    if (selected)
                      Icon(
                        Icons.check_circle_rounded,
                        size: 15,
                        color: scheme.primary,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  variant.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  variant.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.35,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 窗口材质
// ---------------------------------------------------------------------------

class _WindowMaterialSection extends ConsumerWidget {
  const _WindowMaterialSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyThemeSettings settings = ref.watch(themeSettingsProvider);
    final ThemeSettingsNotifier notifier = ref.read(
      themeSettingsProvider.notifier,
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final WindowsBackdropSupport support = ref.watch(
      windowsBackdropSupportProvider,
    );
    final AppliedBackdrop? applied = ref.watch(appliedBackdropProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              support.supportsBackdropType
                  ? Icons.verified_rounded
                  : Icons.info_outline_rounded,
              size: 15,
              color: support.isWindows11
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                support.buildNumber == 0
                    ? '未能读取系统版本，窗口材质可能不可用'
                    : '${support.label} · '
                          '${support.supportsBackdropType
                              ? "支持 Mica / 亚克力（DWM 背景类型）"
                              : support.supportsMica
                              ? "仅支持实验性 Mica"
                              : support.supportsAcrylic
                              ? "仅支持亚克力（强调色策略）"
                              : "仅支持传统高斯模糊"}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        if (applied?.note != null) ...<Widget>[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: scheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    applied!.note!,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            for (final ZhyWindowMaterial material in ZhyWindowMaterial.values)
              _MaterialCard(
                material: material,
                selected: settings.material == material,
                support: support,
                onTap: () => notifier.setMaterial(material),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingSlider(
          label: '背景不透明度',
          hint: '越高越实、越低越透',
          value: settings.windowOpacity,
          min: 0.30,
          max: 1.0,
          display: '${(settings.windowOpacity * 100).round()}%',
          onChanged: notifier.setWindowOpacity,
        ),
        _SettingSlider(
          label: '磨砂强度',
          hint: '模拟磨砂与玻璃面板的模糊半径',
          value: settings.blurSigma,
          min: 0,
          max: 80,
          display: settings.blurSigma.round().toString(),
          onChanged: notifier.setBlurSigma,
        ),
        _SettingSlider(
          label: '面板染色强度',
          hint: '玻璃面板自身的底色浓度，越低越通透',
          value: settings.panelOpacity,
          min: 0.0,
          max: 0.9,
          display: '${(settings.panelOpacity * 100).round()}%',
          onChanged: notifier.setPanelOpacity,
        ),
        const SizedBox(height: 6),
        // 同「播放」菜单：ListTile 的水波纹要画在最近的 Material 上，
        // 否则 debug 下会因"水波纹看不见"直接抛异常；
        // 左右各留 12 的 contentPadding 则是让悬停底色块横向比文字更宽。
        Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            children: <Widget>[
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                dense: true,
                value: settings.coverBackdrop,
                onChanged: notifier.setCoverBackdrop,
                title: const Text(
                  '用封面做磨砂底色',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '关闭后改用主题色渐变（没有封面时行为一致）',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                dense: true,
                value: settings.animatedBackdrop,
                onChanged: notifier.setAnimatedBackdrop,
                title: const Text('切歌时背景淡入', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  '关闭可省一点 GPU，但切歌会显得生硬',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MaterialCard extends StatelessWidget {
  const _MaterialCard({
    required this.material,
    required this.selected,
    required this.support,
    required this.onTap,
  });

  final ZhyWindowMaterial material;
  final bool selected;
  final WindowsBackdropSupport support;
  final VoidCallback onTap;

  /// 当前系统上该材质的限制说明（提前告知，而不是等它静默降级）。
  String? get _limitation {
    if (material == ZhyWindowMaterial.mica && !support.supportsMica) {
      return '需要 Windows 11，当前会改用亚克力';
    }
    if (material == ZhyWindowMaterial.micaAlt &&
        !support.supportsBackdropType) {
      return '需要 Windows 11 22H2，当前会改用亚克力';
    }
    if (material == ZhyWindowMaterial.acrylic && !support.supportsAcrylic) {
      return '需要 Windows 10 1803 以上，当前会改用高斯模糊';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? limitation = _limitation;

    return SizedBox(
      width: 232,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: tokens.fast,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.secondaryContainer.withValues(alpha: 0.55)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(tokens.cardRadius),
              border: Border.all(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.7)
                    : scheme.outlineVariant.withValues(alpha: 0.4),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      material.usesSystemEffect
                          ? Icons.layers_rounded
                          : Icons.brush_rounded,
                      size: 15,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      material.label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    if (selected)
                      Icon(
                        Icons.check_circle_rounded,
                        size: 15,
                        color: scheme.primary,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  material.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.35,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (limitation != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    limitation,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.error.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.hint,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 116,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: scheme.onSurface),
                ),
                Text(
                  hint,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 46,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 维护
// ---------------------------------------------------------------------------

class _MaintenanceSection extends ConsumerStatefulWidget {
  const _MaintenanceSection();

  @override
  ConsumerState<_MaintenanceSection> createState() =>
      _MaintenanceSectionState();
}

class _MaintenanceSectionState extends ConsumerState<_MaintenanceSection> {
  int? _cacheBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    final int bytes = await ref.read(coverCacheProvider).sizeOnDisk();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    await ref.read(coverCacheProvider).clear();
    await _measure();
    if (mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('封面缓存已清空')));
    }
  }

  Future<void> _resetAll() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('重置所有设置？'),
        content: const Text('主题、配色、字体、音质、窗口材质都会回到默认值。播放队列与账号登录状态不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(themeSettingsProvider.notifier).resetToDefaults();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设置已恢复默认')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '封面缓存：${_cacheBytes == null ? "统计中…" : ZhyFormat.bytes(_cacheBytes)}',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _clear,
              icon: const Icon(Icons.delete_sweep_outlined, size: 15),
              label: const Text('清空缓存'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 调试日志入口。放在"维护"里而不是做成独立页面：
        // 它的使用场景是"某首歌突然播不了，我想看看刚才发生了什么"，
        // 属于临时排查，不该在侧边栏占一个永久的导航位。
        // 打开的是右侧滑入的 island（见 showLogPanel），
        // 所以进去看日志不会把当前所在的设置分区滚丢。
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '调试日志：查看应用内部输出，排查"为什么播放不了"',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => unawaited(showLogPanel(context)),
              icon: const Icon(Icons.terminal_rounded, size: 15),
              label: const Text('打开调试日志'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '恢复主题、字体与窗口的全部默认设置',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _resetAll,
              icon: const Icon(Icons.restart_alt_rounded, size: 15),
              label: const Text('重置设置'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          '关于',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '卓越播放器 v0.1.0 · 第三方网易云音乐客户端，支持播放哔哩哔哩收藏\n'
          '本项目仅供个人学习研究使用，与网易云音乐、哔哩哔哩官方无关，请支持正版。',
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 实验
// ---------------------------------------------------------------------------

/// 「实验」分区：把"能用但还不该默认出现"的能力挂在功能开关后面。
///
/// 开关列表**由注册表 [kFeatureFlags] 渲染**，不是一条条手写：加一个开关
/// 只需要在 `feature_flags.dart` 里加一条定义、补一个同名 getter，界面这边
/// 不用再改一遍（也就少了一处"加了开关却忘了画出它的开关"的可能）。
///
/// 这里的列表只负责**把开关画出来并写回取值**；每个开关的效果由它自己的
/// 读取点决定（`if (!flags.<id>) …`），两者刻意分开 —— 否则很容易变成
/// "开关只改了自己的显示状态、什么都没管住"。
class _ExperimentalSection extends ConsumerWidget {
  const _ExperimentalSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyFeatureFlags flags = ref.watch(featureFlagsProvider);
    final FeatureFlagsNotifier notifier = ref.read(
      featureFlagsProvider.notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '每个开关都写明了它管什么、为什么默认是关的。改动即时生效，不需要重启。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        // 与「播放」菜单同一套写法：ListTile 的水波纹要画在最近的 Material 上，
        // 左右各 12 的 contentPadding 则是给悬停底色留出横向余量。
        Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            children: <Widget>[
              for (final ZhyFeatureFlag flag in kFeatureFlags)
                SwitchListTile(
                  key: ValueKey<String>('feature-flag-${flag.id}'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  dense: true,
                  value: flags.isEnabled(flag),
                  onChanged: (bool value) => notifier.setEnabled(flag, value),
                  title: Text(
                    flag.label,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    flag.description,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            // 只在真的被改过之后给这个按钮：一直是默认值时它没有任何可做的事，
            // 摆一个点了没反应的按钮比没有更糟。
            onPressed: flags.isAllDefault
                ? null
                : () => unawaited(notifier.resetAll()),
            icon: const Icon(Icons.restart_alt_rounded, size: 15),
            label: const Text('全部恢复默认'),
          ),
        ),
        const SizedBox(height: 8),
        // 各开关管住的能力本体。关着的时候整个不渲染（SizedBox.shrink），
        // 不是"画出来但点不动"：一个点不动的入口比没有入口更让人困惑。
        const _RawPreferencesPanel(),
        const _EqualizerEntryRow(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 存储路径
// ---------------------------------------------------------------------------

/// 「存储路径」分区：缓存目录 / 下载目录 / 安装目录。
///
/// 三件事必须在这个界面上说清楚，否则它就是一堆会撒谎的路径文字：
/// 1. **路径要能看全**。设置页里以前的「字体文件」那一行只留末尾两级
///    （`…\a\b.ttf`），对字体文件够用，但目录不行 —— 用户要判断的是
///    "这是哪个盘"，而盘符恰好是最容易被截掉的那一段。所以这里用可换行、
///    可选中、可复制的完整路径。
/// 2. **改目录的代价要写出来**。这里**没有**实现自动搬运已有文件，所以只能
///    如实说明（文案来自 [StoragePaths.changeEffectNotice]，两处共用一句）。
/// 3. **哪些缓存还没跟着走要写出来**。歌单缓存（`collection_cache.dart`）目前
///    仍然写在应用支持目录下 —— 假装它也搬过来了是最容易招骂的一种"贴心"。
class _StoragePathsSection extends ConsumerStatefulWidget {
  const _StoragePathsSection();

  @override
  ConsumerState<_StoragePathsSection> createState() =>
      _StoragePathsSectionState();
}

class _StoragePathsSectionState extends ConsumerState<_StoragePathsSection> {
  /// 用户当前选中的目录（可能不同于"真正在用"的目录，见 [_effectiveCache]）。
  String? _cacheDir;
  String? _downloadDir;

  /// 真正能写的那个缓存目录。用户选的目录不可写时会与 [_cacheDir] 不同，
  /// 这时必须显示两个，而不是假装用户选的目录正在生效。
  String? _effectiveCache;

  /// 封面缓存目录现在占多大（null = 目录还不存在）。
  int? _cacheBytes;

  /// 安装目录（只读信息）与安装器配置的状态说明。
  String? _installDir;
  String? _installerNote;

  /// 用户选的缓存目录不可写时的原因。
  String? _cacheProblem;

  /// 「详细信息」这段异步读取是否已经跑完。
  ///
  /// 需要它是因为"没探测出可用目录"有两种意思：还没探测完，或者探测完发现
  /// 一个都不能用。两者对用户的含义完全不同（前者什么都不用说，后者必须说），
  /// 所以不能只看 [_effectiveCache] 是不是 null。
  bool _detailsReady = false;

  bool _busy = false;

  /// 缓存目录当前不可用时要显示的那句话（可用时为 null）。
  String? get _cacheUnavailable {
    if (!_detailsReady) return null;
    final String? problem = _cacheProblem;
    if (problem == null) return null;
    final String? effective = _effectiveCache;
    if (effective == null) {
      return '缓存目录当前不可用：$problem。'
          '在问题解决之前，封面缓存无法写盘（界面仍然可用）。';
    }
    if (effective != _cacheDir) {
      return '你选的缓存目录当前用不了（$problem），'
          '应用已经临时改用 $effective。问题解决后重启即可回到你选的目录。';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  /// 把三个目录与"安装器是否被采纳过"重新读一遍。
  ///
  /// 分两段，是有意的：
  /// 1. **同步段**：用户选中的目录/默认值只读内存与偏好，立刻上屏。这一段
  ///    绝不能失败，也不能等 —— 否则用户看到的是一句"读不到缓存目录"；
  /// 2. **异步段**：探测可写性、统计占用、读安装目录。这些可能碰到慢 IO
  ///    （甚至一个没响应的平台通道），所以它只负责"补充信息"：拿不到就少
  ///    显示一行字，绝不影响第 1 段已经上屏的内容。
  Future<void> _refresh() async {
    final StoragePaths paths = ref.read(storagePathsProvider);

    // 第 1 段：同步，先让界面有内容。
    final String? cache = paths.chosenDirectory(StorageDirectoryKind.cache);
    final String? download = paths.chosenDirectory(StorageDirectoryKind.download);
    if (mounted) {
      setState(() {
        _cacheDir = cache;
        _downloadDir = download;
      });
    }

    // 第 2 段：异步补充信息。
    //
    // **刻意不加超时**：这些步骤是一串依赖（读配置 → 探测目录 → 统计占用），
    // 给它们各挂一个定时器会让"卡住"变成更复杂的问题；而整段挂在真实时间的
    // 定时器上还有一个更实际的代价 —— widget 测试里 `pumpAndSettle` 不会为它
    // 推进时钟，于是测试会被一个永远不触发的定时器拖住。
    //
    // 不超时也不会把界面卡住：第 1 段已经把路径显示出来了，这一段只负责补上
    // "实际用的是哪个目录""占多大""安装目录在哪"，拿不到就少显示一行字。
    String? effective;
    String? problem;
    int? bytes;
    String? install;
    String? note;
    try {
      await _probeDetails(
        paths,
        onEffective: (String? value) => effective = value,
        onProblem: (String? value) => problem = value,
        onBytes: (int? value) => bytes = value,
        onInstall: (String? value) => install = value,
        onNote: (String? value) => note = value,
      );
    } on Object catch (error) {
      debugPrint('[settings] 读取存储路径的详细信息失败：$error');
      note = '读取存储路径的详细信息时出错（目录本身仍然可用）：$error';
    }

    if (!mounted) return;
    setState(() {
      _detailsReady = true;
      _effectiveCache = effective;
      _cacheProblem = problem;
      _cacheBytes = bytes;
      _installDir = install;
      _installerNote = note;
    });
  }

  /// 详细信息的实际读取（由 [_refresh] 调用）。
  Future<void> _probeDetails(
    StoragePaths paths, {
    required ValueChanged<String?> onEffective,
    required ValueChanged<String?> onProblem,
    required ValueChanged<int?> onBytes,
    required ValueChanged<String?> onInstall,
    required ValueChanged<String?> onNote,
  }) async {
    // 先采纳安装器的选择：否则首次运行的这个分区会显示默认目录，
    // 而用户"刚才在安装向导里明明选过"。
    final InstallerChoiceReport report = await paths
        .adoptInstallerChoicesIfNeeded();
    final StorageDirectoryProbe probe = await paths.ensureDirectory(
      StorageDirectoryKind.cache,
    );
    onEffective(probe.directory);
    onProblem(probe.failure);
    if (probe.directory != null) {
      onBytes(await paths.sizeOnDisk(probe.directory!));
    }
    onInstall(await paths.installDirectory());
    onNote(
      report.adopted
          ? '安装器写的路径已经生效'
          : (report.skippedReason ?? '没有可采纳的安装器路径'),
    );
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 让用户挑一个目录。返回 null 表示取消。
  Future<String?> _pickDirectory() async {
    try {
      return await getDirectoryPath(confirmButtonText: '选择此文件夹');
    } on Object catch (error) {
      debugPrint('[settings] 打开目录选择框失败：$error');
      _notify('无法打开目录选择框：$error');
      return null;
    }
  }

  Future<void> _change(StorageDirectoryKind kind) async {
    // 先取出实例，避免 await 之后再碰 BuildContext。
    final StoragePaths paths = ref.read(storagePathsProvider);
    final String? picked = await _pickDirectory();
    if (picked == null || picked.trim().isEmpty) return;

    setState(() => _busy = true);
    try {
      await paths.setDirectory(kind, picked);
      // 缓存目录的 provider 是 keepAlive 的：不显式作废的话，界面会继续显示
      // 旧目录 —— 那就成了最忌讳的"点了没反应"。
      ref.invalidate(cacheRootProvider);
      ref.invalidate(coverCacheDirectoryProvider);
      await _refresh();
      _notify(
        '${kind.label}已改为 $picked\n'
        '${StoragePaths.changeEffectNotice(kind)}',
      );
    } on StoragePathException catch (error) {
      // 这一层给的已经是中文原因（不可写 / 路径为空）。
      _notify(error.message);
    } on Object catch (error) {
      debugPrint('[settings] 设置${kind.label}失败：$error');
      _notify('设置${kind.label}失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset(StorageDirectoryKind kind) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('把${kind.label}恢复默认？'),
        content: Text(
          '${kind.label}会回到应用的默认位置：\n'
          '${ref.read(storagePathsProvider).defaultDirectory(kind) ?? '（环境变量缺失，算不出默认值）'}\n\n'
          '已经在这个目录里的文件不会被移动或删除。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final StoragePaths paths = ref.read(storagePathsProvider);
    setState(() => _busy = true);
    try {
      await paths.resetDirectory(kind);
      ref.invalidate(cacheRootProvider);
      ref.invalidate(coverCacheDirectoryProvider);
      await _refresh();
      _notify('${kind.label}已恢复默认');
    } on Object catch (error) {
      debugPrint('[settings] 恢复默认${kind.label}失败：$error');
      _notify('恢复默认${kind.label}失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String? path, String label) async {
    if (path == null || path.trim().isEmpty) {
      _notify('$label还没有确定，暂时打不开');
      return;
    }
    try {
      // 与下载页的「打开下载目录」共用同一份实现（见 storage_paths.dart）。
      await openDirectoryInExplorer(path);
    } on Object catch (error) {
      _notify('$error');
    }
  }

  Future<void> _copy(String? path, String label) async {
    if (path == null || path.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: path));
    _notify('已复制$label');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      key: const ValueKey<String>('storage-paths-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '这些目录也可以在安装向导里指定。如果指定过，应用会在第一次运行时'
          '把安装器的选择采纳为自己的设置，并记住"已经采纳"；之后你在下面改的值'
          '不会再被安装器的旧值覆盖。开发期直接运行程序时没有安装器配置，'
          '那不是错误 —— 用安装器的默认目录即可。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _installerNote ?? '正在读取安装器配置…',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),

        // 安装目录：只读信息。做成 "标签 + 值" 两列，而不是可点击的行 ——
        // 用户看到路径时最自然的反应是"那我能不能改"，这里必须明确说不能。
        _PathValue(
          label: '安装目录',
          value: _installDir,
          placeholder: '未知（没有安装器记录，也读不到 LOCALAPPDATA）',
          hint: '只读：应用不去改它，显示的是安装器当初写下的位置',
        ),
        const SizedBox(height: 14),

        _buildCacheBlock(),
        const SizedBox(height: 14),
        _buildDownloadBlock(),

        const SizedBox(height: 10),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.3), height: 20),
        Text(
          '下载目录在「下载管理」页里也有一个「更改目录」入口，两处改的是同一个设置。',
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        _NoticeBox(
          tone: _NoticeTone.warning,
          text:
              '还没有跟着走的部分：歌单 / 收藏的本地缓存仍然写在应用支持目录'
              '（%APPDATA%\\com.zhuoyue\\zhuoyue_player\\collections）下，'
              '它不随这里的「缓存目录」变化 —— 下一轮才会接上。'
              '另外下载任务列表（downloads\\tasks.json）也留在应用支持目录：'
              '它是"读不出来就丢状态"的存档，不适合和可以随时重建的封面缓存混在一起。',
        ),
        if (_cacheUnavailable != null) ...<Widget>[
          const SizedBox(height: 6),
          _NoticeBox(
            tone: _NoticeTone.error,
            text: _cacheUnavailable!,
          ),
        ],
      ],
    );
  }

  /// 缓存目录：路径 + 占用 + 四个动作。
  Widget _buildCacheBlock() {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '缓存目录',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        // 完整路径，允许换行也允许选中：长路径在这里**不该**被截成
        // "…\cache"，那样用户根本看不出是哪个盘。
        SelectableText(
          _cacheDir ?? '（读不到缓存目录）',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.45,
            fontFamily: 'Consolas',
            fontFamilyFallback: const <String>['Courier New', 'monospace'],
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _cacheBytes == null
              ? '封面缓存：还没有这个目录（首次写缓存时会自动创建）'
              : '封面缓存占用：${ZhyFormat.bytes(_cacheBytes)}',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        _buildActions(StorageDirectoryKind.cache, _cacheDir),
        const SizedBox(height: 6),
        _buildEffectNotice(StorageDirectoryKind.cache),
      ],
    );
  }

  /// 下载目录：路径 + 四个动作。
  Widget _buildDownloadBlock() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '下载目录',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(
          _downloadDir ?? '（读不到下载目录）',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.45,
            fontFamily: 'Consolas',
            fontFamilyFallback: const <String>['Courier New', 'monospace'],
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '真实文件按音源分子文件夹存放，例如「${MediaSource.netease.label}」',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        _buildActions(StorageDirectoryKind.download, _downloadDir),
        const SizedBox(height: 6),
        _buildEffectNotice(StorageDirectoryKind.download),
      ],
    );
  }

  Widget _buildActions(StorageDirectoryKind kind, String? path) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: <Widget>[
        OutlinedButton.icon(
          onPressed: _busy ? null : () => unawaited(_change(kind)),
          icon: const Icon(Icons.drive_file_move_outline, size: 15),
          label: Text('更改${kind.label}…'),
        ),
        OutlinedButton.icon(
          onPressed: () => unawaited(_open(path, kind.label)),
          icon: const Icon(Icons.folder_open_rounded, size: 15),
          label: const Text('打开'),
        ),
        OutlinedButton.icon(
          onPressed: () => unawaited(_copy(path, kind.label)),
          icon: const Icon(Icons.copy_all_rounded, size: 15),
          label: const Text('复制路径'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => unawaited(_reset(kind)),
          icon: const Icon(Icons.settings_backup_restore_rounded, size: 15),
          label: const Text('恢复默认'),
        ),
      ],
    );
  }

  /// 「改这个目录的代价」——文案来自 `StoragePaths`，与提示语共用同一句。
  Widget _buildEffectNotice(StorageDirectoryKind kind) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      StoragePaths.changeEffectNotice(kind),
      style: TextStyle(
        fontSize: 10.5,
        height: 1.45,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// 完整路径的展示块：标签 + 可换行可复制的值 + 一句说明。
class _PathValue extends StatelessWidget {
  const _PathValue({
    required this.label,
    required this.value,
    required this.placeholder,
    required this.hint,
  });

  final String label;
  final String? value;
  final String placeholder;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(
          (value == null || value!.trim().isEmpty) ? placeholder : value!,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.45,
            fontFamily: 'Consolas',
            fontFamilyFallback: const <String>['Courier New', 'monospace'],
            color: scheme.onSurface.withValues(alpha: 0.9),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 提示框的语义：警告（能继续用，但要知道代价）与错误（当前不生效）。
enum _NoticeTone { warning, error }

/// 分区里的短提示。**不用 Markdown**：这里的文字会原样显示，
/// `**加粗**` 只会变成两个星号。
class _NoticeBox extends StatelessWidget {
  const _NoticeBox({required this.tone, required this.text});

  final _NoticeTone tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZhyTokens tokens = context.tokens;
    final Color accent = tone == _NoticeTone.error
        ? scheme.error
        : scheme.tertiary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(tokens.cardRadius),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            tone == _NoticeTone.error
                ? Icons.error_outline_rounded
                : Icons.info_outline_rounded,
            size: 15,
            color: accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: scheme.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 开关 `rawPreferences` 管住的能力：把本机 `feature.*` 存档原样列出来。
///
/// 存在的理由：开关写了盘、但界面没反应时，第一件要确认的事就是
/// "这个键到底存下去了没有"。这里读的是**真实的 SharedPreferences**，
/// 所以看到什么就是什么，不会和实际存档不一致。
class _RawPreferencesPanel extends ConsumerWidget {
  const _RawPreferencesPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyFeatureFlags flags = ref.watch(featureFlagsProvider);
    // 读取点（开关 rawPreferences）：关掉就整个面板不渲染 ——
    // 这不是"少画一个按钮"，而是关掉之后没有任何地方能看到原始键值。
    if (!flags.rawPreferences) return const SizedBox.shrink();

    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SharedPreferences prefs = ref.watch(sharedPreferencesProvider);
    // 只列 feature.*：别的键（主题、音质、登录凭据）不属于这个开关的范围，
    // 顺手摊开它们既没有用，也会把凭据之类的东西露在不该露的地方。
    final List<String> keys = prefs
        .getKeys()
        .where((String key) => key.startsWith('feature.'))
        .toList()
      ..sort();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(tokens.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '本机 feature.* 存档：${keys.length} 个键',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: keys.isEmpty
                    ? null
                    : () => unawaited(_copy(context, prefs, keys)),
                icon: const Icon(Icons.copy_all_rounded, size: 15),
                label: const Text('复制'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (keys.isEmpty)
            Text(
              '存档里还没有任何 feature.* 键：上面所有开关都还是默认值。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            )
          else
            for (final String key in keys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        key,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface,
                          // 等宽数字：键值要竖着对齐才好一眼扫完。
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${prefs.get(key)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _copy(
    BuildContext context,
    SharedPreferences prefs,
    List<String> keys,
  ) async {
    final String text = keys
        .map((String key) => '$key = ${prefs.get(key)}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('已复制 feature.* 存档')));
  }
}

/// 开关 `equalizerEntry` 管住的能力：设置页里的均衡器入口。
class _EqualizerEntryRow extends ConsumerWidget {
  const _EqualizerEntryRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZhyFeatureFlags flags = ref.watch(featureFlagsProvider);
    // 读取点（开关 equalizerEntry）：关掉就不渲染这个入口。
    if (!flags.equalizerEntry) return const SizedBox.shrink();

    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '均衡器：10 段推子 + 预设。当前播放后端不会把曲线送给声卡，'
            '所以它只影响面板里的显示（面板内也如此标注）。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: () => unawaited(showEqualizerDialog(context)),
          icon: const Icon(Icons.graphic_eq_rounded, size: 15),
          label: const Text('打开均衡器'),
        ),
      ],
    );
  }
}
