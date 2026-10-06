import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:permission_handler/permission_handler.dart';

import 'audio_handler.dart';
import 'library_controller.dart';
import 'models.dart';

/// Воспроизведение очереди (порядок плейлиста) поверх media_kit.
///
/// Нативный плеер создаётся лениво, при первом `playQueue`, поэтому в тестах и до
/// первого запуска музыки нативные библиотеки не нужны. Экраны слушают сам сервис
/// (`ListenableBuilder`) и флаг [hasTrack] (показывать ли «Сейчас играет»).
///
/// На Android состояние дополнительно передаётся в фоновую службу ([HydraAudioHandler]):
/// она держит приложение живым при выключенном экране и рисует уведомление с кнопками.
class PlayerService extends ChangeNotifier implements PlayerControls {
  PlayerService._();

  static final PlayerService instance = PlayerService._();

  /// Есть ли сейчас выбранный трек (для панели «Сейчас играет»).
  static final ValueNotifier<bool> hasTrack = ValueNotifier<bool>(false);

  late final Player _player = Player();
  bool _wired = false;
  bool _askedNotifications = false;
  HydraAudioHandler? _handler;

  List<TrackInfo> queue = const [];
  int index = 0;
  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  TrackInfo? get current => (index >= 0 && index < queue.length) ? queue[index] : null;

  /// Запускает фоновую службу (Android). Вызывается один раз при старте приложения.
  Future<void> initBackground() async {
    _handler = await initBackgroundPlayback(this);
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    _player.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
      _publish();
    });
    _player.stream.position.listen((v) {
      position = v;
      notifyListeners();
    });
    _player.stream.duration.listen((v) {
      duration = v;
      notifyListeners();
      _publish();
    });
    _player.stream.playlist.listen((p) {
      if (p.index != index) {
        index = p.index;
        position = Duration.zero;
        notifyListeners();
        _publishTrack();
        _publish();
      }
    });
    _player.stream.completed.listen((done) {
      if (done) _publish(completed: true);
    });
  }

  /// Сообщает системе текущее состояние (уведомление, экран блокировки).
  void _publish({bool completed = false}) {
    _handler?.publish(
      track: current,
      playing: playing,
      position: position,
      duration: duration,
      index: index,
      queueLength: queue.length,
      completed: completed,
    );
  }

  /// Обложка трека для уведомления: читается из тегов, пока трек не сменился.
  Future<void> _publishTrack() async {
    final handler = _handler;
    final track = current;
    if (handler == null || track == null) return;
    String? cover;
    try {
      cover = await hydraLibrary.coverPath(track.id);
    } catch (_) {
      cover = null;
    }
    if (current?.id != track.id) return;
    handler.setTrack(track, cover == null ? null : Uri.file(cover));
  }

  /// Запускает очередь с позиции [start]; порядок треков - порядок плейлиста.
  Future<void> playQueue(List<TrackInfo> tracks, int start) async {
    if (tracks.isEmpty) return;
    _wire();
    queue = List.of(tracks);
    index = start.clamp(0, queue.length - 1);
    position = Duration.zero;
    duration = Duration.zero;
    hasTrack.value = true;
    notifyListeners();
    if (Platform.isAndroid && !_askedNotifications) {
      // Без разрешения на уведомления Android 13+ не покажет кнопки в шторке.
      _askedNotifications = true;
      unawaited(Permission.notification.request());
    }
    await _player.open(Playlist([for (final t in queue) Media(t.path)], index: index));
    _publishTrack();
    _publish();
  }

  Future<void> playOrPause() {
    if (queue.isEmpty) return Future<void>.value();
    return _player.playOrPause();
  }

  // ---- PlayerControls: команды из уведомления, наушников и экрана блокировки ----

  @override
  bool get isPlaying => playing;

  @override
  Future<void> play() {
    if (queue.isEmpty) return Future<void>.value();
    return _player.play();
  }

  @override
  Future<void> pause() {
    if (queue.isEmpty) return Future<void>.value();
    return _player.pause();
  }

  /// «Стоп»: пауза и возврат в начало трека. Очередь остаётся, уведомление исчезает.
  @override
  Future<void> stop() async {
    if (queue.isEmpty) return;
    await _player.pause();
    await _player.seek(Duration.zero);
    playing = false;
    position = Duration.zero;
    notifyListeners();
    _handler?.publishStopped();
  }

  @override
  Future<void> seek(Duration to) async {
    if (queue.isEmpty) return;
    await _player.seek(to);
    position = to;
    notifyListeners();
    _publish();
  }

  @override
  Future<void> next() {
    if (queue.isEmpty) return Future<void>.value();
    return _player.next();
  }

  @override
  Future<void> previous() {
    if (queue.isEmpty) return Future<void>.value();
    return _player.previous();
  }
}
