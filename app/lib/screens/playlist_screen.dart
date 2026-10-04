import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import 'player_screen.dart';

/// Список треков плейлиста. Каждое действие - явная кнопка; удаление и перемещение
/// требуют подтверждения.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.playlist, required this.allPlaylists});
  final Playlist playlist;
  final List<Playlist> allPlaylists;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  Track? selected;

  Future<void> _delete(Track t) async {
    final ok = await confirmAction(
      context,
      title: 'Удалить трек?',
      message: '«${t.title}» уйдёт в корзину на 30 дней на всех ваших устройствах.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    // TODO(core): journal::record_local(Kind::Delete)
    setState(() {
      widget.playlist.tracks.remove(t);
      selected = null;
    });
  }

  Future<void> _move(Track t) async {
    final targets = widget.allPlaylists.where((p) => p.id != widget.playlist.id).toList();
    if (targets.isEmpty) return;
    final target = await showDialog<Playlist>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Переместить в…'),
        children: [
          for (final p in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(p.name, style: const TextStyle(fontSize: 18)),
              ),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final ok = await confirmAction(
      context,
      title: 'Переместить трек?',
      message: '«${t.title}» будет перенесён из «${widget.playlist.name}» в «${target.name}». '
          'Файл физически переместится между папками.',
      confirmLabel: 'Переместить',
    );
    if (!ok) return;
    // TODO(core): journal::record_local(Kind::Move) + перенос файла на диске
    setState(() {
      widget.playlist.tracks.remove(t);
      target.tracks.add(t);
      selected = null;
    });
  }

  /// Сдвиг трека на одну позицию вверх (-1) или вниз (+1) в порядке воспроизведения.
  void _shift(Track t, int delta) {
    final list = widget.playlist.tracks;
    final from = list.indexOf(t);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= list.length) return;
    // TODO(core): journal::reorder_within(track_id, to) - порядок синхронизируется между устройствами
    setState(() {
      list.removeAt(from);
      list.insert(to, t);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.playlist.tracks;
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlist.name.toLowerCase())),
      body: tracks.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Папка пуста. Положите файлы в Music/Hydra/ - они подтянутся сами.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (context, i) {
                final t = tracks[i];
                final isSel = identical(selected, t);
                return Container(
                  color: isSel ? Metro.surface : null,
                  child: ListTile(
                    leading: Cover(isVideo: t.isVideoContainer),
                    title: Text('${i + 1}. ${t.title}', style: const TextStyle(fontSize: 18)),
                    subtitle: Text(t.fileName),
                    onTap: () => setState(() => selected = isSel ? null : t),
                  ),
                );
              },
            ),
      bottomNavigationBar: selected == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.arrow_upward),
                            label: const Text('Выше'),
                            onPressed: tracks.indexOf(selected!) > 0
                                ? () => _shift(selected!, -1)
                                : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.arrow_downward),
                            label: const Text('Ниже'),
                            onPressed: tracks.indexOf(selected!) < tracks.length - 1
                                ? () => _shift(selected!, 1)
                                : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Играть'),
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => PlayerScreen(queue: tracks, start: selected!))),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.drive_file_move_outline),
                            label: const Text('Переместить'),
                            onPressed: () => _move(selected!),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Удалить'),
                            onPressed: () => _delete(selected!),
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
