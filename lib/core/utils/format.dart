/// 格式化工具集合。
///
/// 单独放一个文件是为了让 UI 组件不必互相 import：播放条、歌单行、
/// 下载页都需要「时长 / 字节数 / 播放量」这几种格式化。
class ZhyFormat {
  const ZhyFormat._();

  /// `m:ss`，超过一小时则为 `h:mm:ss`；null 或负数返回 `--:--`。
  static String duration(Duration? value) {
    if (value == null || value < Duration.zero) return '--:--';
    final int totalSeconds = value.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// 字节数，二进制单位。
  static String bytes(int? value) {
    if (value == null || value <= 0) return '0 B';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    double size = value.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final String text = size >= 100 || unit == 0
        ? size.toStringAsFixed(0)
        : size.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }

  /// 播放量等大数字，用中文习惯的「万 / 亿」。
  static String count(int? value) {
    if (value == null || value <= 0) return '0';
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return '$value';
  }

  /// 相对时间，例如「3 分钟前」。
  static String relativeTime(DateTime time, {DateTime? now}) {
    final Duration delta = (now ?? DateTime.now()).difference(time);
    if (delta.inSeconds < 60) return '刚刚';
    if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
    if (delta.inHours < 24) return '${delta.inHours} 小时前';
    if (delta.inDays < 30) return '${delta.inDays} 天前';
    if (delta.inDays < 365) return '${delta.inDays ~/ 30} 个月前';
    return '${delta.inDays ~/ 365} 年前';
  }
}
