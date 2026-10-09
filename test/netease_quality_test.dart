import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/net/http_client.dart';
import 'package:zhuoyue_player/core/runtime/embedded_netease_api.dart';
import 'package:zhuoyue_player/data/models/collection.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/data/netease/netease_api_client.dart';
import 'package:zhuoyue_player/data/netease/netease_login.dart';
import 'package:zhuoyue_player/data/netease/netease_repository.dart';

/// 「自动」音质上限（ceiling）的行为测试。
///
/// 为什么值得单独一个文件、且写得这么细：这套判定一旦把"某首歌没有无损"
/// 当成"账号没有无损"，用户的无损会被静默降成 320k，而且**现场无法复现**
/// —— 事后没人说得清是哪几首歌触发的。所以每个分支都必须钉死在这里。
///
/// 判据的依据是实测数据（黑胶 VIP 账号「君游虚无」抽 30 首）：
/// 27 首正常无损、1 首只有 320k、2 首无版权 —— 单曲差异常见，
/// 但不可能是"连续 8 首清一色免费档"。
const String _ceilingKey = 'audio.quality.netease.ceiling';
const String _qualityKey = 'audio.quality.netease';

void main() {
  final List<_Harness> harnesses = <_Harness>[];

  tearDown(() async {
    for (final _Harness harness in harnesses) {
      harness.dispose();
    }
    harnesses.clear();
    // 假客户端里那个 EmbeddedNeteaseApi 只是被 new 出来登记了一下（没起进程），
    // 这里统一收尾，别把静态引用留给别的测试。
    await shutdownEmbeddedNeteaseApi();
  });

  /// 造一个能脱离网络跑的 repository。
  ///
  /// [vipLabel] 非空时注入一个"已登录"的账号。注入方式绕了一点，原因是真实的
  /// `/login/status` 只能表达"是不是会员"（见 `tryParseProfile`：vipLabel 只会是
  /// 「黑胶VIP」），用接口 JSON 造不出 SVIP 账号 —— 而 SVIP 正是档位表的最高一档。
  /// 所以先 `logout()` 把会话标记成"已校验"（这样后面的调用不会再走
  /// `/login/status` 把注入的账号冲掉），再把 profile 交给登录服务；
  /// 这一步在真实链路上同样存在：二维码登录成功后就是登录服务交出 profile。
  Future<_Harness> buildHarness({
    String? vipLabel,
    Map<String, Object> prefs = const <String, Object>{},
    String Function(String requested)? actualFor,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final Dio dio = createZhyDio();
    final _FakeClient client = _FakeClient(dio);
    if (actualFor != null) client.actualFor = actualFor;

    final NeteaseLoginService login = NeteaseLoginService(
      apiClient: client,
      preferences: preferences,
    );
    final NeteaseRepository repository = NeteaseRepository(
      client,
      loginService: login,
      preferences: preferences,
    );
    final _Harness harness = _Harness(repository, client, preferences, dio);
    harnesses.add(harness);

    if (vipLabel != null) {
      await repository.logout();
      client.cookie = 'MUSIC_U=test';
      login.cachedProfile = AccountProfile(
        source: MediaSource.netease,
        userId: '10001',
        nickname: '测试账号',
        vipLabel: vipLabel,
      );
      // 账号同步本身是懒的（下一次用到会话的调用才会把登录服务手上的 profile
      // 读进来），所以这里先催一次：否则第一条断言看到的还是"未登录"。
      // 用 lyric() 是因为它不碰音质状态，也不会往 requestedLevels 里塞东西。
      await repository.lyric(_song);
      expect(repository.account?.vipLabel, vipLabel, reason: '账号注入没生效');
    }
    return harness;
  }

  /// 把一串观测按顺序折叠成最终结果（等价于仓库每次 resolveStream 后的读改写）。
  QualityCeilingUpdate fold(
    List<(String, String)> observations, {
    required String ceiling,
    required String maxCeiling,
    String floor = kAutoQualityDegradeFloorId,
  }) {
    QualityCeilingUpdate update = QualityCeilingUpdate(
      ceilingId: ceiling,
      streak: 0,
      lowered: false,
    );
    for (final (String requested, String actual) in observations) {
      update = applyQualityObservation(
        currentCeilingId: update.ceilingId,
        requestedId: requested,
        actualId: actual,
        streak: update.streak,
        maxCeilingId: maxCeiling,
        degradeFloorId: floor,
      );
    }
    return update;
  }

  // ------------------------------------------------- 纯函数：档位比较工具

  group('档位顺序', () {
    test('索引越小档位越高，认不出的档位排在最低档之后', () {
      expect(qualityRank('jymaster'), 0);
      expect(qualityRank('lossless'), lessThan(qualityRank('exhigh')));
      expect(qualityRank('exhigh'), lessThan(qualityRank('higher')));
      expect(qualityRank('higher'), lessThan(qualityRank('standard')));
      // 服务端可能回我们没声明过的档位（例如沉浸声 jyeffect）：
      // 必须是"认不出来"，不能悄悄当成一个正常档位去比较。
      expect(qualityRank('jyeffect'), kUnknownQualityRank);
      expect(qualityRank(''), kUnknownQualityRank);
      expect(qualityIdAtRank(qualityRank('hires')), 'hires');
    });
  });

  // --------------------------------------------- 纯函数：一次观测如何改上限

  group('applyQualityObservation', () {
    test('连续 7 次「请求无损只给极高」上限不动，第 8 次才收到极高', () {
      final QualityCeilingUpdate after7 = fold(
        List<(String, String)>.filled(7, ('lossless', 'exhigh')),
        ceiling: 'lossless',
        maxCeiling: 'lossless',
      );
      expect(after7.ceilingId, 'lossless');
      expect(after7.streak, 7, reason: '计数要累计，供下一首继续判断');
      expect(after7.lowered, isFalse);

      final QualityCeilingUpdate after8 = fold(
        List<(String, String)>.filled(8, ('lossless', 'exhigh')),
        ceiling: 'lossless',
        maxCeiling: 'lossless',
      );
      expect(after8.ceilingId, 'exhigh');
      expect(after8.streak, 0, reason: '降级后计数清零，重新累计');
      expect(after8.lowered, isTrue);
    });

    test('中间夹一次「要到了」（实际==请求）就清零计数，上限不降', () {
      final QualityCeilingUpdate update = fold(
        <(String, String)>[
          ('lossless', 'exhigh'), // 1
          ('lossless', 'exhigh'), // 2
          ('lossless', 'exhigh'), // 3
          ('lossless', 'lossless'), // 要到了 → 清零
          ('lossless', 'exhigh'), // 1
          ('lossless', 'exhigh'), // 2
          ('lossless', 'exhigh'), // 3
          ('lossless', 'exhigh'), // 4
          ('lossless', 'exhigh'), // 5
          ('lossless', 'exhigh'), // 6
          ('lossless', 'exhigh'), // 7
        ],
        ceiling: 'lossless',
        maxCeiling: 'lossless',
      );
      expect(update.streak, 7);
      expect(update.ceilingId, 'lossless');
      expect(update.lowered, isFalse);
    });

    test('这正是真实数据的形态：27 首无损之间夹 1 首 320k，永不降级', () {
      final List<(String, String)> observations = <(String, String)>[
        for (int i = 0; i < 27; i++)
          if (i == 13) ('lossless', 'exhigh') else ('lossless', 'lossless'),
      ];
      final QualityCeilingUpdate update = fold(
        observations,
        ceiling: 'lossless',
        maxCeiling: 'lossless',
      );
      expect(update.ceilingId, 'lossless');
      expect(update.lowered, isFalse);
    });

    test('实际低于请求但高于免费档（请求 Hi-Res 只给无损）不算"没权益"', () {
      final QualityCeilingUpdate update = fold(
        List<(String, String)>.filled(
          kAutoQualityDowngradeStreak + 5,
          ('hires', 'lossless'),
        ),
        ceiling: 'hires',
        maxCeiling: 'hires',
      );
      expect(update.ceilingId, 'hires');
      expect(update.streak, 0, reason: '拿到无损说明权益是被认的，不该累计');
    });

    test('降到免费档而不是"这一次实际给的档位"：实际只有 128k 也收在极高', () {
      final QualityCeilingUpdate update = fold(
        List<(String, String)>.filled(
          kAutoQualityDowngradeStreak,
          ('lossless', 'standard'),
        ),
        ceiling: 'lossless',
        maxCeiling: 'lossless',
      );
      expect(update.ceilingId, 'exhigh');
      expect(update.lowered, isTrue);
    });

    test('免费门槛是参数：换成 higher 时落点跟着变', () {
      final QualityCeilingUpdate update = fold(
        List<(String, String)>.filled(
          kAutoQualityDowngradeStreak,
          ('lossless', 'standard'),
        ),
        ceiling: 'lossless',
        maxCeiling: 'lossless',
        floor: 'higher',
      );
      expect(update.ceilingId, 'higher');
    });

    test('实际高于请求时按实际上抬，但越过不了会员等级上限', () {
      final QualityCeilingUpdate raised = applyQualityObservation(
        currentCeilingId: 'exhigh',
        requestedId: 'exhigh',
        actualId: 'lossless',
        streak: 5,
        maxCeilingId: 'lossless',
      );
      expect(raised.ceilingId, 'lossless');
      expect(raised.streak, 0);

      final QualityCeilingUpdate clamped = applyQualityObservation(
        currentCeilingId: 'exhigh',
        requestedId: 'exhigh',
        actualId: 'hires',
        streak: 0,
        maxCeilingId: 'lossless',
      );
      expect(
        clamped.ceilingId,
        'lossless',
        reason: '一次异常响应不能把自动档抬到账号权益之上',
      );
    });

    test('认不出的档位（例如沉浸声 jyeffect）不参与判断', () {
      final QualityCeilingUpdate update = applyQualityObservation(
        currentCeilingId: 'lossless',
        requestedId: 'lossless',
        actualId: 'jyeffect',
        streak: 4,
        maxCeilingId: 'lossless',
      );
      expect(update.ceilingId, 'lossless');
      expect(update.streak, 4, reason: '既不累计也不清零，当这次没发生过');
      expect(update.lowered, isFalse);
    });
  });

  // ------------------------------------------------------ 仓库：自动档上限

  group('自动档初始值', () {
    test('无记录时等于按会员等级猜的档位：黑胶 VIP → 无损', () async {
      final _Harness harness = await buildHarness(vipLabel: '黑胶VIP');

      expect(harness.repository.autoQualityCeiling.id, 'lossless');
      expect(harness.repository.effectiveQuality.id, 'lossless');

      final ResolvedStream stream = await harness.repository.resolveStream(
        _song,
      );
      expect(harness.client.requestedLevels, <String>['lossless']);
      expect(stream.qualityLabel, '无损');
    });

    test('SVIP 账号 + 无记录 → 最高档 jymaster', () async {
      final _Harness harness = await buildHarness(vipLabel: '黑胶SVIP');

      expect(harness.repository.autoQualityCeiling.id, 'jymaster');
      await harness.repository.resolveStream(_song);
      expect(harness.client.requestedLevels, <String>['jymaster']);
    });

    test('盘上已有记录（模拟重启）时以记录为准', () async {
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶VIP',
        prefs: <String, Object>{_ceilingKey: 'exhigh'},
      );

      expect(harness.repository.autoQualityCeiling.id, 'exhigh');
      expect(harness.repository.effectiveQuality.id, 'exhigh');
      await harness.repository.resolveStream(_song);
      expect(harness.client.requestedLevels, <String>['exhigh']);
    });
  });

  group('自动档降级', () {
    test('连续 8 首只有极高才降级，第 9 首请求的就是极高', () async {
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶VIP',
        actualFor: (String requested) => 'exhigh',
      );

      for (int i = 0; i < 7; i++) {
        await harness.repository.resolveStream(_song);
        expect(
          harness.repository.autoQualityCeiling.id,
          'lossless',
          reason: '第 ${i + 1} 首还不该降级',
        );
      }

      await harness.repository.resolveStream(_song); // 第 8 首
      expect(harness.repository.autoQualityCeiling.id, 'exhigh');
      expect(harness.repository.effectiveQuality.id, 'exhigh');

      await harness.repository.resolveStream(_song); // 第 9 首
      expect(harness.client.requestedLevels.length, 9);
      expect(
        harness.client.requestedLevels.take(8),
        everyElement('lossless'),
      );
      expect(harness.client.requestedLevels.last, 'exhigh');

      // 上限已经落盘：重启后不会又退回无损。
      await harness.repository.qualityStateSettled;
      expect(harness.preferences.getString(_ceilingKey), 'exhigh');
    });

    test('被单曲打断就重新计数：7 次极高 + 1 次无损 + 7 次极高仍不降级', () async {
      int call = 0;
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶VIP',
        actualFor: (String requested) {
          call++;
          // 第 7 首是那种"本来就没有无损"的歌，第 8 首又能拿到无损了。
          return call == 7 ? 'lossless' : 'exhigh';
        },
      );

      for (int i = 0; i < 13; i++) {
        await harness.repository.resolveStream(_song);
      }

      expect(harness.repository.autoQualityCeiling.id, 'lossless');
      expect(harness.repository.effectiveQuality.id, 'lossless');
      // 第 14 首（本轮的连续第 7 次）仍然按无损去请求：计数确实被那次
      // "要到了"打断过，而不是从 0 一路累到 8。
      await harness.repository.resolveStream(_song);
      expect(harness.client.requestedLevels.last, 'lossless');
      expect(harness.repository.autoQualityCeiling.id, 'lossless');
      expect(harness.preferences.getString(_ceilingKey), isNull);
    });

    test('隔一首夹一次"要到了"时永不降级（真实数据的形态）', () async {
      int call = 0;
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶VIP',
        actualFor: (String requested) {
          call++;
          return call.isEven ? 'lossless' : 'exhigh';
        },
      );

      for (int i = 0; i < 20; i++) {
        await harness.repository.resolveStream(_song);
      }
      expect(harness.repository.autoQualityCeiling.id, 'lossless');
    });

    test('降级与观测都写进日志（应用内日志面板抓的就是 debugPrint）', () async {
      final List<String> logs = captureDebugPrint();
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶VIP',
        actualFor: (String requested) => 'exhigh',
      );

      for (int i = 0; i < 3; i++) {
        await harness.repository.resolveStream(_song);
      }
      expect(
        logs,
        contains('[netease] 请求 lossless 实际返回 exhigh（连续第 3 次低于预期）'),
      );
      expect(logs, isNot(contains('[netease] 自动音质上限调整为 极高')));

      for (int i = 3; i < kAutoQualityDowngradeStreak; i++) {
        await harness.repository.resolveStream(_song);
      }
      expect(logs, contains('[netease] 自动音质上限调整为 极高'));
    });

    test('高于免费档的降级不写成"连续第 n 次"（计数与措辞要一致）', () async {
      final List<String> logs = captureDebugPrint();
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶SVIP',
        actualFor: (String requested) => 'hires',
      );

      await harness.repository.resolveStream(_song);

      expect(
        logs,
        contains(
          '[netease] 请求 jymaster 实际返回 hires（低于预期，但仍在免费档以上，不计数）',
        ),
      );
      expect(harness.repository.autoQualityCeiling.id, 'jymaster');
    });
  });

  group('手动档位不受上限影响', () {
    test('上限已降到极高时，手动选无损仍然请求无损', () async {
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶VIP',
        prefs: <String, Object>{_qualityKey: 'lossless', _ceilingKey: 'exhigh'},
        // 服务端依然只给 320k：如实反映在 qualityLabel 上，不去改上限。
        actualFor: (String requested) => 'exhigh',
      );

      expect(harness.repository.preferredQualityId, 'lossless');
      expect(harness.repository.effectiveQuality.id, 'lossless');
      expect(harness.repository.autoQualityCeiling.id, 'exhigh');

      final ResolvedStream stream = await harness.repository.resolveStream(
        _song,
      );
      expect(harness.client.requestedLevels, <String>['lossless']);
      expect(stream.qualityLabel, '极高 320k');
    });

    test('手动档位的降级不会反过来改自动档的上限', () async {
      final _Harness harness = await buildHarness(
        vipLabel: '黑胶VIP',
        prefs: <String, Object>{_qualityKey: 'lossless'},
        actualFor: (String requested) => 'exhigh',
      );

      for (int i = 0; i < kAutoQualityDowngradeStreak + 2; i++) {
        await harness.repository.resolveStream(_song);
      }
      expect(harness.repository.autoQualityCeiling.id, 'lossless');
      expect(harness.preferences.getString(_ceilingKey), isNull);
    });
  });
}

