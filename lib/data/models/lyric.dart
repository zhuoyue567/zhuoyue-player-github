import 'package:flutter/foundation.dart';

/// 一行歌词。
@immutable
class LyricLine {
  const LyricLine({required this.start, this.end, required this.text});

  /// 该行开始时间。
  final Duration start;

  /// 该行结束时间；LRC 里通常没有，由解析器按下一行的时间补出来。
  final Duration? end;

  final String text;

  bool get isMetadata => text.trim().isEmpty;

  @override
  String toString() => '[${start.inMilliseconds}] $text';
}

/// 一首歌的歌词。
///
/// [lines] 按时间升序；[offset] 是 LRC 头部的整体偏移（毫秒），
/// 已经应用到每行的 [LyricLine.start] 上，这里保留原值只是便于排查。
@immutable
class Lyric {
  const Lyric({
    required this.lines,
    this.translatedLines = const <LyricLine>[],
    this.romanizedLines = const <LyricLine>[],
    this.offset = Duration.zero,
    this.isPureMusic = false,
  });

  const Lyric.empty()
    : lines = const <LyricLine>[],
      translatedLines = const <LyricLine>[],
      romanizedLines = const <LyricLine>[],
      offset = Duration.zero,
      isPureMusic = false;

  final List<LyricLine> lines;

  /// 翻译歌词，与 [lines] 按时间对齐（可能为空）。
  final List<LyricLine> translatedLines;

  /// 罗马音 / 音译歌词。
  final List<LyricLine> romanizedLines;

  final Duration offset;

  /// 纯音乐 / 无歌词。
  final bool isPureMusic;

  bool get isEmpty => lines.isEmpty;

  /// 二分查找当前时间应该高亮哪一行；返回 -1 表示还没到第一行。
  ///
  /// 用二分而不是线性扫描：歌词滚动会被挂到每一帧的回调上，
  /// 线性扫描在几百行的歌词上是实打实的每帧开销。
  int indexAt(Duration position) {
    if (lines.isEmpty) return -1;
    final int target = position.inMilliseconds;
    if (target < lines.first.start.inMilliseconds) return -1;

    int low = 0;
    int high = lines.length - 1;
    int result = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (lines[mid].start.inMilliseconds <= target) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  /// 与 [lines] 时间最接近的翻译行。
  LyricLine? translationAt(int index) {
    if (index < 0 || index >= lines.length || translatedLines.isEmpty) {
      return null;
    }
    final Duration target = lines[index].start;
    LyricLine? best;
    Duration bestDelta = const Duration(seconds: 1);
    for (final LyricLine line in translatedLines) {
      final Duration delta = (line.start - target).abs();
      if (delta <= bestDelta) {
        bestDelta = delta;
        best = line;
      }
    }
    return best;
  }
}
