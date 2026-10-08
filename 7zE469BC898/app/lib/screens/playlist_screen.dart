import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets/marquee_text.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import 'player_screen.dart';

/// Список треков плейлиста.
///
/// Обычный режим: нажатие выбирает трек, внизу кнопки «Играть», «Название», «Обложка»,
/// «Переместить», «Удалить» (удаление и перемещение с подтверждением).
/// Пустой плейлист можно удалить кнопкой по центру экрана.
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

  /// Выбор способа сортировки; порядок плейлиста заменяется выбранным.
  Future<void> _chooseSort() async {
    const options = <(String, String)>[
      ('file_asc', 'По имени файла А → Я'),
      ('file_desc', 'По имени файла Я → А'),
      ('artist_asc', 'По исполнителю А → Я'),
      ('artist_desc', 'По исполнителю Я → А'),
      ('date_new', 'По дате добавления: новые сверху'),
      ('date_old', 'По дате добавления: старые сверху'),
    ];
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Сортировка'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text('Текущий порядок треков в плейлисте будет заменён.'),
          ),
          for (final o in options)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, o.$1), child: Text(o.$2)),
        ],
      ),
    );
    if (choice == null) return;
    final sorted = await _sorted(choice);
    await _act(() => hydraLibrary.sortTracks(widget.playlist.id, [for (final t in sorted) t.id]));
    if (mounted) _toast('Отсортировано');
  }

  Future<List<TrackInfo>> _sorted(String mode) async {
    final list = List<TrackInfo>.of(_tracks);
    int byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    switch (mode) {
      case 'file_asc':
        list.sort((a, b) => byText(a.fileName, b.fileName));
      case 'file_desc':
        list.sort((a, b) => byText(b.fileName, a.fileName));
      case 'artist_asc' || 'artist_desc':
        final artistSign = mode == 'artist_asc' ? 1 : -1;
        list.sort((a, b) {
          final x = (a.artist ?? '').trim();
          final y = (b.artist ?? '').trim();
          // треки без исполнителя всегда в конце
          if (x.isEmpty != y.isEmpty) return x.isEmpty ? 1 : -1;
          final c = byText(x, y);
          return c != 0 ? artistSign * c : byText(a.fileName, b.fileName);
        });
      default:
        // дата добавления = время изменения файла (когда он появился на устройстве)
        final times = <String, int>{};
        for (final t in list) {
          try {
            times[t.id] = (await File(t.path).lastModified()).millisecondsSinceEpoch;
          } catch (_) {
            times[t.id] = 0;
          }
        }
        final dateSign = mode == 'date_new' ? -1 : 1;
        list.sort((a, b) {
          final c = times[a.id]!.compareTo(times[b.id]!);
          return c != 0 ? dateSign * c : byText(a.fileName, b.fileName);
        });
    }
    return list;
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

  Future<void> _rename(TrackInfo t) async {
    final controller = TextEditingController(text: t.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Название трека'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: Metro.inputDecoration(hint: 'Название'),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (title == null || title.isEmpty || title == t.title) return;
    try {
      final written = await hydraLibrary.renameTrack(t.id, title);
      if (mounted) {
        _toast(written
            ? 'Название записано в файл.'
            : 'Этот формат не хранит теги: название сохранено только в приложении.');
      }
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _changeCover(TrackInfo t) async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      if (mounted) _toast('Не удалось открыть выбор картинки: $e');
      return;
    }
    if (picked == null) return;
    try {
      await hydraLibrary.setCover(t.id, picked.path);
      if (mounted) _toast('Обложка записана в файл.');
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _deletePlaylist() async {
    final ok = await confirmAction(
      context,
      title: 'Удалить плейлист?',
      message: 'Пустая папка «${widget.playlist.name}» будет удалена.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    try {
      await hydraLibrary.deletePlaylist(widget.playlist.id);
      if (mounted) Navigator.of(context).pop();
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
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
            // у выбранного трека название и исполнитель едут бегущей строкой;
            // высота строки у всех одинаковая
            title: MarqueeText('${i + 1}. ${t.title}',
                style: const TextStyle(fontSize: 18), active: isSel),
            subtitle: MarqueeText(t.artist ?? t.fileName, active: isSel),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(
            children: [
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Тяните за зелёную область справа, чтобы изменить порядок.'),
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.sort),
                label: const Text('Сортировка'),
                onPressed: _tracks.length < 2 ? null : _chooseSort,
              ),
            ],
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
                  title: MarqueeText('${i + 1}. ${t.title}', style: const TextStyle(fontSize: 18)),
                  subtitle: MarqueeText(t.artist ?? t.fileName),
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
                  child: MetroAction(
                    icon: Icons.play_arrow,
                    label: 'Играть',
                    filled: true,
                    onPressed: () => _play(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.edit_outlined,
                    label: 'Название',
                    onPressed: () => _rename(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.image_outlined,
                    label: 'Обложка',
                    onPressed: () => _changeCover(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.drive_file_move_outline,
                    label: 'Переместить',
                    onPressed: () => _move(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.delete_outline,
                    label: 'Удалить',
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Папка пуста. Положите файлы в Music/Hydra/${widget.playlist.name} '
                            'и нажмите «Обновить».',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Удалить плейлист'),
                            onPressed: _deletePlaylist,
                          ),
                        ],
                      ),
                    ),
                  )
                : (_editing ? _editList() : _normalList()),
        bottomNavigationBar: _bottom(_selected),
      ),
    );
  }
}
