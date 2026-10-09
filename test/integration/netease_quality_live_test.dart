import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/net/http_client.dart';
import 'package:zhuoyue_player/core/runtime/embedded_netease_api.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/data/netease/netease_api_client.dart';
import 'package:zhuoyue_player/data/netease/netease_login.dart';
import 'package:zhuoyue_player/data/netease/netease_parsers.dart';
import 'package:zhuoyue_player/data/netease/netease_repository.dart';
import 'package:zhuoyue_player/data/repositories/music_repository.dart';

/// 真实接口下「自动」音质观测的验证。
///
/// 它回答两个纯单测回答不了的问题：
/// 1. 真实 `/song/url/v1` 的 `level` 字段到底有没有、能不能认 ——
///    自动档的整个观测机制都建立在"这是权威信号"之上；
/// 2. "绝大多数歌能拿到无损、只有个别歌没有"这个前提在真实账号上是否成立。
///    如果成立，就不能因为少数单曲缺无损而把自动档整体降级。
///
/// 默认**跳过**，显式开启（运行时目录由 `scripts/fetch-runtime.ps1` 准备好）：
///
/// ```powershell
/// $env:ZHY_LIVE_TESTS = '1'
/// flutter test test\integration\netease_quality_live_test.dart
/// ```
///
/// 想验登录态（黑胶 VIP）再带上真实 cookie，注意**别把 cookie 写进文件**：
///
/// ```powershell
/// $env:ZHY_LIVE_COOKIE = 'MUSIC_U=...; __csrf=...'
/// ```
///
/// 注意：**不要**在这个文件里调 `TestWidgetsFlutterBinding.ensureInitialized()`，
/// 那会让 Dio 用测试用的假 HttpClient，所有 HTTP 请求都变成 400。
const String _enableFlag = 'ZHY_LIVE_TESTS';

/// 未开启时给每个用例的跳过原因。
final Object _skipReason = Platform.environment[_enableFlag] == '1'
    ? false
    : '联网集成测试：设置环境变量 $_enableFlag=1 后运行';

void main() {
  late EmbeddedNeteaseApi api;
  late NeteaseApiClient apiClient;
  late NeteaseRepository repository;

  final String? liveCookie = _trimmed(Platform.environment['ZHY_LIVE_COOKIE']);

  setUpAll(() async {
    // 用内存版本，绝不碰用户真实的那份偏好文件（正在跑的应用会覆盖它）。
    SharedPreferences.setMockInitialValues(<String, Object>{
      NeteaseLoginService.cookieKey: ?liveCookie,
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    api = EmbeddedNeteaseApi();
    final Dio dio = createZhyDio(receiveTimeout: const Duration(seconds: 30));
    apiClient = NeteaseApiClient(api, dio);
    repository = NeteaseRepository(
      apiClient,
      loginService: NeteaseLoginService(apiClient: apiClient, preferences: prefs),
      preferences: prefs,
    );
  });

  tearDownAll(() async {
    repository.dispose();
    // 必须等它真的退出：测试要断言"没留下孤儿 node 进程"。
    await shutdownEmbeddedNeteaseApi(waitForExit: true);
  });

  test(
    '真实 /song/url/v1 会回 level，且它是可识别的档位',
    () async {
      final List<Song> songs = await repository.search('晴天 周杰伦', limit: 5);
      expect(songs, isNotEmpty);
      final Song song = songs.firstWhere(
        (Song s) => s.playable,
        orElse: () => songs.first,
      );

      final Map<String, Object?> body = await apiClient.get(
        '/song/url/v1',
        query: <String, Object?>{'id': song.id, 'level': 'exhigh'},
        receiveTimeout: const Duration(seconds: 30),
      );
      final String? level = neteaseActualLevelId(body);

      debugPrint('[live] ${song.title} 请求 exhigh → 实际 level=$level');
      expect(
        level,
        isNotNull,
        reason: '真实接口必须回可识别的 level，否则自动档没有任何权威信号可用',
      );
      expect(
        neteaseLevelLabel(level),
        isNotNull,
        reason: '认不出的档位无法参与比较（nieatseLevelLabel 是唯一的口径）',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _skipReason,
  );

  test(
    '批量自动档：真实数据不该把上限降下去',
    () async {
      // 带 cookie 时先刷新账号，这样自动档会按真实会员等级起算（黑胶 VIP → 无损）。
      if (liveCookie != null) {
        await repository.refreshAccount();
      }
      debugPrint(
        '[live] 登录态=${repository.isAuthenticated} '
        '会员=${repository.account?.vipLabel ?? "无"} '
        '自动档初始=${repository.effectiveQuality.id}',
      );

      final List<Song> all = await repository.search('周杰伦', limit: 30);
      final List<Song> playable = all
          .where((Song s) => s.playable)
          .take(24)
          .toList();
      expect(playable, isNotEmpty);

      final Map<String, int> distribution = <String, int>{};
      for (final Song song in playable) {
        try {
          final ResolvedStream stream = await repository.resolveStream(song);
          final String label = stream.qualityLabel ?? '未标注';
          distribution.update(label, (int n) => n + 1, ifAbsent: () => 1);
        } on MusicApiException catch (error) {
          // 版权下架之类的单曲失败是正常的，不该中断整轮采样。
          final String key = '失败：${error.message}';
          distribution.update(key, (int n) => n + 1, ifAbsent: () => 1);
        }
      }

      // 这几行是本次验证的主要产出，用同步版本打印：`debugPrint` 默认限流
      // （缓冲 + 定时刷），测试进程退得太快会把它们丢掉。
      debugPrintSynchronously(
        '[live] ${playable.length} 首实际音质分布：$distribution',
      );
      debugPrintSynchronously(
        '[live] 自动档上限=${repository.autoQualityCeiling.id}',
      );

      // 关键断言：真实账号上多数歌有更高规格，自动档的上限不该被少数
      // 没有无损的单曲拖到免费档。
      expect(
        repository.autoQualityCeiling.id,
        isNot(kAutoQualityDegradeFloorId),
        reason: '真实数据下自动档被降到了免费档 —— 说明判据把单曲差异算成了"没权益"',
      );

      if (liveCookie != null) {
        expect(
          distribution.keys.any((String k) => k.contains('无损') || k.contains('Hi-Res')),
          isTrue,
          reason: '黑胶 VIP 账号在这一批里应当至少有一首拿到无损以上',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: _skipReason,
  );
}

String? _trimmed(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
