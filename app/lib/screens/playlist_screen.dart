import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import 'player_screen.dart';

/// Список треков плейлиста. Каждое действие - явная кнопка; удаление и перемещение
/// требуют подтверждения.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.playlist});
  final PlaylistInfo playlist;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<TrackInfo> _tracks = const [];
  bool _loading = true;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  TrackInfo? get _selected {
    for (final t in _tracks) {
      if (t.id == _selectedId) return t;
    }
    return null;
  }

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _load() async {
    try {
      final tracks = await hydraLibrary.tracks(widget.playlist.id);
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _loading = false;
        if (_selected == null) _selectedId = null;
      });
    } on CoreException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e.message);
    }
  }

  /// Выполняет действие ядра, показывает ошибку и перечитывает список.
  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _refresh() async {
    await hydraLibrary.refresh();
    await _load();
  }

  Future<void> _shift(TrackInfo t, int delta) async {
    final from = _tracks.indexOf(t);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= _tracks.length) return;
    await _act(() => hydraLibrary.reorder(t.id, to));
  }

  Future<void> _delete(TrackInfo t) async {
    final ok = await confirmAction(
      context,
      title: 'Удалить трек?',
      message: '«${t.title}» уйдёт в корзину на 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await _act(() => hydraLibrary.deleteTrack(t.id));
  }

  Future<void> _move(TrackInfo t) async {
    final targets = hydraLibrary.playlists.where((p) => p.id != widget.playlist.id).toList();
    if (targets.isEmpty) {
      _toast('Нет другого плейлиста. Создайте его на экране «Плейлисты».');
      return;
    }
    final target = await showDialog<PlaylistInfo>(
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
    await _act(() => hydraLibrary.moveTrack(t.id, target.id));
  }

  Future<void> _play(TrackInfo t) async {
    await PlayerService.instance.playQueue(_tracks, _tracks.indexOf(t));
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlayerScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name.toLowerCase()),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Metro.green))
          : _tracks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Папка пуста. Положите файлы в Music/Hydra/${widget.playlist.name} '
                      'и нажмите «Обновить».',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _tracks.length,
                  itemBuilder: (context, i) {
                    final t = _tracks[i];
                    final isSel = t.id == _selectedId;
                    return Container(
                      color: isSel ? Metro.surface : null,
                      child: ListTile(
                        leading: Cover(isVideo: t.isVideo),
                        title: Text('${i + 1}. ${t.title}', style: const TextStyle(fontSize: 18)),
                        subtitle: Text(t.artist ?? t.fileName),
                        onTap: () => setState(() => _selectedId = isSel ? null : t.id),
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
                            onPressed: _tracks.indexOf(selected) > 0
                                ? () => _shift(selected, -1)
                                : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.arrow_downward),
                            label: const Text('Ниже'),
                            onPressed: _tracks.indexOf(selected) < _tracks.length - 1
                                ? () => _shift(selected, 1)
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
                            onPressed: () => _play(selected),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.drive_file_move_outline),
                            label: const Text('Переместить'),
                            onPressed: () => _move(selected),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Удалить'),
                            onPressed: () => _delete(selected),
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
