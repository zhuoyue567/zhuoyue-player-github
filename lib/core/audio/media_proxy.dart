import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../data/models/song.dart';
import '../net/http_client.dart';

/// 本地媒体代理。
///
/// **为什么必须有这个东西**：哔哩的音频 CDN 会校验 `Referer`，不带就直接
/// 403；而 Windows 上的播放后端（Media Foundation）根本没有给我们设置
/// 自定义请求头的入口 —— `just_audio_windows` 拿到 URL 就交给系统播放器了。
///
/// 于是做法是：在 loopback 上起一个极小的 HTTP 服务，把「真实地址 + 必需
/// 请求头」注册成一个本地 URL 再交给播放器，由代理去补齐请求头并转发。
/// 顺带还解决了第二个问题：**Range 请求**。桌面播放器拖动进度条时会发
/// `Range`，代理必须原样透传并回 `206 Partial Content`，否则拖动就会失灵。
class MediaProxyServer {
  MediaProxyServer._(this._server, this._client);

  final HttpServer _server;
  final HttpClient _client;

  /// 代理是进程级单例：它只绑定 loopback 且端口随机，
  /// 起多个实例除了浪费端口没有任何好处。
  static MediaProxyServer? _instance;
  static Future<MediaProxyServer>? _starting;

  /// token -> 原始流信息。
  final Map<String, ResolvedStream> _routes = <String, ResolvedStream>{};

  /// 创建（或复用）代理实例。
  static Future<MediaProxyServer> instance() {
    final MediaProxyServer? existing = _instance;
    if (existing != null) return Future<MediaProxyServer>.value(existing);
    final Future<MediaProxyServer>? starting = _starting;
    if (starting != null) return starting;

    final Future<MediaProxyServer> task = _start();
    _starting = task;
    return task;
  }

  static Future<MediaProxyServer> _start() async {
    // 显式绑定 127.0.0.1：绝不能让这个代理监听 0.0.0.0，
    // 否则同网段的人就能拿它当免费代理去请求任意已注册的媒体地址。
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;

    final MediaProxyServer proxy = MediaProxyServer._(server, client);
    server.listen(
      proxy._handle,
      onError: (Object error) => debugPrint('[proxy] 服务异常: $error'),
    );
    _instance = proxy;
    _starting = null;
    debugPrint('[proxy] 媒体代理已启动: http://127.0.0.1:${server.port}');
    return proxy;
  }

  int get port => _server.port;

  /// 为一个流注册本地代理地址。
  ///
  /// token 由 URL 摘要决定，因此同一首歌重复播放会命中同一个 token，
  /// 不会让 [_routes] 无限增长。
  Uri register(ResolvedStream stream) {
    final String token = sha1
        .convert(utf8.encode(stream.url.toString()))
        .toString()
        .substring(0, 24);
    _routes[token] = stream;
    return Uri.parse('http://127.0.0.1:$port/stream/$token');
  }

  /// 需要代理的流才走代理；没有自定义请求头的一律直连，少一层转发。
  Uri proxiedUriFor(ResolvedStream stream) =>
      stream.headers.isEmpty ? stream.url : register(stream);

  Future<void> _handle(HttpRequest request) async {
    final List<String> segments = request.uri.pathSegments;
    if (segments.length != 2 || segments.first != 'stream') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final ResolvedStream? stream = _routes[segments[1]];
    if (stream == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      final HttpClientRequest upstream = await _client.openUrl(
        request.method,
        stream.url,
      );

      // 代理存在的全部意义就在这几行：把播放器没法设置的头补上。
      upstream.headers.set(HttpHeaders.userAgentHeader, kBrowserUserAgent);
      stream.headers.forEach(upstream.headers.set);

      // Range 必须原样透传，否则拖动进度条会退化成"从头下载"。
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, range);
      }

      final HttpClientResponse upstreamResponse = await upstream.close();
      final HttpResponse out = request.response;
      out.statusCode = upstreamResponse.statusCode;

      for (final String name in const <String>[
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
      ]) {
        final List<String>? values = upstreamResponse.headers[name];
        if (values != null && values.isNotEmpty) {
          out.headers.set(name, values.join(', '));
        }
      }
      if (out.headers.value('accept-ranges') == null) {
        out.headers.set('accept-ranges', 'bytes');
      }

      if (request.method == 'HEAD') {
        await out.close();
        return;
      }

      // 不做缓冲：边下边播，起播延迟最低。
      await upstreamResponse.pipe(out);
    } on Object catch (error) {
      debugPrint('[proxy] 转发失败 ${stream.url}: $error');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } on Object {
        // 响应可能已经开始写了，这时只能放弃。
      }
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    _client.close(force: true);
    if (identical(_instance, this)) _instance = null;
    _routes.clear();
  }
}
