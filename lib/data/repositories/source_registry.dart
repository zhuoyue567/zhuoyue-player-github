import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bilibili/bilibili_repository.dart';
import '../models/media_source.dart';
import '../netease/netease_repository.dart';
import 'music_repository.dart';

/// 全部音源的注册表。
///
/// 播放器拿到一首歌时只知道它的 [MediaSource]，靠这里路由到具体实现。
/// 用注册表而不是在播放器里写 `switch (source)`：新增一个音源
/// 只需要在这里多注册一项，播放链路一行都不用改。
class _DefaultSourceRegistry implements MusicSourceRegistry {
  _DefaultSourceRegistry(this._repositories);

  final List<MusicRepository> _repositories;

  @override
  List<MusicRepository> get all =>
      List<MusicRepository>.unmodifiable(_repositories);

  @override
  MusicRepository? bySource(MediaSource source) {
    for (final MusicRepository repository in _repositories) {
      if (repository.source == source) return repository;
    }
    return null;
  }
}

final Provider<MusicSourceRegistry> sourceRegistryProvider =
    Provider<MusicSourceRegistry>((Ref ref) {
      return _DefaultSourceRegistry(<MusicRepository>[
        ref.watch(neteaseRepositoryProvider),
        ref.watch(bilibiliRepositoryProvider),
      ]);
    });

/// 便捷取用某一个音源。
MusicRepository? repositoryFor(Ref ref, MediaSource source) =>
    ref.read(sourceRegistryProvider).bySource(source);

/// 便捷取用某一个音源（Widget 版本）。
MusicRepository? repositoryForWidget(WidgetRef ref, MediaSource source) =>
    ref.read(sourceRegistryProvider).bySource(source);