/// 一首最小可播的曲目：测试只关心音质参数，其余字段给它默认值。
const Song _song = Song(
  id: '186016',
  source: MediaSource.netease,
  title: '测试歌曲',
);

/// 一次测试用到的全套对象。
class _Harness {
  _Harness(this.repository, this.client, this.preferences, this.dio);

  final NeteaseRepository repository;
  final _FakeClient client;
  final SharedPreferences preferences;
  final Dio dio;

  void dispose() {
    repository.dispose();
    dio.close(force: true);
  }
}

/// 假客户端：`level` 由 [actualFor] 决定，并记录每次请求的档位。
class _FakeClient extends NeteaseApiClient {
  _FakeClient(Dio dio) : super(EmbeddedNeteaseApi(), dio);

  /// v1 接口请求过的档位，按顺序记录（断言"第 N 次请求了什么"靠它）。
  final List<String> requestedLevels = <String>[];

  /// 请求档位 → 服务端实际回填的档位。默认原样返回（要得到）。
  String Function(String requested) actualFor = (String requested) => requested;

  @override
  Future<Map<String, Object?>> get(
    String path, {
    Map<String, Object?>? query,
    bool raw = false,
    bool bypassCache = false,
    Duration? receiveTimeout,
  }) async {
    if (path == '/song/url/v1') {
      final String requested = '${query?['level']}';
      requestedLevels.add(requested);
      return _songUrlBody(actualFor(requested));
    }
    // /logout、/login/status 等：给个能过的最小响应，本测试不关心它们。
    return <String, Object?>{'code': 200};
  }

  Map<String, Object?> _songUrlBody(String level) => <String, Object?>{
    'code': 200,
    'data': <Map<String, Object?>>[
      <String, Object?>{
        'id': 186016,
        'url': 'https://m701.music.126.net/obj/test-$level.mp3',
        'br': 320000,
        'size': 4096,
        'level': level,
        'type': 'mp3',
        'time': 240000,
      },
    ],
  };
}

/// 捕获本次用例期间的 debugPrint 输出（应用内调试日志面板抓的是同一个通道）。
List<String> captureDebugPrint() {
  final List<String> lines = <String>[];
  final DebugPrintCallback original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  };
  addTearDown(() => debugPrint = original);
  return lines;
}
