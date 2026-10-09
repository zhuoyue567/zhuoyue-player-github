import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/audio/audio_engine.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/theme_providers.dart';
import '../../core/theme/theme_settings.dart';
import '../../data/models/song.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/source_registry.dart';

/// 循环模式。
///
/// 刻意不叫 `ZhyRepeatMode`：Flutter 自己的 `material.dart` 里已经导出了
/// 一个同名的 `ZhyRepeatMode`（来自 `repeating_animation_builder`），
/// 同时 import 两者会直接编译失败。
enum ZhyRepeatMode {
  /// 顺序播放，播完队列就停。
  off('顺序播放', '播完最后一首就停下'),

  /// 列表循环。
  all('列表循环', '播完最后一首回到第一首'),

  /// 单曲循环。
  one('单曲循环', '一直重复当前这首');

  const ZhyRepeatMode(this.label, this.description);

  final String label;
  final String description;

  ZhyRepeatMode get next =>
      ZhyRepeatMode.values[(index + 1) % ZhyRepeatMode.values.length];

  static ZhyRepeatMode fromName(String? name) {
    for (final ZhyRepeatMode mode in values) {
      if (mode.name == name) return mode;
    }
    return ZhyRepeatMode.off;
  }
}

/// 界面上呈现的**单一**播放模式。
///
/// 为什么要多这一层：底层其实是两个正交字段（[PlayerUiState.shuffle] 与
/// [PlayerUiState.repeat]），但界面上摆两个按钮既占地方又难理解 ——
/// 用户想的是"我现在是顺序还是随机"，不是一个布尔值加一个三态枚举。
/// 于是把两者合成一个可循环切换的按钮，顺序是：
///
/// 顺序播放 → 列表循环 → 单曲循环 → 随机播放 → 顺序播放 …
///
/// 注意 [shuffle] 这个模式同时把 `repeat` 设成 [ZhyRepeatMode.all]：
/// `_neighbourIndex` 在"随机 + 非列表循环"时会走到打乱序列的尽头就停下，
/// 那样"随机播放"放十几首就停了，不是用户要的。
enum ZhyPlaybackMode {
  sequential('顺序播放', '播完最后一首就停下'),
  loopAll('列表循环', '播完最后一首回到第一首'),
  loopOne('单曲循环', '一直重复当前这首'),
  shuffle('随机播放', '打乱顺序，一直播下去');

  const ZhyPlaybackMode(this.label, this.description);

  final String label;
  final String description;

  ZhyPlaybackMode get next =>
      ZhyPlaybackMode.values[(index + 1) % ZhyPlaybackMode.values.length];
}

/// 用于在 [PlayerUiState.copyWith] 中区分「不传」与「显式传 null」。
const Object _unset = Object();

/// 播放器的完整界面状态。
@immutable
class PlayerUiState {
  const PlayerUiState({
    this.queue = const <Song>[],
    this.index = -1,
    this.playing = false,
    this.buffering = false,
    this.resolving = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 0.8,
    this.shuffle = false,
    this.repeat = ZhyRepeatMode.off,
    this.error,
    this.qualityLabel,
  });

  final List<Song> queue;
  final int index;

  /// 是否正在出声。
  final bool playing;

  /// 是否在缓冲（加载中）。与 [resolving] 的区别：
  /// resolving 是"还在跟接口要地址"，buffering 是"地址有了，在下载数据"。
  final bool buffering;

  /// 是否正在向音源解析播放地址。
  final bool resolving;

  final Duration position;
  final Duration duration;
  final double volume;
  final bool shuffle;
  final ZhyRepeatMode repeat;

  /// 最近一次失败原因，展示给用户后由 [PlayerController.dismissError] 清掉。
  final String? error;

  /// 当前曲目**实际**拿到的音质（由音源在解析地址时填入）。
  ///
  /// 它是"服务端真正给了什么"，不是用户选了什么 ——
  /// 会员权益不足时服务端会静默降级，播放条必须显示实际值。
  final String? qualityLabel;

  /// 由 [shuffle] 与 [repeat] 推导出的单一播放模式（界面上的那个按钮）。
  ZhyPlaybackMode get mode {
    if (shuffle) return ZhyPlaybackMode.shuffle;
    return switch (repeat) {
      ZhyRepeatMode.off => ZhyPlaybackMode.sequential,
      ZhyRepeatMode.all => ZhyPlaybackMode.loopAll,
      ZhyRepeatMode.one => ZhyPlaybackMode.loopOne,
    };
  }

  Song? get current => index >= 0 && index < queue.length ? queue[index] : null;

  bool get hasTrack => current != null;

