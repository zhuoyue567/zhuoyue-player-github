import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/http_client.dart';
import '../../core/runtime/embedded_netease_api.dart';
import '../models/media_source.dart';
import '../repositories/music_repository.dart';
import 'netease_parsers.dart';

/// 内嵌网易云服务的薄 HTTP 层。
///
/// 职责边界刻意收得很窄：
/// - 保证服务已启动，拼出 `http://127.0.0.1:<port>/<path>`；
/// - 带上 Dart 端持有的 cookie；
/// - 把「业务 code + 中文 message」翻译成 [MusicApiException]。
///
/// **cookie 由 Dart 端持有**（[cookie] 字段）而不是交给 node 进程自己的
/// cookie jar：那个 jar 是进程内存里的，一旦内嵌服务因为崩溃/升级被重启，
/// 登录态就凭空消失，用户会莫名其妙地被登出。放进请求参数则完全无状态 ——
/// 服务端每次请求现读，重启多少次都不影响。
class NeteaseApiClient {
  NeteaseApiClient(this._api, this._dio);

  /// 本客户端对应的音源。
  static const MediaSource source = MediaSource.netease;

  /// 播放地址接口偶尔要等 CDN 回源，给宽一点。
  static const Duration _defaultReceiveTimeout = Duration(seconds: 25);

  final EmbeddedNeteaseApi _api;
  final Dio _dio;

  /// 登录 cookie（`MUSIC_U=...; __csrf=...` 形式）。null 表示未登录。
  String? cookie;

  /// 是否持有 cookie。注意它不代表 cookie 仍然有效，
  /// 有效性由 `/login/status` 说了算（见 `NeteaseLoginService.restore`）。
  bool get hasCookie => cookie != null && cookie!.isNotEmpty;

  /// 发起一次 GET 请求并解包响应信封。
  ///
  /// 网易云的接口几乎全都可以用 GET（服务端用 `app.use` 注册路由，不区分方法），
  /// 唯一需要 POST 的是本地文件上传，用不到。
  ///
  /// [raw] 为 true 时**不做 code 校验**：登录类接口（二维码轮询、手机登录）
  /// 的 code 本身就是业务返回值（801 等待扫码、501 密码错误），
  /// 当成错误信封解包会把正常流程判成失败。
  ///
  /// [bypassCache] 会带上 `x-apicache-bypass` 头。内嵌服务对 200 响应做了
  /// 2 分钟的 URL 级缓存，二维码轮询、登录状态、红心列表这类"必须实时"的
  /// 接口必须绕过，否则用户会一直看到 2 分钟前的旧状态。
  Future<Map<String, Object?>> get(
    String path, {
    Map<String, Object?>? query,
    bool raw = false,
    bool bypassCache = false,
    Duration? receiveTimeout,
  }) async {
    final int port = await _api.ensureStarted();

    final Map<String, String> params = <String, String>{};
    query?.forEach((String key, Object? value) {
      if (value == null) return;
      params[key] = '$value';
    });
    final String? current = cookie;
    if (current != null && current.isNotEmpty) {
      params['cookie'] = current;
    }

    final Uri uri = Uri.parse('http://${EmbeddedNeteaseApi.host}:$port$path')
        .replace(queryParameters: params.isEmpty ? null : params);

    final Response<dynamic> response;
    try {
      response = await _dio.getUri<dynamic>(
        uri,
        options: Options(
          // 服务端在"需要登录"时回 301 且带 JSON body（{"code":301}），
          // 一旦让 Dio 跟着跳转，body 就丢了，登录态判断也就无从谈起。
          followRedirects: false,
          receiveTimeout: receiveTimeout ?? _defaultReceiveTimeout,
          responseType: ResponseType.json,
          headers: bypassCache
              ? const <String, String>{'x-apicache-bypass': '1'}
              : null,
        ),
      );
    } on DioException catch (error) {
      // 连接被拒 = 内嵌服务没起来或刚崩。这种错误必须给出"服务不可用"的
      // 明确说法，否则用户只会看到一个干巴巴的超时。
      throw MusicApiException(
        '内嵌网易云服务不可用，请稍后重试（若持续失败，请在设置中查看运行日志）',
        source: source,
        cause: error,
      );
    }

    final int? status = response.statusCode;
    if (status != null && status >= 400) {
      throw MusicApiException(
        '内嵌网易云服务返回 HTTP $status（$path）',
        source: source,
        code: status,
      );
    }

    final Map<String, Object?> body = _asBody(response.data, path);
    if (raw) return body;
    return _unwrap(body, path);
  }

  /// 诊断用：确认服务真的能应答。
  ///
  /// 与普通请求的区别是失败时会把内嵌服务的最近日志一起带上 ——
  /// 这个方法的唯一用途就是让用户/开发者知道"到底哪里坏了"。
  Future<void> ping() async {
    try {
      await get('/login/status', raw: true, bypassCache: true);
    } on MusicApiException catch (error) {
      final List<String> logs = _api.recentLogs;
      final String tail = logs.isEmpty
          ? '（无日志输出）'
          : logs.sublist(logs.length > 10 ? logs.length - 10 : 0).join('\n');
      throw MusicApiException(
        '${error.message}\n最近日志：\n$tail',
        source: source,
        code: error.code,
        cause: error.cause,
      );
    }
  }

  Map<String, Object?> _asBody(Object? data, String path) {
    final Map<String, Object?>? map = asMap(data);
    if (map != null) return map;
    if (data is String && data.trim().isNotEmpty) {
      // 服务端偶尔会回 HTML（例如版本不兼容时的错误页），
      // 这里把它当成"不是我们认识的响应"，而不是硬解析成 JSON 崩掉。
      throw MusicApiException('内嵌网易云服务返回了非 JSON 响应（$path）', source: source);
    }
    throw MusicApiException('内嵌网易云服务返回了空响应（$path）', source: source);
  }

  /// 解包 `{code, message/msg, ...}` 信封。
  Map<String, Object?> _unwrap(Map<String, Object?> body, String path) {
    final Map<String, Object?>? data = asMap(body['data']);
    // /login/status 只在 data 里带 code，顶层没有 code 字段。
    int? code = asInt(body['code']) ?? asInt(data?['code']);
    if (code == null) return body;

    if (code == 200) return body;

    final String message =
        asString(body['message']) ??
        asString(body['msg']) ??
        asString(data?['message']) ??
        asString(data?['msg']) ??
        '';

    if (code == 301) {
      throw MusicApiException(
        message.isEmpty ? '需要登录网易云账号' : message,
        source: source,
        code: code,
        isAuthError: true,
      );
    }
    if (code == -462) {
      throw MusicApiException(
        '网易云触发了风控校验（-462），请稍后再试；短时间内请求过于频繁也会这样',
        source: source,
        code: code,
      );
    }

    throw MusicApiException(
      message.isEmpty ? '网易云接口返回错误码 $code（$path）' : message,
      source: source,
      code: code,
      // 250 是"需要绑定手机"，同样要靠重新登录/绑定才能继续。
      isAuthError: code == 250,
    );
  }
}

/// 全局唯一的接口客户端。
///
/// 单独提出来是为了让登录服务与 repository 共享**同一个** [NeteaseApiClient]：
/// cookie 存在这个对象上，如果各自 new 一个，登录后 repository 依旧拿着空
/// cookie 去请求，表现为"登录成功但列表还是空的"。
final Provider<NeteaseApiClient> neteaseApiClientProvider =
    Provider<NeteaseApiClient>((Ref ref) {
      return NeteaseApiClient(
        ref.watch(embeddedNeteaseApiProvider),
        ref.watch(dioProvider),
      );
    });
