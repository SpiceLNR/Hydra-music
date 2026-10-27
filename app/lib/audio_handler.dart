import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'models.dart';

/// Всё, чем фоновая служба (уведомление, экран блокировки, наушники) управляет в плеере.
abstract interface class PlayerControls {
  bool get isPlaying;
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration to);
}

/// Мост между плеером и системой Android: показывает уведомление с кнопками,
/// держит службу переднего плана, пока играет музыка (иначе Android усыпляет
/// приложение, и звук обрывается), и передаёт нажатия системы в плеер.
class HydraAudioHandler extends BaseAudioHandler {
  HydraAudioHandler(this._controls);

  final PlayerControls _controls;
  TrackInfo? _track;
  Uri? _art;
  Duration _duration = Duration.zero;
  bool _sessionActive = false;

  // ---- команды от системы ----

  @override
  Future<void> play() => _controls.play();

  @override
  Future<void> pause() => _controls.pause();

  @override
  Future<void> stop() => _controls.stop();

  @override
  Future<void> skipToNext() => _controls.next();

  @override
  Future<void> skipToPrevious() => _controls.previous();

  @override
  Future<void> seek(Duration position) => _controls.seek(position);

  // ---- состояние плеера -> система ----

  /// Трек сменился или нашлась его обложка.
  void setTrack(TrackInfo? track, Uri? art) {
    _track = track;
    _art = art;
    _pushItem();
  }

  void _pushItem() {
    final t = _track;
    if (t == null) return;
    mediaItem.add(MediaItem(
      id: t.id,
      title: t.title,
      artist: t.artist,
      duration: _duration > Duration.zero ? _duration : null,
      artUri: _art,
    ));
  }

  /// Сообщает системе текущее состояние. Позицию по тикам не шлём: Android сам
  /// прибавляет время, пока играет; обновляем только при смене состояния и перемотке.
  void publish({
    required TrackInfo? track,
    required bool playing,
    required Duration position,
    required Duration duration,
    required int index,
    required int queueLength,
    bool completed = false,
  }) {
    if (track == null) {
      publishStopped();
      return;
    }
    if (track.id != _track?.id) {
      _track = track;
      _art = null; // обложку подставит setTrack, когда прочитает её из тегов
      _duration = duration;
      _pushItem();
    } else if (duration != _duration) {
      _duration = duration;
      _pushItem();
    }

    final isPlaying = playing && !completed;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.playPause,
        MediaAction.play,
        MediaAction.pause,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: completed ? AudioProcessingState.completed : AudioProcessingState.ready,
      playing: isPlaying,
      updatePosition: position,
      bufferedPosition: duration > position ? duration : position,
      speed: 1.0,
      queueIndex: index,
    ));

    if (isPlaying && !_sessionActive) {
      _sessionActive = true;
      _activateSession();
    }
  }

  /// Музыка остановлена: уведомление и служба убираются.
  void publishStopped() {
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.idle,
      playing: false,
      controls: const [],
    ));
  }

  void _activateSession() {
    try {
      unawaited(
        AudioSession.instance.then((s) => s.setActive(true)).catchError((Object _) => false),
      );
    } catch (_) {
      // не критично: без фокуса звук всё равно играет
    }
  }
}

/// Запускает фоновую службу и настраивает звуковую сессию (звонки, наушники).
/// Ничего не делает вне Android. Любая ошибка даёт `null`: приложение работает,
/// как раньше, просто без фоновой службы.
Future<HydraAudioHandler?> initBackgroundPlayback(PlayerControls controls) async {
  if (!Platform.isAndroid) return null;
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    var resumeAfterInterruption = false;
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        if (event.type == AudioInterruptionType.duck) return;
        if (controls.isPlaying) {
          resumeAfterInterruption = true;
          unawaited(controls.pause());
        }
      } else {
        if (resumeAfterInterruption && event.type == AudioInterruptionType.pause) {
          unawaited(controls.play());
        }
        resumeAfterInterruption = false;
      }
    });
    session.becomingNoisyEventStream.listen((_) {
      resumeAfterInterruption = false;
      unawaited(controls.pause());
    });

    return await AudioService.init<HydraAudioHandler>(
      builder: () => HydraAudioHandler(controls),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.spicelnr.hydra_music.playback',
        androidNotificationChannelName: 'Воспроизведение',
        androidNotificationOngoing: true,
      ),
    );
  } catch (_) {
    return null;
  }
}