  double get progress {
    final int total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  PlayerUiState copyWith({
    List<Song>? queue,
    int? index,
    bool? playing,
    bool? buffering,
    bool? resolving,
    Duration? position,
    Duration? duration,
    double? volume,
    bool? shuffle,
    ZhyRepeatMode? repeat,
    Object? error = _unset,
    String? qualityLabel,
  }) {
    return PlayerUiState(
      queue: queue ?? this.queue,
      index: index ?? this.index,
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      resolving: resolving ?? this.resolving,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      shuffle: shuffle ?? this.shuffle,
      repeat: repeat ?? this.repeat,
      error: identical(error, _unset) ? this.error : error as String?,
      qualityLabel: qualityLabel ?? this.qualityLabel,
    );
  }
}

/// 播放队列与播放控制。
///
/// 这个类**不关心音源差异**：它拿到的都是 [Song]，地址解析交给
/// [MusicSourceRegistry] 找到的 repository。网易云和哔哩的曲目可以
/// 混在同一个队列里顺序播放，正是靠这一层抽象。
class PlayerController extends Notifier<PlayerUiState> {
  static const String _kVolume = 'player.volume';
  static const String _kShuffle = 'player.shuffle';
  static const String _kRepeat = 'player.repeat';

  AudioEngine? _engine;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final math.Random _random = math.Random();

  /// 随机播放顺序（队列下标的一个排列）。
  List<int> _shuffleOrder = <int>[];

  // ------------------------------------------------------------ 淡入淡出

  /// 当前的实际音量 = 用户音量 × 这个渐变系数。
  ///
  /// 刻意把"用户音量"和"渐变"分开：直接去改 `state.volume` 会让渐变
  /// 把用户设定的音量冲掉（例如渐弱结束时用户音量变成 0，下一首就没声了）。
  double _fadeFactor = 1.0;
  Timer? _fadeTimer;
  bool _fadingOut = false;

  // ------------------------------------------------------------ 预解析

  /// 已经提前解析好的下一首（无缝衔接）。
  ResolvedStream? _prefetchedStream;
  String? _prefetchedUid;
  bool _prefetching = false;

  /// 上一次 [_loadCurrent] 是否以失败告终。
  ///
  /// 用来区分"这首放完了"和"这首压根没加载成功" —— 两者都会触发引擎的
  /// 完成事件，见 [_handleCompletion]。只由**当前这一次**加载设置，
  /// 被取代的加载不许碰它（见 [_loadToken]）。
  bool _loadFailed = false;

  /// 加载序号。每调用一次 [_loadCurrent] 自增；被取代的那次加载
  /// 成功或失败都会被丢弃。用它区分"当前这次加载"与"用户已经换掉的那次"。
  int _loadToken = 0;

  /// 控制器已经销毁。异步回来的回调据此不再改 state。
  bool _disposed = false;

  /// 连续因为"这首放不了"而跳过了几首。
  ///
  /// 它是 [_skipUnplayable] 的递归上限：整队都是下架歌时不能无限跳下去。
  /// 成功播放一首、或用户主动选曲时清零。
  int _unplayableSkips = 0;

  /// 读一次播放设置。**用 `ref.read` 而不是 `ref.watch`**：
  /// 这个 Notifier 的 `build()` 里 watch 任何东西都会在设置变化时重建，
  /// 而重建会把整个播放队列清空 —— 改个设置就丢队列是不能接受的。
  ZhyThemeSettings get _settings => ref.read(themeSettingsProvider);

  @override
  PlayerUiState build() {
    final AudioEngine engine = ref.watch(audioEngineProvider);
    _engine = engine;

    final SharedPreferences prefs = ref.watch(sharedPreferencesProvider);
    final double volume = (prefs.getDouble(_kVolume) ?? 0.8).clamp(0.0, 1.0);
    final bool shuffle = prefs.getBool(_kShuffle) ?? false;
    final ZhyRepeatMode repeat = ZhyRepeatMode.fromName(
      prefs.getString(_kRepeat),
    );

    _subscriptions.addAll(<StreamSubscription<Object?>>[
      engine.positionStream.listen((Duration position) {
        state = state.copyWith(position: position);
        _maybeStartFadeOut(position);
      }),
      engine.durationStream.listen((Duration? duration) {
        if (duration != null && duration > Duration.zero) {
          state = state.copyWith(duration: duration);
        }
      }),
      engine.playingStream.listen((bool playing) {
        state = state.copyWith(playing: playing);
      }),
      engine.bufferingStream.listen((bool buffering) {
        state = state.copyWith(buffering: buffering);
      }),
      engine.errorStream.listen(_handleEngineError),
      engine.completionStream.listen((_) => unawaited(_handleCompletion())),
    ]);

    ref.onDispose(() {
      // 置位后再去取消订阅：setState 是异步发起的（见 [_startPlayback]），
      // 它可能在我们已经销毁之后才回来，那时必须不再碰 state。
      _disposed = true;
      _fadeTimer?.cancel();
      for (final StreamSubscription<Object?> subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
    });

    unawaited(engine.setVolume(volume));

    return PlayerUiState(volume: volume, shuffle: shuffle, repeat: repeat);
  }

  // -------------------------------------------------------------------------
  // 对外操作
  // -------------------------------------------------------------------------

  /// 用一组曲目替换队列并开始播放。
  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    final int index = startIndex.clamp(0, songs.length - 1);
    _regenerateShuffleOrder(songs.length);
    state = state.copyWith(
      queue: List<Song>.unmodifiable(songs),
      index: index,
      position: Duration.zero,
      duration: Duration.zero,
      error: null,
    );
    await _loadUserChoice(autoPlay: true);
  }

