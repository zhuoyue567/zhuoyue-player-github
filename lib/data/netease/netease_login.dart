import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/storage/preferences.dart';
import '../models/collection.dart';
import '../models/media_source.dart';
import '../repositories/music_repository.dart';
import 'netease_api_client.dart';
import 'netease_parsers.dart';

/// 二维码登录的状态机。
enum NeteaseQrStatus {
  /// 等待扫码（接口 code 801）。
  waiting,

  /// 已扫码，等待手机端确认（802）。
  scanned,

  /// 已确认，登录完成（803）。
  authorized,

  /// 二维码已过期（800），需要重新生成。
  expired,

  /// 接口回了我们不认识的码（或响应异常）。UI 应当继续轮询几次再放弃。
  unknown,
}

/// 一次二维码会话。
@immutable
class NeteaseQrSession {
  const NeteaseQrSession({
    required this.key,
    required this.url,
    this.imageDataUrl,
    this.imageBytes,
  });

  /// 轮询用的 key。
  final String key;

  /// 二维码内容（`https://music.163.com/login?codekey=...`）。
  /// 没有图片时可以直接把它当文本展示，让用户手动打开链接。
  final String url;

  /// 接口原样返回的 `data:image/png;base64,...`。
  final String? imageDataUrl;

  /// 已经从 data URL 里解出来的 PNG 字节。
  ///
  /// 之所以在 Dart 侧就解好：UI 不该知道"data URL"这种格式，
  /// 它只需要 `Image.memory(session.imageBytes)`；解不出来时为 null，
  /// UI 就退化成展示 [url] 文本。
  final Uint8List? imageBytes;

  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;
}

/// 一次轮询的结果。
///
/// 这里没有直接用枚举当返回值，是因为"已授权"同时还必须把 cookie 带出来 ——
/// 只返回枚举的话，调用方还得再发一次请求去取凭据，而 803 的响应体里
/// 其实已经给了，白跑一趟还容易出竞态。
@immutable
class NeteaseQrPollResult {
  const NeteaseQrPollResult({required this.status, this.cookie, this.message});

  final NeteaseQrStatus status;

  /// 仅在 [NeteaseQrStatus.authorized] 时可能非空。
  final String? cookie;

  /// 接口给的中文提示（"等待扫码"/"授权成功"…），可以直接展示。
  final String? message;
}

/// 网易云登录：二维码 / 手机号密码 / 手机号验证码，外加 cookie 持久化。
///
/// cookie 是**唯一的登录凭据**，全部由 Dart 端保存并随请求发送
/// （原因见 [NeteaseApiClient] 的类注释）。这里把读写 SharedPreferences
/// 也一并收拢，避免 repository 和 UI 各自去拼 key。
class NeteaseLoginService {
  NeteaseLoginService({
    required NeteaseApiClient apiClient,
    required SharedPreferences preferences,
  }) : _client = apiClient,
       _prefs = preferences;

  /// cookie 的存储键。
  static const String cookieKey = 'netease.cookie';

  /// 账号信息的存储键（JSON 字符串）。
  static const String profileKey = 'netease.profile';

  /// 国家码。国内手机号固定 86，接口默认值也是它，显式传是为了以后好改。
  static const String defaultCountryCode = '86';

  final NeteaseApiClient _client;
  final SharedPreferences _prefs;

  /// 最近一次成功拿到的账号信息，供 UI 立刻渲染账号卡片。
  AccountProfile? cachedProfile;

  // ------------------------------------------------------------------ 二维码

  /// 创建二维码会话：先取 key，再让服务端把 key 渲染成二维码图片。
  Future<NeteaseQrSession> createQrSession() async {
    // 必须绕过服务端的 2 分钟响应缓存：`/login/qr/key` 的 URL 是固定的，
    // 走缓存的话用户点"刷新二维码"会一直拿到同一个（可能已过期的）key。
    final Map<String, Object?> keyBody = await _client.get(
      '/login/qr/key',
      raw: true,
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 20),
    );
    final Map<String, Object?> keyData =
        asMap(keyBody['data']) ?? const <String, Object?>{};
    final String? key = asString(keyData['unikey']) ?? asString(keyData['key']);
    if (key == null) {
      throw MusicApiException(
        asString(keyBody['message']) ??
            asString(keyBody['msg']) ??
            '未能获取二维码，请稍后重试',
        source: MediaSource.netease,
        code: asInt(keyBody['code']),
      );
    }

