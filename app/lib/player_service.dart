import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_messenger.dart';
import 'audio_engine.dart';
import 'audio_handler.dart';
import 'file_probe.dart';
import 'library_controller.dart';
import 'models.dart';

/// Режим порядка воспроизведения (слева направо в переключателе).
/// [repeat] - один трек по кругу; [standard] - плейлист по кругу;
/// [shuffle] - случайный порядок плейлиста; [anarchy] - случайный порядок всех плейлистов.
enum PlayMode { repeat, standard, shuffle, anarchy }

/// Воспроизведение очереди (порядок плейлиста). Звук ведёт [AudioEngine]: на Android
/// ExoPlayer, на Windows mpv.
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

  /// Создание движка (подменяется в тестах).
  AudioEngine Function() engineFactory = createAudioEngine;
  late final AudioEngine _engine = engineFactory();
  DateTime _lastPrevious = DateTime.fromMillisecondsSinceEpoch(0);
  int _errorStreak = 0;
  bool _wired = false;
  bool _askedNotifications = false;
  HydraAudioHandler? _handler;

  /// Громкость 0..100 (на Windows её меняет вертикальная полоса в шторке).
  double volume = 100;

  /// Текущий режим. При запуске приложения всегда «Стандартный».
  PlayMode mode = PlayMode.standard;
  final Random _rng = Random();

  /// Порядок плейлиста, из которого запущена музыка (нужен, чтобы вернуться из случайных режимов).
  List<TrackInfo> _base = const [];

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

  /// Меняет громкость; сохранением занимается интерфейс.
  Future<void> setVolume(double value) async {
    volume = value.clamp(0, 100).toDouble();
    notifyListeners();
    if (_wired) await _engine.setVolume(volume);
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    _engine.setVolume(volume);
    _engine.playingStream.listen((v) {
      playing = v;
      notifyListeners();
      _publish();
    });
    _engine.positionStream.listen((v) {
      // меньше 0.25 с не перерисовываем интерфейс: лишняя нагрузка на телефон
      if (v != Duration.zero && (v - position).abs() < const Duration(milliseconds: 250)) return;
      position = v;
      if (v > const Duration(seconds: 1)) _errorStreak = 0;
      notifyListeners();
    });
    _engine.durationStream.listen((v) {
      duration = v;
      notifyListeners();
      _publish();
    });
    _engine.indexStream.listen((i) {
      if (i != index && i >= 0 && i < queue.length) {
        index = i;
        position = Duration.zero;
        notifyListeners();
        _publishTrack();
        _publish();
      }
    });
    _engine.completedStream.listen((done) {
      if (done) _publish(completed: true);
    });
    _engine.errorStream.listen(_onError);
  }

  /// Файл не открылся: говорим об этом с причиной и, если движок позволяет,
  /// переходим к следующему треку (не больше пяти ошибок подряд).
  void _onError(String message) {
    final t = current;
    final name = t == null ? '' : '«${t.title}» (${t.fileName}): ';
    showAppMessage('Не удалось воспроизвести $name$message');
    if (t != null) {
      // дополняем сообщение справкой о файле (есть ли он, размер, начало)
      probeFile(t.path).then((info) {
        showAppMessage('Не удалось воспроизвести $name$message\n$info');
      });
    }
    _errorStreak++;
    if (_engine.skipOnError && _errorStreak <= 5 && queue.length > 1) {
      Future<void>.delayed(
          const Duration(milliseconds: 300), () => _engine.jumpTo((index + 1) % queue.length));
    }
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

  /// Подменяет трек в очереди после правки названия, исполнителя или обложки.
  void updateTrack(TrackInfo updated) {
    final i = queue.indexWhere((t) => t.id == updated.id);
    if (i < 0) return;
    queue = [...queue]..[i] = updated;
    final b = _base.indexWhere((t) => t.id == updated.id);
    if (b >= 0) _base = [..._base]..[b] = updated;
    if (i == index) {
      _publish();
      unawaited(_publishTrack());
    }
    notifyListeners();
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

  bool get _random => mode == PlayMode.shuffle || mode == PlayMode.anarchy;

  /// Все треки всех плейлистов (для «Анархии»).
  Future<List<TrackInfo>> _everything() async {
    final all = <TrackInfo>[];
    for (final p in List.of(hydraLibrary.playlists)) {
      try {
        all.addAll(await hydraLibrary.tracks(p.id));
      } on Object {
        // плейлист не прочитался: играем остальные
      }
    }
    return all;
  }

  /// Случайный порядок: [first] ставится первым, остальные перемешиваются заново.
  List<TrackInfo> _shuffled(List<TrackInfo> pool, TrackInfo? first) {
    final rest = [for (final t in pool) if (t.id != first?.id) t]..shuffle(_rng);
    return [if (first != null) first, ...rest];
  }

  /// Запускает очередь с позиции [start]. Порядок: плейлиста, а в режимах «Разнобой»
  /// и «Анархия» случайный, начиная с выбранного трека.
  Future<void> playQueue(List<TrackInfo> tracks, int start) async {
    if (tracks.isEmpty) return;
    _wire();
    final first = tracks[start.clamp(0, tracks.length - 1)];
    _base = List.of(tracks);
    if (_random) {
      final pool = mode == PlayMode.anarchy ? await _everything() : tracks;
      queue = _shuffled(pool.isEmpty ? tracks : pool, first);
      index = 0;
    } else {
      queue = List.of(tracks);
      index = start.clamp(0, queue.length - 1);
    }
    position = Duration.zero;
    duration = Duration.zero;
    hasTrack.value = true;
    notifyListeners();
    if (Platform.isAndroid && !_askedNotifications) {
      // Без разрешения на уведомления Android 13+ не покажет кнопки в шторке.
      _askedNotifications = true;
      unawaited(Permission.notification.request());
    }
    _errorStreak = 0;
    await _engine.open([for (final t in queue) t.path], index);
    await _engine.setRepeatOne(mode == PlayMode.repeat);
    _publishTrack();
    _publish();
  }

  /// Переключает режим. Играющий трек не меняется и продолжается с того же места.
  Future<void> setMode(PlayMode next) async {
    if (next == mode) return;
    final before = mode;
    mode = next;
    notifyListeners();
    if (queue.isEmpty) return;
    await _engine.setRepeatOne(next == PlayMode.repeat);
    final cur = current;
    List<TrackInfo>? rebuilt;
    if (next == PlayMode.shuffle || next == PlayMode.anarchy) {
      final pool = next == PlayMode.anarchy ? await _everything() : _base;
      rebuilt = _shuffled(pool.isEmpty ? queue : pool, cur);
    } else if (before == PlayMode.shuffle || before == PlayMode.anarchy) {
      final inBase = cur != null && _base.any((t) => t.id == cur.id);
      rebuilt = [if (cur != null && !inBase) cur, ..._base];
    }
    if (rebuilt == null || cur == null) return;
    final at = max(0, rebuilt.indexWhere((t) => t.id == cur.id));
    final wasPlaying = playing;
    final pos = position;
    queue = rebuilt;
    index = at;
    notifyListeners();
    await _engine.open([for (final t in queue) t.path], index);
    await _engine.setRepeatOne(next == PlayMode.repeat);
    if (pos > Duration.zero) await _engine.seek(pos);
    if (!wasPlaying) await _engine.pause();
    _publishTrack();
    _publish();
  }

  Future<void> playOrPause() => playing ? pause() : play();

  // ---- PlayerControls: команды из уведомления, наушников и экрана блокировки ----

  @override
  bool get isPlaying => playing;

  @override
  Future<void> play() {
    if (queue.isEmpty) return Future<void>.value();
    return _engine.play();
  }

  @override
  Future<void> pause() {
    if (queue.isEmpty) return Future<void>.value();
    return _engine.pause();
  }

  /// «Стоп»: пауза и возврат в начало трека. Очередь остаётся, уведомление исчезает.
  @override
  Future<void> stop() async {
    if (queue.isEmpty) return;
    await _engine.pause();
    await _engine.seek(Duration.zero);
    playing = false;
    position = Duration.zero;
    notifyListeners();
    _handler?.publishStopped();
  }

  @override
  Future<void> seek(Duration to) async {
    if (queue.isEmpty) return;
    await _engine.seek(to);
    position = to;
    notifyListeners();
    _publish();
  }

  @override
  Future<void> next() {
    if (queue.isEmpty) return Future<void>.value();
    return _engine.jumpTo((index + 1) % queue.length);
  }

  /// «Назад»: одно нажатие возвращает в начало трека, второе нажатие подряд
  /// (в течение 1,5 с) переходит к предыдущему треку.
  @override
  Future<void> previous() async {
    if (queue.isEmpty) return;
    final now = DateTime.now();
    final second = now.difference(_lastPrevious) < const Duration(milliseconds: 1500);
    if (second) {
      _lastPrevious = DateTime.fromMillisecondsSinceEpoch(0);
      await _engine.jumpTo((index - 1 + queue.length) % queue.length);
    } else {
      _lastPrevious = now;
      await seek(Duration.zero);
    }
  }
}