  /// 把一组曲目**追加**到当前队列末尾（增量添加）。
  ///
  /// 与 [playQueue] 的区别是"不替换、不跳转"：用户的意图是"把这些歌排到
  /// 后面去"，正在放的那首不该被打断，队列里已有的内容也不该被冲掉。
  ///
  /// 两个细节：
  /// - **按 uid 去重**：已经在队列里的不再加一遍。同一首歌在队列里出现两次
  ///   是纯粹的困惑来源（用户在队列 island 里看到两行一样的歌）。
  /// - **队列原本为空时顺手起播**：这时"添加"和"播放"对用户是同一件事，
  ///   加完却什么都不放会让人觉得功能没生效。
  Future<void> appendToQueue(List<Song> songs) async {
    if (songs.isEmpty) return;

    final Set<String> existing = state.queue
        .map((Song song) => song.uid)
        .toSet();
    final List<Song> fresh = <Song>[];
    for (final Song song in songs) {
      if (existing.add(song.uid)) fresh.add(song);
    }

    if (fresh.isEmpty) {
      debugPrint('[player] 加入队列：${songs.length} 首全都已在队列里，没有新增');
      return;
    }

    final bool wasEmpty = state.queue.isEmpty;
    final List<Song> queue = <Song>[...state.queue, ...fresh];
    _regenerateShuffleOrder(queue.length);
    state = state.copyWith(queue: List<Song>.unmodifiable(queue));
    debugPrint(
      '[player] 加入队列：新增 ${fresh.length} 首'
      '${fresh.length < songs.length ? '（跳过 ${songs.length - fresh.length} 首重复的）' : ''}'
      '，队列现共 ${queue.length} 首',
    );

    if (wasEmpty) {
      state = state.copyWith(
        index: 0,
        position: Duration.zero,
        duration: Duration.zero,
        error: null,
      );
      await _loadUserChoice(autoPlay: true);
    }
  }

  /// 播放单曲。
  ///
  /// [context] 传入时表示"这首来自某个列表"，会用该列表替换队列，
  /// 这样播放结束能自然接着往下走，而不是播完就停 —— 这是用户在
  /// 列表里点一首歌时的真实预期。
  Future<void> playSong(Song song, {List<Song>? context}) async {
    if (context != null && context.isNotEmpty) {
      final int index = context.indexWhere((Song item) => item.uid == song.uid);
      await playQueue(context, startIndex: index >= 0 ? index : 0);
      return;
    }
    final List<Song> queue = <Song>[...state.queue];
    final int existing = queue.indexWhere((Song item) => item.uid == song.uid);
    if (existing >= 0) {
      state = state.copyWith(index: existing, position: Duration.zero);
      await _loadUserChoice(autoPlay: true);
      return;
    }
    // 单曲播放（不在任何列表里）：替换掉队列而不是往后追加，
    // 否则连续点几首单曲会攒出一个莫名其妙的队列。
    _regenerateShuffleOrder(1);
    state = state.copyWith(
      queue: <Song>[song],
      index: 0,
      position: Duration.zero,
      duration: Duration.zero,
      error: null,
    );
    await _loadUserChoice(autoPlay: true);
  }

  Future<void> togglePlayPause() async {
    final AudioEngine? engine = _engine;
    if (engine == null) return;
    if (state.current == null) return;
    if (state.playing) {
      // 乐观更新：按钮立刻变成"播放"图标，不等引擎的事件绕一圈回来。
      // 引擎的状态流仍然是最终权威，它会纠正我们。
      state = state.copyWith(playing: false);
      await engine.pause();
    } else {
      // 播完之后再点播放：从头开始，而不是停在末尾一动不动。
      if (state.duration > Duration.zero && state.position >= state.duration) {
        await engine.seek(Duration.zero);
      }
      state = state.copyWith(playing: true);
      _startPlayback(engine);
    }
  }

  /// 发起播放，但**不阻塞调用方**，并且失败要留下痕迹。
  ///
  /// 为什么要单独一个方法：`just_audio` 的 `play()` 要等这次播放**结束**
  /// 才完成，所以任何"await 它再往下做别的"的写法都是错的（见 [_loadCurrent]
  /// 里的说明）。这里只负责把它的结果收掉：成功了什么都不用做（状态流会
  /// 同步 `playing`），失败了就把原因写进日志与界面。
  void _startPlayback(AudioEngine engine) {
    unawaited(() async {
      try {
        await engine.play();
      } on Object catch (error) {
        if (_disposed) return;
        final String reason = describePlaybackError(error);
        debugPrint('[player] 起播失败：$reason');
        state = state.copyWith(playing: false, error: reason);
      }
    }());
  }

  Future<void> next() => _move(1, userInitiated: true);

