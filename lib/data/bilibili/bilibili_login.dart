import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/collection.dart';
import '../models/media_source.dart';
import '../repositories/music_repository.dart';
import 'bilibili_api_client.dart';
import 'bilibili_parsers.dart';

/// 扫码登录会话。
@immutable
class BilibiliQrSession {
  const BilibiliQrSession({required this.url, required this.qrcodeKey});

  /// 二维码内容。**只是一个 URL 字符串** —— 本项目不引入二维码渲染依赖，
  /// 由界面自行把它画成二维码。
  ///
  /// 实测取值形如：
  /// `https://account.bilibili.com/h5/account-h5/auth/scan-web?navhide=1&callback=close&qrcode_key=...&from=`
  final String url;

  /// 轮询用的凭据。
  final String qrcodeKey;

  bool get isValid => url.isNotEmpty && qrcodeKey.isNotEmpty;
}

/// 扫码状态。
///
/// 取值与哔哩返回的数字码一一对应（实测确认了 86101 与 86038 两个分支）。
enum BilibiliQrStatus {
  /// 尚未扫码。
  waiting,

  /// 已扫码，等待用户在手机上确认。
  scanned,

  /// 已确认，登录成功。
  authorized,

  /// 二维码已过期，需要重新生成。
  expired,

  /// 无法识别的状态码。
  unknown,
}

/// 一次轮询的完整结果。
///
/// 需求里写的是"枚举带出 cookie"，但 Dart 的枚举不能携带实例数据，
/// 所以状态仍然放在 [status]，登录成功时解析到的 cookie 放在 [cookies]。
@immutable
class BilibiliQrPollResult {
  const BilibiliQrPollResult({
    required this.status,
    this.cookies = const <String, String>{},
    this.message,
  });

  final BilibiliQrStatus status;

  /// 登录成功时服务端下发的凭据（`SESSDATA` / `bili_jct` / `DedeUserID` …）。
  final Map<String, String> cookies;

  /// 服务端返回的状态描述，例如「未扫码」「二维码已失效」。
  final String? message;

  bool get isAuthorized => status == BilibiliQrStatus.authorized;
}

/// 哔哩哔哩登录与账号信息服务。
///
/// 只做三件事：扫码登录、查账号、退出/恢复。cookie 的存储与携带全部交给
/// [BilibiliApiClient] —— 登录态与请求头必须是**同一份**数据，
/// 各存一份迟早会出现"界面显示已登录但请求没带 cookie"的鬼故事。
class BilibiliLoginService {
  BilibiliLoginService({required this._client, required this._preferences});

  final BilibiliApiClient _client;
  final SharedPreferences _preferences;

  /// 账号信息的持久化键（值是一段 JSON）。
  ///
  /// 存它是为了让界面在冷启动、`nav` 还没回来的那一瞬间就能显示昵称与头像，
  /// 而不是先闪一下"未登录"再跳成账号卡片。
  static const String profilePreferenceKey = 'bilibili.profile';

  /// 最近一次轮询成功时解析到的 cookie。供只关心枚举的调用方兜底使用。
  Map<String, String> _lastPolledCookies = const <String, String>{};
  Map<String, String> get lastPolledCookies => _lastPolledCookies;

  // -------------------------------------------------------------------------
  // 扫码登录
  // -------------------------------------------------------------------------

  /// 申请一个二维码。
  ///
  /// 实测 `GET https://passport.bilibili.com/x/passport-login/web/qrcode/generate`
  /// 返回 `{"code":0,"message":"OK","data":{"url":"https://account.bilibili.com/...","qrcode_key":"..."}}`。
  Future<BilibiliQrSession> createQrSession() async {
    final Map<String, Object?> body = await _client.getJson(
      '$kBilibiliPassportHost/x/passport-login/web/qrcode/generate',
    );
    final Map<String, Object?> data = asMap(body['data']);
    final BilibiliQrSession session = BilibiliQrSession(
      url: asString(data['url']) ?? '',
      qrcodeKey: asString(data['qrcode_key']) ?? '',
    );
    if (!session.isValid) {
      throw MusicApiException(
        '未能获取哔哩哔哩登录二维码，请稍后重试',
        source: MediaSource.bilibili,
      );
    }
    return session;
  }