    final Map<String, Object?> body = await _client.get(
      '/login/qr/create',
      query: <String, Object?>{'key': key, 'qrimg': 'true'},
      raw: true,
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 20),
    );
    final Map<String, Object?> data =
        asMap(body['data']) ?? const <String, Object?>{};
    final String? imageDataUrl = asString(data['qrimg']);

    return NeteaseQrSession(
      key: key,
      url:
          asString(data['qrurl']) ?? 'https://music.163.com/login?codekey=$key',
      imageDataUrl: imageDataUrl,
      imageBytes: _decodeDataUrl(imageDataUrl),
    );
  }

  /// 轮询二维码状态。
  Future<NeteaseQrPollResult> pollQrStatus(String key) async {
    final Map<String, Object?> body = await _client.get(
      '/login/qr/check',
      query: <String, Object?>{'key': key},
      // 801/802/803 是业务状态，不是错误信封，不能按 code != 200 抛错。
      raw: true,
      // 同一条 URL 会被服务端缓存 2 分钟，不绕过的话状态永远停在第一次的结果。
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 15),
    );

    final int? code = asInt(body['code']);
    final String? message = asString(body['message']) ?? asString(body['msg']);

    final NeteaseQrStatus status;
    switch (code) {
      case 800:
        status = NeteaseQrStatus.expired;
      case 801:
        status = NeteaseQrStatus.waiting;
      case 802:
        status = NeteaseQrStatus.scanned;
      case 803:
        status = NeteaseQrStatus.authorized;
      default:
        status = NeteaseQrStatus.unknown;
    }

    String? cookie;
    if (status == NeteaseQrStatus.authorized) {
      cookie = asString(body['cookie']);
      if (cookie != null) {
        _client.cookie = cookie;
        await _saveCookie(cookie);
        // 顺手把账号信息也拉回来，UI 就能直接显示头像昵称。
        await _refreshAndCacheProfile();
      }
    }

    return NeteaseQrPollResult(
      status: status,
      cookie: cookie,
      message: message,
    );
  }

  // ------------------------------------------------------------ 手机号登录

  /// 手机号 + 密码登录。返回账号信息（拿不到就返回 null，但登录本身算成功）。
  Future<AccountProfile?> loginWithPassword({
    required String phone,
    required String password,
  }) async {
    final Map<String, Object?> body = await _client.get(
      '/login/cellphone',
      query: <String, Object?>{
        'phone': phone,
        'password': password,
        'countrycode': defaultCountryCode,
      },
      raw: true,
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 25),
    );
    return _completePhoneLogin(body);
  }

  /// 手机号 + 短信验证码登录。
  Future<AccountProfile?> loginWithCaptcha({
    required String phone,
    required String captcha,
  }) async {
    final Map<String, Object?> body = await _client.get(
      '/login/cellphone',
      query: <String, Object?>{
        'phone': phone,
        'captcha': captcha,
        'countrycode': defaultCountryCode,
      },
      raw: true,
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 25),
    );
    return _completePhoneLogin(body);
  }

  /// 请求发送短信验证码。
  Future<void> sendCaptcha(String phone) async {
    final Map<String, Object?> body = await _client.get(
      '/captcha/sent',
      query: <String, Object?>{'phone': phone},
      raw: true,
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 25),
    );
    final int? code = asInt(body['code']);
    if (code == 200) return;
    throw MusicApiException(
      _failureMessage(body, fallback: '验证码发送失败，请稍后重试'),
      source: MediaSource.netease,
      code: code,
    );
  }

  /// 退出登录。
  ///
  /// 服务端请求是"尽力而为"：即使它失败了，本地凭据也必须清掉 ——
  /// 否则用户点了退出，界面却还是登录态，只能去删配置文件。
  Future<void> logout() async {
    try {
      await _client.get('/logout', raw: true, bypassCache: true);
    } on MusicApiException catch (error) {
      debugPrint('[netease] 退出登录接口调用失败，已忽略：${error.message}');
    } finally {
      await forgetSession();
    }
  }

  /// 只清本地凭据，不调服务端。
  ///
  /// 用于"cookie 已经失效"的场景（`/login/status` 明确回 301 时），
  /// 这时候再去调 /logout 只会多一次必然失败的请求。
  Future<void> forgetSession() async {
    _client.cookie = null;
    cachedProfile = null;
    await _clearStored();
  }

  // -------------------------------------------------------------- 会话恢复

  /// 本地是否存着 cookie（不联网、也不校验是否还有效）。
  bool get hasStoredCookie => asString(_prefs.getString(cookieKey)) != null;

  /// 读取本地 cookie 并用 `/login/status` 验证。
  ///
  /// 返回可用的 cookie；cookie 不存在或已失效时返回 null 并清空本地存储
  /// （留着死 cookie 会让每次请求都白跑一趟 /login/status）。
  Future<String?> restore() async {
    final String? saved = asString(_prefs.getString(cookieKey));
    if (saved == null) {
      // 没有 cookie 就是未登录。顺手清掉残留的账号缓存，
      // 否则界面上会出现"明明是未登录、却还显示着上次的账号"。
      await _clearStored();
      cachedProfile = null;
      return null;
    }

    _client.cookie = saved;
    try {
      final Map<String, Object?> body = await _client.get(
        '/login/status',
        bypassCache: true,
        receiveTimeout: const Duration(seconds: 20),
      );
      final AccountProfile? profile = tryParseProfile(body);
      if (profile == null) {
        // code 仍是 200 但 profile 为 null：cookie 已经不被服务端认了。
        await _clearStored();
        _client.cookie = null;
        cachedProfile = null;
        return null;
      }
      cachedProfile = profile;
      await _saveProfile(profile);
      return saved;
    } on MusicApiException catch (error) {
      if (error.isAuthError) {
        await _clearStored();
        _client.cookie = null;
        cachedProfile = null;
        return null;
      }
      // 内嵌服务没起来之类的临时故障：保留 cookie，下次启动再验证。
      rethrow;
    }
  }

  /// 直接读本地缓存的账号信息（不联网）。冷启动时先拿它渲染账号卡片。
  AccountProfile? readCachedProfile() {
    final String? raw = _prefs.getString(profileKey);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final Map<String, Object?>? map = asMap(jsonDecode(raw));
      final AccountProfile? profile = map == null ? null : tryParseProfile(map);
      cachedProfile = profile;
      return profile;
    } catch (error) {
      // 存档损坏不是致命问题，当作未登录处理即可。
      debugPrint('[netease] 本地账号缓存解析失败：$error');
      return null;
    }
  }

  // -------------------------------------------------------------------- 内部

  Future<AccountProfile?> _completePhoneLogin(Map<String, Object?> body) async {
    final int? code = asInt(body['code']);
    if (code != 200) {
      throw MusicApiException(
        _failureMessage(body, fallback: '登录失败，请检查手机号与密码'),
        source: MediaSource.netease,
        code: code,
      );
    }

    final String? cookie = asString(body['cookie']);
    if (cookie == null) {
      throw const MusicApiException(
        '登录成功但没有拿到凭据，请重试或改用二维码登录',
        source: MediaSource.netease,
      );
    }
    _client.cookie = cookie;
    await _saveCookie(cookie);
    return _refreshAndCacheProfile();
  }

  Future<AccountProfile?> _refreshAndCacheProfile() async {
    final Map<String, Object?> body = await _client.get(
      '/login/status',
      bypassCache: true,
      receiveTimeout: const Duration(seconds: 20),
    );
    final AccountProfile? profile = tryParseProfile(body);
    if (profile != null) await _saveProfile(profile);
    cachedProfile = profile;
    return profile;
  }

  /// 登录类接口的失败文案。
  ///
  /// 优先用服务端返回的中文提示（它最准确），拿不到再按错误码兜底。
  /// 错误码含义是"尽力而为"的经验值，不同版本可能微调，所以不能只靠它。
  String _failureMessage(
    Map<String, Object?> body, {
    required String fallback,
  }) {
    final String? fromServer =
        asString(body['message']) ?? asString(body['msg']);
    if (fromServer != null) return fromServer;

    switch (asInt(body['code'])) {
      case 400:
        return '请求参数有误，请检查手机号格式';
      case 250:
        return '该账号需要绑定手机号后才能登录';
      case 501:
        return '账号或密码错误；若账号已开启二次验证，请改用验证码登录';
      case 502:
        return '该账号已被冻结，请前往网易云官方客户端处理';
      case 503:
        return '网易云要求短信验证，请改用验证码登录';
      case 504:
        return '该账号不存在，请检查手机号是否正确';
      default:
        return fallback;
    }
  }

  Future<void> _saveCookie(String cookie) async {
    await _prefs.setString(cookieKey, cookie);
  }

  Future<void> _saveProfile(AccountProfile profile) async {
    await _prefs.setString(
      profileKey,
      jsonEncode(<String, Object?>{
        'userId': profile.userId,
        'nickname': profile.nickname,
        'avatarUrl': profile.avatarUrl,
        'signature': profile.signature,
        // 存一个等价的 vipType，读回时才能还原出 vipLabel。
        'vipType': profile.vipLabel == null ? 0 : 1,
        'follows': profile.follows,
        'followers': profile.followers,
      }),
    );
  }

  Future<void> _clearStored() async {
    await _prefs.remove(cookieKey);
    await _prefs.remove(profileKey);
  }

  /// 把 `data:image/png;base64,xxx` 解成字节；解不出来返回 null。
  Uint8List? _decodeDataUrl(String? dataUrl) {
    if (dataUrl == null) return null;
    final int comma = dataUrl.indexOf(',');
    final String payload = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
    if (payload.isEmpty) return null;
    try {
      return base64Decode(payload);
    } catch (error) {
      debugPrint('[netease] 二维码图片解码失败：$error');
      return null;
    }
  }
}

/// 全局唯一的登录服务。
///
/// 与 [neteaseApiClientProvider] 共享同一个客户端实例：cookie 挂在客户端上，
/// 各建一份的话登录完 repository 依旧是无凭据状态。
final Provider<NeteaseLoginService> neteaseLoginServiceProvider =
    Provider<NeteaseLoginService>((Ref ref) {
      return NeteaseLoginService(
        apiClient: ref.watch(neteaseApiClientProvider),
        preferences: ref.watch(sharedPreferencesProvider),
      );
    });
