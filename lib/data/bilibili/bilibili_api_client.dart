import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_source.dart';
import '../repositories/music_repository.dart';
import 'bilibili_parsers.dart';

/// 哔哩哔哩 Web 接口域名。
const String kBilibiliApiHost = 'https://api.bilibili.com';

/// 哔哩哔哩登录（passport）域名。
const String kBilibiliPassportHost = 'https://passport.bilibili.com';

/// **调用 API 时**用的 Referer。
///
/// 哔哩对大多数接口做防盗链校验，缺这个头会拿到风控页或空数据。
const String kBilibiliReferer = 'https://www.bilibili.com';

/// **拉取音频流时**用的 Referer（注意结尾多一个 `/`）。
///
/// 与 [kBilibiliReferer] 是两个不同的值：API 用不带斜杠的，CDN 用带斜杠的，
/// 实测两者 CDN 都放行，但保持与浏览器实际发出的值一致最保险。
const String kBilibiliCdnReferer = 'https://www.bilibili.com/';

/// 哔哩哔哩接口客户端：一个 [Dio] + Dart 侧自己维护的 cookie + WBI 签名。
///
/// 为什么 cookie 要由 Dart 自己管：
/// 哔哩的登录态完全靠 cookie（`SESSDATA` 决定"你是谁"，`bili_jct` 是所有
/// 写操作的 CSRF token），而 dio 默认既不持久化 cookie 也不在重定向后保留，
/// 登录一次就得手动把 `Set-Cookie` 里的东西接住、存下来、之后每次带上。
/// 所以这里做一份**内存 + SharedPreferences 双份**的 cookie：
/// 内存那份是当前会话的事实来源，持久化那份保证重启后还认得你。
class BilibiliApiClient {
  BilibiliApiClient({required this._dio, required this._preferences});
  final Dio _dio;
  final SharedPreferences _preferences;

  /// cookie 的持久化键。整份 cookie 存成 `a=1; b=2` 一个字符串。
  static const String cookiePreferenceKey = 'bilibili.cookie';

  final Map<String, String> _cookies = <String, String>{};
  bool _sessionLoaded = false;

  // ---- WBI 签名状态 -------------------------------------------------------

  /// WBI 的 mixin key 缓存。官方实现建议缓存半小时，这里照做。
  static const Duration _wbiKeyTtl = Duration(minutes: 30);

