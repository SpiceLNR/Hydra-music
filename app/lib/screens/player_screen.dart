import 'dart:io';

import 'package:flutter/material.dart';

import '../library_controller.dart';
import '../models.dart';
import '../player_service.dart';
import '../widgets/metro_widgets.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Экран плеера: обложка, название, кнопки назад / пауза / вперёд, полоса позиции.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final ps = PlayerService.instance;
    return ListenableBuilder(
      listenable: ps,
      builder: (context, _) {
        final track = ps.current;
        if (track == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('плеер')),
            body: const Center(child: Text('Ничего не играет')),
          );
        }
        final max = ps.duration.inMilliseconds > 0 ? ps.duration.inMilliseconds.toDouble() : 1.0;
        final value = (_drag ?? ps.position.inMilliseconds.toDouble()).clamp(0.0, max).toDouble();
        return Scaffold(
          appBar: AppBar(title: const Text('плеер')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(aspectRatio: 1, child: _BigCover(track: track)),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(track.title, style: Theme.of(context).textTheme.titleLarge),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(track.artist ?? track.fileName,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  const SizedBox(height: 8),
                  MetroSlider(
                    value: value,
                    max: max,
                    onChanged: (v) => setState(() => _drag = v),
                    onChangeEnd: (v) {
                      ps.seek(Duration(milliseconds: v.round()));
                      setState(() => _drag = null);
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(Duration(milliseconds: value.round()))),
                      Text(_fmt(ps.duration)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: ps.index > 0 ? ps.previous : null,
                          child: const Icon(Icons.skip_previous, size: 32),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: ps.playOrPause,
                          child: Icon(ps.playing ? Icons.pause : Icons.play_arrow, size: 32),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: ps.index < ps.queue.length - 1 ? ps.next : null,
                          child: const Icon(Icons.skip_next, size: 32),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Обложка из тегов файла; если её нет, значок ноты или киноплёнки для видео.
class _BigCover extends StatefulWidget {
  const _BigCover({required this.track});
  final TrackInfo track;

  @override
  State<_BigCover> createState() => _BigCoverState();
}

class _BigCoverState extends State<_BigCover> {
  late Future<String?> _future = hydraLibrary.coverPath(widget.track.id);

  @override
  void didUpdateWidget(covariant _BigCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) {
      _future = hydraLibrary.coverPath(widget.track.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snap) {
        final path = snap.data;
        if (path != null) return Image.file(File(path), fit: BoxFit.cover);
        return Cover(isVideo: widget.track.isVideo, size: 240);
      },
    );
  }
}