  /// 直接跳到队列中的某一首（点击队列列表时使用）。
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.queue.length || index == state.index) {
      return;
    }
    state = state.copyWith(index: index, position: Duration.zero);
    await _loadUserChoice(autoPlay: true);
  }

  Future<void> previous() async {
    // 播放超过 3 秒时，"上一首"的普遍预期是回到本曲开头。
    if (state.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    await _move(-1, userInitiated: true);
  }

  Future<void> seek(Duration position) async {
    final AudioEngine? engine = _engine;
    if (engine == null) return;
    final Duration target = position < Duration.zero
        ? Duration.zero
        : (state.duration > Duration.zero && position > state.duration
              ? state.duration
              : position);
    // 先本地更新，进度条不会"回弹"一下再跟上。
    state = state.copyWith(position: target);
    await engine.seek(target);
  }

  Future<void> setVolume(double volume) async {
    final double value = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: value);
    await _engine?.setVolume(value);
    unawaited(ref.read(sharedPreferencesProvider).setDouble(_kVolume, value));
  }

  /// 重新解析并加载当前曲目 —— 改完音质后让新档位**当场生效**。
  ///
  /// 保持原来的播放/暂停状态：如果本来停在暂停上，改音质不应该把它放起来。
  Future<void> reloadCurrent() async {
    if (!state.hasTrack) return;
    final bool wasPlaying = state.playing;
    await _loadUserChoice(autoPlay: wasPlaying);
  }

  void toggleShuffle() {
    final bool shuffle = !state.shuffle;
    state = state.copyWith(shuffle: shuffle);
    if (shuffle) _regenerateShuffleOrder(state.queue.length);
    unawaited(ref.read(sharedPreferencesProvider).setBool(_kShuffle, shuffle));
  }

  void cycleRepeat() {
    final ZhyRepeatMode mode = state.repeat.next;
    state = state.copyWith(repeat: mode);
    unawaited(
      ref.read(sharedPreferencesProvider).setString(_kRepeat, mode.name),
    );
  }

  /// 循环切换播放模式 —— 播放条上那个按钮的唯一入口。
  ///
  /// 一次点击同时改 `shuffle` 与 `repeat`（见 [ZhyPlaybackMode] 的说明），
  /// 并把两个字段一起落盘，避免重启后出现"随机开着但循环模式是上一次的"
  /// 这种自相矛盾的状态。
  void cyclePlaybackMode() {
    final ZhyPlaybackMode next = state.mode.next;
    final bool shuffle = next == ZhyPlaybackMode.shuffle;
    final ZhyRepeatMode repeat = switch (next) {
      ZhyPlaybackMode.sequential => ZhyRepeatMode.off,
      ZhyPlaybackMode.loopAll => ZhyRepeatMode.all,
      ZhyPlaybackMode.loopOne => ZhyRepeatMode.one,
      // 随机播放必须配列表循环：否则打乱序列走完就停了。
      ZhyPlaybackMode.shuffle => ZhyRepeatMode.all,
    };

    state = state.copyWith(shuffle: shuffle, repeat: repeat);
    if (shuffle) _regenerateShuffleOrder(state.queue.length);

    final SharedPreferences prefs = ref.read(sharedPreferencesProvider);
    unawaited(prefs.setBool(_kShuffle, shuffle));
    unawaited(prefs.setString(_kRepeat, repeat.name));
    debugPrint('[player] 播放模式切换为 ${next.label}');
  }

  /// 把一首歌加入队列。[next] 为 true 时插到当前曲目之后。
  void enqueue(Song song, {bool next = false}) {
    final List<Song> queue = <Song>[...state.queue];
    final int index = next ? state.index + 1 : queue.length;
    queue.insert(index.clamp(0, queue.length), song);
    _regenerateShuffleOrder(queue.length);
    state = state.copyWith(
      queue: List<Song>.unmodifiable(queue),
      // 插在当前曲目之前时，当前曲目的下标要跟着后移，
      // 否则"正在播放"会瞬间跳到别的歌上。
      index: index <= state.index ? state.index + 1 : state.index,
    );
  }

  void removeAt(int index) {
    if (index < 0 || index >= state.queue.length) return;
    final List<Song> queue = <Song>[...state.queue]..removeAt(index);
    _regenerateShuffleOrder(queue.length);

    if (queue.isEmpty) {
      unawaited(_engine?.stop());
      state = state.copyWith(
        queue: const <Song>[],
        index: -1,
        playing: false,
        position: Duration.zero,
        duration: Duration.zero,
      );
      return;
    }

    if (index < state.index) {
      state = state.copyWith(
        queue: List<Song>.unmodifiable(queue),
        index: state.index - 1,
      );
    } else if (index == state.index) {
      // 删掉的是正在播的那首：保持下标（即自动播下一首），播不了就回退到末尾。
      state = state.copyWith(
        queue: List<Song>.unmodifiable(queue),
        index: state.index.clamp(0, queue.length - 1),
      );
      unawaited(_loadUserChoice(autoPlay: state.playing));
    } else {
      state = state.copyWith(queue: List<Song>.unmodifiable(queue));
    }
  }

  void clearQueue() {
    unawaited(_engine?.stop());
    state = state.copyWith(
      queue: const <Song>[],
      index: -1,
      playing: false,
      position: Duration.zero,
      duration: Duration.zero,
    );
  }

  void dismissError() {
    if (state.error != null) state = state.copyWith(error: null);
  }

  /// 重试当前曲目（播放失败后）。
  Future<void> retry() async {
    state = state.copyWith(error: null);
    await _loadUserChoice(autoPlay: true);
  }

  // -------------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // 淡入淡出
  // -------------------------------------------------------------------------

  /// 把当前"用户音量 × 渐变系数"推给引擎。
  Future<void> _applyVolume() async {
    final double effective = (state.volume * _fadeFactor).clamp(0.0, 1.0);
    await _engine?.setVolume(effective);
  }

  /// 起播时从 0 渐强到用户音量。
  void _startFadeIn() {
    final ZhyThemeSettings settings = _settings;
    _fadingOut = false;
    if (!settings.crossFade) {
      _fadeFactor = 1.0;
      unawaited(_applyVolume());
      return;
    }
    _rampFade(
      from: 0.0,
      to: 1.0,
      duration: Duration(
        milliseconds: (settings.crossFadeSeconds * 1000).round(),
      ),
    );
  }

  /// 临近曲尾时渐弱。
  ///
  /// 判据放在这里（而不是等 `completionStream`）是因为播放结束的那一刻
  /// 已经没有时间做渐变了 —— 必须**提前**开始降音量。
  void _maybeStartFadeOut(Duration position) {
    final ZhyThemeSettings settings = _settings;
    if (!settings.crossFade || _fadingOut) return;
    final Duration total = state.duration;
    if (total <= Duration.zero) return;

    final Duration fade = Duration(
      milliseconds: (settings.crossFadeSeconds * 1000).round(),
    );
    // 单曲循环时不渐弱：那一遍结束会立刻从头播同一首，渐弱反而突兀。
    if (state.repeat == ZhyRepeatMode.one) return;
    if (total - position > fade) return;

    _fadingOut = true;
    _rampFade(from: _fadeFactor, to: 0.0, duration: total - position);
  }

  /// 线性渐变。50ms 一档足够顺滑，也不会把定时器压满。
  void _rampFade({
    required double from,
    required double to,
    required Duration duration,
  }) {
    _fadeTimer?.cancel();
    if (duration <= Duration.zero) {
      _fadeFactor = to;
      unawaited(_applyVolume());
      return;
    }

    const int stepMs = 50;
    final int steps = (duration.inMilliseconds / stepMs).ceil().clamp(1, 400);
    final double delta = (to - from) / steps;
    int done = 0;
    double current = from;
    _fadeFactor = from;
    unawaited(_applyVolume());

    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (
      Timer t,
    ) {
      done++;
      current += delta;
      if (done >= steps) {
        current = to;
        t.cancel();
      }
      _fadeFactor = current.clamp(0.0, 1.0);
      unawaited(_applyVolume());
    });
  }

  // -------------------------------------------------------------------------
  // 预解析（无缝衔接）
  // -------------------------------------------------------------------------

  /// 取当前曲目的播放地址：命中预解析结果就直接用，否则现解析。
  Future<ResolvedStream> _takeStream(
    Song song,
    MusicRepository repository,
  ) async {
    if (_prefetchedUid == song.uid && _prefetchedStream != null) {
      final ResolvedStream ready = _prefetchedStream!;
      // 预解析的地址也可能已经过期（签名直链有寿命），过期的必须丢掉重解析。
      if (ready.isValidAt(DateTime.now())) {
        _prefetchedStream = null;
        _prefetchedUid = null;
        return ready;
      }
      _prefetchedStream = null;
      _prefetchedUid = null;
    }
    return repository.resolveStream(song);
  }

  /// 后台解析下一首。失败就静默放弃 —— 它只是优化，不能影响播放。
  Future<void> _prefetchNext() async {
    if (!_settings.gaplessPlayback || _prefetching) return;
    if (state.queue.isEmpty) return;

    final int? next = _neighbourIndex(1);
    if (next == null) return;
    final Song song = state.queue[next];
    // 单曲循环时"下一首"就是自己，没必要预解析。
    if (song.uid == state.current?.uid) return;
    if (_prefetchedUid == song.uid) return;

    final MusicRepository? repository = ref
        .read(sourceRegistryProvider)
        .bySource(song.source);
    if (repository == null || !song.playable) return;

    _prefetching = true;
    try {
      final ResolvedStream stream = await repository.resolveStream(song);
      _prefetchedStream = stream;
      _prefetchedUid = song.uid;
      debugPrint('[player] 已预解析下一首：${song.title}');
    } on Object catch (error) {
      debugPrint('[player] 预解析下一首失败（忽略）：$error');
    } finally {
      _prefetching = false;
    }
  }

  /// 一次"用户主动发起"的加载：先把"跳过不可播"的预算清零。
  ///
  /// 预算必须在**用户动作**里重置，不能放进 [_loadCurrent] —— 跳过本身也会
  /// 递归调用 [_loadCurrent]，在那里清零等于把递归上限废掉，整队都是下架歌时
  /// 会无限跳下去。
  Future<void> _loadUserChoice({
    required bool autoPlay,
    int direction = 1,
  }) {
    _unplayableSkips = 0;
    return _loadCurrent(autoPlay: autoPlay, direction: direction);
  }

  Future<void> _loadCurrent({
    required bool autoPlay,
    int direction = 1,
  }) async {
    final AudioEngine? engine = _engine;
    final Song? song = state.current;
    if (engine == null || song == null) return;

    // ★ 每次加载领一个号。
    //
    // 用户连续点几首歌时会有多个 `_loadCurrent` 同时在飞，而 `just_audio`
    // 在旧的 `setAudioSource` 被新的打断时会抛 `PlayerInterruptedException`
    // （我们把它翻成「播放被中断」）。以前这个"被取代的那次加载"的失败会
    // **覆盖掉当前这首歌的状态**：于是明明新歌正在正常播放，播放条上却挂着
    // 一条「播放被中断」——用户看到的正是"大部分歌曲播放失败"。
    //
    // 有了这个号，被取代的加载无论成功还是失败都直接丢弃：它已经不是"当前
    // 这一次"了。同样的道理，`_loadFailed` 也只认当前号的失败，
    // 否则它会一直挡着新歌的"播完自动下一首"。
    final int token = ++_loadToken;

    state = state.copyWith(
      resolving: true,
      error: null,
      position: Duration.zero,
      duration: song.duration ?? Duration.zero,
    );

    /// 这次加载是否已经被更新的选曲取代。
    bool superseded() => token != _loadToken;

    try {
      if (!song.playable) {
        throw MusicApiException(
          song.unplayableReason ?? '该曲目当前不可播放',
          source: song.source,
        );
      }

      final MusicRepository? repository = ref
          .read(sourceRegistryProvider)
          .bySource(song.source);
      if (repository == null) {
        throw MusicApiException('没有可用的音源实现：${song.source.label}');
      }

      final ResolvedStream stream = await _takeStream(song, repository);

      // 解析期间用户又点了别的歌 —— **这里绝不能再往下走**。
      //
      // 只做"load 之后丢弃结果"是不够的：解析（联网）可能比用户的下一次点击
      // 还慢，那时这一次的 `engine.load` 会**反过来把新歌的流顶掉**，
      // 于是引擎里装着 A、界面状态里是 B —— 播放条显示的歌和真正在放的对不上。
      // 所以必须在换流之前就退出。
      if (superseded()) {
        debugPrint('[player] 解析完成但已被新的选曲取代，不再换流：${song.title}');
        return;
      }

      final Duration? actual = await engine.load(stream);

      // 解析期间用户又点了别的歌：这次加载已经过期，成功也不能再改状态，
      // 否则它会覆盖新歌的 duration / qualityLabel / resolving。
      if (superseded()) {
        debugPrint('[player] 加载已完成但已被新的选曲取代，丢弃结果：${song.title}');
        return;
      }

      // 把**实际**音质记进状态：服务端可能已经按权益降级了，
      // 播放条显示的是拿到手的档位，而不是用户选的那一档。
      state = state.copyWith(qualityLabel: stream.qualityLabel);
      if (actual != null && Duration.zero < actual) {
        state = state.copyWith(duration: actual);
      }
      state = state.copyWith(resolving: false);
      _loadFailed = false;
      // 真的播上了一首，跳过计数归零。
      _unplayableSkips = 0;
      if (autoPlay) {
        // ★ 绝不能 `await engine.play()`。
        //
        // `just_audio` 的 `play()` 是"**播放结束**才完成的 Future"
        // （源码 `await playCompleter.future`），而且它开头还有一句
        // `if (playing) return;`。原先是 `await engine.play(); _startFadeIn();`
        // 的写法，后果是：
        //   - 起播渐强被推迟到**整首歌放完**才执行（等于没有渐强）；
        //   - 紧随其后的"预解析下一首"同理，无缝衔接形同虚设；
        //   - `_loadCurrent` 一直挂在这个 await 上不返回。
        // 所以这里改成"发起播放后立刻继续"，把播放的 Future 交给
        // [_startPlayback] 去收尾（失败要能看见）。
        state = state.copyWith(playing: true);
        _startPlayback(engine);
        _startFadeIn();
      }
      // 起播之后再预解析下一首：不要让预解析跟本次播放抢网络。
      unawaited(_prefetchNext());
    } on Object catch (error) {
      // 被取代的那次加载失败**不是错误** —— 用户就是换了首歌。
      // 这里必须静默丢弃：它的「播放被中断」既不该显示，也不该
      // 把 `_loadFailed` 立起来挡住新歌播完后的自动下一首。
      if (superseded()) {
        debugPrint('[player] 被新的选曲取代的加载失败（忽略）：$error');
        return;
      }

      _loadFailed = true;
      final String reason = describePlaybackError(error);
      // 把"哪一首、哪个音源、什么原因"完整写进日志：用户就是靠这条
      // 去回答"这首为什么放不了"。列表层的标记（unplayableReason）也带上，
      // 因为它和解析失败的原因往往不是同一个。
      debugPrint(
        '[player] 播放失败：${song.title} · ${song.artistLabel}'
        '（${song.source.label}，id=${song.id}）→ $reason'
        '${song.unplayableReason == null ? '' : '；列表标记：${song.unplayableReason}'}',
      );

      // ★ 这首歌根本放不了（版权下架 / 需要购买）→ 按队列**切歌**。
      //
      // 用户的要求很明确：下架的歌放不了就该跳过，而不是停在原地。
      // 两种失败必须分开处理（判据见 [_isUnplayable]）：
      //   - "放不了" → 换一首是真能解决问题的；
      //   - "暂时失败"（网络、403）→ 换歌解决不了，停在原地给原因 + 重试。
      if (_isUnplayable(song, error)) {
        // 先把声音停下。否则引擎里还留着**上一首**的流并继续出声，
        // 而界面已经切到这首下架歌上了 —— 就是用户看到的
        // "实际在播放的还是分开的，但专辑和歌词显示的是下架歌曲"。
        await _engine?.pause();
        state = state.copyWith(
          resolving: false,
          buffering: false,
          playing: false,
          error: null,
        );
        await _skipUnplayable(direction: direction);
        return;
      }

      state = state.copyWith(
        resolving: false,
        buffering: false,
        playing: false,
        error: reason,
      );
    }
  }

  /// 这次失败是否意味着"这首歌根本放不了"（而不是"这次碰巧失败"）。
  ///
  /// 判据全部来自**类型化信号**，不匹配错误文案：
  /// - 列表层已经标了 `playable == false`（网易云的 `noCopyrightRcmd`
  ///   就是这样标出来的，`unplayableReason` 是「该歌曲暂无版权，已下架」）；
  /// - 或者异常自己声明了 `unplayable`（解析层拿到 `url == null` 时），
  ///   有些歌列表层看着正常、要到取直链时才知道放不了。
  ///
  /// 网络超时 / 403 地址过期这类**不在**此列：换一首歌并不会让网络恢复，
  /// 反而会把用户真正想听的那首跳过去。
  static bool _isUnplayable(Song song, Object error) {
    if (!song.playable) return true;
    if (error is MusicApiException) return error.unplayable;
    return false;
  }

  /// 当前曲目放不了：沿 [direction] 方向找下一首能播的。
  ///
  /// **必须有次数上限**，而且它是**承重**的：[`_neighbourIndex`] 在
  /// 「列表循环」模式下永远不会返回 `null`（到头会绕回开头），整队都是下架歌时
  /// 没有上限就是无限递归。上限取队列长度 —— 转完一整圈还没找到，
  /// 就说明真的没有可播的了。
  ///
  /// 顺带说明「单曲循环」下的行为：`_neighbourIndex` **不**对 `repeat == one`
  /// 做特殊处理，所以跳过时还是会往前走一格，不会原地卡在同一首上。
  Future<void> _skipUnplayable({required int direction}) async {
    final int length = state.queue.length;
    if (_unplayableSkips >= length) {
      debugPrint('[player] 队列里 $length 首全都不可播放，停止');
      state = state.copyWith(
        playing: false,
        error: '播放列表里的曲目都不可播放（版权下架或需要购买）',
      );
      return;
    }

    final int? target = _neighbourIndex(direction);
    if (target == null) {
      // 沿这个方向走到头了。顺序播放时这是正常尽头；但如果是"你点的这首
      // 放不了、后面也没有能放的了"，得说清楚，别让用户以为程序卡住。
      debugPrint('[player] $direction 方向已无更多曲目，停止');
      state = state.copyWith(
        playing: false,
        error: '没有可播放的曲目了（其余曲目因版权下架或需要购买而不可播）',
      );
      return;
    }

    _unplayableSkips++;
    final Song next = state.queue[target];
    debugPrint(
      '[player] 跳过不可播放的曲目，切到：${next.title} · ${next.artistLabel}',
    );
    // 先把界面切过去（封面 / 标题 / 歌词都跟着 currentSongProvider 走），
    // 再去加载 —— 这样"看到的那首"和"正在放的那首"始终是同一首。
    state = state.copyWith(
      index: target,
      position: Duration.zero,
      duration: next.duration ?? Duration.zero,
      error: null,
    );
    await _loadCurrent(autoPlay: true, direction: direction);
  }

  /// 移动到队列中的下一首 / 上一首。
  Future<void> _move(int delta, {required bool userInitiated}) async {
    if (state.queue.isEmpty) return;
    final int? target = _neighbourIndex(delta);
    if (target == null) {
      // 顺序播放走到尽头：停下但保留当前曲目，用户还能按播放重听。
      await _engine?.pause();
      state = state.copyWith(index: state.index, playing: false);
      return;
    }
    state = state.copyWith(index: target);
    // 把方向传下去：如果这一首也放不了，"跳过"要顺着用户刚才的方向继续走
    // （点上一首碰到下架歌，应该继续往前找，而不是掉头往后）。
    await _loadCurrent(autoPlay: true, direction: delta.sign);
  }

  int? _neighbourIndex(int delta) {
    final int length = state.queue.length;
    if (length == 0) return null;

    if (state.shuffle && _shuffleOrder.length == length) {
      final int position = _shuffleOrder.indexOf(state.index);
      final int nextPosition = position + delta;
      if (nextPosition >= 0 && nextPosition < length) {
        return _shuffleOrder[nextPosition];
      }
      return state.repeat == ZhyRepeatMode.all
          ? _shuffleOrder[(nextPosition % length + length) % length]
          : null;
    }

    final int candidate = state.index + delta;
    if (candidate >= 0 && candidate < length) return candidate;
    if (state.repeat == ZhyRepeatMode.all) {
      return (candidate % length + length) % length;
    }
    return null;
  }

  Future<void> _handleCompletion() async {
    // ★ 关键：加载失败的曲目也会抛出一个"播放完成"事件。
    //
    // 引擎把"这次播放结束了"和"这次加载根本没成功"报成同一个事件，
    // 于是照常推进就会**静默跳到下一首** —— 用户点了第 3 首，看到的却是
    // 第 4 首在放，而且完全不知道第 3 首为什么没放（错误信息还会被下一首的
    // 加载覆盖掉）。这里直接忽略这次完成事件，把错误留在界面上。
    if (_loadFailed) {
      debugPrint('[player] 当前曲目加载失败，忽略这次完成事件（不自动跳曲）');
      return;
    }

    // ★ 换流本身也会换来一次"完成"事件。
    //
    // 改音质会重新解析并把新地址交给引擎，**替换掉旧音源时 just_audio 会把
    // 旧的那次播放当成"结束"**。于是用户在播放栏点一下"无损"，歌就自己跳到
    // 下一首了。这类"完成"不是"这首歌播完了"，必须挡掉。两条判据：
    //
    // 1. 正在解析/换流中 —— 说明这次完成是换流引起的；
    // 2. 播放位置离曲尾还很远 —— 正常播完时位置必然在曲尾附近，
    //    差得远就说明引擎报的这个"完成"与"这首歌放完了"无关。
    //
    // 两条都要有：换流的完成事件可能在 `resolving` 刚变 false 之后才到，
    // 那时只靠第 1 条挡不住；而只靠第 2 条又会在"时长为 0 / 未上报"时失效。
    if (state.resolving) {
      debugPrint('[player] 换流期间的完成事件，忽略（不自动跳曲）');
      return;
    }
    const Duration tail = Duration(seconds: 3);
    final Duration total = state.duration;
    if (Duration.zero < total && state.position + tail < total) {
      debugPrint(
        '[player] 位置离曲尾还远（${state.position.inSeconds}s / '
        '${total.inSeconds}s），忽略这次完成事件',
      );
      return;
    }

    if (state.repeat == ZhyRepeatMode.one) {
      await seek(Duration.zero);
      final AudioEngine? engine = _engine;
      if (engine != null) {
        // 同样不能 await：`just_audio` 的 `play()` 要等下一遍也放完才完成，
        // await 它会让这个完成处理函数一直挂着。
        state = state.copyWith(playing: true);
        _startPlayback(engine);
      }
      return;
    }
    await _move(1, userInitiated: false);
  }

  void _handleEngineError(Object error) {
    state = state.copyWith(
      error: describePlaybackError(error),
      playing: false,
      buffering: false,
    );
  }

  void _regenerateShuffleOrder(int length) {
    _shuffleOrder = List<int>.generate(length, (int i) => i);
    // Fisher–Yates。
    for (int i = length - 1; i > 0; i--) {
      final int j = _random.nextInt(i + 1);
      final int tmp = _shuffleOrder[i];
      _shuffleOrder[i] = _shuffleOrder[j];
      _shuffleOrder[j] = tmp;
    }
  }

  /// 更新当前曲目的显示时长（列表里拿到的时长往往比解码出来的更准）。
  void patchCurrentDuration(Duration duration) {
    final Song? song = state.current;
    if (song == null || song.duration == duration) return;
    final List<Song> queue = <Song>[...state.queue];
    queue[state.index] = song.copyWith(duration: duration);
    state = state.copyWith(queue: List<Song>.unmodifiable(queue));
  }
}

