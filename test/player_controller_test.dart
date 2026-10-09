import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuoyue_player/core/audio/audio_engine.dart';
import 'package:zhuoyue_player/core/storage/preferences.dart';
import 'package:zhuoyue_player/data/models/media_source.dart';
import 'package:zhuoyue_player/data/models/song.dart';
import 'package:zhuoyue_player/data/repositories/music_repository.dart';
import 'package:zhuoyue_player/data/repositories/source_registry.dart';
import 'package:zhuoyue_player/features/player/player_controller.dart';

/// 假的播放引擎：只记录 `setVolume` 的调用序列，用来验证渐变确实发生了。
class _FakeEngine implements AudioEngine {
  final List<double> volumes = <double>[];
  final StreamController<bool> _playing = StreamController<bool>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();

  bool _isPlaying = false;
  Duration _duration = const Duration(minutes: 3);

  /// 测试里手动推播放位置，用来验证"临近曲尾渐弱"。
  void emitPosition(Duration position) {
    if (!_position.isClosed) _position.add(position);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream =>
      Stream<Duration?>.value(_duration).asBroadcastStream();

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  final Stream<bool> bufferingStream = const Stream<bool>.empty();

  @override
  final Stream<Object> errorStream = const Stream<Object>.empty();

  final StreamController<void> _completion =
      StreamController<void>.broadcast();

  /// 手动触发一次"播放完成"。真实引擎在**正常播完**与**音源被换掉**时
  /// 都会发这个事件，这正是本轮要区分的那两种情形。
  void emitCompletion() {
    if (!_completion.isClosed) _completion.add(null);
  }

  /// 让下一次 `load` 挂住，直到 [releaseLoad] 被调用。
  Completer<void>? _gate;
  Completer<void>? get loadGate => _gate;
  void holdNextLoad() => _gate = Completer<void>();
  void releaseLoad() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Stream<void> get completionStream => _completion.stream;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => _duration;

  @override
  bool get playing => _isPlaying;

  @override
  double get volume => volumes.isEmpty ? 1 : volumes.last;

  @override
  double get speed => 1;

  /// 模拟"旧的 load 被新的 load 打断"。
  ///
  /// 真实的 `just_audio` 在旧的 `setAudioSource` 被新的顶掉时会抛
  /// `PlayerInterruptedException`（引擎层翻成「播放被中断」）。这个开关把
  /// 那一刻的行为搬进测试：第 1 次 load 挂住，等第 2 次 load 开始时以
  /// "播放被中断"失败。
  bool interruptFirstLoad = false;
  Completer<void>? _firstLoadGate;
  int _loadCalls = 0;

  /// 真的以"被中断"失败过几次。用来证明测试确实走到了那条路径 ——
  /// 否则这个回归测试可能只是因为"中断根本没发生"而通过的。
  int interruptedLoads = 0;

  /// 被真正换流过的地址（按顺序）。用来断言"过期的那次根本没去换流"。
  final List<String> loadedUrls = <String>[];

  @override
  Future<Duration?> load(
    ResolvedStream stream, {
    Duration? initialPosition,
  }) async {
    loadedUrls.add(stream.url.toString());
    final int call = ++_loadCalls;
    if (interruptFirstLoad && call == 1) {
      _firstLoadGate = Completer<void>();
      // 这个 future 会以异常完成，异常正好从 await 处抛出，
      // 与真实引擎"load 抛错"的形态一致。
      await _firstLoadGate!.future;
    }
    if (interruptFirstLoad && call > 1) {
      interruptedLoads++;
      _firstLoadGate?.completeError(
        AudioEngineException('播放被中断', cause: StateError('superseded')),
      );
      _firstLoadGate = null;
    }
    _duration = stream.duration ?? const Duration(minutes: 3);
    return _duration;
  }

  /// 与 `just_audio` 一致的"这一遍播放还没结束"凭据。
  ///
  /// **假引擎必须照抄这条语义**：`just_audio` 的 `play()` 是
  /// "播放**结束**才完成的 Future"（源码 `await playCompleter.future`），
  /// 而且开头有 `if (playing) return;`。原先这个假实现立刻返回 `Future.value`，
  /// 于是 `await engine.play()` 这种错误写法在测试里完全看不出来 ——
  /// 真机上它把"起播渐强"和"预解析下一首"推迟到整首歌放完才执行。
  Completer<void>? _playCompleter;

  @override
  Future<void> play() async {
    // 已经在播就直接返回，与 `just_audio` 的 `if (playing) return;` 一致。
    if (_isPlaying) return;
    _isPlaying = true;
    if (!_playing.isClosed) _playing.add(true);
    _playCompleter = Completer<void>();
    await _playCompleter!.future;
  }

  /// 结束"这一遍播放"，让挂起的 [play] 返回 —— 对应真实的暂停/播完/换源。
  void _finishPlayback() {
    final Completer<void>? completer = _playCompleter;
    _playCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  Future<void> pause() async {
    _isPlaying = false;
    if (!_playing.isClosed) _playing.add(false);
    _finishPlayback();
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double value) async => volumes.add(value);

  @override
  Future<void> setSpeed(double value) async {}

  @override
  Future<void> stop() async {
    _isPlaying = false;
    _finishPlayback();
  }

  @override
  Future<void> dispose() async {
    await _position.close();
    await _playing.close();
    await _completion.close();
  }
}

/// 只实现 `resolveStream`，其余成员靠 noSuchMethod 兜住 ——
/// 这个测试关心的是"解析被调用几次"，不是仓库的其它能力。
class _FakeRepository implements MusicRepository {
  _FakeRepository();

  @override
  final MediaSource source = MediaSource.netease;

  int resolveCount = 0;

  /// 让解析慢下来，用来模拟"解析比用户的下一次点击还慢"。
  Duration resolveDelay = Duration.zero;

  /// 让解析按指定异常失败。用来区分"这首歌放不了"与"这次碰巧失败"。
  Object? failWith;

  /// 只让指定的歌曲 id 失败（其余正常）。用来测"某首歌取不到直链"。
  Map<String, Object> failFor = const <String, Object>{};

  @override
  Future<ResolvedStream> resolveStream(Song song) async {
    resolveCount++;
    if (resolveDelay > Duration.zero) await Future<void>.delayed(resolveDelay);
    final Object? perSong = failFor[song.id];
    if (perSong != null) throw perSong;
    final Object? failure = failWith;
    if (failure != null) throw failure;
    return ResolvedStream(
      url: Uri.parse('https://example.invalid/${song.id}.mp3'),
      duration: const Duration(minutes: 3),
      qualityLabel: '极高 320k',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRegistry implements MusicSourceRegistry {
  _FakeRegistry(this.repository);

  final MusicRepository repository;

  @override
  List<MusicRepository> get all => <MusicRepository>[repository];

  @override
  MusicRepository? bySource(MediaSource source) =>
      source == repository.source ? repository : null;
}

const Song _songA = Song(
  id: 'a',
  source: MediaSource.netease,
  title: '第一首',
  duration: Duration(minutes: 3),
);
const Song _songB = Song(
  id: 'b',
  source: MediaSource.netease,
  title: '第二首',
  duration: Duration(minutes: 3),
);

/// 一首"版权下架、根本放不了"的歌。
///
/// 这正是用户截图里那首：列表层由 `noCopyrightRcmd` 标成
/// `playable == false`，`unplayableReason` 是「该歌曲暂无版权，已下架」。
/// 放不了的歌不该停在原地，而应该按队列切歌 —— 见下面那组用例。
const Song _songGone = Song(
  id: 'gone',
  source: MediaSource.netease,
  title: '下架歌',
  duration: Duration(minutes: 3),
  playable: false,
  unplayableReason: '该歌曲暂无版权，已下架',
);

/// 组装一个只挂了假引擎与假音源的容器。
Future<
  ({ProviderContainer container, _FakeEngine engine, _FakeRepository repo})
>
_pump({
  required bool crossFade,
  required bool gapless,
  double crossFadeSeconds = 0.15,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'player.volume': 0.8,
    'player.crossFade': crossFade,
    'player.crossFadeSeconds': crossFadeSeconds,
    'player.gapless': gapless,
  });
  final SharedPreferences prefs = await SharedPreferences.getInstance();

  final _FakeEngine engine = _FakeEngine();
  final _FakeRepository repo = _FakeRepository();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      audioEngineProvider.overrideWithValue(engine),
      sourceRegistryProvider.overrideWithValue(_FakeRegistry(repo)),
    ],
  );
  return (container: container, engine: engine, repo: repo);
}

/// 等到 [condition] 成立，或超时。
///
/// **不要用固定的 `Future.delayed` 去等渐变**：渐变是 50ms 一档的真实定时器，
/// 整套测试并行跑的时候机器一忙，"等 300ms"就不够了 —— 表现是单独跑通过、
/// 全量跑偶发失败。条件等待把这个不确定性去掉。
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// 渐变已经停稳（音量回到用户音量）。
bool _settled(_FakeEngine engine) =>
    engine.volumes.isNotEmpty && (engine.volumes.last - 0.8).abs() < 0.001;

void main() {
  test('淡入淡出开启时：起播音量从 0 渐强到用户音量', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: true, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    // build() 里会先按用户音量推一次，清掉以免干扰断言。
    env.engine.volumes.clear();

    await controller.playQueue(<Song>[_songA]);
    // 等渐变真正跑完（50ms 一档、0.15s → 3 档），不要猜时间：整套测试
    // 并行跑的时候机器一忙，"等 400ms"就可能不够，表现成偶发失败。
    await _waitFor(() => _settled(env.engine));

    expect(env.engine.volumes, isNotEmpty, reason: '应当推过音量');
    expect(env.engine.volumes.first, 0.0, reason: '渐变必须从 0 开始');
    expect(
      env.engine.volumes.last,
      closeTo(0.8, 0.001),
      reason: '渐变结束必须回到用户音量，而不是把音量留在 0',
    );
    // 单调不减：中间不能出现回跳。
    for (int i = 1; i < env.engine.volumes.length; i++) {
      expect(env.engine.volumes[i] >= env.engine.volumes[i - 1] - 1e-9, isTrue);
    }
  });

  test('淡入淡出关闭时：直接就是用户音量，没有渐变', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    env.engine.volumes.clear();

    await controller.playQueue(<Song>[_songA]);
    await _waitFor(() => env.engine.volumes.isNotEmpty);
    // 再多等一会儿，确认真的没有后续 ramp。
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // 关掉渐变时只会推一次（起播不做 ramp）。
    expect(env.engine.volumes, <double>[0.8]);
  });