  /// 官方固定的重排表。把 `img_key + sub_key`（各 32 字符，共 64）
  /// 按这张表重排后取前 32 位，就是 mixin key。
  static const List<int> _wbiPermutation = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52,
  ];

  String? _wbiMixinKey;
  DateTime? _wbiMixinKeyExpiresAt;

  // -------------------------------------------------------------------------
  // cookie
  // -------------------------------------------------------------------------

  /// 组装成 `Cookie:` 请求头的值。
  String get cookieHeader => _cookies.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join('; ');

  /// 本地是否存有登录态（只看有没有 `SESSDATA`，不代表它还有效）。
  bool get hasSession => asString(_cookies['SESSDATA']) != null;

  /// 读某个 cookie 的值（写操作要用的 `bili_jct` 就走这里）。
  String? cookieValue(String name) => _cookies[name];

  /// 从 SharedPreferences 载入持久化的 cookie（幂等，只会真正读一次）。
  void loadPersistedSession() {
    if (_sessionLoaded) return;
    _sessionLoaded = true;
    final String? raw = _preferences.getString(cookiePreferenceKey);
    if (raw == null || raw.isEmpty) return;
    for (final String part in raw.split(';')) {
      final String piece = part.trim();
      if (piece.isEmpty) continue;
      final int eq = piece.indexOf('=');
      if (eq <= 0) continue;
      _cookies[piece.substring(0, eq).trim()] = piece.substring(eq + 1).trim();
    }
  }

  /// 合并一批 cookie（登录成功后写入凭据，或从 `Set-Cookie` 里接住服务端下发的）。
  void mergeCookies(Map<String, String> cookies) {
    _cookies.addAll(cookies);
  }

  /// 把当前 cookie 落盘。
  Future<void> persistCookies() async {
    await _preferences.setString(cookiePreferenceKey, cookieHeader);
  }

  /// 清空登录态（退出登录）。
  Future<void> clearSession() async {
    _cookies.clear();
    await _preferences.remove(cookiePreferenceKey);
  }

  // -------------------------------------------------------------------------
  // 请求入口
  // -------------------------------------------------------------------------

  /// 发一个 GET 并返回**整个响应信封** `{"code":..,"message":..,"data":..}`。
  ///
  /// 信封里的 `code` 已经在内部校验过：非 0 一律抛 [MusicApiException]，
  /// 所以调用方拿到的一定是成功响应，只需要关心 `data`。
  ///
  /// [signed] 为 true 时走 WBI 签名（详见 [wbiSign]）。
  /// [tolerateAuthError] 为 true 时 `code == -101`（未登录）不抛异常而是
  /// 把信封原样返回 —— `nav` 接口就是这样：未登录时它仍然返回 `wbi_img`，
  /// 而 WBI 签名正需要这个字段，不能因为它"未登录"就当成错误。
  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, dynamic>? query,
    bool signed = false,
    bool tolerateAuthError = false,
  }) {
    return _request(
      'GET',
      path,
      query: query,
      signed: signed,
      tolerateAuthError: tolerateAuthError,
    );
  }

  /// 只取信封里的 `data`，原样返回（可能是 Map、List 或 null）。
  Future<Object?> getData(
    String path, {
    Map<String, dynamic>? query,
    bool signed = false,
    bool tolerateAuthError = false,
  }) async {
    final Map<String, Object?> body = await getJson(
      path,
      query: query,
      signed: signed,
      tolerateAuthError: tolerateAuthError,
    );
    return body['data'];
  }

  /// 发一个表单 POST。**写操作必须带 `csrf`**（见 [BilibiliApiClient] 类注释）。
  Future<Map<String, Object?>> postForm(
    String path, {
    required Map<String, String> form,
    Map<String, dynamic>? query,
    bool signed = false,
  }) {
    return _request('POST', path, query: query, form: form, signed: signed);
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Map<String, String>? form,
    bool signed = false,
    bool tolerateAuthError = false,
  }) async {
    loadPersistedSession();

    String url = path.startsWith('http') ? path : '$kBilibiliApiHost$path';
    final Map<String, dynamic> params = <String, dynamic>{...?query};

    if (signed) {
      // 签名必须作用在**实际发出去的那串 query** 上：服务端是拿它收到的
      // 原始字符串重算 md5 的。所以签名请求由我们自己拼 query 字符串，
      // 不交给 dio 的 queryParameters 编码 —— 两边对空格的处理不一样
      // （dio/Uri.encodeQueryComponent 编成 `+`，WBI 参考实现编成 `%20`），
      // 只要有一个字符不同，服务端算出来的 w_rid 就和我们的不一样。
      final String queryString = await wbiQueryString(params);
      if (queryString.isNotEmpty) url = '$url?$queryString';
    }

    final Map<String, String> headers = <String, String>{
      'Referer': kBilibiliReferer,
      'Origin': kBilibiliReferer,
      'Accept': 'application/json, text/plain, */*',
    };
    final String cookie = cookieHeader;
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;

    final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        url,
        data: form,
        queryParameters: signed || params.isEmpty ? null : params,
        options: Options(
          method: method,
          // 刻意用 plain 而不是 json：哔哩的风控拦截返回的是 HTML 页面，
          // 交给 dio 的 JSON 转换器只会得到一句"格式错误"，看不到真正原因。
          // 自己 decode 才能在报错里带上 HTTP 状态码和页面标题。
          responseType: ResponseType.plain,
          contentType: form == null ? null : Headers.formUrlEncodedContentType,
          headers: headers,
        ),
      );
    } on DioException catch (error) {
      throw MusicApiException(
        '网络请求失败：${error.message ?? error.type.name}',
        source: MediaSource.bilibili,
        cause: error,
      );
    }

    await _absorbSetCookie(response.headers);
    final Map<String, Object?> body = _decode(response, url);
    return _validate(body, tolerateAuthError: tolerateAuthError);
  }

  /// 把响应体解析成 JSON 对象；解析不出来就抛一条**能直接指向原因**的错误。
  ///
  /// 实测：`/x/web-interface/search/type`（旧路径）现在返回的是
  /// `HTTP 200 + text/html` 的一整页 `出错啦! - aba.bilibili.com`，
  /// 而不是 JSON。如果这里只是简单 `as Map`，上层会看到
  /// "type 'String' is not a subtype of type 'Map'" 这种毫无信息量的崩溃。
  Map<String, Object?> _decode(Response<dynamic> response, String url) {
    final Object? raw = response.data;
    if (raw is Map) return asMap(raw);

    final String text = raw is String ? raw : '';
    if (text.isEmpty) {
      throw MusicApiException(
        '哔哩哔哩返回了空响应（HTTP ${response.statusCode}）',
        source: MediaSource.bilibili,
        code: response.statusCode,
      );
    }
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map) return asMap(decoded);
    } on FormatException {
      // 落到下面统一报错。
    }
    final String title =
        RegExp(
          r'<title>(.*?)</title>',
          dotAll: true,
        ).firstMatch(text)?.group(1)?.trim() ??
        '';
    throw MusicApiException(
      '哔哩哔哩返回了非 JSON 响应（HTTP ${response.statusCode}'
      '${title.isEmpty ? '' : '，页面标题：$title'}），'
      '通常是接口路径已变更或请求被风控拦截。',
      source: MediaSource.bilibili,
      code: response.statusCode,
    );
  }

  /// 校验信封的业务错误码。
  Map<String, Object?> _validate(
    Map<String, Object?> body, {
    required bool tolerateAuthError,
  }) {
    final int code = asInt(body['code']) ?? 0;
    if (code == 0) return body;

    // 实测两个字段名都会出现：`nav` 用 `message`，音频区的
    // `music-service-c/url` 用的是 `msg`。只读一个会丢掉真正的原因。
    final String? apiMessage =
        asString(body['message']) ?? asString(body['msg']);
    final String reason = _describeCode(code);
    final bool isAuthError = code == -101;

    if (isAuthError && tolerateAuthError) return body;

    throw MusicApiException(
      apiMessage == null ? reason : '$reason（接口返回：$apiMessage）',
      source: MediaSource.bilibili,
      code: code,
      isAuthError: isAuthError,
    );
  }

  /// 把业务错误码翻译成用户能看懂的话。括号里的数字实测都真出现过。
  static String _describeCode(int code) {
    switch (code) {
      case -101:
        return '哔哩哔哩账号未登录或登录态已失效';
      case -403:
        return '哔哩哔哩访问权限不足';
      case -352:
        return '哔哩哔哩风控校验失败，请稍后重试，或先在浏览器里登录一次哔哩哔哩';
      case -400:
        return '哔哩哔哩请求参数错误';
      case 72000000:
        return '哔哩哔哩音频接口参数校验失败'
            '（必须同时带 songid / mid / quality / privilege / platform）';
      case 7201006:
        return '音频未找到或已下架';
      default:
        return '哔哩哔哩接口返回错误（code=$code）';
    }
  }

  // -------------------------------------------------------------------------
  // Set-Cookie 处理
  // -------------------------------------------------------------------------

  /// 解析并合并 `Set-Cookie`。
  ///
  /// dio 的 `response.headers` 里，同一个头的多个值以 `List<String>` 出现；
  /// 但它也可能被上层拼成一个字符串，所以两种都要处理。
  Future<void> _absorbSetCookie(Headers headers) async {
    final List<String> entries = <String>[];
    for (final MapEntry<String, List<String>> entry in headers.map.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final String value in entry.value) {
        entries.addAll(_splitJoinedSetCookie(value));
      }
    }
    if (entries.isEmpty) return;

    bool changed = false;
    for (final String entry in entries) {
      final int semicolon = entry.indexOf(';');
      final String pair =
          (semicolon < 0 ? entry : entry.substring(0, semicolon)).trim();
      final int eq = pair.indexOf('=');
      if (eq <= 0) continue;

      final String name = pair.substring(0, eq).trim();
      final String value = pair.substring(eq + 1).trim();
      if (name.isEmpty || _cookieAttributes.contains(name.toLowerCase())) {
        continue;
      }

      if (value.isEmpty) {
        // 值为空 = 服务端要求删除这个 cookie（退出登录时就是这样）。
        changed = _cookies.remove(name) != null || changed;
      } else if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }
    if (changed) await persistCookies();
  }

  /// 单个 `Set-Cookie` 里以 `;` 分隔的属性名，不能当成 cookie 键。
  static const Set<String> _cookieAttributes = <String>{
    'path',
    'domain',
    'expires',
    'max-age',
    'httponly',
    'secure',
    'samesite',
    'version',
    'comment',
    'commenturl',
    'discard',
    'port',
  };

  /// 把可能被拼接过的 `Set-Cookie` 拆成多条。
  ///
  /// 只在 `,` 后面紧跟 `名字=` 时才认为是新的一条。这样
  /// `Expires=Wed, 21 Oct 2015 07:28:00 GMT` 里的逗号不会被误拆
  /// （它后面是 ` 21 Oct`，不像 `名字=`）。
  static List<String> _splitJoinedSetCookie(String raw) {
    final List<String> parts = <String>[];
    final RegExp boundary = RegExp(r',\s*(?=[A-Za-z0-9_\-\.]+=)');
    int start = 0;
    for (final RegExpMatch match in boundary.allMatches(raw)) {
      parts.add(raw.substring(start, match.start));
      start = match.end;
    }
    parts.add(raw.substring(start));
    return parts;
  }

  // -------------------------------------------------------------------------
  // WBI 签名
  // -------------------------------------------------------------------------

  /// 给参数补上 `wts` 与 `w_rid`，返回**新的** map（不改动入参）。
  ///
  /// 对应需求里的 `wbi_sign`；Dart 侧统一用驼峰命名。
  ///
  /// 算法（照官方实现，一步步都不能省）：
  /// 1. 取 `nav` 的 `data.wbi_img.img_url` 与 `sub_url`，各自去掉路径与扩展名，
  ///    拼成 64 字符；
  /// 2. 按 [_wbiPermutation] 重排，取**前 32 位**作为 mixin key；
  /// 3. 参数按 key 升序拼成 `k=v&k2=v2`，值里剔除 `!'()*`；
  /// 4. `wts` = 当前 unix 秒；
  /// 5. `w_rid` = md5(排序后的 query + mixin key)。
  ///
  /// **哪些接口真的需要它，实测结论**（这一点和文档说法不完全一致）：
  /// - 本文件与 repository 实际调用的接口（`nav` / `view` / `player/playurl` /
  ///   `v3/fav/*` / `audio/music-service-c/*`）**实测都不校验签名**，
  ///   不签名照样返回 `code: 0`。
  /// - `x/web-interface/wbi/search/type` 实测签名与不签名都能成功，
  ///   为了不依赖这个"宽松"行为，搜索请求仍然按 WBI 规范签名。
  /// - 真正会卡签名的是一批 `x/space/wbi/*` 接口（本实现不使用）。
  ///
  /// 另外必须坦白：**这套签名没能做到端到端验证**。本机访问
  /// `x/space/wbi/arc/search` 时，无论 `w_rid` 正确还是故意写错，
  /// 服务端都返回同一个 `code: -352 风控校验失败`（带 `v_voucher` 挑战），
  /// 因此无法区分"签名对不对"。能确认的只有：重排表算出的 mixin key
  /// （`ea1db124af3c7062474693fa704f4ff8`）与线上公开值一致，
  /// 且带签名时请求能穿过 WAF（完全不签名会拿到 HTML 拦截页）。
  Future<Map<String, dynamic>> wbiSign(Map<String, dynamic> params) async {
    final String mixinKey = await _mixinKey();
    final Map<String, dynamic> signed = <String, dynamic>{...params};
    signed['wts'] = _nowSeconds();
    final String query = _wbiQuery(signed);
    signed['w_rid'] = _md5Hex('$query$mixinKey');
    return signed;
  }

  /// 直接产出签名后的 query 字符串（含 `wts` 与 `w_rid`）。
  ///
  /// 请求层用它而不是用 [wbiSign] 的结果再交给 dio 编码，理由见 `_request`。
  Future<String> wbiQueryString(Map<String, dynamic> params) async {
    final String mixinKey = await _mixinKey();
    final Map<String, dynamic> withTimestamp = <String, dynamic>{
      ...params,
      'wts': _nowSeconds(),
    };
    final String query = _wbiQuery(withTimestamp);
    return '$query&w_rid=${_md5Hex('$query$mixinKey')}';
  }

  /// 取（并缓存）mixin key。
  Future<String> _mixinKey() async {
    final String? cached = _wbiMixinKey;
    final DateTime? expiresAt = _wbiMixinKeyExpiresAt;
    if (cached != null &&
        expiresAt != null &&
        DateTime.now().isBefore(expiresAt)) {
      return cached;
    }

    // 这个 nav 调用自己**不能**签名（签名要用它返回的 key），否则递归；
    // 同时它未登录时也是 `code: -101`，必须容忍。
    final Map<String, Object?> body = await getJson(
      '/x/web-interface/nav',
      tolerateAuthError: true,
    );
    final Map<String, Object?> img = asMap(asMap(body['data'])['wbi_img']);
    final String? imgUrl = asString(img['img_url']);
    final String? subUrl = asString(img['sub_url']);
    if (imgUrl == null || subUrl == null) {
      throw MusicApiException(
        '未能从 nav 接口取到 WBI 密钥（wbi_img），无法生成签名',
        source: MediaSource.bilibili,
      );
    }

    final String raw =
        '${_fileNameWithoutExtension(imgUrl)}${_fileNameWithoutExtension(subUrl)}';
    if (raw.length < _wbiPermutation.length) {
      throw MusicApiException(
        'nav 接口返回的 WBI 密钥长度异常（${raw.length}），无法生成签名',
        source: MediaSource.bilibili,
      );
    }
    final StringBuffer shuffled = StringBuffer();
    for (final int index in _wbiPermutation) {
      shuffled.write(raw[index]);
    }
    final String mixinKey = shuffled.toString().substring(0, 32);

    _wbiMixinKey = mixinKey;
    _wbiMixinKeyExpiresAt = DateTime.now().add(_wbiKeyTtl);
    return mixinKey;
  }

  /// 按 key 升序拼 `k=v&k2=v2`，值里剔除 `!'()*`。
  static String _wbiQuery(Map<String, dynamic> params) {
    final List<String> keys =
        params.keys.map((String k) => k.toString()).toList()..sort();
    final List<String> parts = <String>[];
    for (final String key in keys) {
      final Object? value = params[key];
      if (value == null) continue;
      final String text = value is Iterable
          ? value.join(',')
          : value.toString();
      // 官方参考实现会把值里这 5 个字符去掉再参与签名，服务端同样处理，
      // 所以两边必须一致，否则算出来的 w_rid 对不上。
      parts.add(
        '${_wbiEncode(key)}=${_wbiEncode(text.replaceAll(_wbiStrip, ''))}',
      );
    }
    return parts.join('&');
  }

  static final RegExp _wbiStrip = RegExp(r"[!'()*]");

  static const String _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~';

  /// 按 WBI 参考实现的方式做百分号编码。
  ///
  /// 不能用 `Uri.encodeQueryComponent`：它把空格编成 `+`，
  /// 而参考实现（JS 的 `encodeURIComponent`、Python 的
  /// `urllib.parse.quote(safe='')`）编成 `%20`，两者算出的 w_rid 不同。
  static String _wbiEncode(String value) {
    final StringBuffer buffer = StringBuffer();
    for (final int unit in utf8.encode(value)) {
      final String char = String.fromCharCode(unit);
      if (unit < 128 && _unreserved.contains(char)) {
        buffer.write(char);
      } else {
        buffer.write(
          '%${unit.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
    return buffer.toString();
  }

  static String _md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// `https://i0.hdslb.com/bfs/wbi/7cd0....png` → `7cd0...`
  static String _fileNameWithoutExtension(String url) {
    final String path;
    try {
      path = Uri.parse(url).path;
    } on FormatException {
      return '';
    }
    final String name = path.split('/').last;
    final int dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  /// 释放资源。这里只清理自身状态；[Dio] 由注入方负责关闭。
  void dispose() {
    _cookies.clear();
    _wbiMixinKey = null;
    _wbiMixinKeyExpiresAt = null;
  }
}
