import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hydra_music/audio_engine.dart';
import 'package:hydra_music/models.dart';
import 'package:hydra_music/player_service.dart';

class FakeEngine implements AudioEngine {
  final List<String> calls = [];
  final StreamController<bool> _playing = StreamController<bool>.broadcast();
  final StreamController<Duration> _position = StreamController<Duration>.broadcast();
  final StreamController<Duration> _duration = StreamController<Duration>.broadcast();
  final StreamController<int> _index = StreamController<int>.broadcast();
  final StreamController<bool> _completed = StreamController<bool>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();

  @override
  bool get skipOnError => false;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<int> get indexStream => _index.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Future<void> open(List<String> paths, int index) async => calls.add('open:$index');
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration to) async => calls.add('seek:${to.inSeconds}');
  @override
  Future<void> next() async => calls.add('next');
  @override
  Future<void> previous() async => calls.add('previous');
  @override
  Future<void> jumpTo(int index) async => calls.add('jump:$index');
  @override
  Future<void> setRepeatOne(bool one) async => calls.add('repeat:$one');
  @override
  Future<void> setVolume(double volume) async {}
}

TrackInfo _track(String id) => TrackInfo(
      id: id,
      playlistId: 'p',
      title: id,
      fileName: '$id.mp3',
      path: '/music/$id.mp3',
      isVideo: false,
    );

void main() {
  test('«назад»: один раз - в начало трека, второй раз подряд - предыдущий трек', () async {
    final engine = FakeEngine();
    final service = PlayerService.instance;
    service.engineFactory = () => engine;

    await service.playQueue([_track('a'), _track('b'), _track('c')], 1);
    engine.calls.clear();

    await service.previous();
    expect(engine.calls, ['seek:0']);

    await service.previous();
    expect(engine.calls, ['seek:0', 'jump:0']);

    // после перехода счёт начинается заново: снова «в начало»
    await service.previous();
    expect(engine.calls.last, 'seek:0');
  });
}
