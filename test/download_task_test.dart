import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/download/download_task.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';

/// 下载任务的持久化与进度语义测试。
///
/// 全部离线：这里验的是"写进磁盘的东西能不能原样读回来"，一旦有字段在中途
/// 丢掉，表现是重启后下载列表少了几条、或者断点续传从一个错误的位置开始 ——
/// 这两类问题都不会抛异常，只会在用户那里悄悄发生。
void main() {
  const Song song = Song(
    id: '186016',
    source: MediaSource.netease,
    title: '晴天',
    artists: <String>['周杰伦'],
    album: '叶惠美',
    coverUrl: 'https://img.example/cover.jpg',
    duration: Duration(minutes: 4, seconds: 29),
    playable: true,
    extra: <String, Object?>{
      'fee': 8,
      'level': 'lossless',
      'nested': <Object?>[1, 'a'],
    },
  );

  group('DownloadTask 序列化', () {
    test('toJson / fromJson 往返后每一个字段都不丢', () {
      final DateTime createdAt = DateTime(2026, 3, 1, 10, 30);
      final DateTime finishedAt = DateTime(2026, 3, 1, 10, 35);
      final DownloadTask task = DownloadTask(
        song: song,
        status: DownloadStatus.completed,
        receivedBytes: 4194304,
        totalBytes: 4194304,
        error: null,
        filePath: r'E:\Music\ZhuoYuePlayer\网易云音乐\周杰伦 - 晴天.mp3',
        createdAt: createdAt,
        finishedAt: finishedAt,
      );

      // 走一遍真正的 JSON 编解码，而不是只调 fromJson(toJson())：
      // 后者会让一个"塞了不可序列化对象"的字段蒙混过关。
      final String encoded = jsonEncode(task.toJson());
      final DownloadTask restored = DownloadTask.fromJson(
        jsonDecode(encoded) as Map<String, Object?>,
      );

      expect(restored.song.uid, song.uid);
      expect(restored.song.id, song.id);
      expect(restored.song.source, MediaSource.netease);
      expect(restored.song.title, song.title);
      expect(restored.song.artists, song.artists);
      expect(restored.song.album, song.album);
      expect(restored.song.coverUrl, song.coverUrl);
      expect(restored.song.duration, song.duration);
      expect(restored.song.playable, isTrue);
      expect(restored.song.extra, song.extra);

      expect(restored.status, DownloadStatus.completed);
      expect(restored.receivedBytes, 4194304);
      expect(restored.totalBytes, 4194304);
      expect(restored.filePath, task.filePath);
      expect(restored.createdAt, createdAt);
      expect(restored.finishedAt, finishedAt);
      expect(restored.error, isNull);
    });

    test('失败原因与暂停状态也能往返', () {
      final DownloadTask task = DownloadTask(
        song: song,
        status: DownloadStatus.failed,
        receivedBytes: 1024,
        error: '音源拒绝了下载请求（403）',
        createdAt: DateTime(2026, 3, 2),
      );
      final DownloadTask restored = DownloadTask.fromJson(
        jsonDecode(jsonEncode(task.toJson())) as Map<String, Object?>,
      );

      expect(restored.status, DownloadStatus.failed);
      expect(restored.error, '音源拒绝了下载请求（403）');
      expect(restored.totalBytes, isNull);
      expect(restored.finishedAt, isNull);
    });

    test('缺曲目信息 / 状态名不认识时按可恢复的方式降级', () {
      expect(
        () => DownloadTask.fromJson(const <String, Object?>{
          'status': 'running',
          'receivedBytes': 10,
        }),
        throwsA(isA<FormatException>()),
      );

      final DownloadTask unknown = DownloadTask.fromJson(<String, Object?>{
        'song': song.toJsonForTest(),
        'status': '某个将来才会有的状态',
        'createdAt': '2026-03-03T00:00:00.000',
      });
      // 老版本/新版本互相读写存档时，不认识的枚举值必须落回一个安全值，
      // 而不是让整份列表读不出来。
      expect(unknown.status, DownloadStatus.queued);
      expect(unknown.receivedBytes, 0);
    });
  });

  group('DownloadTask 进度', () {
    test('总大小未知时返回 0，并用 hasStarted 表达"已开始"', () {
      final DownloadTask task = DownloadTask(
        song: song,
        status: DownloadStatus.running,
        receivedBytes: 512 * 1024,
        createdAt: DateTime(2026, 3, 1),
      );

      // 编一个分母出来会让进度条永远走不到头，所以这里必须是 0。
      expect(task.progress, 0);
      expect(task.percent, 0);
      expect(task.totalBytes, isNull);
      expect(task.hasStarted, isTrue);
    });

    test('总大小已知时是比例，且被夹在 0~1', () {
      final DownloadTask half = DownloadTask(
        song: song,
        receivedBytes: 50,
        totalBytes: 100,
        createdAt: DateTime(2026, 3, 1),
      );
      expect(half.progress, 0.5);
      expect(half.percent, 50);

      final DownloadTask over = DownloadTask(
        song: song,
        receivedBytes: 120,
        totalBytes: 100,
        createdAt: DateTime(2026, 3, 1),
      );
      // 服务端报的 Content-Length 偶尔偏小，别让进度条冲出轨道。
      expect(over.progress, 1.0);
      expect(over.percent, 100);
    });

    test('copyWith 能把可空字段显式清成 null', () {
      final DownloadTask task = DownloadTask(
        song: song,
        status: DownloadStatus.failed,
        error: '旧的错误',
        totalBytes: 100,
        filePath: r'C:\tmp\a.mp3',
        createdAt: DateTime(2026, 3, 1),
      );
      final DownloadTask cleared = task.copyWith(
        status: DownloadStatus.queued,
        error: null,
        filePath: null,
      );

      // `?? this.error` 那种写法清不掉旧错误，于是"重试"之后界面上
      // 还挂着上一轮的报错 —— 这里把这条约定钉死。
      expect(cleared.error, isNull);
      expect(cleared.filePath, isNull);
      expect(cleared.status, DownloadStatus.queued);
      expect(cleared.totalBytes, 100);
      // 不传的字段保持原值。
      expect(task.copyWith(receivedBytes: 7).error, '旧的错误');
    });
  });

  group('Song 序列化', () {
    test('关键字段不丢，且不含不可序列化的东西', () {
      final Map<String, Object?> json =
          jsonDecode(jsonEncode(_roundTripSong(song))) as Map<String, Object?>;

      expect(json['id'], '186016');
      expect(json['source'], 'netease');
      expect(json['title'], '晴天');
      expect(json['artists'], <String>['周杰伦']);
      expect(json['album'], '叶惠美');
      expect(json['coverUrl'], 'https://img.example/cover.jpg');
      // 时长按毫秒存：`Duration` 本身不是 JSON 类型，必须先换算。
      expect(json['duration'], 269000);
      expect(json['playable'], isTrue);
      expect(json['extra'], song.extra);
    });

    test('网易云与哔哩的 uid 都能原样恢复（跨源身份不能串）', () {
      const Song bilibili = Song(
        id: 'BV1xx411c7mD',
        source: MediaSource.bilibili,
        title: '某视频',
        artists: <String>['UP主'],
        extra: <String, Object?>{'cid': 12345, 'page': null},
      );
      final DownloadTask task = DownloadTask(
        song: bilibili,
        createdAt: DateTime(2026, 3, 4),
      );
      final DownloadTask restored = DownloadTask.fromJson(
        jsonDecode(jsonEncode(task.toJson())) as Map<String, Object?>,
      );

      expect(restored.uid, 'bilibili:BV1xx411c7mD');
      expect(restored.song.source, MediaSource.bilibili);
      // `extra` 是"重新解析地址"的依据（cid / page 都在里面），不能丢。
      expect(restored.song.extra['cid'], 12345);
      expect(restored.song.extra['page'], isNull);
    });
  });
}

/// 把 [Song] 过一次 JSON：借助 [DownloadTask] 这条真实链路，
/// 免得测试自己再实现一遍序列化、结果两边都错还对得上。
Map<String, Object?> _roundTripSong(Song song) {
  final DownloadTask task = DownloadTask(
    song: song,
    createdAt: DateTime(2026, 3, 1),
  );
  final Map<String, Object?> json = task.toJson();
  return json['song']! as Map<String, Object?>;
}

/// 测试里构造"最小可识别曲目 JSON"用的快捷方式。
extension on Song {
  Map<String, Object?> toJsonForTest() => _roundTripSong(this);
}
