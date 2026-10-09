import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_tokens.dart';
import '../../core/ui/cover_image.dart';
import '../../core/ui/qr_code_view.dart';
import '../../data/bilibili/bilibili_login.dart';
import '../../data/bilibili/bilibili_repository.dart';
import '../../data/models/collection.dart';
import '../../data/netease/netease_login.dart';
import 'account_providers.dart';

/// 打开账号登录弹窗。
Future<void> showLoginDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => const LoginDialog(),
  );
}

enum _LoginTab {
  netease('网易云音乐'),
  bilibili('哔哩哔哩');

  const _LoginTab(this.label);

  final String label;
}

/// 账号登录弹窗：扫码为主，网易云额外提供手机号密码登录。
class LoginDialog extends ConsumerStatefulWidget {
  const LoginDialog({super.key});

  @override
  ConsumerState<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends ConsumerState<LoginDialog> {
  _LoginTab _tab = _LoginTab.netease;

  // ---- 网易云扫码 ----
  NeteaseQrSession? _neteaseSession;
  String _neteaseHint = '正在获取二维码…';
  bool _neteaseBusy = false;

  // ---- 哔哩扫码 ----
  BilibiliQrSession? _bilibiliSession;
  String _bilibiliHint = '正在获取二维码…';
  bool _bilibiliBusy = false;

  // ---- 网易云手机号登录 ----
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _phoneBusy = false;
  String? _phoneError;

  Timer? _pollTimer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshQr(_LoginTab.netease));
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 二维码

  Future<void> _refreshQr(_LoginTab tab) async {
    _pollTimer?.cancel();
    if (tab == _LoginTab.netease) {
      setState(() {
        _neteaseBusy = true;
        _neteaseHint = '正在获取二维码…';
        _neteaseSession = null;
      });
    } else {
      setState(() {
        _bilibiliBusy = true;
        _bilibiliHint = '正在获取二维码…';
        _bilibiliSession = null;
      });
    }

    try {
      if (tab == _LoginTab.netease) {
        final NeteaseQrSession session = await ref
            .read(neteaseLoginServiceProvider)
            .createQrSession();
        if (_disposed) return;
        setState(() {
          _neteaseSession = session;
          _neteaseBusy = false;
          _neteaseHint = '请用网易云音乐 App 扫描二维码';
        });
      } else {
        final BilibiliQrSession session = await ref
            .read(bilibiliLoginServiceProvider)
            .createQrSession();
        if (_disposed) return;
        setState(() {
          _bilibiliSession = session;
          _bilibiliBusy = false;
          _bilibiliHint = '请用哔哩哔哩 App 扫描二维码';
        });
      }
      _startPolling(tab);
    } on Object catch (error) {
      if (_disposed) return;
      final String message = _describe(error);
      setState(() {
        if (tab == _LoginTab.netease) {
          _neteaseBusy = false;
          _neteaseHint = message;
        } else {
          _bilibiliBusy = false;
          _bilibiliHint = message;
        }
      });
    }
  }

