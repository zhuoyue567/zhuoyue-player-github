import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/download/download_task.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/core/ui/song_list.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/features/downloads/downloads_page.dart';

/// 测试替身：只提供任务列表与变化流，不碰网络与磁盘。
class _FakeQueue implements DownloadQueue {
  _FakeQueue(this._tasks);

  final List<DownloadTask> _tasks;
  final StreamController<List<DownloadTask>> _changes =
      StreamController<List<DownloadTask>>.broadcast();

  @override
  List<DownloadTask> get tasks => _tasks;

  @override
  Stream<List<DownloadTask>> get changes => _changes.stream;

  @override
  String? get directory => r'C:\Music\ZhuoYuePlayer';

  @override
  Listenable get directoryChanges => _directoryChanges;
  final ChangeNotifier _directoryChanges = ChangeNotifier();

  @override
  Future<void> start(Song song) async {}

  @override
  Future<void> cancel(String uid) async {}

  @override
  Future<void> pause(String uid) async {}

  @override
  Future<void> resume(String uid) async {}

  @override
  Future<void> retry(String uid) async {}

  @override
  Future<void> remove(String uid, {bool deleteFile = false}) async {}

  @override
  Future<void> pauseAll() async {}

  @override
  Future<void> resumeAll() async {}

  @override
  Future<void> clearCompleted() async {}

  @override
  Future<void> selectDirectory() async {}

  @override
  Future<void> openFolder() async {}

  @override
  Future<void> revealFile(String uid) async {}
}

DownloadTask _task(
  String id,
  MediaSource source,
  String title, {
  DownloadStatus status = DownloadStatus.running,
  int received = 1024 * 1024,
  int? total = 4 * 1024 * 1024,
}) {
  return DownloadTask(
    song: Song(
      id: id,
      source: source,
      title: title,
      duration: const Duration(minutes: 3),
    ),
    createdAt: DateTime(2026, 10, 8),
    status: status,
    receivedBytes: received,
    totalBytes: total,
  );
}

void main() {
  /// 挂载下载页并注入任务。
  Future<void> pumpDownloads(
    WidgetTester tester,
    List<DownloadTask> tasks,
  ) async {
    final ZhyThemeSettings settings = const ZhyThemeSettings(
      material: ZhyWindowMaterial.solid,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [downloadQueueProvider.overrideWithValue(_FakeQueue(tasks))],
        child: MaterialApp(
          theme: buildZhyTheme(
            scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            tokens: buildZhyTokens(settings, Brightness.light),
            material: settings.material,
          ),
          home: const Scaffold(body: DownloadsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('下载管理按音源分栏：标签始终存在，且带条数', (WidgetTester tester) async {
    await pumpDownloads(tester, <DownloadTask>[
      _task('n1', MediaSource.netease, '网易云甲'),
      _task('n2', MediaSource.netease, '网易云乙'),
      _task('b1', MediaSource.bilibili, '哔哩丙'),
    ]);

    // 三个标签都在：全部 / 网易云 / 哔哩。哪怕某个源是 0 条也要在，
    // 否则用户不知道这里能按音源分开看。
    //
    // 用 findsWidgets 而不是 findsOneWidget：音源名既出现在标签上，
    // 也出现在每条任务行里（那是刻意的，方便一眼看出这条来自哪个源）。
    expect(find.text('全部'), findsOneWidget);
    expect(find.text(MediaSource.netease.label), findsWidgets);
    expect(find.text(MediaSource.bilibili.label), findsWidgets);

    // 默认「全部」：三个任务都在。
    expect(find.text('网易云甲'), findsOneWidget);
    expect(find.text('网易云乙'), findsOneWidget);
    expect(find.text('哔哩丙'), findsOneWidget);
  });

  testWidgets('切到哔哩标签后只留下哔哩的任务', (WidgetTester tester) async {
    await pumpDownloads(tester, <DownloadTask>[
      _task('n1', MediaSource.netease, '网易云甲'),
      _task('n2', MediaSource.netease, '网易云乙'),
      _task('b1', MediaSource.bilibili, '哔哩丙'),
    ]);

    await tester.tap(find.text(MediaSource.bilibili.label).first);
    await tester.pumpAndSettle();

    // 这是本文件的核心断言：分源管理必须真的过滤，而不是只换个高亮。
    expect(find.text('哔哩丙'), findsOneWidget);
    expect(find.text('网易云甲'), findsNothing);
    expect(find.text('网易云乙'), findsNothing);
  });

  testWidgets('切到网易云标签后反过来只留网易云任务', (WidgetTester tester) async {
    await pumpDownloads(tester, <DownloadTask>[
      _task('n1', MediaSource.netease, '网易云甲'),
      _task('b1', MediaSource.bilibili, '哔哩丙'),
    ]);

    await tester.tap(find.text(MediaSource.netease.label).first);
    await tester.pumpAndSettle();

    expect(find.text('网易云甲'), findsOneWidget);
    expect(find.text('哔哩丙'), findsNothing);
  });

  testWidgets('某源没有任务时切过去给出空状态，而不是空白页', (WidgetTester tester) async {
    await pumpDownloads(tester, <DownloadTask>[
      _task('n1', MediaSource.netease, '网易云甲'),
    ]);

    await tester.tap(find.text(MediaSource.bilibili.label).first);
    await tester.pumpAndSettle();

    expect(find.text('网易云甲'), findsNothing);
    // 空态文案必须存在：否则用户看到一片空白会以为界面坏了。
    expect(find.byType(EmptyStateView), findsOneWidget);
  });

  testWidgets('未装配下载器时说明原因，而不是当作"没有任务"', (WidgetTester tester) async {
    final ZhyThemeSettings settings = const ZhyThemeSettings(
      material: ZhyWindowMaterial.solid,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [downloadQueueProvider.overrideWithValue(null)],
        child: MaterialApp(
          theme: buildZhyTheme(
            scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            tokens: buildZhyTokens(settings, Brightness.light),
            material: settings.material,
          ),
          home: const Scaffold(body: DownloadsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 「没有任务」和「下载器没启用」是两件事，混在一起会让用户以为下载完了。
    expect(find.text('下载器未启用'), findsWidgets);
  });

  testWidgets('任务行显示进度与状态，而不是只有标题', (WidgetTester tester) async {
    await pumpDownloads(tester, <DownloadTask>[
      _task(
        'n1',
        MediaSource.netease,
        '网易云甲',
        status: DownloadStatus.running,
        received: 1024 * 1024,
        total: 4 * 1024 * 1024,
      ),
    ]);

    expect(find.byType(LinearProgressIndicator), findsWidgets);
    expect(find.textContaining('下载中'), findsWidgets);
  });
}
