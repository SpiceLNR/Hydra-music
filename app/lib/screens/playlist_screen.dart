import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import 'player_screen.dart';

/// Список треков плейлиста.
///
/// Обычный режим: нажатие выбирает трек, внизу кнопки «Играть», «Переместить», «Удалить»
/// (удаление и перемещение с подтверждением).
/// Режим редактирования: включается долгим нажатием на любой трек; порядок меняется
/// перетаскиванием за зелёную область справа. Кнопка «Готово» (или «назад») выходит из режима.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.playlist});
  final PlaylistInfo playlist;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<TrackInfo> _tracks = const [];
  bool _loading = true;
  bool _editing = false;
  String? _selectedId;

  /// Перестановки идут в ядро строго по очереди, чтобы порядок операций не перепутался.
  Future<void> _reorderQueue = Future<void>.value();

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

  void _startEditing() {
    HapticFeedback.mediumImpact();
    setState(() {
      _editing = true;
      _selectedId = null;
    });
  }

  void _stopEditing() => setState(() => _editing = false);

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;
    final moved = _tracks[oldIndex];
    final target = newIndex;
    setState(() {
      final list = List<TrackInfo>.of(_tracks);
      list.removeAt(oldIndex);
      list.insert(target, moved);
      _tracks = list;
    });
    _reorderQueue = _reorderQueue.then((_) async {
      try {
        await hydraLibrary.reorder(moved.id, target);
      } on CoreException catch (e) {
        if (mounted) _toast(e.message);
        await _load();
      }
    });
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
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlayerScreen()));
  }

  Widget _normalList() {
    return ListView.builder(
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
            onLongPress: _startEditing,
          ),
        );
      },
    );
  }

  Widget _editList() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Тяните за зелёную область справа, чтобы изменить порядок.'),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _tracks.length,
            onReorder: _onReorder,
            proxyDecorator: (child, index, animation) =>
                Material(color: Metro.surface, child: child),
            itemBuilder: (context, i) {
              final t = _tracks[i];
              return Container(
                key: ValueKey<String>(t.id),
                color: Metro.surface,
                margin: const EdgeInsets.only(bottom: 2),
                child: ListTile(
                  leading: Cover(isVideo: t.isVideo),
                  title: Text('${i + 1}. ${t.title}', style: const TextStyle(fontSize: 18)),
                  subtitle: Text(t.artist ?? t.fileName),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: Container(
                      width: 56,
                      height: 56,
                      color: Metro.green,
                      child: const Icon(Icons.drag_handle, color: Colors.white, size: 32),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _bottom(TrackInfo? selected) {
    if (_editing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NowPlayingBar(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Готово'),
                  onPressed: _stopEditing,
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (selected == null) return const NowPlayingBar(safeBottom: true);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const NowPlayingBar(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
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
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _stopEditing();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? 'редактирование' : widget.playlist.name.toLowerCase()),
          actions: [
            if (!_editing)
              IconButton(
                tooltip: 'Обновить',
                icon: const Icon(Icons.refresh),
                onPressed: _refresh,
              ),
          ],
        ),
        body: _loading
            ? const Center(child: SizedBox(width: 200, child: MetroProgress()))
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
                : (_editing ? _editList() : _normalList()),
        bottomNavigationBar: _bottom(_selected),
      ),
    );
  }
}
