import 'package:flutter/foundation.dart';

import '../../data/models/media_source.dart';
import '../../data/models/song.dart';

/// `copyWith` 的哨兵值。
///
/// 可空字段（`totalBytes` / `error` / `filePath` / `finishedAt`）需要区分
/// "不改"和"改成 null"两件事，而 `?? this.x` 区分不了：失败重试时必须能把
/// 上一次的错误文案清掉，否则任务在下一次失败前一直挂着一句过期的报错。
/// 用一个私有常量当默认值就能同时表达这两层意思：传 `null` = 清空，
/// 不传 = 保持原值。
const Object _unset = Object();

/// 下载任务的状态。
///
/// 比"播放器状态机"简单得多，但每个值都必须存在：
/// - [paused] 与 [cancelled] 分开：前者是"我一会儿还要继续"，后者是
///   "这次不要了"。合成一个值会让界面无法决定该显示「继续」还是「重试」；
/// - [failed] 与 [cancelled] 分开：失败要给出原因（403 / 断网），
///   取消不需要解释。
enum DownloadStatus {
  queued('排队中'),
  running('下载中'),
  paused('已暂停'),
  completed('已完成'),
  failed('失败'),
  cancelled('已取消');

  const DownloadStatus(this.label);

  /// 界面上的中文标签。
  final String label;

  /// 是否还占着队列（排队中 / 下载中）。
  bool get isActive => this == queued || this == running;

  /// 是否已经结束（不会自己再动起来，但可以重新入队）。
  bool get isTerminal =>
      this == completed || this == failed || this == cancelled;

  /// 从持久化字符串还原；无法识别时按「排队中」处理。
  ///
  /// 不做成 `DownloadStatus.values.byName`：存档是磁盘上的数据，将来删掉
  /// 某个枚举值时，老存档不应该让整个任务列表读不出来。
  static DownloadStatus fromName(String? name) {
    for (final DownloadStatus status in values) {
      if (status.name == name) return status;
    }
    return DownloadStatus.queued;
  }
}

/// 一个下载任务。
///
/// 它同时是**持久化模型**和**界面渲染的数据**：下载器把它写进
/// `tasks.json`，界面直接读它画任务行。合成一份而不是"存档一份、视图一份"，
/// 是因为两者的字段完全重合，分两份必然有一份会忘记同步。
///
/// 刻意做成不可变值对象（`@immutable`）：下载器每推进一步就产出一个**新的**
/// 快照并通过 `changes` 推给界面。可变对象在 `setState` 之外被悄悄改掉时
/// 界面根本不会刷新，是最难查的一类 bug。
@immutable
class DownloadTask {
  const DownloadTask({
    required this.song,
    required this.createdAt,
    this.status = DownloadStatus.queued,
    this.receivedBytes = 0,
    this.totalBytes,
    this.error,
    this.filePath,
    this.finishedAt,
  });

  /// 任务对应的曲目。[uid] 就是任务身份，跨音源唯一。
  final Song song;

  final DownloadStatus status;

  /// 已经落盘的字节数。重启后以**磁盘文件的真实长度**为准（见下载器）。
  final int receivedBytes;

  /// 总字节数；服务端没给 `Content-Length` 时为 null。
  final int? totalBytes;

  /// 失败原因（中文），仅 [DownloadStatus.failed] 时非空。
  final String? error;

  /// 目标文件路径。**在第一次开始写之前就确定**，断点续传靠它找回半成品。
  final String? filePath;

  final DateTime createdAt;

  /// 进入终态的时间（完成 / 失败 / 取消 / 暂停），用于"3 分钟前"这类展示。
  final DateTime? finishedAt;

  /// 任务身份：曲目的跨音源唯一键。
  String get uid => song.uid;