/// 把底层异常翻译成用户能看懂的一句话。
///
/// 直接把 `PlayerException` / `SocketException` 的原文丢到界面上，
/// 用户只会看到一堆英文和堆栈。这里统一收敛成中文说明。
String describePlaybackError(Object error) {
  if (error is MusicApiException) return error.message;
  if (error is AudioEngineException) return error.message;
  final String text = error.toString();
  if (text.contains('SocketException') || text.contains('Connection')) {
    return '网络连接失败，请检查网络后重试';
  }
  if (text.contains('403')) {
    return '音源拒绝了本次请求（403），可能是地址已过期，请重试';
  }
  if (text.contains('404')) {
    return '音源地址已失效（404），请重试';
  }
  return '播放失败：$text';
}

final NotifierProvider<PlayerController, PlayerUiState>
playerControllerProvider = NotifierProvider<PlayerController, PlayerUiState>(
  PlayerController.new,
);

/// 当前曲目（没有则为 null）。
final Provider<Song?> currentSongProvider = Provider<Song?>(
  (Ref ref) => ref.watch(playerControllerProvider).current,
);

/// 当前封面地址，供背景层取色与显示使用。
final Provider<String?> currentCoverUrlProvider = Provider<String?>(
  (Ref ref) => ref.watch(playerControllerProvider).current?.coverUrl,
);

/// 是否正在播放。
final Provider<bool> isPlayingProvider = Provider<bool>(
  (Ref ref) => ref.watch(playerControllerProvider).playing,
);