  /// 只用状态码的轮询（接口约定里的签名）。
  ///
  /// 登录成功时 cookie 已经写入 [BilibiliApiClient] 并落盘，
  /// 需要一次性拿到 cookie 的调用方请用 [pollQr]。
  Future<BilibiliQrStatus> pollQrStatus(String qrcodeKey) async {
    final BilibiliQrPollResult result = await pollQr(qrcodeKey);
    return result.status;
  }

  /// 轮询扫码状态，并在登录成功时**接住凭据**。
  ///
  /// 状态码在 `data.code` 里，外层 `code` 恒为 0 —— 这一点很容易写错，
  /// 实测响应：
  /// ```json
  /// {"code":0,"message":"OK","data":{"url":"","code":86101,"message":"未扫码"}}
  /// ```
  /// 映射关系：`0` 已确认 / `86038` 已失效 / `86090` 已扫码待确认 /
  /// `86101` 未扫码。
  ///
  /// 登录成功后的凭据**以 `data.url` 的 query 参数为准**：
  /// 那个 URL 形如
  /// `https://passport.biligame.com/crossDomain?DedeUserID=...&SESSDATA=...&bili_jct=...`。
  /// 走 `Set-Cookie` 头也可以拿到，但经过 dio 之后并不可靠：
  /// 多个 cookie 可能被拼成一行、也可能被重定向丢掉。既然服务端在 body 里
  /// 明确给了一份，就以它为准，`Set-Cookie` 只作为补充（客户端已经自动合并过一次）。
  Future<BilibiliQrPollResult> pollQr(String qrcodeKey) async {
    final Map<String, Object?> body = await _client.getJson(
      '$kBilibiliPassportHost/x/passport-login/web/qrcode/poll',
      query: <String, dynamic>{'qrcode_key': qrcodeKey},
    );
    final Map<String, Object?> data = asMap(body['data']);
    final int? innerCode = asInt(data['code']);
    final String? message = asString(data['message']);

    switch (innerCode) {
      case 0:
        final Map<String, String> cookies = parseCrossDomainCookies(
          asString(data['url']),
        );
        if (cookies.isNotEmpty) {
          _client.mergeCookies(cookies);
          await _client.persistCookies();
        }
        _lastPolledCookies = cookies;
        return BilibiliQrPollResult(
          status: BilibiliQrStatus.authorized,
          cookies: cookies,
          message: message,
        );
      case 86038:
        return BilibiliQrPollResult(
          status: BilibiliQrStatus.expired,
          message: message ?? '二维码已失效',
        );
      case 86090:
        return BilibiliQrPollResult(
          status: BilibiliQrStatus.scanned,
          message: message ?? '已扫码，请在手机上确认',
        );
      case 86101:
        return BilibiliQrPollResult(
          status: BilibiliQrStatus.waiting,
          message: message ?? '未扫码',
        );
      default:
        return BilibiliQrPollResult(
          status: BilibiliQrStatus.unknown,
          message: message ?? '未知的扫码状态（code=$innerCode）',
        );
    }
  }

