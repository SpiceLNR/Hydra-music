import 'package:flutter/material.dart';

import '../models.dart';
import '../widgets/metro_widgets.dart';

/// Экран плеера: обложка, название, кнопки назад / пауза / вперёд, полоса позиции.
/// Каркас: реальное воспроизведение подключается через media_kit на этапе 2.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.queue, required this.start});
  final List<Track> queue;
  final Track start;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late int index = widget.queue.indexOf(widget.start);
  bool playing = true;
  double position = 0;

  Track get track => widget.queue[index];

  void _step(int delta) {
    final next = index + delta;
    if (next < 0 || next >= widget.queue.length) return;
    setState(() {
      index = next;
      position = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('плеер')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Cover(isVideo: track.isVideoContainer, size: 240),
                  ),
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
              Slider(value: position, onChanged: (v) => setState(() => position = v)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: index > 0 ? () => _step(-1) : null,
                      child: const Icon(Icons.skip_previous, size: 32),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () => setState(() => playing = !playing),
                      child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 32),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: index < widget.queue.length - 1 ? () => _step(1) : null,
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
  }
}
