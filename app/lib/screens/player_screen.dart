import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Экран плеера: обложка, название, кнопки назад / пауза / вперёд, полоса позиции.
/// Шестерёнка справа вверху открывает окно правки: обложка, название, исполнитель.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  double? _drag;

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  /// Мини-окно правки трека: обложка, название, исполнитель.
  Future<void> _openSettings(TrackInfo track) async {
    final result = await showDialog<_TrackEdit>(
      context: context,
      builder: (ctx) => _TrackSettingsDialog(track: track),
    );
    if (result == null) return;
    final artist = result.artist.trim();
    final title = result.title.trim();
    final sameTitle = title == track.title;
    final sameArtist = artist == (track.artist ?? '').trim();
    if (sameTitle && sameArtist) return;
    try {
      final written = await hydraLibrary.editTrack(track.id, title, artist);
      PlayerService.instance.updateTrack(track.copyWith(
        title: title,
        artist: artist.isEmpty ? null : artist,
        clearArtist: artist.isEmpty,
      ));
      if (mounted) {
        _toast(written
            ? 'Сохранено, теги записаны в файл.'
            : 'Этот формат не хранит теги: изменения сохранены только в приложении.');
      }
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ps = PlayerService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([ps, hydraLibrary]),
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
          appBar: AppBar(
            title: const Text('плеер'),
            actions: [
              IconButton(
                tooltip: 'Настройки трека',
                icon: const Icon(Icons.settings, color: Metro.textDim),
                onPressed: () => _openSettings(track),
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(aspectRatio: 1, child: _BigCover(track: track, revision: hydraLibrary.tracksRevision)),
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
  const _BigCover({required this.track, required this.revision});
  final TrackInfo track;

  /// Растёт после замены обложки: по нему картинка перечитывается.
  final int revision;

  @override
  State<_BigCover> createState() => _BigCoverState();
}

class _BigCoverState extends State<_BigCover> {
  late Future<String?> _future = hydraLibrary.coverPath(widget.track.id);

  @override
  void didUpdateWidget(covariant _BigCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id || oldWidget.revision != widget.revision) {
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

/// Результат окна правки.
class _TrackEdit {
  const _TrackEdit(this.title, this.artist);
  final String title;
  final String artist;
}

/// Окно правки: «Изменить обложку», поле названия, поле исполнителя.
/// Обложка заменяется сразу после выбора картинки, название и исполнитель - по «Сохранить».
class _TrackSettingsDialog extends StatefulWidget {
  const _TrackSettingsDialog({required this.track});
  final TrackInfo track;

  @override
  State<_TrackSettingsDialog> createState() => _TrackSettingsDialogState();
}

class _TrackSettingsDialogState extends State<_TrackSettingsDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.track.title);
  late final TextEditingController _artist =
      TextEditingController(text: widget.track.artist ?? '');
  String? _coverNote;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      setState(() => _coverNote = 'Не удалось открыть выбор картинки: $e');
      return;
    }
    if (picked == null) return;
    setState(() {
      _busy = true;
      _coverNote = null;
    });
    try {
      await hydraLibrary.setCover(widget.track.id, picked.path);
      if (mounted) setState(() => _coverNote = 'Обложка записана в файл.');
    } on CoreException catch (e) {
      if (mounted) setState(() => _coverNote = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Настройки трека', style: TextStyle(fontWeight: FontWeight.w300, fontSize: 24)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pickCover,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Изменить обложку'),
              ),
            ),
            if (_coverNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_coverNote!, style: Theme.of(context).textTheme.bodyMedium),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              decoration: Metro.inputDecoration(hint: 'Название композиции'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _artist,
              decoration: Metro.inputDecoration(hint: 'Исполнитель'),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () => Navigator.pop(context, _TrackEdit(_title.text, _artist.text)),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
