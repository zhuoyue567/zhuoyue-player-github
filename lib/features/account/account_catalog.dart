import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/collection.dart';
import '../../data/models/media_source.dart';
import 'account_providers.dart';

/// 「账户」页描述一个音源所需的全部信息。
///
/// 页面**完全由清单驱动**（遍历 [kAccountSources] 渲染），而不是把
/// 网易云 / 哔哩两个音源硬编码进布局。理由是具体的：这个客户端的音源是
/// 会长出来的（QQ 音乐、酷狗音乐……），如果每接一个音源都要去改一遍页面
/// 布局，那必然会漏 —— 漏掉的结果就是"某个音源能登录，但在账户页上
/// 根本不存在"，而用户只能在别处撞见它。
///
/// **接入一个新音源：界面这边只需要在 [kAccountSources] 里加一条。**
/// （数据层当然还要有对应的 `MediaSource`、repository 与账号 provider，
/// 那是另一条链路的事。）
@immutable
class AccountSourceSpec {
  const AccountSourceSpec({
    required this.id,
    required this.label,
    required this.icon,
    this.source,
    this.accountProvider,
    this.note,
    this.signInLabel = '登录',
  });

  /// 已经接入了音源的条目。
  ///
  /// 展示名直接取 [MediaSource.label]，不在这里再写一遍字符串：
  /// 否则迟早会出现"枚举里叫网易云音乐、清单里叫网易云"的两份文案。
  factory AccountSourceSpec.supported({
    required MediaSource source,
    required NotifierProvider<AccountNotifier, AccountProfile?> accountProvider,
    required IconData icon,
    String? note,
    String signInLabel = '登录',
  }) {
    return AccountSourceSpec(
      id: source.key,
      label: source.label,
      icon: icon,
      source: source,
      accountProvider: accountProvider,
      note: note,
      signInLabel: signInLabel,
    );
  }

  /// 规划中的音源：数据层还没有它，所以只能给出展示用的 id 与名称。
  factory AccountSourceSpec.planned({
    required String id,
    required String label,
    required IconData icon,
    String? note,
    String signInLabel = '登录',
  }) {
    return AccountSourceSpec(
      id: id,
      label: label,
      icon: icon,
      note: note,
      signInLabel: signInLabel,
    );
  }

  /// 稳定标识（不依赖展示文案）：做 key、做测试定位都用它，改名不会破坏引用。
  final String id;

  /// 界面上展示的音源名。
  final String label;

  final IconData icon;

  /// 已实现音源对应的枚举值；规划中的音源为 null ——
  /// 它在 `MediaSource` 里还根本不存在，这正是"规划中"的准确含义
  /// （`MediaSource` 位于 `lib/data/**`，是共享枚举，不能为了一个页面去动它）。
  final MediaSource? source;

  /// 该音源的账号状态源。页面靠它 watch 登录状态、refresh、logout。
  final NotifierProvider<AccountNotifier, AccountProfile?>? accountProvider;

  /// 一句话说明（"登录后能做什么"或"为什么现在还不能用"）。
  final String? note;

  /// 「还没登录 / 还没实现」时那个按钮上的字。
  ///
  /// 默认「登录」，但**不是每个音源都靠登录接入**：NAS 走的是
  /// "填一个共享路径（UNC 或映射盘）"，它没有账号可登，写成「登录」
  /// 就是一句不准确的话 —— 所以这个字必须能按音源覆盖。
  final String signInLabel;

  /// 这个音源现在能不能真的登录。
  ///
  /// 判据是"有枚举值**且**有账号 provider"，而不是再单独存一个布尔字段：
  /// 少写一个字段、或者哪天只加了枚举忘了接账号，页面都会如实地把它渲染成
  /// 「规划中」，而不是画出一个点不动的登录按钮让用户以为是自己点错了。
  bool get implemented => source != null && accountProvider != null;
}

/// 「账户」页的音源清单：加一个音源 = 在这里加一条。
///
/// 规划中的音源也留在这里，而不是等做好了再出现。它们在页面上的存在本身
/// 就是信息：用户能看到这个客户端打算支持哪些平台，也能看到为什么现在用不了
/// （[AccountSourceSpec.note]）。**不要**给规划中的音源写"即将上线"这类
/// 无法验证的话 —— 页面只陈述代码里的事实。
final List<AccountSourceSpec> kAccountSources = <AccountSourceSpec>[
  AccountSourceSpec.supported(
    source: MediaSource.netease,
    accountProvider: neteaseAccountProvider,
    icon: Icons.music_note_rounded,
    note: '登录后可同步歌单、每日推荐与会员音质档位。',
  ),
  AccountSourceSpec.supported(
    source: MediaSource.bilibili,
    accountProvider: bilibiliAccountProvider,
    icon: Icons.video_library_rounded,
    note: '不登录也能浏览公开收藏夹；登录后才能读取你自己的收藏夹。',
  ),
  AccountSourceSpec.planned(
    id: 'qqmusic',
    label: 'QQ 音乐',
    icon: Icons.library_music_rounded,
    note: '本仓库还没有 QQ 音乐的曲库与登录实现，所以这里没有可用的登录入口。',
  ),
  AccountSourceSpec.planned(
    id: 'kugou',
    label: '酷狗音乐',
    icon: Icons.graphic_eq_rounded,
    note: '本仓库还没有酷狗音乐的曲库与登录实现，所以这里没有可用的登录入口。',
  ),
  // NAS 与上面两个**不是同一类**音源：它们是要登录的在线平台，而 NAS 是
  // 你自己网络里的存储。所以它排在最后，并且按钮写「连接」而不是「登录」
  // （它没有账号可登）。
  //
  // 记一笔将来要怎么做（这是给实现者的备注，**不是**给用户的承诺，所以不会
  // 出现在界面上）：走 UNC / 映射盘路径（`\\NAS\Music` 或 `Z:\Music`），
  // 靠 Windows 自身的凭据认证，应用里不存密码；扫目录列出音频文件，
  // 元数据先用文件名与目录结构，封面读同目录的 `folder.jpg` / `cover.jpg`。
  //
  // 界面这一侧不用再改：将来数据层就位后，把这一条换成
  // `AccountSourceSpec.supported(...)` 并接上账号 provider 即可 ——
  // `implemented` 是由字段推导的，页面会自动把它渲染成可用状态。
  AccountSourceSpec.planned(
    id: 'nas',
    label: 'NAS',
    icon: Icons.dns_rounded,
    signInLabel: '连接',
    note:
        '本仓库还没有扫描目录的曲库实现（sourceRegistryProvider 里只注册了'
        '网易云与哔哩哔哩，「本地」也没有对应的 repository），'
        '所以现在无法列出或播放 NAS 上的文件。',
  ),
];
