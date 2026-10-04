import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';

/// Воспроизведение очереди (порядок плейлиста) поверх media_kit.
///
/// Нативный плеер создаётся лениво, при первом `playQueue`, поэтому в тестах и до
/// первого запуска музыки нативные библиотеки не нужны. Экраны слушают сам сервис
/// (`ListenableBuilder`) и флаг [hasTrack] (показывать ли «Сейчас играет» на главной).
class PlayerService extends ChangeNotifier {
  PlayerService._();

  static final PlayerService instance = PlayerService._();

  /// Есть ли сейчас выбранный трек (для мини-панели на главном экране).
  static final ValueNotifier<bool> hasTrack = ValueNotifier<bool>(false);

  late final Player _player = Player();
  bool _wired = false;

  List<TrackInfo> queue = const [];
  int index = 0;
  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  TrackInfo? get current => (index >= 0 && index < queue.length) ? queue[index] : null;

  void _wire() {
    if (_wired) return;
    _wired = true;
    _player.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
    });
    _player.stream.position.listen((v) {
      position = v;
      notifyListeners();
    });
    _player.stream.duration.listen((v) {
      duration = v;
      notifyListeners();
    });
    _player.stream.playlist.listen((p) {
      if (p.index != index) {
        index = p.index;
        position = Duration.zero;
        notifyListeners();
      }
    });
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
    await _player.open(Playlist([for (final t in queue) Media(t.path)], index: index));
  }

  Future<void> playOrPause() => _player.playOrPause();

  Future<void> seek(Duration to) => _player.seek(to);

  Future<void> next() => _player.next();

  Future<void> previous() => _player.previous();
}
