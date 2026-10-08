import 'dart:async';
import 'dart:io' show Platform;

import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart' as mk;

/// Звуковой движок под плеером. Android: системный ExoPlayer (just_audio): он экономнее
/// к батарее, без заиканий и надёжно работает с Bluetooth. Windows: mpv (media_kit).
/// Громкость здесь 0..100.
abstract class AudioEngine {
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;

  /// Номер текущего трека в открытой очереди.
  Stream<int> get indexStream;
  Stream<bool> get completedStream;

  /// Человекочитаемые ошибки воспроизведения (файл не читается, формат не поддержан).
  Stream<String> get errorStream;

  /// После ошибки трека имеет смысл сразу перейти к следующему.
  bool get skipOnError;

  /// Открывает очередь файлов и начинает играть с [index].
  Future<void> open(List<String> paths, int index);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> next();

  /// Предыдущий трек очереди (без «сначала, если играет дольше 3 секунд»).
  Future<void> previous();
  Future<void> setVolume(double volume);
}

AudioEngine createAudioEngine() =>
    Platform.isAndroid ? JustAudioEngine() : MediaKitEngine();

/// Android: ExoPlayer. Треки готовятся лениво, поэтому очередь в сотни файлов открывается сразу.
class JustAudioEngine implements AudioEngine {
  final StreamController<String> _errors = StreamController<String>.broadcast();

  late final ja.AudioPlayer _p = _create();

  ja.AudioPlayer _create() {
    // прерывания (звонок, другое приложение) обрабатывает наш HydraAudioHandler
    final player = ja.AudioPlayer(handleInterruptions: false);
    player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace _) {
      _errors.add(_describe(e));
    });
    return player;
  }

  static String _describe(Object e) {
    if (e is ja.PlayerException) {
      final m = e.message;
      return (m == null || m.isEmpty) ? 'код ${e.code}' : m;
    }
    if (e is ja.PlayerInterruptedException) return 'загрузка прервана';
    return e.toString();
  }

  @override
  bool get skipOnError => true;

  @override
  Stream<bool> get playingStream => _p.playingStream;

  @override
  Stream<Duration> get positionStream => _p.positionStream;

  @override
  Stream<Duration> get durationStream => _p.durationStream.map((d) => d ?? Duration.zero);

  @override
  Stream<int> get indexStream =>
      _p.currentIndexStream.where((i) => i != null).map((i) => i!);

  @override
  Stream<bool> get completedStream =>
      _p.processingStateStream.map((s) => s == ja.ProcessingState.completed);

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Future<void> open(List<String> paths, int index) async {
    try {
      final source = ja.ConcatenatingAudioSource(
        useLazyPreparation: true,
        children: [for (final path in paths) ja.AudioSource.uri(Uri.file(path))],
      );
      // preload: false - ошибка файла придёт через errorStream, а не оборвёт открытие очереди
      await _p.setAudioSource(source, initialIndex: index, initialPosition: Duration.zero, preload: false);
      unawaited(_p.play().catchError((Object e) {
        _errors.add(_describe(e));
      }));
    } catch (e) {
      _errors.add(_describe(e));
    }
  }

  @override
  Future<void> play() async {
    unawaited(_p.play().catchError((Object e) {
      _errors.add(_describe(e));
    }));
  }

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> seek(Duration to) => _p.seek(to);

  @override
  Future<void> next() async {
    if (_p.hasNext) await _p.seekToNext();
  }

  @override
  Future<void> previous() async {
    final i = _p.currentIndex ?? 0;
    if (i > 0) await _p.seek(Duration.zero, index: i - 1);
  }

  @override
  Future<void> setVolume(double volume) => _p.setVolume((volume / 100).clamp(0.0, 1.0));
}

/// Windows: mpv через media_kit.
class MediaKitEngine implements AudioEngine {
  late final mk.Player _p = _create();

  mk.Player _create() {
    final player = mk.Player();
    // небольшой запас аудиобуфера и плавный переход между треками
    unawaited(_set(player, 'audio-buffer', '0.5'));
    unawaited(_set(player, 'gapless-audio', 'yes'));
    return player;
  }

  static Future<void> _set(mk.Player player, String name, String value) async {
    try {
      await (player.platform as dynamic).setProperty(name, value);
    } catch (_) {
      // настройка не принята: играем с настройками по умолчанию
    }
  }

  @override
  bool get skipOnError => false;

  @override
  Stream<bool> get playingStream => _p.stream.playing;

  @override
  Stream<Duration> get positionStream => _p.stream.position;

  @override
  Stream<Duration> get durationStream => _p.stream.duration;

  @override
  Stream<int> get indexStream => _p.stream.playlist.map((p) => p.index);

  @override
  Stream<bool> get completedStream => _p.stream.completed;

  @override
  Stream<String> get errorStream => _p.stream.error;

  @override
  Future<void> open(List<String> paths, int index) =>
      _p.open(mk.Playlist([for (final path in paths) mk.Media(path)], index: index));

  @override
  Future<void> play() => _p.play();

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> seek(Duration to) => _p.seek(to);

  @override
  Future<void> next() => _p.next();

  @override
  Future<void> previous() => _p.previous();

  @override
  Future<void> setVolume(double volume) => _p.setVolume(volume);
}