  test('无缝衔接开启时：会预解析下一首', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: true);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA, _songB]);
    await _waitFor(() => env.repo.resolveCount >= 2);

    // 一次给当前曲目，一次给下一首 —— 这就是"切歌不再有解析空档"的依据。
    expect(env.repo.resolveCount, 2);
  });

  test('无缝衔接关闭时：只解析当前曲目', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA, _songB]);
    await _waitFor(() => env.repo.resolveCount >= 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(env.repo.resolveCount, 1);
  });

  test('播放模式按钮：一次点击在四种模式间循环，且 shuffle/repeat 始终自洽', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    PlayerUiState state() => env.container.read(playerControllerProvider);

    // 默认：顺序播放。
    expect(state().mode, ZhyPlaybackMode.sequential);
    expect(state().shuffle, isFalse);
    expect(state().repeat, ZhyRepeatMode.off);

    controller.cyclePlaybackMode();
    expect(state().mode, ZhyPlaybackMode.loopAll);
    expect(state().repeat, ZhyRepeatMode.all);
    expect(state().shuffle, isFalse);

    controller.cyclePlaybackMode();
    expect(state().mode, ZhyPlaybackMode.loopOne);
    expect(state().repeat, ZhyRepeatMode.one);
    expect(state().shuffle, isFalse);

    controller.cyclePlaybackMode();
    expect(state().mode, ZhyPlaybackMode.shuffle);
    expect(state().shuffle, isTrue);
    // 随机播放必须配列表循环：`_neighbourIndex` 在"随机 + 非列表循环"时
    // 走到打乱序列尽头就停了，那样"随机"放十几首就不放了。
    expect(state().repeat, ZhyRepeatMode.all);

    // 转回顺序播放，形成闭环。
    controller.cyclePlaybackMode();
    expect(state().mode, ZhyPlaybackMode.sequential);
    expect(state().shuffle, isFalse);
    expect(state().repeat, ZhyRepeatMode.off);
  });

  test('连续选曲：被取代的那次加载失败不得污染当前曲目状态', () async {
    // 这是用户报的"大部分歌曲播放失败 / 播放被中断"的回归测试。
    // 真实场景：连续点几首歌 → 每次点击都会打断上一次的换流 →
    // 被取代的那次抛「播放被中断」。以前它会覆盖当前曲目的状态，
    // 于是新歌明明在正常播放，播放条上却挂着一条「播放被中断」。
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    env.engine.interruptFirstLoad = true;
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    // 先点第一首（它的 load 会挂住），紧接着点第二首（打断它）。
    final Future<void> first = controller.playQueue(<Song>[_songA]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final Future<void> second = controller.playQueue(<Song>[_songB]);
    await Future.wait(<Future<void>>[first, second]);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final PlayerUiState state = env.container.read(playerControllerProvider);
    // 先证明"打断"真的发生了：否则下面几条断言可能只是因为没走到那条路径而通过。
    expect(
      env.engine.interruptedLoads,
      greaterThan(0),
      reason: '这次测试必须真的模拟出"旧加载被新加载打断"',
    );
    expect(state.current?.id, 'b', reason: '当前曲目应当是最后点的那首');
    expect(
      state.error,
      isNull,
      reason: '被取代的加载失败不是错误，绝不能挂在界面上',
    );
    expect(state.resolving, isFalse);
    expect(state.playing, isTrue, reason: '第二首应当正常在播');
  });

  test('解析比下一次点击还慢：过期的那次不得去换流，否则会顶掉新歌', () async {
    // 这是"只丢弃 load 结果"不够用的那一半。
    // 解析是联网操作，可能比用户的下一次点击还慢：如果过期的那次解析完成后
    // 仍然调 engine.load，它会把**新歌的流顶掉** —— 引擎里装着 A、
    // 界面状态里是 B，用户听到的和看到的对不上。
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    env.repo.resolveDelay = const Duration(milliseconds: 150);
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    final Future<void> first = controller.playQueue(<Song>[_songA]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final Future<void> second = controller.playQueue(<Song>[_songB]);
    await Future.wait(<Future<void>>[first, second]);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // A 的解析虽然最终也回来了，但它已经被取代，不该换流。
    expect(
      env.engine.loadedUrls.where((String u) => u.endsWith('a.mp3')),
      isEmpty,
      reason: '过期的那次解析绝不能去换流',
    );
    expect(env.engine.loadedUrls.last, endsWith('b.mp3'));

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(state.current?.id, 'b');
    expect(state.error, isNull);
    expect(state.playing, isTrue);
  });

  test('换流引起的"完成"事件不得让歌自己跳到下一首', () async {
    // 这是用户报的"在播放栏手动切换音质，歌曲会自动切换"的回归测试。
    // 机制：改音质要把新地址交给引擎，替换旧音源时 just_audio 会把旧的那次
    // 播放当成"结束"，于是完成事件被当成了"这首播完了" → 自动下一首。
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA, _songB]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(env.container.read(playerControllerProvider).current?.id, 'a');

    // 位置还在曲首（离曲尾很远），此时收到"完成" = 换流引起的。
    env.engine.emitPosition(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    env.engine.emitCompletion();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      env.container.read(playerControllerProvider).current?.id,
      'a',
      reason: '位置在曲首时收到的"完成"不是播完，绝不能跳曲',
    );

    // 对照组：位置真的到了曲尾，这时才该往下走 ——
    // 否则上面那条断言可能只是因为"完成事件根本没被处理"而通过。
    final Duration total = env.container.read(playerControllerProvider).duration;
    env.engine.emitPosition(total);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    env.engine.emitCompletion();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      env.container.read(playerControllerProvider).current?.id,
      'b',
      reason: '真的播完了就应该自动下一首',
    );
  });

  test('起播不被"播放结束"的 Future 卡住：渐强与预解析都在起播时发生', () async {
    // 这是"点歌不开始播放 / 没有渐强 / 无缝衔接不生效"的根因回归测试。
    //
    // `just_audio` 的 `play()` 要等**这次播放结束**才完成，所以任何
    // `await engine.play()` 都会把后续代码推迟到整首歌放完之后：
    //   - `playQueue` 一直不返回；
    //   - 起播渐强不在起播时发生；
    //   - 预解析下一首也不在起播时发生（无缝衔接形同虚设）。
    // 下面的断言分别盯住这三点。
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: true, gapless: true);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA, _songB]).timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail(
        'playQueue 没有立刻返回 —— 说明有人在 await 引擎的 play()，'
        '而它要等这次播放结束才完成',
      ),
    );

    // 起播渐强：必须已经推过音量（而不是等到整首歌放完才推）。
    expect(
      env.engine.volumes,
      isNotEmpty,
      reason: '起播渐亮没有在起播时发生（被 play() 的 Future 推迟了）',
    );
    // 无缝衔接：预解析也必须在起播时就发起。
    await _waitFor(() => env.repo.resolveCount >= 2);
    expect(env.repo.resolveCount, 2, reason: '下一首没有在起播时被预解析');
    expect(env.container.read(playerControllerProvider).playing, isTrue);
  });

  test('添加到队列：只追加、不替换、按 uid 去重、不打断当前曲目', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // B 是新的，A 已经在队列里 —— 只有 B 该被加进去。
    await controller.appendToQueue(<Song>[_songB, _songA]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(
      state.queue.map((Song song) => song.id).toList(),
      <String>['a', 'b'],
      reason: '应当是追加到末尾，并且重复的 a 不出现两次',
    );
    expect(state.current?.id, 'a', reason: '追加不该切走正在播放的那首');
    expect(state.index, 0);
  });

  test('队列原本为空时「添加到队列」顺手开始播放', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.appendToQueue(<Song>[_songA, _songB]);
    await _waitFor(
      () => env.container.read(playerControllerProvider).playing,
    );

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(state.queue.length, 2);
    expect(state.current?.id, 'a', reason: '空队列添加后应当从第一首开始放');
    expect(state.playing, isTrue);
  });

  // -------------------------------------------------------------------------
  // 放不了的曲目（版权下架）→ 按队列切歌
  // -------------------------------------------------------------------------

  test('点到一首下架歌：跳过它、播下一首，封面/歌词跟着切过去', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    // 队列：A(可播) → 下架 → B(可播)，直接从下架那首开始。
    await controller.playQueue(<Song>[
      _songA,
      _songGone,
      _songB,
    ], startIndex: 1);
    await _waitFor(
      () => env.container.read(playerControllerProvider).current?.id == 'b',
    );

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(state.current?.id, 'b', reason: '下架歌应当被跳过，改播下一首能播的');
    expect(state.error, isNull, reason: '已经靠切歌恢复了，不该再挂着错误');
    expect(state.playing, isTrue, reason: '跳过之后应当真的在放');
    // 封面走 currentCoverUrlProvider、歌词走 currentSongProvider，两者都以
    // "当前曲目"为唯一来源。所以只要当前曲目是对的，就不可能再出现
    // "音频还在放上一首、封面和歌词却显示下架歌" 的脱节。
    expect(
      env.container.read(currentCoverUrlProvider),
      _songB.coverUrl,
      reason: '封面必须跟着切到正在播的那首',
    );
  });

  test('从正常歌点下一首遇到下架歌：继续往前切，而不是停在原地', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    await controller.playQueue(<Song>[_songA, _songGone, _songB]);
    await _waitFor(
      () => env.container.read(playerControllerProvider).playing,
    );

    await controller.next();
    await _waitFor(
      () => env.container.read(playerControllerProvider).current?.id == 'b',
    );

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(state.current?.id, 'b', reason: '下一首是下架歌，应当继续往前切到能播的');
    expect(state.error, isNull);
  });

  test('点上一首遇到下架歌：沿"上"的方向继续找，不掉头往后', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    // A(可播) → 下架 → B(可播)，正在播 B。
    await controller.playQueue(<Song>[_songA, _songGone, _songB], startIndex: 2);
    await _waitFor(
      () => env.container.read(playerControllerProvider).playing,
    );

    await controller.previous();
    await _waitFor(
      () => env.container.read(playerControllerProvider).current?.id == 'a',
    );

    expect(
      env.container.read(playerControllerProvider).current?.id,
      'a',
      reason: '上一首是下架歌，应当继续往前（上）找，而不是掉头回到 B 自己',
    );
  });

  test('整队都不可播：停下来并说明原因，不能无限跳下去', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    // 两首下架歌。跳过逻辑是递归的，没有次数上限就会一直跳 —— 这条用例
    // 就是钉住那个上限的（它必须在有限时间内结束并给出结论）。
    await controller.playQueue(<Song>[_songGone, _songGone]).timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('整队不可播时没有停下来 —— 跳过逻辑可能是无限递归'),
    );
    await _waitFor(
      () => env.container.read(playerControllerProvider).error != null,
    );

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(state.playing, isFalse);
    expect(
      state.error,
      isNotNull,
      reason: '全都放不了时必须明确告诉用户，而不是静默停住',
    );
  });

  test('列表层看着正常、取直链时才知道放不了（unplayable 异常）也要切歌', () async {
    // `_isUnplayable` 有两条来源：列表层的 `playable == false`，以及解析层
    // 自己声明的 `MusicApiException.unplayable`（拿到 `url == null` 时）。
    // 上一条用例走的是前者，这条专走后者。
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    // A 拿不到直链（放不了），B 正常。
    env.repo.failFor = <String, Object>{
      'a': const MusicApiException(
        '该歌曲暂无可用音源（可能是版权或会员限制）',
        unplayable: true,
      ),
    };
    await controller.playQueue(<Song>[_songA, _songB]);
    await _waitFor(
      () => env.container.read(playerControllerProvider).current?.id == 'b',
    );

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(state.current?.id, 'b', reason: '拿不到直链也算"根本放不了"，应当切歌');
    expect(state.error, isNull);
  });

  test('网络类失败**不**跳歌：停在原地给原因与重试（对照组）', () async {
    // 这条是防"跳过头"的：只有"这首歌根本放不了"才该切歌。
    // 网络超时换一首歌并不会好，反而会把用户真正想听的那首跳过去。
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);
    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );

    env.repo.failWith = const MusicApiException(
      '网络连接失败，请检查网络后重试',
    ); // unplayable 默认 false
    await controller.playQueue(<Song>[_songA, _songB]);
    await _waitFor(
      () => env.container.read(playerControllerProvider).error != null,
    );

    final PlayerUiState state = env.container.read(playerControllerProvider);
    expect(
      state.current?.id,
      'a',
      reason: '暂时性失败不该跳到下一首 —— 用户还在等这一首',
    );
    expect(state.error, isNotNull, reason: '必须给出原因与重试入口');
    expect(state.playing, isFalse);
  });

  test('实际音质被写进播放状态（供播放条显示）', () async {    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: false, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA]);
    await _waitFor(
      () => env.container.read(playerControllerProvider).qualityLabel != null,
    );

    expect(
      env.container.read(playerControllerProvider).qualityLabel,
      '极高 320k',
    );
  });

  test('临近曲尾时渐弱到 0（不是等播完才降音量）', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: true, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA]);
    // 等起播的渐强跑完，再单独观察渐弱。
    await _waitFor(() => _settled(env.engine));
    expect(env.engine.volumes.last, closeTo(0.8, 0.001));

    env.engine.volumes.clear();
    final Duration total = env.container
        .read(playerControllerProvider)
        .duration;
    expect(total, const Duration(minutes: 3), reason: '时长应当来自引擎');

    // 距离曲尾只剩 100ms（小于 0.15s 的渐变时长）→ 应当立刻开始渐弱。
    env.engine.emitPosition(total - const Duration(milliseconds: 100));
    await _waitFor(
      () => env.engine.volumes.isNotEmpty && env.engine.volumes.last <= 0.05,
    );

    expect(env.engine.volumes, isNotEmpty, reason: '应当推过渐弱音量');
    expect(env.engine.volumes.last, closeTo(0.0, 0.05), reason: '渐弱必须降到 0');
    for (int i = 1; i < env.engine.volumes.length; i++) {
      expect(
        env.engine.volumes[i] <= env.engine.volumes[i - 1] + 1e-9,
        isTrue,
        reason: '渐弱过程中音量不能回升',
      );
    }
  });

  test('单曲循环时不渐弱（那一遍结束会立刻重播同一首）', () async {
    final ({
      ProviderContainer container,
      _FakeEngine engine,
      _FakeRepository repo,
    })
    env = await _pump(crossFade: true, gapless: false);
    addTearDown(env.container.dispose);

    final PlayerController controller = env.container.read(
      playerControllerProvider.notifier,
    );
    await controller.playQueue(<Song>[_songA]);
    // 必须等渐强停稳再清空，否则残留的 ramp 会被当成"渐弱"。
    await _waitFor(() => _settled(env.engine));

    controller.cycleRepeat(); // off → all
    controller.cycleRepeat(); // all → one
    expect(
      env.container.read(playerControllerProvider).repeat,
      ZhyRepeatMode.one,
    );

    env.engine.volumes.clear();
    final Duration total = env.container
        .read(playerControllerProvider)
        .duration;
    env.engine.emitPosition(total - const Duration(milliseconds: 100));
    // 这里反过来要等够久：确认"什么都没有发生"。400ms 远超单档 50ms。
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // 关键断言：单曲循环下不该出现渐弱（否则每次循环都会"掉一下音量"）。
    expect(env.engine.volumes, isEmpty);
  });
}
