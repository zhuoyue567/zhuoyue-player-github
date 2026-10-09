import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/models/song.dart';
import 'media_proxy.dart';

/// 播放引擎抽象。
///
/// 上层（播放队列、界面）只依赖这个接口，不直接碰 `just_audio`。
/// 这样做的直接收益：将来要把后端换成 `media_kit`（支持更多格式、能放 MV）
/// 时，只需要新增一个实现类，队列与界面一行都不用改。
abstract interface class AudioEngine {
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<Object> get errorStream;

  /// 一首曲目自然播放完毕的信号（不是因为用户暂停/切歌）。
  /// 播放队列靠它决定「单曲循环 / 自动下一首 / 顺序播完停止」。
  Stream<void> get completionStream;

  Duration get position;
  Duration? get duration;
  bool get playing;
  double get volume;
  double get speed;

  /// 载入并准备播放（不自动开始）。
  Future<Duration?> load(ResolvedStream stream, {Duration? initialPosition});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double value);
  Future<void> setSpeed(double value);
  Future<void> stop();
  Future<void> dispose();
}

/// 基于 `just_audio` 的实现。
///
/// Windows 上由 `just_audio_windows` 提供后端（C++/WinRT，走 Media Foundation）。
/// 没有选 `media_kit` 的原因写在 docs/architecture.md：它的 Windows 原生库
/// 需要在 CMake 配置阶段从 GitHub Releases 下载，而本机网络到 GitHub 不通，
/// 构建会直接失败。
class JustAudioEngine implements AudioEngine {
  JustAudioEngine({AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    // 播放期的错误（解码失败、网络中断、403）不会从 Future 里抛出来，
    // 而是走这条事件流。不接住它，用户只会看到"点了没反应"。
    _errorSubscription = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[audio] 播放事件错误: $error');
        if (!_errors.isClosed) _errors.add(error);
      },
    );
    _processingSubscription = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        // 播放结束 ≠ 用户想停。这里只发出"播完了"的信号，
        // 由播放队列决定是单曲循环、顺序下一首还是停止。
        if (!_completions.isClosed) _completions.add(null);
      }
    });
  }

  final AudioPlayer _player;
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  final StreamController<void> _completions =
      StreamController<void>.broadcast();

  late final StreamSubscription<PlaybackEvent> _errorSubscription;
  late final StreamSubscription<ProcessingState> _processingSubscription;

  /// 当前载入的真实地址，避免把同一个地址重复 setAudioSource。
  Uri? _currentUri;

  /// 一首歌播完的通知，供队列监听。
  @override
  Stream<void> get completionStream => _completions.stream;
  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<bool> get bufferingStream => _player.processingStateStream
      .map(
        (ProcessingState state) =>
            state == ProcessingState.loading ||
            state == ProcessingState.buffering,
      )
      .distinct();

  @override
  Stream<Object> get errorStream => _errors.stream;

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  bool get playing => _player.playing;

  @override
  double get volume => _player.volume;

  @override
  double get speed => _player.speed;

  @override
  Future<Duration?> load(
    ResolvedStream stream, {
    Duration? initialPosition,
  }) async {
    // 带自定义请求头（哔哩）的流走本地代理，其余直连。
    final Uri uri = stream.headers.isEmpty
        ? stream.url
        : (await MediaProxyServer.instance()).proxiedUriFor(stream);

    try {
      if (_currentUri == uri) {
        // 同一个地址重复载入：只做定位，不重新建流，
        // 避免"切回上一首"时白等一次网络握手。
        if (initialPosition != null) await _player.seek(initialPosition);
        return _player.duration;
      }
      _currentUri = uri;
      return await _player.setAudioSource(
        AudioSource.uri(uri),
        preload: true,
        initialPosition: initialPosition,
      );
    } on PlayerException catch (error, stackTrace) {
      throw AudioEngineException(
        '无法播放该音频：${error.message ?? '播放器返回未知错误'}',
        cause: error,
        stackTrace: stackTrace,
      );
    } on PlayerInterruptedException catch (error, stackTrace) {
      throw AudioEngineException('播放被中断', cause: error, stackTrace: stackTrace);
    } on Object catch (error, stackTrace) {
      throw AudioEngineException(
        '播放失败：$error',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double value) =>
      _player.setVolume(value.clamp(0.0, 1.0));

  @override
  Future<void> setSpeed(double value) =>
      _player.setSpeed(value.clamp(0.5, 2.0));

  @override
  Future<void> stop() async {
    _currentUri = null;
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    await _errorSubscription.cancel();
    await _processingSubscription.cancel();
    await _player.dispose();
    await _errors.close();
    await _completions.close();
  }
}

/// 播放失败。
class AudioEngineException implements Exception {
  const AudioEngineException(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'AudioEngineException: $message';
}

final Provider<AudioEngine> audioEngineProvider = Provider<AudioEngine>((
  Ref ref,
) {
  final JustAudioEngine engine = JustAudioEngine();
  ref.onDispose(engine.dispose);
  return engine;
});