  /// 从 crossDomain 回调地址里挑出真正的凭据。
  ///
  /// 那个 URL 里混着 `gourl` / `timestamp` / `Expires` 之类**不是 cookie**
  /// 的参数，直接全盘收下会往 `Cookie` 头里塞脏东西，所以按白名单取。
  @visibleForTesting
  static Map<String, String> parseCrossDomainCookies(String? url) {
    if (url == null || url.isEmpty) return const <String, String>{};
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      return const <String, String>{};
    }
    final Map<String, String> cookies = <String, String>{};
    uri.queryParameters.forEach((String key, String value) {
      if (!kBilibiliCredentialNames.contains(key)) return;
      final String? text = asString(value);
      if (text != null) cookies[key] = text;
    });
    return cookies;
  }

  // -------------------------------------------------------------------------
  // 账号信息
  // -------------------------------------------------------------------------

  /// 拉取当前账号信息；服务端明确说"未登录"时返回 null。
  ///
  /// 实测未登录时 `nav` 返回的是 **`code: -101`** 且 `data.isLogin == false`，
  /// 所以这里必须容忍 -101（客户端已自动合并 `Set-Cookie`，无需额外处理）：
  /// - 返回 null 且**清掉本地登录态**：服务端说没登录，就说明 `SESSDATA`
  ///   真的失效了，留着它只会让后续请求一直拿到 -101。
  /// - 网络异常（抛 [MusicApiException]）**不清登录态**：断网不等于被登出，
  ///   否则用户一断网就被"退出登录"，这是最招人烦的 bug 之一。
  Future<AccountProfile?> fetchAccount() async {
    final Map<String, Object?> body = await _client.getJson(
      '/x/web-interface/nav',
      tolerateAuthError: true,
    );
    final Map<String, Object?> data = asMap(body['data']);

    if (asBool(data['isLogin']) != true) {
      await clearSession();
      return null;
    }

    final int? mid = asInt(data['mid']);
    final String? nickname = asString(data['uname']);
    if (mid == null || nickname == null) {
      // isLogin 为真却拿不到 mid/uname：服务端字段变了，不能硬编一个假账号。
      throw MusicApiException(
        '哔哩哔哩账号信息不完整（缺少 mid 或 uname），请稍后重试',
        source: MediaSource.bilibili,
      );
    }

    // vipStatus 的写法在不同版本的接口里有 vipStatus / vip_status 两种，
    // 而 vip_label 只在真是会员时才有意义。
    final int? vipStatus =
        asInt(data['vipStatus']) ?? asInt(data['vip_status']);
    final AccountProfile profile = AccountProfile(
      source: MediaSource.bilibili,
      userId: '$mid',
      nickname: nickname,
      avatarUrl: normalizeCoverUrl(data['face']),
      signature: asString(data['sign']),
      vipLabel: vipStatus == 1 ? asString(data['vip_label']) : null,
      follows: asInt(data['following']),
      followers: asInt(data['follower']),
    );

    await _preferences.setString(
      profilePreferenceKey,
      jsonEncode(<String, Object?>{
        'userId': profile.userId,
        'nickname': profile.nickname,
        'avatarUrl': profile.avatarUrl,
        'signature': profile.signature,
        'vipLabel': profile.vipLabel,
        'follows': profile.follows,
        'followers': profile.followers,
      }),
    );
    return profile;
  }

  /// 读出上次成功缓存的账号信息（不校验有效性，纯为了启动时先渲染）。
  AccountProfile? cachedAccount() {
    final String? raw = _preferences.getString(profilePreferenceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Map<String, Object?> data = asMap(jsonDecode(raw));
      final String? userId = asString(data['userId']);
      final String? nickname = asString(data['nickname']);
      if (userId == null || nickname == null) return null;
      return AccountProfile(
        source: MediaSource.bilibili,
        userId: userId,
        nickname: nickname,
        avatarUrl: asString(data['avatarUrl']),
        signature: asString(data['signature']),
        vipLabel: asString(data['vipLabel']),
        follows: asInt(data['follows']),
        followers: asInt(data['followers']),
      );
    } on FormatException {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 退出 / 恢复
  // -------------------------------------------------------------------------

  /// 退出登录。
  ///
  /// 这里**只清理本地凭据**，刻意不去调服务端的 `login/exit/v2`：
  /// 那个接口需要 `bili_jct` 做 CSRF，而且一旦调用成功，用户在**浏览器上**
  /// 的登录态也会一起失效 —— 桌面播放器没有权力顺手把别人的网页登录踹掉。
  Future<void> logout() async {
    _lastPolledCookies = const <String, String>{};
    await _client.clearSession();
    await _preferences.remove(profilePreferenceKey);
  }

  /// 冷启动时恢复登录态。
  ///
  /// 只有本地确实存过 `SESSDATA` 才会去问服务端；校验失败（含 -101）
  /// 返回 false，网络异常也返回 false 但**不**清 cookie。
  Future<bool> restore() async {
    _client.loadPersistedSession();
    if (!_client.hasSession) return false;
    try {
      return await fetchAccount() != null;
    } on MusicApiException catch (error) {
      if (error.isAuthError) {
        await clearSession();
        return false;
      }
      // 网络问题：保留 cookie，下次再试。
      debugPrint('[bilibili] 恢复登录态失败：$error');
      return false;
    }
  }

  /// 登录态失效时统一清理。
  Future<void> clearSession() async {
    _lastPolledCookies = const <String, String>{};
    await _client.clearSession();
    await _preferences.remove(profilePreferenceKey);
  }
}

/// 真正要落进 `Cookie` 头的凭据名白名单。
///
/// `sid` 不是每个账号都有，但有了就必须带上（部分风控策略会看它）。
const Set<String> kBilibiliCredentialNames = <String>{
  'SESSDATA',
  'bili_jct',
  'DedeUserID',
  'DedeUserID__ckMd5',
  'sid',
};
