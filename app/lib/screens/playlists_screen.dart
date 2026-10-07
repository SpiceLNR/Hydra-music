import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import 'playlist_screen.dart';

/// Список плейлистов.
///
/// Обычный режим: нажатие открывает плейлист. Долгое нажатие на плейлист включает режим
/// редактирования: рядом с каждым плейлистом кнопка «переименовать», а порядок меняется
/// перетаскиванием за тёмно-зелёную область справа. «Готово» (или «назад») выходит из режима.
class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  bool _editing = false;

  /// Копия списка на время редактирования: перетаскивание не должно «прыгать»,
  /// пока ядро обрабатывает перестановки.
  List<PlaylistInfo> _order = const [];

  /// Перестановки идут в ядро строго по очереди.
  Future<void> _queue = Future<void>.value();

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  void _startEditing() {
    HapticFeedback.mediumImpact();
    setState(() {
      _editing = true;
      _order = List<PlaylistInfo>.of(hydraLibrary.playlists);
    });
  }

  void _stopEditing() => setState(() => _editing = false);

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый плейлист'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: Metro.inputDecoration(hint: 'Название папки'),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Создать')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await hydraLibrary.createPlaylist(name);
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  Future<void> _rename(PlaylistInfo p) async {
    final controller = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переименовать плейлист'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: Metro.inputDecoration(hint: 'Название папки'),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == p.name) return;
    try {
      await hydraLibrary.renamePlaylist(p.id, name);
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    if (mounted) setState(() => _order = List<PlaylistInfo>.of(hydraLibrary.playlists));
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;
    final moved = _order[oldIndex];
    final target = newIndex;
    setState(() {
      final list = List<PlaylistInfo>.of(_order);
      list.removeAt(oldIndex);
      list.insert(target, moved);
      _order = list;
    });
    _queue = _queue.then((_) async {
      try {
        await hydraLibrary.reorderPlaylist(moved.id, target);
      } on CoreException catch (e) {
        if (mounted) {
          _toast(e.message);
          setState(() => _order = List<PlaylistInfo>.of(hydraLibrary.playlists));
        }
      }
    });
  }

  Widget _label(PlaylistInfo p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(p.name,
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.w400, color: Colors.white)),
        Text('${p.trackCount} треков', style: const TextStyle(color: Colors.white)),
      ],
    );
  }

  Widget _normalList(List<PlaylistInfo> playlists) {
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: playlists.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final p = playlists[i];
        return Material(
          color: Metro.green,
          child: InkWell(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => PlaylistScreen(playlist: p))),
            onLongPress: _startEditing,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.folder_open, size: 36, color: Colors.white),
                  const SizedBox(width: 16),
                  Expanded(child: _label(p)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _editList() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Тяните за тёмную область справа, чтобы изменить порядок. '
                'Карандаш переименовывает плейлист.'),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: _order.length,
            onReorder: _onReorder,
            proxyDecorator: (child, index, animation) =>
                Material(color: Metro.green, child: child),
            itemBuilder: (context, i) {
              final p = _order[i];
              return Container(
                key: ValueKey<String>(p.id),
                color: Metro.green,
                margin: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    const Icon(Icons.folder_open, size: 36, color: Colors.white),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: _label(p),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Переименовать',
                      icon: const Icon(Icons.edit_outlined, color: Colors.white),
                      onPressed: () => _rename(p),
                    ),
                    ReorderableDragStartListener(
                      index: i,
                      child: Container(
                        width: 56,
                        height: 88,
                        color: Metro.greenDark,
                        child: const Icon(Icons.drag_handle, color: Colors.white, size: 32),
                      ),
                    ),
                  ],
                ),
              );
            },
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
          title: Text(_editing ? 'редактирование' : 'плейлисты'),
          actions: [
            if (!_editing)
              IconButton(
                tooltip: 'Обновить',
                icon: const Icon(Icons.refresh),
                onPressed: hydraLibrary.refresh,
              ),
          ],
        ),
        body: ListenableBuilder(
          listenable: hydraLibrary,
          builder: (context, _) {
            final playlists = hydraLibrary.playlists;
            return Column(
              children: [
                if (hydraLibrary.scanning) const MetroProgress(),
                Expanded(
                  child: playlists.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Плейлистов пока нет.\nСоздайте плейлист кнопкой ниже или положите '
                              'папку с музыкой в Music/Hydra.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : (_editing ? _editList() : _normalList(playlists)),
                ),
              ],
            );
          },
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NowPlayingBar(),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: double.infinity,
                  child: _editing
                      ? ElevatedButton.icon(
                          onPressed: _stopEditing,
                          icon: const Icon(Icons.check),
                          label: const Text('Готово'),
                        )
                      : ElevatedButton.icon(
                          onPressed: _create,
                          icon: const Icon(Icons.add),
                          label: const Text('Новый плейлист'),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