  /// 2 秒轮一次。
  ///
  /// 这个间隔是权衡的结果：服务端会缓存轮询结果，太密不但没有更快，
  /// 反而容易触发风控；太慢则用户确认后要盯着界面等。
  void _startPolling(_LoginTab tab) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (Timer timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      unawaited(_pollOnce(tab, timer));
    });
  }

  Future<void> _pollOnce(_LoginTab tab, Timer timer) async {
    try {
      if (tab == _LoginTab.netease) {
        final NeteaseQrSession? session = _neteaseSession;
        if (session == null) return;
        final NeteaseQrPollResult result = await ref
            .read(neteaseLoginServiceProvider)
            .pollQrStatus(session.key);
        if (_disposed) return;
        switch (result.status) {
          case NeteaseQrStatus.waiting:
            setState(() => _neteaseHint = '等待扫码…');
          case NeteaseQrStatus.scanned:
            setState(() => _neteaseHint = '已扫码，请在手机上确认');
          case NeteaseQrStatus.expired:
            timer.cancel();
            setState(() => _neteaseHint = '二维码已过期，请点击刷新');
          case NeteaseQrStatus.unknown:
            break;
          case NeteaseQrStatus.authorized:
            timer.cancel();
            await _finishLogin(_LoginTab.netease);
        }
      } else {
        final BilibiliQrSession? session = _bilibiliSession;
        if (session == null) return;
        final BilibiliQrPollResult result = await ref
            .read(bilibiliLoginServiceProvider)
            .pollQr(session.qrcodeKey);
        if (_disposed) return;
        switch (result.status) {
          case BilibiliQrStatus.waiting:
            setState(() => _bilibiliHint = '等待扫码…');
          case BilibiliQrStatus.scanned:
            setState(() => _bilibiliHint = '已扫码，请在手机上确认');
          case BilibiliQrStatus.expired:
            timer.cancel();
            setState(() => _bilibiliHint = '二维码已过期，请点击刷新');
          case BilibiliQrStatus.unknown:
            break;
          case BilibiliQrStatus.authorized:
            timer.cancel();
            await _finishLogin(_LoginTab.bilibili);
        }
      }
    } on Object catch (error) {
      // 单次轮询失败不该中断整个流程（网络抖一下很常见），
      // 但要把原因显示出来，否则界面会像卡住一样。
      if (_disposed) return;
      setState(() {
        if (tab == _LoginTab.netease) {
          _neteaseHint = _describe(error);
        } else {
          _bilibiliHint = _describe(error);
        }
      });
    }
  }

  /// 手机号 + 密码登录。
  Future<void> _loginWithPassword() async {
    final String phone = _phoneController.text.trim();
    final String password = _passwordController.text;
    if (phone.isEmpty || password.isEmpty) {
      setState(() => _phoneError = '请填写手机号与密码');
      return;
    }
    setState(() {
      _phoneBusy = true;
      _phoneError = null;
    });
    try {
      await ref
          .read(neteaseLoginServiceProvider)
          .loginWithPassword(phone: phone, password: password);
      if (_disposed) return;
      await _finishLogin(_LoginTab.netease);
    } on Object catch (error) {
      if (_disposed) return;
      setState(() {
        _phoneBusy = false;
        _phoneError = _describe(error);
      });
    }
  }

  Future<void> _finishLogin(_LoginTab tab) async {
    _pollTimer?.cancel();
    // cookie 已经写进共享的 api client 了，这里只要把账号信息重新拉一次，
    // 界面（侧边栏卡片、歌单页）就会跟着刷新。
    if (tab == _LoginTab.netease) {
      await ref.read(neteaseAccountProvider.notifier).refresh();
    } else {
      await ref.read(bilibiliAccountProvider.notifier).refresh();
    }
    if (_disposed || !mounted) return;
    Navigator.of(context).maybePop();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${tab.label} 登录成功')));
  }

  Future<void> _logout(_LoginTab tab) async {
    if (tab == _LoginTab.netease) {
      await ref.read(neteaseAccountProvider.notifier).logout();
    } else {
      await ref.read(bilibiliAccountProvider.notifier).logout();
    }
    if (_disposed || !mounted) return;
    await _refreshQr(tab);
  }

  String _describe(Object error) {
    final String text = error.toString();
    // MusicApiException.toString() 已经带了可读信息，这里只做裁剪。
    final int index = text.indexOf(': ');
    return index >= 0 && index + 2 < text.length
        ? text.substring(index + 2)
        : text;
  }

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AccountProfile? netease = ref.watch(neteaseAccountProvider);
    final AccountProfile? bilibili = ref.watch(bilibiliAccountProvider);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.account_circle_rounded,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '账号登录',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  for (final _LoginTab tab in _LoginTab.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(tab.label),
                        selected: _tab == tab,
                        onSelected: (_) {
                          setState(() => _tab = tab);
                          final bool loggedIn = tab == _LoginTab.netease
                              ? netease != null
                              : bilibili != null;
                          if (!loggedIn &&
                              (tab == _LoginTab.netease
                                  ? _neteaseSession == null
                                  : _bilibiliSession == null)) {
                            unawaited(_refreshQr(tab));
                          }
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (_tab == _LoginTab.netease)
                _buildNetease(scheme, tokens, netease)
              else
                _buildBilibili(scheme, tokens, bilibili),
              const SizedBox(height: 14),
              Text(
                '登录凭据（cookie）只保存在本机，用于直接访问你自己的账号数据。\n'
                '本项目为第三方客户端，与官方无关。',
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetease(
    ColorScheme scheme,
    ZhyTokens tokens,
    AccountProfile? profile,
  ) {
    if (profile != null) {
      return _LoggedInCard(
        profile: profile,
        onLogout: () => unawaited(_logout(_LoginTab.netease)),
      );
    }

    final NeteaseQrSession? session = _neteaseSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Center(
          child: SizedBox(
            width: 196,
            height: 196,
            child: _neteaseBusy || session == null
                ? const Center(child: CircularProgressIndicator())
                : session.hasImage
                ? Image.memory(session.imageBytes!, fit: BoxFit.contain)
                : _QrFallback(text: session.url),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            _neteaseHint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton.icon(
            onPressed: _neteaseBusy
                ? null
                : () => unawaited(_refreshQr(_LoginTab.netease)),
            icon: const Icon(Icons.refresh_rounded, size: 15),
            label: const Text('刷新二维码'),
          ),
        ),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 6),
        Text(
          '或使用手机号密码登录',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(hintText: '手机号'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _passwordController,
                obscureText: true,
                onSubmitted: (_) => unawaited(_loginWithPassword()),
                decoration: const InputDecoration(hintText: '密码'),
              ),
            ),
          ],
        ),
        if (_phoneError != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _phoneError!,
            style: TextStyle(fontSize: 11.5, color: scheme.error),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _phoneBusy
                ? null
                : () => unawaited(_loginWithPassword()),
            child: _phoneBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('登录'),
          ),
        ),
      ],
    );
  }

  Widget _buildBilibili(
    ColorScheme scheme,
    ZhyTokens tokens,
    AccountProfile? profile,
  ) {
    if (profile != null) {
      return _LoggedInCard(
        profile: profile,
        onLogout: () => unawaited(_logout(_LoginTab.bilibili)),
      );
    }

    final BilibiliQrSession? session = _bilibiliSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Center(
          child: _bilibiliBusy || session == null
              ? const SizedBox(
                  width: 196,
                  height: 196,
                  child: Center(child: CircularProgressIndicator()),
                )
              : QrCodeView(data: session.url, size: 196),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            _bilibiliHint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton.icon(
            onPressed: _bilibiliBusy
                ? null
                : () => unawaited(_refreshQr(_LoginTab.bilibili)),
            icon: const Icon(Icons.refresh_rounded, size: 15),
            label: const Text('刷新二维码'),
          ),
        ),
        Text(
          '提示：不登录也可以浏览公开收藏夹；登录后才能读取你自己的收藏夹。',
          style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 已登录时的账号卡片。
class _LoggedInCard extends StatelessWidget {
  const _LoggedInCard({required this.profile, required this.onLogout});

  final AccountProfile profile;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final ZhyTokens tokens = context.tokens;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        ClipOval(
          child: SizedBox(
            width: 56,
            height: 56,
            child: profile.avatarUrl == null
                ? ColoredBox(
                    color: scheme.primaryContainer,
                    child: Icon(
                      Icons.person_rounded,
                      color: scheme.onPrimaryContainer,
                    ),
                  )
                : CoverImage(url: profile.avatarUrl, size: 56),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      profile.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  if (profile.vipLabel != null) ...<Widget>[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(tokens.pillRadius),
                      ),
                      child: Text(
                        profile.vipLabel!,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '${profile.source.label} · 已登录',
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton(onPressed: onLogout, child: const Text('退出登录')),
      ],
    );
  }
}

/// 网易云二维码图片拿不到时的兜底：把内容直接给用户。
class _QrFallback extends StatelessWidget {
  const _QrFallback({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.qr_code_2_rounded,
            size: 30,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            '二维码图片获取失败，可在浏览器打开以下链接完成登录：',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: scheme.primary),
          ),
        ],
      ),
    );
  }
}
