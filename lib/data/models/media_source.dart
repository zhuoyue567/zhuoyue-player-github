/// 曲目的来源。
///
/// 队列、播放器、下载器都只认这个枚举，不关心背后是哪家接口。
/// 新增一个音源（本地文件、其他平台）只需要加一个枚举值 + 一个
/// `MusicRepository` 实现，播放链路完全不用动。
enum MediaSource {
  /// 网易云音乐，经内嵌的 Node 服务访问。
  netease('网易云音乐', 'netease'),

  /// 哔哩哔哩收藏（视频稿件 / 音频区），Dart 端直连接口。
  bilibili('哔哩哔哩', 'bilibili'),

  /// 本地文件或已下载到本地的曲目。
  local('本地', 'local');

  const MediaSource(this.label, this.key);

  /// 界面上展示的名称。
  final String label;

  /// 持久化用的稳定标识（不依赖 enum 名字，重命名常量也不会破坏存档）。
  final String key;

  static MediaSource fromKey(String? key) {
    for (final MediaSource s in values) {
      if (s.key == key) return s;
    }
    return MediaSource.local;
  }
}
