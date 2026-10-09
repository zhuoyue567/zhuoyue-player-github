import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoyue_player/core/theme/app_theme.dart';
import 'package:zhuoyue_player/core/theme/theme_settings.dart';
import 'package:zhuoyue_player/core/theme/window_material.dart';
import 'package:zhuoyue_player/core/ui/song_list.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/features/player/player_controller.dart';

/// 记录 `playSong` / `togglePlayPause` 的调用，不碰任何音频引擎。
///
/// 覆盖 `build()` 是必须的：真实 `build()` 会去建引擎、读偏好，
/// 测试里既不必要也会失败。
class _RecordingController extends PlayerController {
  final List<String> played = <String>[];
  int toggles = 0;

  @override
  PlayerUiState build() => const PlayerUiState();

  @override
  Future<void> playSong(Song song, {List<Song>? context}) async {
    played.add(song.uid);
  }

  @override
  Future<void> togglePlayPause() async {
    toggles++;
  }
}

Song _song(int id, {MediaSource source = MediaSource.netease}) => Song(
  id: '$id',
  source: source,
  title: '歌曲 $id',
  duration: const Duration(minutes: 3),
);

/// 挂载一个歌曲列表。
///
/// `currentSongProvider` / `isPlayingProvider` 都是普通 `Provider`，
/// 直接覆盖成固定值即可 —— 不需要真的搭一套音频引擎。
Future<void> _pumpList(
  WidgetTester tester,
  List<Song> songs, {
  void Function(Song song)? onDownload,
  void Function(int index)? onRemove,
  _RecordingController? controller,
}) async {
  const ZhyThemeSettings settings = ZhyThemeSettings(
    material: ZhyWindowMaterial.solid,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentSongProvider.overrideWithValue(null),
        isPlayingProvider.overrideWithValue(false),
        if (controller != null)
          playerControllerProvider.overrideWith(() => controller),
      ],
      child: MaterialApp(
        theme: buildZhyTheme(
          scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
          tokens: buildZhyTokens(settings, Brightness.light),
          material: settings.material,
        ),
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: SongListView(
              songs: songs,
              onDownload: onDownload,
              onRemove: onRemove,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('行尾只留一个「…」，播放/下一首/加入队列/下载都不再占位', (WidgetTester tester) async {
    await _pumpList(tester, <Song>[_song(1), _song(2), _song(3)]);

    // 每行一个「…」。
    expect(find.byIcon(Icons.more_horiz_rounded), findsNWidgets(3));
    expect(find.byType(PopupMenuButton<String>), findsNWidgets(3));

    // 那排内联图标必须消失 —— 这正是本次改动的重点：它们把标题挤成了省略号。
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
    expect(find.byIcon(Icons.queue_music_rounded), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
  });

  testWidgets('序号照常显示（没有悬停时不是播放按钮）', (WidgetTester tester) async {
    await _pumpList(tester, <Song>[_song(1), _song(2)]);

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  testWidgets('鼠标移到序号上时变成播放按钮', (WidgetTester tester) async {
    await _pumpList(tester, <Song>[_song(1), _song(2)]);

    // 用真实指针制造 hover：`_hovered` 是靠 MouseRegion 的 onEnter 驱动的，
    // 直接调 setState 就测不到"鼠标移上去"这件事本身。
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await gesture.moveTo(tester.getCenter(find.text('1')));
    await tester.pumpAndSettle();

    // 第一行变成播放按钮，序号让位。
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('1'), findsNothing);
    // 其它行不受影响。
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('单击一行就直接播放这首歌（不需要先选中、也不必去播放栏再按播放）', (
    WidgetTester tester,
  ) async {
    // 这是用户报的"点击歌单里的歌不会自动开始播放"的回归测试。
    // 以前单击只切换"选中"态，播放要双击或点行首悬浮出来的播放键。
    final _RecordingController controller = _RecordingController();
    await _pumpList(
      tester,
      <Song>[_song(1), _song(2)],
      controller: controller,
    );

    await tester.tap(find.text('歌曲 2'));
    await tester.pumpAndSettle();

    expect(controller.played, <String>['netease:2']);
    expect(controller.toggles, 0, reason: '单击不该变成暂停开关');
  });

  testWidgets('不可播放的行：单击只解释原因，不发播放请求', (WidgetTester tester) async {
    final _RecordingController controller = _RecordingController();
    final Song blocked = Song(
      id: '9',
      source: MediaSource.netease,
      title: '下架的歌',
      playable: false,
      unplayableReason: '版权下架',
    );
    await _pumpList(tester, <Song>[blocked], controller: controller);

    await tester.tap(find.text('下架的歌'));
    await tester.pumpAndSettle();

    expect(controller.played, isEmpty);
  });

  testWidgets('行尾「…」的点击不会被整行的单击播放抢走', (WidgetTester tester) async {
    // 之前整行是 opaque + onDoubleTap 的识别器，点「…」会被行本身赢走。
    final _RecordingController controller = _RecordingController();
    await _pumpList(tester, <Song>[_song(1)], controller: controller);

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('加入队列'), findsOneWidget, reason: '菜单必须真的打开');
    expect(controller.played, isEmpty, reason: '点菜单不等于点播放');
  });

  testWidgets('「…」菜单里保留了完整动作（下载/加入队列/移除）', (WidgetTester tester) async {
    await _pumpList(
      tester,
      <Song>[_song(1)],
      onDownload: (Song _) {},
      onRemove: (int _) {},
    );

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();

    // 摘掉内联按钮的前提是菜单里真的都有 —— 否则就是功能丢失。
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('下一首播放'), findsOneWidget);
    expect(find.text('加入队列'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('从队列移除'), findsOneWidget);
  });

  testWidgets('不可播放的曲目：菜单里的播放与下载都置灰', (WidgetTester tester) async {
    final Song blocked = Song(
      id: '9',
      source: MediaSource.netease,
      title: '下架的歌',
      playable: false,
      unplayableReason: '版权下架',
    );
    await _pumpList(tester, <Song>[blocked], onDownload: (Song _) {});

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();

    // 置灰而不是隐藏：菜单项还在，用户能看出"这首不行"。
    expect(_menuItemEnabled(tester, '下载'), isFalse);
    expect(_menuItemEnabled(tester, '播放'), isFalse);
    // 「加入队列」与播放能力无关，仍然可用。
    expect(_menuItemEnabled(tester, '加入队列'), isTrue);
  });
}

/// 取出某个菜单项的 `enabled`。
bool? _menuItemEnabled(WidgetTester tester, String label) {
  final PopupMenuItem<String> item = tester.widget<PopupMenuItem<String>>(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(PopupMenuItem<String>),
    ),
  );
  return item.enabled;
}
