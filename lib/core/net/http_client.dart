import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 访问哔哩接口时使用的浏览器 UA。
///
/// 这不是"伪装"而是必需项：哔哩的 Web 接口对未知 UA 会返回风控页或
/// 空数据，音频 CDN 更是会直接 403。全局统一一个 UA 也便于排查问题。
const String kBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

/// 构造一个配置统一的 [Dio]。
///
/// 统一超时与 UA，避免各音源各写一套；日志只在 debug 下开，
/// 且默认关闭响应体打印（音乐接口的响应动辄几百 KB，全打出来反而没法看）。
Dio createZhyDio({
  String? baseUrl,
  Map<String, String>? defaultHeaders,
  Duration connectTimeout = const Duration(seconds: 12),
  Duration receiveTimeout = const Duration(seconds: 20),
}) {
  final Dio dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? '',
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: connectTimeout,
      // 交给我们自己判断状态码：平台接口在 4xx 时也常常返回有用的错误码。
      validateStatus: (int? status) => status != null && status < 500,
      headers: <String, String>{
        'User-Agent': kBrowserUserAgent,
        ...?defaultHeaders,
      },
      responseType: ResponseType.json,
    ),
  );

  if (kDebugMode) {
    dio.interceptors.add(
      LogInterceptor(
        request: false,
        requestHeader: false,
        requestBody: false,
        responseHeader: false,
        responseBody: false,
        logPrint: (Object object) => debugPrint('[http] $object'),
      ),
    );
  }

  return dio;
}

/// 默认 HTTP 客户端（不绑定 baseUrl，按绝对地址请求）。
final Provider<Dio> dioProvider = Provider<Dio>((Ref ref) {
  final Dio dio = createZhyDio();
  ref.onDispose(dio.close);
  return dio;
});