  /// 进度 0~1。
  ///
  /// 总大小未知时**返回 0 而不是猜一个数** —— 界面据此显示"大小未知"，
  /// 是不是"已经开始了"由 [hasStarted] 回答。凭空编一个分母，
  /// 用户会看到一条永远走不到头的进度条。
  double get progress {
    final int? total = totalBytes;
    if (total == null || total <= 0) return 0;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  /// 是否已经收到过数据（总大小未知时，用它表达"已经开始了"）。
  bool get hasStarted => receivedBytes > 0;

  int get percent => (progress * 100).round();

  DownloadTask copyWith({
    Song? song,
    DownloadStatus? status,
    int? receivedBytes,
    Object? totalBytes = _unset,
    Object? error = _unset,
    Object? filePath = _unset,
    DateTime? createdAt,
    Object? finishedAt = _unset,
  }) {
    return DownloadTask(
      song: song ?? this.song,
      status: status ?? this.status,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: identical(totalBytes, _unset)
          ? this.totalBytes
          : totalBytes as int?,
      error: identical(error, _unset) ? this.error : error as String?,
      filePath: identical(filePath, _unset)
          ? this.filePath
          : filePath as String?,
      createdAt: createdAt ?? this.createdAt,
      finishedAt: identical(finishedAt, _unset)
          ? this.finishedAt
          : finishedAt as DateTime?,
    );
  }

  /// 写成 JSON。
  ///
  /// 全部内容都是**恢复所必需的最小集合**：曲目身份、状态、进度、目标文件。
  /// 直链、请求头、音质这些一律不存 —— 它们带时效签名，存下来只会变成
  /// 一个下次启动必然不可用的脏数据。
  Map<String, Object?> toJson() => <String, Object?>{
    'song': _songToJson(song),
    'status': status.name,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'error': error,
    'filePath': filePath,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
  };

  /// 从存档还原。缺曲目身份（id / title）时抛 [FormatException]，
  /// 由调用方决定"跳过这一条"还是"放弃整个存档"。
  factory DownloadTask.fromJson(Map<String, Object?> json) {
    final Song? song = _songFromJson(json['song']);
    if (song == null) {
      throw const FormatException('下载任务记录里没有可识别的曲目信息');
    }
    return DownloadTask(
      song: song,
      status: DownloadStatus.fromName(_asString(json['status'])),
      receivedBytes: _asInt(json['receivedBytes']) ?? 0,
      totalBytes: _asInt(json['totalBytes']),
      error: _asString(json['error']),
      filePath: _asString(json['filePath']),
      createdAt: _asDate(json['createdAt']) ?? DateTime.now(),
      finishedAt: _asDate(json['finishedAt']),
    );
  }

  @override
  String toString() =>
      'DownloadTask($uid, ${status.name}, $receivedBytes/$totalBytes)';
}

// ---------------------------------------------------------------------------
// 曲目序列化
// ---------------------------------------------------------------------------

/// 把一个 [Song] 压成 JSON。
///
/// **只保证恢复展示与重新解析地址所需的最小字段**：
/// `id` / `source` / `title` / `artists` / `album` / `coverUrl` /
/// `duration`(毫秒) / `playable` / `extra`。
///
/// 为什么不多存一点：`albumId`、`unplayableReason` 之类的东西在恢复后都能
/// 重新拉到，存下来只会让存档跟着音源接口一起腐烂 —— 一旦某个平台把字段
/// 换了名字，老存档就再也读不出来了。而下载任务真正需要的是"能重新解析出
/// 播放地址"（`id` + `source`）和"断网时也能认出这是哪首歌"
/// （`title` + `artists` + `coverUrl`）。
Map<String, Object?> _songToJson(Song song) => <String, Object?>{
  'id': song.id,
  'source': song.source.key,
  'title': song.title,
  'artists': song.artists,
  'album': song.album,
  'coverUrl': song.coverUrl,
  'duration': song.duration?.inMilliseconds,
  'playable': song.playable,
  'extra': _jsonSafe(song.extra),
};

Song? _songFromJson(Object? value) {
  if (value is! Map) return null;
  final String id = _asString(value['id']) ?? '';
  final String title = _asString(value['title']) ?? '';
  if (id.isEmpty || title.isEmpty) return null;

  final int? milliseconds = _asInt(value['duration']);
  return Song(
    id: id,
    source: MediaSource.fromKey(_asString(value['source'])),
    title: title,
    artists: _asStringList(value['artists']),
    album: _asString(value['album']),
    coverUrl: _asString(value['coverUrl']),
    duration: milliseconds == null
        ? null
        : Duration(milliseconds: milliseconds),
    // 缺字段时按可播放处理：断言"不能播"会让用户连试都试不了。
    playable: value['playable'] != false,
    extra: _asStringKeyedMap(value['extra']),
  );
}

/// 只保留能被 `jsonEncode` 写出来的值。
///
/// `extra` 是各音源自己塞的私有字段，类型不受这里控制。里面一旦出现
/// DateTime、Duration 或自定义对象，**整份存档都会写不出去**。宁可丢一个
/// 字段，也不能让整个任务列表存不下来。
Object? _jsonSafe(Object? value) {
  if (value == null || value is bool || value is String) return value;
  if (value is int) return value;
  if (value is double) return value.isFinite ? value : null;
  if (value is num) return value;
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': _jsonSafe(entry.value),
    };
  }
  if (value is Iterable) {
    return <Object?>[for (final Object? item in value) _jsonSafe(item)];
  }
  return null;
}

// ---------------------------------------------------------------------------
// 解析小工具
//
// 存档是磁盘上的 JSON，可能是上个版本写的，也可能被用户手改过。
// 下面每个取值都按"类型不对就是没有"处理，绝不 `as` 强转 —— 一个类型错误
// 不该让整个下载列表消失。
// ---------------------------------------------------------------------------

String? _asString(Object? value) => value is String ? value : null;

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _asDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

List<String> _asStringList(Object? value) {
  if (value is! Iterable) return const <String>[];
  return <String>[
    for (final Object? item in value)
      if (item != null) '$item',
  ];
}

Map<String, Object?> _asStringKeyedMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return <String, Object?>{
    for (final MapEntry<Object?, Object?> entry in value.entries)
      '${entry.key}': entry.value,
  };
}
